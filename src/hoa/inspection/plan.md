# Inspection & Logging — Design Plan

## Context

The inspection module is a self-contained logging and tracing system. It captures, stores, and exposes structured records of all agent activity. It functions independently — attach it to any Claude Code invocation and it will log inputs, outputs, tool calls, timing, and cost, regardless of whether the agent was launched through HoA's planner or run ad hoc.

**Phase 0 scope:** Structured JSON logging to `.hoa/logs/`, a trace viewer CLI (`hoa inspect`), and a query interface for filtering by run, task, agent, and time range. No real-time dashboard (Phase 1).

---

## Public Interface

The inspection module exposes three things: a `LogEvent` data model, a `Logger` that writes events, and a `TraceStore` that reads them back.

### `LogEvent` — The atomic unit of logging (`logger.py`)

```python
class EventType(str, Enum):
    AGENT_START = "agent.start"
    AGENT_END = "agent.end"
    TOOL_CALL = "tool.call"
    TOOL_RESULT = "tool.result"
    GUARDRAIL_CHECK = "guardrail.check"
    GUARDRAIL_RESULT = "guardrail.result"
    PLAN_CREATED = "plan.created"
    PLAN_APPROVED = "plan.approved"
    PLAN_REJECTED = "plan.rejected"
    TASK_STATE_CHANGE = "task.state_change"
    ESCALATION = "escalation"
    RETRO_CREATED = "retro.created"
    ERROR = "error"
    CUSTOM = "custom"

class LogEvent(BaseModel):
    """A single structured log entry. Immutable, serializable, queryable."""
    id: str                          # ULID — time-sortable
    timestamp: datetime
    event_type: EventType
    run_id: str | None = None
    task_id: str | None = None
    agent_id: str | None = None
    tier: int | None = None
    payload: dict                    # event-specific data (tool args, result, etc.)
    parent_event_id: str | None = None  # for linking tool_call → tool_result
    tags: list[str] = []             # arbitrary tags for filtering

    @computed_field
    @property
    def date_partition(self) -> str:
        """YYYY-MM-DD for file-based partitioning."""
```

**Design decisions:**
- `LogEvent` is a **flat, immutable model**. No nesting, no inheritance hierarchy for event types. The `payload` dict carries type-specific data — this avoids a proliferation of event subclasses while keeping the core model stable.
- `parent_event_id` links related events (e.g., a `TOOL_CALL` to its `TOOL_RESULT`). This enables trace reconstruction without requiring events to be emitted in order.
- Tags are free-form strings for ad hoc filtering (e.g., `["slow", "high-cost", "retry"]`).
- Events use ULIDs for IDs — time-sortable, unique, no coordination needed.

### `Logger` — Event sink (`logger.py`)

```python
class EventSink(Protocol):
    """Where log events go. Swappable for testing."""
    def write(self, event: LogEvent) -> None: ...
    def flush(self) -> None: ...

class JsonFileEventSink:
    """Writes events as JSON lines to date-partitioned files in .hoa/logs/."""
    def __init__(self, log_dir: Path): ...
    # Writes to: log_dir/YYYY-MM-DD/events.jsonl

class InMemoryEventSink:
    """For testing. Collects events in a list."""
    def __init__(self): ...
    @property
    def events(self) -> list[LogEvent]: ...

class Logger:
    """Accepts events and dispatches to one or more sinks."""
    def __init__(self, sinks: list[EventSink] | None = None): ...

    def log(self, event: LogEvent) -> None: ...
    def log_agent_start(self, *, task_id: str, agent_id: str, run_id: str, config: dict) -> str: ...
    def log_agent_end(self, *, event_id: str, result: dict) -> None: ...
    def log_tool_call(self, *, task_id: str, tool_name: str, arguments: dict) -> str: ...
    def log_tool_result(self, *, parent_event_id: str, result: str) -> None: ...
    def log_error(self, *, task_id: str | None, error: str, context: dict | None = None) -> None: ...
```

**Design decisions:**
- `EventSink` is a **Protocol**. The real implementation writes JSON lines; tests use `InMemoryEventSink`.
- `Logger` is a **multiplexer** — it can write to multiple sinks simultaneously (e.g., file + console + future dashboard).
- Convenience methods (`log_agent_start`, `log_tool_call`, etc.) construct `LogEvent` instances with correct `EventType` and return the event ID for linking.
- The logger has **no dependencies** on other HoA modules. It accepts `LogEvent` objects — the caller is responsible for constructing them with the right data.

### `TraceStore` — Query and retrieval (`tracer.py`)

```python
class TraceQuery(BaseModel):
    run_id: str | None = None
    task_id: str | None = None
    agent_id: str | None = None
    event_types: list[EventType] | None = None
    tags: list[str] | None = None
    after: datetime | None = None
    before: datetime | None = None
    limit: int = 1000
    offset: int = 0

class Trace(BaseModel):
    """A sequence of related events forming a trace."""
    run_id: str
    events: list[LogEvent]
    root_task_id: str | None = None
    total_duration_seconds: float | None = None
    total_cost_usd: float | None = None

class TraceStore(Protocol):
    """Reads log events back. Swappable for testing."""
    def query(self, q: TraceQuery) -> list[LogEvent]: ...
    def get_trace(self, run_id: str) -> Trace: ...
    def get_last_run(self) -> Trace | None: ...
    def count(self, q: TraceQuery) -> int: ...

class JsonFileTraceStore:
    """Reads from JSON lines files written by JsonFileEventSink."""
    def __init__(self, log_dir: Path): ...
```

**Design decisions:**
- `TraceStore` is a **Protocol** separate from `EventSink`. Writing and reading are decoupled — you can write to files but query from an in-memory index, or vice versa.
- `TraceQuery` is a data model, not method kwargs. This makes queries serializable (useful for CLI `--filter` flags) and testable (assert on query construction).
- `Trace` aggregates events for a run — convenience for the `hoa inspect --last` use case.
- Phase 0: `JsonFileTraceStore` scans JSON lines files. This is O(n) but sufficient for small-to-medium runs. Phase 1: SQLite index for O(1) lookups.

### `DiffView` — Comparing runs (`replay.py`)

```python
class RunDiff(BaseModel):
    """Differences between two runs of the same task."""
    added_events: list[LogEvent]
    removed_events: list[LogEvent]
    changed_tasks: list[TaskDiffSummary]
    cost_delta_usd: float
    duration_delta_seconds: float

class TaskDiffSummary(BaseModel):
    task_name: str
    old_state: str
    new_state: str
    old_duration: float | None
    new_duration: float | None

class ReplayEngine:
    """Compares and replays traces."""
    def __init__(self, store: TraceStore): ...
    def diff(self, run_id_a: str, run_id_b: str) -> RunDiff: ...
```

---

## Integration Points

| Producer | What it emits | How |
|----------|--------------|-----|
| `core/lifecycle.py` | `log_agent_start()`, `log_agent_end()` | Calls logger before/after agent launch |
| `core/scheduler.py` | `log(TASK_STATE_CHANGE)` | Calls logger on every task state transition |
| `core/planner.py` | `log(PLAN_CREATED)`, `log(PLAN_APPROVED)` | Calls logger on plan lifecycle events |
| `guardrails/engine.py` | `log(GUARDRAIL_CHECK)`, `log(GUARDRAIL_RESULT)` | Calls logger on guardrail evaluation |
| `security/escalation.py` | `log(ESCALATION)` | Calls logger on privilege escalation requests |
| `retro/collector.py` | `log(RETRO_CREATED)` | Calls logger when retrospective is generated |

| Consumer | What it reads | How |
|----------|--------------|-----|
| `cli/inspect.py` | `TraceStore.get_last_run()`, `TraceStore.query()` | CLI reads traces for display |
| `retro/aggregator.py` | `TraceStore.query(event_types=[ERROR])` | Retrospection queries error patterns |
| `guardrails/lifecycle.py` | `TraceStore.query(event_types=[GUARDRAIL_RESULT])` | Monitors guardrail trigger frequency |

**Integration is optional.** If no guardrail module is present, no `GUARDRAIL_CHECK` events are emitted — the logger doesn't care. Every producer calls the logger directly; the logger doesn't poll or subscribe.

---

## Files to Create

| File | Purpose |
|------|---------|
| `src/hoa/inspection/__init__.py` | Package init — exports `Logger`, `LogEvent`, `TraceStore`, `EventType` |
| `src/hoa/inspection/logger.py` | `LogEvent`, `EventType`, `EventSink` protocol, `JsonFileEventSink`, `InMemoryEventSink`, `Logger` |
| `src/hoa/inspection/tracer.py` | `TraceQuery`, `Trace`, `TraceStore` protocol, `JsonFileTraceStore` |
| `src/hoa/inspection/dashboard.py` | Placeholder — Phase 1 real-time streaming |
| `src/hoa/inspection/replay.py` | `RunDiff`, `TaskDiffSummary`, `ReplayEngine` |
| `tests/unit/test_logger.py` | Event creation, sink writing, multiplexing |
| `tests/unit/test_tracer.py` | Query filtering, trace assembly, last-run retrieval |
| `tests/unit/test_replay.py` | Run diffing |

---

## Test Strategy

### Unit tests — Logger (`test_logger.py`)

| Test | What it validates |
|------|------------------|
| `test_log_event_creation` | `LogEvent` with all fields serializes to JSON |
| `test_log_event_ulid_ordering` | Events created in sequence have increasing IDs |
| `test_log_event_date_partition` | `date_partition` returns YYYY-MM-DD string |
| `test_in_memory_sink_collects` | Events written to `InMemoryEventSink` appear in `.events` |
| `test_json_file_sink_writes_jsonl` | Events written to file are valid JSON lines |
| `test_json_file_sink_date_partitioned` | Events on different dates go to different files |
| `test_logger_dispatches_to_multiple_sinks` | Logger with 2 sinks → both receive the event |
| `test_log_agent_start_returns_id` | Convenience method returns event ID for linking |
| `test_log_tool_call_and_result_linked` | `tool.result` event has `parent_event_id` matching `tool.call` |
| `test_logger_with_no_sinks` | Logger with empty sink list → no error, events discarded |

### Unit tests — TraceStore (`test_tracer.py`)

| Test | What it validates |
|------|------------------|
| `test_query_by_run_id` | Only events with matching run_id returned |
| `test_query_by_task_id` | Filters to single task |
| `test_query_by_event_type` | Filters by event type list |
| `test_query_by_tags` | Events with matching tags returned |
| `test_query_by_time_range` | `after` and `before` filters work |
| `test_query_limit_and_offset` | Pagination works correctly |
| `test_get_trace_aggregates` | Trace includes duration and cost totals |
| `test_get_last_run` | Returns most recent run's trace |
| `test_get_last_run_empty` | No runs → returns None |
| `test_count_matches_query_length` | `count()` matches `len(query())` |
| `test_jsonfile_store_reads_sink_output` | Store can read what sink wrote (roundtrip) |

### Unit tests — Replay (`test_replay.py`)

| Test | What it validates |
|------|------------------|
| `test_diff_identical_runs` | Same run diffed with itself → empty diff |
| `test_diff_added_task` | Run B has extra task → shows in added_events |
| `test_diff_cost_delta` | Cost difference calculated correctly |
| `test_diff_duration_delta` | Duration difference calculated correctly |

### Integration test

| Test | What it validates |
|------|------------------|
| `test_write_and_read_roundtrip` | Sink writes events → Store reads them back → events match |

Uses `JsonFileEventSink` + `JsonFileTraceStore` with a `tmp_path` fixture. Validates the full I/O path.

---

## Phase 0 → Phase 1 Evolution

| Area | Phase 0 | Phase 1 |
|------|---------|---------|
| Storage | JSON lines in `.hoa/logs/YYYY-MM-DD/` | SQLite index + JSON lines (index for queries, files for bulk) |
| Query performance | O(n) scan of JSON lines | O(1) via SQLite index |
| Dashboard | None — CLI only (`hoa inspect`) | Real-time streaming via WebSocket |
| Retention | No cleanup | Configurable retention policy (days, size) |
| Event sink | File only | File + SQLite + optional webhook |

The `LogEvent`, `EventSink`, and `TraceStore` interfaces stay the same — only implementations change.
