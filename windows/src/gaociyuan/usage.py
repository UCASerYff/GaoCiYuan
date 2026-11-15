"""用量分析只汇总已经读到的快照。没有 Token 或费用的窗口不会被写成 0。"""

from __future__ import annotations

import csv
import io
import sqlite3
from datetime import datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

from gaociyuan.timeutil import parse_instant


def range_start(key: str, now: datetime, zone: ZoneInfo) -> datetime | None:
    local = now.astimezone(zone)
    if key == "all":
        return None
    if key == "today":
        start = local.replace(hour=0, minute=0, second=0, microsecond=0)
        return start.astimezone(now.tzinfo)
    if key == "7d":
        return now - timedelta(days=7)
    if key == "30d":
        return now - timedelta(days=30)
    if key == "month":
        start = local.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
        return start.astimezone(now.tzinfo)
    raise ValueError(key)


def in_range(observed: str, key: str, now: datetime, zone: ZoneInfo) -> bool:
    moment = parse_instant(observed)
    if moment is None or moment > now:
        return False
    start = range_start(key, now, zone)
    return start is None or moment >= start


class UsageLedger:
    def __init__(self, path: Path):
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._ensure()

    def _connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self.path)
        connection.row_factory = sqlite3.Row
        return connection

    def _ensure(self) -> None:
        with self._connect() as connection:
            connection.execute(
                """
                CREATE TABLE IF NOT EXISTS observations (
                    account_id TEXT NOT NULL,
                    provider TEXT NOT NULL,
                    observed_at TEXT NOT NULL,
                    source TEXT NOT NULL,
                    input_tokens INTEGER,
                    output_tokens INTEGER,
                    cost_currency TEXT NOT NULL,
                    cost_value REAL,
                    PRIMARY KEY (account_id, observed_at, source, cost_currency)
                )
                """
            )

    def record(self, account: dict, snapshot: dict) -> None:
        incoming = snapshot.get("inputTokens")
        outgoing = snapshot.get("outputTokens")
        costs = snapshot.get("costs") or []
        has_tokens = incoming is not None and outgoing is not None
        if not has_tokens and not costs:
            return
        with self._connect() as connection:
            if costs:
                for cost in costs:
                    connection.execute(
                        """
                        INSERT OR REPLACE INTO observations
                        (account_id, provider, observed_at, source, input_tokens, output_tokens, cost_currency, cost_value)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        (
                            account["id"],
                            account["provider"],
                            snapshot["observedAt"],
                            snapshot.get("source") or "",
                            incoming,
                            outgoing,
                            cost["currency"],
                            cost["value"],
                        ),
                    )
            else:
                connection.execute(
                    """
                    INSERT OR REPLACE INTO observations
                    (account_id, provider, observed_at, source, input_tokens, output_tokens, cost_currency, cost_value)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        account["id"],
                        account["provider"],
                        snapshot["observedAt"],
                        snapshot.get("source") or "",
                        incoming,
                        outgoing,
                        "",
                        None,
                    ),
                )

    def rows(self, key: str, now: datetime, zone: ZoneInfo, provider: str = "") -> list[dict]:
        with self._connect() as connection:
            query = "SELECT * FROM observations"
            found = connection.execute(query).fetchall()
        result = []
        for row in found:
            if provider and row["provider"] != provider:
                continue
            if not in_range(row["observed_at"], key, now, zone):
                continue
            result.append(
                {
                    "accountId": row["account_id"],
                    "provider": row["provider"],
                    "observedAt": row["observed_at"],
                    "source": row["source"],
                    "inputTokens": row["input_tokens"],
                    "outputTokens": row["output_tokens"],
                    "currency": row["cost_currency"],
                    "cost": row["cost_value"],
                }
            )
        return result


def history_quota_rows(accounts: list[dict], key: str, now: datetime, zone: ZoneInfo, provider: str = "", query: str = "") -> list[dict]:
    rows = []
    needle = query.casefold()
    for account in accounts:
        if provider and account.get("provider") != provider:
            continue
        if needle and needle not in (account.get("name") or "").casefold() and needle not in account.get("provider", "").casefold():
            continue
        for snapshot in account.get("history") or []:
            if not in_range(snapshot.get("observedAt") or "", key, now, zone):
                continue
            for quota in snapshot.get("quotas") or []:
                rows.append(
                    {
                        "account": account.get("name"),
                        "provider": account.get("provider"),
                        "observedAt": snapshot.get("observedAt"),
                        "source": snapshot.get("source"),
                        "quota": quota.get("title"),
                        "usedPercent": quota.get("usedPercent"),
                        "resetsAt": quota.get("resetsAt"),
                    }
                )
    return rows


def csv_bytes(headers: list[str], rows: list[dict]) -> bytes:
    buffer = io.StringIO()
    writer = csv.DictWriter(buffer, fieldnames=headers, lineterminator="\r\n", extrasaction="ignore")
    writer.writeheader()
    for row in rows:
        writer.writerow({key: "" if row.get(key) is None else row.get(key) for key in headers})
    return ("\ufeff" + buffer.getvalue()).encode("utf-8")
