from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen

import pytest

from gaociyuan.antigravity_report import JSON_REPORT_SOURCE, MAX_BYTES, REPORT_FIELD, REPORT_SOURCE, parse_report
from gaociyuan.catalog import AGENT_LOCAL, ANTIGRAVITY_REPORT, FILE, GEMINI_APP
from gaociyuan.credentials import MemoryCredentialStore
from gaociyuan.errors import AppError
from gaociyuan.store import TokenStore, empty_library
from gaociyuan.web import serve

NOW = datetime(2026, 11, 28, tzinfo=timezone.utc)
CLI_FIXTURE = Path(__file__).resolve().parents[2] / "Tests" / "Fixtures" / "AntigravityCLIUsage.json"
REPORT = """Models & Quota
CapturedAt: 2099-01-01T12:00:00Z
Fixture account: fixture@example.invalid
╭────────────────────────────────────────────────╮
│ \x1b[36mGemini Models\x1b[0m │
│ Five Hour Limit Remaining: 75.5% │
│ Weekly Limit Remaining │
│ ▒▒▒ 60% │
│ Claude and GPT models: │
│ Five Hour Limit Remaining │ 75.5% │
│ Weekly Limit Remaining: 0% │
╰────────────────────────────────────────────────╯
"""


def test_explicit_pools_and_windows_only():
    source, quotas = parse_report("\ufeff" + REPORT.replace("\n", "\r\n"))
    assert source == REPORT_SOURCE
    assert [item["usedPercent"] for item in quotas] == [24.5, 40, 24.5, 100]
    assert [item["windowSeconds"] for item in quotas] == [18_000, 604_800, 18_000, 604_800]
    assert len({item["id"] for item in quotas}) == 4
    assert all(item["resetsAt"] is None and not item["exhausted"] for item in quotas)
    _, partial = parse_report("Gemini Models\nWeekly Limit Remaining: 10%\nUnrelated models\nFive Hour Limit Remaining: 90%")
    assert [item["usedPercent"] for item in partial] == [90]
    for unavailable in ("N/A", "unknown", "Unavailable", "—"):
        _, partial = parse_report(f"Gemini Models\nFive Hour Limit Remaining: 22%\nWeekly Limit Remaining: {unavailable}")
        assert [item["usedPercent"] for item in partial] == [78]


@pytest.mark.parametrize("bad", [
    pytest.param("Gemini Flash\nFive Hour Limit Remaining: 10%", id="individual-model"),
    pytest.param("Gemini Models\nFive Hour Limit Used: 10%", id="used-not-remaining"),
    pytest.param("Gemini Models\nWeekly Limit Remaining:\nClaude and GPT models", id="missing-value"),
    pytest.param("Gemini Models\nWeekly Limit Remaining: 160%", id="outside-range"),
    pytest.param("Gemini Models\nWeekly Limit Remaining: 90% remaining or 10% used", id="ambiguous-value"),
    pytest.param("Gemini Models\nWeekly Limit Remaining: 50%\nWeekly Limit Remaining: 40%", id="duplicate-window"),
    pytest.param("Gemini Models\nWeekly Limit Remaining: N/A\nWeekly Limit Remaining: 40%", id="duplicate-unavailable-window"),
    pytest.param("Gemini Models\nWeekly Limit Remaining: N/A", id="all-unavailable"),
    pytest.param(REPORT + "中" * (MAX_BYTES // 2), id="over-byte-limit"),
    pytest.param(REPORT + "\ud800", id="invalid-utf8"),
])
def test_malformed_or_ambiguous_transcript_is_rejected(bad):
    with pytest.raises(AppError):
        parse_report(bad)


def test_historical_import_is_account_scoped_non_live_persistent_and_replay_safe(tmp_path):
    clock = [NOW]
    vault = MemoryCredentialStore()
    store = TokenStore(tmp_path, credentials=vault, now=lambda: clock[0])
    account = store.save_account({"provider": "gemini", "name": "Fixture A"})
    other = store.save_account({"provider": "claude", "name": "Fixture B", "connection": FILE})
    assert account["connection"] == ANTIGRAVITY_REPORT
    verified = {"observedAt": "2026-11-28T00:00:00Z", "source": "Fixture verified source", "quotas": [{
        "id": "five", "title": "5 hours", "usedPercent": 5, "windowSeconds": 18_000,
        "resetsAt": "2026-11-28T05:00:00Z", "exhausted": False,
    }], "balances": [], "costs": []}
    account.update(snapshot=verified, history=[verified], lastAttempt=verified["observedAt"])
    store._write_library()
    store.notify = lambda *_: pytest.fail("Unverified report triggered an alert")
    store.connector_reader = lambda *_, **kwargs: pytest.fail("Manual import tried to call a connector")
    payload = {"id": account["id"], "confirmed": True, "report": REPORT, "observedAt": "2026-11-28T00:00:00Z"}
    with pytest.raises(AppError, match="确认"):
        store.import_antigravity_report({**payload, "confirmed": "true"})
    with pytest.raises(AppError, match="账户"):
        store.import_antigravity_report({**payload, "id": other["id"]})
    with pytest.raises(AppError, match="凭据"):
        store.set_credential(account["id"], "fixture")

    before = store.view_account(account)
    imported = store.import_antigravity_report(payload)
    assert imported["duplicate"] is False
    assert imported["report"] == {"source": REPORT_SOURCE, "importedAt": verified["observedAt"], "observedAt": None,
                                  "verified": False, "quotas": parse_report(REPORT)[1]}
    view = store.view_account(store._find(account["id"]))
    for key in ("snapshot", "history", "lastAttempt", "ring", "quotaForecast", "warnings", "health"):
        assert before[key] == view[key]
    assert view[REPORT_FIELD] == imported["report"]
    assert not store.alerts_path.exists()
    assert not store._actions
    store.refresh(account["id"], user_initiated=True)
    assert not store._actions
    with pytest.raises(AppError, match="手动导入"):
        store.test_account(account)

    clock[0] += timedelta(days=2)
    newer_import = store.import_antigravity_report({**payload, "report": REPORT.replace("75.5%", "88%")})
    assert newer_import["report"]["importedAt"] == "2026-11-30T00:00:00Z"
    reloaded = TokenStore(tmp_path, credentials=vault, now=lambda: clock[0])
    clock[0] += timedelta(days=2)
    historical_return = reloaded.import_antigravity_report({**payload, "report": REPORT.replace("60%", "60.000%")})
    assert historical_return["duplicate"] is False
    assert historical_return["report"] == {**imported["report"], "importedAt": "2026-12-02T00:00:00Z"}
    assert reloaded._find(account["id"])["snapshot"] == verified
    reloaded.save_account({"id": account["id"], "provider": "gemini", "name": "Renamed", "enabled": False})
    assert reloaded.view_account(reloaded._find(account["id"]))[REPORT_FIELD] == historical_return["report"]
    clock[0] += timedelta(days=2)
    assert reloaded.import_antigravity_report(payload) == {"report": historical_return["report"], "duplicate": True}
    encoded = reloaded.library_path.read_text(encoding="utf-8")
    assert "2099" not in encoded and "fixture@example.invalid" not in encoded
    assert not vault.has(account["id"])


def test_official_json_retains_reported_windows_and_distinct_argon(tmp_path):
    document = CLI_FIXTURE.read_text(encoding="utf-8")
    payload = json.loads(document)
    groups = payload["command"]["data"]["groups"]
    payload.update(account="fixture@example.invalid", observedAt="2099-01-01T00:00:00Z", verified=True)
    groups.append({"name": "Another Model Group", "buckets": [
        {"id": "other-5h", "window": "5h", "remaining_fraction": 0.875, "reset_time": "2026-10-22T11:20:00"},
        {"id": "future-shape", "window": "monthly", "remaining_fraction": 1},
        {"id": "no-reading", "window": "weekly", "remaining_fraction": None},
        {"id": "also-unreported", "window": "5h"},
    ]})
    groups[0]["buckets"].append({"id": "../unsafe", "window": "weekly", "remaining_fraction": 1})
    store = TokenStore(tmp_path, now=lambda: NOW)
    account = store.save_account({"provider": "gemini"})
    store.notify = lambda *_: pytest.fail("Historical JSON triggered an alert")
    imported = store.import_antigravity_report({"id": account["id"], "confirmed": True, "report": "\ufeff" + json.dumps(payload)})
    report = imported["report"]
    assert report["source"] == JSON_REPORT_SOURCE and report["observedAt"] is None and not report["verified"]
    rows = {quota["id"]: quota for quota in report["quotas"]}
    assert set(rows) == {"gemini-5h", "gemini-weekly", "3p-weekly", "gemini-argon-wtu-weekly", "other-5h"}
    assert rows["gemini-5h"]["usedPercent"] == 37.5 and rows["gemini-5h"]["resetsAt"] == "2026-10-20T17:20:45.125Z"
    assert rows["3p-weekly"]["usedPercent"] == 100 and rows["3p-weekly"]["resetsAt"] == "2026-10-22T09:10:15Z"
    assert rows["other-5h"]["resetsAt"] is None
    assert rows["gemini-argon-wtu-weekly"]["title"] == "Gemini 4 Argon · 每周"
    assert rows["gemini-argon-wtu-weekly"]["usedPercent"] == 50 and rows["gemini-argon-wtu-weekly"]["windowSeconds"] == 604_800
    assert all(not row["exhausted"] for row in rows.values())
    assert not store.alerts_path.exists()
    encoded = store.library_path.read_text(encoding="utf-8")
    assert "2099" not in encoded and "fixture@example.invalid" not in encoded
    reloaded = TokenStore(tmp_path, now=lambda: NOW + timedelta(days=1))
    view = reloaded.view_account(reloaded._find(account["id"]))
    assert view[REPORT_FIELD] == report and view["snapshot"] is None and not view["history"]
    assert view["ring"]["showsDash"] and not view["warnings"] and view["quotaForecast"]["reason"] == "noReadings"
    groups.reverse()
    for group in groups:
        group["buckets"].reverse()
    same = reloaded.import_antigravity_report({"id": account["id"], "confirmed": True, "report": json.dumps(payload)})
    assert same == {"report": report, "duplicate": True}


def test_json_rejects_agent_statusline_and_inconsistent_quota_fields():
    document = CLI_FIXTURE.read_text(encoding="utf-8")
    valid = json.loads(document)
    for malformed in (
        {"rate_limits": {"five_hour": {"used_percentage": 42}}},
        {**valid, "status": "ERROR"},
        {**valid, "conversation_id": "other-conversation"},
        {**valid, "num_turns": 1},
        {**valid, "num_turns": False},
        {**valid, "usage": {**valid["usage"], "cache_read_tokens": 1}},
        {**valid, "usage": {"total_tokens": 0}},
        {**valid, "command": {**valid["command"], "name": "statusline"}},
        {**valid, "command": {**valid["command"], "data": {"groups": []}}},
    ):
        with pytest.raises(AppError):
            parse_report(json.dumps(malformed))
    for malformed in (
        document.replace('"status": "SUCCESS"', '"status": "ERROR", "status": "SUCCESS"'),
        document.replace('"remaining_fraction": 0.75', '"remaining_fraction": NaN'),
        document.replace('"remaining_fraction": 0.75', '"remaining_fraction": 1e999999999999999999999999'),
        document.replace('"remaining_fraction": 0.75', '"remaining_fraction": "0.75"'),
        document.replace('"id": "gemini-weekly", "window": "weekly"', '"id": "gemini-weekly", "window": "5h"'),
        document.replace('"name": "Gemini Models"', '"name": "Claude and GPT models"'),
        document.replace('"id": "gemini-5h"', '"id": "gemini-weekly"'),
        document.replace('"Gemini 4 Argon"', '"Gemini Models"'),
    ):
        with pytest.raises(AppError):
            parse_report(malformed)


def test_existing_text_report_without_source_or_with_old_fingerprints_reopens(tmp_path):
    store = TokenStore(tmp_path, now=lambda: NOW)
    account = store.save_account({"provider": "gemini"})
    payload = {"id": account["id"], "confirmed": True, "report": REPORT}
    first = store.import_antigravity_report(payload)
    persisted = json.loads(store.library_path.read_text(encoding="utf-8"))
    previous = persisted["accounts"][0][REPORT_FIELD]
    del previous["source"]
    previous["fingerprints"] = ["a" * 64]
    store.library_path.write_text(json.dumps(persisted), encoding="utf-8")
    reloaded = TokenStore(tmp_path, now=lambda: NOW + timedelta(days=1))
    assert reloaded.import_antigravity_report(payload) == {"report": first["report"], "duplicate": True}


def test_legacy_mac_rows_are_not_relabelled_or_reused_on_windows(tmp_path):
    vault = MemoryCredentialStore()
    vault.put("legacy-configured", "fixture legacy credential")
    report = {"observedAt": "2026-11-28T00:00:00Z", "source": "Fixture legacy source", "quotas": [{
        "id": "five", "title": "5 hours", "usedPercent": 99, "windowSeconds": 18_000,
        "resetsAt": "2026-11-28T05:00:00Z", "exhausted": False,
    }], "balances": [], "costs": []}
    legacy = dict(empty_library(), accounts=[
        {"id": "legacy-automatic", "provider": "gemini", "connection": "Gemini 桌面端 Antigravity", "autoDiscovered": True,
         "name": "Gemini", "statusNote": "Earlier status"},
        {"id": "legacy-configured", "provider": "gemini", "connection": GEMINI_APP, "name": "Intentional legacy",
         "scopeID": "prior", "snapshot": report, "history": [report]},
        {"id": "legacy-other", "provider": "gemini", "connection": AGENT_LOCAL, "name": "Older connection"},
    ])
    raw = json.dumps(legacy, ensure_ascii=False)
    (tmp_path / "library.json").write_text(raw, encoding="utf-8")
    store = TokenStore(tmp_path, credentials=vault, now=lambda: NOW)
    assert not store.load_failed
    assert store.library_path.read_text(encoding="utf-8") == raw
    automatic, configured, older = store.library["accounts"]
    assert automatic["connection"] == "Gemini 桌面端 Antigravity" and automatic["name"] == "Gemini"
    assert configured["connection"] == GEMINI_APP
    assert older["connection"] == AGENT_LOCAL
    assert automatic["statusNote"] == "Earlier status"
    view = store.view_account(configured)
    assert view["snapshot"] == report and view["history"] == [report] and view["stale"]
    assert view["health"] == "historical" and view["ring"]["showsDash"]
    assert not view["warnings"] and "quotaForecast" not in view
    for account in (automatic, configured, older):
        store.refresh(account["id"], user_initiated=True)
        with pytest.raises(AppError, match="独立版"):
            store.import_antigravity_report({"id": account["id"], "confirmed": True, "report": REPORT})
    assert store.refresh_all() == [] and store.refresh_due() == []
    assert store.library_path.read_text(encoding="utf-8") == raw

    with pytest.raises(AppError, match="另建"):
        store.save_account({"provider": "gemini", "connection": GEMINI_APP})
    with pytest.raises(AppError, match="另建"):
        store.save_account({"id": "legacy-configured", "provider": "gemini", "connection": ANTIGRAVITY_REPORT})
    candidates = [{"provider": "gemini", "connection": ANTIGRAVITY_REPORT}]
    added, = store.add_discovered(candidates)
    assert not store.add_discovered(candidates)
    assert store._find(added)["connection"] == ANTIGRAVITY_REPORT
    assert store._find("legacy-configured")["snapshot"] == report
    assert store._find("legacy-configured")["scopeID"] == "prior"
    assert store._find("legacy-configured")["connection"] == GEMINI_APP
    assert vault.has("legacy-configured")
    encoded = json.loads(store.library_path.read_text(encoding="utf-8"))
    assert encoded["accounts"][0]["connection"] == automatic["connection"]
    assert encoded["accounts"][0]["name"] == automatic["name"]


def test_an_existing_gemini_json_connection_remains_usable(tmp_path):
    fixture = tmp_path / "snapshot.json"
    fixture.write_text(json.dumps({"observedAt": "2026-11-28T00:00:00Z", "source": "fixture", "quotas": [{
        "id": "five", "title": "5 hours", "usedPercent": 10, "windowSeconds": 18_000,
        "resetsAt": "2026-11-28T05:00:00Z", "exhausted": False,
    }], "balances": [], "costs": []}), encoding="utf-8")
    account = {"id": "existing-file", "name": "Existing JSON", "provider": "gemini", "connection": FILE, "filePath": str(fixture)}
    (tmp_path / "library.json").write_text(json.dumps(dict(empty_library(), accounts=[account])), encoding="utf-8")
    store = TokenStore(tmp_path, now=lambda: NOW)
    store.save_account({**account, "name": "Renamed JSON"})
    store.refresh(account["id"], user_initiated=True)
    snapshot = store._find(account["id"])["snapshot"]
    assert snapshot["source"] == "快照文件"
    for metadata in ({"source": "Gemini App 中的 Antigravity · /usage"}, {"isUnverifiedAntigravityReport": True}):
        fixture.write_text(json.dumps({**snapshot, **metadata}), encoding="utf-8")
        store.refresh(account["id"], user_initiated=True)
        assert store._find(account["id"])["snapshot"] == snapshot
        assert "历史报告" in store._find(account["id"])["error"]
    for prohibited in ({"provider": "gemini", "connection": FILE}, {**account, "connection": ANTIGRAVITY_REPORT}):
        with pytest.raises(AppError, match="另建"):
            store.save_account(prohibited)
    separate = store.save_account({"provider": "gemini"})
    assert separate["connection"] == ANTIGRAVITY_REPORT and separate["id"] != account["id"]


def test_report_web_requires_auth_and_surfaces_file_write_failure(tmp_path, monkeypatch):
    store = TokenStore(tmp_path, now=lambda: NOW)
    account = store.save_account({"provider": "gemini"})
    server = serve(store, open_browser=False, start_timer=False)
    payload = json.dumps({"id": account["id"], "confirmed": True, "report": REPORT}).encode()
    url = server.url + "api/antigravity/import"
    try:
        with pytest.raises(HTTPError) as error:
            urlopen(Request(url, data=payload), timeout=5)
        assert error.value.code == 403
        with urlopen(Request(url, data=payload, headers={"X-Gao-Token": server.token}), timeout=5) as response:
            saved = json.load(response)
        assert saved["result"]["report"] == saved["state"]["accounts"][0][REPORT_FIELD]
        assert "fingerprints" not in saved["result"]["report"]
        assert "fingerprints" not in saved["state"]["rail"][0][REPORT_FIELD]
        assert store.refresh_all() == [] and store.refresh_due() == []

        def failed_write(*_args, **_kwargs):
            raise OSError("isolated disk failure")

        monkeypatch.setattr(store, "_write_library", failed_write)
        changed = payload.replace(b"75.5%", b"77%")
        with pytest.raises(HTTPError) as error:
            urlopen(Request(url, data=changed, headers={"X-Gao-Token": server.token}), timeout=5)
        assert json.load(error.value)["code"] == "io"
        assert store.view_account(store._find(account["id"]))[REPORT_FIELD] == saved["result"]["report"]
    finally:
        server.shutdown()
        server.server_close()
