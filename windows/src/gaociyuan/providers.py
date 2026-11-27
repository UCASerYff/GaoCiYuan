"""Documented, read-only Windows quota connectors and Claude Code status-line capture."""

from __future__ import annotations

import json
import http.client
import math
import os
import re
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path
from queue import Empty, Queue
from typing import BinaryIO

from gaociyuan.catalog import ALIBABA_CODING_CLI, connection_details, windows_read_mode
from gaociyuan.discovery import ProviderDiscovery, _path_roots, automatic_provider, find_command
from gaociyuan.errors import AppError
from gaociyuan.snapshots import normalize_snapshot
from gaociyuan.timeutil import format_iso, parse_instant
from gaociyuan.version import MARKETING_VERSION

CLAUDE_STATUSLINE_FILE = "claude-statusline-usage.json"
CLAUDE_WINDOWS = {
    "five_hour": ("5 小时", 18_000),
    "seven_day": ("每周", 604_800),
    "spend_limit": ("消费上限", None),
}
MIMO_REGIONS = {"cn", "sgp", "ams"}
MAX_PAYLOAD = 1_048_576
CONNECTOR_TIMEOUT = 8


def _format_error(source: str) -> AppError:
    return AppError(f"{source}返回的额度格式无法识别，已保留上次数据。", "format")


def _epoch(value: object, source: str) -> str | None:
    if value is None:
        return None
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        try:
            return format_iso(datetime.fromtimestamp(value, timezone.utc))
        except (OverflowError, OSError, ValueError):
            pass
    raise _format_error(source)


def _quota(identifier: str, title: str, value: object, reset: str | None, seconds: int | None, source: str) -> dict:
    if not isinstance(value, (float, int)) or isinstance(value, bool) or not 0 <= value <= 100:
        raise _format_error(source)
    return {"id": identifier, "title": title, "usedPercent": value, "resetsAt": reset,
            "windowSeconds": seconds, "exhausted": value >= 100}


def _snapshot(source: str, now: datetime, quotas: list[dict], **values: object) -> dict:
    return normalize_snapshot({"observedAt": format_iso(now), "source": source, "quotas": quotas, **values}, now)


def parse_codex(result: dict, now: datetime) -> dict:
    source = "Codex 本机服务"
    pools = result.get("rateLimitsByLimitId")
    if not isinstance(pools, dict) or not pools:
        primary_pool = result.get("rateLimits")
        pool_id = primary_pool.get("limitId") if isinstance(primary_pool, dict) else None
        if pool_id is not None and not isinstance(pool_id, str):
            raise _format_error(source)
        pools = {pool_id or "codex": primary_pool} if isinstance(primary_pool, dict) else {}
    quotas = []
    plans = set()
    for pool_id, pool in sorted(pools.items()):
        if not isinstance(pool, dict) or not re.fullmatch(r"[\w.-]{1,80}", pool_id):
            raise _format_error(source)
        if any(provider in pool_id.casefold() for provider in ("claude", "gemini")):
            continue
        limit_name = pool.get("limitName")
        name = limit_name if isinstance(limit_name, str) and 0 < len(limit_name) <= 80 else pool_id
        plan = pool.get("planType")
        if isinstance(plan, str) and re.fullmatch(r"[\w -]{1,40}", plan):
            plans.add(plan)
        for key, default in (("primary", "主要窗口"), ("secondary", "次要窗口")):
            window = pool.get(key)
            if window is None:
                continue
            if not isinstance(window, dict):
                raise _format_error(source)
            duration = window.get("windowDurationMins")
            if duration is not None and (type(duration) is not int or not 0 < duration <= 527_040):
                raise _format_error(source)
            label = {300: "5 小时", 10080: "每周"}.get(duration, f"{duration} 分钟" if duration else default)
            quotas.append(_quota(f"{pool_id}-{key}", f"{name} · {label}", window.get("usedPercent"),
                                 _epoch(window.get("resetsAt"), source), duration * 60 if duration else None, source))
    if not quotas:
        raise AppError("Codex 未返回会员额度。请确认已在 Codex CLI 中登录 ChatGPT 会员账户。", "auth")
    parts = [*sorted(plans), "额度比例为 Codex 会员配额"]
    return _snapshot(source, now, quotas, note=" · ".join(parts))


def _codex_executable(configured: str) -> Path:
    names = ("codex", "codex-x86_64-pc-windows-msvc")
    if not isinstance(configured, str):
        raise AppError("请选择本地官方 Codex CLI 的 codex.exe 文件。", "missing")
    if configured:
        path = Path(configured)
        if path.is_absolute() and not str(path).startswith(("\\\\", "//")) and path.name.casefold() in {
            name + ".exe" for name in names
        } and path.is_file():
            return path
        raise AppError("请选择本地官方 Codex CLI 的 codex.exe 文件。", "missing")
    executable = find_command(names, native=True)
    if executable:
        return executable
    # Resolve the published npm package's executable directly, without using a cmd shim.
    target = "x86_64-pc-windows-msvc"
    vendor_paths = (
        Path("node_modules", "@openai", "codex", "node_modules", "@openai", "codex-win32-x64", "vendor"),
        Path("node_modules", "@openai", "codex-win32-x64", "vendor"),
        Path("node_modules", "@openai", "codex", "vendor"),
    )
    roots = _path_roots()
    if roaming := os.environ.get("APPDATA"):
        roots.append(Path(roaming, "npm"))
    for directory in roots:
        if str(directory).startswith(("\\\\", "//")):
            continue
        for vendor in vendor_paths:
            for relative in (Path(target, "bin", "codex.exe"), Path(target, "codex", "codex.exe")):
                candidate = directory / vendor / relative
                if candidate.is_file():
                    return candidate
    raise AppError("找不到 Codex CLI。请安装官方 Windows CLI，或选择它的 codex.exe 文件。", "missing")


def _read_codex(argv: list[str], workdir: Path, timeout: float = CONNECTOR_TIMEOUT) -> dict:
    """Use the app-server JSONL handshake. Never send a thread/turn/login request."""
    options = {"creationflags": subprocess.CREATE_NO_WINDOW} if os.name == "nt" else {}
    try:
        proc = subprocess.Popen(argv, cwd=workdir, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, **options)
    except OSError:
        raise AppError("无法启动 Codex CLI。请检查官方 CLI 的安装路径。", "missing") from None
    messages = Queue()
    stop = threading.Event()
    assert proc.stdin is not None and proc.stdout is not None

    def receive() -> None:
        remaining = MAX_PAYLOAD
        try:
            for _ in range(200):
                line = proc.stdout.readline(remaining + 1)
                if stop.is_set() or not line:
                    break
                remaining -= len(line)
                if remaining < 0:
                    break
                try:
                    message = json.loads(line)
                except (UnicodeError, ValueError):
                    continue
                if isinstance(message, dict):
                    messages.put(message)
        except OSError:
            pass
        finally:
            messages.put(None)

    def send(event: dict) -> None:
        proc.stdin.write(json.dumps(event).encode("utf-8") + b"\n")
        proc.stdin.flush()

    reader = threading.Thread(target=receive, daemon=True)
    deadline = time.monotonic() + timeout
    reader.start()
    try:
        send({"id": 1, "method": "initialize", "params": {
            "clientInfo": {"name": "gaociyuan", "title": "GaoCiYuan", "version": MARKETING_VERSION}
        }})
        expected = 1
        while time.monotonic() < deadline:
            message = messages.get(timeout=max(0, deadline - time.monotonic()))
            if message is None:
                break
            if message.get("id") != expected or "method" in message:
                continue
            if "error" in message:
                if expected == 1:
                    raise AppError("Codex CLI 服务初始化失败。请检查官方 CLI 版本。", "format")
                detail = message["error"]
                code = detail.get("code") if isinstance(detail, dict) else None
                body = detail.get("message") if isinstance(detail, dict) else None
                if code in (401, 403) or isinstance(body, str) and re.search(r"\b(401|403|auth|login|sign.in)\b", body, re.I):
                    raise AppError("Codex 登录无效或没有会员额度权限。请在 Codex CLI 中重新登录。", "auth")
                if code == 429 or isinstance(body, str) and re.search(r"\b(429|rate.limit)\b", body, re.I):
                    raise AppError("Codex 服务限流，请稍后再试。", "rate")
                raise AppError("Codex 服务未返回额度，请检查网络和登录状态。", "network")
            result = message.get("result")
            if not isinstance(result, dict):
                raise _format_error("Codex 本机服务")
            if expected == 2:
                return result
            send({"method": "initialized"})
            send({"id": 2, "method": "account/rateLimits/read"})
            expected = 2
    except (Empty, OSError):
        pass
    finally:
        stop.set()
        try:
            proc.stdin.close()
        except OSError:
            pass
        try:
            proc.wait(timeout=0.35)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
        reader.join(timeout=0.5)
        if not reader.is_alive():
            proc.stdout.close()
    raise AppError("Codex CLI 服务未及时返回额度，请检查登录和网络。", "network")


def capture_claude_statusline(stream: BinaryIO, directory: Path, now: datetime) -> str | None:
    """Accept Claude Code's official status-line payload and keep only quota fields."""
    try:
        body = stream.read(MAX_PAYLOAD + 1)
        raw = json.loads(body) if len(body) <= MAX_PAYLOAD else None
    except (ValueError, UnicodeError):
        raw = None
    rates = raw.get("rate_limits") if isinstance(raw, dict) else None
    if not isinstance(rates, dict):
        return None
    quotas = []
    for key, (title, duration) in CLAUDE_WINDOWS.items():
        window = rates.get(key)
        if not isinstance(window, dict) or window.get("used_percentage") is None:
            continue
        used = window["used_percentage"]
        if key == "spend_limit" and type(used) in (float, int) and used > 100 and math.isfinite(used):
            used = 100  # The app's quota model caps usage percentages at an exhausted window.
        reset = _epoch(window.get("resets_at"), "Claude Code 状态栏")
        if reset is not None and parse_instant(reset) <= now:
            continue
        quotas.append(_quota(f"claude-{key}", title, used, reset, duration, "Claude Code 状态栏"))
    if not quotas:
        return None
    snapshot = _snapshot("Claude Code 状态栏推送", now, quotas)
    directory.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=directory, prefix=".claude-usage-", delete=False) as output:
        temporary = Path(output.name)
        try:
            output.write(json.dumps(snapshot, ensure_ascii=False).encode("utf-8"))
            output.close()
            os.replace(temporary, directory / CLAUDE_STATUSLINE_FILE)
        finally:
            temporary.unlink(missing_ok=True)
    return " · ".join(f"{quota['title']} {quota['usedPercent']:g}%" for quota in quotas)


def _read_claude(directory: Path, now: datetime) -> dict:
    source = "Claude Code 状态栏推送"
    try:
        with (directory / CLAUDE_STATUSLINE_FILE).open("rb") as handle:
            body = handle.read(MAX_PAYLOAD + 1)
    except FileNotFoundError:
        raise AppError("等待 Claude Code 状态栏推送。请配置 statusLine，并在 Claude Code 中完成一次响应。", "missing") from None
    except OSError:
        raise AppError("Claude Code 状态栏记录无法读取，已保留上次数据。", "format") from None
    try:
        raw = json.loads(body) if len(body) <= MAX_PAYLOAD else None
        if not isinstance(raw, dict) or raw.get("source") != source:
            raise _format_error(source)
        snapshot = normalize_snapshot(raw, now)
    except (ValueError, TypeError, KeyError, OverflowError):
        raise _format_error(source) from None
    captured = parse_instant(snapshot["observedAt"])
    if captured is None or now - captured > timedelta(hours=6) or not any(
        not item["resetsAt"] or parse_instant(item["resetsAt"]) > now for item in snapshot["quotas"]
    ):
        raise AppError("当前 Claude Code 状态栏额度已过期，等待新的推送。", "missing")
    return snapshot


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def _quota_json(endpoint: str, key: str, source: str, *, header: str = "api-key") -> dict:
    request = urllib.request.Request(endpoint, headers={"Accept": "application/json", header: key})
    deadline = time.monotonic() + CONNECTOR_TIMEOUT
    try:
        with urllib.request.build_opener(_NoRedirect).open(request, timeout=CONNECTOR_TIMEOUT) as response:
            chunks = []
            size = 0
            while size <= MAX_PAYLOAD and time.monotonic() < deadline:
                chunk = response.read1(min(16384, MAX_PAYLOAD + 1 - size))
                if not chunk:
                    break
                chunks.append(chunk)
                size += len(chunk)
            if size > MAX_PAYLOAD or time.monotonic() >= deadline:
                raise _format_error(source)
    except urllib.error.HTTPError as error:
        code = error.code
        error.close()
        if code in {401, 403}:
            raise AppError(f"{source}密钥无效或权限不足，请检查套餐密钥。", "auth") from None
        if code == 429:
            raise AppError(f"{source}限流，请稍后再试。", "rate") from None
        raise AppError(f"{source}返回 HTTP {code}，已保留上次数据。", "network") from None
    except (OSError, ValueError, http.client.HTTPException):
        raise AppError(f"{source}网络请求失败，已保留上次数据。", "network") from None
    try:
        payload = json.loads(b"".join(chunks))
    except (ValueError, UnicodeError):
        raise _format_error(source) from None
    if not isinstance(payload, dict):
        raise _format_error(source)
    return payload


def parse_mimo(payload: dict, now: datetime) -> dict:
    source = "MiMo Token Plan"
    period, quota = payload.get("period"), payload.get("quota")
    if payload.get("object") != "token_plan" or not isinstance(period, dict) or not isinstance(quota, dict):
        raise _format_error(source)
    try:
        dates = [datetime.strptime(period[key], "%Y-%m-%d %H:%M:%S").replace(tzinfo=timezone.utc)
                 for key in ("start_at", "end_at")]
    except (KeyError, ValueError, TypeError):
        raise _format_error(source) from None
    start, end = dates
    if end <= start or end <= now:
        raise AppError("MiMo Token Plan 额度周期已结束，已保留上次数据。", "missing")
    total, used, remaining = (quota.get(key) for key in ("total_credits", "used_credits", "remaining_credits"))
    if any(type(value) is not int or not 0 <= value <= 2**63 - 1 for value in (total, used, remaining)):
        raise _format_error(source)
    if remaining != max(0, total - used):
        raise _format_error(source)
    quotas = []
    if total:
        seconds = int((end - start).total_seconds())
        quotas = [_quota("mimo-billing-cycle", "MiMo · 当前套餐周期", min(100, used / total * 100),
                         format_iso(end), seconds, source)]
    plan = payload.get("plan_code")
    note = plan if isinstance(plan, str) and re.fullmatch(r"[\w .-]{1,80}", plan) else None
    return _snapshot(source, now, quotas, periodStart=format_iso(start), periodEnd=format_iso(end), note=note,
                     creditBalances=[{"id": "mimo-remaining", "title": "剩余套餐积分", "unit": "Credits",
                                      "value": remaining}])


def _minimax_command() -> list[str]:
    return _npm_command("mmx-cli", "mmx.mjs", "MiniMax CLI", ["quota", "show", "--output", "json"])


def _npm_command(package: str, module: str, source: str, arguments: list[str]) -> list[str]:
    node = find_command(("node",), native=True)
    if not node:
        raise AppError(f"找不到运行{source}所需的 Node.js。", "missing")
    roots = _path_roots()
    if roaming := os.environ.get("APPDATA"):
        roots.append(Path(roaming, "npm"))
    for directory in roots:
        if str(directory).startswith(("\\\\", "//")):
            continue
        script = directory / "node_modules" / package / "dist" / module
        if script.is_file():
            return [str(node), str(script), *arguments]
    raise AppError(f"找不到{source}。请安装官方 {package}，并在终端完成登录。", "missing")


def _read_cli_json(argv: list[str], workdir: Path, source: str) -> dict:
    options = {"creationflags": subprocess.CREATE_NO_WINDOW} if os.name == "nt" else {}
    try:
        proc = subprocess.Popen(argv, cwd=workdir, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, **options)
    except OSError:
        raise AppError(f"无法启动{source}，请检查安装。", "missing") from None
    assert proc.stdout is not None
    responses = Queue()

    def receive() -> None:
        with proc.stdout:
            try:
                responses.put(proc.stdout.read(MAX_PAYLOAD + 1))
            except OSError:
                responses.put(b"")

    reader = threading.Thread(target=receive, daemon=True)
    end = time.monotonic() + CONNECTOR_TIMEOUT
    reader.start()
    try:
        content = responses.get(timeout=max(0, end - time.monotonic()))
        if len(content) > MAX_PAYLOAD:
            raise _format_error(source)
        if proc.wait(timeout=max(0, end - time.monotonic())) != 0:
            raise AppError(f"{source}未返回套餐额度，请检查 CLI 登录状态和网络。", "network")
    except (Empty, subprocess.TimeoutExpired):
        raise AppError(f"{source}额度读取超时，已保留上次数据。", "network") from None
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait()
        reader.join(timeout=0.5)
    try:
        payload = json.loads(content)
    except (ValueError, UnicodeError):
        raise _format_error(source) from None
    if not isinstance(payload, dict):
        raise _format_error(source)
    return payload


def _finite_number(value: object) -> float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float, str)):
        return None
    try:
        converted = float(value)
    except (OverflowError, ValueError):
        return None
    return converted if math.isfinite(converted) else None


def parse_minimax(payload: dict, now: datetime) -> dict:
    source = "MiniMax CLI"
    status = payload.get("base_resp")
    if isinstance(status, dict) and (code := _finite_number(status.get("status_code"))) not in (None, 0):
        if code == 1004:
            raise AppError("MiniMax CLI 登录无效，请在终端重新登录 Token Plan。", "auth")
        raise AppError("MiniMax CLI 报告套餐服务暂不可用，已保留上次数据。", "network")
    body = payload.get("data") if isinstance(payload.get("data"), dict) else payload
    models = body.get("model_remains")
    if not isinstance(models, list):
        raise AppError("MiniMax CLI 未返回 Token Plan 额度。请检查登录的套餐类型。", "missing")
    quotas = []
    for row in models:
        if not isinstance(row, dict):
            raise _format_error(source)
        name = row.get("model_name")
        if not isinstance(name, str) or not re.fullmatch(r"[\w.-]{1,80}", name):
            continue
        for window, prefix, fixed in (("interval", "", None), ("weekly", "weekly_", 604_800)):
            remaining = _finite_number(row.get(f"current_{window}_remaining_percent"))
            total = _finite_number(row.get(f"current_{window}_total_count"))
            status = _finite_number(row.get(f"current_{window}_status"))
            if remaining is None or not 0 <= remaining <= 100 or total == 0 and (status == 3 or remaining == 100):
                continue
            start = _finite_number(row.get(prefix + "start_time"))
            end = _finite_number(row.get(prefix + "end_time"))
            duration = fixed or (int((end - start) / 1000) if start and end and end > start > 0 else None)
            if duration is None or not 0 < duration <= 366 * 86400:
                continue
            reset = _epoch(end / 1000, source) if end and end > 0 else None
            if reset and parse_instant(reset) <= now:
                continue
            title = "每周" if window == "weekly" else ("5 小时" if duration == 18000 else "当前窗口")
            display = "MiniMax" if name.casefold() == "general" else name
            quotas.append(_quota(f"minimax-{name}-{window}", f"{display} · {title}",
                                 100 - remaining, reset, duration, source))
    if not quotas:
        raise AppError("MiniMax CLI 未返回含百分比的有效套餐窗口，已保留上次数据。", "missing")
    return _snapshot(source, now, quotas)


def parse_opencode_go(payload: dict, now: datetime) -> dict:
    source = "OpenCode Go 官方接口"
    usage = payload.get("usage")
    if not isinstance(usage, dict):
        raise _format_error(source)
    quotas = []
    windows = (("rolling", "5 小时", 18_000), ("weekly", "每周", 604_800), ("monthly", "每月", None))
    for key, label, duration in windows:
        meter = usage.get(key)
        if meter is None:
            continue
        if not isinstance(meter, dict) or meter.get("status") not in ("ok", "rate-limited"):
            raise _format_error(source)
        reset = parse_instant(meter.get("resetsAt"))
        percent = meter.get("percent")
        if reset is None or type(percent) is not int or (meter["status"] == "rate-limited" and percent != 100):
            raise _format_error(source)
        quotas.append(_quota(f"opencode-go-{key}", f"OpenCode Go · {label}",
                             percent, format_iso(reset), duration, source))
    if not quotas:
        raise _format_error(source)
    return _snapshot(source, now, quotas)


def parse_bailian(payload: dict, now: datetime, *, coding: bool) -> dict:
    plan = "Coding Plan" if coding else "Token Plan"
    source = f"百炼 CLI {plan}"
    body = payload.get("result") if isinstance(payload.get("result"), dict) else payload
    windows = []
    if coding:
        for key, title, duration in (("per5Hour", "5 小时", 18_000), ("perWeek", "每周", 604_800),
                                     ("perBillMonth", "每月", None)):
            data = body.get(key)
            if isinstance(data, dict):
                windows.append((key, title, duration, data.get("percentage"), data.get("resetTime")))
    elif body.get("hasQuotaData") is not False:
        units = {"Hour": (3600, "小时"), "Day": (86400, "天"), "Week": (604800, "周"), "Month": (None, "月")}
        for field, fraction in body.items():
            match = re.fullmatch(r"(per([1-9][0-9]{0,2})(Hour|Day|Week|Month))Percentage", field)
            if not match:
                continue
            key, count, unit = match.groups()
            seconds, label = units[unit]
            windows.append((key, f"{count} {label}", seconds * int(count) if seconds else None,
                            fraction, body.get(key + "ResetTime")))
    quotas = []
    for key, title, duration, raw, reset_value in windows:
        ratio = _finite_number(raw)
        if ratio is None or ratio < 0 or duration and duration > 366 * 86400:
            continue
        reset_raw = _finite_number(reset_value)
        reset = _epoch(reset_raw / 1000, source) if reset_raw and reset_raw > 0 else None
        if reset and parse_instant(reset) <= now:
            continue
        quotas.append(_quota(f"bailian-{plan.casefold().replace(' ', '-')}-{key}", f"{plan} · {title}",
                             min(100, ratio * 100), reset, duration, source))
    if not quotas:
        raise AppError(f"{source}未返回当前个人套餐额度，请检查控制台登录和订阅状态。", "missing")
    quotas.sort(key=lambda quota: quota["windowSeconds"] or 366 * 86400)
    return _snapshot(source, now, quotas)


def read_connector(account: dict, secret: str | None, now: datetime, *, data_dir: Path | None = None) -> dict:
    provider, connection = account.get("provider", ""), account.get("connection", "")
    if windows_read_mode(provider, connection) != "connector":
        raise AppError(connection_details(provider, connection)["help"], "unsupported")
    if provider == "openai":
        executable = _codex_executable(account.get("filePath") or "")
        if data_dir is None:
            raise AppError("Codex 读取需要应用资料目录。", "missing")
        data_dir.mkdir(parents=True, exist_ok=True)
        return parse_codex(_read_codex([str(executable), "app-server", "--listen", "stdio://"], data_dir), now)
    if provider == "claude":
        if data_dir is None:
            raise AppError("Claude Code 读取需要应用资料目录。", "missing")
        return _read_claude(data_dir, now)
    if provider == "mimo":
        if not isinstance(secret, str) or not re.fullmatch(r"tp-[A-Za-z0-9_-]{1,512}", secret):
            raise AppError("请填写 MiMo 个人 Token Plan 专属密钥（tp-）。", "missing")
        region = account.get("region") or "cn"
        if not isinstance(region, str) or region not in MIMO_REGIONS:
            raise AppError("请选择 MiMo 密钥对应的中国、新加坡或欧洲集群。", "missing")
        endpoint = f"https://token-plan-{region}.xiaomimimo.com/v1/platform/token_plan"
        return parse_mimo(_quota_json(endpoint, secret, "MiMo Token Plan"), now)
    if provider == "minimax":
        if data_dir is None:
            raise AppError("MiniMax CLI 读取需要应用资料目录。", "missing")
        data_dir.mkdir(parents=True, exist_ok=True)
        return parse_minimax(_read_cli_json(_minimax_command(), data_dir, "MiniMax CLI"), now)
    if provider == "opencode":
        if not isinstance(secret, str) or not re.fullmatch(r"[A-Za-z0-9_.=-]{1,512}", secret):
            raise AppError("请填写 OpenCode Go 专属 API Key。", "missing")
        payload = _quota_json("https://opencode.ai/inference/go/v1/usage", f"Bearer {secret}",
                              "OpenCode Go", header="Authorization")
        return parse_opencode_go(payload, now)
    if provider == "alibaba":
        if data_dir is None:
            raise AppError("百炼 CLI 读取需要应用资料目录。", "missing")
        data_dir.mkdir(parents=True, exist_ok=True)
        coding = connection == ALIBABA_CODING_CLI
        command = ["usage", "coding-plan" if coding else "token-plan", "--output", "json"]
        argv = _npm_command("bailian-cli", "bailian.mjs", "百炼 CLI", command)
        return parse_bailian(_read_cli_json(argv, data_dir, "百炼 CLI"), now, coding=coding)
    raise AppError("此连接在 Windows 暂无经验证的读取方式。", "unsupported")
