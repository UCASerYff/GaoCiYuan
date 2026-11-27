"""只监听 127.0.0.1 的本地页面。用量和凭据不离开这台电脑。"""

from __future__ import annotations

import json
import mimetypes
import os
import re
import secrets
import threading
import time
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse
from gaociyuan.catalog import catalog_entries
from gaociyuan.errors import AppError
from gaociyuan.resources import asset_dir, brand_dir
from gaociyuan.routes import app_fragment
from gaociyuan.store import TokenStore
from gaociyuan.usage import csv_bytes, history_quota_rows
from gaociyuan.updates import UpdateService
from gaociyuan.version import VERSION_LABEL


class TokenServer(ThreadingHTTPServer):
    allow_reuse_address = False

    def __init__(self, store: TokenStore, host: str = "127.0.0.1", port: int = 0, *, local_usage=None, discovery=None):
        self.store = store
        self.token = secrets.token_urlsafe(24)
        self.lock = store.lock
        self.shutdown_requested = threading.Event()
        self._work_changed = threading.Condition()
        self._active_work = 0
        self.local_usage = local_usage
        self.discovery = discovery
        self.native = None
        self.updates = UpdateService(store.directory)
        self.updates_lock = threading.Lock()
        super().__init__((host, port), Handler)

    @property
    def url(self) -> str:
        host, port = self.server_address[:2]
        return f"http://{host}:{port}/"

    @contextmanager
    def work(self, *, drain: bool = True):
        with self._work_changed:
            admitted = not self.shutdown_requested.is_set()
            if admitted and drain:
                self._active_work += 1
        try:
            yield admitted
        finally:
            if admitted and drain:
                with self._work_changed:
                    self._active_work -= 1
                    self._work_changed.notify_all()

    def request_shutdown(self) -> None:
        with self._work_changed:
            self.shutdown_requested.set()

    def drain_work(self) -> None:
        with self._work_changed:
            self._work_changed.wait_for(lambda: self._active_work == 0)

    def check_updates(self) -> dict:
        with self.updates_lock:
            with self.lock:
                source = self.store.settings['updateAppcastURL']
            return self.updates.check(source)

    def download_update(self) -> dict:
        with self.updates_lock:
            with self.lock:
                source = self.store.settings['updateAppcastURL']
                key = self.store.settings['updatePublicKey']
            return self.updates.download(source, key)

    def discover(self, *, force: bool = False, provider: str | None = None) -> list[str]:
        if self.discovery is None:
            return []
        suggested = self.discovery.automatic_accounts(self.discovery.observations(force=force))
        if provider is not None:
            suggested = [item for item in suggested if item['provider'] == provider]
        with self.lock:
            return self.store.add_discovered(suggested)


class Handler(BaseHTTPRequestHandler):
    server: TokenServer

    def setup(self) -> None:
        self.request.settimeout(10)
        super().setup()

    def do_GET(self) -> None:
        if not self._same_host():
            return
        parsed = urlparse(self.path)
        if parsed.path == "/":
            self._page('index.html')
            return
        if parsed.path == '/panel':
            self._page('panel.html')
            return
        if parsed.path.startswith('/brand/') or parsed.path == '/translations.tsv':
            self._brand(parsed.path)
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
        if parsed.path in {'/api/panel', '/api/discovery', '/api/native', '/api/updates', '/api/usage/settings', '/api/export/local-usage.csv', '/api/export/local-usage.json'}:
            if self._authorized():
                try:
                    self._extra_get(parsed.path, parse_qs(parsed.query))
                except AppError as exc:
                    self._json({'ok': False, 'error': exc.message, 'code': exc.code}, 400)
                except (TypeError, ValueError):
                    self._json({'ok': False, 'error': '请求格式无效。'}, 400)
            return
        if parsed.path == "/api/credentials/status":
            if not self._authorized():
                return
            account_id = parse_qs(parsed.query).get("id", [""])[0]
            with self.server.lock:
                self._json({"hasCredential": self.server.store.credential_present(account_id)})
            return
        if parsed.path == "/api/export/history.csv":
            self._history_csv(parse_qs(parsed.query))
            return
        if parsed.path == "/api/export/usage.csv":
            self._usage_csv(parse_qs(parsed.query))
            return
        if parsed.path == '/api/export/accounts.csv':
            self._accounts_csv()
            return
        root = asset_dir().resolve()
        asset = (root / parsed.path.lstrip("/")).resolve()
        if asset.is_file() and root in asset.parents:
            mime = mimetypes.guess_type(asset.name)[0] or "application/octet-stream"
            self._bytes(asset.read_bytes(), mime)
            return
        self._json({"error": "没有这个页面。"}, 404)

    def do_POST(self) -> None:
        if not self._same_host():
            return
        parsed = urlparse(self.path)
        if parsed.path == "/api/shutdown":
            if not self._authorized():
                return
            self._json({"ok": True})
            native = self.server.native
            if native is not None and not native.hidden:
                native.request_quit()
            else:
                self.server.request_shutdown()
                threading.Thread(target=self.server.shutdown, daemon=True).start()
            return
        if not self._authorized():
            return
        ui_only = parsed.path.startswith(('/api/choose/', '/api/open/')) or parsed.path in {'/api/window/open', '/api/panel/size'}
        with self.server.work(drain=not ui_only) as admitted:
            if not admitted:
                self._json({'ok': False, 'error': '应用正在退出。', 'code': 'shutdown'}, 503)
                return
            try:
                payload = self._body()
                result = self._action(parsed.path, payload)
                with self.server.lock:
                    state = self.server.store.snapshot_state()
                self._json({"ok": True, "result": result, "state": state})
            except AppError as exc:
                self._json({"ok": False, "error": exc.message, "code": exc.code}, 400)
            except (KeyError, TypeError, ValueError):
                self._json({"ok": False, "error": "请求格式无效。", "code": "invalid"}, 400)
            except OSError:
                self._json({'ok': False, 'error': '无法完成本机文件操作。', 'code': 'io'}, 400)

    def _action(self, path: str, payload: dict):
        store = self.server.store
        if path in {'/api/accounts/refresh', '/api/accounts/refresh-all', '/api/accounts/test', '/api/refresh-due'}:
            return dispatch(store, path, payload)
        if path == '/api/discovery/add':
            provider = payload.get('provider')
            return {'ids': self.server.discover(force=True, provider=provider if isinstance(provider, str) else None)}
        if path == '/api/updates/check':
            return self.server.check_updates()
        if path == '/api/updates/download':
            return self.server.download_update()
        if path in {'/api/open/data', '/api/open/updates'}:
            target = store.directory if path.endswith('/data') else self.server.updates.directory
            if os.name != 'nt':
                raise AppError('此操作需要 Windows 资源管理器。')
            target.mkdir(parents=True, exist_ok=True)
            os.startfile(str(target))
            return {'path': str(target)}
        native = self.server.native
        if path.startswith('/api/choose/'):
            if native is None:
                raise AppError('文件选取器需要桌面窗口。请直接填写本机路径。', 'desktop_required')
            if path not in {'/api/choose/snapshot', '/api/choose/directory'}:
                raise AppError('没有这个文件选取器。')
            return {'path': native.choose(path.rsplit('/', 1)[1])}
        if path == '/api/window/open':
            fragment = app_fragment(payload.get('page') or 'overview', payload.get('account') or '')
            if native is None:
                raise AppError('此操作需要桌面窗口。', 'desktop_required')
            native.open_main(fragment)
            return {'opened': True}
        if path == '/api/panel/size':
            if native is not None:
                native.size_panel(payload)
            return {'ok': True}
        if path.startswith('/api/usage/'):
            usage = self._require_usage()
            if path == '/api/usage/settings':
                return usage.save_settings(payload)
            if path == '/api/usage/scan':
                return usage.scan(store.now(), store.zone)
            if path == '/api/usage/import':
                return usage.import_archive(payload)
            if path == '/api/usage/prices':
                return usage.refresh_public_prices(store.now())
        with self.server.lock:
            return dispatch(store, path, payload)

    def _usage(self, query: dict) -> None:
        key = query.get("range", ["7d"])[0]
        provider = query.get("provider", [""])[0]
        with self.server.lock:
            rows = self.server.store.usage_rows(key, provider)
        data = {'rows': rows}
        if self.server.local_usage is not None:
            try:
                store = self.server.store
                offset = max(0, int(query.get('offset', ['0'])[0]))
                data.update(self.server.local_usage.dashboard(key, store.now(), store.zone, offset=offset))
            except (AppError, ValueError) as exc:
                self._json({'error': getattr(exc, 'message', '用量范围无效。')}, 400)
                return
        self._json(data)

    def _require_usage(self):
        if self.server.local_usage is None:
            raise AppError('没有启用本机用量服务。')
        return self.server.local_usage

    def _extra_get(self, path: str, query: dict) -> None:
        store = self.server.store
        if path == '/api/discovery':
            discovery = self.server.discovery
            observations = discovery.observations(force=query.get('rescan') == ['1']) if discovery is not None else []
            self._json({'observations': observations, 'completed': bool(discovery and discovery.completed)})
        elif path == '/api/native':
            native = self.server.native
            self._json({'desktop': native is not None, 'cliPath': native.cli_path if native is not None else None,
                        'ready': bool(native and native.ready and native.panel_ready),
                        'trayRegistered': bool(native and native.tray.registered)})
        elif path == '/api/updates':
            update = self.server.updates
            self._json(update.public_state if update.source == store.settings['updateAppcastURL'] else {'status': 'unconfigured'})
        elif path == '/api/panel':
            with self.server.lock:
                self._json(store.panel_state())
        elif path == '/api/usage/settings':
            self._json(self._require_usage().settings_state())
        elif path == '/api/export/local-usage.csv':
            key = query.get('range', ['all'])[0]
            result = self._require_usage().export_csv(key, store.now(), store.zone)
            self._bytes(result, 'text/csv; charset=utf-8')
        elif path == '/api/export/local-usage.json':
            result = self._require_usage().export_json(store.now(), store.zone)
            if not isinstance(result, bytes):
                result = json.dumps(result, ensure_ascii=False).encode('utf-8')
            self._bytes(result, 'application/json; charset=utf-8')

    def _brand(self, path: str) -> None:
        if path == '/translations.tsv':
            asset = brand_dir() / 'Translations.tsv'
        elif path == '/brand/GaoCiYuanIcon.png':
            asset = brand_dir() / 'GaoCiYuanIcon.png'
        elif path == '/brand/claude-native-white-flower.png':
            asset = brand_dir() / 'PanelIcons' / 'claude-native-white-flower.png'
        elif re.fullmatch(r'/brand/[a-z0-9]+\.png', path):
            asset = brand_dir() / 'ProviderIcons' / path.rsplit('/', 1)[1]
        else:
            self.send_error(404)
            return
        if not asset.is_file():
            self.send_error(404)
            return
        self._bytes(asset.read_bytes(), 'image/png' if asset.suffix == '.png' else 'text/tab-separated-values; charset=utf-8')

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

    def _accounts_csv(self) -> None:
        if not self._authorized():
            return
        rows = []
        with self.server.lock:
            for account in self.server.store.library['accounts']:
                snapshot = account.get('snapshot') or {}
                rows.append({'account': account['name'], 'provider': account['provider'], 'plan': account['plan'],
                             'source': snapshot.get('source'), 'observedAt': snapshot.get('observedAt'),
                             'quotas': json.dumps(snapshot.get('quotas', []), ensure_ascii=False),
                             'balances': json.dumps(snapshot.get('balances', []), ensure_ascii=False)})
        self._bytes(csv_bytes(['account', 'provider', 'plan', 'source', 'observedAt', 'quotas', 'balances'], rows), 'text/csv; charset=utf-8')

    def _page(self, name: str) -> None:
        html = (asset_dir() / name).read_text(encoding="utf-8")
        html = html.replace("{{TOKEN}}", self.server.token).replace("{{VERSION}}", VERSION_LABEL)
        self._bytes(html.encode("utf-8"), "text/html; charset=utf-8")

    def _authorized(self) -> bool:
        if self.headers.get("X-Gao-Token") == self.server.token:
            return True
        self._json({"error": "缺少本机会话令牌。"}, 403)
        return False

    def _same_host(self) -> bool:
        host = self.server.url.split('/')[2]
        if self.headers.get('Host') == host and self.headers.get('Origin') in (None, f'http://{host}'):
            return True
        self._json({'error': '仅接受本机窗口请求。'}, 403)
        return False

    def _body(self) -> dict:
        length = int(self.headers.get("Content-Length") or 0)
        limit = 64 * 1024 * 1024 if self.path == '/api/usage/import' else 2_000_000
        if not 0 <= length <= limit:
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
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('Referrer-Policy', 'no-referrer')
        self.send_header('Content-Security-Policy', "default-src 'self'; img-src 'self' data: blob:; style-src 'self' 'unsafe-inline'; object-src 'none'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'")
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
    if path == '/api/accounts/refresh-all':
        return {'ids': store.refresh_all()}
    if path == '/api/accounts/test':
        return store.test_account(payload)
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


def serve(store: TokenStore, port: int = 0, open_browser: bool = True, start_timer: bool = True, *, local_usage=None, discovery=None) -> TokenServer:
    server = TokenServer(store, port=port, local_usage=local_usage, discovery=discovery)
    thread = threading.Thread(target=server.serve_forever, name="gaociyuan-http", daemon=True)
    thread.start()
    if start_timer:
        threading.Thread(target=_timer, args=(server,), name="gaociyuan-refresh", daemon=True).start()
        threading.Thread(target=_update_timer, args=(server,), name='gaociyuan-updates', daemon=True).start()
    if open_browser:
        import webbrowser

        webbrowser.open(server.url)
    return server


def _timer(server: TokenServer) -> None:
    while not server.shutdown_requested.wait(60):
        with server.work() as admitted:
            if not admitted:
                return
            try:
                server.store.refresh_due()
            except (AppError, OSError):
                pass
            if (not server.shutdown_requested.is_set() and server.local_usage is not None
                    and not server.store.load_failed and server.store.library.get('autoRefresh', True)):
                try:
                    server.local_usage.scan(server.store.now(), server.store.zone, automatic=True)
                except (AppError, OSError):
                    pass


def _update_timer(server: TokenServer) -> None:
    last_attempt = float('-inf')
    previous = ''
    while not server.shutdown_requested.wait(30):
        source = server.store.settings['updateAppcastURL']
        if source and (source != previous or time.monotonic() - last_attempt >= 7200):
            previous = source
            last_attempt = time.monotonic()
            with server.work() as admitted:
                if not admitted:
                    return
                try:
                    server.check_updates()
                except AppError:
                    pass
