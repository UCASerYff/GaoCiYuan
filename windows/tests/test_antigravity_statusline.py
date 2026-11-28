from __future__ import annotations

import io
import json
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

from gaociyuan.antigravity_report import REPORT_FIELD
from gaociyuan.antigravity_statusline import (
    EXPIRED, SOURCE, WAITING, account_key, capture_antigravity_statusline, read_antigravity_statusline,
)
from gaociyuan.errors import AppError
from gaociyuan.store import TokenStore


NOW = datetime(2026, 11, 28, 3, 15, tzinfo=timezone.utc)
EMAIL_A = "first@example.invalid"
EMAIL_B = "second@example.invalid"


def payload(email=EMAIL_A, **overrides):
    return {
        "product": "antigravity", "email": email, "agent_state": "idle",
        "cwd": r"Q:\PRIVATE_FIXTURE", "conversation_title": "PRIVATE_FIXTURE", "plan_tier": "Pro",
        "quota": {
            "gemini-weekly": {"remaining_fraction": 0.9378, "reset_time": "2026-12-03T11:01:23+08:00"},
            "gemini-5h": {"remaining_fraction": 0, "reset_in_seconds": 240},
            "3p-weekly": {"remaining_fraction": 0.9, "disabled": True},
            "gemini-new-model": {"remaining_fraction": 0.875},
            "expired-5h": {"remaining_fraction": 1, "reset_time": "2026-11-20T01:00:00Z"},
            "amount-only": {"remaining_amount": 500},
        },
        **overrides,
    }


def capture(tmp_path, now=NOW, *, expected_email=EMAIL_A, **changes):
    raw = json.dumps(payload(**changes)).encode("utf-8")
    return capture_antigravity_statusline(io.BytesIO(raw), tmp_path, now, account_key(expected_email))


def test_statusline_keeps_only_explicit_quota_and_expires(tmp_path):
    assert capture(tmp_path, email=EMAIL_A.upper())
    path, = (tmp_path / "antigravity-statusline").glob("*.json")
    cached = path.read_text("utf-8")
    assert not any(word in cached for word in (EMAIL_A, "PRIVATE_FIXTURE", "Pro", "remaining_amount"))
    assert path.stem == json.loads(cached)["account"]
    snapshot = read_antigravity_statusline(tmp_path, EMAIL_A, NOW)
    rows = {q["id"]: q for q in snapshot["quotas"]}
    assert set(rows) == {"gemini-weekly", "gemini-5h", "gemini-new-model"}
    assert rows["gemini-weekly"]["usedPercent"] == 6.22
    assert rows["gemini-weekly"]["resetsAt"] == "2026-12-03T03:01:23Z"
    assert rows["gemini-5h"]["exhausted"] and rows["gemini-5h"]["resetsAt"] == "2026-11-28T03:19:00Z"
    assert rows["gemini-new-model"]["windowSeconds"] is None
    assert (snapshot["source"], snapshot["observedAt"]) == (SOURCE, "2026-11-28T03:15:00Z")
    with pytest.raises(AppError, match="等待"):
        read_antigravity_statusline(tmp_path, EMAIL_B, NOW)
    with pytest.raises(AppError, match="过期"):
        read_antigravity_statusline(tmp_path, EMAIL_A, NOW + timedelta(minutes=15, seconds=1))
    with pytest.raises(AppError, match="过期"):
        read_antigravity_statusline(tmp_path, EMAIL_A, NOW - timedelta(seconds=1))


def test_unchanged_data_is_throttled_and_old_callbacks_do_not_overwrite(tmp_path):
    absolute_only = {"gemini-weekly": payload()["quota"]["gemini-weekly"]}
    assert capture(tmp_path, quota=absolute_only)
    assert not capture(tmp_path, NOW + timedelta(seconds=10), quota=absolute_only)
    assert capture(tmp_path, NOW + timedelta(minutes=1), quota=absolute_only)
    older_callback = {"gemini-weekly": {"remaining_fraction": 0.25}}
    assert not capture(tmp_path, NOW + timedelta(seconds=45), quota=older_callback)
    latest = read_antigravity_statusline(tmp_path, EMAIL_A, NOW + timedelta(minutes=1))
    assert latest["observedAt"] == "2026-11-28T03:16:00Z"
    assert latest["quotas"][0]["usedPercent"] == 6.22


def test_callback_for_unconfigured_login_never_creates_a_cache(tmp_path):
    assert not capture(tmp_path, email=EMAIL_B)
    assert not (tmp_path / "antigravity-statusline").exists()


@pytest.mark.parametrize("invalid", [
    {"product": "gemini"}, {"email": "not an email"}, {"email": None},
    {"agent_state": "initializing"}, {"agent_state": "authenticating"}, {"agent_state": "error"}, {"agent_state": []},
    {"quota": {"ratio": {"remaining_fraction": True}}},
    {"quota": {"ratio": {"remaining_fraction": -0.1}}},
    {"quota": {"ratio": {"remaining_fraction": float("inf")}}},
    {"quota": {"ratio": {"remaining_fraction": 0.25, "reset_time": "invalid"}}},
    {"quota": {"ratio": {"remaining_fraction": 0.25, "reset_in_seconds": 0}}},
    {"quota": {"ratio": {"remaining_fraction": 0.25, "reset_in_seconds": 999_999_999}}},
])
def test_invalid_callback_does_not_change_the_cache(tmp_path, invalid):
    assert capture(tmp_path)
    path, = (tmp_path / "antigravity-statusline").glob("*.json")
    before = path.read_bytes()
    assert not capture(tmp_path, NOW + timedelta(minutes=2), **invalid)
    assert path.read_bytes() == before


def test_automatic_refresh_is_account_bound_and_keeps_legacy_report(tmp_path):
    clock = [NOW]
    store = TokenStore(tmp_path, now=lambda: clock[0])
    account_a = store.save_account({"provider": "gemini", "name": "First"})
    history = store.import_antigravity_report({"id": account_a["id"], "confirmed": True,
        "report": "Gemini Models\nWeekly Limit Remaining: 30%"})["report"]
    account_a = store.save_account({"id": account_a["id"], "provider": "gemini", "antigravityEmail": " First@Example.invalid "})
    account_b = store.save_account({"provider": "gemini", "name": "Second", "antigravityEmail": EMAIL_B})
    report_only = store.save_account({"provider": "gemini", "name": "Historical"})
    assert account_a["antigravityEmail"] == EMAIL_A
    assert store.view_account(account_a)[REPORT_FIELD] == history
    assert not store.view_account(account_a)["hasCredential"]
    with pytest.raises(AppError, match="另建"):
        store.save_account({"id": account_a["id"], "provider": "gemini", "antigravityEmail": EMAIL_B})
    with pytest.raises(AppError, match="已绑定其他账户"):
        store.save_account({"provider": "gemini", "antigravityEmail": EMAIL_A})

    store.connector_reader = lambda *_args, **_kwargs: pytest.fail("Push sync invoked a process/network connector")
    assert capture(tmp_path, expected_email=EMAIL_B, email=EMAIL_B, quota={"3p-weekly": {"remaining_fraction": .75}})
    assert store.refresh_due() == [account_a["id"], account_b["id"]]
    assert account_a["statusNote"] == WAITING and account_a["snapshot"] is None
    assert account_b["snapshot"]["quotas"][0]["usedPercent"] == 25

    assert capture(tmp_path)
    store.refresh_due()
    assert account_a["snapshot"]["source"] == SOURCE and not account_a["statusNote"]
    assert store.view_account(account_a)[REPORT_FIELD] == history
    assert report_only["snapshot"] is None
    after = store.library_path.read_bytes()
    store.refresh_due()
    assert store.library_path.read_bytes() == after

    store.library["autoRefresh"] = False
    clock[0] += timedelta(minutes=16)
    assert not store.refresh_due()
    store.refresh(account_a["id"], user_initiated=True)
    assert account_a["statusNote"] == EXPIRED and store.view_account(account_a)["stale"]
    reloaded = TokenStore(tmp_path, now=lambda: clock[0])
    assert reloaded.view_account(reloaded._find(account_a["id"]))[REPORT_FIELD] == history


def test_console_receives_statusline_without_opening_application(tmp_path):
    launch = Path(__file__).resolve().parents[1] / "launch_cli.py"
    result = subprocess.run([
        sys.executable, str(launch), "--data-dir", str(tmp_path), "--capture-antigravity-status",
        "--antigravity-account", account_key(EMAIL_A),
    ], input=json.dumps(payload(quota={"gemini-weekly": {"remaining_fraction": 0.625}})).encode(),
        capture_output=True, timeout=15, check=False)
    assert result.returncode == 0 and not result.stdout and not result.stderr
    assert not (tmp_path / "library.json").exists()
    from gaociyuan.timeutil import utcnow

    snapshot = read_antigravity_statusline(tmp_path, EMAIL_A, utcnow())
    assert snapshot["quotas"][0]["usedPercent"] == 37.5
