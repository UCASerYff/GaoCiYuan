"""Read accounting fields from consented, local Agent session logs."""

from __future__ import annotations

import hashlib
import json
import math
import ntpath
import os
import re
import sqlite3
import stat
import time
from collections.abc import Iterator
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

from gaociyuan.errors import AppError
from gaociyuan.timeutil import parse_instant

MAX_COUNT = 1_000_000_000_000
MAX_RECORDS = 200_000
SCANNER_REVISION = 2
TOKEN_FIELDS = ("input", "output", "cacheRead", "cacheWrite", "reasoning")
PRICE_FIELDS = ("inputPerMillion", "outputPerMillion", "cacheReadPerMillion", "cacheWritePerMillion", "cacheWrite1hPerMillion")
AMOUNT_FIELDS = (*TOKEN_FIELDS, "messageCount", "costUSD")


@dataclass(frozen=True)
class UsageSource:
    id: str
    name: str
    locations: tuple[tuple[str, str, str], ...] = ()

    @property
    def supported(self) -> bool:
        return bool(self.locations)


# Each configured environment variable replaces only its own home-relative locations.
SOURCES = (
    UsageSource("cursor", "Cursor（官方账户用量）"),
    UsageSource("claude", "Claude Code", (("CLAUDE_CONFIG_DIR", ".claude", "projects"), ("CLAUDE_CONFIG_DIR", ".claude", "transcripts"))),
    UsageSource("codex", "Codex", (("CODEX_HOME", ".codex", "sessions"), ("CODEX_HOME", ".codex", "archived_sessions"))),
    UsageSource("opencode", "OpenCode", (("XDG_DATA_HOME", ".local/share", "opencode"), ("OPENCODE_DB", "", ""))),
    UsageSource("hermes", "Hermes Agent", (("HERMES_HOME", ".hermes", "state.db"), ("HERMES_HOME", ".hermes", "profiles"))),
    UsageSource("openclaw", "OpenClaw", (("OPENCLAW_STATE_DIR", ".openclaw", "agents"), ("", ".clawdbot", "agents"), ("", ".moltbot", "agents"), ("", ".moldbot", "agents"))),
    UsageSource("antigravity", "Antigravity"),
    UsageSource("cline", "Cline", (("CLINE_SESSION_DATA_DIR", ".cline/data", ""),
                                  ("CLINE_DATA_DIR", "", "sessions"), ("CLINE_DIR", "", "data/sessions"),
                                  ("APPDATA", "", "Code/User/globalStorage/saoudrizwan.claude-dev/tasks"))),
    UsageSource("amp", "Amp"),
    UsageSource("droid", "Factory Droid", (("", ".factory", "sessions"),)),
    UsageSource("kimi", "Kimi", (("", ".kimi", "sessions"), ("KIMI_CODE_HOME", ".kimi-code", "sessions"))),
    UsageSource("qwen", "Qwen CLI", (("QWEN_HOME", ".qwen", "projects"),)),
    UsageSource("grok", "Grok Build", (("GROK_HOME", ".grok", "sessions"),)),
    UsageSource("copilot", "GitHub Copilot（OpenTelemetry 文件）", (("COPILOT_OTEL_FILE_EXPORTER_PATH", "", ""),)),
    UsageSource("pi", "Pi", (("PI_AGENT_DIR", ".pi/agent", "sessions"),)),
    UsageSource("omp", "Oh My Pi", (("", ".omp/agent", "sessions"),)),
    UsageSource("zed", "Zed"),
    UsageSource("kilo", "Kilo", (("APPDATA", "", "Code/User/globalStorage/kilocode.kilo-code/tasks"),)),
    UsageSource("commandcode", "Command Code（文本估算）"),
    UsageSource("mimo", "Xiaomi MiMo"),
    UsageSource("muse", "Muse Code"),
    UsageSource("zcode", "ZCode"),
    UsageSource("kiro", "Kiro（部分估算）"),
    UsageSource("codebuddy", "CodeBuddy"),
    UsageSource("workbuddy", "WorkBuddy"),
    UsageSource("proma", "Proma"),
    UsageSource("qodercn", "Qoder CN"),
    UsageSource("reasonix", "Reasonix"),
    UsageSource("dsh", "DeepSeek Harness"),
    UsageSource("cherrystudio", "Cherry Studio"),
    UsageSource("lmstudio", "LM Studio"),
    UsageSource("unsloth", "Unsloth Studio"),
    UsageSource("devin", "Devin"),
    UsageSource("fx", "fx"),
    UsageSource("mcode", "MiniMax Code"),
    UsageSource("gemini", "Gemini CLI", (("GEMINI_CLI_HOME", ".gemini", "tmp"),)),
)
SUPPORTED = {source.id: source for source in SOURCES if source.supported}
DEFAULT_IDS = tuple(key for key in SUPPORTED if key != "copilot")


def identifier(value: object, *, limit: int = 300) -> str:
    if isinstance(value, str) and 0 < len(value) <= limit and not any(ord(char) < 32 for char in value):
        return value.strip()
    return ""


def digest(*values: object) -> str:
    raw = json.dumps(values, ensure_ascii=True, separators=(",", ":"))
    return hashlib.sha256(raw.encode("ascii")).hexdigest()


def obj(value: object) -> dict:
    return value if isinstance(value, dict) else {}


def count(value: object) -> int:
    return value if type(value) is int and 0 <= value <= MAX_COUNT else 0


def price(value: object) -> float | None:
    if type(value) in (float, int) and 0 <= value <= 1_000_000_000 and math.isfinite(value):
        return float(value)
    return None


def moment(value: object) -> datetime | None:
    try:
        if isinstance(value, str):
            return parse_instant(value)
        if type(value) in (float, int) and 0 < value < 4_200_000_000_000:
            return datetime.fromtimestamp(value / 1000 if value > 100_000_000_000 else value, timezone.utc)
    except (OverflowError, OSError, ValueError):
        pass
    return None


def project(value: object) -> tuple[str | None, str | None]:
    path = identifier(value, limit=4096)
    if not path or not ntpath.isabs(path):
        return None, None
    label = ntpath.basename(path.rstrip("/\\"))
    return digest(ntpath.normcase(ntpath.normpath(path))), label[:160] or None


@dataclass(frozen=True)
class UsageEvent:
    id: str
    client: str
    session: str
    model: str
    at: datetime
    tokens: tuple[int, int, int, int, int]
    cwd: tuple[str | None, str | None] = (None, None)
    cost: float | None = None
    duration: int = 0
    cache_write_1h: int = 0
    messages: int = 1

    @property
    def total(self) -> int:
        return sum(self.tokens)


def event(client: str, session: str, model: object, at: object, token_values: tuple[int, int, int, int, int], identity: object,
          cwd: tuple[str | None, str | None] = (None, None), *, cost: object = None, duration: int = 0,
          cache_write_1h: int = 0, messages: int = 1) -> UsageEvent | None:
    captured = moment(at)
    recorded_cost = price(cost)
    if captured is None or (not any(token_values) and recorded_cost is None):
        return None
    session = session if re.fullmatch(r"[A-Za-z0-9._:-]{1,160}", session) else digest(client, "session", session)
    return UsageEvent(digest(client, identity), client, session, identifier(model) or "unknown", captured, token_values,
                      cwd, recorded_cost, duration, cache_write_1h, messages)


def _codex_amounts(usage: object, separate_reasoning: bool = False) -> tuple[int, int, int, int] | None:
    usage = obj(usage)
    if not usage:
        return None
    incoming = count(usage.get("input_tokens"))
    outgoing = count(usage.get("output_tokens"))
    cached = min(incoming, count(usage.get("cached_input_tokens")))
    reasoning = count(usage.get("reasoning_output_tokens"))
    return incoming - cached, outgoing if separate_reasoning else outgoing - min(outgoing, reasoning), cached, reasoning if separate_reasoning else min(outgoing, reasoning)


def codex(lines: Iterator[tuple[int, dict]], path: Path) -> Iterator[UsageEvent | None]:
    session = path.stem
    model = ""
    cwd = (None, None)
    previous = None
    for index, row in lines:
        payload = obj(row.get("payload"))
        if row.get("type") == "session_meta":
            session = identifier(payload.get("id")) or session
            cwd = project(payload.get("cwd"))
            model = identifier(payload.get("model")) or model
        elif row.get("type") == "turn_context":
            model = identifier(payload.get("model")) or model
            if payload.get("cwd"):
                cwd = project(payload["cwd"])
        elif row.get("type") == "event_msg" and payload.get("type") == "token_count":
            info = obj(payload.get("info"))
            cumulative = _codex_amounts(info.get("total_token_usage"))
            last = _codex_amounts(info.get("last_token_usage"), info.get("last_usage_includes_reasoning") is False)
            if cumulative is not None and cumulative == previous:
                continue
            if cumulative is not None and previous is not None and all(new >= old for new, old in zip(cumulative, previous)):
                delta = tuple(new - old for new, old in zip(cumulative, previous))
            else:
                delta = last or (cumulative if previous is None else None)
            if cumulative is not None:
                previous = cumulative
            if delta is not None:
                incoming, outgoing, cached, reasoning = delta
                yield event("codex", session, model, row.get("timestamp"), (incoming, outgoing, cached, 0, reasoning),
                            (session, row.get("timestamp"), cumulative if cumulative is not None else index), cwd)


def claude(lines: Iterator[tuple[int, dict]], path: Path) -> Iterator[UsageEvent | None]:
    for index, row in lines:
        if row.get("type") != "assistant":
            continue
        message = obj(row.get("message"))
        usage = obj(message.get("usage"))
        session = identifier(row.get("sessionId")) or path.stem
        request = identifier(message.get("id")) or identifier(row.get("uuid")) or (session, index)
        cache_write_1h = count(obj(usage.get("cache_creation")).get("ephemeral_1h_input_tokens"))
        values = tuple(count(usage.get(key)) for key in ("input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"))
        yield event("claude", session, message.get("model"), row.get("timestamp"), (*values, 0), request,
                    project(row.get("cwd")), cache_write_1h=min(values[3], cache_write_1h))


def kimi(lines: Iterator[tuple[int, dict]], path: Path) -> Iterator[UsageEvent | None]:
    # Kimi CLI's path ends in a session ID. Kimi Code adds an agents/<id> pair.
    agent = path.parent.name if path.parent.parent.name == "agents" else "main"
    session = path.parent.parent.parent.name if path.parent.parent.name == "agents" else path.parent.name
    for index, row in lines:
        message = obj(row.get("message"))
        if row.get("type") == "usage.record" and row.get("usageScope") in (None, "turn"):
            data = obj(row.get("usage"))
            values = tuple(count(data.get(key)) for key in ("inputOther", "output", "inputCacheRead", "inputCacheCreation"))
            yield event("kimi", session, row.get("model") or "kimi-for-coding", row.get("time"), (*values, 0),
                        (session, agent, identifier(row.get("id")) or index))
        elif message.get("type") == "StatusUpdate":
            payload = obj(message.get("payload"))
            data = obj(payload.get("token_usage"))
            values = tuple(count(data.get(key)) for key in ("input_other", "output", "input_cache_read", "input_cache_creation"))
            yield event("kimi", session, payload.get("model") or "kimi-for-coding", row.get("timestamp"), (*values, 0),
                        (session, agent, identifier(payload.get("message_id")) or index))


def _assistant(lines: Iterator[tuple[int, dict]], path: Path, client: str) -> Iterator[UsageEvent | None]:
    session = path.stem
    cwd = (None, None)
    started = False
    for index, row in lines:
        if row.get("type") == "session" and identifier(row.get("id")):
            session = row["id"]
            cwd = project(row.get("cwd"))
            started = True
        if not started or row.get("type") != "message":
            continue
        message = obj(row.get("message"))
        usage = obj(message.get("usage"))
        if message.get("role") != "assistant" or not usage:
            continue
        values = tuple(count(usage.get(key)) for key in ("input", "output", "cacheRead", "cacheWrite"))
        identity = identifier(row.get("id")) or index
        # Entry IDs can be short. Include the timestamp to distinguish unrelated sessions.
        at = row.get("timestamp") or message.get("timestamp")
        yield event(client, session, message.get("model"), at, (*values, 0), (identity, at), cwd,
                    cost=price(obj(usage.get("cost")).get("total")) or None)


def cline(data: object, path: Path, client: str) -> Iterator[UsageEvent | None]:
    if isinstance(data, dict):
        data = data.get("messages")
    if not isinstance(data, list):
        return
    if path.name.casefold() == "ui_messages.json":
        yield from _cline_desktop(data, path, client)
    elif client == "cline":
        yield from _cline_cli(data, path)


def _cline_desktop(data: list, path: Path, client: str) -> Iterator[UsageEvent | None]:
    session = path.parent.name
    for index, item in enumerate(data):
        row = obj(item)
        if row.get("type") != "say" or row.get("say") != "api_req_started" or not isinstance(row.get("text"), str):
            continue
        try:
            metrics = obj(json.loads(row["text"]))
        except (ValueError, RecursionError):
            continue
        model_info = obj(row.get("modelInfo"))
        protocol = metrics.get("apiProtocol")
        provider = model_info.get("providerId")
        incoming, outgoing, read, write = (count(metrics.get(key)) for key in ("tokensIn", "tokensOut", "cacheReads", "cacheWrites"))
        if protocol == "openai":
            read = min(incoming, read)
            write = min(incoming - read, write)
            incoming -= read + write
        elif protocol != "anthropic" and provider != "anthropic":
            # Files from older plugins lack a protocol. Count input/output,
            # but skip cache fields with an unverified overlap convention.
            read = write = 0
        quote = price(metrics.get("cost")) or None
        yield event(client, session, model_info.get("modelId") or metrics.get("modelId"), row.get("ts"),
                    (incoming, outgoing, read, write, 0), (session, row.get("ts"), index), cost=quote)


def _cline_cli(data: list, path: Path) -> Iterator[UsageEvent | None]:
    session = path.name.removesuffix(".messages.json")
    for index, item in enumerate(data):
        row = obj(item)
        if row.get("role") != "assistant":
            continue
        metrics = obj(row.get("metrics"))
        if not metrics:
            continue
        incoming = count(metrics.get("inputTokens"))
        outgoing = count(metrics.get("outputTokens"))
        cache_read = min(incoming, count(metrics.get("cacheReadTokens")))
        cache_write = min(incoming - cache_read, count(metrics.get("cacheWriteTokens")))
        at = row.get("timestamp") or row.get("ts")
        model = obj(row.get("modelInfo")).get("id") or row.get("modelId") or row.get("model")
        yield event("cline", session, model, at,
                    (incoming - cache_read - cache_write, outgoing, cache_read, cache_write, 0),
                    (session, identifier(row.get("id")) or index), cost=price(metrics.get("cost")) or None)


def opencode_json(data: dict, path: Path) -> Iterator[UsageEvent | None]:
    if isinstance(data.get("messages"), list):
        session = obj(data.get("info"))
        messages = (obj(obj(record).get("info")) for record in data["messages"])
        fallback_session = identifier(session.get("id")) or path.stem
        project_path = project(session.get("directory"))
    else:
        messages = (data,)
        fallback_session = path.parent.name
        project_path = (None, None)
    for row in messages:
        if row.get("role") != "assistant":
            continue
        token = obj(row.get("tokens"))
        cached = obj(token.get("cache"))
        session = identifier(row.get("sessionID")) or fallback_session
        identity = identifier(row.get("id")) or path.stem
        values = (count(token.get("input")), count(token.get("output")), count(cached.get("read")),
                  count(cached.get("write")), count(token.get("reasoning")))
        cwd = project(obj(row.get("path")).get("cwd")) if obj(row.get("path")).get("cwd") else project_path
        yield event("opencode", session, row.get("modelID"), obj(row.get("time")).get("created"), values, identity,
                    cwd, cost=price(row.get("cost")) or None)


def _properties(conn, table: str) -> set[str]:
    record = conn.execute("SELECT type, sql FROM sqlite_schema WHERE name = ?", (table,)).fetchone()
    if not record or record[0] != "table" or not record[1] or record[1].upper().startswith("CREATE VIRTUAL TABLE"):
        return set()
    return {row[1] for row in conn.execute(f"PRAGMA table_info({table})")}


def hermes_sqlite(conn) -> Iterator[UsageEvent | None]:
    properties = _properties(conn, "sessions")
    required = ("id", "model", "started_at", "input_tokens", "output_tokens")
    optional = ("cache_read_tokens", "cache_write_tokens", "reasoning_tokens", "actual_cost_usd", "estimated_cost_usd", "message_count", "cwd")
    if not set(required).issubset(properties):
        raise sqlite3.DatabaseError("unrecognized Hermes sessions schema")
    columns = ", ".join(field if field in properties else "NULL" for field in (*required, *optional))
    for session, model, at, incoming, outgoing, read, write, reasoning, actual, estimated, messages, cwd in conn.execute(f"SELECT {columns} FROM sessions"):
        if not (identifier(session) and identifier(model)):
            continue
        incoming, outgoing, read, write, reasoning = map(count, (incoming, outgoing, read, write, reasoning))
        reasoning = min(outgoing, reasoning)
        values = (incoming, outgoing - reasoning, read, write, reasoning)
        quote = price(actual)
        if quote is None:
            quote = price(estimated) or None
        yield event("hermes", session, model, at, values, session, project(cwd), cost=quote, messages=count(messages))


def opencode_sqlite(conn) -> Iterator[UsageEvent | None]:
    message_required = {"id", "session_id", "time_created", "data"}
    layouts = []
    if message_required.issubset(_properties(conn, "message")):
        layouts.append(("message", "json_extract(data, '$.role') = 'assistant'", "$.modelID"))
    if (message_required | {"type"}).issubset(_properties(conn, "session_message")):
        layouts.append(("session_message", "type = 'assistant' OR (type = 'compaction' AND json_extract(data, '$.status') IN ('completed', 'failed'))", "$.model.id"))
    if not layouts:
        raise sqlite3.DatabaseError("unrecognized OpenCode sessions schema")
    token_fields = ("input", "output", "cache.read", "cache.write", "reasoning")
    cost_fields = ", ".join(f"json_extract(data, '$.tokens.{field}')" for field in token_fields)
    for table, accept, model_path in layouts:
        sql = f"""
            SELECT id, session_id, COALESCE(json_extract(data, '$.time.created'), time_created),
                   json_extract(data, '{model_path}'), json_extract(data, '$.path.cwd'),
                   json_extract(data, '$.cost'), {cost_fields} FROM {table}
            WHERE json_valid(data) AND ({accept}) AND json_type(data, '$.tokens') = 'object'
        """
        for identity, session, at, model, cwd, cost, *values in conn.execute(sql):
            if identifier(identity) and identifier(session):
                yield event("opencode", session, model, at, tuple(map(count, values)), identity, project(cwd), cost=price(cost) or None)


def gemini(data: dict) -> Iterator[UsageEvent | None]:
    session = identifier(data.get("sessionId"))
    messages = data.get("messages")
    if not session or not isinstance(messages, list):
        return
    for index, message in enumerate(messages):
        yield _gemini_event(obj(message), session, index)


def gemini_lines(lines: Iterator[tuple[int, dict]], path: Path) -> Iterator[UsageEvent | None]:
    session = ""
    for index, row in lines:
        session = identifier(row.get("sessionId")) or session
        if session:
            yield _gemini_event(row, session, index)


def _gemini_event(message: dict, session: str, index: int) -> UsageEvent | None:
    if message.get("type") != "gemini":
        return None
    usage = obj(message.get("tokens"))
    incoming = count(usage.get("input"))
    cached = min(incoming, count(usage.get("cached")))
    values = (incoming - cached + count(usage.get("tool")), count(usage.get("output")), cached, 0, count(usage.get("thoughts")))
    return event("gemini", session, message.get("model"), message.get("timestamp"), values,
                 (session, identifier(message.get("id")) or index))


def qwen(lines: Iterator[tuple[int, dict]], path: Path) -> Iterator[UsageEvent | None]:
    for index, row in lines:
        if row.get("type") != "assistant":
            continue
        session = identifier(row.get("sessionId")) or path.stem
        metadata = obj(row.get("usageMetadata"))
        if metadata:
            input_tokens = count(metadata.get("promptTokenCount")) + count(metadata.get("toolUsePromptTokenCount"))
            cache = min(input_tokens, count(metadata.get("cachedContentTokenCount")))
            output, reasoning = (count(metadata.get(field)) for field in ("candidatesTokenCount", "thoughtsTokenCount"))
        else:
            usage = obj(row.get("tokens"))
            input_tokens, output, reasoning = (count(usage.get(field)) for field in ("input", "output", "thoughts"))
            cache = min(input_tokens, count(usage.get("cached")))
        yield event("qwen", session, row.get("model"), row.get("timestamp"), (input_tokens - cache, output, cache, 0, reasoning),
                    (session, identifier(row.get("uuid")) or index), project(row.get("cwd")))


def grok(lines: Iterator[tuple[int, dict]], path: Path) -> Iterator[UsageEvent | None]:
    # Grok Build session accounting is independent of Grok Bot quota reports.
    # Only final usage with a breakdown is counted; context length is ambiguous.
    for index, row in lines:
        params = obj(row.get("params"))
        update = obj(params.get("update"))
        if row.get("method") != "session/update" or update.get("sessionUpdate") != "turn_completed":
            continue
        metadata = obj(params.get("_meta"))
        usage = obj(update.get("usage"))
        models = obj(usage.get("modelUsage"))
        model = next(iter(models)) if len(models) == 1 else metadata.get("modelId")
        nested = obj(models.get(model)) if isinstance(model, str) else {}
        incoming = count(usage.get("inputTokens") or usage.get("input_tokens"))
        outgoing = count(usage.get("outputTokens") or usage.get("output_tokens"))
        cache_read = min(incoming, count(usage.get("cachedReadTokens") or usage.get("cached_read_tokens")))
        cache_write = min(incoming - cache_read, count(usage.get("cachedWriteTokens") or usage.get("cached_write_tokens")))
        reasoning = min(outgoing, count(usage.get("reasoningTokens") or usage.get("reasoning_tokens")))
        if not incoming and not outgoing:
            continue
        ticks = usage.get("costUsdTicks", nested.get("costUsdTicks"))
        known_cost = not (usage.get("costIsPartial") or usage.get("usageIsIncomplete") or nested.get("costIsPartial"))
        cost = ticks / 10_000_000_000 if known_cost and type(ticks) is int and 0 < ticks <= 10**19 else None
        session = identifier(params.get("sessionId")) or path.parent.name
        turn = identifier(update.get("prompt_id") or update.get("promptId")) or identifier(metadata.get("eventId")) or index
        messages = count(usage.get("modelCalls") or nested.get("modelCalls")) or 1
        yield event("grok", session, model, metadata.get("agentTimestampMs") or row.get("timestamp"),
                    (incoming - cache_read - cache_write, outgoing - reasoning, cache_read, cache_write, reasoning),
                    (session, turn), cost=cost, messages=messages)


def droid(data: dict, path: Path, modified: float) -> UsageEvent | None:
    usage = obj(data.get("tokenUsage"))
    session = path.name.removesuffix(".settings.json")
    model = identifier(data.get("model"))
    values = tuple(count(usage.get(key)) for key in ("inputTokens", "outputTokens", "cacheReadTokens", "cacheCreationTokens", "thinkingTokens"))
    return event("droid", session, model, data.get("providerLockTimestamp") or modified, values, session,
                 project(data.get("cwd")), messages=count(usage.get("messageCount")))


def copilot(lines: Iterator[tuple[int, dict]], path: Path) -> Iterator[UsageEvent | None]:
    # The documented OTLP file exporter can emit full requests, and some versions
    # emit a single SDK-readable span per line. Ignore metrics (cumulative values).
    for _, row in lines:
        spans = [row]
        if isinstance(row.get("resourceSpans"), list):
            scopes = [scope for resource in row["resourceSpans"] if isinstance(resource, dict) and isinstance(resource.get("scopeSpans"), list)
                      for scope in resource["scopeSpans"] if isinstance(scope, dict)]
            spans = [span for scope in scopes if isinstance(scope.get("spans"), list) for span in scope["spans"]]
        for span in spans:
            span = obj(span)
            encoded = span.get("attributes")
            attributes = obj(encoded)
            if isinstance(encoded, list):
                attributes = {item.get("key"): next(iter(obj(item.get("value")).values()), None)
                              for item in encoded if isinstance(item, dict) and isinstance(item.get("key"), str)}
            if attributes.get("gen_ai.operation.name") != "chat":
                continue
            span_id = identifier(span.get("spanId"))
            trace_id = identifier(span.get("traceId"))
            if not span_id or not trace_id:
                continue
            conversation = identifier(attributes.get("gen_ai.conversation.id")) or identifier(attributes.get("github.copilot.session.id")) or trace_id
            model = attributes.get("gen_ai.response.model") or attributes.get("gen_ai.request.model")
            numbers = []
            for key in ("gen_ai.usage.input_tokens", "gen_ai.usage.output_tokens", "gen_ai.usage.cache_read.input_tokens",
                        "gen_ai.usage.cache_write.input_tokens", "gen_ai.usage.reasoning.output_tokens"):
                value = attributes.get(key)
                if isinstance(value, str) and re.fullmatch(r"[0-9]{1,13}", value):
                    value = int(value)
                numbers.append(count(value))
            incoming, outgoing, cache_read, cache_write, reasoning = numbers
            # Cache writes are part of the prompt's input, except for formats
            # which supply a separately disjoint set. Copilot reports totals.
            cache_read = min(incoming, cache_read)
            cache_write = min(incoming - cache_read, cache_write)
            reasoning = min(outgoing, reasoning)
            try:
                start = int(span.get("startTimeUnixNano"))
                end = int(span.get("endTimeUnixNano"))
            except (TypeError, ValueError, OverflowError):
                continue
            if not 0 < start <= end <= 4_200_000_000_000_000_000:
                continue
            yield event("copilot", conversation, model, end / 1_000_000_000,
                        (incoming - cache_read - cache_write, outgoing - reasoning, cache_read, cache_write, reasoning),
                        (trace_id, span_id), duration=count((end - start) // 1_000_000))


def local_path(raw: str) -> Path | None:
    if not raw or len(raw) > 4096 or raw.startswith(("\\\\", "//")) or any(ord(char) < 32 for char in raw):
        return None
    path = Path(raw)
    if not path.is_absolute() or ":" in str(path)[len(path.drive):]:
        return None
    if os.name == "nt":
        import ctypes

        # An absolute drive path can still refer to a mapped network share.
        if ctypes.windll.kernel32.GetDriveTypeW(str(path.anchor)) not in (2, 3, 5, 6):
            return None
    return path


def default_paths(source: UsageSource, *, allow_default_paths: bool) -> list[Path]:
    if not allow_default_paths:
        return []
    paths = []
    for variable, relative, child in source.locations:
        configured = os.environ.get(variable) if variable else None
        if configured:
            root = local_path(configured)
        elif relative:
            root = Path.home() / relative
        else:
            root = None
        if root is not None:
            paths.append(root / child if child else root)
    return paths


def _walkable(path: Path) -> os.stat_result | None:
    info = path.lstat()
    if stat.S_ISLNK(info.st_mode) or getattr(info, "st_file_attributes", 0) & stat.FILE_ATTRIBUTE_REPARSE_POINT:
        return None
    return info


def local_item(path: Path) -> os.stat_result | None:
    # Check ancestors before opening the leaf because a Windows junction can
    # redirect even a normal-looking descendant to a different drive/root.
    for parent in reversed(path.parents):
        if _walkable(parent) is None:
            return None
    return _walkable(path)


@dataclass
class ScanBudget:
    deadline: float = field(default_factory=lambda: time.monotonic() + 180)
    remaining_files: int = 50_000
    remaining_bytes: int = 512 * 1024 * 1024
    malformed: int = 0
    incomplete: set[str] = field(default_factory=set)

    def check(self) -> None:
        if time.monotonic() >= self.deadline or self.remaining_files <= 0 or self.remaining_bytes < 0:
            raise AppError("本机用量采集达到处理上限，已有历史保持不变。", "usage-limit")


def _matches(client: str, path: Path, explicit: bool) -> bool:
    name = path.name.casefold()
    if client == "gemini":
        return path.suffix.lower() in (".json", ".jsonl") and (explicit or (name.startswith("session-") and path.parent.name.casefold() == "chats"))
    if client == "codex":
        return name.endswith(".jsonl") and (explicit or name.startswith("rollout-"))
    if client == "kimi":
        return name == "wire.jsonl"
    if client == "hermes":
        return name == "state.db"
    if client in ("cline", "kilo"):
        return name == "ui_messages.json" or (client == "cline" and name.endswith(".messages.json"))
    if client == "grok":
        return name == "updates.jsonl"
    if client == "droid":
        return name.endswith(".settings.json")
    if client == "opencode":
        if path.suffix.casefold() == ".db":
            return explicit or re.fullmatch(r"opencode(?:-[a-z0-9_-]+)?\.db", name) is not None
        return path.suffix.casefold() == ".json" and (explicit or (name.startswith("msg_") and path.parent.parent.name == "message"))
    if client in ("openclaw", "qwen"):
        folder = "sessions" if client == "openclaw" else "chats"
        return name.endswith(".jsonl") and (explicit or path.parent.name.casefold() == folder)
    if client == "copilot":
        return explicit and path.suffix.casefold() in {".jsonl", ".ndjson", ".json"}
    return name.endswith(".jsonl") and name not in {"history.jsonl", "sessions-index.jsonl"}


def _files(client: str, root: Path, budget: ScanBudget) -> Iterator[tuple[Path, os.stat_result]]:
    pending = [(root, True)]
    while pending:
        budget.check()
        path, explicit = pending.pop()
        budget.remaining_files -= 1
        try:
            info = local_item(path) if explicit else _walkable(path)
            if info is None:
                continue
            if stat.S_ISDIR(info.st_mode):
                with os.scandir(path) as entries:
                    for entry in entries:
                        if len(pending) >= budget.remaining_files:
                            raise AppError("采集目录包含过多项目，已有历史保持不变。", "usage-limit")
                        pending.append((Path(entry.path), False))
            elif stat.S_ISREG(info.st_mode) and _matches(client, path, explicit):
                yield path, info
        except FileNotFoundError:
            continue
        except OSError:
            budget.incomplete.add(client)


def _lines(stream, budget: ScanBudget) -> Iterator[tuple[int, dict]]:
    max_line = 4 * 1024 * 1024
    index = 0
    while raw := stream.readline(max_line + 1):
        budget.remaining_bytes -= len(raw)
        budget.check()
        index += 1
        if len(raw) > max_line:
            while not raw.endswith(b"\n") and (raw := stream.readline(max_line + 1)):
                budget.remaining_bytes -= len(raw)
                budget.check()
            budget.malformed += 1
            continue
        try:
            item = json.loads(raw.decode("utf-8-sig"))
        except (UnicodeError, ValueError, RecursionError):
            if raw.strip() and raw.endswith(b"\n"):
                budget.malformed += 1
            continue
        if isinstance(item, dict):
            yield index, item


def _database_sidecars(path: Path) -> tuple[os.stat_result | None, os.stat_result | None]:
    def sidecar(suffix):
        try:
            info = _walkable(path.with_name(path.name + suffix))
        except FileNotFoundError:
            return None
        if info is None or not stat.S_ISREG(info.st_mode):
            raise OSError("invalid SQLite sidecar")
        return info

    return sidecar("-wal"), sidecar("-shm")


def _read_sqlite(client: str, path: Path, info: os.stat_result, budget: ScanBudget) -> Iterator[UsageEvent | None]:
    wal, shared = _database_sidecars(path)
    budget.remaining_bytes -= info.st_size + (wal.st_size if wal else 0)
    budget.check()
    with path.open("rb") as stream:
        header = stream.read(20)
    if not header.startswith(b"SQLite format 3\x00"):
        raise OSError("invalid SQLite database")
    params = "?mode=ro"
    if header[18:20] == b"\x02\x02":
        # A stopped WAL database can be opened without creating journaling files.
        # When WAL is active, the writer already owns both sidecar files.
        if wal is None and shared is None:
            params += "&immutable=1"
        elif wal is None or shared is None:
            raise OSError("incomplete SQLite sidecar state")
    conn = sqlite3.connect(path.as_uri() + params, uri=True, timeout=2)
    try:
        conn.execute("PRAGMA query_only=ON")
        conn.execute("PRAGMA trusted_schema=OFF")
        conn.set_progress_handler(lambda: int(time.monotonic() >= budget.deadline), 10000)
        yield from (hermes_sqlite(conn) if client == "hermes" else opencode_sqlite(conn))
    finally:
        conn.close()


def _read(client: str, path: Path, info: os.stat_result, budget: ScanBudget) -> Iterator[UsageEvent | None]:
    suffix = path.suffix.casefold()
    document = suffix == ".json" and client in ("gemini", "opencode", "cline", "kilo", "droid")
    database = suffix == ".db" and client in ("hermes", "opencode")
    max_file = (512 if database else 32 if document else 128) * 1024 * 1024
    if info.st_size > max_file:
        budget.incomplete.add(client)
        return
    try:
        if database:
            yield from _read_sqlite(client, path, info, budget)
            return
        with path.open("rb") as stream:
            if document:
                raw = stream.read(max_file + 1)
                budget.remaining_bytes -= len(raw)
                budget.check()
                if len(raw) > max_file:
                    budget.incomplete.add(client)
                    return
                payload = json.loads(raw.decode("utf-8-sig"))
                if client == "gemini":
                    yield from gemini(obj(payload))
                elif client == "opencode":
                    yield from opencode_json(obj(payload), path)
                elif client == "droid":
                    yield droid(obj(payload), path, info.st_mtime)
                else:
                    yield from cline(payload, path, client)
                return
            lines = _lines(stream, budget)
            if client in ("pi", "openclaw", "omp"):
                yield from _assistant(lines, path, client)
            else:
                yield from {"codex": codex, "claude": claude, "kimi": kimi, "copilot": copilot, "gemini": gemini_lines,
                            "qwen": qwen, "grok": grok}[client](lines, path)
    except (OSError, ValueError, RecursionError, sqlite3.DatabaseError):
        budget.incomplete.add(client)


def _stamp(path: Path, info: os.stat_result) -> str:
    files = [info]
    if path.suffix.casefold() == ".db":
        wal, _ = _database_sidecars(path)
        if wal:
            files.append(wal)
    metadata = [(item.st_dev, item.st_ino, item.st_size, item.st_mtime_ns, item.st_ctime_ns) for item in files]
    return digest(SCANNER_REVISION, metadata)


@dataclass
class UsageScan:
    events: dict[str, UsageEvent]
    stamps: dict[str, tuple[str, int]]
    warnings: list[str]


def scan_paths(paths: dict[str, list[Path]], now: datetime, known: dict[str, tuple[str, int]]) -> UsageScan:
    events: dict[str, UsageEvent] = {}
    budget = ScanBudget()
    visited: set[str] = set()
    stamps: dict[str, tuple[str, int]] = {}
    for client, roots in paths.items():
        for root in roots:
            if local_path(str(root)) is None:
                continue
            for path, info in _files(client, root, budget):
                key = digest(client, os.path.normcase(os.path.normpath(path)))
                if key in visited:
                    continue
                visited.add(key)
                try:
                    stamp = _stamp(path, info)
                except OSError:
                    budget.incomplete.add(client)
                    continue
                prior = known.get(key)
                if prior is not None and prior[0] == stamp:
                    stamps[key] = prior
                    continue
                malformed = budget.malformed
                valid = 0
                for record in _read(client, path, info, budget):
                    if record is None or record.at.year < 1970:
                        continue
                    if record.at > now:
                        # A future timestamp can become eligible on a later scan.
                        valid = -1
                        continue
                    if valid >= 0:
                        valid += 1
                    previous = events.get(record.id)
                    if previous is None or (record.total, record.messages, record.at) > (previous.total, previous.messages, previous.at):
                        events[record.id] = record
                    if len(events) > MAX_RECORDS:
                        raise AppError("单次采集超过 20 万条用量记录，已有历史保持不变。", "usage-limit")
                if valid >= 0 and client not in budget.incomplete and budget.malformed == malformed:
                    try:
                        after = _walkable(path)
                        if after is not None and _stamp(path, after) == stamp:
                            stamps[key] = (stamp, valid)
                    except OSError:
                        budget.incomplete.add(client)
    warnings = []
    budget.check()
    if budget.incomplete:
        sources = "、".join(SUPPORTED[client].name for client in sorted(budget.incomplete))
        warnings.append(f"{sources} 的部分日志无法读取或超出大小限制，已保留以往记录。")
    if budget.malformed:
        warnings.append(f"忽略了 {budget.malformed} 条损坏或超出大小限制的日志记录。")
    if not events and not any(count for _, count in stamps.values()):
        warnings.append("本次采集未找到可统计的日志记录。")
    return UsageScan(events, stamps, warnings)
