"""命令行入口。窗口版与命令行版共用这些参数。"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from gaociyuan.credentials import open_credential_store
from gaociyuan.errors import AppError
from gaociyuan.store import TokenStore
from gaociyuan.timeutil import default_data_dir
from gaociyuan.version import VERSION_LABEL
from gaociyuan.web import serve


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="GaoCiYuan", description="搞词元 Windows 版")
    parser.add_argument("--version", action="store_true")
    parser.add_argument("--data-dir", default=None)
    parser.add_argument("--serve", action="store_true")
    parser.add_argument("--no-browser", action="store_true")
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--create-empty", action="store_true")
    parser.add_argument("--inspect", action="store_true")
    parser.add_argument("--no-refresh", action="store_true")
    args = parser.parse_args(argv)
    if args.version:
        print(VERSION_LABEL)
        return 0
    directory = default_data_dir() if not args.data_dir else Path(args.data_dir)
    store = TokenStore(directory, credentials=open_credential_store(directory))
    try:
        if args.create_empty:
            store.create_library()
            if not args.serve and not args.inspect:
                print("created")
                return 0
        if args.inspect:
            _print_summary(store)
            if not args.serve:
                return 0
    except AppError as exc:
        print(exc.message, file=sys.stderr)
        return 2
    server = serve(store, port=args.port, open_browser=not args.no_browser, start_timer=not args.no_refresh)
    try:
        server.shutdown_requested.wait()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


def _print_summary(store: TokenStore) -> None:
    print(f"status={'readonly' if store.load_failed else 'ready'}")
    print(f"version={VERSION_LABEL}")
    print(f"accounts={len(store.library['accounts'])}")
    print(f"grokbot={store.grok_path}")
    print(f"credentials={store.credentials.backend}")
