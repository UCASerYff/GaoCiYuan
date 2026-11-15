from datetime import datetime, timezone

from gaociyuan.usage import csv_bytes, history_quota_rows, in_range


def test_csv_is_bom_crlf_and_range_filter():
    now = datetime(2026, 11, 15, 2, tzinfo=timezone.utc)
    from zoneinfo import ZoneInfo

    zone = ZoneInfo("Asia/Shanghai")
    accounts = [
        {
            "name": "Claude",
            "provider": "claude",
            "history": [
                {
                    "observedAt": "2026-11-15T01:00:00Z",
                    "source": "快照文件",
                    "quotas": [{"title": "5小时", "usedPercent": 12, "resetsAt": None}],
                }
            ],
        }
    ]
    rows = history_quota_rows(accounts, "today", now, zone)
    assert rows[0]["usedPercent"] == 12
    body = csv_bytes(["account", "usedPercent"], rows)
    assert body.startswith("\ufeff".encode())
    assert b"\r\n" in body
    assert in_range("2026-11-01T00:00:00Z", "today", now, zone) is False
