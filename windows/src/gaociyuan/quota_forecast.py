"""Estimate time to exhaust a measured percentage quota within its reset window."""

from __future__ import annotations

from datetime import datetime, timedelta
from statistics import median, quantiles

from gaociyuan.grokbot import is_grok_bot_route
from gaociyuan.rings import STALE_AFTER
from gaociyuan.snapshots import YEAR_SECONDS, is_status_quota, remaining_percent
from gaociyuan.timeutil import format_iso, parse_instant

MAX_OBSERVATIONS = 48
LOOKBACK = timedelta(hours=24)
MAX_GAP_SECONDS = 2 * 3600
MIN_POINT_SPACING = 5 * 60
MIN_SPAN_SECONDS = 30 * 60
MIN_USAGE_CHANGE = 1.0


def _history(account: dict) -> tuple[str | None, list]:
    history = account.get('quotaForecastHistory')
    if isinstance(history, dict) and isinstance(history.get('source'), str) and isinstance(history.get('observations'), list):
        return history['source'], history['observations'][-MAX_OBSERVATIONS:]
    return None, []


def _window_value(quota: dict, observed: datetime) -> list | None:
    reset = _instant(quota.get('resetsAt'))
    used = quota.get('usedPercent')
    duration = quota.get('windowSeconds')
    if not _usage_value(used) or is_status_quota(quota) or reset is None or reset <= observed:
        return None
    if duration is not None and (type(duration) not in (int, float) or not 0 < duration <= YEAR_SECONDS
                                 or (reset - observed).total_seconds() > duration):
        return None
    return [used, format_iso(reset), duration]


def record_quota_observation(account: dict, snapshot: dict, source_key: str, now: datetime) -> None:
    """Keep distinct timestamps separately from the existing deduplicated history and ledger."""
    if is_grok_bot_route(account):
        return
    source, observations = _history(account)
    if source != source_key:
        account.pop('quotaForecastHistory', None)
        observations = []
    observed = _instant(snapshot.get('observedAt'))
    if observed is None or not now - LOOKBACK <= observed <= now:
        return
    windows = {}
    for quota in snapshot.get('quotas') or []:
        value = _window_value(quota, observed)
        if value is not None:
            windows[quota['id']] = value
    if not windows and not observations:
        return

    latest = observations[-1] if observations else None
    latest_at = _observation_time(latest)
    if latest_at is not None and observed <= latest_at:
        if observed < latest_at or windows == latest.get('windows'):
            return
        # Conflicting readings from the same timestamp cannot establish a rate.
        observations = []
    cutoff = observed - LOOKBACK
    observations = [row for row in observations if (at := _observation_time(row)) and at >= cutoff]
    observations.append({'at': format_iso(observed), 'windows': windows})
    account['quotaForecastHistory'] = {'source': source_key, 'observations': observations[-MAX_OBSERVATIONS:]}


def quota_forecast(account: dict, now: datetime) -> dict:
    if not account.get('enabled', True):
        return _result('excluded', 'disabled')
    if is_grok_bot_route(account):
        return _result('excluded', 'manualGrok')
    snapshot = account.get('snapshot') or {}
    if not snapshot:
        return _result('insufficient', 'noReadings')
    quotas = [quota for quota in snapshot.get('quotas') or [] if not is_status_quota(quota)]
    if not quotas:
        return _result('excluded', 'nonQuota')

    observed = _instant(snapshot.get('observedAt'))
    _, observations = _history(account)
    windows = [_forecast_window(quota, snapshot.get('source'), observed, observations, now,
                                bool(account.get('error') or account.get('statusNote'))) for quota in quotas]
    status = 'available' if any(item['status'] != 'insufficient' for item in windows) else 'insufficient'
    return _result(status, None, windows)


def _result(status: str, reason: str | None, windows: list | None = None) -> dict:
    return {'status': status, 'reason': reason, 'windows': windows or []}


def _forecast_window(quota: dict, source: str | None, observed: datetime | None, observations: list,
                     now: datetime, sync_issue: bool) -> dict:
    reset = _instant(quota.get('resetsAt'))
    used = quota.get('usedPercent')
    remaining = remaining_percent(used) if _usage_value(used) else None
    result = {
        'id': quota['id'], 'title': quota['title'], 'status': 'insufficient', 'reason': None,
        'source': source or '', 'observedAt': format_iso(observed) if observed else None,
        'remainingPercent': remaining, 'resetsAt': format_iso(reset) if reset else None,
        'estimatedExhaustedAt': None, 'confidence': None, 'sampleCount': 0, 'observedSpanSeconds': 0,
        'ratePercentPerHour': None,
    }
    if reset is not None and reset <= now:
        return {**result, 'reason': 'expired'}
    if observed is None or not 0 <= (now - observed).total_seconds() <= STALE_AFTER:
        return {**result, 'reason': 'stale'}
    if remaining == 0:
        return {**result, 'status': 'exhausted'}
    if reset is None:
        return {**result, 'reason': 'unknownReset'}
    if sync_issue:
        return {**result, 'reason': 'syncIssue'}

    target = _window_value(quota, observed)
    points = _recent_points(observations, quota['id'], target, observed, reset)
    if len(points) > 12:
        # Evenly spread the points across the evidence interval when polling is frequent.
        points = [points[index * (len(points) - 1) // 11] for index in range(12)]
    span = (points[-1][0] - points[0][0]).total_seconds() if points else 0
    result.update(sampleCount=len(points), observedSpanSeconds=int(span))
    if len(points) < 3 or span < MIN_SPAN_SECONDS:
        return {**result, 'reason': 'insufficientHistory'}
    if points[-1][1] - points[0][1] < MIN_USAGE_CHANGE:
        return {**result, 'reason': 'lowChange'}

    rates = []
    for index, (earlier, initial) in enumerate(points[:-1]):
        for later, final in points[index + 1:]:
            elapsed = (later - earlier).total_seconds()
            if elapsed >= 2 * MIN_POINT_SPACING:
                rates.append((final - initial) / elapsed)
    if len(rates) < 3 or remaining is None:
        return {**result, 'reason': 'insufficientHistory'}
    rate = median(rates)
    lower, _, upper = quantiles(rates, n=4, method='inclusive')
    seconds_to_reset = (reset - observed).total_seconds()
    required_rate = remaining / seconds_to_reset
    if lower <= 0 or upper > lower * 3 or lower <= required_rate < upper:
        return {**result, 'reason': 'unstable'}

    seconds_to_exhaustion = remaining / rate
    if min(seconds_to_exhaustion, seconds_to_reset) > max(3 * 3600, 3 * span):
        return {**result, 'reason': 'beyondEvidence'}
    risk = seconds_to_exhaustion < seconds_to_reset
    estimated = observed + timedelta(seconds=seconds_to_exhaustion) if risk else None
    confidence = 'higher' if len(points) >= 5 and span >= 3600 and upper <= lower * 1.5 else 'moderate'
    return {**result, 'status': 'risk' if risk else 'stable', 'confidence': confidence,
            'reason': 'estimatedPassed' if estimated and estimated <= now else None,
            'ratePercentPerHour': round(rate * 3600, 2),
            'estimatedExhaustedAt': format_iso(estimated) if estimated else None}


def _recent_points(observations: list, identifier: str, target: list | None, observed: datetime,
                   reset: datetime) -> list[tuple[datetime, float]]:
    if target is None or not observations:
        return []
    latest = observations[-1]
    if _observation_time(latest) != observed or _recorded_window(latest, identifier) != target:
        return []
    points = [(observed, target[0])]
    last_at, last_used = points[0]
    for row in reversed(observations[:-1]):
        at = _observation_time(row)
        window = _recorded_window(row, identifier)
        if (at is None or not 0 < (last_at - at).total_seconds() <= MAX_GAP_SECONDS
                or observed - at > LOOKBACK or not isinstance(window, list) or len(window) != 3
                or window[1:] != target[1:] or not _usage_value(window[0]) or window[0] > last_used):
            break
        if target[2] is not None and (reset - at).total_seconds() > target[2]:
            break
        last_at, last_used = at, window[0]
        if (points[-1][0] - at).total_seconds() >= MIN_POINT_SPACING:
            points.append((at, last_used))
    return list(reversed(points))


def _observation_time(row: object) -> datetime | None:
    return _instant(row.get('at')) if isinstance(row, dict) else None


def _recorded_window(row: object, identifier: str) -> object:
    windows = row.get('windows') if isinstance(row, dict) else None
    return windows.get(identifier) if isinstance(windows, dict) else None


def _instant(value: object) -> datetime | None:
    try:
        return parse_instant(value) if isinstance(value, str) else None
    except OverflowError:
        return None


def _usage_value(value: object) -> bool:
    return type(value) in (int, float) and 0 <= value <= 100
