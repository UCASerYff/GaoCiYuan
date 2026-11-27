"""One Windows host owns the data folder and receives shell activation."""

from __future__ import annotations

import json
import os
import time
from pathlib import Path
from urllib.parse import parse_qs

from gaociyuan.routes import app_fragment


class Instance:
    def __init__(self, directory: Path):
        import msvcrt

        directory.mkdir(parents=True, exist_ok=True)
        self.lock_file = (directory / '.desktop.lock').open('a+b')
        self.queued = directory / '.desktop-route.json'
        self.lock_file.seek(0)
        try:
            msvcrt.locking(self.lock_file.fileno(), msvcrt.LK_NBLCK, 1)
            self.primary = True
        except OSError:
            self.primary = False

    def activate(self, fragment: str) -> None:
        nonce = f'{os.getpid()}-{time.monotonic_ns()}'
        temp = self.queued.with_name(f'.desktop-route-{nonce}.tmp')
        try:
            temp.write_text(json.dumps(fragment), encoding='utf-8')
            for attempt in range(5):
                try:
                    os.replace(temp, self.queued)
                    return
                except PermissionError:
                    if attempt == 4:
                        raise
                    time.sleep(.04)
        finally:
            temp.unlink(missing_ok=True)

    def read_route(self) -> str | None:
        pending = self.queued.with_name('.desktop-route-reading.json')
        try:
            self.queued.replace(pending)
        except (FileNotFoundError, PermissionError):
            return None
        try:
            value = json.loads(pending.read_text(encoding='utf-8'))
            if not isinstance(value, str) or not value.startswith('#'):
                return None
            page, _, query = value[1:].partition('?')
            return app_fragment(page, parse_qs(query).get('account', [''])[0])
        except (UnicodeError, ValueError):
            return None
        finally:
            pending.unlink(missing_ok=True)

    def close(self) -> None:
        self.lock_file.close()
