"""Persistent notification rules shared by desktop refreshes and the tray."""

from gaociyuan.snapshots import chart_quotas
from gaociyuan.timeutil import parse_instant


def failure_alert(record: dict, enabled: bool, count: int, error: str) -> list[str]:
    if enabled and count >= 3 and not record.get('reportedFailure'):
        record['reportedFailure'] = True
        return [error]
    return []


def reading_alerts(record: dict, settings: dict, account: dict, snapshot: dict, now) -> list[str]:
    alerts = []
    record['reportedFailure'] = False
    balance_limit = settings['notifyLowBalance']
    currency = account.get('currency', 'USD')
    balance = next((row for row in snapshot.get('balances', []) if row.get('currency') == currency), None)
    if not balance_limit or (balance is not None and balance['value'] >= balance_limit):
        record.pop('balanceLimit', None)
    elif balance is not None and record.get('balanceLimit') != balance_limit:
        record['balanceLimit'] = balance_limit
        display_balance = balance.get('text') or f'{balance["value"]} {currency}'
        alerts.append(f'余额仅剩 {display_balance}')

    threshold = settings['notifyThreshold']
    windows = record.setdefault('windows', {})
    for quota in chart_quotas(snapshot, now):
        window_id = str(quota.get('id') or quota.get('title') or 'quota')
        title = quota.get('title') or '额度'
        percent = float(quota['usedPercent'])
        reset_text = quota.get('resetsAt')
        reset = parse_instant(reset_text) if reset_text else None
        last = windows.get(window_id, {})
        old_text = last.get('reset')
        old_reset = parse_instant(old_text) if old_text else None
        announced = last.get('announced', 0)
        if reset and ((old_reset and (reset - old_reset).total_seconds() > 60) or last.get('percent', 0) - percent >= 40):
            if settings['notifyOnReset'] and announced:
                alerts.append(f'{title} 已重置')
            announced = 0
        if settings['notifyExhausted'] and quota.get('exhausted') is True and announced < 100:
            alerts.append(f'{title} 已用尽')
            announced = 100
        elif threshold and min(99, percent) >= threshold > announced:
            alerts.append(f'{title} 已用 {threshold}%')
            announced = threshold
        windows[window_id] = {'percent': percent, 'reset': reset_text, 'announced': announced}
    return alerts
