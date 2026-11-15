"""账户、快照、手动 Grok Bot 读取和刷新。自动刷新不会打开 grokbot-usage.json。"""

from __future__ import annotations

import json
import os
import uuid
from datetime import datetime, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

from gaociyuan.catalog import (
    AGENT_LOCAL,
    available_connections,
    creation_kinds,
    default_agent_name,
    display_name,
    agent_software,
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
from gaociyuan.rings import adaptive_interval, attention, health_of, rail_accounts, ring_for
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
    "grokBotManualReading",
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
        "notifyThreshold": 0,
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
        provider = payload.get("provider")
        if not isinstance(provider, str) or not known_provider(provider):
            raise AppError("未知的 Agent 软件。")
        account_id = payload.get("id") or str(uuid.uuid4())
        existing = self._find(account_id)
        if existing is None and not creation_kinds(provider):
            raise AppError("搞词元仅记录 Agent 软件，不支持 API 账户。")
        if provider == "custom":
            raise AppError("搞词元仅记录 Agent 软件，不支持 API 账户。")
        connection, unknown = normalize_connection(str(payload.get("connection") or AGENT_LOCAL))
        if unknown:
            self.unknown_connections.append(str(payload.get("connection")))
        if connection not in available_connections(provider, "Agent"):
            raise AppError("这个 Agent 没有该连接方式。")
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
            "grokBotManualReading": None,
        }
        if existing:
            account["history"] = existing.get("history") or []
            same = _same_source(existing, account)
            if same and not (isinstance(secret, str) and secret.strip()):
                for key in ("snapshot", "lastAttempt", "error", "statusNote", "grokBotManualReading", "lastQuotaChangedAt"):
                    account[key] = existing.get(key)
            for key, value in existing.items():
                if key not in ACCOUNT_KEYS and key not in SECRET_FIELDS:
                    account[key] = value
            if existing.get("connection") != connection and not (isinstance(secret, str) and secret.strip()):
                self.credentials.delete(account_id)
        if isinstance(secret, str) and secret.strip():
            self.credentials.put(account_id, secret.strip())
        self._replace(account)
        self._validate()
        self._write_library()
        return account

    def delete_account(self, account_id: str) -> None:
        self._ensure_writable()
        before = len(self.library["accounts"])
        self.library["accounts"] = [item for item in self.library["accounts"] if item["id"] != account_id]
        if len(self.library["accounts"]) == before:
            raise AppError("没有这个账户。", "missing")
        self.credentials.delete(account_id)
        self.failures.pop(account_id, None)
        self._write_library()
        self._write_alerts()

    def set_credential(self, account_id: str, secret: str) -> None:
        self._ensure_writable()
        if self._find(account_id) is None:
            raise AppError("没有这个账户。", "missing")
        self.credentials.put(account_id, secret)

    def delete_credential(self, account_id: str) -> None:
        self.credentials.delete(account_id)

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
        now = self.now()
        if user_initiated:
            self._actions[account_id] = now
        if mode == "file":
            self._refresh_file(account, now)
            return
        if user_initiated:
            self._set_status(account, UNSUPPORTED, now)

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
        if self.load_failed or not self.library.get("autoRefresh", True):
            return []
        now = self.now()
        fixed = bool(self.settings.get("refreshFixedInterval"))
        done = []
        for account in list(self.library["accounts"]):
            if is_grok_bot_route(account):
                continue
            if windows_read_mode(account["provider"], account["connection"]) != "file":
                continue
            if not account.get("enabled", True):
                continue
            interval = self.library["refreshMinutes"] * 60 if fixed else adaptive_interval(
                self._changes.get(account["id"]),
                self._actions.get(account["id"]),
                now,
                True,
            )
            last = parse_instant(account.get("lastAttempt") or "")
            elapsed = 10**12 if last is None else (now - last).total_seconds()
            if elapsed >= interval:
                self.refresh(account["id"], user_initiated=False)
                done.append(account["id"])
        return done

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

    def view_account(self, account: dict) -> dict:
        now = self.now().astimezone(self.zone)
        threshold = float(self.library.get("warningThreshold") or 20)
        failures = self.failures.get(account["id"], 0)
        view = dict(account)
        view["hasCredential"] = self.credentials.has(account["id"])
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
        rail_source = [item for item in self.library["accounts"] if item.get("showInRail", True)]
        rail = rail_accounts(rail_source, self.now())
        rail_views = [self.view_account(item) for item in rail[:12]]
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
            "settings": self.settings,
            "accounts": accounts,
            "rail": rail_views,
            "railOverflow": max(0, len(rail) - 12),
            "grokReads": self.grok_reads,
        }

    def _refresh_file(self, account: dict, now: datetime) -> None:
        path = account.get("filePath") or ""
        try:
            if not path:
                raise AppError("请选择快照 JSON 文件。")
            if is_grokbot_filename(path):
                raise AppError("grokbot-usage.json 只能通过「读取本机额度」读取。")
            file_path = Path(path)
            data = file_path.read_bytes()
            if len(data) > 2_000_000:
                raise AppError("快照文件不能超过 2 MB。")
            snapshot = normalize_snapshot(json.loads(data.decode("utf-8")), now)
            snapshot = strip_status_quotas(snapshot)
            snapshot["source"] = "快照文件"
            validate_snapshot(snapshot, now)
        except AppError as exc:
            self._set_error(account, exc.message, now)
            return
        except (OSError, UnicodeError, json.JSONDecodeError):
            self._set_error(account, "快照文件无法读取，已保留上次数据。", now)
            return
        self._apply_snapshot(account, snapshot, now)

    def _apply_snapshot(self, account: dict, snapshot: dict, now: datetime) -> None:
        current = account.get("snapshot")
        account["lastAttempt"] = format_iso(now)
        account["error"] = None
        account["statusNote"] = None
        self.failures[account["id"]] = 0
        if current and same_observation(current, snapshot):
            self._write_library()
            self._write_alerts()
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
            for account_id in removed:
                self.credentials.delete(account_id)
            self._validate()
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
        connection, unknown = normalize_connection(connection_raw)
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
        if kind == "Agent" and (name in legacy or (provider == "openai" and "/" in name)):
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
            "grokBotManualReading": raw.get("grokBotManualReading") if isinstance(raw.get("grokBotManualReading"), dict) else None,
        }
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

    def _write_library(self) -> None:
        if self.load_failed:
            return
        for account in self.library["accounts"]:
            account["history"] = (account.get("history") or [])[-300:]
        payload = {
            "schema": self.library["schema"],
            "accounts": self.library["accounts"],
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
        _atomic_json(self.alerts_path, {"failures": self.failures})

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
    keys = ("provider", "kind", "connection", "filePath", "scopeID", "region", "customConfig")
    return all(left.get(key) == right.get(key) for key in keys)


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
