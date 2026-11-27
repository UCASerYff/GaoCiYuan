"""Public price tables update only through an explicit user request."""

from __future__ import annotations

import hashlib
import http.client
import json
import stat
import threading
import time
from datetime import datetime
from pathlib import Path
from urllib.parse import urlsplit

from gaociyuan.errors import AppError
from gaociyuan.usage_scan import PRICE_FIELDS, identifier, local_item, obj, price

PRICE_SOURCES = {
    "LiteLLM": "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json",
    "models.dev": "https://models.dev/api.json",
}
MAX_DOWNLOAD = 16 * 1024 * 1024
MAX_CACHE = 32 * 1024 * 1024
MAX_MODELS = 100_000
_refresh_lock = threading.Lock()
_LITELLM = dict(zip(("input_cost_per_token", "output_cost_per_token", "cache_read_input_token_cost",
                     "cache_creation_input_token_cost", "cache_creation_input_token_cost_above_1hr"), PRICE_FIELDS))
_MODELS_DEV = dict(zip(("input", "output", "cache_read", "cache_write"), PRICE_FIELDS))


def _cache_path(directory: Path, label: str) -> Path:
    return directory / "usage-prices" / (label.lower() + ".json")


def _save(path: Path, payload: dict) -> None:
    from gaociyuan.local_usage import _atomic_bytes

    _atomic_bytes(path, json.dumps(payload, ensure_ascii=False, separators=(",", ":"), allow_nan=False).encode("utf-8"))


def _load(path: Path) -> dict:
    try:
        info = local_item(path)
        if info is None or not stat.S_ISREG(info.st_mode) or info.st_size > MAX_CACHE:
            return {}
        with path.open("rb") as stream:
            raw = stream.read(MAX_CACHE + 1)
        return obj(json.loads(raw)) if len(raw) <= MAX_CACHE else {}
    except (OSError, ValueError, RecursionError):
        return {}


def _cache(directory: Path, label: str, now: datetime) -> tuple[dict, float | None]:
    payload = _load(_cache_path(directory, label))
    at = payload.get("time")
    models = payload.get("models")
    if type(at) not in (float, int) or not 0 <= at <= now.timestamp() or not isinstance(models, dict) or not 0 < len(models) <= MAX_MODELS:
        return {}, None
    cache = {}
    for model, rates in models.items():
        normalized = {key: price(value) for key, value in obj(rates).items() if key in PRICE_FIELDS}
        if not identifier(model, limit=1000) or not normalized or any(value is None for value in normalized.values()):
            return {}, None
        cache[model] = normalized
    return cache, at


def cached_rates(directory: Path, now: datetime) -> tuple[dict, list]:
    tables = {}
    warnings = []
    for label in PRICE_SOURCES:
        models, at = _cache(directory, label, now)
        tables[label] = models
        if at is not None and now.timestamp() - at > 3600:
            warnings.append(f"{label} 使用旧的本机价格缓存。")
    models = dict(tables["models.dev"])
    for name, rates in tables["LiteLLM"].items():
        models[name] = {**models.get(name, {}), **rates}
    if models and len(models) > MAX_MODELS:
        models = dict(tables["LiteLLM"])
    return models, warnings


def _fetch(url: str) -> bytes:
    if url not in PRICE_SOURCES.values():
        raise ValueError("invalid public price source")
    parsed = urlsplit(url)
    deadline = time.monotonic() + 45
    conn = http.client.HTTPSConnection(parsed.hostname, timeout=12)
    try:
        conn.request("GET", parsed.path, headers={"Accept": "application/json", "User-Agent": "GaoCiYuan-Windows/4.13"})
        with conn.getresponse() as response:
            if response.status != 200:
                raise ValueError("price service HTTP error")
            size = response.getheader("Content-Length")
            if size is not None and int(size) > MAX_DOWNLOAD:
                raise ValueError("price response exceeds limit")
            chunks = bytearray()
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError("price download timed out")
                if conn.sock is not None:
                    conn.sock.settimeout(min(remaining, 12))
                chunk = response.read1(min(64 * 1024, MAX_DOWNLOAD + 1 - len(chunks)))
                if not chunk:
                    return bytes(chunks)
                chunks.extend(chunk)
                if len(chunks) > MAX_DOWNLOAD:
                    raise ValueError("price response exceeds limit")
    finally:
        conn.close()


def _row_rates(data: dict, keys: dict, units: int) -> dict:
    result = {}
    for key, output in keys.items():
        raw = data.get(key)
        if raw is None:
            continue
        normalized = price(raw)
        if normalized is None or price(normalized * units) is None:
            raise ValueError("invalid model rate")
        result[output] = normalized * units
    return result


def _normalize(label: str, data: bytes) -> dict:
    root = obj(json.loads(data))
    if not root or len(root) > MAX_MODELS:
        raise ValueError("invalid price table")
    models = {}
    if label == "LiteLLM":
        for name, item in root.items():
            if not identifier(name, limit=1000):
                continue
            rates = _row_rates(obj(item), _LITELLM, 1_000_000)
            if any(key in rates for key in PRICE_FIELDS[:2]):
                models[name] = rates
    else:
        for provider, details in root.items():
            for key, row in obj(obj(details).get("models")).items():
                row = obj(row)
                name = identifier(row.get("id") or key, limit=1000)
                if not name:
                    continue
                rates = _row_rates(obj(row.get("cost")), _MODELS_DEV, 1)
                if not all(key in rates for key in PRICE_FIELDS[:2]):
                    continue
                models[f"{provider}/{name}"] = rates
                if provider in ("openai", "anthropic", "google"):
                    models[name] = rates
                if len(models) > MAX_MODELS:
                    raise ValueError("too many model rates")
    if not models:
        raise ValueError("no valid model rates")
    return models


def refresh_prices(directory: Path, now: datetime, *, fetch=None) -> dict:
    if not _refresh_lock.acquire(blocking=False):
        raise AppError("公开价格正在更新，请稍后再试。", "pricing-busy")
    try:
        return _refresh_prices(directory, now, fetch or _fetch)
    finally:
        _refresh_lock.release()


def _refresh_prices(directory: Path, now: datetime, fetch) -> dict:
    state_path = directory / "usage-prices" / "refresh.json"
    state = _load(state_path)
    started = now.timestamp()
    previous = state.get("attemptedAt")
    if type(previous) in (int, float) and 0 <= previous <= started:
        age = started - previous
        valid = [label for label in PRICE_SOURCES if _cache(directory, label, now)[1] == previous]
        if state.get("complete") is True and len(valid) == len(PRICE_SOURCES) and age < 3600:
            return {"fetchedAt": datetime.fromtimestamp(previous, now.tzinfo).isoformat(), "updatedSources": valid,
                    "warnings": ["公开价格仍在 1 小时缓存有效期内。"], "message": "公开价格仍在 1 小时缓存有效期内。"}
        if age < 900:
            raise AppError("公开价格更新间隔至少 15 分钟，原有缓存仍可使用。", "pricing-backoff")
    try:
        _save(state_path, {"attemptedAt": started, "complete": False})
    except OSError as error:
        raise AppError("无法保存价格更新状态。", "pricing-storage") from error
    updated = []
    warnings = []
    for label, url in PRICE_SOURCES.items():
        try:
            data = fetch(url)
            if len(data) > MAX_DOWNLOAD:
                raise ValueError("price response exceeds limit")
            models = _normalize(label, data)
            _save(_cache_path(directory, label), {"time": started, "source": url, "downloadSHA256": hashlib.sha256(data).hexdigest(), "models": models})
            updated.append(label)
        except (OSError, ValueError, RecursionError, http.client.HTTPException):
            warnings.append(f"{label} 价格读取失败，原有缓存仍可使用。")
    if not updated:
        raise AppError("公开价格更新失败，原有缓存仍可使用。", "pricing-unavailable")
    if len(updated) == len(PRICE_SOURCES):
        try:
            _save(state_path, {"attemptedAt": started, "complete": True})
        except OSError:
            warnings.append("价格已更新，但更新状态无法保存。")
    return {"fetchedAt": now.isoformat(), "updatedSources": updated, "warnings": warnings,
            "message": f"已更新{'、'.join(updated)}公开价格。下次采集使用本机缓存。"}
