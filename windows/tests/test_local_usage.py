import json
import sqlite3
from copy import deepcopy
from datetime import datetime, timedelta, timezone
from pathlib import Path
from urllib.request import Request, urlopen
from zoneinfo import ZoneInfo

import pytest

from gaociyuan.errors import AppError
from gaociyuan.local_usage import LocalUsageService
from gaociyuan.usage import UsageLedger
from gaociyuan.usage_prices import PRICE_SOURCES, cached_rates, refresh_prices

NOW = datetime(2026, 9, 1, 16, tzinfo=timezone.utc)
ZONE = ZoneInfo("Asia/Shanghai")
STAMP = "2026-09-01T01:00:00Z"


def json_lines(path, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(map(json.dumps, rows)) + "\n", encoding="utf-8")
    return path


def configure(service, paths, **extras):
    return service.save_settings({"engine": {"enabledClientIDs": list(paths),
                                             "customPaths": {key: [str(path) for path in values] for key, values in paths.items()},
                                             "modelPrices": extras.pop("prices", [])}, **extras})


def test_codex_history_is_private_idempotent_and_separate_from_snapshot_ledger(tmp_path, monkeypatch):
    from gaociyuan import usage_scan

    db = tmp_path / "data"
    snapshots = UsageLedger(db / "usage-ledger.sqlite")
    snapshots.record({"id": "old", "provider": "codex"}, {"observedAt": STAMP, "source": "manual", "inputTokens": 7, "outputTokens": 5})
    service = LocalUsageService(db, allow_default_paths=False)
    assert service.scan(NOW, ZONE, automatic=True) == {"skipped": True}
    assert not service.path.exists()

    def counts(input_tokens, cached, output, reasoning):
        return dict(input_tokens=input_tokens, cached_input_tokens=cached, output_tokens=output, reasoning_output_tokens=reasoning)

    def usage(at, total, last):
        return {"timestamp": at, "type": "event_msg", "payload": {"type": "token_count", "info": {"total_token_usage": total, "last_token_usage": last}}}

    first = counts(100, 60, 25, 5)
    second = counts(300, 180, 55, 15)
    rows = [
        {"type": "session_meta", "payload": {"id": "session-1", "cwd": r"C:\fixture-private\project-alpha"}},
        {"type": "turn_context", "payload": {"model": "fixture-model"}},
        {"type": "response_item", "payload": {"content": "TEST-PROMPT-DO-NOT-STORE"}},
        usage("2026-08-31T16:10:00Z", first, first),
        usage("2026-08-31T16:10:05Z", first, first),
        usage("2026-09-01T16:00:00Z", second, counts(200, 120, 30, 10)),
    ]
    active = json_lines(tmp_path / "logs" / "rollout-active.jsonl", rows)
    archived = json_lines(tmp_path / "archive" / "rollout-copy.jsonl", rows)
    configure(service, {"codex": [active.parent, archived.parent]}, prices=[{"model": "fixture-model", "inputPerMillion": 2,
                                                                             "outputPerMillion": 10, "cacheReadPerMillion": .2}])
    assert service.scan(NOW, ZONE)["eventCount"] == 2
    dashboard = service.dashboard("7d", NOW, ZONE)
    assert dashboard["total"] == {"input": 120, "output": 40, "cacheRead": 180, "cacheWrite": 0,
                                  "reasoning": 15, "messageCount": 2, "costUSD": pytest.approx(.000826), "totalTokens": 355}
    assert [row["day"] for row in dashboard["days"]] == ["2026-09-01", "2026-09-02"]
    assert dashboard["sessions"]["rows"][0]["projectLabel"] == "project-alpha"
    assert service.dashboard("today", NOW, ZONE)["total"]["totalTokens"] == 230
    assert service.dashboard("today", NOW, ZONE)["sessions"]["totalCount"] == 1
    assert service.dashboard("today", NOW, ZONE, offset=50)["sessions"]["rows"] == []
    assert service.scan(NOW + timedelta(seconds=5), ZONE, automatic=True) == {"skipped": True}

    original_read = usage_scan._read
    observed_paths = []

    def track_read(client, path, info, budget):
        observed_paths.append(path)
        yield from original_read(client, path, info, budget)

    monkeypatch.setattr(usage_scan, "_read", track_read)
    assert service.scan(NOW, ZONE)["eventCount"] == 0
    assert observed_paths == []
    active.unlink()
    archived.unlink()
    assert service.scan(NOW, ZONE)["warnings"]
    closed = LocalUsageService(db, allow_default_paths=False)
    assert closed.dashboard("7d", NOW, ZONE)["total"]["totalTokens"] == 355
    assert snapshots.rows("all", NOW, ZONE)[0]["inputTokens"] == 7
    archive = closed.export_json()
    assert b"TEST-PROMPT-DO-NOT-STORE" not in archive + service.path.read_bytes()
    assert b"fixture-private" not in archive + service.path.read_bytes()
    assert b"rollout-active" not in service.path.read_bytes()


def test_supported_parsers_count_actual_usage_and_discard_prompt_data(tmp_path):
    service = LocalUsageService(tmp_path / "data", allow_default_paths=False)
    source = tmp_path / "logs"
    private = "TEST-MESSAGE-CONTENTS"
    claude = {"type": "assistant", "sessionId": "claude-1", "timestamp": STAMP, "cwd": r"C:\private\project",
              "message": {"id": "msg-1", "model": "claude-pro", "content": private,
                          "usage": {"input_tokens": 10, "output_tokens": 2, "cache_read_input_tokens": 4, "cache_creation_input_tokens": 5,
                                    "cache_creation": {"ephemeral_1h_input_tokens": 2}}}}
    claude_path = json_lines(source / "claude.jsonl", [claude, claude])
    kimi = {"timestamp": 1788224400, "message": {"type": "StatusUpdate", "payload": {"message_id": "kimi-message", "token_usage": {"input_other": 20, "output": 4}}}}
    kimi_a = json_lines(source / "kimi" / "a" / "session-1" / "wire.jsonl", [kimi])
    kimi_b = json_lines(source / "kimi" / "b" / "session-1" / "wire.jsonl", [kimi])
    kimi_code = {"type": "usage.record", "usageScope": "turn", "time": 1788224400000, "model": "kimi-code", "usage": {"inputOther": 5, "output": 1}}
    kimi_c = json_lines(source / "kimi" / "b" / "session-2" / "agents" / "main" / "wire.jsonl", [kimi_code, kimi_code])
    gemini = {"type": "gemini", "id": "gem-req", "model": "gemini-1", "timestamp": STAMP, "content": private,
              "tokens": {"input": 32, "output": 8, "cached": 16, "thoughts": 2, "tool": 4}}
    gemini_legacy = source / "session-legacy.json"
    gemini_legacy.write_text(json.dumps({"sessionId": "gemini-1", "messages": [gemini]}), encoding="utf-8")
    gemini_modern = json_lines(source / "session-modern.jsonl", [{"sessionId": "gemini-1", "projectHash": "fixture"}, gemini, gemini])
    pi_session = {"type": "session", "id": "pi-1", "cwd": r"C:\private\project"}
    pi_usage = {"type": "message", "id": "req", "timestamp": STAMP, "message": {"role": "assistant", "model": "gpt-fixture", "content": private,
                                                                                 "usage": {"input": 5, "output": 2, "cacheRead": 2, "cacheWrite": 1, "cost": {"total": .4}}}}
    pi = json_lines(source / "pi.jsonl", [pi_session, pi_usage])
    openclaw = json_lines(source / "openclaw.jsonl", [pi_session, pi_usage])
    qwen = json_lines(source / "qwen.jsonl", [{"type": "assistant", "uuid": "qwen-req", "sessionId": "qwen-1", "model": "qwen3",
                                              "timestamp": STAMP, "usageMetadata": {"promptTokenCount": 7, "candidatesTokenCount": 1,
                                                                                      "cachedContentTokenCount": 2, "thoughtsTokenCount": 3}}])
    attrs = {"gen_ai.operation.name": "chat", "gen_ai.usage.input_tokens": "8", "gen_ai.usage.output_tokens": "3",
             "gen_ai.usage.cache_read.input_tokens": "1", "gen_ai.usage.cache_write.input_tokens": "2", "gen_ai.usage.reasoning.output_tokens": "1",
             "gen_ai.response.model": "gpt-fixture", "gen_ai.conversation.id": "copilot-1", "gen_ai.input.messages": private}
    span = {"traceId": "trace-1", "spanId": "span-1", "startTimeUnixNano": "1788224399000000000", "endTimeUnixNano": "1788224400000000000",
            "attributes": [{"key": key, "value": {"stringValue": value}} for key, value in attrs.items()]}
    duplicate_summary = {**span, "spanId": "summary", "attributes": {**attrs, "gen_ai.operation.name": "invoke_agent"}}
    copilot = json_lines(source / "otel.ndjson", [{"resourceSpans": [{"scopeSpans": [{"spans": [span, duplicate_summary]}]}]}])
    configured = configure(service, {"claude": [claude_path], "kimi": [kimi_a, kimi_b, kimi_c], "gemini": [gemini_legacy, gemini_modern],
                                     "pi": [pi], "openclaw": [openclaw], "qwen": [qwen], "copilot": [copilot]})
    assert all(choice["supported"] and choice["detected"] for choice in configured["sources"] if choice["id"] in configured["engine"]["enabledClientIDs"])
    assert service.scan(NOW, ZONE)["eventCount"] == 9
    usage = service.dashboard("all", NOW, ZONE)
    totals = {row["name"]: row["amounts"]["totalTokens"] for row in usage["byClient"]}
    assert totals == {"claude": 21, "gemini": 46, "kimi": 36, "pi": 10, "openclaw": 10, "qwen": 11, "copilot": 11}
    assert usage["total"]["costUSD"] is None
    copilot_session = next(item for item in usage["sessions"]["rows"] if item["client"] == "copilot")
    assert copilot_session["timedDurationMS"] == 1000
    assert copilot_session["timedTokens"] == 11
    assert private.encode() not in service.path.read_bytes() + service.export_json()


def test_archive_merge_csv_and_validation_are_idempotent(tmp_path):
    original = LocalUsageService(tmp_path / "host-a", allow_default_paths=False)
    log = json_lines(tmp_path / "claude.jsonl", [{"type": "assistant", "timestamp": STAMP, "sessionId": "a", "message": {"id": "a1", "model": "=danger", "usage": {"input_tokens": 9}}}])
    output = tmp_path / "manual-export"
    output.mkdir()
    configure(original, {"claude": [log]}, automaticExportPath=str(output))
    original.scan(NOW, ZONE)
    archive_path, = output.glob("搞词元-用量-*.json")
    package = json.loads(archive_path.read_text(encoding="utf-8"))
    assert package["format"] == 2
    assert len(package["devices"]) == 1
    csv = original.export_csv("all", NOW, ZONE)
    assert csv.startswith(b"\xef\xbb\xbf") and b"\r\n" in csv and b"'=danger" in csv
    assert original.import_archive(package)["deviceCount"] == 1
    other = LocalUsageService(tmp_path / "host-b", allow_default_paths=False)
    for version in (1, 2, 3, 4):
        package["format"] = version
        other.import_archive(package)
        assert other.dashboard("all", NOW, ZONE)["total"]["totalTokens"] == 9
    package["devices"][0]["days"].append({**package["devices"][0]["days"][0], "amounts": {"input": -1}})
    with pytest.raises(AppError, match="用量包"):
        other.import_archive(package)
    assert other.dashboard("all", NOW, ZONE)["total"]["totalTokens"] == 9


def mac_usage_package(extra=False):
    def amounts(tokens, messages=1, cost=None):
        result = {"input": tokens, "output": 0, "cacheRead": 0, "cacheWrite": 0, "reasoning": 0, "messageCount": messages}
        if cost is not None:
            result["costUSD"] = cost
        return result

    def row(session_id, model, counters):
        return {"client": "antigravity", "sessionID": session_id, "model": model, "amounts": counters}

    def day(row):
        return {**row, "day": "2026-09-01"}

    def session(row, timed_tokens, duration):
        return {**row, "firstActive": STAMP, "lastActive": STAMP, "timedTokens": timed_tokens, "timedDurationMS": duration}

    event_id = "a" * 64
    known = row("known-session", "gemini-3.8-flash", amounts(10, cost=0.01))
    legacy = row("legacy-session", "unknown", amounts(23))
    captured = {**known, "eventID": event_id, "timestamp": STAMP, "durationMS": 1000,
                "projectKey": "b" * 64, "projectLabel": "Synthetic project"}
    events = [captured]
    if extra:
        events.append({**captured, "eventID": "c" * 64, "amounts": amounts(5, cost=0.01)})
        known = {**known, "amounts": amounts(15, messages=2, cost=0.02)}
    coverage = {**known, "model": "unknown"}
    legacy_overlap = {**legacy, "amounts": amounts(3, messages=0)}
    legacy_residual = {**legacy, "amounts": amounts(20)}
    duration = 2000 if extra else 1000
    return {"format": 4, "exportedAt": STAMP, "devices": [{
        "id": "FA825567-2B25-431E-8A41-453FF1969142", "name": "Fixture Mac",
        "days": [day(known), day(legacy_residual)],
        "sessions": [{**session(known, known["amounts"]["input"], duration), "projectKey": captured["projectKey"],
                      "projectLabel": captured["projectLabel"]}, session(legacy_residual, 0, 0)],
        "cursorEvents": [],
        "localUsage": {"clients": ["antigravity"], "events": events,
                       "coverageDays": [day(coverage), day(legacy_overlap)],
                       "coverageSessions": [session(coverage, 0, 0), session(legacy_overlap, 0, 0)],
                       "baselineDays": [day(legacy)], "baselineSessions": [session(legacy, 0, 0)],
                       "retainedUnknownEventIDs": [event_id]},
    }]}


def test_mac_archive_keeps_source_events_and_monotonic_totals_after_round_trip(tmp_path):
    directory = tmp_path / "relay"
    service = LocalUsageService(directory, allow_default_paths=False)
    package = mac_usage_package()
    original_mac = package["devices"][0]
    # A previous Windows reader may already have imported these same aggregate
    # rows without their provenance. Adopting the source does not add them twice.
    legacy = deepcopy(package)
    legacy["format"] = 2
    legacy["devices"][0].pop("localUsage")
    legacy["devices"][0]["id"] = original_mac["id"].lower()
    service.import_archive(legacy)
    service.import_archive(package)
    service.import_archive(package)
    service.import_archive(legacy)
    assert service.dashboard("all", NOW, ZONE)["total"]["totalTokens"] == 30
    assert service.dashboard("all", NOW, ZONE)["sessions"]["totalCount"] == 2

    reopened = LocalUsageService(directory, allow_default_paths=False)
    exported = json.loads(reopened.export_json(NOW))
    assert exported["format"] == 4
    mac = next(device for device in exported["devices"] if device["id"] == original_mac["id"])
    assert mac["localUsage"] == original_mac["localUsage"]
    assert sum(row["amounts"]["input"] for row in mac["days"]) == 30
    second_relay = LocalUsageService(tmp_path / "next-host", allow_default_paths=False)
    second_relay.import_archive(exported)
    assert second_relay.dashboard("all", NOW, ZONE)["total"]["totalTokens"] == 30

    newer = mac_usage_package(extra=True)
    reopened.import_archive(newer)
    reopened.import_archive(package)
    assert reopened.dashboard("all", NOW, ZONE)["total"]["totalTokens"] == 35
    new_export = json.loads(reopened.export_json(NOW))
    mac = next(device for device in new_export["devices"] if device["id"] == original_mac["id"])
    assert mac["localUsage"] == newer["devices"][0]["localUsage"]


def test_mac_archive_conflict_does_not_change_records_or_strip_provenance(tmp_path):
    service = LocalUsageService(tmp_path / "data", allow_default_paths=False)
    package = mac_usage_package()
    service.import_archive(package)
    before = json.loads(service.export_json(NOW))
    other_device = {"id": "adbe2426-eb74-43e4-9db8-87ac6ffdb910", "name": "Other fixture", "days": [], "sessions": []}

    different_event = deepcopy(package)
    event = different_event["devices"][0]["localUsage"]["events"][0]
    changed_id = "d" * 64
    event["eventID"] = changed_id
    different_event["devices"][0]["localUsage"]["retainedUnknownEventIDs"] = [changed_id]
    different_event["devices"].insert(0, other_device)
    with pytest.raises(AppError, match="无法安全合并"):
        service.import_archive(different_event)

    legacy = deepcopy(package)
    legacy["format"] = 2
    legacy["devices"][0].pop("localUsage")
    legacy["devices"][0]["days"][0]["amounts"]["input"] = 20
    with pytest.raises(AppError, match="无法安全合并"):
        service.import_archive(legacy)
    assert json.loads(service.export_json(NOW)) == before


@pytest.mark.parametrize("failure", ["older-format-marker", "missing-event", "unsupported-field", "inflated-projection", "ambiguous-baseline", "subsecond-event"])
def test_invalid_mac_archive_is_rejected_before_opening_database(tmp_path, failure):
    service = LocalUsageService(tmp_path / failure, allow_default_paths=False)
    package = mac_usage_package()
    device = package["devices"][0]
    usage = device["localUsage"]
    if failure == "older-format-marker":
        package["format"] = 3
    elif failure == "missing-event":
        usage["retainedUnknownEventIDs"] = ["d" * 64]
    elif failure == "unsupported-field":
        usage["unsupported"] = "Fixture"
    elif failure == "inflated-projection":
        row = device["days"][0]
        row["amounts"] = {**row["amounts"], "input": 20}
    elif failure == "ambiguous-baseline":
        usage["baselineDays"].append({**usage["coverageDays"][0]})
    elif failure == "subsecond-event":
        usage["events"][0]["timestamp"] = STAMP.replace("Z", ".0000001Z")
    with pytest.raises(AppError, match="用量包"):
        service.import_archive(package)
    assert not service.path.exists()


def test_mac_archive_round_trip_through_desktop_import_export_routes(tmp_path):
    from gaociyuan.store import TokenStore
    from gaociyuan.web import serve

    directory = tmp_path / "loopback"
    store = TokenStore(directory, now=lambda: NOW)
    service = LocalUsageService(directory, allow_default_paths=False)
    server = serve(store, open_browser=False, start_timer=False, local_usage=service)
    package = mac_usage_package()
    fixture = package["devices"][0]
    headers = {"X-Gao-Token": server.token, "Content-Type": "application/json"}
    try:
        for _ in range(2):
            request = Request(server.url + "api/usage/import", json.dumps(package).encode("utf-8"), headers)
            with urlopen(request, timeout=5) as response:
                assert json.load(response)["result"]["deviceCount"] == 1
        with urlopen(Request(server.url + "api/usage?range=all", headers=headers), timeout=5) as response:
            assert json.load(response)["total"]["totalTokens"] == 30
        with urlopen(Request(server.url + "api/export/local-usage.json", headers=headers), timeout=5) as response:
            exported = json.load(response)
        assert exported["format"] == 4
        foreign = next(device for device in exported["devices"] if device["id"] == fixture["id"])
        assert foreign["localUsage"] == fixture["localUsage"]
    finally:
        server.shutdown()
        server.server_close()


@pytest.mark.parametrize("original", [b"{", b'{"authorized":"true"}', b'{"automaticExportPath":[]}',
                                     b'{"automaticExportPath":"relative-folder"}', b'{"engine":{"unsupported":true}}'])
def test_malformed_usage_settings_are_preserved_across_scan_save_and_archive_import(tmp_path, original):
    directory = tmp_path / "locked-settings"
    directory.mkdir()
    path = directory / "windows-usage-settings.json"
    path.write_bytes(original)
    service = LocalUsageService(directory, allow_default_paths=False)
    assert service.settings_state()["error"]
    with pytest.raises(AppError, match="原文件已保留"):
        service.save_settings({"refreshMinutes": 10})
    with pytest.raises(AppError, match="原文件已保留"):
        service.scan(NOW, ZONE)
    assert service.scan(NOW, ZONE, automatic=True)["skipped"]
    assert not service.path.exists()
    service.import_archive(mac_usage_package())
    assert service.dashboard("all", NOW, ZONE)["total"]["totalTokens"] == 30
    assert path.read_bytes() == original


def test_temporarily_unavailable_usage_export_path_is_preserved_without_disabling_scan(tmp_path):
    directory = tmp_path / "unavailable-export"
    directory.mkdir()
    path = directory / "windows-usage-settings.json"
    export_path = str(tmp_path / "missing-destination")
    original = json.dumps({"authorized": True, "engine": {"enabledClientIDs": []}, "automaticExportPath": export_path}).encode("utf-8")
    path.write_bytes(original)
    service = LocalUsageService(directory, allow_default_paths=False)
    assert service.settings_state()["error"] is None
    assert service.settings_state()["automaticExportPath"] == export_path
    assert any("自动导出的文件夹不可用" in warning for warning in service.scan(NOW, ZONE)["warnings"])
    assert path.read_bytes() == original


def test_usage_save_does_not_replace_a_file_corrupted_after_startup(tmp_path):
    service = LocalUsageService(tmp_path / "changed-settings", allow_default_paths=False)
    service.save_settings({"refreshMinutes": 10})
    changed = b'{"authorized":'
    service.settings_path.write_bytes(changed)
    with pytest.raises(AppError, match="原文件已保留"):
        service.save_settings({"refreshMinutes": 15})
    assert service.settings_state()["refreshMinutes"] == 10
    assert service.settings_path.read_bytes() == changed


def test_default_paths_are_opt_in_and_isolation_can_disable_them(tmp_path, monkeypatch):
    log = json_lines(tmp_path / "fixture-codex" / "sessions" / "rollout-test.jsonl", [
        {"type": "turn_context", "payload": {"model": "fixture"}},
        {"timestamp": STAMP, "type": "event_msg", "payload": {"type": "token_count", "info": {"total_token_usage": {"input_tokens": 30}}}},
    ])
    monkeypatch.setenv("CODEX_HOME", str(log.parent.parent))
    for name in ("APPDATA", "CLAUDE_CONFIG_DIR", "KIMI_CODE_HOME", "PI_AGENT_DIR", "OPENCLAW_STATE_DIR", "GEMINI_CLI_HOME", "QWEN_HOME",
                 "OPENCODE_DB", "XDG_DATA_HOME", "HERMES_HOME", "CLINE_SESSION_DATA_DIR", "CLINE_DATA_DIR", "CLINE_DIR", "GROK_HOME"):
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setattr(Path, "home", classmethod(lambda cls: tmp_path / "fixture-home"))
    service = LocalUsageService(tmp_path / "isolated", allow_default_paths=False)
    assert service.scan(NOW, ZONE)["eventCount"] == 0
    default_service = LocalUsageService(tmp_path / "default")
    assert default_service.scan(NOW, ZONE, automatic=True) == {"skipped": True}
    assert default_service.scan(NOW, ZONE)["eventCount"] == 1
    with pytest.raises(AppError, match="本地磁盘"):
        configure(default_service, {"codex": [r"\\server\share\path"]})


def test_sqlite_reads_numeric_columns_and_detects_open_wal_updates(tmp_path):
    service = LocalUsageService(tmp_path / "data", allow_default_paths=False)
    private = "PRIVATE-CONVERSATION-TEXT"
    hermes = tmp_path / "state.db"
    conn = sqlite3.connect(hermes)
    try:
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("""CREATE TABLE sessions (id TEXT, model TEXT, started_at REAL, input_tokens INTEGER, output_tokens INTEGER,
                        reasoning_tokens INTEGER, cache_read_tokens INTEGER, message_count INTEGER, system_prompt TEXT)""")
        conn.execute("INSERT INTO sessions VALUES (?,?,?,?,?,?,?,?,?)", ("h1", "hermes-model", 1788224400, 15, 3, 1, 5, 2, private))
        conn.commit()

        oc = tmp_path / "opencode.db"
        open_conn = sqlite3.connect(oc)
        try:
            open_conn.execute("CREATE TABLE message (id TEXT, session_id TEXT, time_created INTEGER, data TEXT)")
            open_conn.execute("CREATE TABLE session_message (id TEXT, session_id TEXT, time_created INTEGER, type TEXT, data TEXT)")
            content = {"role": "assistant", "modelID": "oc-model", "tokens": {"input": 10, "output": 2, "reasoning": 3, "cache": {"read": 4, "write": 1}}, "content": private}
            open_conn.execute("INSERT INTO message VALUES (?,?,?,?)", ("m1", "oc", 1788224400000, json.dumps(content)))
            modern = {**content, "model": {"id": "oc-model"}}
            open_conn.execute("INSERT INTO session_message VALUES (?,?,?,?,?)", ("m1", "oc", 1788224400000, "assistant", json.dumps(modern)))
            open_conn.execute("INSERT INTO message VALUES (?,?,?,?)", ("m2", "oc", 1788224400000, "malformed"))
            open_conn.commit()
        finally:
            open_conn.close()
        configure(service, {"hermes": [hermes], "opencode": [oc]})
        assert service.scan(NOW, ZONE)["eventCount"] == 2
        assert service.dashboard("all", NOW, ZONE)["total"]["totalTokens"] == 43
        assert service.scan(NOW, ZONE)["eventCount"] == 0
        conn.execute("UPDATE sessions SET output_tokens=8, message_count=4")
        conn.commit()
        assert service.scan(NOW, ZONE)["eventCount"] == 1
        data = service.dashboard("all", NOW, ZONE)
        assert data["total"]["totalTokens"] == 48
        assert data["total"]["messageCount"] == 5
        assert any("跨日" in text for text in data["warnings"])
    finally:
        conn.close()
    assert not hermes.with_name("state.db-shm").exists()
    assert not hermes.with_name("state.db-wal").exists()
    service.scan(NOW, ZONE)
    assert not hermes.with_name("state.db-shm").exists()
    assert not hermes.with_name("state.db-wal").exists()
    assert private.encode() not in service.path.read_bytes() + service.export_json()


def test_cline_kilo_read_desktop_and_cli_token_buckets(tmp_path):
    service = LocalUsageService(tmp_path / "data", allow_default_paths=False)
    paths = {}
    for name, protocol in {"cline": "anthropic", "kilo": "openai"}.items():
        path = tmp_path / name / "fixture-task" / "ui_messages.json"
        path.parent.mkdir(parents=True)
        metrics = {"apiProtocol": protocol, "tokensIn": 10, "tokensOut": 3, "cacheReads": 5, "cacheWrites": 2, "cost": .2, "request": "PROMPT-NEVER-PERSIST"}
        row = {"type": "say", "say": "api_req_started", "ts": 1788224400000, "modelInfo": {"modelId": "fixture-model"}, "text": json.dumps(metrics)}
        path.write_text(json.dumps([row]), encoding="utf-8")
        paths[name] = [path]
    cli = tmp_path / "fixture-cli.messages.json"
    cli.write_text(json.dumps({"version": 1, "messages": [{"role": "assistant", "id": "c1", "ts": 1788224400000,
                                                           "modelInfo": {"id": "fixture-cli-model", "provider": "anthropic"},
                                                           "metrics": {"inputTokens": 10, "outputTokens": 2, "cacheReadTokens": 2, "cacheWriteTokens": 1, "cost": .1}}]}), encoding="utf-8")
    paths["cline"].append(cli)
    configure(service, paths)
    assert service.scan(NOW, ZONE)["eventCount"] == 3
    totals = {row["name"]: row["amounts"] for row in service.dashboard("all", NOW, ZONE)["byClient"]}
    assert totals["cline"]["totalTokens"] == 32
    assert totals["kilo"]["totalTokens"] == 13
    assert b"PROMPT-NEVER-PERSIST" not in service.path.read_bytes() + service.export_json()


def test_grok_build_and_droid_read_accounting_without_opening_grok_bot(tmp_path):
    service = LocalUsageService(tmp_path / "data", allow_default_paths=False)
    usage = {"inputTokens": 100, "outputTokens": 25, "cachedReadTokens": 50, "reasoningTokens": 5, "modelCalls": 2,
             "costUsdTicks": 10_000_000_000, "modelUsage": {"grok-4.5": {}}}
    row = {"method": "session/update", "params": {"sessionId": "grok-1", "_meta": {"agentTimestampMs": 1788224400000},
                                                     "update": {"sessionUpdate": "turn_completed", "prompt_id": "prompt-1", "usage": usage}}}
    grok = json_lines(tmp_path / "grok" / "updates.jsonl", [row, row])
    (grok.parent / "grokbot-usage.json").write_text(json.dumps(row), encoding="utf-8")
    droid = tmp_path / "droid.settings.json"
    droid.write_text(json.dumps({"model": "droid-model", "providerLockTimestamp": STAMP,
                                  "tokenUsage": {"inputTokens": 10, "outputTokens": 3, "cacheReadTokens": 5, "thinkingTokens": 2}}), encoding="utf-8")
    configure(service, {"grok": [grok.parent], "droid": [droid]})
    assert service.scan(NOW, ZONE)["eventCount"] == 2
    values = {row["name"]: row["amounts"] for row in service.dashboard("all", NOW, ZONE)["byClient"]}
    assert values["grok"]["totalTokens"] == 125 and values["grok"]["costUSD"] == 1
    assert values["grok"]["messageCount"] == 2
    assert values["droid"]["totalTokens"] == 20


def test_public_price_download_cache_uses_two_explicit_sources(tmp_path):
    requests = []

    def fetch(url):
        requests.append(url)
        if url == PRICE_SOURCES["LiteLLM"]:
            return json.dumps({"fixture": {"input_cost_per_token": .000002, "output_cost_per_token": .000005}}).encode()
        return json.dumps({"openai": {"models": {"fixture": {"cost": {"input": 3, "output": 10, "cache_read": .5}}}}}).encode()

    assert cached_rates(tmp_path, NOW) == ({}, [])
    assert refresh_prices(tmp_path, NOW, fetch=fetch)["updatedSources"] == ["LiteLLM", "models.dev"]
    assert requests == list(PRICE_SOURCES.values())
    assert cached_rates(tmp_path, NOW)[0]["fixture"] == {"inputPerMillion": 2, "outputPerMillion": 5, "cacheReadPerMillion": .5}
    assert refresh_prices(tmp_path, NOW + timedelta(minutes=5), fetch=fetch)["warnings"]
    assert len(requests) == 2
    after_stale = NOW + timedelta(hours=2)
    assert len(cached_rates(tmp_path, after_stale)[1]) == 2
    with pytest.raises(AppError, match="更新失败"):
        refresh_prices(tmp_path, after_stale, fetch=lambda _: b'{"fixture":{"input_cost_per_token":true}}')
    with pytest.raises(AppError, match="15 分钟"):
        refresh_prices(tmp_path, after_stale + timedelta(minutes=1), fetch=fetch)
    assert cached_rates(tmp_path, after_stale)[0]["fixture"]["inputPerMillion"] == 2
