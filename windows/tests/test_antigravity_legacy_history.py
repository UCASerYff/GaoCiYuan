from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone

import pytest

from gaociyuan.catalog import AGENT_LOCAL, ANTIGRAVITY_REPORT, CODEX, GEMINI_APP
from gaociyuan.credentials import MemoryCredentialStore
from gaociyuan.store import TokenStore, empty_library
from gaociyuan.timeutil import format_iso


NOW = datetime(2026, 11, 28, 12, tzinfo=timezone.utc)


def readings(count: int) -> list[dict]:
    return [
        {
            "observedAt": format_iso(NOW - timedelta(minutes=count - index)),
            "source": "旧 Gemini 来源" if index % 2 else "Legacy Antigravity source",
            "quotas": [{"id": "five", "title": "5 小时额度", "usedPercent": index % 100,
                        "windowSeconds": 18_000, "resetsAt": format_iso(NOW + timedelta(hours=1))}],
            "balances": [],
            "costs": [],
            "legacyObservationMetadata": {"fixtureIndex": index},
        }
        for index in range(count)
    ]


def fixture_store(directory) -> TokenStore:
    return TokenStore(directory, credentials=MemoryCredentialStore(), now=lambda: NOW)


@pytest.mark.parametrize("connection", [GEMINI_APP, AGENT_LOCAL, "Gemini 桌面端 Antigravity"])
def test_retired_gemini_history_survives_settings_and_independent_account_save(tmp_path, connection):
    history = readings(341)
    legacy = {"id": "legacy", "provider": "gemini", "kind": "Agent", "name": "旧额度账户",
              "connection": connection, "snapshot": history[-1], "history": history}
    history_only = {**legacy, "id": "history-only", "snapshot": None, "history": history[:1]}
    empty = {**history_only, "id": "no-readings", "history": []}
    library_path = tmp_path / "library.json"
    original = json.dumps(dict(empty_library(), accounts=[legacy, history_only, empty]), ensure_ascii=False)
    library_path.write_text(original, encoding="utf-8")

    store = fixture_store(tmp_path)
    assert not store.load_failed
    assert library_path.read_text(encoding="utf-8") == original
    assert store.refresh_all() == [] and store.refresh_due() == []
    for account in store.snapshot_state()["accounts"]:
        expected = account["id"] != "no-readings"
        assert account["health"] == ("historical" if expected else "syncPaused") and account["stale"] == expected
        assert account["ring"]["showsDash"] and not account["warnings"] and "quotaForecast" not in account

    store.update_settings({"refreshMinutes": 11, "appearance": "dark"})
    standalone = store.save_account({"provider": "gemini", "connection": ANTIGRAVITY_REPORT})
    persisted = json.loads(library_path.read_text(encoding="utf-8"))
    assert persisted["refreshMinutes"] == 11
    saved_accounts = {account["id"]: account for account in persisted["accounts"]}
    assert saved_accounts["legacy"]["connection"] == connection
    assert saved_accounts["legacy"]["history"] == history
    assert saved_accounts["legacy"]["snapshot"] == history[-1]
    assert saved_accounts["history-only"]["history"] == history[:1]
    assert not saved_accounts[standalone["id"]]["history"]

    reopened = fixture_store(tmp_path)
    assert not reopened.load_failed and reopened.settings["appearance"] == "dark"
    assert reopened._find("legacy")["history"] == history
    assert reopened._find("history-only")["history"] == history[:1]


def test_active_agent_history_retains_existing_bound(tmp_path):
    history = readings(305)
    active = {"id": "active", "provider": "openai", "kind": "Agent", "name": "Active fixture",
              "connection": CODEX, "snapshot": history[-1], "history": history}
    library_path = tmp_path / "library.json"
    library_path.write_text(json.dumps(dict(empty_library(), accounts=[active])), encoding="utf-8")
    store = fixture_store(tmp_path)
    assert not store.load_failed and store._find("active")["history"] == history[-300:]
    store.update_settings({"autoRefresh": False})
    persisted = json.loads(library_path.read_text(encoding="utf-8"))
    assert persisted["accounts"][0]["history"] == history[-300:]
