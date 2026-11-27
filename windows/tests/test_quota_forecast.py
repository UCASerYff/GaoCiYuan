import json
from datetime import datetime, timedelta, timezone

import pytest

from gaociyuan.catalog import FILE
from gaociyuan.quota_forecast import quota_forecast, record_quota_observation
from gaociyuan.store import TokenStore
from gaociyuan.timeutil import format_iso


NOW = datetime(2026, 11, 2, 7, tzinfo=timezone.utc)
RESET = NOW + timedelta(minutes=75)
TIMES = (-82, -62, -42, -22, -2)


def reading(minutes, used, *, reset=RESET, duration=18_000, source='fixture', zone=timezone.utc):
    return {
        'observedAt': (NOW + timedelta(minutes=minutes)).astimezone(zone).isoformat(),
        'source': source,
        'quotas': [{'id': 'short', 'title': '5 小时', 'usedPercent': used, 'windowSeconds': duration,
                    'resetsAt': reset.astimezone(zone).isoformat() if reset else None}],
    }


def account_with(*readings):
    account = {'id': 'forecast-fixture', 'provider': 'openai', 'kind': 'Agent', 'snapshot': readings[-1]}
    for item in readings:
        record_quota_observation(account, item, 'fixture-key', NOW)
    return account


def short_window(account, now=NOW):
    return quota_forecast(account, now)['windows'][0]


def test_risk_uses_recent_measured_rate_and_normalizes_time_zones():
    zones = [timezone(timedelta(hours=offset)) for offset in (-5, 8, 0, -4, 9)]
    account = account_with(*(reading(t, v, zone=z) for t, v, z in zip(TIMES, (50, 60, 70, 80, 90), zones)))
    row = short_window(account, NOW.astimezone(zones[0]))
    assert row['status'] == 'risk' and row['confidence'] == 'higher'
    assert row['remainingPercent'] == 10 and row['ratePercentPerHour'] == 30
    assert row['estimatedExhaustedAt'] == format_iso(NOW + timedelta(minutes=18))
    assert row['resetsAt'] == format_iso(RESET)
    assert row['sampleCount'] == 5 and row['observedSpanSeconds'] == 80 * 60


def test_stable_window_has_no_post_reset_eta():
    account = account_with(*(reading(t, v) for t, v in zip(TIMES, (60, 61, 62, 63, 64))))
    row = short_window(account)
    assert row['status'] == 'stable' and row['estimatedExhaustedAt'] is None
    assert row['remainingPercent'] == 36 and row['ratePercentPerHour'] == 3


def test_elapsed_prediction_requests_confirmation_without_marking_measured_exhaustion():
    account = account_with(reading(-72, 67), reading(-42, 82), reading(-12, 97))
    row = short_window(account)
    assert row['status'] == 'risk' and row['reason'] == 'estimatedPassed'
    assert row['estimatedExhaustedAt'] == format_iso(NOW - timedelta(minutes=6))
    assert row['remainingPercent'] == 3


@pytest.mark.parametrize(('readings', 'reason'), [
    ([reading(-6, 40), reading(-4, 50), reading(-2, 60)], 'insufficientHistory'),
    ([reading(-245, 40), reading(-125, 50), reading(-2, 60)], 'insufficientHistory'),
    ([reading(-62, 60), reading(-42, 60), reading(-22, 60.1), reading(-2, 60.2)], 'lowChange'),
    ([reading(-62, 20), reading(-42, 21), reading(-22, 22), reading(-2, 70)], 'unstable'),
    ([reading(-62, 20, duration=None, reset=NOW + timedelta(days=3)),
      reading(-32, 21, duration=None, reset=NOW + timedelta(days=3)),
      reading(-2, 22, duration=None, reset=NOW + timedelta(days=3))], 'beyondEvidence'),
])
def test_insufficient_evidence_preserves_measured_value(readings, reason):
    row = short_window(account_with(*readings))
    assert row['status'] == 'insufficient' and row['reason'] == reason
    assert row['remainingPercent'] == pytest.approx(100 - readings[-1]['quotas'][0]['usedPercent'])
    assert row['estimatedExhaustedAt'] is None and row['confidence'] is None


@pytest.mark.parametrize(('minutes', 'reset', 'used', 'status', 'reason'), [
    (-16, RESET, 85, 'insufficient', 'stale'),
    (+1, RESET, 85, 'insufficient', 'stale'),
    (-2, NOW - timedelta(minutes=1), 90, 'insufficient', 'expired'),
    (-2, None, 90, 'insufficient', 'unknownReset'),
    (-2, None, 100, 'exhausted', None),
])
def test_current_observation_controls_status_without_fabricating_a_forecast(minutes, reset, used, status, reason):
    row = short_window(account_with(reading(minutes, used, reset=reset)))
    assert (row['status'], row['reason'], row['remainingPercent']) == (status, reason, 100 - used)
    assert row['estimatedExhaustedAt'] is None


@pytest.mark.parametrize('latest', [
    reading(-2, 10),
    reading(-2, 90, reset=RESET + timedelta(minutes=5)),
    reading(-2, 90, duration=36_000),
])
def test_top_up_reset_and_duration_change_start_a_new_segment(latest):
    account = account_with(reading(-62, 60), reading(-42, 70), reading(-22, 80), latest)
    assert short_window(account)['sampleCount'] == 1
    assert short_window(account)['reason'] == 'insufficientHistory'


def test_duplicate_out_of_order_and_conflicting_times_never_add_independent_evidence():
    account = account_with(reading(-62, 60), reading(-32, 70), reading(-2, 80))
    latest = account['snapshot']
    for repeat in (latest, latest, reading(-20, 77)):
        record_quota_observation(account, repeat, 'fixture-key', NOW)
    assert short_window(account)['sampleCount'] == 3
    conflict = reading(-2, 85)
    record_quota_observation(account, conflict, 'fixture-key', NOW)
    account['snapshot'] = conflict
    assert short_window(account)['sampleCount'] == 1


def test_stale_connector_error_suppresses_prediction_but_keeps_measured_values():
    account = account_with(reading(-62, 60), reading(-32, 75), reading(-2, 90))
    account['error'] = 'fixture refresh failed'
    row = short_window(account)
    assert row['reason'] == 'syncIssue' and row['remainingPercent'] == 10


def test_money_and_credit_records_remain_outside_percentage_forecast():
    account = {'snapshot': {'observedAt': format_iso(NOW), 'quotas': [],
                            'balances': [{'currency': 'USD', 'value': 2}, {'currency': 'CNY', 'value': 100}],
                            'creditBalances': [{'id': 'test', 'unit': 'points', 'value': 500}]}}
    assert quota_forecast(account, NOW) == {'status': 'excluded', 'reason': 'nonQuota', 'windows': []}


def test_file_refresh_tracks_distinct_values_without_rewriting_existing_history(tmp_path):
    store = TokenStore(tmp_path, now=lambda: NOW)
    fixture = tmp_path / 'quota.json'
    account_id = store.save_account({'provider': 'openai', 'connection': FILE,
                                     'filePath': str(fixture), 'name': '合成额度'})['id']
    for moment, used in zip(TIMES, (60, 60, 65, 75, 90)):
        fixture.write_text(json.dumps(reading(moment, used)), encoding='utf-8')
        store.refresh(account_id, user_initiated=True)
    account = TokenStore(tmp_path, now=lambda: NOW).snapshot_state()['accounts'][0]
    assert len(account['history']) == 4  # unchanged usage does not add to the existing change history
    assert 'quotaForecastHistory' not in account
    assert account['quotaForecast']['windows'][0]['sampleCount'] == 5
    assert account['quotaForecast']['windows'][0]['source'] == '快照文件'

    for moment, used in ((-1, 91), (0, 92)):
        fixture.write_text(json.dumps(reading(moment, used, source='alternate fixture')), encoding='utf-8')
        store.refresh(account_id, user_initiated=True)
    view = store.snapshot_state()['accounts'][0]
    assert view['quotaForecast']['windows'][0]['sampleCount'] == 1
    assert view['quotaForecast']['windows'][0]['reason'] == 'insufficientHistory'


def test_legacy_history_is_never_treated_as_source_verified():
    readings = [reading(t, v) for t, v in zip(TIMES, (60, 70, 80, 90, 95))]
    account = {'history': readings, 'snapshot': readings[-1]}
    assert short_window(account)['reason'] == 'insufficientHistory'
    assert account['history'] is readings
