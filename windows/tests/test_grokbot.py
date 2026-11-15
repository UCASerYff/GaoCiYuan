"""Grok Bot 快照约定：缺失不是 0%，过期变淡，自动刷新不读文件。"""

from __future__ import annotations

import json
import os
import stat
from datetime import datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

import pytest

from gaociyuan.grokbot import (
    FILE_NAME,
    STALE_AFTER,
    FUTURE_SKEW,
    MAXIMUM_BYTES,
    MAXIMUM_PLAN_LENGTH,
    FileProvider,
    Freshness,
    Rejection,
    connector_status,
    dedicated_ring_face,
    ingest,
    manual_button_title,
    presentation,
)
from gaociyuan.timeutil import mac_contract_path

ZONE = ZoneInfo("Asia/Shanghai")
PARSER = "%Y-%m-%dT%H:%M:%SZ"


def at(text: str) -> datetime:
    return datetime.strptime(text, PARSER).replace(tzinfo=timezone.utc)


NOW = at("2026-11-07T02:00:00Z")
CONTRACT = (
    '{"schema":1,"source":"grok-bot-usage-report","capturedAt":"2026-11-07T01:12:00Z",'
    '"plan":"Premium","weeklyPercentUsed":19.3,"resetsAt":"2026-11-09T01:00:00Z","sharedWithOtherApps":true}'
)


def payload(updates=None, nulls=(), drop=()):
    object_ = {
        "schema": 1,
        "source": "grok-bot-usage-report",
        "capturedAt": "2026-11-07T01:12:00Z",
        "plan": "Premium",
        "weeklyPercentUsed": 19.3,
        "resetsAt": "2026-11-09T01:00:00Z",
        "sharedWithOtherApps": True,
    }
    for key in drop:
        object_.pop(key)
    object_.update(updates or {})
    for key in nulls:
        object_[key] = None
    return json.dumps(object_, ensure_ascii=False).encode("utf-8")


def rejected(data: bytes, reason: str):
    reading, rejection, detail = ingest(data, NOW, ZONE)
    assert reading is None
    assert rejection is Rejection.INVALID
    assert detail == reason


def test_contract_display_and_remaining_ring():
    reading, rejection, _ = ingest(CONTRACT.encode(), NOW, ZONE)
    assert rejection is None and reading is not None
    assert reading.freshness is Freshness.CURRENT
    assert reading.snapshot.weekly_percent_used == 19.3
    assert reading.snapshot.shared_with_other_apps is True
    expected = "本周已用 19.3%（与套餐内其他应用共享） · 重置 周一 11月9日 09:00 · 数据 周六 11月7日 09:12"
    assert reading.line == expected
    shown = presentation(reading)
    assert shown == f"读取最近一次快照（采集于 周六 11月7日 09:12） · {reading.remaining_line}"
    assert "剩余" in shown and "已用" in shown and "Premium" not in shown and "0%" not in shown
    assert manual_button_title(False) == "读取本机额度"
    assert manual_button_title(True) == "正在读取本机额度…"
    offset = CONTRACT.replace("2026-11-07T01:12:00Z", "2026-11-07T09:12:00+08:00")
    shifted, _, _ = ingest(offset.encode(), NOW, ZONE)
    assert shifted.line == expected


def test_percent_edges_and_null_reset():
    whole, _, _ = ingest(payload({"weeklyPercentUsed": 19, "sharedWithOtherApps": False}), NOW, ZONE)
    assert whole.line.startswith("本周已用 19% · 重置 ")
    assert "共享" not in whole.line
    precise, _, _ = ingest(payload({"weeklyPercentUsed": 19.25}), NOW, ZONE)
    assert precise.line.startswith("本周已用 19.25%")
    full, _, _ = ingest(payload({"weeklyPercentUsed": 100}), NOW, ZONE)
    assert full.line.startswith("本周已用 100%")
    zero, _, _ = ingest(payload({"weeklyPercentUsed": 0}), NOW, ZONE)
    assert zero.line.startswith("本周已用 0%")
    open_reset, _, _ = ingest(payload(nulls=["resetsAt"]), NOW, ZONE)
    assert open_reset.freshness is Freshness.CURRENT
    assert "平台未提供重置时间" in open_reset.line
    trimmed, _, _ = ingest(payload({"plan": "  Premium  "}), NOW, ZONE)
    assert trimmed.snapshot.plan == "Premium"
    named, _, _ = ingest(payload({"plan": 'see "schema": 1.0'}), NOW, ZONE)
    assert named.snapshot.plan == 'see "schema": 1.0'


def test_staleness_boundaries():
    exactly = NOW - timedelta(seconds=STALE_AFTER)
    boundary, _, _ = ingest(payload({"capturedAt": exactly.strftime(PARSER)}), NOW, ZONE)
    assert boundary.freshness is Freshness.CURRENT
    older_at = exactly - timedelta(seconds=1)
    older, _, _ = ingest(payload({"capturedAt": older_at.strftime(PARSER)}), NOW, ZONE)
    assert older.freshness is Freshness.OLDER_THAN_LIMIT
    text = presentation(older)
    assert text.startswith(f"读取最近一次快照（采集于 {older.captured_text}） · 已超过 6 小时，不作为当前读数 · 记录：本周已用 19.3%")
    assert "实时" not in text
    elapsed, _, _ = ingest(payload({"capturedAt": NOW.strftime(PARSER), "resetsAt": NOW.strftime(PARSER)}), NOW, ZONE)
    assert elapsed.freshness is Freshness.RESET_ELAPSED
    status = connector_status(elapsed, None, True, True)
    assert "重置时间已过，不作为本周读数" in status
    both, _, _ = ingest(payload({"capturedAt": older_at.strftime(PARSER), "resetsAt": older_at.strftime(PARSER)}), NOW, ZONE)
    assert both.freshness is Freshness.RESET_ELAPSED
    ahead = NOW + timedelta(seconds=FUTURE_SKEW)
    skewed, _, _ = ingest(payload({"capturedAt": ahead.strftime(PARSER), "resetsAt": (NOW + timedelta(hours=1)).strftime(PARSER)}), NOW, ZONE)
    assert skewed.freshness is Freshness.CURRENT
    rejected(payload({"capturedAt": (ahead + timedelta(seconds=1)).strftime(PARSER)}), "capturedAt 晚于当前时间")


def test_rejections_do_not_invent_percent():
    rejected(b"", "文件为空")
    rejected(b"[]", "不是 JSON 对象")
    rejected(b'"grok-bot-usage-report"', "不是 JSON 对象")
    rejected((CONTRACT + " {}").encode(), "不是 JSON 对象")
    rejected(payload(drop=["resetsAt"]), "缺少约定字段")
    rejected(payload({"onDemandCents": 0}), "含有未约定的字段")
    rejected(payload({"source": "Grok 账号官方接口"}), "source 必须为 grok-bot-usage-report")
    rejected(payload({"schema": 2}), "schema 必须为整数 1")
    rejected(payload({"schema": True}), "schema 必须为整数 1")
    rejected(CONTRACT.replace('"schema":1', '"schema":1.0').encode(), "schema 必须为整数 1")
    rejected(CONTRACT.replace('"schema":1', '"schema":1e0').encode(), "schema 必须为整数 1")
    rejected(payload({"weeklyPercentUsed": True}), "weeklyPercentUsed 必须为 0 到 100 的数字")
    rejected(payload({"weeklyPercentUsed": "19.3"}), "weeklyPercentUsed 必须为 0 到 100 的数字")
    rejected(payload({"weeklyPercentUsed": 100.1}), "weeklyPercentUsed 必须为 0 到 100 的数字")
    rejected(payload({"weeklyPercentUsed": -0.1}), "weeklyPercentUsed 必须为 0 到 100 的数字")
    rejected(CONTRACT.replace("19.3", "NaN").encode(), "weeklyPercentUsed 必须为 0 到 100 的数字")
    rejected(CONTRACT.replace("19.3", "Infinity").encode(), "weeklyPercentUsed 必须为 0 到 100 的数字")
    rejected(CONTRACT.replace('"schema":1', '"schema":1,"schema":1').encode(), "字段重复")
    rejected(bytes([0xFF, 0xFE, 0xFD]), "不是 UTF-8")
    rejected(payload({"resetsAt": ""}), "resetsAt 必须为 ISO 8601 时间或 null")
    rejected(payload({"resetsAt": 1_762_473_600}), "resetsAt 必须为 ISO 8601 时间或 null")
    rejected(payload({"capturedAt": "2026-11-07T09:12:00"}), "capturedAt 必须为 ISO 8601 时间")
    rejected(payload({"plan": " "}), "plan 为空或含控制字符")
    rejected(payload({"plan": "Premium\nPlus"}), "plan 为空或含控制字符")
    rejected(payload({"plan": "A" * (MAXIMUM_PLAN_LENGTH + 1)}), "plan 为空或含控制字符")
    rejected(payload({"sharedWithOtherApps": 1}), "sharedWithOtherApps 必须为布尔值")
    rejected(payload({"sharedWithOtherApps": "true"}), "sharedWithOtherApps 必须为布尔值")
    rejected(json.dumps({"usagePercent": 19.3, "source": "sand"}).encode(), "缺少约定字段")
    missing = connector_status(None, Rejection.MISSING, False, False)
    assert missing == "尚未检测到 Grok Bot。安装或启动后会自动重新检测；等待可读取的用量记录。"
    assert "%" not in missing and "0" not in missing
    invalid = connector_status(None, Rejection.INVALID, True, True)
    assert invalid == "已检测到 Grok Bot（运行中）。用量记录不符合 grokbot-usage.json 约定，未显示百分比。"
    assert "LEAKED" not in invalid


def test_ring_uses_remaining_and_dims_when_stale():
    live_now = at("2026-11-07T04:00:00Z")
    live, _, _ = ingest(
        payload(
            {
                "capturedAt": "2026-11-07T03:31:14Z",
                "resetsAt": "2026-11-13T13:54:00+08:00",
                "weeklyPercentUsed": 84.8,
                "plan": "Premium",
                "sharedWithOtherApps": True,
            }
        ),
        live_now,
        ZONE,
    )
    from gaociyuan.grokbot import manual_reading_dict

    stored = manual_reading_dict(live)
    face = dedicated_ring_face(True, stored, live_now, ZONE)
    assert face.shows_dash is False
    assert face.stale is False
    assert face.label == "15.2%"
    assert abs(face.fill - 0.152) < 0.000_001
    assert "已用 84.8%" in face.help
    full, _, _ = ingest(payload({"weeklyPercentUsed": 100}), live_now, ZONE)
    full_face = dedicated_ring_face(True, manual_reading_dict(full), live_now, ZONE)
    assert full_face.label == "0%" and full_face.fill == 0
    zero, _, _ = ingest(payload({"weeklyPercentUsed": 0}), live_now, ZONE)
    zero_face = dedicated_ring_face(True, manual_reading_dict(zero), live_now, ZONE)
    assert zero_face.label == "100%" and zero_face.fill == 1
    aged = live_now + timedelta(seconds=STALE_AFTER + 1)
    stale = dedicated_ring_face(True, stored, aged, ZONE)
    assert stale.stale is True and stale.label == "15.2%" and "旧" not in stale.label
    assert "快照已过期" in stale.help and "不是实时读数" in stale.help
    reset_face = dedicated_ring_face(True, stored, at("2026-11-13T06:00:00Z"), ZONE)
    assert reset_face.stale is True
    empty = dedicated_ring_face(True, None, live_now, ZONE)
    assert empty.shows_dash and empty.label == "—" and empty.fill == 0 and empty.remaining_percent is None
    assert dedicated_ring_face(False, stored, live_now, ZONE) is None


def test_file_provider_does_not_create_or_follow_escape(tmp_path: Path):
    home = tmp_path / "home"
    url = mac_contract_path(home)
    provider = FileProvider(url, root=url.parent, zone=ZONE)
    reading, rejection, _ = provider.load(NOW)
    assert reading is None and rejection is Rejection.MISSING
    assert not (home / "Library").exists()
    url.parent.mkdir(parents=True)
    url.write_bytes(CONTRACT.encode())
    loaded, rejection, _ = provider.load(NOW)
    assert rejection is None and loaded.snapshot.weekly_percent_used == 19.3
    before = url.read_bytes()
    provider.load(NOW)
    assert url.read_bytes() == before

    outside = tmp_path / "outside.json"
    outside.write_text(CONTRACT.replace("19.3", "77"), encoding="utf-8")
    url.unlink()
    try:
        os.symlink(outside, url)
    except OSError:
        pytest.skip("this platform cannot create symlinks")
    calls = {"n": 0}

    def _read(_path):
        calls["n"] += 1
        return outside.read_bytes()

    escaped = FileProvider(url, root=url.parent, zone=ZONE, read=_read)
    _, rejection, detail = escaped.load(NOW)
    assert rejection is Rejection.INVALID and detail == "符号链接指向数据目录之外"
    assert calls["n"] == 0
    url.unlink()
    inside = url.parent / "real.json"
    inside.write_bytes(CONTRACT.encode())
    os.symlink(inside, url)
    followed, rejection, _ = provider.load(NOW)
    assert rejection is None and followed.snapshot.weekly_percent_used == 19.3


def test_stable_read_discards_torn_file(tmp_path: Path):
    folder = tmp_path / "Token"
    folder.mkdir()
    url = folder / FILE_NAME
    url.write_bytes(CONTRACT.encode())
    replaced = {"ok": False}

    def swap():
        incoming = folder / "incoming.json"
        incoming.write_text(CONTRACT.replace("19.3", "50"), encoding="utf-8")
        try:
            os.replace(incoming, url)
            replaced["ok"] = True
        except OSError:
            # Windows 不允许替换仍被打开的文件。原描述符继续读原来的完整内容。
            incoming.unlink(missing_ok=True)

    renamed = FileProvider(url, root=folder, zone=ZONE, after_open=swap)
    stable, rejection, _ = renamed.load(NOW)
    if stable is not None:
        assert stable.snapshot.weekly_percent_used == 19.3
    else:
        assert replaced["ok"] and rejection is Rejection.UNREADABLE
    url.write_bytes(CONTRACT.encode())
    truncated = {"ok": False}

    def truncate():
        try:
            with url.open("r+b") as handle:
                handle.truncate(0)
            truncated["ok"] = True
        except OSError:
            return

    torn = FileProvider(url, root=folder, zone=ZONE, after_open=truncate)
    torn_reading, rejection, _ = torn.load(NOW)
    if truncated["ok"]:
        assert rejection is Rejection.UNREADABLE
    else:
        assert torn_reading is not None and torn_reading.snapshot.weekly_percent_used == 19.3
    url.write_bytes(b"")
    _, rejection, detail = FileProvider(url, root=folder, zone=ZONE).load(NOW)
    assert rejection is Rejection.INVALID and detail == "文件为空"
    url.write_bytes(b"\x00" * (MAXIMUM_BYTES + 1))
    _, rejection, _ = FileProvider(url, root=folder, zone=ZONE).load(NOW)
    assert rejection is Rejection.TOO_LARGE
    url.unlink()
    url.mkdir()
    _, rejection, detail = FileProvider(url, root=folder, zone=ZONE).load(NOW)
    assert rejection is Rejection.INVALID and detail == "路径是目录"


def test_permission_denied(tmp_path: Path):
    if os.name == "nt" or not hasattr(os, "geteuid") or os.geteuid() == 0:
        pytest.skip("permission bits do not block the current user")
    url = tmp_path / FILE_NAME
    url.write_bytes(CONTRACT.encode())
    os.chmod(url, 0)
    try:
        _, rejection, _ = FileProvider(url, root=tmp_path, zone=ZONE).load(NOW)
        assert rejection is Rejection.UNREADABLE
    finally:
        os.chmod(url, stat.S_IRUSR | stat.S_IWUSR)
