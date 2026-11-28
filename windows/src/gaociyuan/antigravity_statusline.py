"""Receive the independent Antigravity CLI's documented statusLine payload."""

from __future__ import annotations

import hashlib
import json
import os
import re
import tempfile
import time
from contextlib import contextmanager
from datetime import datetime, timedelta
from pathlib import Path
from typing import BinaryIO

from gaociyuan.errors import AppError
from gaociyuan.snapshots import chart_quotas, normalize_snapshot
from gaociyuan.timeutil import format_iso, parse_instant


SOURCE = "Antigravity 独立 CLI 状态栏同步"
EMAIL_FIELD = "antigravityEmail"
WAITING = "等待独立 Antigravity CLI 推送。请核对 CLI 登录邮箱及账户中的状态栏配置。"
EXPIRED = "独立 Antigravity CLI 推送已过期，等待新读数。"
MAX_BYTES = 262_144
MAX_QUOTAS = 64
MAX_AGE = timedelta(minutes=15)
HEARTBEAT = timedelta(minutes=1)
VALID_STATES = ("idle", "working", "tool_use", "reviewing")
EMAIL = re.compile(r"[a-z0-9.!#$%&'*+/=?^_`{|}~-]{1,64}@[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?")
ACCOUNT_KEY = re.compile(r"[a-f0-9]{64}")
BUCKET = re.compile(r"[a-z0-9][a-z0-9._-]{0,79}")
KNOWN_BUCKETS = {
    "gemini-5h": ("Gemini Models · 5 小时", 18_000),
    "gemini-weekly": ("Gemini Models · 每周", 604_800),
    "3p-5h": ("Claude and GPT models · 5 小时", 18_000),
    "3p-weekly": ("Claude and GPT models · 每周", 604_800),
    "gemini-argon-wtu-weekly": ("Gemini 4 Argon · 每周", 604_800),
}


def canonical_email(value: object) -> str | None:
    if not isinstance(value, str):
        return None
    email = value.strip().lower()
    return email if len(email) <= 254 and EMAIL.fullmatch(email) else None


def account_key(email: str) -> str:
    return hashlib.sha256(email.encode("ascii")).hexdigest()


def _cache_path(directory: Path, key: str) -> Path:
    return directory / "antigravity-statusline" / (key + ".json")


def _object(stream: BinaryIO) -> dict | None:
    try:
        encoded = stream.read(MAX_BYTES + 1)
        payload = json.loads(encoded) if len(encoded) <= MAX_BYTES else None
    except (ValueError, UnicodeError, RecursionError):
        return None
    return payload if isinstance(payload, dict) else None


def _reset(value: dict, now: datetime) -> datetime | None:
    absolute = value.get("reset_time")
    if absolute is not None:
        reset = parse_instant(absolute)
    else:
        seconds = value.get("reset_in_seconds")
        if seconds is None:
            return None
        if type(seconds) not in (int, float) or not 0 <= seconds <= 366 * 86_400:
            raise ValueError("Invalid quota reset")
        reset = now + timedelta(seconds=seconds)
    if reset is None or reset > now + timedelta(days=366):
        raise ValueError("Invalid quota reset")
    return reset


def _quotas(windows: dict, now: datetime) -> list[dict]:
    if not windows or len(windows) > MAX_QUOTAS:
        return []
    quotas = []
    for identifier, value in sorted(windows.items()):
        if not BUCKET.fullmatch(identifier) or not isinstance(value, dict) or value.get("disabled", False) is not False:
            continue
        fraction = value.get("remaining_fraction")
        if type(fraction) not in (int, float) or not 0 <= fraction <= 1:
            continue
        try:
            reset = _reset(value, now)
        except (ValueError, OverflowError):
            continue
        if reset is not None and reset <= now:
            continue
        title, duration = KNOWN_BUCKETS.get(identifier, (identifier, None))
        quotas.append({
            "id": identifier,
            "title": title,
            "usedPercent": round((1 - fraction) * 100, 8),
            "resetsAt": format_iso(reset) if reset is not None else None,
            "exhausted": fraction == 0,
            "windowSeconds": duration,
        })
    return quotas


@contextmanager
def _writer_lock(path: Path):
    # Callbacks can overlap across independent CLI terminals for the same user.
    with path.with_suffix(".lock").open("a+b") as lock:
        lock.seek(0)
        try:
            if os.name == "nt":
                import msvcrt

                msvcrt.locking(lock.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl

                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            yield False
        else:
            yield True


def capture_antigravity_statusline(stream: BinaryIO, directory: Path, now: datetime, expected_account: str) -> bool:
    raw = _object(stream)
    if not raw or raw.get("product") != "antigravity" or raw.get("agent_state") not in VALID_STATES:
        return False
    email = canonical_email(raw.get("email"))
    windows = raw.get("quota")
    if email is None or not isinstance(windows, dict):
        return False
    key = account_key(email)
    if key != expected_account:
        return False
    quotas = _quotas(windows, now)
    if not quotas:
        return False
    path = _cache_path(directory, key)
    path.parent.mkdir(parents=True, exist_ok=True)
    with _writer_lock(path) as active:
        if not active:
            return False
        try:
            with path.open("rb") as handle:
                prior = _object(handle)
        except FileNotFoundError:
            prior = None
        if prior and prior.get("account") == key:
            captured_at = parse_instant(prior.get("observedAt"))
            if captured_at and (
                captured_at > now or (now - captured_at < HEARTBEAT and prior.get("quotas") == quotas)
            ):
                return False
        # Keep only account fingerprint, receipt time and quota data. The CLI
        # transcript paths, context, billing amounts and email never enter this cache.
        document = {"account": key, "source": SOURCE, "observedAt": format_iso(now), "quotas": quotas}
        with tempfile.NamedTemporaryFile(dir=path.parent, prefix=".quota-", delete=False) as output:
            temporary = Path(output.name)
            try:
                output.write(json.dumps(document, ensure_ascii=False, allow_nan=False).encode("utf-8"))
                output.close()
                for attempt in range(3):
                    try:
                        os.replace(temporary, path)
                        return True
                    except PermissionError:
                        if attempt == 2:
                            raise
                        time.sleep(.02)
            finally:
                temporary.unlink(missing_ok=True)
    return False


def read_antigravity_statusline(directory: Path, email: str, now: datetime) -> dict:
    key = account_key(email)
    try:
        with _cache_path(directory, key).open("rb") as handle:
            raw = _object(handle)
    except FileNotFoundError:
        raise AppError(WAITING, "missing") from None
    except OSError:
        raise AppError("独立 Antigravity CLI 推送暂不可读，保留上次额度。", "unavailable") from None
    if not raw or raw.get("source") != SOURCE or raw.get("account") != key:
        raise AppError(WAITING, "missing")
    observed = parse_instant(raw.get("observedAt"))
    if observed is None or observed > now or now - observed > MAX_AGE:
        raise AppError(EXPIRED, "missing")
    try:
        snapshot = normalize_snapshot({"source": SOURCE, "observedAt": raw["observedAt"], "quotas": raw["quotas"]}, now)
    except (AppError, KeyError, TypeError, ValueError, OverflowError):
        raise AppError(WAITING, "missing") from None
    if not chart_quotas(snapshot, now):
        raise AppError(EXPIRED, "missing")
    return snapshot
