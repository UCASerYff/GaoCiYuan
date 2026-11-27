import io
import json
import os
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

from gaociyuan import providers
from gaociyuan.catalog import AGENT_LOCAL, CLAUDE_STATUSLINE, CODEX, FILE, GROK_ACCOUNT, MIMO, catalog_entries, windows_read_mode
from gaociyuan.discovery import ProviderDiscovery, automatic_provider, observations_from
from gaociyuan.errors import AppError


NOW = datetime(2026, 11, 27, 4, tzinfo=timezone.utc)


def test_catalog_keeps_provider_ids_and_distinguishes_windows_routes():
    entries = {row["id"]: row for row in catalog_entries()}
    for provider, connection in (("openai", CODEX), ("claude", CLAUDE_STATUSLINE), ("grok", AGENT_LOCAL), ("mimo", MIMO)):
        row = entries[provider]
        assert row["defaultConnection"] == connection
        assert row["connectionDetails"][connection]["mode"] in {"connector", "grokbot"}
    assert entries["cursor"]["defaultConnection"] == FILE
    assert not entries["openrouter"]["creatable"]
    assert windows_read_mode("grok", GROK_ACCOUNT) == "unsupported"
    assert windows_read_mode("grok", FILE) == "file"


def test_discovery_separates_desktop_running_and_cli_and_automatic_routes():
    observations = observations_from(
        {"claude", "deepseek harness"}, {"qoder"}, {"codex", "deepseek"},
        lambda commands: Path("isolated", "codex.exe") if commands == ("codex",) else None,
        lambda identity: False,
    )
    rows = {row["provider"]: row for row in observations}
    assert rows["openai"]["isRunning"] and not rows["openai"]["appInstalled"]
    assert rows["openai"]["cliPath"].endswith("codex.exe")
    assert rows["claude"]["appInstalled"] and not rows["claude"]["isRunning"]
    assert rows["deepseek"]["isRunning"] and not rows["dsh"]["isRunning"]
    automatic = {item["provider"]: item for item in ProviderDiscovery.automatic_accounts(observations)}
    assert set(automatic) == {"openai", "claude"}
    assert automatic["openai"]["connection"] == CODEX
    assert automatic["claude"]["connection"] == CLAUDE_STATUSLINE
    assert automatic_provider({"provider": "grok", "connection": AGENT_LOCAL}) == "grok"
    assert automatic_provider({"provider": "grok", "connection": GROK_ACCOUNT}) is None
    hidden = {"provider": "grok", "connection": AGENT_LOCAL, "autoDiscovered": True}
    discovery = ProviderDiscovery(collect=lambda: observations)
    assert discovery.rail_visible(hidden)
    assert discovery.observations(force=True) == observations
    assert discovery.completed and not discovery.rail_visible(hidden)
    assert discovery.rail_visible({**hidden, "autoDiscovered": False})
    assert ProviderDiscovery(enabled=False, collect=lambda: pytest.fail("isolated discovery touched host")).observations(force=True) == []


@pytest.mark.skipif(os.name != "nt", reason="Win32 package and process APIs")
def test_win32_discovery_uses_current_session_and_current_user(monkeypatch):
    from gaociyuan import discovery

    monkeypatch.setattr(discovery, "_PACKAGE_FAMILIES", {"fixture": "GaoCiYuan.Synthetic_abcdefghijklm"})
    assert discovery._installed_packages() == set()
    assert Path(sys.executable).stem.casefold() in discovery._running_names()


def test_codex_process_handshake_is_read_only(tmp_path):
    fixture = tmp_path / "app_server.py"
    fixture.write_text('''
import json
import sys

def receive():
    return json.loads(sys.stdin.buffer.readline())

def reply(payload):
    print(json.dumps(payload), flush=True)

hello = receive()
assert hello["method"] == "initialize" and hello["params"]["clientInfo"]["name"] == "gaociyuan"
reply({"id": hello["id"], "result": {}})
assert receive() == {"method": "initialized"}
query = receive()
assert query == {"id": 2, "method": "account/rateLimits/read"}
reply({"method": "account/rateLimits/updated", "params": {}})
reply({"id": 2, "result": {"rateLimits": {"limitId": "codex", "planType": "plus",
    "primary": {"usedPercent": 25, "windowDurationMins": 300, "resetsAt": 1795777200}}}})
assert not sys.stdin.buffer.read()
''', encoding="utf-8")
    data = providers._read_codex([sys.executable, str(fixture)], tmp_path, timeout=3)
    result = providers.parse_codex(data, NOW)
    assert result["quotas"][0]["id"] == "codex-primary"
    assert result["quotas"][0]["usedPercent"] == 25
    assert result["quotas"][0]["windowSeconds"] == 18_000


def test_codex_separate_pools_and_timeout_preserve_error(tmp_path):
    fixture = tmp_path / "stuck.py"
    fixture.write_text("import time\ntime.sleep(30)\n", encoding="utf-8")
    with pytest.raises(AppError) as failure:
        providers._read_codex([sys.executable, str(fixture)], tmp_path, timeout=.15)
    assert failure.value.code == "network"
    pools = {"rateLimitsByLimitId": {
        "codex": {"primary": {"usedPercent": 10, "windowDurationMins": 300}, "secondary": {"usedPercent": 100}},
        "codex_other": {"limitName": "Other", "primary": {"usedPercent": 20}},
        "claude": {"primary": {"usedPercent": 3}},
    }}
    quotas = providers.parse_codex(pools, NOW)["quotas"]
    assert [item["id"] for item in quotas] == ["codex-primary", "codex-secondary", "codex_other-primary"]
    assert quotas[1]["exhausted"]
    with pytest.raises(AppError):
        providers.parse_codex({"rateLimits": {"primary": {"usedPercent": True}}}, NOW)


def test_claude_capture_discards_session_and_ignores_empty_push(tmp_path):
    account = {"provider": "claude", "connection": CLAUDE_STATUSLINE}
    with pytest.raises(AppError, match="等待"):
        providers.read_connector(account, None, NOW, data_dir=tmp_path)
    fixture = {"transcript_path": "sensitive-fixture", "session_id": "never-store", "rate_limits": {
        "five_hour": {"used_percentage": 10.25, "resets_at": int((NOW + timedelta(hours=5)).timestamp())},
        "seven_day": {"used_percentage": 35, "resets_at": int((NOW - timedelta(minutes=1)).timestamp())},
        "spend_limit": {"used_percentage": 120, "used_usd": 999999},
    }}
    assert providers.capture_claude_statusline(io.BytesIO(json.dumps(fixture).encode()), tmp_path, NOW) == "5 小时 10.25% · 消费上限 100%"
    cached = tmp_path / providers.CLAUDE_STATUSLINE_FILE
    cache_before = cached.read_bytes()
    assert b"sensitive-fixture" not in cache_before
    assert b"never-store" not in cache_before
    assert b"999999" not in cache_before
    assert providers.capture_claude_statusline(io.BytesIO(b'{"model": {"id": "fixture"}}'), tmp_path, NOW) is None
    assert cached.read_bytes() == cache_before
    read = providers.read_connector(account, None, NOW, data_dir=tmp_path)
    assert [item["usedPercent"] for item in read["quotas"]] == [10.25, 100]
    with pytest.raises(AppError, match="已过期"):
        providers.read_connector(account, None, NOW + timedelta(hours=7), data_dir=tmp_path)


def test_mimo_uses_fixed_region_scoped_endpoint_and_real_credit_fields(monkeypatch):
    payload = {
        "object": "token_plan", "plan_code": "lite-monthly",
        "period": {"start_at": "2026-11-05 02:00:00", "end_at": "2026-12-05 02:00:00"},
        "quota": {"total_credits": 200, "used_credits": 30, "remaining_credits": 170},
    }

    def intercept(endpoint, key, source):
        assert endpoint == "https://token-plan-sgp.xiaomimimo.com/v1/platform/token_plan"
        assert key == "tp-synthetic-only" and source == "MiMo Token Plan"
        return payload

    monkeypatch.setattr(providers, "_quota_json", intercept)
    account = {"provider": "mimo", "connection": MIMO, "region": "sgp"}
    read = providers.read_connector(account, "tp-synthetic-only", NOW)
    assert read["quotas"][0]["usedPercent"] == 15
    assert read["quotas"][0]["resetsAt"] == "2026-12-05T02:00:00Z"
    assert read["creditBalances"][0]["value"] == 170
    with pytest.raises(AppError, match="专属密钥"):
        providers.read_connector(account, "wrong-fixture", NOW)
    with pytest.raises(AppError, match="集群"):
        providers.read_connector({**account, "region": "host.invalid"}, "tp-synthetic-only", NOW)
    with pytest.raises(AppError):
        providers.parse_mimo({**payload, "quota": {"total_credits": 200, "used_credits": 30, "remaining_credits": 200}}, NOW)


def test_unsupported_and_grok_report_routes_do_not_call_connector():
    for account in ({"provider": "grok", "connection": AGENT_LOCAL}, {"provider": "grok", "connection": GROK_ACCOUNT}):
        with pytest.raises(AppError) as failure:
            providers.read_connector(account, "irrelevant", NOW)
        assert failure.value.code == "unsupported"

def test_minimax_cli_uses_documented_percentages_and_separate_windows(tmp_path, monkeypatch):
    start = int((NOW - timedelta(hours=2)).timestamp() * 1000)
    end = int((NOW + timedelta(hours=3)).timestamp() * 1000)
    payload = {"base_resp": {"status_code": 0}, "model_remains": [
        {"model_name": "general", "start_time": start, "end_time": end,
         "current_interval_remaining_percent": "40", "current_interval_usage_count": 123,
         "current_weekly_remaining_percent": 75, "weekly_end_time": end,
         "current_weekly_total_count": 300, "current_interval_total_count": 500},
        {"model_name": "video", "start_time": start, "end_time": end,
         "current_interval_remaining_percent": 100, "current_interval_status": 3,
         "current_interval_total_count": 0, "current_weekly_remaining_percent": 100,
         "current_weekly_total_count": 0}
    ]}
    from gaociyuan.catalog import MINIMAX, MINIMAX_CLI

    program = tmp_path / "mmx.py"
    program.write_text("print(" + repr(json.dumps(payload)) + ")\n", encoding="utf-8")
    command = [sys.executable, str(program)]
    monkeypatch.setattr(providers, "_minimax_command", lambda: command)
    result = providers.read_connector({"provider": "minimax", "connection": MINIMAX_CLI}, None, NOW, data_dir=tmp_path)
    assert [(quota["title"], quota["usedPercent"]) for quota in result["quotas"]] == [
        ("MiniMax · 5 小时", 60), ("MiniMax · 每周", 25)
    ]
    assert windows_read_mode("minimax", MINIMAX) == "unsupported"


def test_minimax_resolves_approved_npm_entrypoint_without_cmd_shell(tmp_path, monkeypatch):
    script = tmp_path / "node_modules" / "mmx-cli" / "dist" / "mmx.mjs"
    script.parent.mkdir(parents=True)
    script.touch()
    node = tmp_path / "node.exe"
    monkeypatch.setattr(providers, "_path_roots", lambda: [tmp_path])
    monkeypatch.setattr(providers, "find_command", lambda names, native: node)
    assert providers._minimax_command() == [str(node), str(script), "quota", "show", "--output", "json"]

def test_opencode_go_uses_public_fixed_endpoint_and_explicit_key(monkeypatch):
    from gaociyuan.catalog import OPENCODE, OPENCODE_GO

    def intercept(endpoint, key, source, *, header):
        assert endpoint == "https://opencode.ai/inference/go/v1/usage"
        assert (header, key, source) == ("Authorization", "Bearer sk-test-fixture", "OpenCode Go")
        return {"usage": {
            "rolling": {"status": "ok", "percent": 30, "resetsAt": "2026-11-27T06:30:00.000Z"},
            "weekly": {"status": "rate-limited", "percent": 100, "resetsAt": "2026-11-30T00:00:00Z"},
        }}

    monkeypatch.setattr(providers, "_quota_json", intercept)
    result = providers.read_connector({"provider": "opencode", "connection": OPENCODE_GO}, "sk-test-fixture", NOW)
    assert [(quota["usedPercent"], quota["exhausted"]) for quota in result["quotas"]] == [(30, False), (100, True)]
    with pytest.raises(AppError, match="专属"):
        providers.read_connector({"provider": "opencode", "connection": OPENCODE_GO}, "auth=session;", NOW)
    with pytest.raises(AppError) as failure:
        providers.read_connector({"provider": "opencode", "connection": OPENCODE}, "sk-test-fixture", NOW)
    assert failure.value.code == "unsupported"


def test_bailian_cli_uses_distinct_windows_and_respects_unknown_quota(tmp_path, monkeypatch):
    from gaociyuan.catalog import ALIBABA_CODING_CLI, ALIBABA_TOKEN_CLI

    reset = int((NOW + timedelta(hours=4)).timestamp() * 1000)
    payloads = {
        "token-plan": {"per5HourPercentage": .3, "per5HourResetTime": reset, "per1WeekPercentage": 0, "hasQuotaData": True},
        "coding-plan": {"result": {"per5Hour": {"percentage": .4, "resetTime": reset},
                                    "perWeek": {"usedQuota": 7, "totalQuota": 0}, "perBillMonth": {"percentage": .2}}},
    }

    def npm_command(package, module, source, args):
        assert (package, module, source) == ("bailian-cli", "bailian.mjs", "百炼 CLI")
        assert args[:1] == ["usage"] and args[2:] == ["--output", "json"]
        return [args[1]]

    monkeypatch.setattr(providers, "_npm_command", npm_command)
    monkeypatch.setattr(providers, "_read_cli_json", lambda args, cwd, source: payloads[args[0]])
    token = providers.read_connector({"provider": "alibaba", "connection": ALIBABA_TOKEN_CLI}, None, NOW, data_dir=tmp_path)
    coding = providers.read_connector({"provider": "alibaba", "connection": ALIBABA_CODING_CLI}, None, NOW, data_dir=tmp_path)
    assert [quota["usedPercent"] for quota in token["quotas"]] == [30, 0]
    assert [quota["usedPercent"] for quota in coding["quotas"]] == [40, 20]
    with pytest.raises(AppError, match="未返回"):
        providers.parse_bailian({"hasQuotaData": False}, NOW, coding=False)
