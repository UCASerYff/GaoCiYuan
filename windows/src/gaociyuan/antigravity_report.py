"""Read only explicit quota measurements from a user-selected Antigravity /usage report."""

from __future__ import annotations

import json
import re
from decimal import Decimal, DecimalException
from typing import NoReturn

from gaociyuan.errors import AppError
from gaociyuan.timeutil import format_iso, parse_instant

REPORT_FIELD = "antigravityReport"
REPORT_SOURCE = "Antigravity 独立版 /usage 手动报告"
JSON_REPORT_SOURCE = "Antigravity 独立 CLI · /usage JSON（手动导入）"
HISTORICAL_SOURCES = frozenset((
    REPORT_SOURCE,
    JSON_REPORT_SOURCE,
    "Gemini 内置 Antigravity · 手动报告",
    "Gemini 内置 Antigravity · 手工记录",
    "Antigravity 独立版 · /usage 手动报告",
    "Gemini App 中的 Antigravity",
    "Gemini App 中的 Antigravity · /usage",
    "Antigravity /usage 手动报告",
    "Antigravity 本机服务",
))
MAX_BYTES = 65_536
IMPORT_HELP = "请为所选 Antigravity 账户手动导入 /usage JSON 或文本报告。"

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
_UNAVAILABLE = {"n/a", "unknown", "unavailable", "—"}
_JSON_WINDOWS = {"5h": ("5 小时", 18_000), "weekly": ("每周", 604_800)}
_WINDOW_BY_SECONDS = {seconds: window for window, (_, seconds) in _JSON_WINDOWS.items()}
_KNOWN_JSON_BUCKETS = {
    "gemini-5h": ("Gemini Models", "5h"),
    "gemini-weekly": ("Gemini Models", "weekly"),
    "3p-5h": ("Claude and GPT models", "5h"),
    "3p-weekly": ("Claude and GPT models", "weekly"),
    "gemini-argon-wtu-weekly": ("Gemini 4 Argon", "weekly"),
}
_JSON_TOKEN_COUNTERS = ("input_tokens", "output_tokens", "thinking_tokens", "cache_read_tokens", "total_tokens")
_BUCKET_ID = re.compile(r"[a-z0-9][a-z0-9._-]{0,79}")
_GROUP_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9 .+_&()'–-]{0,79}")
_RESET_TIME = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,9})?(?:Z|[+-](?:[01][0-9]|2[0-3]):[0-5][0-9])")
_MAX_QUOTAS = 64


def _invalid() -> AppError:
    return AppError("未读到明确的 Antigravity 模型组与剩余额度。请选择 /usage 的 UTF-8 JSON 或文本报告。")


def _quota(key: str, used: float) -> dict:
    title, seconds = _QUOTAS[key]
    return {"id": key, "title": title, "usedPercent": used, "windowSeconds": seconds,
            "resetsAt": None, "exhausted": False}


def parse_report(text: str) -> tuple[str, list[dict]]:
    if not isinstance(text, str) or len(text) > MAX_BYTES:
        raise _invalid()
    try:
        if len(text.encode("utf-8")) > MAX_BYTES:
            raise _invalid()
    except UnicodeEncodeError as exc:
        raise _invalid() from exc
    document = text.removeprefix("\ufeff").lstrip()
    if document.startswith(("{", "[")):
        return JSON_REPORT_SOURCE, _parse_json_report(document)
    return REPORT_SOURCE, _parse_text_report(document)


def _parse_text_report(document: str) -> list[dict]:
    group = None
    pending = None
    used_by_id = {}
    seen = set()
    for raw in _STYLE.sub("", document).splitlines():
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


def _unique_object(pairs: list[tuple]) -> dict:
    result = dict(pairs)
    if len(result) != len(pairs):
        raise ValueError("Duplicate JSON key")
    return result


def _bad_constant(_value: str) -> NoReturn:
    raise ValueError("Non-finite JSON number")


def _reset(value: object) -> str | None:
    if not isinstance(value, str) or not _RESET_TIME.fullmatch(value):
        return None
    try:
        moment = parse_instant(value)
    except (OverflowError, ValueError):
        return None
    if moment is None:
        return None
    stamp = moment.isoformat().removesuffix("+00:00")
    return (stamp.rstrip("0").rstrip(".") if "." in stamp else stamp) + "Z"


def _json_quota(key: str, group: str, window: str, used: float, reset: object) -> dict:
    known = _KNOWN_JSON_BUCKETS.get(key)
    if known is not None and (group.casefold(), window) != (known[0].casefold(), known[1]):
        raise _invalid()
    label, seconds = _JSON_WINDOWS[window]
    return {"id": key, "title": f"{known[0] if known else group} · {label}", "usedPercent": used,
            "windowSeconds": seconds, "resetsAt": _reset(reset), "exhausted": False}


def _json_quota_order(row: dict) -> tuple:
    group = row["title"].split(" · ", 1)[0]
    rank = ("Gemini Models", "Claude and GPT models")
    return (rank.index(group) if group in rank else len(rank), group.casefold(), row["windowSeconds"], row["id"])


def _is_zero(value: object) -> bool:
    return type(value) in (int, Decimal) and value == 0


def _parse_json_report(document: str) -> list[dict]:
    try:
        payload = json.loads(document, object_pairs_hook=_unique_object, parse_float=Decimal, parse_constant=_bad_constant)
    except (ValueError, RecursionError, DecimalException) as exc:
        raise _invalid() from exc
    if (not isinstance(payload, dict) or payload.get("status") != "SUCCESS" or payload.get("conversation_id") != ""
            or not _is_zero(payload.get("num_turns"))):
        raise _invalid()
    usage, command = payload.get("usage"), payload.get("command")
    if (not isinstance(usage, dict) or not all(_is_zero(usage.get(field)) for field in _JSON_TOKEN_COUNTERS)
            or not isinstance(command, dict) or command.get("name") != "usage"):
        raise _invalid()
    result = command.get("data")
    groups = result.get("groups") if isinstance(result, dict) else None
    if not isinstance(groups, list) or len(groups) > _MAX_QUOTAS:
        raise _invalid()

    quotas = []
    seen = set()
    for group in groups:
        if not isinstance(group, dict) or not isinstance(group.get("buckets"), list):
            raise _invalid()
        name = group.get("name")
        if not isinstance(name, str) or not _GROUP_NAME.fullmatch(name.strip()):
            continue
        name = name.strip()
        for bucket in group["buckets"]:
            if not isinstance(bucket, dict):
                raise _invalid()
            key, window = bucket.get("id"), bucket.get("window")
            if not isinstance(key, str) or not _BUCKET_ID.fullmatch(key):
                continue
            if key in seen or len(seen) >= _MAX_QUOTAS:
                raise _invalid()
            seen.add(key)
            if bucket.get("disabled") is True or bucket.get("remaining_fraction") is None:
                continue
            if not isinstance(window, str) or window not in _JSON_WINDOWS:
                if key in _KNOWN_JSON_BUCKETS:
                    raise _invalid()
                continue
            remaining = bucket["remaining_fraction"]
            if type(remaining) not in (int, Decimal) or not 0 <= remaining <= 1:
                raise _invalid()
            quotas.append(_json_quota(key, name, window, float((1 - remaining) * 100), bucket.get("reset_time")))
    if not quotas:
        raise _invalid()
    return sorted(quotas, key=_json_quota_order)


def public_report(record: dict | None) -> dict | None:
    if record is None:
        return None
    return {"source": record["source"], "importedAt": record["importedAt"], "observedAt": None,
            "verified": False, "quotas": record["quotas"]}


def decode_report(record: object) -> dict | None:
    if not isinstance(record, dict):
        return None
    try:
        imported = parse_instant(record.get("importedAt"))
    except (OverflowError, ValueError):
        return None
    source, stored = record.get("source", REPORT_SOURCE), record.get("quotas")
    if (source not in (REPORT_SOURCE, JSON_REPORT_SOURCE) or imported is None or not isinstance(stored, list)
            or not 1 <= len(stored) <= _MAX_QUOTAS):
        return None
    quotas = {}
    for item in stored:
        if not isinstance(item, dict):
            return None
        key, used = item.get("id"), item.get("usedPercent")
        if not isinstance(key, str) or key in quotas or type(used) not in (int, float) or not 0 <= used <= 100:
            return None
        if source == REPORT_SOURCE:
            if key not in _QUOTAS:
                return None
            quotas[key] = _quota(key, float(used))
            continue
        title, seconds = item.get("title"), item.get("windowSeconds")
        if not isinstance(title, str) or type(seconds) is not int or seconds not in _WINDOW_BY_SECONDS or not _BUCKET_ID.fullmatch(key):
            return None
        group, _, label = title.rpartition(" · ")
        window = _WINDOW_BY_SECONDS[seconds]
        if not _GROUP_NAME.fullmatch(group) or label != _JSON_WINDOWS[window][0]:
            return None
        try:
            quotas[key] = _json_quota(key, group, window, float(used), item.get("resetsAt"))
        except AppError:
            return None
    ordered = sorted(quotas.values(), key=_json_quota_order) if source == JSON_REPORT_SOURCE else [quotas[key] for key in _QUOTAS if key in quotas]
    return {"source": source, "importedAt": format_iso(imported), "quotas": ordered}
