"""Read only explicit remaining percentages from a user-supplied Antigravity /usage transcript."""

from __future__ import annotations

import hashlib
import json
import re
from decimal import Decimal

from gaociyuan.errors import AppError
from gaociyuan.timeutil import format_iso, parse_instant

REPORT_FIELD = "antigravityReport"
REPORT_SOURCE = "Antigravity 独立版 /usage 手动报告"
HISTORICAL_SOURCES = frozenset((
    REPORT_SOURCE,
    "Gemini 内置 Antigravity · 手动报告",
    "Antigravity 独立版 · /usage 手动报告",
    "Gemini App 中的 Antigravity",
    "Gemini App 中的 Antigravity · /usage",
    "Antigravity /usage 手动报告",
    "Antigravity 本机服务",
))
MAX_BYTES = 65_536
MAX_FINGERPRINTS = 64
IMPORT_HELP = "请在账户设置为所选 Antigravity 账户手动导入 /usage 文本。"

_GROUPS = {"Gemini Models": "gemini-models", "Claude and GPT models": "claude-gpt-models"}
_HEADINGS = {title.casefold(): slug for title, slug in _GROUPS.items()}
_WINDOWS = {
    "Five Hour Limit Remaining": ("five-hour", "5 小时", 18_000),
    "Weekly Limit Remaining": ("weekly", "每周", 604_800),
}
_QUOTAS = {
    f"antigravity-{group}-{window}": (f"{group_title} · {label}", seconds)
    for group_title, group in _GROUPS.items()
    for window, label, seconds in _WINDOWS.values()
}
_WINDOW_LINE = re.compile(r"^(Five Hour Limit Remaining|Weekly Limit Remaining)(?:\s*:\s*|\s+|$)(.*)$", re.IGNORECASE)
_WINDOW_KEYS = {label.casefold(): window for label, (window, _, _) in _WINDOWS.items()}
_PERCENT = re.compile(r"(?:[░▒▓█■□━─]+\s*)?([0-9]{1,3}(?:\.[0-9]{1,6})?)\s*%")
_STYLE = re.compile(r"\x1b\[[0-9;:]*m")
_BORDER = re.compile(r"[╭╮╰╯┌┐└┘├┤┬┴┼┏┓┗┛━─═+ -]+")
_DIGEST = re.compile(r"[a-f0-9]{64}")
_UNAVAILABLE = {"n/a", "unknown", "unavailable", "—"}


def _invalid() -> AppError:
    return AppError("未读到明确的 Antigravity 模型组与剩余额度。请选择 /usage 的 UTF-8 文本报告。")


def _quota(key: str, used: float) -> dict:
    title, seconds = _QUOTAS[key]
    return {"id": key, "title": title, "usedPercent": used, "windowSeconds": seconds,
            "resetsAt": None, "exhausted": False}


def parse_report(text: str) -> list[dict]:
    if not isinstance(text, str) or len(text) > MAX_BYTES:
        raise _invalid()
    try:
        if len(text.encode("utf-8")) > MAX_BYTES:
            raise _invalid()
    except UnicodeEncodeError as exc:
        raise _invalid() from exc

    group = None
    pending = None
    used_by_id = {}
    seen = set()
    for raw in _STYLE.sub("", text.removeprefix("\ufeff")).splitlines():
        line = raw.strip("│┃| \t")
        if not line or _BORDER.fullmatch(line):
            continue
        heading = _HEADINGS.get(line.rstrip(":").strip().casefold())
        if heading:
            if pending:
                raise _invalid()
            group = heading
            continue
        if group is None:
            continue
        window = _WINDOW_LINE.fullmatch(line.replace("│", " ").replace("┃", " ").replace("|", " "))
        if window:
            if pending:
                raise _invalid()
            key = f"antigravity-{group}-{_WINDOW_KEYS[window[1].casefold()]}"
            value = window[2].strip()
            if not value:
                pending = key
                continue
        elif pending:
            key, value = pending, line
            pending = None
        else:
            # Another heading or control line may introduce a different model group.
            group = None
            continue
        if key in seen:
            raise _invalid()
        seen.add(key)
        if value.casefold() in _UNAVAILABLE:
            continue
        match = _PERCENT.fullmatch(value)
        if not match:
            raise _invalid()
        remaining = Decimal(match[1])
        if not 0 <= remaining <= 100:
            raise _invalid()
        used_by_id[key] = float(100 - remaining)
    if pending or not used_by_id:
        raise _invalid()
    return [_quota(key, used_by_id[key]) for key in _QUOTAS if key in used_by_id]


def report_fingerprint(quotas: list[dict]) -> str:
    normalized = [(quota["id"], quota["usedPercent"]) for quota in quotas]
    return hashlib.sha256(json.dumps(normalized, separators=(",", ":")).encode("ascii")).hexdigest()


def public_report(record: dict | None) -> dict | None:
    if record is None:
        return None
    return {"source": REPORT_SOURCE, "importedAt": record["importedAt"], "observedAt": None,
            "verified": False, "quotas": record["quotas"]}


def decode_report(record: object) -> dict | None:
    if not isinstance(record, dict):
        return None
    try:
        imported = parse_instant(record.get("importedAt"))
    except (OverflowError, ValueError):
        return None
    quotas = record.get("quotas")
    if imported is None or not isinstance(quotas, list) or not 1 <= len(quotas) <= len(_QUOTAS):
        return None
    used_by_id = {}
    for item in quotas:
        if not isinstance(item, dict):
            return None
        key, used = item.get("id"), item.get("usedPercent")
        if not isinstance(key, str) or key not in _QUOTAS or key in used_by_id or type(used) not in (int, float) or not 0 <= used <= 100:
            return None
        used_by_id[key] = float(used)
    quotas = [_quota(key, used_by_id[key]) for key in _QUOTAS if key in used_by_id]
    saved = record.get("fingerprints")
    fingerprints = [item for item in saved[-MAX_FINGERPRINTS:] if isinstance(item, str) and _DIGEST.fullmatch(item)] if isinstance(saved, list) else []
    current = report_fingerprint(quotas)
    fingerprints = [item for item in fingerprints if item != current] + [current]
    return {"importedAt": format_iso(imported), "quotas": quotas, "fingerprints": fingerprints[-MAX_FINGERPRINTS:]}
