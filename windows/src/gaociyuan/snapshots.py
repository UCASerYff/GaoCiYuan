"""用量快照校验。无效快照直接拒绝，不用 0 或空额度填上。"""

from __future__ import annotations

import math
from datetime import datetime, timedelta

from gaociyuan.errors import AppError
from gaociyuan.timeutil import format_iso, parse_instant

INT64_HALF = (2**63 - 1) // 2
YEAR_SECONDS = 366 * 86_400


def is_status_quota(quota: dict) -> bool:
    title = str(quota.get("title") or "")
    identifier = str(quota.get("id") or "")
    return "status" in identifier or "运行中" in title or "未启动" in title


def strip_status_quotas(snapshot: dict) -> dict:
    copy = dict(snapshot)
    copy["quotas"] = [quota for quota in snapshot.get("quotas") or [] if not is_status_quota(quota)]
    return copy


def has_measured_values(snapshot: dict) -> bool:
    quotas = snapshot.get("quotas") or []
    costs = snapshot.get("costs") or []
    balances = snapshot.get("balances") or []
    credits = snapshot.get("creditBalances") or []
    incoming = snapshot.get("inputTokens")
    outgoing = snapshot.get("outputTokens")
    tokens = False
    if incoming is not None and outgoing is not None:
        try:
            total = int(incoming) + int(outgoing)
        except (TypeError, ValueError):
            total = None
        tokens = total is not None and total >= 0
    return bool(quotas or costs or balances or credits or tokens)


def remaining_percent(used: float) -> float:
    return max(0.0, min(100.0, 100.0 - used))


def _number(value: object) -> float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    number = float(value)
    if not math.isfinite(number):
        return None
    return number


def _optional_date(value: object, label: str) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str) or parse_instant(value) is None:
        raise AppError(f"{label}需为 ISO 8601 时间。")
    return format_iso(parse_instant(value))  # type: ignore[arg-type]


def normalize_snapshot(raw: object, now: datetime) -> dict:
    if not isinstance(raw, dict):
        raise AppError("快照必须是 JSON 对象。")
    observed = parse_instant(raw.get("observedAt")) if isinstance(raw.get("observedAt"), str) else None
    if observed is None:
        raise AppError("快照缺少 observedAt。")
    windows = raw.get("quotas")
    if windows is not None and not isinstance(windows, list):
        raise AppError("快照包含无效额度窗口。")
    quotas = []
    for item in windows or []:
        if not isinstance(item, dict):
            raise AppError("快照包含无效额度窗口。")
        used = _number(item.get("usedPercent"))
        if used is None or not item.get("id") or not item.get("title"):
            raise AppError("快照包含无效时间、重复项目、百分比或数值。")
        window = item.get("windowSeconds")
        window_number = None if window is None else _number(window)
        if window is not None and window_number is None:
            raise AppError("快照包含无效时间、重复项目、百分比或数值。")
        quotas.append(
            {
                "id": str(item["id"]),
                "title": str(item["title"]),
                "usedPercent": used,
                "resetsAt": _optional_date(item.get("resetsAt"), "重置时间"),
                "exhausted": bool(item.get("exhausted")) if item.get("exhausted") is not None else False,
                "windowSeconds": window_number,
            }
        )
    costs = _money_list(raw.get("costs") or [])
    balances = _money_list(raw.get("balances") or [])
    credits = []
    for item in raw.get("creditBalances") or []:
        if not isinstance(item, dict):
            raise AppError("快照包含无效积分余额。")
        value = _number(item.get("value"))
        if value is None or not item.get("id") or not item.get("title") or not item.get("unit"):
            raise AppError("快照包含无效时间、重复项目、百分比或数值。")
        credits.append({"id": str(item["id"]), "title": str(item["title"]), "unit": str(item["unit"]), "value": value})
    deadlines = []
    for item in raw.get("deadlines") or []:
        if not isinstance(item, dict) or not item.get("label") or not isinstance(item.get("date"), str):
            raise AppError("快照包含无效到期日。")
        deadlines.append({"label": str(item["label"]), "date": _optional_date(item.get("date"), "到期日")})
    incoming = raw.get("inputTokens")
    outgoing = raw.get("outputTokens")
    snapshot = {
        "observedAt": format_iso(observed),
        "periodStart": _optional_date(raw.get("periodStart"), "统计起始"),
        "periodEnd": _optional_date(raw.get("periodEnd"), "统计结束"),
        "source": str(raw.get("source") or ""),
        "quotas": quotas,
        "inputTokens": None if incoming is None else int(incoming),
        "outputTokens": None if outgoing is None else int(outgoing),
        "costs": costs,
        "balances": balances,
        "note": raw.get("note") if isinstance(raw.get("note"), str) else None,
        "deadlines": deadlines,
        "creditBalances": credits,
    }
    validate_snapshot(snapshot, now)
    return snapshot


def _money_list(items: object) -> list[dict]:
    if not isinstance(items, list):
        raise AppError("快照包含无效金额。")
    rows = []
    for item in items:
        if not isinstance(item, dict):
            raise AppError("快照包含无效金额。")
        value = _number(item.get("value"))
        currency = item.get("currency")
        if value is None or not isinstance(currency, str):
            raise AppError("快照包含无效时间、重复项目、百分比或数值。")
        rows.append({"currency": currency, "value": value})
    return rows


def validate_snapshot(snapshot: dict, now: datetime) -> None:
    observed = parse_instant(snapshot.get("observedAt") or "")
    if observed is None or observed > now + timedelta(seconds=300):
        raise AppError("快照包含无效时间、重复项目、百分比或数值。")
    credits = snapshot.get("creditBalances") or []
    quotas = snapshot.get("quotas") or []
    if len(credits) > 30:
        raise AppError("快照包含无效时间、重复项目、百分比或数值。")
    if any(not item.get("id") or not item.get("title") or not item.get("unit") for item in credits):
        raise AppError("快照包含无效时间、重复项目、百分比或数值。")
    if len({item["id"] for item in credits}) != len(credits):
        raise AppError("快照包含无效时间、重复项目、百分比或数值。")
    if len(quotas) > 100:
        raise AppError("快照包含无效时间、重复项目、百分比或数值。")
    seen: set[str] = set()
    for quota in quotas:
        used = quota.get("usedPercent")
        window = quota.get("windowSeconds")
        if not isinstance(used, (int, float)) or isinstance(used, bool) or not math.isfinite(used) or not 0 <= used <= 100:
            raise AppError("快照包含无效时间、重复项目、百分比或数值。")
        if not quota.get("title"):
            raise AppError("快照包含无效时间、重复项目、百分比或数值。")
        if window is not None and (not isinstance(window, (int, float)) or isinstance(window, bool) or not math.isfinite(window) or window <= 0 or window > YEAR_SECONDS):
            raise AppError("快照包含无效时间、重复项目、百分比或数值。")
        if quota["id"] in seen:
            raise AppError("快照包含无效时间、重复项目、百分比或数值。")
        seen.add(quota["id"])
    for token in (snapshot.get("inputTokens"), snapshot.get("outputTokens")):
        if token is None:
            continue
        if isinstance(token, bool) or not isinstance(token, int) or token < 0 or token > INT64_HALF:
            raise AppError("快照包含无效时间、重复项目、百分比或数值。")
    for money in list(snapshot.get("costs") or []) + list(snapshot.get("balances") or []):
        currency = money.get("currency") or ""
        value = money.get("value")
        if not isinstance(value, (int, float)) or isinstance(value, bool) or not math.isfinite(value):
            raise AppError("快照包含无效时间、重复项目、百分比或数值。")
        if len(currency) != 3 or any(not ("A" <= ch <= "Z") for ch in currency):
            raise AppError("快照包含无效时间、重复项目、百分比或数值。")
    if len({item["currency"] for item in snapshot.get("costs") or []}) != len(snapshot.get("costs") or []):
        raise AppError("快照包含无效时间、重复项目、百分比或数值。")
    if len({item["currency"] for item in snapshot.get("balances") or []}) != len(snapshot.get("balances") or []):
        raise AppError("快照包含无效时间、重复项目、百分比或数值。")
    deadlines = snapshot.get("deadlines") or []
    if len(deadlines) > 20 or any(not item.get("label") for item in deadlines):
        raise AppError("快照包含无效时间、重复项目、百分比或数值。")
    start = parse_instant(snapshot["periodStart"]) if snapshot.get("periodStart") else None
    end = parse_instant(snapshot["periodEnd"]) if snapshot.get("periodEnd") else None
    if start and end and start > end:
        raise AppError("统计起始时间不能晚于结束时间。")
    if snapshot.get("costs") or snapshot.get("inputTokens") is not None or snapshot.get("outputTokens") is not None:
        if start is None or end is None:
            raise AppError("Token 与费用必须注明统计起止时间。")


def same_observation(left: dict, right: dict) -> bool:
    keys = ("source", "quotas", "inputTokens", "outputTokens", "costs", "balances", "creditBalances", "note")
    return all(left.get(key) == right.get(key) for key in keys)


def quota_expired(quota: dict, now: datetime) -> bool:
    resets = quota.get("resetsAt")
    if not isinstance(resets, str):
        return False
    moment = parse_instant(resets)
    return moment is not None and moment <= now


def chart_quotas(snapshot: dict, now: datetime) -> list[dict]:
    return [quota for quota in snapshot.get("quotas") or [] if not is_status_quota(quota) and not quota_expired(quota, now)]


def credential_error(message: str | None) -> bool:
    if not message:
        return False
    phrases = ["密钥无效", "登录已过期", "登录态已过期", "凭证已被拒绝", "凭据失效", "会话已过期", "缺少会话项"]
    return any(phrase in message for phrase in phrases)
