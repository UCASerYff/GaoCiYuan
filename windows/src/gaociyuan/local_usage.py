"""Windows local-usage analytics, independent of quota snapshot history."""

from __future__ import annotations

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
        self._lock = threading.RLock()
        self._scan_lock = threading.Lock()
        self._revision = 0
        self._last_attempt = None
        self._warnings = None
        if self.settings_path.exists():
            try:
                info = local_item(self.settings_path)
                if info is None or not stat.S_ISREG(info.st_mode) or info.st_size > 2_000_000:
                    raise ValueError("invalid preferences file")
                raw = json.loads(self.settings_path.read_text(encoding="utf-8"))
                # An unavailable automatic-export folder does not disable scans.
                validated = _settings({**raw, "automaticExportPath": None}, self._settings, self.directory)
                validated["authorized"] = raw.get("authorized") is True
                stored_export = raw.get("automaticExportPath")
                if isinstance(stored_export, str) and local_path(stored_export) is not None:
                    validated["automaticExportPath"] = stored_export
                self._settings = validated
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
            for path in (*paths, *extra):
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

    def _write_settings(self, settings: dict) -> None:
        try:
            _atomic_bytes(self.settings_path, json.dumps(settings, ensure_ascii=False, indent=2).encode("utf-8"))
        except OSError as error:
            raise AppError("用量采集设置无法保存。", "usage-settings") from error

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
                    export_dir = Path(settings["automaticExportPath"])
                    if local_item(export_dir) is None or not export_dir.is_dir() or export_dir.resolve().is_relative_to(self.directory.resolve()):
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
        payload = {"format": 2, "exportedAt": _archive_date(_date_json(now or utcnow())), "devices": list(devices.values())}
        result = json.dumps(payload, ensure_ascii=False, separators=(",", ":"), allow_nan=False).encode("utf-8")
        if len(result) > MAX_ARCHIVE_SIZE:
            raise AppError("用量 JSON 超过 64 MB。", "usage-limit")
        return result

    def import_archive(self, payload: dict) -> dict:
        batches = _read_archive(payload)
        with self._lock, self._db(create=True) as conn:
            identifier = self._device(conn, self._metadata(conn))
            for device, label, days, sessions, cursor in batches:
                if device == identifier:
                    continue
                conn.execute("INSERT INTO devices VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET label = excluded.label", (device, label))
                conn.executemany(_import_sql("imported_days", "device, day, client, session, model", 12), days)
                conn.executemany(_import_sql("imported_sessions", "device, client, session, model", 17, session=True), sessions)
                conn.executemany("INSERT OR IGNORE INTO cursor_events VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)", cursor)
        return {"deviceCount": len(batches), "dayCount": sum(len(item[2]) for item in batches),
                "sessionCount": sum(len(item[3]) for item in batches)}


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


def _read_archive(payload: dict) -> list:
    if not isinstance(payload, dict) or type(payload.get("format")) is not int or payload["format"] not in (1, 2, 3, 4):
        raise _invalid_archive()
    _archive_moment(payload.get("exportedAt"))
    devices = _archive_list(payload, "devices")
    if len(devices) > MAX_DEVICES:
        raise _invalid_archive()
    result = []
    seen_devices = set()
    entries = 0
    for raw in devices:
        try:
            device = str(UUID(raw["id"]))
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
        day_keys, session_keys, cursor_keys = set(), set(), set()
        for row in raw_days:
            try:
                day = date.fromisoformat(row.get("day"))
            except (TypeError, ValueError):
                raise _invalid_archive() from None
            if day.isoformat() != row["day"]:
                raise _invalid_archive()
            client, session, model = _archive_ids(row)
            key = day.isoformat(), client, session, model
            if key in day_keys or (client == "cursor" and not raw_cursor):
                raise _invalid_archive()
            day_keys.add(key)
            amounts = _archive_amounts(row)
            if client != "cursor":
                days.append((device, *key, *amounts))
        for row in raw_sessions:
            client, session, model = key = _archive_ids(row)
            first = _archive_moment(row.get("firstActive"), optional=True)
            last = _archive_moment(row.get("lastActive"), optional=True)
            if key in session_keys or (first and last and first > last) or (client == "cursor" and not raw_cursor):
                raise _invalid_archive()
            session_keys.add(key)
            amounts = _archive_amounts(row)
            if client != "cursor":
                label_value = _archive_text(row.get("projectLabel"), limit=160, optional=True)
                if label_value and any(char in label_value for char in "/\\"):
                    raise _invalid_archive()
                project = _archive_text(row.get("projectKey"), optional=True)
                if project and (len(project) != 64 or any(char not in "abcdef0123456789" for char in project)):
                    project = digest(project)
                sessions.append((device, *key, project, label_value, first, last,
                                 _archive_count(row.get("timedTokens")), _archive_count(row.get("timedDurationMS")), *amounts))
        for row in raw_cursor:
            key = _archive_text(row.get("accountKey"), limit=64)
            event_id = _archive_text(row.get("eventID"), limit=64)
            conversation = _archive_text(row.get("conversationID"), limit=64)
            amounts = _archive_amounts(row)
            hashes = (key, event_id, conversation)
            if (any(len(value) != 64 or set(value) - set("0123456789abcdef") for value in hashes)
                    or str(UUID(hex=key[:32])) != device or (key, event_id) in cursor_keys or amounts[4:6] != (0, 1)):
                raise _invalid_archive()
            cursor_keys.add((key, event_id))
            cursor.append((device, key, event_id, _archive_moment(row.get("timestamp")), conversation,
                           _archive_text(row.get("model")), *amounts))
        result.append((device, label, days, sessions, cursor))
    return result
