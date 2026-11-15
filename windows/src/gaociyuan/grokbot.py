"""Grok Bot 手动快照约定。

只解析用户另行写成的 grokbot-usage.json。不创建文件、不写回、不访问网络，
也不把缺失或无效文件变成 0%。圆环口径与 Mac `dedicatedRingFace` 相同：
弧长和数字是剩余百分比，由 weeklyPercentUsed 换算；过期后变淡，数字不写「旧」。
"""

from __future__ import annotations

import math
import os
import re
import stat
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from enum import Enum
from pathlib import Path
from typing import Callable
from zoneinfo import ZoneInfo

from gaociyuan.timeutil import format_timestamp, parse_instant

SCHEMA_VERSION = 1
SOURCE_IDENTIFIER = "grok-bot-usage-report"
FILE_NAME = "grokbot-usage.json"
STALE_AFTER = 6 * 60 * 60
FUTURE_SKEW = 60
MAXIMUM_BYTES = 64 * 1024
MAXIMUM_PLAN_LENGTH = 64
REQUIRED_KEYS = {
    "schema",
    "source",
    "capturedAt",
    "plan",
    "weeklyPercentUsed",
    "resetsAt",
    "sharedWithOtherApps",
}
_NUMBER = re.compile(r"^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?$")


class Freshness(Enum):
    CURRENT = "current"
    OLDER_THAN_LIMIT = "olderThanLimit"
    RESET_ELAPSED = "resetElapsed"


class Rejection(Enum):
    MISSING = "missing"
    UNREADABLE = "unreadable"
    TOO_LARGE = "tooLarge"
    INVALID = "invalid"


@dataclass
class Snapshot:
    plan: str
    weekly_percent_used: float
    resets_at: datetime | None
    captured_at: datetime
    shared_with_other_apps: bool


@dataclass
class Reading:
    snapshot: Snapshot
    freshness: Freshness
    line: str
    remaining_line: str
    captured_text: str
    detail: str = ""


def percent_text(value: float) -> str:
    scaled = value * 10_000
    if scaled >= 0:
        rounded = math.floor(scaled + 0.5)
    else:
        rounded = math.ceil(scaled - 0.5)
    text = f"{rounded / 10_000:.4f}"
    while text.endswith("0"):
        text = text[:-1]
    if text.endswith("."):
        text = text[:-1]
    return text


def remaining_percent(used: float) -> float:
    return max(0.0, min(100.0, 100.0 - used))


def freshness_of(snapshot: Snapshot, now: datetime) -> Freshness:
    if snapshot.resets_at is not None and snapshot.resets_at <= now:
        return Freshness.RESET_ELAPSED
    if (now - snapshot.captured_at).total_seconds() > STALE_AFTER:
        return Freshness.OLDER_THAN_LIMIT
    return Freshness.CURRENT


def display_line(snapshot: Snapshot, zone: ZoneInfo) -> str:
    share = "（与套餐内其他应用共享）" if snapshot.shared_with_other_apps else ""
    reset = format_timestamp(snapshot.resets_at, zone) if snapshot.resets_at else "平台未提供重置时间"
    captured = format_timestamp(snapshot.captured_at, zone)
    return f"本周已用 {percent_text(snapshot.weekly_percent_used)}%{share} · 重置 {reset} · 数据 {captured}"


def remaining_display_line(snapshot: Snapshot, zone: ZoneInfo) -> str:
    remaining = percent_text(remaining_percent(snapshot.weekly_percent_used))
    used = percent_text(snapshot.weekly_percent_used)
    share = "（与套餐内其他应用共享）" if snapshot.shared_with_other_apps else ""
    reset = format_timestamp(snapshot.resets_at, zone) if snapshot.resets_at else "平台未提供重置时间"
    captured = format_timestamp(snapshot.captured_at, zone)
    return f"本周剩余 {remaining}%（已用 {used}%）{share} · 重置 {reset} · 数据 {captured}"


def presentation(reading: Reading) -> str:
    lead = f"读取最近一次快照（采集于 {reading.captured_text}）"
    if reading.freshness is Freshness.CURRENT:
        return f"{lead} · {reading.remaining_line}"
    if reading.freshness is Freshness.OLDER_THAN_LIMIT:
        return f"{lead} · 已超过 6 小时，不作为当前读数 · 记录：{reading.line}"
    return f"{lead} · 重置时间已过，不作为本周读数 · 记录：{reading.line}"


def manual_button_title(refreshing: bool) -> str:
    return "正在读取本机额度…" if refreshing else "读取本机额度"


def discovery_status(installed: bool, running: bool) -> str:
    if running:
        return "已检测到 Grok Bot（运行中）。尚无可读取用量，等待记录。"
    if installed:
        return "已检测到 Grok Bot（未启动）。尚无可读取用量，等待记录。"
    return "尚未检测到 Grok Bot。安装或启动后会自动重新检测；等待可读取的用量记录。"


def unavailable_phrase(kind: Rejection) -> str:
    if kind is Rejection.MISSING:
        return ""
    if kind is Rejection.UNREADABLE:
        return "用量记录无法读取，未显示百分比。"
    if kind is Rejection.TOO_LARGE:
        return "用量记录超出大小限制，未显示百分比。"
    return "用量记录不符合 grokbot-usage.json 约定，未显示百分比。"


def presence_prefix(installed: bool, running: bool) -> str:
    if running:
        return "已检测到 Grok Bot（运行中）。"
    if installed:
        return "已检测到 Grok Bot（未启动）。"
    return "尚未检测到 Grok Bot。"


def connector_status(ok: Reading | None, rejection: Rejection | None, installed: bool, running: bool) -> str:
    if ok is not None:
        return presentation(ok)
    if rejection is Rejection.MISSING:
        return discovery_status(installed, running)
    return presence_prefix(installed, running) + unavailable_phrase(rejection or Rejection.INVALID)


def ingest(data: bytes, now: datetime, zone: ZoneInfo) -> tuple[Reading | None, Rejection | None, str]:
    if len(data) > MAXIMUM_BYTES:
        return None, Rejection.TOO_LARGE, ""
    if not data:
        return None, Rejection.INVALID, "文件为空"
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        return None, Rejection.INVALID, "不是 UTF-8"
    tokens, scan_error = _scan_top_level(text)
    if scan_error:
        return None, Rejection.INVALID, scan_error
    used_token = tokens.get("weeklyPercentUsed")
    if used_token is not None and not _is_json_number(used_token):
        return None, Rejection.INVALID, "weeklyPercentUsed 必须为 0 到 100 的数字"
    import json

    try:
        root = json.loads(text)
    except json.JSONDecodeError:
        return None, Rejection.INVALID, "不是 JSON 对象"
    if not isinstance(root, dict):
        return None, Rejection.INVALID, "不是 JSON 对象"
    keys = set(root)
    if keys != REQUIRED_KEYS:
        if REQUIRED_KEYS.issubset(keys):
            return None, Rejection.INVALID, "含有未约定的字段"
        return None, Rejection.INVALID, "缺少约定字段"
    if tokens.get("schema") != "1" or type(root.get("schema")) is not int or root.get("schema") != SCHEMA_VERSION:
        return None, Rejection.INVALID, "schema 必须为整数 1"
    if root.get("source") != SOURCE_IDENTIFIER:
        return None, Rejection.INVALID, "source 必须为 grok-bot-usage-report"
    captured = parse_instant(root.get("capturedAt")) if isinstance(root.get("capturedAt"), str) else None
    if captured is None:
        return None, Rejection.INVALID, "capturedAt 必须为 ISO 8601 时间"
    if captured > now + timedelta(seconds=FUTURE_SKEW):
        return None, Rejection.INVALID, "capturedAt 晚于当前时间"
    plan = _normalized_plan(root.get("plan"))
    if plan is None:
        return None, Rejection.INVALID, "plan 为空或含控制字符"
    if used_token is None or not _is_json_number(used_token):
        return None, Rejection.INVALID, "weeklyPercentUsed 必须为 0 到 100 的数字"
    used = _finite_number(root.get("weeklyPercentUsed"))
    if used is None or not 0 <= used <= 100:
        return None, Rejection.INVALID, "weeklyPercentUsed 必须为 0 到 100 的数字"
    if root.get("resetsAt") is None:
        resets_at = None
    elif isinstance(root.get("resetsAt"), str):
        resets_at = parse_instant(root["resetsAt"])
        if resets_at is None:
            return None, Rejection.INVALID, "resetsAt 必须为 ISO 8601 时间或 null"
    else:
        return None, Rejection.INVALID, "resetsAt 必须为 ISO 8601 时间或 null"
    shared = root.get("sharedWithOtherApps")
    if type(shared) is not bool:
        return None, Rejection.INVALID, "sharedWithOtherApps 必须为布尔值"
    snapshot = Snapshot(plan, used, resets_at, captured, shared)
    captured_text = format_timestamp(captured, zone)
    reading = Reading(
        snapshot=snapshot,
        freshness=freshness_of(snapshot, now),
        line=display_line(snapshot, zone),
        remaining_line=remaining_display_line(snapshot, zone),
        captured_text=captured_text,
    )
    return reading, None, ""


def manual_reading_dict(reading: Reading) -> dict:
    snap = reading.snapshot
    return {
        "weeklyPercentUsed": snap.weekly_percent_used,
        "capturedAt": _iso(snap.captured_at),
        "resetsAt": _iso(snap.resets_at) if snap.resets_at else None,
        "sharedWithOtherApps": snap.shared_with_other_apps,
        "plan": snap.plan,
        "source": "legacySnapshot",
    }


def reading_from_manual(raw: dict, now: datetime, zone: ZoneInfo) -> Reading | None:
    if not isinstance(raw, dict):
        return None
    used = _finite_number(raw.get("weeklyPercentUsed"))
    captured = parse_instant(raw.get("capturedAt")) if isinstance(raw.get("capturedAt"), str) else None
    if used is None or captured is None or not 0 <= used <= 100:
        return None
    resets_raw = raw.get("resetsAt")
    resets_at = parse_instant(resets_raw) if isinstance(resets_raw, str) else None
    shared = raw.get("sharedWithOtherApps")
    if type(shared) is not bool:
        shared = False
    plan = raw.get("plan") if isinstance(raw.get("plan"), str) else ""
    snapshot = Snapshot(plan or "", used, resets_at, captured, shared)
    return Reading(
        snapshot=snapshot,
        freshness=freshness_of(snapshot, now),
        line=display_line(snapshot, zone),
        remaining_line=remaining_display_line(snapshot, zone),
        captured_text=format_timestamp(captured, zone),
    )


def status_line(raw: dict, now: datetime, zone: ZoneInfo) -> str:
    made = reading_from_manual(raw, now, zone)
    if made is None:
        return ""
    if raw.get("source") == "avatarMenu":
        remaining = percent_text(remaining_percent(made.snapshot.weekly_percent_used))
        used = percent_text(made.snapshot.weekly_percent_used)
        captured = format_timestamp(made.snapshot.captured_at, zone)
        plan = raw.get("plan") if isinstance(raw.get("plan"), str) and raw.get("plan") else "未显示"
        return f"Grok Bot 头像栏目（采集于 {captured}） · 额度剩余 {remaining}%（已用 {used}%） · 套餐 {plan}"
    return presentation(made)


@dataclass
class RingFace:
    shows_dash: bool
    remaining_percent: float | None
    fill: float
    stale: bool
    label: str
    help: str
    used_percent: float | None = None

    def as_dict(self) -> dict:
        return {
            "showsDash": self.shows_dash,
            "remainingPercent": self.remaining_percent,
            "usedPercent": self.used_percent,
            "fill": self.fill,
            "stale": self.stale,
            "label": self.label,
            "help": self.help,
            "dim": self.stale,
        }


def dedicated_ring_face(is_grok_bot_route: bool, reading: dict | None, now: datetime, zone: ZoneInfo) -> RingFace | None:
    if not is_grok_bot_route:
        return None
    if not reading:
        return RingFace(True, None, 0, False, "—", "尚未读取 Grok Bot 本机额度")
    made = reading_from_manual(reading, now, zone)
    if made is None:
        return RingFace(True, None, 0, False, "—", "尚未读取 Grok Bot 本机额度")
    stale = made.freshness is not Freshness.CURRENT
    remaining = remaining_percent(made.snapshot.weekly_percent_used)
    remaining_text = percent_text(remaining)
    used_text = percent_text(made.snapshot.weekly_percent_used)
    source = "本机头像栏目读数" if reading.get("source") == "avatarMenu" else "快照"
    prefix = f"{source}已过期，" if stale else ""
    help_text = f"{prefix}剩余 {remaining_text}%，由已用 {used_text}% 换算。采集于 {made.captured_text}。不是实时读数。"
    return RingFace(
        False,
        remaining,
        min(1.0, max(0.0, remaining / 100)),
        stale,
        remaining_text + "%",
        help_text,
        made.snapshot.weekly_percent_used,
    )


def is_grok_bot_route(account: dict) -> bool:
    return account.get("provider") == "grok" and account.get("kind") == "Agent" and account.get("connection") == "本机软件自动读取"


def is_grokbot_filename(path: str | Path) -> bool:
    return Path(path).name.lower() == FILE_NAME


class FileProvider:
    """只读一份 JSON。不创建目录、不写字节、不监听路径。"""

    def __init__(
        self,
        file_path: Path,
        root: Path | None = None,
        maximum_bytes: int = MAXIMUM_BYTES,
        zone: ZoneInfo | None = None,
        after_open: Callable[[], None] | None = None,
        read: Callable[[Path], bytes] | None = None,
    ):
        self.file_path = Path(file_path)
        self.root = Path(root) if root is not None else self.file_path.parent
        self.maximum_bytes = maximum_bytes
        self.zone = zone or ZoneInfo("Asia/Shanghai")
        self.after_open = after_open
        self.read = read

    def load(self, now: datetime) -> tuple[Reading | None, Rejection | None, str]:
        located, rejection, detail = _locate(self.file_path, self.root)
        if rejection is not None:
            return None, rejection, detail
        assert located is not None
        if self.read is not None:
            try:
                data = self.read(Path(located))
            except Exception:
                return None, Rejection.UNREADABLE, ""
        else:
            data, rejection, detail = _read_stable(located, self.maximum_bytes, self.after_open)
            if rejection is not None:
                return None, rejection, detail
            assert data is not None
        if len(data) > self.maximum_bytes:
            return None, Rejection.TOO_LARGE, ""
        return ingest(data, now, self.zone)


def _iso(moment: datetime) -> str:
    return moment.astimezone(timezone.utc).replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ")


def _finite_number(value: object) -> float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    number = float(value)
    if not math.isfinite(number):
        return None
    return number


def _is_json_number(token: str) -> bool:
    return _NUMBER.fullmatch(token) is not None


def _normalized_plan(value: object) -> str | None:
    if not isinstance(value, str):
        return None
    plan = value.strip()
    if not plan or len(plan) > MAXIMUM_PLAN_LENGTH:
        return None
    for character in plan:
        category = __import__("unicodedata").category(character)
        if category in {"Cc", "Cf"}:
            return None
    return plan


def _scan_top_level(text: str) -> tuple[dict[str, str], str]:
    chars = list(text)
    index = 0
    depth = 0
    tokens: dict[str, str] = {}
    length = len(chars)
    while index < length:
        character = chars[index]
        if character == '"':
            literal, index = _read_json_string(chars, index)
            if depth == 1:
                while index < length and chars[index].isspace():
                    index += 1
                if index >= length or chars[index] != ":":
                    return {}, "不是 JSON 对象"
                index += 1
                while index < length and chars[index].isspace():
                    index += 1
                if index >= length:
                    return {}, "不是 JSON 对象"
                start = index
                while index < length:
                    nxt = chars[index]
                    if nxt == '"' and start == index:
                        _, index = _read_json_string(chars, index)
                        break
                    if nxt in ",}]" or nxt.isspace():
                        break
                    index += 1
                if literal in tokens:
                    return {}, "字段重复"
                tokens[literal] = "".join(chars[start:index])
            continue
        if character in "{[":
            depth += 1
        elif character in "}]":
            depth -= 1
        index += 1
    return tokens, ""


def _read_json_string(chars: list[str], index: int) -> tuple[str, int]:
    value: list[str] = []
    index += 1
    escape = False
    while index < len(chars):
        character = chars[index]
        if escape:
            value.append(character)
            escape = False
        elif character == "\\":
            escape = True
        elif character == '"':
            return "".join(value), index + 1
        else:
            value.append(character)
        index += 1
    return "".join(value), index


def _locate(file_path: Path, root: Path) -> tuple[str | None, Rejection | None, str]:
    path = os.fspath(file_path)
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        return None, Rejection.MISSING, ""
    except OSError:
        return None, Rejection.UNREADABLE, ""
    if stat.S_ISLNK(info.st_mode):
        try:
            resolved = os.path.realpath(path)
        except OSError:
            return None, Rejection.UNREADABLE, ""
        if not _path_is_inside(resolved, root):
            return None, Rejection.INVALID, "符号链接指向数据目录之外"
        candidate = resolved
    else:
        if not _path_is_inside(path, root):
            return None, Rejection.INVALID, "符号链接指向数据目录之外"
        candidate = path
    try:
        final = os.lstat(candidate)
    except OSError:
        return None, Rejection.UNREADABLE, ""
    if stat.S_ISDIR(final.st_mode):
        return None, Rejection.INVALID, "路径是目录"
    if not stat.S_ISREG(final.st_mode):
        return None, Rejection.UNREADABLE, ""
    return candidate, None, ""


def _path_is_inside(path: str, root: Path) -> bool:
    root_real = os.path.realpath(root)
    file_real = os.path.realpath(path)
    prefix = root_real if root_real.endswith(os.sep) else root_real + os.sep
    return file_real != root_real and file_real.startswith(prefix)


def _read_stable(path: str, maximum_bytes: int, after_open: Callable[[], None] | None) -> tuple[bytes | None, Rejection | None, str]:
    flags = os.O_RDONLY
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    try:
        fd = os.open(path, flags)
    except PermissionError:
        return None, Rejection.UNREADABLE, ""
    except OSError:
        return None, Rejection.UNREADABLE, ""
    try:
        before = os.fstat(fd)
        if before.st_size < 0 or before.st_size > maximum_bytes:
            return None, Rejection.TOO_LARGE, ""
        if before.st_size == 0:
            return None, Rejection.INVALID, "文件为空"
        if after_open is not None:
            after_open()
        chunks = []
        remaining = before.st_size
        while remaining:
            piece = os.read(fd, remaining)
            if not piece:
                return None, Rejection.UNREADABLE, ""
            chunks.append(piece)
            remaining -= len(piece)
        data = b"".join(chunks)
        if len(data) != before.st_size:
            return None, Rejection.UNREADABLE, ""
        after = os.fstat(fd)
        if after.st_dev != before.st_dev or after.st_ino != before.st_ino or after.st_size != before.st_size:
            return None, Rejection.UNREADABLE, ""
        return data, None, ""
    finally:
        os.close(fd)
