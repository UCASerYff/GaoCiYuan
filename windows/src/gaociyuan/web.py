"""只监听 127.0.0.1 的本地页面。用量和凭据不离开这台电脑。"""

from __future__ import annotations

import json
import mimetypes
import secrets
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse
from gaociyuan.catalog import catalog_entries
from gaociyuan.errors import AppError
from gaociyuan.resources import asset_dir
from gaociyuan.store import TokenStore
from gaociyuan.usage import csv_bytes, history_quota_rows
from gaociyuan.version import VERSION_LABEL


class TokenServer(ThreadingHTTPServer):
    allow_reuse_address = False

    def __init__(self, store: TokenStore, host: str = "127.0.0.1", port: int = 0):
        self.store = store
        self.token = secrets.token_urlsafe(24)
        self.lock = threading.Lock()
        self.shutdown_requested = threading.Event()
        super().__init__((host, port), Handler)

    @property
    def url(self) -> str:
        host, port = self.server_address[:2]
        return f"http://{host}:{port}/"


class Handler(BaseHTTPRequestHandler):
    server: TokenServer

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path == "/":
            self._page()
            return
        if parsed.path == "/api/state":
            if not self._authorized():
                return
            query = parse_qs(parsed.query)
            with self.server.lock:
                self._json(
                    self.server.store.snapshot_state(
                        query.get("q", [""])[0],
                        query.get("provider", [""])[0],
                        query.get("health", [""])[0],
                    )
                )
            return
        if parsed.path == "/api/catalog":
            if not self._authorized():
                return
            self._json({"providers": catalog_entries()})
            return
        if parsed.path == "/api/usage":
            if not self._authorized():
                return
            self._usage(parse_qs(parsed.query))
            return
        if parsed.path == "/api/credentials/status":
            if not self._authorized():
                return
            account_id = parse_qs(parsed.query).get("id", [""])[0]
            with self.server.lock:
                self._json({"hasCredential": self.server.store.credentials.has(account_id)})
            return
        if parsed.path == "/api/export/history.csv":
            self._history_csv(parse_qs(parsed.query))
            return
        if parsed.path == "/api/export/usage.csv":
            self._usage_csv(parse_qs(parsed.query))
            return
        root = asset_dir().resolve()
        asset = (root / parsed.path.lstrip("/")).resolve()
        if asset.is_file() and root in asset.parents:
            mime = mimetypes.guess_type(asset.name)[0] or "application/octet-stream"
            self._bytes(asset.read_bytes(), mime)
            return
        self._json({"error": "没有这个页面。"}, 404)

    def do_POST(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path == "/api/shutdown":
            if not self._authorized():
                return
            self._json({"ok": True})
            self.server.shutdown_requested.set()
            threading.Thread(target=self.server.shutdown, daemon=True).start()
            return
        if not self._authorized():
            return
        try:
            payload = self._body()
            with self.server.lock:
                result = dispatch(self.server.store, parsed.path, payload)
                state = self.server.store.snapshot_state()
            self._json({"ok": True, "result": result, "state": state})
        except AppError as exc:
            self._json({"ok": False, "error": exc.message, "code": exc.code}, 400)
        except (KeyError, TypeError, ValueError):
            self._json({"ok": False, "error": "请求格式无效。", "code": "invalid"}, 400)

    def _usage(self, query: dict) -> None:
        key = query.get("range", ["7d"])[0]
        provider = query.get("provider", [""])[0]
        with self.server.lock:
            rows = self.server.store.usage_rows(key, provider)
        self._json({"rows": rows})

    def _history_csv(self, query: dict) -> None:
        if not self._authorized():
            return
        key = query.get("range", ["all"])[0]
        provider = query.get("provider", [""])[0]
        text = query.get("q", [""])[0]
        with self.server.lock:
            store = self.server.store
            rows = history_quota_rows(store.library["accounts"], key, store.now(), store.zone, provider, text)
        body = csv_bytes(["account", "provider", "observedAt", "source", "quota", "usedPercent", "resetsAt"], rows)
        self._bytes(body, "text/csv; charset=utf-8")

    def _usage_csv(self, query: dict) -> None:
        if not self._authorized():
            return
        key = query.get("range", ["all"])[0]
        provider = query.get("provider", [""])[0]
        with self.server.lock:
            rows = self.server.store.usage_rows(key, provider)
        body = csv_bytes(
            ["accountId", "provider", "observedAt", "source", "inputTokens", "outputTokens", "currency", "cost"],
            rows,
        )
        self._bytes(body, "text/csv; charset=utf-8")

    def _page(self) -> None:
        html = (asset_dir() / "index.html").read_text(encoding="utf-8")
        html = html.replace("{{TOKEN}}", self.server.token).replace("{{VERSION}}", VERSION_LABEL)
        self._bytes(html.encode("utf-8"), "text/html; charset=utf-8")

    def _authorized(self) -> bool:
        if self.headers.get("X-Gao-Token") == self.server.token:
            return True
        self._json({"error": "缺少本机会话令牌。"}, 403)
        return False

    def _body(self) -> dict:
        length = int(self.headers.get("Content-Length") or 0)
        if length > 2_000_000:
            raise AppError("请求体过大。")
        raw = self.rfile.read(length) if length else b"{}"
        data = json.loads(raw.decode("utf-8") or "{}")
        if not isinstance(data, dict):
            raise AppError("请求体须为 JSON 对象。")
        return data

    def _json(self, payload: dict, status: int = 200) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self._bytes(body, "application/json; charset=utf-8", status)

    def _bytes(self, body: bytes, content_type: str, status: int = 200) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt: str, *args) -> None:
        return


def dispatch(store: TokenStore, path: str, payload: dict):
    if path == "/api/library/create":
        store.create_library()
        return {"created": True}
    if path == "/api/settings":
        return store.update_settings(payload)
    if path == "/api/accounts/save":
        account = store.save_account(payload)
        return {"id": account["id"]}
    if path == "/api/accounts/delete":
        store.delete_account(payload["id"])
        return {"deleted": True}
    if path == "/api/accounts/refresh":
        store.refresh(payload["id"], user_initiated=True)
        return {"refreshed": True}
    if path == "/api/grokbot/read":
        store.read_grokbot(payload["id"])
        return {"read": True, "grokReads": store.grok_reads}
    if path == "/api/credentials/set":
        store.set_credential(payload["id"], payload.get("secret") or "")
        return {"stored": True}
    if path == "/api/credentials/delete":
        store.delete_credential(payload["id"])
        return {"deleted": True}
    if path == "/api/refresh-due":
        return {"ids": store.refresh_due()}
    raise AppError("没有这个操作。")


def serve(store: TokenStore, port: int = 0, open_browser: bool = True, start_timer: bool = True) -> TokenServer:
    server = TokenServer(store, port=port)
    thread = threading.Thread(target=server.serve_forever, name="gaociyuan-http", daemon=True)
    thread.start()
    if start_timer:
        threading.Thread(target=_timer, args=(server,), name="gaociyuan-refresh", daemon=True).start()
    if open_browser:
        import webbrowser

        webbrowser.open(server.url)
    return server


def _timer(server: TokenServer) -> None:
    while not server.shutdown_requested.wait(60):
        with server.lock:
            server.store.refresh_due()
