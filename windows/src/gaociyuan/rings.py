"""悬浮圆环。Grok Bot 走剩余换算；其余账户按各自读数画弧，没有读数就是「—」。"""

from __future__ import annotations

import math
from datetime import datetime

from gaociyuan.grokbot import dedicated_ring_face, is_grok_bot_route
from gaociyuan.snapshots import chart_quotas, quota_expired, remaining_percent
from gaociyuan.timeutil import parse_instant

STALE_AFTER = 900
RAIL_CAPACITY = 12


def account_stale(account: dict, now: datetime) -> bool:
    snapshot = account.get("snapshot")
    if not snapshot:
        return True
    observed = parse_instant(snapshot.get("observedAt") or "")
    if observed is None:
        return True
    return (now - observed).total_seconds() > STALE_AFTER


def _trunc(value: float, decimals: int) -> str:
    factor = 10**decimals
    truncated = math.trunc(value * factor) / factor
    return f"{truncated:.{decimals}f}"


def compact_balance(value: float) -> str:
    absolute = abs(value)
    decimals = 0 if absolute >= 100 else 1 if absolute >= 10 else 2
    return _trunc(value, decimals)


def compact_credits(value: float) -> str:
    decimals = 0 if abs(value) >= 100 else 1
    return _trunc(value, decimals)


def ring_for(account: dict, threshold: float, now: datetime, zone) -> dict:
    if is_grok_bot_route(account):
        face = dedicated_ring_face(True, account.get("grokBotManualReading"), now, zone)
        assert face is not None
        payload = face.as_dict()
        payload["kind"] = "grokbot"
        payload["opacity"] = 0.45 if face.stale else 1
        payload["color"] = "secondary" if face.stale or face.shows_dash else "iris"
        return payload
    stale = account.get("snapshot") is not None and account_stale(account, now)
    if account.get("provider") == "dsh":
        return _balance_ring(account, now, stale, divisor=100, unit="¥", kind="dsh", help_text="DeepSeek 钱包余额")
    if account.get("provider") == "workbuddy":
        return _balance_ring(account, now, stale, divisor=1000, unit="", kind="workbuddy", help_text="WorkBuddy 积分余额 · 1000 积分满环", credits=True)
    snapshot = account.get("snapshot") or {}
    quotas = chart_quotas(snapshot, now) if snapshot else []
    if not quotas:
        return _empty("quota")
    fullest = max(enumerate(quotas), key=lambda item: (item[1].get("usedPercent") or 0, -item[0]))[1]
    remaining = remaining_percent(float(fullest["usedPercent"]))
    color = "secondary" if stale else "orange" if remaining <= threshold else "teal"
    elapsed = _window_elapsed(fullest, now)
    return {
        "kind": "quota",
        "showsDash": False,
        "fill": max(0.0, min(1.0, remaining / 100)),
        "label": f"{int(remaining)}%",
        "stale": stale,
        "dim": stale,
        "opacity": 0.5 if stale else 1,
        "color": color,
        "help": fullest.get("title") or "",
        "remainingPercent": remaining,
        "usedPercent": fullest.get("usedPercent"),
        "windowElapsed": elapsed,
    }


def _empty(kind: str) -> dict:
    return {
        "kind": kind,
        "showsDash": True,
        "fill": 0,
        "label": "—",
        "stale": False,
        "dim": False,
        "opacity": 1,
        "color": "secondary",
        "help": "",
        "remainingPercent": None,
        "usedPercent": None,
        "windowElapsed": None,
    }


def _balance_ring(account: dict, now: datetime, stale: bool, divisor: float, unit: str, kind: str, help_text: str, credits: bool = False) -> dict:
    balances = (account.get("snapshot") or {}).get("balances") or []
    if not balances:
        face = _empty(kind)
        face["help"] = help_text
        face["stale"] = stale
        face["dim"] = stale
        face["opacity"] = 0.5 if stale else 1
        return face
    value = float(balances[0]["value"])
    if credits:
        label = compact_credits(value)
        color = "secondary" if stale else "coral" if value < 10 else "amber" if value < 100 else "workbuddy"
    else:
        label = unit + compact_balance(value)
        color = "secondary" if stale else "coral" if value < 1 else "amber" if value < 5 else "deepseek"
    return {
        "kind": kind,
        "showsDash": False,
        "fill": max(0.0, min(1.0, value / divisor)),
        "label": label,
        "stale": stale,
        "dim": stale,
        "opacity": 0.5 if stale else 1,
        "color": color,
        "help": help_text,
        "remainingPercent": None,
        "usedPercent": None,
        "windowElapsed": None,
        "value": value,
    }


def _window_elapsed(quota: dict, now: datetime) -> float | None:
    resets = parse_instant(quota["resetsAt"]) if isinstance(quota.get("resetsAt"), str) else None
    window = quota.get("windowSeconds")
    if resets is None or not isinstance(window, (int, float)) or isinstance(window, bool) or window <= 0:
        return None
    if quota_expired(quota, now):
        return None
    start = resets.timestamp() - float(window)
    elapsed = (now.timestamp() - start) / float(window)
    return min(max(elapsed, 0.0), 1.0)


def rail_accounts(accounts: list[dict], now: datetime) -> list[dict]:
    visible = [account for account in accounts if account.get("showInRail", True) and account.get("enabled", True) and account.get("kind") == "Agent" and account.get("provider") != "custom"]

    def key(item: tuple[int, dict]) -> tuple:
        index, account = item
        moment = account.get("lastQuotaChangedAt")
        if not moment and account.get("history"):
            moment = account["history"][0].get("observedAt")
        if not moment and account.get("snapshot"):
            moment = account["snapshot"].get("observedAt")
        parsed = parse_instant(moment) if isinstance(moment, str) else None
        stamp = parsed.timestamp() if parsed else float("-inf")
        return (-stamp, index)

    ordered = [account for _, account in sorted(enumerate(visible), key=key)]
    return ordered


def attention(account: dict, threshold: float, now: datetime) -> list[str]:
    if not account.get("enabled", True) or not account.get("snapshot"):
        return []
    snapshot = account["snapshot"]
    lines = []
    for quota in snapshot.get("quotas") or []:
        if quota_expired(quota, now):
            continue
        remaining = remaining_percent(float(quota["usedPercent"]))
        if remaining <= threshold:
            lines.append(f"{quota['title']}剩余 {int(remaining)}%")
    start = snapshot.get("periodStart")
    end = snapshot.get("periodEnd")
    budget = account.get("budget")
    if isinstance(budget, (int, float)) and budget > 0 and _same_month(start, now) and _same_month(end, now):
        currency = account.get("currency")
        cost = next((item for item in snapshot.get("costs") or [] if item.get("currency") == currency), None)
        if cost and cost["value"] >= budget * (1 - threshold / 100):
            lines.append(f"{currency} 本月预算已使用 {cost['value'] / budget * 100:.0f}%")
    for money in snapshot.get("balances") or []:
        if money["value"] <= 0:
            lines.append(f"{money['currency']} 余额不足")
    if account.get("provider") == "dsh":
        for money in snapshot.get("balances") or []:
            if 0 < money["value"] < 1:
                lines.append(f"{money['currency']} 余额不足")
    if account.get("provider") == "workbuddy":
        for money in snapshot.get("balances") or []:
            if 0 < money["value"] < 10:
                lines.append("积分不足 10")
    for item in snapshot.get("deadlines") or []:
        moment = parse_instant(item.get("date") or "")
        if moment is not None and (moment - now).total_seconds() <= 3 * 86400:
            lines.append(f"{item['label']} 将于 {moment.astimezone(now.tzinfo).month}月{moment.astimezone(now.tzinfo).day}日 到期" if now.tzinfo else f"{item['label']} 即将到期")
    return lines


def _same_month(text: str | None, now: datetime) -> bool:
    moment = parse_instant(text or "")
    if moment is None:
        return False
    local_now = now.astimezone(now.tzinfo) if now.tzinfo else now
    local = moment.astimezone(now.tzinfo) if now.tzinfo else moment
    return local.year == local_now.year and local.month == local_now.month


def health_of(account: dict, threshold: float, now: datetime, failures: int) -> str:
    if attention(account, threshold, now):
        return "needsAction"
    if account.get("error"):
        from gaociyuan.snapshots import credential_error

        if credential_error(account.get("error")) or failures >= 3:
            return "needsAction"
        return "syncPaused"
    if account.get("snapshot") and account_stale(account, now):
        return "historical"
    return "ok"


def adaptive_interval(last_change: datetime | None, last_action: datetime | None, now: datetime, watched: bool = True) -> float:
    cap = 1800 if watched else 300
    ages = []
    for moment in (last_change, last_action):
        if moment is None:
            continue
        age = (now - moment).total_seconds()
        if age >= 0:
            ages.append(age)
    if not ages:
        return float(cap)
    quiet = min(ages)
    if quiet < 5 * 60:
        wait = 120
    elif quiet < 60 * 60:
        wait = 300
    elif quiet < 4 * 60 * 60:
        wait = 900
    else:
        wait = 1800
    return float(min(wait, cap))
