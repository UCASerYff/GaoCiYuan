"""本地页面只接受本机会话，响应里不出现凭据。"""

from __future__ import annotations

import json
from datetime import datetime, timezone
from urllib.request import Request, urlopen

from gaociyuan.credentials import MemoryCredentialStore
from gaociyuan.store import TokenStore
from gaociyuan.web import serve

NOW = datetime(2026, 11, 15, 2, 0, tzinfo=timezone.utc)


def test_http_round_trip(tmp_path):
    store = TokenStore(tmp_path, credentials=MemoryCredentialStore(), now=lambda: NOW)
    server = serve(store, port=0, open_browser=False, start_timer=False)
    try:
        page = urlopen(server.url, timeout=5)
        html = page.read().decode("utf-8")
        assert page.status == 200
        token = html.split('name="gao-token" content="', 1)[1].split('"', 1)[0]
        assert token
        denied = Request(server.url + "api/state")
        try:
            urlopen(denied, timeout=5)
            assert False
        except Exception as exc:
            assert getattr(exc, "code", None) == 403
        created = _post(server, token, "/api/library/create", {})
        assert created["ok"] is True
        saved = _post(
            server,
            token,
            "/api/accounts/save",
            {"provider": "grok", "connection": "本机软件自动读取", "name": "xAI · Grok · Grok Bot", "secret": "should-not-leak"},
        )
        account_id = saved["result"]["id"]
        blob = json.dumps(saved["state"], ensure_ascii=False)
        assert "should-not-leak" not in blob
        contract = {
            "schema": 1,
            "source": "grok-bot-usage-report",
            "capturedAt": "2026-11-15T01:40:00Z",
            "plan": "Premium",
            "weeklyPercentUsed": 20,
            "resetsAt": "2026-11-16T01:00:00Z",
            "sharedWithOtherApps": False,
        }
        (tmp_path / "grokbot-usage.json").write_text(json.dumps(contract), encoding="utf-8")
        read = _post(server, token, "/api/grokbot/read", {"id": account_id})
        match = next(item for item in read["state"]["accounts"] if item["id"] == account_id)
        assert match["ring"]["label"] == "80%"
        assert match["history"] == []
        _post(server, token, "/api/shutdown", {})
    finally:
        server.shutdown()
        server.server_close()


def _post(server, token, path, payload):
    data = json.dumps(payload).encode("utf-8")
    request = Request(server.url.rstrip("/") + path, data=data, method="POST")
    request.add_header("Content-Type", "application/json")
    request.add_header("X-Gao-Token", token)
    with urlopen(request, timeout=5) as response:
        return json.loads(response.read().decode("utf-8"))
