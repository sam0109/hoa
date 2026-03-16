# Task DAG Management System — Design Plan

## Context

GitHub Issues can't represent DAG dependencies — there's no way to say "task B depends on tasks A and C" and have scheduling respect that. HoA needs its own task management system where plans are DAGs, dependencies control execution order, and agents own tasks at specific tiers.

## Dependencies

```
tasks/  →  (none)
```

The tasks module has **no dependencies** on other HoA modules. It defines the `Task` data model, `TaskState` state machine, the in-memory DAG engine, and the SQLite-backed `TaskStore`. It is consumed by `core/` (which uses `TaskStore` for scheduling) and `inspection/` (which logs task state changes), but it never imports from them.

## Approach: SQLite + In-Memory DAG (Hybrid)

### Why this combination?

| Approach | Local-first | Survives restarts | Queryable | Concurrent access | DAG-native |
|---|---|---|---|---|---|
| SQLite alone | ✅ | ✅ | ✅ SQL | ✅ WAL mode | ⚠️ recursive CTEs for graphs |
| JSON files | ✅ | ✅ | ⚠️ load-filter | ❌ file locking fragile | ⚠️ flat |
| In-memory only | ✅ | ❌ crash loses state | ✅ Python | ⚠️ locking | ✅ |
| NetworkX + persistence | ✅ | ⚠️ | ⚠️ | ⚠️ | ✅ |

**None alone is right.** The hybrid wins:

- **SQLite is the source of truth.** Survives crashes, queryable from CLI (`sqlite3`), single-file, zero external services. WAL mode handles concurrent readers.
- **In-memory DAG is the working cache.** Graph operations (cycle detection, topological sort, ready-task resolution, critical path) are trivial in Python but painful in SQL. Write-through: every mutation hits SQLite first, then updates memory. If they diverge, SQLite wins.
- **Scheduler API pattern.** The scheduler process is the single writer. Agents communicate back through an API (function calls initially, HTTP later for Docker containers). Agents never write to SQLite directly.

### Dependencies

Only two new dependencies beyond stdlib:
- **pydantic** (≥2.5) — validation, serialization, JSON schema
- **python-ulid** (≥2.0) — time-sortable unique IDs (chronological ordering for free)

SQLite is stdlib (`sqlite3`). No SQLAlchemy, no NetworkX, no external services.

---

## Data Model (`models.py`)

### TaskState — State machine

```
pending → planning → awaiting_approval → running → completing → retrospecting → done
                                                                               ↘ failed
failed → pending  (retry)
```

Transitions are an explicit dict (`VALID_TRANSITIONS`), not method logic — inspectable and testable.

### Task — The core model

| Field | Type | Purpose |
|-------|------|---------|
| `id` | ULID str | Time-sortable unique ID |
| `name` | str | Human-readable name |
| `description` | str | Detailed description |
| `agent_id` | str \| None | Which agent owns this task |
| `tier` | int | Tier in the hierarchy (0 = top) |
| `parent_task_id` | str \| None | If part of a sub-DAG (plan decomposition) |
| `run_id` | str \| None | Groups tasks into a single `hoa run` |
| `depends_on` | list[str] | Task IDs this depends on (DAG edges) |
| `state` | TaskState | Current lifecycle state |
| `created_at` | datetime | UTC |
| `updated_at` | datetime | UTC |
| `started_at` | datetime \| None | When transitioned to RUNNING |
| `completed_at` | datetime \| None | When transitioned to DONE/FAILED |
| `escalation_history` | list[EscalationRecord] | Full escalation chain |
| `retrospective` | Retrospective \| None | Post-completion reflection |
| `metadata` | dict | Escape hatch for anything else |
| `plan_task_ids` | list[str] | Child tasks from plan decomposition |

### Sub-models

- **EscalationRecord** — timestamp, from/to agent, from/to tier, reason, suggested options
- **Retrospective** — outcome, summary, lessons, metrics dict

---

## DAG Engine (`dag.py`) — In-Memory Cache

Dual adjacency lists for O(1) lookups in both directions:
- `_forward[A] = {B, C}` — A depends on B and C (A waits for them)
- `_reverse[B] = {A}` — B is depended on by A (B blocks A)

### Key operations

| Method | What it does | Complexity |
|--------|-------------|-----------|
| `add_task(task)` | Add task + edges, reject if cycle | O(V) for cycle check |
| `ready_tasks()` | Pending tasks whose deps are all terminal | O(V × avg_deps) |
| `blocked_by(task_id)` | Non-terminal dependencies of a task | O(deps) |
| `blocks(task_id)` | Tasks that depend on this one | O(reverse_deps) |
| `subtasks(parent_id)` | All tasks in a parent's plan sub-DAG | O(V) |
| `topological_sort()` | Kahn's algorithm | O(V + E) |
| `critical_path(target)` | Longest dependency chain to target | O(V + E) |

### Cycle detection

Before adding an edge `A depends on B`, DFS from B through existing forward edges — if we reach A, adding the edge would create a cycle. Reject with `CycleError` that includes the cycle path for debugging.

---

## SQLite Storage (`store.py`)

### Schema

```sql
tasks (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    state TEXT NOT NULL,           -- indexed, for WHERE state = ?
    agent_id TEXT,                 -- indexed, for WHERE agent_id = ?
    tier INTEGER DEFAULT 0,
    parent_task_id TEXT,           -- indexed, for WHERE parent_task_id = ?
    run_id TEXT,                   -- indexed, for WHERE run_id = ?
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    started_at TEXT,
    completed_at TEXT,
    blob TEXT NOT NULL             -- full Pydantic JSON (canonical representation)
)

dependencies (
    task_id TEXT NOT NULL,
    depends_on_id TEXT NOT NULL,
    PRIMARY KEY (task_id, depends_on_id)
)
```

### The blob column pattern

Indexed columns exist for SQL `WHERE`/`ORDER BY`. The `blob` column is the canonical Pydantic JSON containing everything (escalation_history, retrospective, metadata, etc.).

**Why this works:**
- **No migrations** — Add a field to the Pydantic model, it appears in the blob. Old rows get defaults on load.
- **No ORM** — Raw `sqlite3` with parameterized queries.
- **Inspectable** — `sqlite3 hoa.db "SELECT json_extract(blob, '$.retrospective') FROM tasks WHERE state='done'"` works from CLI.

### Write-through protocol

Every mutation:
1. Acquire write lock (`threading.Lock`)
2. Validate against in-memory DAG (fast cycle check, state machine check)
3. Write to SQLite (within a transaction)
4. Update in-memory DAG
5. Emit structured event
6. Release lock

If SQLite write fails → roll back in-memory change. If process crashes → SQLite is intact, in-memory is rebuilt from SQLite on restart.

### Key methods

| Method | What it does |
|--------|-------------|
| `add_task(task)` | Validate DAG, persist, update cache, emit event |
| `transition(task_id, new_state)` | Enforce state machine, update timestamps, persist |
| `attach_plan(parent_id, tasks)` | Atomically add sub-DAG to parent (rollback on any failure) |
| `update_task(task_id, **kwargs)` | Update fields (not state — use transition for that) |
| `query(state?, agent_id?, tier?, run_id?)` | SQL-backed flat filtering |
| `get(task_id)` | Single task lookup from cache |
| `ready_tasks()` / `blocked_by()` / etc. | Delegated to in-memory DAG |
| `dump_json()` | Full DAG as JSON for inspection |

### Restart recovery

1. Process crashes.
2. SQLite file is intact (WAL + fsync).
3. New process starts → `_load_from_db()` reconstructs in-memory DAG in dependency order.
4. Tasks that were `RUNNING` are still `RUNNING`. Scheduler checks if agents are alive; if not, fails those tasks.

---

## How Plans (Sub-DAGs) Work

```
Task X: "Build authentication system"
  state: RUNNING
  plan_task_ids: [A, B, C]
  │
  ├── Task A: "Design auth schema"        parent_task_id: X, depends_on: []
  ├── Task B: "Implement JWT middleware"   parent_task_id: X, depends_on: [A]
  └── Task C: "Write auth tests"           parent_task_id: X, depends_on: [A, B]
```

1. Scheduler dispatches Task X to an agent.
2. Agent decomposes X into subtasks [A, B, C].
3. Agent calls `store.attach_plan(X.id, [A, B, C])` — atomically adds all subtasks with `parent_task_id = X`.
4. Scheduler sees A as ready (no deps), dispatches it.
5. When all subtasks are DONE, scheduler can transition X to COMPLETING.
6. **Sub-DAGs can nest** — Task B could itself produce subtasks. The `parent_task_id` chain gives the full decomposition tree.

---

## Structured Event Logging (`events.py`)

Every state change emits a structured JSON event to `logging.getLogger("hoa.task_events")`:

```json
{
  "event": "task.state_changed",
  "timestamp": "2026-03-15T20:00:00Z",
  "task_id": "01JD...",
  "task_name": "Implement JWT middleware",
  "state": "running",
  "agent_id": "agent-42",
  "tier": 1,
  "run_id": "run-001",
  "parent_task_id": "01JD...",
  "previous_state": "awaiting_approval"
}
```

Event types: `task.created`, `task.state_changed`, `task.plan_attached`, `task.escalated`, `task.retrospective`

---

## Concurrent Access Model

```
Agent Container A ──read (HTTP)──→ ┌────────────┐
                                    │ Scheduler   │  (single writer)
Agent Container B ──read (HTTP)──→ │ Process     │
                                    │  ┌────────┐ │
Agent results ──────write (HTTP)──→ │  │In-Mem  │ │
                                    │  │DAG     │ │
                                    │  └───┬────┘ │
                                    │      │write │
                                    │  ┌───▼────┐ │
                                    │  │SQLite  │ │
                                    │  │(WAL)   │ │
                                    │  └────────┘ │
                                    └────────────┘
```

- Scheduler holds the write lock and in-memory DAG. Single writer.
- Agents communicate through the scheduler API (function calls now, HTTP later).
- SQLite WAL allows concurrent readers (for inspection, CLI tools, dashboard).

---

## Files to Create

| File | Purpose |
|------|---------|
| `pyproject.toml` | Project config, deps (pydantic, python-ulid), dev deps (pytest, ruff) |
| `src/hoa/__init__.py` | Package init |
| `src/hoa/tasks/__init__.py` | Tasks subpackage init |
| `src/hoa/tasks/models.py` | Task, TaskState, EscalationRecord, Retrospective, VALID_TRANSITIONS |
| `src/hoa/tasks/dag.py` | In-memory DAG engine (adjacency lists, cycle detection, scheduling queries) |
| `src/hoa/tasks/store.py` | SQLite-backed TaskStore (write-through, restart recovery, query) |
| `src/hoa/tasks/events.py` | Structured event logging for task lifecycle |
| `tests/__init__.py` | Tests package |
| `tests/unit/__init__.py` | Unit tests package |
| `tests/unit/test_models.py` | State machine, serialization, ULID tests |
| `tests/unit/test_dag.py` | DAG operations, cycle detection, ready_tasks, topological sort |
| `tests/unit/test_store.py` | Persistence, restart recovery, atomicity, concurrent reads |

---

## Phase 0 → Phase 1 Evolution Path

| Area | Phase 0 (now) | Phase 1 (later) |
|---|---|---|
| Scheduler | Polling loop with `time.sleep` | `asyncio` event loop with callbacks |
| Agent comms | Function calls (same process) | HTTP API for Docker containers |
| Concurrency | Threading lock + WAL | `aiosqlite` or move to Postgres if multi-machine |
| Schema | Blob column, no migrations | Alembic if schema stabilizes |
| Monitoring | JSON lines log file | Datasette web UI or custom dashboard |
| Critical path | Task-count weighted | Estimated duration weighted |
| Retries | Manual `FAILED → PENDING` | Automatic retry with backoff |

The `TaskStore` interface stays the same — only internals change. The scheduler's `AgentDispatcher` protocol means the dispatch mechanism is swappable.
