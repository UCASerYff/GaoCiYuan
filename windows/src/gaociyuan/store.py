"""账户、快照、手动 Grok Bot 读取和刷新。自动刷新不会打开 grokbot-usage.json。"""

from __future__ import annotations

import hashlib
import json
import math
import os
import threading
import uuid
from datetime import datetime, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

from gaociyuan.alerts import failure_alert, reading_alerts
from gaociyuan.antigravity_report import (
    HISTORICAL_SOURCES,
    IMPORT_HELP,
    MAX_FINGERPRINTS,
    REPORT_FIELD,
    decode_report,
    parse_report,
    public_report,
    report_fingerprint,
)
from gaociyuan.catalog import (
    AGENT_LOCAL,
    ANTIGRAVITY_REPORT,
    FILE,
    available_connections,
    creation_kinds,
    default_agent_name,
    display_name,
    agent_software,
    is_legacy_gemini_connection,
    known_provider,
    normalize_connection,
    normalize_kind,
    windows_read_mode,
)
from gaociyuan.credentials import open_credential_store
from gaociyuan.errors import AppError
from gaociyuan.grokbot import (
    FileProvider,
    Rejection,
    connector_status,
    is_grok_bot_route,
    is_grokbot_filename,
    manual_reading_dict,
    presentation,
    status_line,
)
from gaociyuan.quota_forecast import MAX_OBSERVATIONS, quota_forecast, record_quota_observation
from gaociyuan.rings import adaptive_interval, attention, health_of, rail_accounts, ring_for
from gaociyuan.routes import ACCOUNT_ID
from gaociyuan.snapshots import (
    credential_error,
    has_measured_values,
    is_status_quota,
    normalize_snapshot,
    same_observation,
    strip_status_quotas,
    validate_snapshot,
)
from gaociyuan.timeutil import format_iso, grokbot_snapshot_path, parse_instant, utcnow
from gaociyuan.usage import UsageLedger

LIBRARY_KEYS = {"schema", "accounts", "refreshMinutes", "warningThreshold", "autoRefresh"}
FORECAST_HISTORY = "quotaForecastHistory"
SOURCE_FIELDS = ("provider", "kind", "connection", "filePath", "scopeID", "region", "customConfig")
ACCOUNT_KEYS = {
    "id",
    "provider",
    "kind",
    "name",
    "plan",
    "connection",
    "filePath",
    "scopeID",
    "region",
    "enabled",
    "budget",
    "currency",
    "snapshot",
    "lastAttempt",
    "error",
    "statusNote",
    "balanceBasis",
    "baselines",
    "history",
    "lastQuotaChangedAt",
    "customConfig",
    "showInRail",
    "autoDiscovered",
    "connectorAuthorized",
    "grokBotManualReading",
    "quotaForecast",
    FORECAST_HISTORY,
    REPORT_FIELD,
}
SECRET_FIELDS = {"secret", "apiKey", "token", "password", "credential"}
UNSUPPORTED = "Windows 版不调用这条连接的在线接口或辅助功能，也不会写入百分比。可改用「快照文件」导入真实读数。上次数据已保留。"


def empty_library() -> dict:
    return {"schema": 1, "accounts": [], "refreshMinutes": 5, "warningThreshold": 20, "autoRefresh": True}


def default_settings() -> dict:
    return {
        "language": "zh-Hans",
        "appearance": "system",
        "refreshFixedInterval": False,
        "timeZone": "Asia/Shanghai",
        "panelFloating": True,
        "panelDock": "right",
        "panelTwoColumns": False,
        "panelHideFullScreen": False,
        "panelFollowDisplay": False,
        "panelPosition": None,
        "notifyThreshold": 0,
        "notifyLowBalance": 0,
        "notifyExhausted": False,
        "notifyFailures": False,
        "notifyOnReset": False,
        "updateAppcastURL": "",
        "updatePublicKey": "",
    }


class TokenStore:
    def __init__(self, directory: Path, credentials=None, now=None, zone: ZoneInfo | None = None):
        self.directory = Path(directory)
        self.library_path = self.directory / "library.json"
        self.settings_path = self.directory / "settings.json"
        self.alerts_path = self.directory / "alerts.json"
        self.grok_path = grokbot_snapshot_path(self.directory)
        self.credentials = credentials if credentials is not None else open_credential_store(self.directory, force_memory=True)
        self.zone = zone or ZoneInfo("Asia/Shanghai")
        self._now = now or utcnow
        self.load_failed = False
        self.notice: str | None = None
        self.persisted = False
        self.library = empty_library()
        self.extras: dict = {}
        self.settings = default_settings()
        self.failures: dict[str, int] = {}
        self.alert_memory: dict[str, dict] = {}
        self.notify = lambda account, message: None
        self.rail_visible = lambda account: account.get('showInRail', True)
        self.connector_reader = None
        self.lock = threading.RLock()
        self._refreshing: set[str] = set()
        self.unknown_connections: list[str] = []
        self.grok_reads = 0
        self._changes: dict[str, datetime] = {}
        self._actions: dict[str, datetime] = {}
        self._ledger: UsageLedger | None = None
        self._load_settings()
        self._load_alerts()
        self._load_library()

    def now(self) -> datetime:
        moment = self._now()
        if moment.tzinfo is None:
            moment = moment.replace(tzinfo=timezone.utc)
        return moment.astimezone(timezone.utc)

    def create_library(self) -> None:
        if self.load_failed:
            raise AppError("原文件无法读取，不会用空库覆盖。", "readonly")
        if self.library_path.exists():
            raise AppError("资料库已存在。", "exists")
        self.library = empty_library()
        self.extras = {}
        self._write_library()
        self.persisted = True

    def save_account(self, payload: dict) -> dict:
        self._ensure_writable()
        if not isinstance(payload, dict):
            raise AppError("账户格式无效。")
        secret = payload.get("secret")
        new_credential = isinstance(secret, str) and bool(secret.strip())
        provider = payload.get("provider")
        if not isinstance(provider, str) or not known_provider(provider):
            raise AppError("未知的 Agent 软件。")
        account_id = payload.get("id") or str(uuid.uuid4())
        if not isinstance(account_id, str) or not ACCOUNT_ID.fullmatch(account_id):
            raise AppError("账户编号无效。")
        existing = self._find(account_id)
        if existing is None and not creation_kinds(provider):
            raise AppError("搞词元仅记录 Agent 软件，不支持 API 账户。")
        if provider == "custom":
            raise AppError("搞词元仅记录 Agent 软件，不支持 API 账户。")
        default = (existing["connection"] if existing else ANTIGRAVITY_REPORT) if provider == "gemini" else AGENT_LOCAL
        requested = str(payload.get("connection") or default)
        connection, unknown = (requested, False) if is_legacy_gemini_connection(provider, requested) else normalize_connection(requested)
        if unknown:
            self.unknown_connections.append(str(payload.get("connection")))
        if connection not in available_connections(provider, "Agent"):
            raise AppError("这个 Agent 没有该连接方式。")
        current_route = (existing["provider"], existing["connection"]) if existing else None
        new_route = (provider, connection)
        routes = [route for route in (current_route, new_route) if route is not None]
        if new_route != current_route and any(
            is_legacy_gemini_connection(*route) or route == ("gemini", FILE) for route in routes
        ):
            raise AppError("请另建 Antigravity 独立版账户。旧 Gemini 连接和历史记录会保留。", "legacy_connection")
        if connection == ANTIGRAVITY_REPORT and new_credential:
            raise AppError("Antigravity 手动报告不需要凭据。")
        name = str(payload.get("name") or default_agent_name(provider)).strip()
        if not name:
            raise AppError("账户设置无效。")
        currency = str(payload.get("currency") or "USD").upper()
        if len(currency) != 3 or any(not ("A" <= ch <= "Z") for ch in currency):
            currency = "USD"
        budget = payload.get("budget")
        if budget is not None and (isinstance(budget, bool) or not isinstance(budget, (int, float)) or not budget > 0):
            raise AppError("账户设置无效。")
        account = {
            "id": account_id,
            "provider": provider,
            "kind": "Agent",
            "name": name,
            "plan": str(payload.get("plan") or ""),
            "connection": connection,
            "filePath": str(payload.get("filePath") or ""),
            "scopeID": payload.get("scopeID"),
            "region": payload.get("region"),
            "enabled": bool(payload.get("enabled", True)),
            "budget": budget,
            "currency": currency,
            "snapshot": None,
            "lastAttempt": None,
            "error": None,
            "statusNote": None,
            "balanceBasis": payload.get("balanceBasis"),
            "baselines": payload.get("baselines") if isinstance(payload.get("baselines"), dict) else None,
            "history": [],
            "lastQuotaChangedAt": None,
            "customConfig": None,
            "showInRail": bool(payload.get("showInRail", True)),
            "autoDiscovered": bool(payload.get("autoDiscovered", False)),
            "connectorAuthorized": False,
            "grokBotManualReading": None,
        }
        if existing:
            account["autoDiscovered"] = existing.get("autoDiscovered", False)
            account["history"] = existing.get("history") or []
            same = _same_source(existing, account)
            if same:
                account["connectorAuthorized"] = existing.get("connectorAuthorized", False)
                if connection == ANTIGRAVITY_REPORT and REPORT_FIELD in existing:
                    account[REPORT_FIELD] = existing[REPORT_FIELD]
            if same and not new_credential:
                for key in ("snapshot", "lastAttempt", "error", "statusNote", "grokBotManualReading", "lastQuotaChangedAt"):
                    account[key] = existing.get(key)
                if account['plan'] == existing['plan'] and FORECAST_HISTORY in existing:
                    account[FORECAST_HISTORY] = existing[FORECAST_HISTORY]
            for key, value in existing.items():
                if key not in ACCOUNT_KEYS and key not in SECRET_FIELDS:
                    account[key] = value
        try:
            if new_credential:
                self.credentials.put(account_id, secret.strip())
            elif existing and existing.get("connection") != connection:
                self.credentials.delete(account_id)
        except (AppError, OSError):
            # DPAPI and Credential Manager writes can succeed independently.
            if existing:
                self._discard_forecast_evidence(existing)
            raise
        self._replace(account)
        self._validate()
        self._write_library()
        return account

    def add_discovered(self, suggested: list[dict]) -> list[str]:
        if self.load_failed:
            return []
        added = []
        def identity(account: dict) -> tuple:
            provider = account["provider"]
            return provider, account["connection"] if provider == "gemini" else None

        existing = {identity(item) for item in self.library["accounts"]}
        for candidate in suggested:
            key = identity(candidate)
            if key in existing or ("id" in candidate and self._find(candidate["id"]) is not None):
                continue
            account = self.save_account({**candidate, "autoDiscovered": True})
            added.append(account["id"])
            existing.add(key)
        return added

    def delete_account(self, account_id: str) -> None:
        self._ensure_writable()
        before = len(self.library["accounts"])
        self.library["accounts"] = [item for item in self.library["accounts"] if item["id"] != account_id]
        if len(self.library["accounts"]) == before:
            raise AppError("没有这个账户。", "missing")
        self.credentials.delete(account_id)
        self.failures.pop(account_id, None)
        self.alert_memory.pop(account_id, None)
        self._write_library()
        self._write_alerts()

    def set_credential(self, account_id: str, secret: str) -> None:
        with self.lock:
            self._ensure_writable()
            account = self._find(account_id)
            if account is None:
                raise AppError("没有这个账户。", "missing")
            if account.get("connection") == ANTIGRAVITY_REPORT:
                raise AppError("Antigravity 手动报告不需要凭据。")
            if not isinstance(secret, str) or not secret.strip():
                raise AppError("凭据不能为空。", "credential")
            try:
                self.credentials.put(account_id, secret)
            finally:
                self._discard_forecast_evidence(account)

    def delete_credential(self, account_id: str) -> None:
        with self.lock:
            self._ensure_writable()
            account = self._find(account_id)
            if account is None:
                raise AppError("没有这个账户。", "missing")
            try:
                self.credentials.delete(account_id)
            finally:
                self._discard_forecast_evidence(account)

    def _discard_forecast_evidence(self, account: dict) -> None:
        updated = dict(account)
        updated.pop(FORECAST_HISTORY, None)
        # An in-flight connector holds the original object and must not publish after a key change.
        self._replace(updated)
        if FORECAST_HISTORY in account:
            self._write_library()

    def credential_present(self, account_id: str) -> bool:
        return self._find(account_id) is not None and self.credentials.has(account_id)

    def update_settings(self, payload: dict) -> dict:
        if self.load_failed:
            raise AppError("原文件无法读取，不会写入。", "readonly")
        if "language" in payload and payload["language"] in {"system", "zh-Hans", "en"}:
            self.settings["language"] = payload["language"]
        if "appearance" in payload and payload["appearance"] in {"system", "light", "dark"}:
            self.settings["appearance"] = payload["appearance"]
        if "refreshFixedInterval" in payload:
            self.settings["refreshFixedInterval"] = bool(payload["refreshFixedInterval"])
        if "timeZone" in payload and isinstance(payload["timeZone"], str):
            try:
                self.zone = ZoneInfo(payload["timeZone"])
                self.settings["timeZone"] = payload["timeZone"]
            except Exception as exc:
                raise AppError("无法识别这个时区。") from exc
        if "panelFloating" in payload:
            self.settings["panelFloating"] = bool(payload["panelFloating"])
        if payload.get("panelDock") in ("left", "right", "top", "floating"):
            self.settings["panelDock"] = payload["panelDock"]
        position = payload.get("panelPosition")
        if isinstance(position, list) and len(position) == 2 and all(type(value) is int and abs(value) < 100000 for value in position):
            self.settings["panelPosition"] = position
        for key in ("panelTwoColumns", "panelHideFullScreen", "panelFollowDisplay", "notifyExhausted", "notifyFailures", "notifyOnReset"):
            if key in payload:
                self.settings[key] = bool(payload[key])
        if "notifyLowBalance" in payload:
            value = payload["notifyLowBalance"]
            self.settings["notifyLowBalance"] = value if type(value) in (int, float) and 0 < value <= 1e9 and math.isfinite(value) else 0
        for key in ("updateAppcastURL", "updatePublicKey"):
            if key in payload:
                value = payload[key]
                if not isinstance(value, str) or len(value) > 4096:
                    raise AppError("更新源设置无效。")
                self.settings[key] = value.strip()
        if "notifyThreshold" in payload:
            value = payload["notifyThreshold"]
            self.settings["notifyThreshold"] = value if value in {0, 75, 80, 90, 95} else 0
        if any(key in payload for key in ("refreshMinutes", "warningThreshold", "autoRefresh")):
            self._ensure_writable()
            if "refreshMinutes" in payload:
                minutes = payload["refreshMinutes"]
                if not isinstance(minutes, int) or isinstance(minutes, bool) or not 1 <= minutes <= 60:
                    raise AppError("刷新间隔须在 1 到 60 分钟。")
                self.library["refreshMinutes"] = minutes
            if "warningThreshold" in payload:
                threshold = payload["warningThreshold"]
                if isinstance(threshold, bool) or not isinstance(threshold, (int, float)) or not 5 <= float(threshold) <= 50:
                    raise AppError("提醒阈值须在 5 到 50。")
                self.library["warningThreshold"] = float(threshold)
            if "autoRefresh" in payload:
                self.library["autoRefresh"] = bool(payload["autoRefresh"])
            self._write_library()
        self._write_settings()
        return self.settings

    def refresh(self, account_id: str, user_initiated: bool = False) -> None:
        with self.lock:
            if self.load_failed or not user_initiated and not self.library.get("autoRefresh", True):
                return
            account = self._find(account_id)
            if account is None or not account.get("enabled", True) or account.get("kind") != "Agent":
                return
            if is_grok_bot_route(account):
                if user_initiated:
                    self.read_grokbot(account_id)
                return
            mode = windows_read_mode(account["provider"], account["connection"])
            if mode == "antigravity-report" or is_legacy_gemini_connection(account["provider"], account["connection"]):
                return
            now = self.now()
            if user_initiated:
                self._actions[account_id] = now
            if mode == "file":
                self._refresh_file(account, now)
                return
            if mode != "connector" or self.connector_reader is None:
                if user_initiated:
                    self._set_status(account, UNSUPPORTED, now)
                return
            if account_id in self._refreshing or not user_initiated and not account.get("connectorAuthorized"):
                return
            secret = self.credentials.get(account_id)
            self._refreshing.add(account_id)
        try:
            snapshot = self.connector_reader(dict(account), secret, now, data_dir=self.directory)
            validate_snapshot(snapshot, now)
            with self.lock:
                if self._find(account_id) is account:
                    account["connectorAuthorized"] = True
                    source_key = _quota_source_key(account, snapshot.get("source"))
                    self._apply_snapshot(account, snapshot, now, source_key)
        except AppError as exc:
            with self.lock:
                if self._find(account_id) is account:
                    if exc.code in {"missing", "unsupported", "neutral", "unavailable"}:
                        self._set_status(account, exc.message, now)
                    else:
                        self._set_error(account, exc.message, now)
        finally:
            with self.lock:
                self._refreshing.discard(account_id)

    def test_account(self, payload: dict) -> dict:
        provider = payload.get("provider")
        if not isinstance(provider, str) or not known_provider(provider) or not creation_kinds(provider):
            raise AppError("请选择 Agent 软件。")
        connection, _ = normalize_connection(str(payload.get("connection") or AGENT_LOCAL))
        if connection not in available_connections(provider, "Agent"):
            raise AppError("这个 Agent 没有该连接方式。")
        draft = {**payload, "connection": connection, "kind": "Agent", "provider": provider}
        mode = windows_read_mode(provider, connection)
        if is_grok_bot_route(draft):
            raise AppError("请保存账户，再用「读取本机额度」读取 Grok Bot。")
        if mode == "antigravity-report":
            raise AppError(IMPORT_HELP, "manual_report")
        now = self.now()
        if mode == "file":
            snapshot, _ = self._read_snapshot_file(draft, now)
        elif mode == "connector" and self.connector_reader is not None:
            secret = payload.get("secret")
            if not secret and payload.get("id"):
                with self.lock:
                    existing = self._find(payload["id"])
                    secret = self.credentials.get(payload["id"]) if existing and _same_source(existing, draft) else None
            snapshot = self.connector_reader(draft, secret, now, data_dir=self.directory)
            validate_snapshot(snapshot, now)
        else:
            raise AppError(UNSUPPORTED, "unsupported")
        return {"snapshot": snapshot}

    def refresh_all(self) -> list[str]:
        with self.lock:
            account_ids = [item["id"] for item in self.library["accounts"]
                           if item.get("enabled") and not is_grok_bot_route(item) and item["connection"] != ANTIGRAVITY_REPORT
                           and not is_legacy_gemini_connection(item["provider"], item["connection"])]
        for account_id in account_ids:
            self.refresh(account_id, user_initiated=True)
        return account_ids

    def import_antigravity_report(self, payload: dict) -> dict:
        with self.lock:
            self._ensure_writable()
            account_id = payload.get("id")
            account = self._find(account_id) if isinstance(account_id, str) else None
            if not account or account["provider"] != "gemini" or account["connection"] != ANTIGRAVITY_REPORT:
                raise AppError("请选择已保存的 Antigravity 独立版报告账户。", "wrong_account")
            if payload.get("confirmed") is not True:
                raise AppError("请确认所选账户和报告来源。", "confirmation_required")
            quotas = parse_report(payload.get("report"))
            fingerprint = report_fingerprint(quotas)
            previous = account.get(REPORT_FIELD)
            fingerprints = previous["fingerprints"] if previous else []
            if fingerprint in fingerprints:
                return {"report": public_report(previous), "duplicate": True}

            # An editable transcript has no trustworthy provider observation time or identity.
            # Its values are displayed separately from snapshots, alerts, history and forecasts.
            report = {"importedAt": format_iso(self.now()), "quotas": quotas,
                      "fingerprints": (fingerprints + [fingerprint])[-MAX_FINGERPRINTS:]}
            updated = {**account, REPORT_FIELD: report}
            accounts = [updated if item is account else item for item in self.library["accounts"]]
            self._write_library(accounts=accounts)
            self.library["accounts"] = accounts
            return {"report": public_report(report), "duplicate": False}

    def read_grokbot(self, account_id: str) -> None:
        """唯一会打开 grokbot-usage.json 的入口。"""
        self._ensure_writable()
        account = self._find(account_id)
        if account is None or not is_grok_bot_route(account):
            raise AppError("这个账户不是 Grok Bot 本机额度。")
        now = self.now()
        self.grok_reads += 1
        provider = FileProvider(self.grok_path, root=self.directory, zone=self.zone)
        reading, rejection, detail = provider.load(now)
        if reading is not None:
            account["grokBotManualReading"] = manual_reading_dict(reading)
            account["statusNote"] = presentation(reading)
            account["error"] = None
        else:
            installed = False
            running = False
            account["statusNote"] = connector_status(None, rejection, installed, running)
            if detail and rejection is Rejection.INVALID and detail not in {"文件为空"}:
                account["statusNote"] = "尚未检测到 Grok Bot。用量记录不符合 grokbot-usage.json 约定，未显示百分比。"
            account["error"] = None
        account["lastAttempt"] = format_iso(now)
        self._actions[account_id] = now
        self._write_library()

    def refresh_due(self) -> list[str]:
        with self.lock:
            if self.load_failed or not self.library.get("autoRefresh", True):
                return []
            now = self.now()
            fixed = bool(self.settings.get("refreshFixedInterval"))
            due = []
            for account in self.library["accounts"]:
                if is_grok_bot_route(account) or not account.get("enabled", True):
                    continue
                mode = windows_read_mode(account["provider"], account["connection"])
                if mode != "file" and not (mode == "connector" and account.get("connectorAuthorized")):
                    continue
                account_id = account["id"]
                interval = self.library["refreshMinutes"] * 60 if fixed else adaptive_interval(
                    self._changes.get(account_id), self._actions.get(account_id), now, True,
                )
                last = parse_instant(account.get("lastAttempt") or "")
                if last is None or (now - last).total_seconds() >= interval:
                    due.append(account_id)
        for account_id in due:
            self.refresh(account_id, user_initiated=False)
        return due

    def usage_rows(self, key: str, provider: str = "") -> list[dict]:
        path = self.directory / "usage-ledger.sqlite"
        if not path.exists():
            return []
        return UsageLedger(path).rows(key, self.now(), self.zone, provider)

    def filtered_accounts(self, query: str = "", provider: str = "", health: str = "") -> list[dict]:
        needle = query.casefold()
        rows = []
        for account in self.library["accounts"]:
            if provider and account.get("provider") != provider:
                continue
            view = self.view_account(account)
            if health and view["health"] != health:
                continue
            blob = " ".join([account.get("name") or "", account.get("provider") or "", account.get("plan") or ""]).casefold()
            if needle and needle not in blob:
                continue
            rows.append(view)
        return rows

    def view_account(self, account: dict, *, include_forecast: bool = True) -> dict:
        now = self.now().astimezone(self.zone)
        threshold = float(self.library.get("warningThreshold") or 20)
        failures = self.failures.get(account["id"], 0)
        view = dict(account)
        view.pop(FORECAST_HISTORY, None)
        legacy_gemini = is_legacy_gemini_connection(account["provider"], account["connection"])
        if account["connection"] == ANTIGRAVITY_REPORT:
            view[REPORT_FIELD] = public_report(account.get(REPORT_FIELD))
        if include_forecast and not legacy_gemini:
            view["quotaForecast"] = quota_forecast(account, now)
        view["hasCredential"] = not legacy_gemini and account["connection"] != ANTIGRAVITY_REPORT and self.credentials.has(account["id"])
        if legacy_gemini:
            view["stale"] = bool(account.get("snapshot"))
            view["warnings"] = []
            view["health"] = "historical" if view["stale"] else "syncPaused"
            view["ring"] = ring_for({**account, "snapshot": None}, threshold, now, self.zone)
            view["grokStatus"] = None
            return view
        observed = parse_instant((account.get("snapshot") or {}).get("observedAt") or "") if account.get("snapshot") else None
        view["stale"] = observed is not None and (now - observed).total_seconds() > 900
        view["warnings"] = attention(account, threshold, now)
        view["health"] = health_of(account, threshold, now, failures)
        view["ring"] = ring_for(account, threshold, now, self.zone)
        reading = account.get("grokBotManualReading")
        if is_grok_bot_route(account) and reading:
            view["grokStatus"] = status_line(reading, now, self.zone)
        else:
            view["grokStatus"] = account.get("statusNote")
        return view

    def snapshot_state(self, query: str = "", provider: str = "", health: str = "") -> dict:
        accounts = self.filtered_accounts(query, provider, health) if (query or provider or health) else [self.view_account(item) for item in self.library["accounts"]]
        return {
            "version": __import__("gaociyuan.version", fromlist=["VERSION_LABEL"]).VERSION_LABEL,
            "status": "readonly" if self.load_failed else "ready",
            "persisted": self.persisted,
            "notice": self.notice,
            "dataDir": str(self.directory),
            "grokbotPath": str(self.grok_path),
            "credentialBackend": getattr(self.credentials, "backend", "memory"),
            "library": {
                "schema": self.library.get("schema"),
                "refreshMinutes": self.library.get("refreshMinutes"),
                "warningThreshold": self.library.get("warningThreshold"),
                "autoRefresh": self.library.get("autoRefresh"),
            },
            **self.panel_state(),
            "accounts": accounts,
            "grokReads": self.grok_reads,
            "refreshing": sorted(self._refreshing),
        }

    def panel_state(self) -> dict:
        rail_source = [item for item in self.library["accounts"] if self.rail_visible(item)]
        rail = rail_accounts(rail_source, self.now())
        return {
            "settings": self.settings,
            "rail": [self.view_account(item, include_forecast=False) for item in rail[:12]],
            "railOverflow": max(0, len(rail) - 12),
        }

    def _refresh_file(self, account: dict, now: datetime) -> None:
        try:
            snapshot, source_key = self._read_snapshot_file(account, now)
        except AppError as exc:
            self._set_error(account, exc.message, now)
            return
        self._apply_snapshot(account, snapshot, now, source_key)

    def _read_snapshot_file(self, account: dict, now: datetime) -> tuple[dict, str]:
        path = account.get("filePath") or ""
        if not path:
            raise AppError("请选择快照 JSON 文件。")
        if is_grokbot_filename(path):
            raise AppError("grokbot-usage.json 只能通过「读取本机额度」读取。")
        try:
            file_path = Path(path)
            if self.grok_path.exists() and file_path.samefile(self.grok_path):
                raise AppError("grokbot-usage.json 只能通过「读取本机额度」读取。")
            with file_path.open('rb') as handle:
                data = handle.read(2_000_001)
            if len(data) > 2_000_000:
                raise AppError("快照文件不能超过 2 MB。")
            raw = json.loads(data.decode("utf-8-sig"))
            snapshot = strip_status_quotas(normalize_snapshot(raw, now))
            if account["provider"] == "gemini" and (
                snapshot["source"] in HISTORICAL_SOURCES or raw.get("isUnverifiedAntigravityReport") is True
            ):
                raise AppError("Antigravity 历史报告仅供参考，不能更新当前 JSON 快照。")
            source_key = _quota_source_key(account, snapshot["source"])
            snapshot["source"] = "快照文件"
            validate_snapshot(snapshot, now)
        except (OSError, UnicodeError, json.JSONDecodeError) as exc:
            raise AppError("快照文件无法读取，已保留上次数据。") from exc
        return snapshot, source_key

    def _apply_snapshot(self, account: dict, snapshot: dict, now: datetime, source_key: str) -> None:
        current = account.get("snapshot")
        account["lastAttempt"] = format_iso(now)
        account["error"] = None
        account["statusNote"] = None
        self.failures[account["id"]] = 0
        record_quota_observation(account, snapshot, source_key, now)
        events = reading_alerts(self.alert_memory.setdefault(account["id"], {}), self.settings, account, snapshot, now)
        if current and same_observation(current, snapshot):
            current_at = parse_instant(current.get('observedAt'))
            observed_at = parse_instant(snapshot.get('observedAt'))
            if observed_at and (current_at is None or observed_at > current_at):
                account['snapshot'] = snapshot
            self._write_library()
            self._write_alerts()
            self._notify(account, events)
            return
        history = list(account.get("history") or [])
        history.append(snapshot)
        account["history"] = history[-300:]
        account["snapshot"] = snapshot
        account["lastQuotaChangedAt"] = format_iso(now)
        self._changes[account["id"]] = now
        self._usage_ledger().record(account, snapshot)
        self._write_library()
        self._write_alerts()
        self._notify(account, events)

    def _set_status(self, account: dict, message: str, now: datetime) -> None:
        account["statusNote"] = message
        account["error"] = None
        account["lastAttempt"] = format_iso(now)
        self._write_library()

    def _set_error(self, account: dict, message: str, now: datetime) -> None:
        account["error"] = message
        account["statusNote"] = None
        account["lastAttempt"] = format_iso(now)
        if credential_error(message):
            self.failures[account["id"]] = self.failures.get(account["id"], 0) + 1
        else:
            neutral = any(phrase in message for phrase in ("请选择快照 JSON 文件", "只能通过"))
            if not neutral:
                self.failures[account["id"]] = self.failures.get(account["id"], 0) + 1
        self._write_library()
        self._write_alerts()
        memory = self.alert_memory.setdefault(account["id"], {})
        events = failure_alert(memory, self.settings["notifyFailures"], self.failures.get(account["id"], 0), message)
        if events:
            self._write_alerts()
            self._notify(account, events)

    def _notify(self, account: dict, events: list[str]) -> None:
        if events:
            self.notify(account, "\n".join(events))

    def _load_library(self) -> None:
        if not self.library_path.exists():
            self.library = empty_library()
            self.persisted = False
            return
        try:
            raw_text = self.library_path.read_text(encoding="utf-8-sig")
            raw = json.loads(raw_text)
            if not isinstance(raw, dict):
                raise AppError("数据文件不是对象。")
            schema = raw.get("schema", 1)
            if schema != 1:
                raise AppError("不兼容或无效的存档。")
            self.extras = {key: value for key, value in raw.items() if key not in LIBRARY_KEYS and key != "station"}
            station = "station" in raw
            accounts = []
            removed = []
            self.unknown_connections = []
            changed = station
            for item in raw.get("accounts") or []:
                if not isinstance(item, dict):
                    raise AppError("账户格式无效。")
                account, normalized = self._decode_account(item)
                if normalized:
                    changed = True
                if account["kind"] == "LLM" or account["provider"] == "custom":
                    removed.append(account["id"])
                    changed = True
                    continue
                accounts.append(account)
            library = {
                "schema": 1,
                "accounts": accounts,
                "refreshMinutes": raw.get("refreshMinutes", 5),
                "warningThreshold": raw.get("warningThreshold", 20),
                "autoRefresh": raw.get("autoRefresh", True) if isinstance(raw.get("autoRefresh", True), bool) else True,
            }
            threshold = library["warningThreshold"]
            if isinstance(threshold, bool) or not isinstance(threshold, (int, float)) or not 5 <= float(threshold) <= 50:
                library["warningThreshold"] = min(50, max(5, float(threshold) if isinstance(threshold, (int, float)) and not isinstance(threshold, bool) else 20))
                changed = True
            if not isinstance(library["refreshMinutes"], int) or isinstance(library["refreshMinutes"], bool):
                raise AppError("不兼容或无效的存档。")
            self.library = library
            self._validate()
            for account_id in removed:
                self.credentials.delete(account_id)
            self.persisted = True
            self.load_failed = False
            if self.unknown_connections:
                self.notice = f"有 {len(self.unknown_connections)} 处连接方式无法识别，已回退为「本机软件自动读取」，请在账户设置中确认。"
            if changed or removed:
                self._write_library()
        except Exception as exc:
            self.library = empty_library()
            self.load_failed = True
            self.persisted = True
            self.notice = f"数据文件读取失败，原文件已保留，暂时禁止写入。请检查原文件后再试。\n{exc}"

    def _decode_account(self, raw: dict) -> tuple[dict, bool]:
        provider = raw.get("provider")
        if not isinstance(provider, str) or not known_provider(provider):
            raise AppError("账户设置无效。")
        kind = normalize_kind(str(raw.get("kind") or "Agent"))
        connection_raw = str(raw.get("connection") or AGENT_LOCAL)
        gemini_legacy = is_legacy_gemini_connection(provider, connection_raw)
        connection, unknown = (connection_raw, False) if gemini_legacy else normalize_connection(connection_raw)
        if unknown:
            self.unknown_connections.append(connection_raw)
        original_currency = str(raw.get("currency") or "USD")
        currency = original_currency.upper()
        dirty = currency != original_currency
        if len(currency) != 3 or any(not ("A" <= ch <= "Z") for ch in currency):
            currency = "USD"
            dirty = True
        name = str(raw.get("name") or "").strip()
        original_name = name
        legacy = {
            "ChatGPT / Codex",
            "OpenAI · ChatGPT",
            "ChatGPT/Codex",
            "Codex",
            display_name(provider),
            f"{display_name(provider)} · {agent_software(provider)}",
        }
        if kind == "Agent" and not gemini_legacy and (name in legacy or (provider == "openai" and "/" in name)):
            name = default_agent_name(provider)
        if name != original_name:
            dirty = True
        snapshot = raw.get("snapshot")
        if isinstance(snapshot, dict):
            before = len(snapshot.get("quotas") or [])
            snapshot = strip_status_quotas(snapshot)
            if len(snapshot.get("quotas") or []) != before:
                dirty = True
        history = []
        raw_history = raw.get("history") or []
        for item in raw_history:
            if not isinstance(item, dict):
                continue
            item = strip_status_quotas(item)
            if has_measured_values(item):
                history.append(item)
        history = history[-300:]
        if len(history) != len(raw_history):
            dirty = True
        account = {
            "id": str(raw.get("id") or uuid.uuid4()),
            "provider": provider,
            "kind": kind,
            "name": name,
            "plan": str(raw.get("plan") or ""),
            "connection": connection,
            "filePath": str(raw.get("filePath") or ""),
            "scopeID": raw.get("scopeID"),
            "region": raw.get("region"),
            "enabled": bool(raw.get("enabled", True)),
            "budget": raw.get("budget"),
            "currency": currency,
            "snapshot": snapshot,
            "lastAttempt": raw.get("lastAttempt"),
            "error": raw.get("error"),
            "statusNote": raw.get("statusNote"),
            "balanceBasis": raw.get("balanceBasis"),
            "baselines": raw.get("baselines"),
            "history": history,
            "lastQuotaChangedAt": raw.get("lastQuotaChangedAt"),
            "customConfig": raw.get("customConfig"),
            "showInRail": bool(raw.get("showInRail", True)),
            "autoDiscovered": bool(raw.get("autoDiscovered", False)),
            "connectorAuthorized": raw.get("connectorAuthorized") is True,
            "grokBotManualReading": raw.get("grokBotManualReading") if isinstance(raw.get("grokBotManualReading"), dict) else None,
        }
        forecast = raw.get(FORECAST_HISTORY)
        if (isinstance(forecast, dict) and isinstance(forecast.get("source"), str)
                and forecast["source"].startswith(_quota_account_key(account) + ":")
                and isinstance(forecast.get("observations"), list)):
            account[FORECAST_HISTORY] = {
                "source": forecast["source"],
                "observations": forecast["observations"][-MAX_OBSERVATIONS:],
            }
        if provider == "gemini" and connection == ANTIGRAVITY_REPORT:
            report = decode_report(raw.get(REPORT_FIELD))
            if report is not None:
                account[REPORT_FIELD] = report
        for key, value in raw.items():
            if key not in ACCOUNT_KEYS and key not in SECRET_FIELDS:
                account[key] = value
        return account, dirty

    def _validate(self) -> None:
        library = self.library
        if library.get("schema") != 1 or not isinstance(library.get("refreshMinutes"), int) or not 1 <= library["refreshMinutes"] <= 60:
            raise AppError("不兼容或无效的存档。")
        threshold = library.get("warningThreshold")
        if isinstance(threshold, bool) or not isinstance(threshold, (int, float)) or not 5 <= float(threshold) <= 50:
            raise AppError("不兼容或无效的存档。")
        identities = [item["id"] for item in library["accounts"]]
        if len(identities) != len(set(identities)):
            raise AppError("不兼容或无效的存档。")
        now = self.now()
        for account in library["accounts"]:
            if not account.get("name") or account["connection"] not in available_connections(account["provider"], account["kind"]):
                raise AppError("账户设置无效。")
            budget = account.get("budget")
            if budget is not None and (isinstance(budget, bool) or not isinstance(budget, (int, float)) or not budget > 0):
                raise AppError("账户设置无效。")
            currency = account.get("currency") or ""
            if len(currency) != 3 or any(not ("A" <= ch <= "Z") for ch in currency):
                raise AppError("账户设置无效。")
            if account.get("snapshot"):
                validate_snapshot(account["snapshot"], now)
            for item in account.get("history") or []:
                validate_snapshot(item, now)

    def _write_library(self, *, accounts: list[dict] | None = None) -> None:
        if self.load_failed:
            return
        if accounts is None:
            accounts = self.library["accounts"]
        for account in accounts:
            account["history"] = (account.get("history") or [])[-300:]
        payload = {
            "schema": self.library["schema"],
            "accounts": accounts,
            "refreshMinutes": self.library["refreshMinutes"],
            "warningThreshold": self.library["warningThreshold"],
            "autoRefresh": self.library["autoRefresh"],
        }
        payload.update(self.extras)
        _atomic_json(self.library_path, payload)
        self.persisted = True

    def _write_settings(self) -> None:
        _atomic_json(self.settings_path, self.settings)

    def _write_alerts(self) -> None:
        _atomic_json(self.alerts_path, {"failures": self.failures, "notifications": self.alert_memory})

    def _usage_ledger(self) -> UsageLedger:
        if self._ledger is None:
            self._ledger = UsageLedger(self.directory / "usage-ledger.sqlite")
        return self._ledger

    def _load_settings(self) -> None:
        if not self.settings_path.exists():
            return
        try:
            raw = json.loads(self.settings_path.read_text(encoding="utf-8"))
            if isinstance(raw, dict):
                self.settings.update({key: raw[key] for key in default_settings() if key in raw})
                self.zone = ZoneInfo(self.settings.get("timeZone") or "Asia/Shanghai")
                balance = self.settings["notifyLowBalance"]
                if type(balance) not in (int, float) or not 0 <= balance <= 1e9:
                    self.settings["notifyLowBalance"] = 0
                if self.settings["notifyThreshold"] not in (0, 75, 80, 90, 95):
                    self.settings["notifyThreshold"] = 0
                if self.settings["panelDock"] not in ("left", "right", "top", "floating"):
                    self.settings["panelDock"] = "right"
                for key in ("updateAppcastURL", "updatePublicKey"):
                    if not isinstance(self.settings[key], str):
                        self.settings[key] = ""
        except Exception:
            self.settings = default_settings()

    def _load_alerts(self) -> None:
        if not self.alerts_path.exists():
            return
        try:
            raw = json.loads(self.alerts_path.read_text(encoding="utf-8"))
            failures = raw.get("failures") if isinstance(raw, dict) else None
            if isinstance(failures, dict):
                self.failures = {str(key): int(value) for key, value in failures.items()}
            memory = raw.get("notifications") if isinstance(raw, dict) else None
            if isinstance(memory, dict):
                self.alert_memory = {key: value for key, value in memory.items() if isinstance(value, dict) and isinstance(value.get("windows", {}), dict)}
        except Exception:
            self.failures = {}

    def _ensure_writable(self) -> None:
        if self.load_failed:
            raise AppError("数据文件不可写，请检查原文件后再试。", "readonly")

    def _find(self, account_id: str) -> dict | None:
        return next((item for item in self.library["accounts"] if item["id"] == account_id), None)

    def _replace(self, account: dict) -> None:
        for index, item in enumerate(self.library["accounts"]):
            if item["id"] == account["id"]:
                self.library["accounts"][index] = account
                return
        self.library["accounts"].append(account)


def _same_source(left: dict, right: dict) -> bool:
    return all(left.get(key) == right.get(key) for key in SOURCE_FIELDS)


def _quota_account_key(account: dict) -> str:
    return _source_digest([account.get(key) for key in ("id", *SOURCE_FIELDS, "plan")])


def _quota_source_key(account: dict, origin: str | None) -> str:
    return _quota_account_key(account) + ":" + _source_digest(origin)


def _source_digest(value: object) -> str:
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode("ascii")).hexdigest()


def _atomic_json(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    data = json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True).encode("utf-8")
    temporary = path.with_name(path.name + ".tmp")
    try:
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        try:
            os.write(fd, data)
            os.fsync(fd)
        finally:
            os.close(fd)
        os.replace(temporary, path)
        try:
            os.chmod(path, 0o600)
        except OSError:
            pass
    finally:
        if temporary.exists():
            temporary.unlink()
