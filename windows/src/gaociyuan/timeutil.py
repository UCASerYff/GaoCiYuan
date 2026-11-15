"""时间与路径。资料目录对应 Mac 的 Application Support/GaoSeries/Token。"""

from __future__ import annotations

import os
from datetime import datetime, timezone
from pathlib import Path
from zoneinfo import ZoneInfo


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


def parse_instant(text: str) -> datetime | None:
    if not isinstance(text, str) or not text:
        return None
    candidate = text
    if candidate.endswith("Z"):
        candidate = candidate[:-1] + "+00:00"
    try:
        parsed = datetime.fromisoformat(candidate)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        return None
    return parsed.astimezone(timezone.utc)


def format_iso(moment: datetime) -> str:
    if moment.tzinfo is None:
        moment = moment.replace(tzinfo=timezone.utc)
    moment = moment.astimezone(timezone.utc).replace(microsecond=0)
    return moment.strftime("%Y-%m-%dT%H:%M:%SZ")


def format_timestamp(moment: datetime, zone: ZoneInfo) -> str:
    local = moment.astimezone(zone)
    names = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
    weekday = names[local.isoweekday() % 7]
    return f"{weekday} {local.month}月{local.day}日 {local.hour:02d}:{local.minute:02d}"


def default_data_dir() -> Path:
    appdata = os.environ.get("APPDATA")
    if appdata:
        return Path(appdata) / "GaoSeries" / "Token"
    local = os.environ.get("LOCALAPPDATA")
    if local:
        return Path(local) / "GaoSeries" / "Token"
    return Path.home() / ".local" / "share" / "GaoSeries" / "Token"


def grokbot_snapshot_path(data_dir: Path) -> Path:
    """Windows 等价位置：%APPDATA%\\GaoSeries\\Token\\grokbot-usage.json。"""
    return Path(data_dir) / "grokbot-usage.json"


def mac_contract_path(home: Path) -> Path:
    """Mac 版约定路径。Windows 运行时不读这个位置。"""
    return (
        Path(home)
        / "Library"
        / "Application Support"
        / "GaoSeries"
        / "Token"
        / "grokbot-usage.json"
    )
