"""命令行入口。窗口版与命令行版共用这些参数。"""

from __future__ import annotations

import argparse
import os
import sys
import threading
from pathlib import Path

from gaociyuan.antigravity_statusline import ACCOUNT_KEY, capture_antigravity_statusline
from gaociyuan.credentials import open_credential_store
from gaociyuan.errors import AppError
from gaociyuan.local_usage import LocalUsageService
from gaociyuan.providers import ProviderDiscovery, capture_claude_statusline, read_connector
from gaociyuan.routes import app_fragment, deep_link
from gaociyuan.store import TokenStore
from gaociyuan.timeutil import default_data_dir, utcnow
from gaociyuan.version import VERSION_LABEL
from gaociyuan.web import serve


def main(argv: list[str] | None = None, *, console: bool = False) -> int:
    parser = argparse.ArgumentParser(prog="GaoCiYuan", description="搞词元 Windows 版")
    parser.add_argument("--version", action="store_true")
    parser.add_argument("--data-dir", default=None)
    parser.add_argument("--serve", action="store_true")
    parser.add_argument("--no-browser", action="store_true")
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--create-empty", action="store_true")
    parser.add_argument("--inspect", action="store_true")
    parser.add_argument("--no-refresh", action="store_true")
    capture = parser.add_mutually_exclusive_group()
    capture.add_argument('--capture-claude-status', action='store_true')
    capture.add_argument('--capture-antigravity-status', action='store_true')
    parser.add_argument('--antigravity-account')
    parser.add_argument('--desktop-hidden', action='store_true', help=argparse.SUPPRESS)
    parser.add_argument('link', nargs='?')
    args = parser.parse_args(argv)
    if args.version:
        print(VERSION_LABEL)
        return 0
    if args.capture_antigravity_status and not ACCOUNT_KEY.fullmatch(args.antigravity_account or ""):
        parser.error('--capture-antigravity-status requires --antigravity-account with the linked account fingerprint')
    if args.antigravity_account and not args.capture_antigravity_status:
        parser.error('--antigravity-account requires --capture-antigravity-status')
    if console and not any((args.serve, args.no_browser, args.create_empty, args.inspect,
                            args.capture_claude_status, args.capture_antigravity_status, args.desktop_hidden)):
        parser.print_help()
        return 0
    directory = (default_data_dir() if not args.data_dir else Path(args.data_dir)).resolve()
    if args.capture_antigravity_status:
        try:
            capture_antigravity_statusline(sys.stdin.buffer, directory, utcnow(), args.antigravity_account)
            return 0
        except OSError:
            print("无法保存 Antigravity 状态栏读数。", file=sys.stderr)
            return 2
    if args.capture_claude_status:
        try:
            summary = capture_claude_statusline(sys.stdin.buffer, directory, utcnow())
            if summary:
                print(summary)
            return 0
        except (AppError, OSError) as exc:
            print(getattr(exc, 'message', '无法保存 Claude Code 状态栏读数。'), file=sys.stderr)
            return 2
    if args.desktop_hidden and (not args.data_dir or args.serve or args.no_browser):
        parser.error('--desktop-hidden requires an isolated --data-dir and the desktop host')
    try:
        fragment = deep_link(args.link) if args.link else app_fragment()
    except ValueError:
        parser.error('无效的搞词元深链。')
    desktop = os.name == 'nt' and (args.desktop_hidden or not (console or args.serve or args.no_browser))
    instance = None
    try:
        if desktop and not (args.create_empty or args.inspect):
            from gaociyuan.instance import Instance

            instance = Instance(directory)
            if not instance.primary:
                instance.activate(fragment if args.link else '')
                return 0
            from gaociyuan.webview_runtime import require_webview2

            require_webview2()
        credentials = open_credential_store(directory, system_store=not args.data_dir)
        store = TokenStore(directory, credentials=credentials)
        if args.create_empty:
            store.create_library()
            if not args.serve and not args.inspect:
                print("created")
                return 0
        if args.inspect:
            _print_summary(store)
            if not args.serve:
                return 0
        store.connector_reader = read_connector
        discovery = ProviderDiscovery(enabled=not args.data_dir and desktop)
        store.rail_visible = discovery.rail_visible
        local_usage = LocalUsageService(directory, allow_default_paths=not args.data_dir)
        server = serve(store, port=args.port, open_browser=not desktop and not args.no_browser,
                       start_timer=not args.no_refresh, local_usage=local_usage, discovery=discovery)
        try:
            if desktop:
                from gaociyuan.desktop import Desktop
                if discovery.enabled:
                    def discover_on_startup():
                        with server.work() as admitted:
                            if admitted:
                                server.discover()

                    threading.Thread(target=discover_on_startup, name='gaociyuan-discovery', daemon=True).start()
                Desktop(server, instance, fragment, args.desktop_hidden).start()
            else:
                server.shutdown_requested.wait()
        finally:
            server.request_shutdown()
            server.shutdown()
            server.server_close()
            server.drain_work()
    except (AppError, OSError) as exc:
        message = getattr(exc, 'message', '无法启动搞词元。请检查资料目录与运行环境。')
        if desktop and not args.desktop_hidden and not (args.inspect or args.create_empty):
            from gaociyuan.webview_runtime import startup_error

            startup_error(message)
        elif sys.stderr:
            print(message, file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        return 0
    finally:
        if instance is not None:
            instance.close()
    return 0


def _print_summary(store: TokenStore) -> None:
    print(f"status={'readonly' if store.load_failed else 'ready'}")
    print(f"version={VERSION_LABEL}")
    print(f"accounts={len(store.library['accounts'])}")
    print(f"grokbot={store.grok_path}")
    print(f"credentials={store.credentials.backend}")
