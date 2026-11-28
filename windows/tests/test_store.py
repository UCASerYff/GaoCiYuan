"""资料库、刷新、凭据和圆环。"""

from __future__ import annotations

import json
import os
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

from gaociyuan.catalog import FILE, MIMO
from gaociyuan.credentials import MemoryCredentialStore
from gaociyuan.errors import AppError
from gaociyuan.rings import adaptive_interval, compact_balance, compact_credits
from gaociyuan.store import TokenStore

NOW = datetime(2026, 11, 15, 2, 0, tzinfo=timezone.utc)


def clock():
    return NOW


def store(tmp_path: Path) -> TokenStore:
    return TokenStore(tmp_path, credentials=MemoryCredentialStore(), now=clock)


def snapshot(used: float, observed: str = "2026-11-15T01:50:00Z", note: str | None = None, tokens=None, cost=None) -> dict:
    body = {
        "observedAt": observed,
        "periodStart": "2026-11-01T00:00:00Z",
        "periodEnd": observed,
        "source": "导入",
        "quotas": [
            {
                "id": "five",
                "title": "5小时",
                "usedPercent": used,
                "resetsAt": "2026-11-15T06:00:00Z",
                "exhausted": False,
                "windowSeconds": 18000,
            }
        ],
        "inputTokens": None if not tokens else tokens[0],
        "outputTokens": None if not tokens else tokens[1],
        "costs": [] if not cost else [{"currency": "USD", "value": cost}],
        "balances": [],
        "note": note,
        "deadlines": [],
        "creditBalances": [],
    }
    return body


def test_migration_removes_llm_without_backup(tmp_path: Path):
    vault = MemoryCredentialStore()
    vault.put("llm-id", "secret-llm")
    vault.put("keep-id", "secret-keep")
    raw = {
        "schema": 1,
        "station": {"gold": 3},
        "futureField": {"keep": True},
        "accounts": [
            {"id": "llm-id", "provider": "openai", "kind": "LLM", "name": "API", "connection": "OpenAI 管理 API", "currency": "USD"},
            {"id": "custom-id", "provider": "custom", "kind": "Agent", "name": "自定义", "connection": "自定义 API 余额查询（GET）", "currency": "USD"},
            {"id": "keep-id", "provider": "openai", "kind": "Agent", "name": "Codex", "connection": "本机 Codex", "currency": "usd"},
        ],
        "refreshMinutes": 5,
        "warningThreshold": 20,
        "autoRefresh": True,
    }
    (tmp_path / "library.json").write_text(json.dumps(raw), encoding="utf-8")
    loaded = TokenStore(tmp_path, credentials=vault, now=clock)
    assert loaded.load_failed is False
    assert [item["id"] for item in loaded.library["accounts"]] == ["keep-id"]
    assert loaded.library["accounts"][0]["name"] == "OpenAI · ChatGPT · Codex"
    assert loaded.library["accounts"][0]["currency"] == "USD"
    assert vault.get("llm-id") is None
    assert vault.get("keep-id") == "secret-keep"
    saved = json.loads((tmp_path / "library.json").read_text(encoding="utf-8"))
    assert "station" not in saved
    assert saved["futureField"] == {"keep": True}
    assert "secret-llm" not in (tmp_path / "library.json").read_text(encoding="utf-8")
    names = [path.name for path in tmp_path.iterdir()]
    assert not any("bak" in name or "backup" in name for name in names)


def test_legacy_credential_migration_persists_before_delete_and_retries(tmp_path, monkeypatch):
    library_path = tmp_path / "library.json"
    library_payload = {
        "schema": 1,
        "accounts": [
            {"id": "Retired", "provider": "openai", "kind": "LLM", "name": "Legacy API", "connection": "OpenAI 管理 API"},
            {"id": "retired", "provider": "next-version", "kind": "FutureAgent", "name": "Future fixture", "metadata": {"keep": [1, 2]}},
            {"id": "Live-ID", "provider": "openai", "kind": "Agent", "name": "Active fixture", "connection": "本机 Codex"},
            {"id": "live-id", "provider": "custom", "kind": "Agent", "name": "Removed collision"},
            {"id": "Only-Old", "provider": "openai", "kind": "LLM", "name": "Remove only after save"},
        ],
    }
    original = json.dumps(library_payload)
    library_path.write_text(original, encoding="utf-8")
    calls = []

    class Vault(MemoryCredentialStore):
        retry = False

        def delete(self, account_id):
            saved = json.loads(library_path.read_text(encoding="utf-8"))
            assert saved["pendingLegacyCredentialIDs"] == ["Only-Old"]
            assert {record["id"] for record in saved["accounts"]} == {"retired", "Live-ID"}
            calls.append(account_id)
            if not self.retry:
                raise AppError("synthetic vault refusal", "credential")
            super().delete(account_id)

    vault = Vault()
    for account_id in ("Retired", "Live-ID", "Only-Old"):
        vault.put(account_id, f"synthetic-{account_id}")
    with monkeypatch.context() as patch:
        def block_replace(*args):
            raise PermissionError("synthetic file write refusal")

        patch.setattr("gaociyuan.store._atomic_json", block_replace)
        failed = TokenStore(tmp_path, credentials=vault, now=clock)
        assert failed.load_failed
        assert not calls
        assert library_path.read_text(encoding="utf-8") == original

    loaded = TokenStore(tmp_path, credentials=vault, now=clock)
    assert not loaded.load_failed
    assert "下次启动" in loaded.notice
    assert calls == ["Only-Old"]
    assert vault.has("Only-Old")
    vault.retry = True
    reloaded = TokenStore(tmp_path, credentials=vault, now=clock)
    assert calls == ["Only-Old", "Only-Old"]
    assert not vault.has("Only-Old")
    assert vault.has("Retired") and vault.has("Live-ID")
    reloaded.update_settings({"refreshMinutes": 7})
    saved = json.loads(library_path.read_text(encoding="utf-8"))
    assert "pendingLegacyCredentialIDs" not in saved
    assert next(item for item in saved["accounts"] if item["id"] == "retired") == library_payload["accounts"][1]
    with pytest.raises(AppError, match="历史账户"):
        reloaded.save_account({"id": "Retired", "provider": "openai", "connection": "本机 Codex"})


@pytest.mark.parametrize("original", ['{"theme":', '[]', '{"timeZone": "invalid/Zone"}'])
def test_corrupt_application_settings_remain_byte_identical(tmp_path, original):
    settings = tmp_path / "settings.json"
    settings.write_text(original, encoding="utf-8")
    loaded = store(tmp_path)
    before = loaded.settings.copy()
    assert loaded.settings_failed and "原文件已保留" in loaded.notice
    with pytest.raises(AppError, match="无法读取"):
        loaded.update_settings({"theme": "light", "autoRefresh": False})
    assert loaded.settings == before
    assert settings.read_text(encoding="utf-8") == original


def test_corrupt_library_is_not_overwritten(tmp_path: Path):
    original = "{not json"
    (tmp_path / "library.json").write_text(original, encoding="utf-8")
    loaded = store(tmp_path)
    assert loaded.load_failed is True
    assert (tmp_path / "library.json").read_text(encoding="utf-8") == original
    try:
        loaded.save_account({"provider": "claude", "connection": "本机软件自动读取"})
        raised = False
    except Exception:
        raised = True
    assert raised
    assert (tmp_path / "library.json").read_text(encoding="utf-8") == original


def test_snapshot_history_is_idempotent_and_capped(tmp_path: Path):
    library = store(tmp_path)
    account = library.save_account(
        {"provider": "claude", "connection": "自动读取快照文件", "filePath": str(tmp_path / "snap.json"), "name": "Claude Code"}
    )
    path = tmp_path / "snap.json"
    path.write_text(json.dumps(snapshot(12)), encoding="utf-8")
    library.refresh(account["id"], user_initiated=True)
    library.refresh(account["id"], user_initiated=True)
    saved = library._find(account["id"])
    assert len(saved["history"]) == 1
    assert saved["snapshot"]["quotas"][0]["usedPercent"] == 12
    assert saved["snapshot"]["source"] == "快照文件"
    path.write_text(json.dumps(snapshot(40)), encoding="utf-8")
    library.refresh(account["id"], user_initiated=True)
    assert len(library._find(account["id"])["history"]) == 2
    path.write_text("{", encoding="utf-8")
    library.refresh(account["id"], user_initiated=True)
    assert library._find(account["id"])["snapshot"]["quotas"][0]["usedPercent"] == 40
    assert "无法读取" in (library._find(account["id"])["error"] or "")
    for index in range(301):
        path.write_text(json.dumps(snapshot(index / 10, note=str(index))), encoding="utf-8")
        library.refresh(account["id"], user_initiated=True)
    assert len(library._find(account["id"])["history"]) == 300


def test_grokbot_is_manual_and_failure_keeps_last_reading(tmp_path: Path):
    library = store(tmp_path)
    grok = library.save_account({"provider": "grok", "connection": "本机软件自动读取", "name": "xAI · Grok · Grok Bot"})
    other = library.save_account(
        {"provider": "claude", "connection": "自动读取快照文件", "filePath": str(library.grok_path), "name": "不要读快照"}
    )
    contract = {
        "schema": 1,
        "source": "grok-bot-usage-report",
        "capturedAt": "2026-11-15T01:30:00Z",
        "plan": "Premium",
        "weeklyPercentUsed": 84.8,
        "resetsAt": "2026-11-16T01:00:00Z",
        "sharedWithOtherApps": True,
    }
    library.grok_path.write_text(json.dumps(contract), encoding="utf-8")
    library.refresh_due()
    library.refresh(grok["id"], user_initiated=False)
    assert library.grok_reads == 0
    assert library._find(grok["id"])["grokBotManualReading"] is None
    library.refresh(other["id"], user_initiated=True)
    blocked = library._find(other["id"])
    assert blocked["snapshot"] is None
    assert "读取本机额度" in (blocked["error"] or "")
    library.read_grokbot(grok["id"])
    assert library.grok_reads == 1
    reading = library._find(grok["id"])["grokBotManualReading"]
    assert reading["weeklyPercentUsed"] == 84.8
    assert library._find(grok["id"])["snapshot"] is None
    assert library._find(grok["id"])["history"] == []
    view = library.view_account(library._find(grok["id"]))
    assert view["ring"]["label"] == "15.2%"
    assert view["ring"]["stale"] is False
    library.grok_path.write_text("{", encoding="utf-8")
    library.read_grokbot(grok["id"])
    kept = library._find(grok["id"])
    assert kept["grokBotManualReading"]["weeklyPercentUsed"] == 84.8
    assert "未显示百分比" in kept["statusNote"]
    assert "0%" not in kept["statusNote"]
    library._now = lambda: NOW + timedelta(hours=7)
    dimmed = library.view_account(library._find(grok["id"]))
    assert dimmed["ring"]["stale"] is True
    assert dimmed["ring"]["label"] == "15.2%"
    assert dimmed["ring"]["opacity"] == 0.45
    assert library.grok_reads == 2


def test_secret_stays_out_of_library(tmp_path: Path):
    library = store(tmp_path)
    account = library.save_account(
        {"provider": "glm", "connection": "GLM Coding Plan API", "name": "Zcode", "secret": "sk-test-secret"}
    )
    text = (tmp_path / "library.json").read_text(encoding="utf-8")
    assert "sk-test-secret" not in text
    assert library.credentials.get(account["id"]) == "sk-test-secret"
    state = json.dumps(library.snapshot_state(), ensure_ascii=False)
    assert "sk-test-secret" not in state
    assert library.view_account(library._find(account["id"]))["hasCredential"] is True
    library.refresh(account["id"], user_initiated=True)
    note = library._find(account["id"])["statusNote"]
    assert "百分比" in note or "不会写入" in note
    assert library._find(account["id"])["snapshot"] is None


def test_filters_and_balance_rings(tmp_path: Path):
    library = store(tmp_path)
    claude = library.save_account({"provider": "claude", "connection": "本机软件自动读取", "name": "桌面 Claude"})
    body = snapshot(85)
    body["balances"] = []
    path = tmp_path / "claude.json"
    library._find(claude["id"])["connection"] = "自动读取快照文件"
    library._find(claude["id"])["filePath"] = str(path)
    path.write_text(json.dumps(body), encoding="utf-8")
    library.refresh(claude["id"], user_initiated=True)
    view = library.view_account(library._find(claude["id"]))
    assert view["health"] == "needsAction"
    assert any("剩余" in line for line in view["warnings"])
    assert view["ring"]["color"] == "orange"
    found = library.filtered_accounts(query="桌面", health="needsAction")
    assert len(found) == 1
    assert library.filtered_accounts(query="不存在") == []
    dsh = library.save_account({"provider": "dsh", "connection": "DeepSeek Harness 本机凭证", "name": "Harness"})
    balance = snapshot(0)
    balance["quotas"] = []
    balance["balances"] = [{"currency": "CNY", "value": 12.345}]
    library._find(dsh["id"])["snapshot"] = balance
    face = library.view_account(library._find(dsh["id"]))["ring"]
    assert face["kind"] == "dsh"
    assert face["label"] == "¥" + compact_balance(12.345)
    work = library.save_account({"provider": "workbuddy", "connection": "WorkBuddy 积分余额（本机只读）", "name": "WorkBuddy"})
    credits = snapshot(0)
    credits["quotas"] = []
    credits["balances"] = [{"currency": "CNY", "value": 1096.99}]
    library._find(work["id"])["snapshot"] = credits
    assert library.view_account(library._find(work["id"]))["ring"]["label"] == compact_credits(1096.99)


def test_adaptive_interval_and_usage_rows(tmp_path: Path):
    assert adaptive_interval(None, None, NOW) == 1800
    assert adaptive_interval(NOW - timedelta(minutes=1), None, NOW) == 120
    assert adaptive_interval(None, None, NOW, watched=False) == 300
    library = store(tmp_path)
    account = library.save_account({"provider": "claude", "connection": "自动读取快照文件", "name": "用量", "filePath": str(tmp_path / "u.json")})
    path = tmp_path / "u.json"
    path.write_text(json.dumps(snapshot(10)), encoding="utf-8")
    library.refresh(account["id"], user_initiated=True)
    assert library.usage_rows("all") == []
    path.write_text(json.dumps(snapshot(11, tokens=(1200, 300), cost=1.5)), encoding="utf-8")
    library.refresh(account["id"], user_initiated=True)
    rows = library.usage_rows("today")
    assert len(rows) == 1
    assert rows[0]["inputTokens"] == 1200
    assert rows[0]["outputTokens"] == 300
    assert rows[0]["cost"] == 1.5
    assert rows[0]["inputTokens"] != 0 or rows[0]["cost"] == 1.5


@pytest.mark.parametrize("invalid_field", [
    {"quotas": 42}, {"quotas": ""},
    {"quotas": [{"id": "five", "title": "5 小时", "usedPercent": 10**400}]},
    {"inputTokens": {"not": "a count"}}, {"deadlines": 42},
])
def test_invalid_snapshot_keeps_last_reading_and_does_not_starve_other_accounts(tmp_path, invalid_field):
    now = [NOW]
    library = TokenStore(tmp_path, credentials=MemoryCredentialStore(), now=lambda: now[0])
    first, second = tmp_path / "first.json", tmp_path / "second.json"
    account_x = library.save_account({"provider": "openai", "connection": FILE, "filePath": str(first)})
    account_y = library.save_account({"provider": "openai", "connection": FILE, "filePath": str(second)})
    first.write_text(json.dumps(snapshot(23)), encoding="utf-8")
    library.refresh(account_x["id"], user_initiated=True)
    previous = account_x["snapshot"]
    now[0] += timedelta(minutes=45)
    first.write_text(json.dumps({**snapshot(85), **invalid_field}), encoding="utf-8")
    second.write_text(json.dumps(snapshot(55)), encoding="utf-8")

    assert library.refresh_due() == [account_x["id"], account_y["id"]]
    assert account_x["snapshot"] == previous and account_x["history"] == [previous]
    assert account_x["error"] and library.failures[account_x["id"]] == 1
    assert account_y["snapshot"]["quotas"][0]["usedPercent"] == 55 and account_y["error"] is None


def test_account_save_reports_failed_disk_replace_without_publishing_a_draft(tmp_path, monkeypatch):
    library = store(tmp_path)
    account = library.save_account({"provider": "gemini", "name": "Saved fixture"})
    prior_bytes = library.library_path.read_bytes()
    real_replace = os.replace

    def deny_library_replace(source, destination):
        if destination == library.library_path:
            raise PermissionError("fixture destination denies replacement")
        return real_replace(source, destination)

    with monkeypatch.context() as patch:
        patch.setattr(os, "replace", deny_library_replace)
        with pytest.raises(PermissionError):
            library.save_account({"provider": "gemini", "id": account["id"], "name": "Unsaved edit"})
        assert library._find(account["id"]) is account
        assert library.library_path.read_bytes() == prior_bytes
        assert not list(tmp_path.glob(".library.json-*.tmp"))

    renamed = library.save_account({"provider": "gemini", "id": account["id"], "name": "Saved retry"})
    assert renamed["name"] == "Saved retry" and store(tmp_path)._find(account["id"])["name"] == "Saved retry"


def test_account_save_holds_credentials_after_partial_replace_failure(tmp_path, monkeypatch):
    library = store(tmp_path)
    original = {"provider": "mimo", "connection": MIMO, "name": "Original", "region": "cn"}
    account = library.save_account({**original, "secret": "synthetic-old"})
    fixture_calls = []

    def fake_connector(current, secret, _now, *, data_dir):
        fixture_calls.append((current["region"], secret))
        return snapshot(30)

    library.connector_reader = fake_connector
    library.refresh(account["id"], user_initiated=True)
    before = library.library_path.read_bytes()
    draft = {**original, "id": account["id"], "name": "Draft", "region": "ams"}
    assert fixture_calls == [("cn", "synthetic-old")]

    def deny_stage(*_args, **_kwargs):
        raise PermissionError("fixture cannot create the stage")

    with monkeypatch.context() as patch:
        patch.setattr(tempfile, "NamedTemporaryFile", deny_stage)
        with pytest.raises(PermissionError):
            library.save_account({**draft, "secret": "synthetic-new"})
        assert library._find(account["id"]) is account
        assert library.library_path.read_bytes() == before
        assert library.credentials.get(account["id"]) == "synthetic-old"

    def deny_rename(_source, destination):
        assert destination == library.library_path
        raise PermissionError("fixture destination denies replacement")

    with monkeypatch.context() as patch:
        patch.setattr(os, "replace", deny_rename)
        with pytest.raises(AppError, match="凭据可能已更新"):
            library.save_account({**draft, "secret": "synthetic-new"})
        assert library.library_path.read_bytes() == before
        current = library._find(account["id"])
        assert current["region"] == "cn" and current["snapshot"] == account["snapshot"]
        assert "quotaForecastHistory" not in current
        library.refresh(account["id"], user_initiated=True)
        assert fixture_calls == [("cn", "synthetic-old")]
        with pytest.raises(AppError, match="重新填写"):
            library.test_account({**original, "id": account["id"]})
        with pytest.raises(AppError, match="重新填写"):
            library.save_account(draft)
        assert not list(tmp_path.glob(".library.json-*.tmp"))

    revised = library.save_account({**draft, "secret": "synthetic-new"})
    library.refresh(revised["id"], user_initiated=True)
    assert fixture_calls == [("cn", "synthetic-old"), ("ams", "synthetic-new")]
