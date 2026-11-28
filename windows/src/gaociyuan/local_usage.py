"""Windows local-usage analytics, independent of quota snapshot history."""

from __future__ import annotations

from collections import defaultdict
import csv
import io
import json
import os
import sqlite3
import stat
import tempfile
import threading
from contextlib import contextmanager
from copy import deepcopy
from dataclasses import dataclass
from datetime import date, datetime, time, timedelta, timezone
from pathlib import Path
from uuid import UUID, uuid4
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from gaociyuan.errors import AppError
from gaociyuan.timeutil import parse_instant, utcnow
from gaociyuan.usage_scan import (
    AMOUNT_FIELDS,
    DEFAULT_IDS,
    MAX_COUNT,
    MAX_RECORDS,
    PRICE_FIELDS,
    SOURCES,
    SUPPORTED,
    TOKEN_FIELDS,
    UsageEvent,
    default_paths,
    digest,
    identifier,
    local_item,
    local_path,
    moment,
    price,
    scan_paths,
)

PAGE_SIZE = 50
MAX_ARCHIVE_SIZE = 64 * 1024 * 1024
MAX_DEVICES = 64
MAC_EVENT_CLIENTS = frozenset(("kimi", "antigravity"))
MAC_USAGE_ROWS = ("events", "coverageDays", "coverageSessions", "baselineDays", "baselineSessions")
COLUMNS = "input, output, cache_read, cache_write, reasoning, messages, cost"
SUMS = ", ".join(f"SUM({column})" for column in COLUMNS.split(", ")[:-1])
SUMS += ", CASE WHEN COUNT(*) = COUNT(cost) THEN SUM(cost) END"
EMPTY_AMOUNTS = {**dict.fromkeys(AMOUNT_FIELDS, 0), "totalTokens": 0, "costUSD": None}


def _atomic_bytes(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=path.parent, prefix=".usage-", delete=False) as stream:
            temporary = Path(stream.name)
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def _date_json(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z")


def _archive_date(value: str | None) -> str | None:
    if value is None:
        return None
    parsed = parse_instant(value)
    return parsed.strftime("%Y-%m-%dT%H:%M:%SZ") if parsed is not None else None


def _range(key: str, now: datetime, zone) -> tuple[date, date | None]:
    today = now.astimezone(zone).date()
    if key == "all":
        return today, None
    if key == "today":
        return today, today
    if key in ("7d", "week"):
        return today, today - timedelta(days=6)
    if key in ("30d", "month30"):
        return today, today - timedelta(days=29)
    if key in ("month", "calendarMonth"):
        return today, today.replace(day=1)
    raise AppError("用量统计时间范围无效。")


def _utc_boundary(day: date, zone) -> str:
    return _date_json(datetime.combine(day, time.min, tzinfo=zone))


def _amounts(values: tuple) -> dict:
    result = dict(zip(AMOUNT_FIELDS, values))
    result["totalTokens"] = sum(result[key] for key in TOKEN_FIELDS)
    return result


def _add(total: dict, amounts: dict) -> dict:
    for key in (*TOKEN_FIELDS, "totalTokens", "messageCount"):
        total[key] += amounts[key]
    left, right = total["costUSD"], amounts["costUSD"]
    total["costUSD"] = left + right if left is not None and right is not None else None
    return total


def _group(groups: dict, key: str, label: str, amounts: dict) -> None:
    if key not in groups:
        groups[key] = {"key": key, "name": label, "amounts": amounts.copy()}
    else:
        _add(groups[key]["amounts"], amounts)


def _rank(groups: dict) -> list:
    return sorted(groups.values(), key=lambda item: (-item["amounts"]["totalTokens"], item["name"].casefold(), item["key"]))


def _defaults() -> dict:
    return {
        "engine": {"enabledClientIDs": list(DEFAULT_IDS), "customPaths": {}, "modelPrices": []},
        "automaticallyScan": True,
        "refreshMinutes": 5,
        "automaticExportPath": None,
        "authorized": False,
    }


def _rates(candidate: object) -> list[dict]:
    if not isinstance(candidate, list) or len(candidate) > 500:
        raise AppError("自定义模型价格最多保存 500 项。")
    result = []
    models = set()
    for raw in candidate:
        if not isinstance(raw, dict) or not (model := identifier(raw.get("model"))) or model in models:
            raise AppError("请输入唯一的模型名称（最多 300 字）。")
        values = {key: price(raw.get(key)) for key in PRICE_FIELDS}
        if any(raw.get(key) not in (None, "") and values[key] is None for key in values):
            raise AppError("模型价格须为有限的非负数。")
        if all(values[key] is None for key in PRICE_FIELDS[:2]):
            raise AppError("模型价格至少填写一项输入或输出费率，免费请填 0。")
        models.add(model)
        result.append({"model": model, **values})
    return result


def _source_paths(candidate: object) -> dict[str, list[str]]:
    if not isinstance(candidate, dict) or any(key not in SUPPORTED for key in candidate):
        raise AppError("采集目录所属工具无效。")
    result = {}
    for key, values in candidate.items():
        if not isinstance(values, list) or len(values) > 16:
            raise AppError("每种工具最多添加 16 个目录或日志文件。")
        unique_paths = {}
        for value in values:
            normalized = local_path(value.strip()) if isinstance(value, str) else None
            if normalized is None:
                raise AppError("请选择本地磁盘上的绝对目录或日志文件路径。")
            unique_paths[os.path.normcase(str(normalized))] = str(normalized)
        if unique_paths:
            result[key] = list(unique_paths.values())
    return result


def _settings(candidate: object, existing: dict, directory: Path) -> dict:
    if not isinstance(candidate, dict) or not isinstance(candidate.get("engine", {}), dict):
        raise AppError("用量采集设置格式无效。")
    engine = {**existing["engine"], **candidate.get("engine", {})}
    sources = engine["enabledClientIDs"]
    if not isinstance(sources, list) or any(not isinstance(item, str) or item not in SUPPORTED for item in sources):
        raise AppError("请选择 Windows 版支持的本机采集工具。")
    cadence = candidate.get("refreshMinutes", existing["refreshMinutes"])
    automatic = candidate.get("automaticallyScan", existing["automaticallyScan"])
    if type(cadence) is not int or not 2 <= cadence <= 60 or type(automatic) is not bool:
        raise AppError("自动采集间隔应为 2–60 分钟。")
    export = candidate.get("automaticExportPath", existing["automaticExportPath"])
    if export:
        folder = local_path(export.strip()) if isinstance(export, str) else None
        try:
            info = local_item(folder) if folder is not None else None
        except OSError:
            info = None
        if info is None or not stat.S_ISDIR(info.st_mode):
            raise AppError("请选择已存在的本机导出文件夹。")
        if folder.resolve().is_relative_to(directory.resolve()):
            raise AppError("请将用量导出保存在应用数据目录之外。")
        export = str(folder)
    paths = _source_paths(engine["customPaths"])
    return {
        "engine": {"enabledClientIDs": list(dict.fromkeys(sources)), "customPaths": paths, "modelPrices": _rates(engine["modelPrices"])},
        "automaticallyScan": automatic,
        "refreshMinutes": cadence,
        "automaticExportPath": export or None,
        "authorized": bool(existing["authorized"]),
    }


def _stored_settings(raw: object, defaults: dict, directory: Path) -> dict:
    if not isinstance(raw, dict) or not raw.keys() <= defaults.keys():
        raise ValueError("invalid usage settings")
    engine = raw.get("engine", {})
    if not isinstance(engine, dict) or not engine.keys() <= defaults["engine"].keys():
        raise ValueError("invalid usage engine settings")
    authorized = raw.get("authorized", False)
    if type(authorized) is not bool:
        raise ValueError("invalid usage authorization")
    export = raw.get("automaticExportPath")
    if export is not None:
        # A saved local drive may be disconnected. Check the saved path's shape
        # now and its drive, directory and ancestry before any export writes.
        if (not isinstance(export, str) or not export or len(export) > 4096
                or export.startswith(("\\\\", "//")) or any(ord(char) < 32 for char in export)):
            raise ValueError("invalid usage export path")
        path = Path(export)
        if not path.is_absolute() or ":" in str(path)[len(path.drive):]:
            raise ValueError("invalid usage export path")
    validated = _settings({**raw, "automaticExportPath": None}, defaults, directory)
    return {**validated, "authorized": authorized, "automaticExportPath": export}


def _record_cost(record: UsageEvent, custom: dict, public: dict) -> float | None:
    rates = custom.get(record.model, {})
    if not rates and record.cost is not None:
        return record.cost
    fallback = public.get(record.model, {})
    incoming, outgoing, read, write, reasoning = record.tokens
    billable = (incoming, outgoing + reasoning, read, write - record.cache_write_1h, record.cache_write_1h)
    cost = 0.0
    for tokens, key in zip(billable, PRICE_FIELDS):
        if not tokens:
            continue
        rate = rates.get(key)
        if rate is None:
            rate = fallback.get(key)
        if rate is None:
            return record.cost
        cost += (tokens / 1_000_000) * rate
    return price(cost) if record.total else record.cost


class LocalUsageService:
    def __init__(self, directory: Path, *, allow_default_paths: bool = True):
        self.directory = Path(directory)
        self.path = self.directory / "local-usage.sqlite"
        self.settings_path = self.directory / "windows-usage-settings.json"
        self.allow_default_paths = allow_default_paths
        self._settings = _defaults()
        self._settings_error = None
        self._settings_source = None
        self._lock = threading.RLock()
        self._scan_lock = threading.Lock()
        self._revision = 0
        self._last_attempt = None
        self._warnings = None
        try:
            source = self._read_settings_data()
            if source is not None:
                self._settings = _stored_settings(json.loads(source.decode("utf-8")), self._settings, self.directory)
                self._settings_source = source
        except (AppError, OSError, ValueError, TypeError, RecursionError):
            self._settings_error = "用量采集设置读取失败，原文件已保留。"

    def settings_state(self) -> dict:
        with self._lock:
            config = deepcopy(self._settings)
            config["error"] = self._settings_error
        config["sources"] = []
        for source in SOURCES:
            paths = default_paths(source, allow_default_paths=self.allow_default_paths)
            extra = [Path(value) for value in config["engine"]["customPaths"].get(source.id, [])]
            detected = False
            for path in (() if config["error"] else (*paths, *extra)):
                try:
                    if local_item(path) is not None:
                        detected = True
                        break
                except OSError:
                    continue
            config["sources"].append({"id": source.id, "name": source.name, "supported": source.supported,
                                      "defaultEnabled": source.id in DEFAULT_IDS, "supportsCustomPaths": source.supported,
                                      "paths": [str(path) for path in paths], "detected": detected})
        return config

    def save_settings(self, candidate: dict) -> dict:
        with self._lock:
            if self._settings_error:
                raise AppError(self._settings_error, "usage-settings")
            next_settings = _settings(candidate, self._settings, self.directory)
            next_settings["authorized"] = True
            self._write_settings(next_settings)
            self._revision += 1
            self._settings = next_settings
        return self.settings_state()

    def _read_settings_data(self) -> bytes | None:
        try:
            info = local_item(self.settings_path)
        except FileNotFoundError:
            return None
        limit = 2_000_000
        if info is None or not stat.S_ISREG(info.st_mode) or info.st_size > limit:
            raise ValueError("invalid preferences file")
        with self.settings_path.open("rb") as stream:
            source = stream.read(limit + 1)
        if len(source) > limit:
            raise ValueError("invalid preferences file")
        return source

    def _write_settings(self, settings: dict) -> None:
        try:
            unchanged = self._read_settings_data() == self._settings_source
        except (OSError, ValueError):
            unchanged = False
        if not unchanged:
            self._settings_error = "用量采集设置已在应用外更改或无法读取，原文件已保留。"
            self._revision += 1
            raise AppError(self._settings_error, "usage-settings")
        source = json.dumps(settings, ensure_ascii=False, indent=2).encode("utf-8")
        try:
            _atomic_bytes(self.settings_path, source)
        except OSError as error:
            raise AppError("用量采集设置无法保存。", "usage-settings") from error
        self._settings_source = source

    @contextmanager
    def _db(self, *, create: bool = False):
        if not self.path.exists() and not create:
            yield None
            return
        conn = None
        try:
            self.directory.mkdir(parents=True, exist_ok=True)
            if self.path.exists() or self.path.is_symlink():
                info = local_item(self.path)
                if info is None or not stat.S_ISREG(info.st_mode):
                    raise AppError("本机用量数据库路径无法读取。", "usage-database")
            conn = sqlite3.connect(self.path)
            if create:
                self._create_tables(conn)
            with conn:
                yield conn
        except (sqlite3.DatabaseError, OSError) as error:
            raise AppError("本机用量数据库无法读取或写入，已有历史保持不变。", "usage-database") from error
        finally:
            if conn is not None:
                conn.close()

    @staticmethod
    def _create_tables(conn: sqlite3.Connection) -> None:
        conn.executescript("""
            CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS devices (id TEXT PRIMARY KEY, label TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS scan_stamps (path_key TEXT PRIMARY KEY, stamp TEXT NOT NULL, records INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS local_events (
                id TEXT PRIMARY KEY, at TEXT NOT NULL, client TEXT NOT NULL, session TEXT NOT NULL, model TEXT NOT NULL,
                project_key TEXT, project_label TEXT, duration INTEGER NOT NULL, write_1h INTEGER NOT NULL, recorded_cost REAL,
                input INTEGER NOT NULL, output INTEGER NOT NULL, cache_read INTEGER NOT NULL, cache_write INTEGER NOT NULL,
                reasoning INTEGER NOT NULL, messages INTEGER NOT NULL, cost REAL
            );
            CREATE INDEX IF NOT EXISTS local_events_at ON local_events(at);
            CREATE TABLE IF NOT EXISTS imported_days (
                device TEXT NOT NULL, day TEXT NOT NULL, client TEXT NOT NULL, session TEXT NOT NULL, model TEXT NOT NULL,
                input INTEGER, output INTEGER, cache_read INTEGER, cache_write INTEGER, reasoning INTEGER, messages INTEGER, cost REAL,
                PRIMARY KEY (device, day, client, session, model)
            );
            CREATE INDEX IF NOT EXISTS imported_days_day ON imported_days(day);
            CREATE TABLE IF NOT EXISTS imported_sessions (
                device TEXT NOT NULL, client TEXT NOT NULL, session TEXT NOT NULL, model TEXT NOT NULL, project_key TEXT,
                project_label TEXT, first_at TEXT, last_at TEXT, timed_tokens INTEGER, duration INTEGER,
                input INTEGER, output INTEGER, cache_read INTEGER, cache_write INTEGER, reasoning INTEGER, messages INTEGER, cost REAL,
                PRIMARY KEY (device, client, session, model)
            );
            CREATE TABLE IF NOT EXISTS cursor_events (
                device TEXT NOT NULL, account_key TEXT NOT NULL, id TEXT NOT NULL, at TEXT NOT NULL,
                session TEXT NOT NULL, model TEXT NOT NULL,
                input INTEGER, output INTEGER, cache_read INTEGER, cache_write INTEGER, reasoning INTEGER, messages INTEGER, cost REAL,
                PRIMARY KEY (account_key, id)
            );
            CREATE INDEX IF NOT EXISTS cursor_events_at ON cursor_events(at);
            CREATE TABLE IF NOT EXISTS mac_archive_usage (
                device TEXT PRIMARY KEY, source_id TEXT NOT NULL, payload TEXT NOT NULL
            );
        """)

    @staticmethod
    def _metadata(conn) -> dict:
        return dict(conn.execute("SELECT key, value FROM metadata")) if conn is not None else {}

    @staticmethod
    def _put(conn, key: str, value: str) -> None:
        conn.execute("INSERT INTO metadata VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", (key, value))

    @classmethod
    def _device(cls, conn: sqlite3.Connection, meta: dict) -> str:
        device = meta.get("deviceID") or str(uuid4())
        if "deviceID" not in meta:
            cls._put(conn, "deviceID", device)
            conn.execute("INSERT INTO devices VALUES (?, ?)", (device, "这台 Windows"))
        return device

    def scan(self, now: datetime, zone, *, automatic: bool = False) -> dict:
        if not self._scan_lock.acquire(blocking=False):
            if automatic:
                return {"skipped": True}
            raise AppError("正在采集本机用量。", "usage-busy")
        try:
            return self._scan(now, zone, automatic)
        except AppError as error:
            with self._lock:
                self._warnings = [error.message]
            if automatic:
                return {"skipped": True, "warnings": [error.message]}
            raise
        finally:
            self._scan_lock.release()

    def _scan(self, now: datetime, zone, automatic: bool) -> dict:
        with self._lock:
            settings = deepcopy(self._settings)
            if self._settings_error:
                raise AppError(self._settings_error, "usage-settings")
            if automatic:
                if not settings["authorized"] or not settings["automaticallyScan"]:
                    return {"skipped": True}
                with self._db() as conn:
                    previous = parse_instant(self._metadata(conn).get("lastScanAt"))
                last_attempt = self._last_attempt or previous
                if last_attempt and now - last_attempt < timedelta(minutes=settings["refreshMinutes"]):
                    return {"skipped": True}
            elif not settings["authorized"]:
                settings["authorized"] = True
                self._write_settings(settings)
                self._settings = settings
            self._last_attempt = now
            revision = self._revision
            with self._db() as conn:
                known = {}
                if conn is not None and conn.execute("SELECT 1 FROM sqlite_master WHERE name='scan_stamps'").fetchone():
                    known = {key: (stamp, count) for key, stamp, count in conn.execute("SELECT path_key, stamp, records FROM scan_stamps")}
        engine = settings["engine"]
        paths = {key: default_paths(SUPPORTED[key], allow_default_paths=self.allow_default_paths) +
                 [Path(value) for value in engine["customPaths"].get(key, [])] for key in engine["enabledClientIDs"]}
        result = scan_paths(paths, now, known)
        warnings = result.warnings
        custom = {item["model"]: item for item in engine["modelPrices"]}
        public, price_warnings = self._public_rates(now)
        warnings.extend(price_warnings)
        with self._lock:
            if revision != self._revision:
                raise AppError("采集设置已更改，请按新设置重新采集。", "usage-settings")
            with self._db(create=True) as conn:
                metadata = self._metadata(conn)
                device = self._device(conn, metadata)
                self._save_events(conn, result.events, custom, public, metadata)
                conn.execute("DELETE FROM scan_stamps")
                conn.executemany("INSERT INTO scan_stamps VALUES (?,?,?)", ((key, *entry) for key, entry in result.stamps.items()))
                if conn.execute("SELECT 1 FROM local_events WHERE cost IS NULL LIMIT 1").fetchone():
                    warnings.append("部分模型没有完整的可验证价格，相关费用显示为未定价。")
                if conn.execute("SELECT 1 FROM local_events WHERE client = 'hermes' LIMIT 1").fetchone():
                    warnings.append("Hermes Agent 按会话保存总量，跨日会话归入启动当天。")
                captured = _date_json(now)
                self._put(conn, "lastScanAt", captured)
                self._put(conn, "zone", getattr(zone, "key", "UTC"))
                self._put(conn, "warnings", json.dumps(warnings, ensure_ascii=False))
            self._warnings = warnings
            if settings["automaticExportPath"]:
                try:
                    export_dir = local_path(settings["automaticExportPath"])
                    if (export_dir is None or local_item(export_dir) is None or not export_dir.is_dir()
                            or export_dir.resolve().is_relative_to(self.directory.resolve())):
                        raise OSError("invalid export path")
                    _atomic_bytes(export_dir / f"搞词元-用量-{device}.json", self.export_json(now, zone))
                except (AppError, OSError):
                    self._warnings = [*warnings, "用量已保存，自动导出的文件夹不可用或导出失败。"]
            return {"lastScanAt": captured, "eventCount": len(result.events), "warnings": self._warnings}

    @staticmethod
    def _save_events(conn, events: dict[str, UsageEvent], custom: dict, public: dict, metadata: dict) -> None:
        spec = digest(custom, public)
        upsert = """
            INSERT INTO local_events VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET at = MIN(local_events.at, excluded.at),
                model = CASE WHEN excluded.model = 'unknown' THEN local_events.model ELSE excluded.model END,
                project_key = COALESCE(excluded.project_key, local_events.project_key),
                project_label = COALESCE(excluded.project_label, local_events.project_label),
                duration = MAX(excluded.duration, local_events.duration),
                write_1h = excluded.write_1h,
                recorded_cost = COALESCE(excluded.recorded_cost, local_events.recorded_cost),
                input = excluded.input, output = excluded.output, cache_read = excluded.cache_read,
                cache_write = excluded.cache_write, reasoning = excluded.reasoning,
                messages = MAX(local_events.messages, excluded.messages), cost = excluded.cost
            WHERE excluded.input + excluded.output + excluded.cache_read + excluded.cache_write + excluded.reasoning
                  >= local_events.input + local_events.output + local_events.cache_read + local_events.cache_write + local_events.reasoning
              AND (excluded.model != 'unknown' OR local_events.model = 'unknown')
        """
        conn.executemany(upsert, ((record.id, _date_json(record.at), record.client, record.session, record.model, *record.cwd,
                                    record.duration, record.cache_write_1h, record.cost, *record.tokens, record.messages,
                                    _record_cost(record, custom, public)) for record in events.values()))
        if metadata.get("priceSignature") != spec:
            rows = conn.execute("SELECT id, model, write_1h, recorded_cost, input, output, cache_read, cache_write, reasoning FROM local_events")
            for event_id, model, write_1h, cost, *tokens in rows:
                sample = UsageEvent(event_id, "", "", model, datetime.min, tuple(tokens), cost=cost, cache_write_1h=write_1h)
                conn.execute("UPDATE local_events SET cost = ? WHERE id = ?", (_record_cost(sample, custom, public), event_id))
            LocalUsageService._put(conn, "priceSignature", spec)

    def _public_rates(self, now: datetime) -> tuple[dict, list]:
        from gaociyuan.usage_prices import cached_rates

        return cached_rates(self.directory, now)

    def refresh_public_prices(self, now: datetime) -> dict:
        from gaociyuan.usage_prices import refresh_prices

        return refresh_prices(self.directory, now)

    @staticmethod
    def _sources(conn, metadata: dict, zone):
        conn.create_function("usage_day", 1, lambda text: parse_instant(text).astimezone(zone).date().isoformat(), deterministic=True)
        return metadata.get("deviceID", "")

    @classmethod
    def _day_rows(cls, conn, metadata: dict, zone, start: date | None, end: date | None):
        if conn is None:
            return iter(())
        device = cls._sources(conn, metadata, zone)
        min_day = start.isoformat() if start else "0001-01-01"
        max_day = end.isoformat() if end else "9999-12-31"
        min_date = _utc_boundary(start, zone) if start else ""
        max_date = _utc_boundary(end + timedelta(days=1), zone) if end else "9999-12-31"
        return conn.execute(f"""
            SELECT device, day, client, session, model, {COLUMNS} FROM imported_days WHERE day BETWEEN ? AND ?
            UNION ALL
            SELECT ?, usage_day(at), client, session, model, {SUMS} FROM local_events
                WHERE at >= ? AND at < ? GROUP BY usage_day(at), client, session, model
            UNION ALL
            SELECT device, usage_day(at), 'cursor', session, model, {SUMS} FROM cursor_events
                WHERE at >= ? AND at < ? GROUP BY device, usage_day(at), session, model
        """, (min_day, max_day, device, min_date, max_date, min_date, max_date))

    @classmethod
    def _session_rows(cls, conn, metadata: dict):
        if conn is None:
            return iter(())
        return conn.execute(f"""
            SELECT device, client, session, model, project_key, project_label, first_at, last_at, timed_tokens, duration, {COLUMNS}
                FROM imported_sessions
            UNION ALL
            SELECT ?, client, session, model,
                   CASE WHEN COUNT(DISTINCT project_key) = 1 THEN MAX(project_key) END,
                   CASE WHEN COUNT(DISTINCT project_key) = 1 THEN MAX(project_label) END,
                   MIN(at), MAX(at), SUM(CASE WHEN duration > 0 THEN input + output + cache_read + cache_write + reasoning ELSE 0 END),
                   SUM(duration), {SUMS} FROM local_events GROUP BY client, session, model
            UNION ALL
            SELECT device, 'cursor', session, model, NULL, NULL, MIN(at), MAX(at), 0, 0, {SUMS}
                FROM cursor_events GROUP BY device, session, model
            ORDER BY last_at DESC, device, client, session, model
        """, (metadata.get("deviceID", ""),))

    @staticmethod
    def _session(row: tuple) -> dict:
        device, client, session, model, key, label, first, last, timed, duration, *amounts = row
        return {"deviceID": device, "client": client, "sessionID": session, "model": model,
                "projectKey": key, "projectLabel": label, "firstActive": first, "lastActive": last,
                "timedTokens": timed, "timedDurationMS": duration, "amounts": _amounts(tuple(amounts))}

    def dashboard(self, key: str, now: datetime, zone, offset: int = 0) -> dict:
        end, start = _range(key, now, zone)
        if type(offset) is not int or offset < 0:
            raise AppError("会话分页无效。")
        with self._lock, self._db() as conn:
            metadata = self._metadata(conn)
            devices = dict(conn.execute("SELECT id, label FROM devices")) if conn is not None else {}
            daily = {}
            for device, day, client, _, model, *values in self._day_rows(conn, metadata, zone, start, end):
                row_key = (device, day, client, model)
                amounts = _amounts(tuple(values))
                if row_key in daily:
                    _add(daily[row_key], amounts)
                else:
                    daily[row_key] = amounts
            total = EMPTY_AMOUNTS.copy()
            if daily:
                total["costUSD"] = 0.0
            by_client, by_model = {}, {}
            days = []
            for (device, day, client, model), amounts in sorted(daily.items()):
                _add(total, amounts)
                _group(by_client, client, client, amounts)
                _group(by_model, model, model, amounts)
                days.append({"deviceID": device, "deviceLabel": devices.get(device, device), "day": day,
                             "client": client, "model": model, "amounts": amounts})
            by_project, by_device = {}, {}
            sessions = []
            total_count = 0
            for index, entry in enumerate(self._session_rows(conn, metadata)):
                row = self._session(entry)
                device = row["deviceID"]
                device_label = devices.get(device, device)
                _group(by_project, row["projectKey"] or "", row["projectLabel"] or "未知项目", row["amounts"])
                _group(by_device, device, device_label, row["amounts"])
                if offset <= index < offset + PAGE_SIZE:
                    row["id"] = digest(device, row["client"], row["sessionID"], row["model"])
                    row["deviceLabel"] = device_label
                    sessions.append(row)
                total_count += 1
            warnings = self._warnings if self._warnings is not None else json.loads(metadata.get("warnings", "[]"))
            if self._settings_error and self._settings_error not in warnings:
                warnings = [*warnings, self._settings_error]
            return {"total": total, "days": days, "byClient": _rank(by_client), "byModel": _rank(by_model),
                    "sessionSummary": {"byProject": _rank(by_project), "byDevice": _rank(by_device)},
                    "sessions": {"rows": sessions, "totalCount": total_count, "offset": offset, "pageSize": PAGE_SIZE},
                    "lastScanAt": metadata.get("lastScanAt"), "warnings": warnings, "scanning": self._scan_lock.locked()}

    def export_csv(self, key: str, now: datetime, zone) -> bytes:
        end, start = _range(key, now, zone)
        buffer = io.StringIO()
        writer = csv.writer(buffer, lineterminator="\r\n")
        writer.writerow(("日期", "设备标识", "设备", "客户端", "模型", "会话", "输入 Token", "输出 Token", "缓存读取", "缓存写入", "推理 Token", "消息数", "估算美元费用"))
        with self._lock, self._db() as conn:
            metadata = self._metadata(conn)
            devices = dict(conn.execute("SELECT id, label FROM devices")) if conn is not None else {}
            for index, (device, day, client, session, model, *values) in enumerate(self._day_rows(conn, metadata, zone, start, end)):
                if index >= MAX_RECORDS or buffer.tell() > MAX_ARCHIVE_SIZE:
                    raise AppError("用量 CSV 超出大小上限，请缩小日期范围。", "usage-limit")
                fields = [day, device, devices.get(device, device), client, model, session, *values]
                writer.writerow(["'" + value if isinstance(value, str) and value[:1] in ("=", "+", "-", "@") else value for value in fields])
        return buffer.getvalue().encode("utf-8-sig")

    def export_json(self, now: datetime | None = None, zone=None) -> bytes:
        archive_format = 2
        with self._lock, self._db() as conn:
            metadata = self._metadata(conn)
            if zone is None:
                key = metadata.get("zone", "UTC")
                try:
                    zone = ZoneInfo(key) if key != "UTC" else timezone.utc
                except ZoneInfoNotFoundError:
                    zone = timezone.utc
            devices = {device: {"id": device, "name": label, "days": [], "sessions": [], "cursorEvents": []}
                       for device, label in conn.execute("SELECT id, label FROM devices")} if conn is not None else {}
            if len(devices) > MAX_DEVICES:
                raise AppError("设备数量超出单个用量包上限。", "usage-limit")
            records = 0
            for device, day, client, session, model, *values in self._day_rows(conn, metadata, zone, None, None):
                records += 1
                if records > MAX_RECORDS:
                    raise AppError("用量 JSON 超过 20 万条记录。", "usage-limit")
                devices[device]["days"].append({"day": day, "client": client, "sessionID": session, "model": model,
                                                "amounts": _amounts(tuple(values))})
            for entry in self._session_rows(conn, metadata):
                records += 1
                if records > MAX_RECORDS:
                    raise AppError("用量 JSON 超过 20 万条记录。", "usage-limit")
                row = self._session(entry)
                device = row.pop("deviceID")
                for key in ("firstActive", "lastActive"):
                    row[key] = _archive_date(row[key])
                devices[device]["sessions"].append(row)
            if conn is not None:
                for device, account_key, event_id, at, session, model, *values in conn.execute(f"SELECT device, account_key, id, at, session, model, {COLUMNS} FROM cursor_events"):
                    records += 1
                    if records > MAX_RECORDS:
                        raise AppError("用量 JSON 超过 20 万条记录。", "usage-limit")
                    devices[device]["cursorEvents"].append({"accountKey": account_key, "eventID": event_id, "timestamp": _archive_date(at),
                                                            "conversationID": session, "model": model, "amounts": _amounts(tuple(values))})
                if conn.execute("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'mac_archive_usage'").fetchone():
                    for device, source_id, saved in conn.execute("SELECT device, source_id, payload FROM mac_archive_usage"):
                        if device not in devices or source_id.lower() != device:
                            raise _invalid_archive()
                        batch, count = _stored_mac_usage(saved, limit=MAX_RECORDS - records)
                        devices[device]["id"] = source_id
                        devices[device]["localUsage"] = batch
                        archive_format = 4
                        records += count
        payload = {"format": archive_format, "exportedAt": _archive_date(_date_json(now or utcnow())), "devices": list(devices.values())}
        result = json.dumps(payload, ensure_ascii=False, separators=(",", ":"), allow_nan=False).encode("utf-8")
        if len(result) > MAX_ARCHIVE_SIZE:
            raise AppError("用量 JSON 超过 64 MB。", "usage-limit")
        return result

    def import_archive(self, payload: dict) -> dict:
        batches = _read_archive(payload)
        with self._lock, self._db(create=True) as conn:
            identifier = self._device(conn, self._metadata(conn))
            for batch in batches:
                if batch.device == identifier:
                    if batch.local_usage is not None:
                        raise _archive_conflict()
                    continue
                conn.execute("INSERT INTO devices VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET label = excluded.label", (batch.device, batch.label))
                days, sessions = _merge_mac_archive(conn, batch)
                conn.executemany(_import_sql("imported_days", "device, day, client, session, model", 12), days)
                conn.executemany(_import_sql("imported_sessions", "device, client, session, model", 17, session=True), sessions)
                conn.executemany("INSERT OR IGNORE INTO cursor_events VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)", batch.cursor)
        return {"deviceCount": len(batches), "dayCount": sum(len(batch.days) for batch in batches),
                "sessionCount": sum(len(batch.sessions) for batch in batches)}


@dataclass
class _ArchiveDevice:
    device: str
    source_id: str
    label: str
    days: list[tuple]
    sessions: list[tuple]
    cursor: list[tuple]
    local_usage: dict | None


def _import_sql(table: str, keys: str, columns: int, *, session: bool = False) -> str:
    counters = COLUMNS.split(", ")[:-1]
    update = [f"{key} = MAX({table}.{key}, excluded.{key})" for key in counters]
    known = " AND ".join(f"excluded.{key} >= {table}.{key}" for key in counters[:-1])
    update.append(f"cost = CASE WHEN {known} THEN excluded.cost ELSE MAX({table}.cost, excluded.cost) END")
    if session:
        update.extend((f"project_key = COALESCE(excluded.project_key, {table}.project_key)",
                       f"project_label = COALESCE(excluded.project_label, {table}.project_label)",
                       f"first_at = COALESCE(MIN({table}.first_at, excluded.first_at), {table}.first_at, excluded.first_at)",
                       f"last_at = COALESCE(MAX({table}.last_at, excluded.last_at), {table}.last_at, excluded.last_at)",
                       f"timed_tokens = MAX({table}.timed_tokens, excluded.timed_tokens)",
                       f"duration = MAX({table}.duration, excluded.duration)"))
    return f"INSERT INTO {table} VALUES ({','.join('?' for _ in range(columns))}) ON CONFLICT({keys}) DO UPDATE SET {', '.join(update)}"


def _invalid_archive() -> AppError:
    return AppError("用量包格式或记录无效，已有历史保持不变。", "usage-archive")


def _archive_conflict() -> AppError:
    return AppError("用量包与已保存的 Mac 用量来源记录不一致，无法安全合并。已有历史保持不变。", "usage-archive")


def _archive_text(value: object, *, limit: int = 1024, optional: bool = False) -> str | None:
    if value is None and optional:
        return None
    result = identifier(value, limit=limit)
    if not result:
        raise _invalid_archive()
    return result


def _archive_count(value: object) -> int:
    if type(value) is not int or not 0 <= value <= MAX_COUNT:
        raise _invalid_archive()
    return value


def _archive_amounts(row: dict) -> tuple:
    amounts = row.get("amounts")
    if not isinstance(amounts, dict):
        raise _invalid_archive()
    cost = amounts.get("costUSD")
    if cost is not None and price(cost) is None:
        raise _invalid_archive()
    return (*(_archive_count(amounts.get(key)) for key in AMOUNT_FIELDS[:-1]), cost)


def _archive_moment(value, *, optional: bool = False) -> str | None:
    parsed = moment(value) if isinstance(value, str) else None
    if parsed is None:
        if value is None and optional:
            return None
        raise _invalid_archive()
    if parsed.year < 1970 or parsed > utcnow() + timedelta(days=1):
        raise _invalid_archive()
    return _date_json(parsed)


def _archive_ids(row: dict) -> tuple[str, str, str]:
    return (_archive_text(row.get("client"), limit=100), _archive_text(row.get("sessionID")), _archive_text(row.get("model")))


def _archive_list(raw: dict, key: str, *, optional: bool = False) -> list[dict]:
    values = raw.get(key, [] if optional else None)
    if not isinstance(values, list) or any(not isinstance(row, dict) for row in values):
        raise _invalid_archive()
    return values


def _archive_day(row: dict, device: str) -> tuple:
    try:
        day = date.fromisoformat(row.get("day"))
    except (TypeError, ValueError):
        raise _invalid_archive() from None
    if day.isoformat() != row["day"]:
        raise _invalid_archive()
    return device, day.isoformat(), *_archive_ids(row), *_archive_amounts(row)


def _archive_session(row: dict, device: str) -> tuple:
    first = _archive_moment(row.get("firstActive"), optional=True)
    last = _archive_moment(row.get("lastActive"), optional=True)
    if first and last and first > last:
        raise _invalid_archive()
    label = _archive_text(row.get("projectLabel"), limit=160, optional=True)
    if label and any(char in label for char in "/\\"):
        raise _invalid_archive()
    project = _archive_text(row.get("projectKey"), optional=True)
    if project and not _sha256(project):
        project = digest(project)
    return (device, *_archive_ids(row), project, label, first, last,
            _archive_count(row.get("timedTokens")), _archive_count(row.get("timedDurationMS")), *_archive_amounts(row))


def _sha256(value: object) -> bool:
    return isinstance(value, str) and len(value) == 64 and all(char in "0123456789abcdef" for char in value)


def _versioned_fields(value: object, keys: tuple[str, ...]) -> None:
    if not isinstance(value, dict) or not value.keys() <= set(keys):
        raise _invalid_archive()


def _mac_source_text(value: object, *, limit: int = 1024) -> str:
    result = _archive_text(value, limit=limit)
    try:
        if value != result or len(result.encode("utf-8")) > limit:
            raise _invalid_archive()
    except UnicodeEncodeError as error:
        raise _invalid_archive() from error
    return result


def _mac_source_amounts(row: dict) -> dict:
    _versioned_fields(row.get("amounts"), (*AMOUNT_FIELDS, "totalTokens"))
    result = dict(zip(AMOUNT_FIELDS, _archive_amounts(row)))
    supplied = row["amounts"].get("totalTokens")
    if "totalTokens" in row["amounts"] and (type(supplied) is not int or supplied != sum(result[key] for key in TOKEN_FIELDS)):
        raise _invalid_archive()
    if result["costUSD"] is None:
        result.pop("costUSD")
    return result


def _mac_source_row(row: dict, clients: set[str], kind: str) -> dict:
    names = ("client", "sessionID", "model", "amounts")
    project_fields = ("projectKey", "projectLabel")
    if kind == "events":
        fields = (*names, "eventID", "timestamp", "durationMS", *project_fields)
    elif kind.endswith("Days"):
        fields = (*names, "day")
    else:
        fields = (*names, "firstActive", "lastActive", "timedTokens", "timedDurationMS", *project_fields)
    _versioned_fields(row, fields)
    client = _mac_source_text(row.get("client"), limit=100)
    if client not in clients:
        raise _invalid_archive()
    result = {"client": client, "sessionID": _mac_source_text(row.get("sessionID")),
              "model": _mac_source_text(row.get("model")),
              "amounts": _mac_source_amounts(row)}
    if kind == "events":
        if not _sha256(row.get("eventID")) or len(result["model"]) > 300:
            raise _invalid_archive()
        timestamp = _mac_source_date(row.get("timestamp"))
        if timestamp == "1970-01-01T00:00:00Z":
            raise _invalid_archive()
        result.update(eventID=row["eventID"], timestamp=timestamp, durationMS=_archive_count(row.get("durationMS")))
    elif kind.endswith("Days"):
        result["day"] = _archive_day(row, "")[1]
    else:
        first = _mac_source_date(row.get("firstActive"), optional=True)
        last = _mac_source_date(row.get("lastActive"), optional=True)
        if first and last and first > last:
            raise _invalid_archive()
        if first is not None:
            result["firstActive"] = first
        if last is not None:
            result["lastActive"] = last
        result.update(timedTokens=_archive_count(row.get("timedTokens")), timedDurationMS=_archive_count(row.get("timedDurationMS")))
    if row.get("projectKey") is not None:
        if not _sha256(row["projectKey"]):
            raise _invalid_archive()
        result["projectKey"] = row["projectKey"]
    if row.get("projectLabel") is not None:
        label = _mac_source_text(row["projectLabel"])
        if len(label) > 160 or "/" in label or "\\" in label:
            raise _invalid_archive()
        result["projectLabel"] = label
    return result


def _mac_source_date(value: object, *, optional: bool = False) -> str | None:
    stamp = _archive_moment(value, optional=optional)
    # Native Mac archive dates have whole-second precision. Do not truncate
    # unsupported input and accidentally change an event's provenance.
    if stamp is not None and ("." in value or "," in value):
        raise _invalid_archive()
    return _archive_date(stamp)


def _mac_row_key(row: dict, kind: str) -> tuple:
    if kind == "events":
        return row["client"], row["eventID"]
    key = row["client"], row["sessionID"], row["model"]
    return (row["day"], *key) if kind.endswith("Days") else key


def _read_mac_usage(raw: object, archive_format: int, *, limit: int) -> tuple[dict, int]:
    _versioned_fields(raw, ("clients", *MAC_USAGE_ROWS, "retainedUnknownEventIDs"))
    raw_clients = raw.get("clients")
    if (archive_format < 3 or not isinstance(raw_clients, list) or not 1 <= len(raw_clients) <= len(MAC_EVENT_CLIENTS)
            or any(not isinstance(client, str) or client not in MAC_EVENT_CLIENTS for client in raw_clients)
            or len(raw_clients) != len(set(raw_clients))):
        raise _invalid_archive()
    if archive_format < 4 and raw.get("retainedUnknownEventIDs") is not None:
        raise _invalid_archive()
    clients = set(raw_clients)
    retained = raw.get("retainedUnknownEventIDs")
    if retained is not None and (not isinstance(retained, list) or len(retained) > limit
                                 or not all(_sha256(event_id) for event_id in retained) or len(retained) != len(set(retained))):
        raise _invalid_archive()
    count = len(retained or [])
    parsed = {"clients": sorted(clients)}
    for kind in MAC_USAGE_ROWS:
        if kind.startswith("baseline") and raw.get(kind) is None:
            continue
        rows = _archive_list(raw, kind)
        count += len(rows)
        if count > limit:
            raise _invalid_archive()
        keyed = {}
        for row in rows:
            normalized = _mac_source_row(row, clients, kind)
            key = _mac_row_key(normalized, kind)
            if key in keyed:
                raise _invalid_archive()
            keyed[key] = normalized
        parsed[kind] = [keyed[key] for key in sorted(keyed)]
    if retained is not None:
        parsed["retainedUnknownEventIDs"] = sorted(retained)
        marked = set(retained)
        known = {event["eventID"]: event["sessionID"] for event in parsed["events"]
                 if event["client"] == "antigravity" and event["model"].lower() not in ("unknown", "gemini-default")}
        if not marked <= known.keys():
            raise _invalid_archive()
        protected_sessions = {known[event_id] for event_id in marked}
        for kind in ("baselineDays", "baselineSessions"):
            if any(row["client"] == "antigravity" and row["model"] == "unknown" and row["sessionID"] in protected_sessions
                   and (any(row["amounts"].values()) or row.get("timedTokens") or row.get("timedDurationMS")) for row in parsed.get(kind, [])):
                raise _archive_conflict()
    return parsed, count


def _stored_mac_usage(data: str, *, limit: int = MAX_RECORDS) -> tuple[dict, int]:
    try:
        return _read_mac_usage(json.loads(data), 4, limit=limit)
    except (ValueError, TypeError, RecursionError) as error:
        raise _invalid_archive() from error


def _amounts_cover(current: tuple, previous: tuple) -> bool:
    before, after = previous[:-1], current[:-1]
    return (all(new >= old for new, old in zip(after, before))
            and (after != before or previous[-1] is None or current[-1] == previous[-1]))


def _rows_cover(current, previous, *, sessions: bool = False) -> bool:
    key_length = 4 if sessions else 5
    existing = {row[:key_length]: row for row in current}
    for old in previous:
        new = existing.get(old[:key_length])
        if new is None or not _amounts_cover(new[-len(AMOUNT_FIELDS):], old[-len(AMOUNT_FIELDS):]):
            return False
        if sessions and (
            any(before is not None and before != after for before, after in zip(old[4:6], new[4:6]))
            or old[6] is not None and (new[6] is None or new[6] > old[6])
            or old[7] is not None and (new[7] is None or new[7] < old[7])
            or new[8] < old[8] or new[9] < old[9]
        ):
            return False
    return True


def _mac_usage_covers(current: dict, previous: dict) -> bool:
    if (not set(previous["clients"]) <= set(current["clients"])
            or not set(previous.get("retainedUnknownEventIDs", [])) <= set(current.get("retainedUnknownEventIDs", []))):
        return False
    events = {_mac_row_key(event, "events"): event for event in current["events"]}
    for old in previous["events"]:
        new = events.get(_mac_row_key(old, "events"))
        if (new is None or any(new.get(key) != old.get(key) for key in ("sessionID", "model", "timestamp", "projectKey", "projectLabel"))
                or new["durationMS"] < old["durationMS"] or not _amounts_cover(_archive_amounts(new), _archive_amounts(old))):
            return False
    for kind in MAC_USAGE_ROWS[1:]:
        sessions = kind.endswith("Sessions")
        parse = _archive_session if sessions else _archive_day
        if not _rows_cover((parse(row, "") for row in current.get(kind, [])),
                           (parse(row, "") for row in previous.get(kind, [])), sessions=sessions):
            return False
    return True


def _merge_mac_archive(conn: sqlite3.Connection, batch: _ArchiveDevice) -> tuple[list[tuple], list[tuple]]:
    current = batch.local_usage
    saved = conn.execute("SELECT source_id, payload FROM mac_archive_usage WHERE device = ?", (batch.device,)).fetchone()
    previous = _stored_mac_usage(saved[1])[0] if saved is not None else None
    if current is None and previous is None:
        return batch.days, batch.sessions
    if current is not None and saved is not None and saved[0] != batch.source_id:
        raise _archive_conflict()

    # Swift exports the complete source state for each device plus its materialized
    # day/session totals. Never add those totals to the same source's event records.
    managed = sorted(set((current or {}).get("clients", [])) | set((previous or {}).get("clients", [])))
    keys = ",".join("?" for _ in managed)
    where = f"WHERE device = ? AND client IN ({keys})"
    params = (batch.device, *managed)
    old_days = conn.execute(f"SELECT * FROM imported_days {where}", params).fetchall()
    old_sessions = conn.execute(f"SELECT * FROM imported_sessions {where}", params).fetchall()
    new_days = [row for row in batch.days if row[2] in managed]
    new_sessions = [row for row in batch.sessions if row[1] in managed]
    newer_rows = _rows_cover(new_days, old_days) and _rows_cover(new_sessions, old_sessions, sessions=True)
    older_rows = _rows_cover(old_days, new_days) and _rows_cover(old_sessions, new_sessions, sessions=True)

    # On a later legacy import, do not overwrite or add a managed observation.
    if current is None:
        if not older_rows:
            raise _archive_conflict()
    elif previous is None or _mac_usage_covers(current, previous):
        covers_new = previous is not None and _mac_usage_covers(previous, current)
        if not newer_rows or (covers_new and (not older_rows or previous != current)):
            raise _archive_conflict()
        if not covers_new:
            conn.execute(f"DELETE FROM imported_days {where}", params)
            conn.execute(f"DELETE FROM imported_sessions {where}", params)
            conn.executemany(_import_sql("imported_days", "device, day, client, session, model", 12), new_days)
            conn.executemany(_import_sql("imported_sessions", "device, client, session, model", 17, session=True), new_sessions)
            conn.execute("INSERT INTO mac_archive_usage VALUES (?, ?, ?) ON CONFLICT(device) DO UPDATE SET payload = excluded.payload",
                         (batch.device, batch.source_id, json.dumps(current, ensure_ascii=False, separators=(",", ":"), allow_nan=False)))
    elif not older_rows or not _mac_usage_covers(previous, current):
        raise _archive_conflict()

    return [row for row in batch.days if row[2] not in managed], [row for row in batch.sessions if row[1] not in managed]


def _validate_mac_projection(batch: dict, days: list[tuple], sessions: list[tuple]) -> None:
    # Check totals by original source session and model. The Mac's local time
    # zone decides the daily buckets, so Windows must not relabel those dates.
    counter_fields = AMOUNT_FIELDS[:-1]

    def add(groups: dict, key: tuple, counts) -> None:
        for index, value in enumerate(counts):
            groups[key][index] += value

    events = defaultdict(lambda: [0] * len(counter_fields))
    for event in batch["events"]:
        add(events, _mac_row_key(event, "sessions"), (event["amounts"][field] for field in counter_fields))
    for name, rows, start in (("Days", days, 2), ("Sessions", sessions, 1)):
        expected = defaultdict(lambda: [0] * len(counter_fields), {key: totals.copy() for key, totals in events.items()})
        coverage = {_mac_row_key(row, name): row["amounts"] for row in batch[f"coverage{name}"]}
        for baseline in batch.get(f"baseline{name}", []):
            covered = coverage.get(_mac_row_key(baseline, name), {})
            counts = (max(0, baseline["amounts"][field] - covered.get(field, 0)) for field in counter_fields)
            add(expected, _mac_row_key(baseline, "sessions"), counts)
        actual = defaultdict(lambda: [0] * len(counter_fields))
        for row in rows:
            if row[start] in batch["clients"]:
                add(actual, row[start:start + 3], row[-len(AMOUNT_FIELDS):-1])
        if {key: counts for key, counts in expected.items() if any(counts)} != {key: counts for key, counts in actual.items() if any(counts)}:
            raise _archive_conflict()


def _read_archive(payload: dict) -> list[_ArchiveDevice]:
    if not isinstance(payload, dict) or type(payload.get("format")) is not int or payload["format"] not in (1, 2, 3, 4):
        raise _invalid_archive()
    archive_format = payload["format"]
    _archive_moment(payload.get("exportedAt"))
    devices = _archive_list(payload, "devices")
    if len(devices) > MAX_DEVICES:
        raise _invalid_archive()
    result = []
    seen_devices = set()
    entries = 0
    for raw in devices:
        try:
            source_id = raw["id"]
            device = str(UUID(source_id))
        except (AttributeError, ValueError, TypeError, KeyError):
            raise _invalid_archive() from None
        if device in seen_devices:
            raise _invalid_archive()
        seen_devices.add(device)
        label = _archive_text(raw.get("name"), limit=200)
        days, sessions, cursor = [], [], []
        raw_days = _archive_list(raw, "days")
        raw_sessions = _archive_list(raw, "sessions")
        raw_cursor = _archive_list(raw, "cursorEvents", optional=True)
        entries += len(raw_days) + len(raw_sessions) + len(raw_cursor)
        if entries > MAX_RECORDS:
            raise _invalid_archive()
        local_usage = None
        if raw.get("localUsage") is not None:
            if source_id.lower() != device:
                raise _invalid_archive()
            _versioned_fields(payload, ("format", "exportedAt", "devices"))
            _versioned_fields(raw, ("id", "name", "days", "sessions", "cursorEvents", "localUsage"))
            local_usage, local_count = _read_mac_usage(raw["localUsage"], archive_format, limit=MAX_RECORDS - entries)
            entries += local_count
        day_keys, session_keys, cursor_keys = set(), set(), set()
        for row in raw_days:
            parsed = _archive_day(row, device)
            key = parsed[1:5]
            client = parsed[2]
            if key in day_keys or (client == "cursor" and not raw_cursor):
                raise _invalid_archive()
            day_keys.add(key)
            if client != "cursor":
                days.append(parsed)
        for row in raw_sessions:
            key = _archive_ids(row)
            client = key[0]
            if key in session_keys or (client == "cursor" and not raw_cursor):
                raise _invalid_archive()
            session_keys.add(key)
            if client != "cursor":
                sessions.append(_archive_session(row, device))
            else:
                _archive_amounts(row)
                first = _archive_moment(row.get("firstActive"), optional=True)
                last = _archive_moment(row.get("lastActive"), optional=True)
                if first and last and first > last:
                    raise _invalid_archive()
        for row in raw_cursor:
            key = _archive_text(row.get("accountKey"), limit=64)
            event_id = _archive_text(row.get("eventID"), limit=64)
            conversation = _archive_text(row.get("conversationID"), limit=64)
            amounts = _archive_amounts(row)
            hashes = (key, event_id, conversation)
            if (not all(_sha256(value) for value in hashes)
                    or str(UUID(hex=key[:32])) != device or (key, event_id) in cursor_keys or amounts[4:6] != (0, 1)):
                raise _invalid_archive()
            cursor_keys.add((key, event_id))
            cursor.append((device, key, event_id, _archive_moment(row.get("timestamp")), conversation,
                           _archive_text(row.get("model")), *amounts))
        if local_usage is not None:
            _validate_mac_projection(local_usage, days, sessions)
        result.append(_ArchiveDevice(device, source_id, label, days, sessions, cursor, local_usage))
    return result
