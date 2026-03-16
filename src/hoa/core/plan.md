# Core Orchestration Engine — Design Plan

## Context

The core module is the integration hub of HoA. It manages the agent lifecycle (init, plan, approve, run, retro, terminate), hosts the planner that decomposes tasks into DAGs, and runs the scheduler that dispatches ready tasks respecting dependency order. It depends on the `tasks/` module for storage and the `Sandbox` protocol from `security/` for agent isolation — but both dependencies are injected, not imported directly.

**Phase 0 scope:** Single-agent execution. The "agent" is a Claude Code instance launched via subprocess. The planner produces a DAG, the human approves it, and the scheduler executes tasks sequentially (parallel execution is Phase 1). No multi-tier delegation.

**Relationship to `tasks/`:** The `tasks/` module owns the data model (`Task`, `TaskState`) and persistence (`TaskStore`, `DAG`). The `core/` module owns the *orchestration logic* — it uses `TaskStore` as a dependency but does not define task storage. See `src/hoa/tasks/plan.md` for the storage layer design.

---

## Public Interface

### `AgentConfig` — How to launch an agent (`lifecycle.py`)

```python
class AgentConfig(BaseModel):
    """Everything needed to launch a Claude Code agent for a specific task."""
    task_id: str
    working_dir: str
    prompt: str                              # the task description / instructions
    claude_md: str | None = None             # CLAUDE.md content to inject
    agents_md: str | None = None             # AGENTS.md content to inject
    permission_manifest: PermissionManifest | None = None
    guardrail_ids: list[str] = []            # guardrails to enforce during execution
    timeout_seconds: int = 600
    max_cost_usd: float | None = None
```

### `AgentResult` — What comes back (`lifecycle.py`)

```python
class AgentResult(BaseModel):
    task_id: str
    success: bool
    output: str                              # agent's final output
    error: str | None = None
    tool_calls: list[ToolCallRecord] = []    # every tool call made
    token_usage: TokenUsage | None = None
    cost_usd: float | None = None
    duration_seconds: float | None = None
    files_modified: list[str] = []           # paths changed during execution

class ToolCallRecord(BaseModel):
    tool_name: str
    arguments: dict
    result: str
    timestamp: datetime

class TokenUsage(BaseModel):
    input_tokens: int
    output_tokens: int
```

### `AgentLauncher` — Protocol for launching agents (`lifecycle.py`)

```python
class AgentLauncher(Protocol):
    """Launches a Claude Code instance for a task. Swappable for testing."""
    async def launch(self, config: AgentConfig) -> AgentResult: ...
    async def abort(self, task_id: str) -> None: ...
```

**Design decisions:**
- `AgentLauncher` is a **Protocol**, not a class. The real implementation calls `claude` CLI as a subprocess. Tests inject a mock that returns canned `AgentResult`s.
- The protocol is intentionally narrow — launch and abort. No "send message to running agent" (that's future work in `comms/`).

### `Planner` — Task decomposition (`planner.py`)

```python
class SubtaskSpec(BaseModel):
    name: str
    description: str
    depends_on: list[str] = []              # names of other subtasks in this plan
    execution: Literal["self", "delegate"]  # self-execute or delegate to sub-agent
    estimated_complexity: Literal["trivial", "small", "medium", "large"] = "small"

class Plan(BaseModel):
    parent_task_id: str
    subtasks: list[SubtaskSpec]
    rationale: str                           # why this decomposition

    def to_dag_edges(self) -> list[tuple[str, str]]:
        """Convert named dependencies to edge pairs for DAG validation."""

    def validate_dag(self) -> list[str]:
        """Return list of errors (empty = valid). Checks: no cycles, no missing deps, no self-deps."""

class Planner(Protocol):
    """Decomposes a task into a plan. Phase 0: calls Claude Code to plan. Testable with mocks."""
    async def create_plan(self, task_description: str, context: PlanningContext) -> Plan: ...

class PlanningContext(BaseModel):
    project_description: str
    existing_files: list[str]               # file listing for context
    completed_tasks: list[str]              # what's already done
    guardrail_summaries: list[str] = []     # active guardrails (for awareness)
```

**Design decisions:**
- `Plan` is a **pure data model** — it can be validated, serialized, and diffed without executing anything.
- `Plan.validate_dag()` runs cycle detection and dependency resolution on the subtask list. This is a pure function — no database, no side effects.
- `Planner` is a **Protocol**. Phase 0 calls Claude Code with a planning prompt. Tests inject a mock that returns canned plans.
- `SubtaskSpec.execution` is declared at plan time, not execution time. The reviewer sees "this subtask will be delegated" and can override.

### `PlanReviewer` — Plan approval (`planner.py`)

```python
class ReviewDecision(BaseModel):
    approved: bool
    feedback: str | None = None             # revision instructions if not approved
    modified_plan: Plan | None = None       # reviewer can directly edit the plan

class PlanReviewer(Protocol):
    """Reviews and approves/rejects plans. Phase 0: human via CLI. Future: parent agent."""
    async def review(self, plan: Plan, task_description: str) -> ReviewDecision: ...
```

### `Scheduler` — Task dispatch (`scheduler.py`)

```python
class Scheduler:
    """Dispatches ready tasks to agents, respecting DAG order."""

    def __init__(
        self,
        store: TaskStore,           # from tasks/ module
        launcher: AgentLauncher,
        enforcer: PermissionEnforcer | None = None,   # from security/ — optional
    ): ...

    async def run(self, run_id: str) -> RunResult: ...
    async def tick(self) -> list[str]:
        """One scheduling cycle: find ready tasks, dispatch them. Returns dispatched task IDs."""

    def pending_tasks(self) -> list[Task]: ...
    def running_tasks(self) -> list[Task]: ...
    def is_complete(self) -> bool: ...

class RunResult(BaseModel):
    run_id: str
    tasks_completed: int
    tasks_failed: int
    total_cost_usd: float
    total_duration_seconds: float
    success: bool                            # True if all tasks completed
```

**Design decisions:**
- The scheduler takes a `TaskStore` and `AgentLauncher` as constructor args — both are injected. Tests provide in-memory implementations.
- `PermissionEnforcer` is optional. If absent, no permission checking occurs (the security module is not required).
- `tick()` is the fundamental operation: one scheduling cycle. `run()` is a loop that calls `tick()` until all tasks are done or failed. This makes testing trivial — call `tick()` and assert on what was dispatched.
- Phase 0: `tick()` dispatches one task at a time (sequential). Phase 1: dispatches all ready tasks concurrently.

---

## Integration Points

| Consumer | What it uses | How |
|----------|-------------|-----|
| `cli/run.py` | `Scheduler`, `AgentLauncher` | CLI constructs a scheduler, calls `run()` |
| `cli/init.py` | `AgentConfig` | Generates initial config for project setup |
| `inspection/logger.py` | `AgentResult`, `ToolCallRecord` | Logs agent results after each task |
| `guardrails/engine.py` | `AgentResult` | Post-execution guardrails evaluate the result |
| `retro/collector.py` | `AgentResult` | Retrospection analyzes what happened |
| `security/` | `PermissionManifest` (input), `PermissionEnforcer` (used by scheduler) | Scheduler checks permissions before dispatch |
| `tasks/` | `TaskStore`, `Task`, `TaskState` | Scheduler reads/writes task state |

**All dependencies are injected.** The scheduler doesn't import `inspection`, `guardrails`, or `retro` — it emits `AgentResult` objects that those modules consume. The wiring happens at the CLI layer.

---

## Files to Create

| File | Purpose |
|------|---------|
| `src/hoa/core/__init__.py` | Package init — exports `Scheduler`, `AgentLauncher`, `Planner`, `PlanReviewer` |
| `src/hoa/core/lifecycle.py` | `AgentConfig`, `AgentResult`, `ToolCallRecord`, `TokenUsage`, `AgentLauncher` protocol, CC subprocess impl |
| `src/hoa/core/planner.py` | `SubtaskSpec`, `Plan`, `PlanningContext`, `Planner` protocol, `PlanReviewer` protocol, `ReviewDecision` |
| `src/hoa/core/scheduler.py` | `Scheduler`, `RunResult` |
| `tests/unit/test_lifecycle.py` | Agent config/result model tests, launcher protocol tests |
| `tests/unit/test_planner.py` | Plan validation, DAG edge conversion, cycle detection |
| `tests/unit/test_scheduler.py` | Scheduling logic with mock store and launcher |

---

## Test Strategy

### Unit tests — Planner (`test_planner.py`)

| Test | What it validates |
|------|------------------|
| `test_plan_validate_dag_valid` | Linear chain A→B→C passes validation |
| `test_plan_validate_dag_cycle` | A→B→A returns cycle error |
| `test_plan_validate_dag_missing_dep` | Dep on nonexistent subtask returns error |
| `test_plan_validate_dag_self_dep` | A→A returns error |
| `test_plan_validate_dag_parallel` | Independent tasks with shared downstream passes |
| `test_plan_to_dag_edges` | Converts named deps to `(name, dep_name)` pairs |
| `test_plan_roundtrip_json` | Serialize → deserialize is lossless |
| `test_subtask_spec_defaults` | Default `execution="self"`, empty `depends_on` |
| `test_plan_reviewer_approve` | Mock reviewer approves → plan returned |
| `test_plan_reviewer_reject_with_feedback` | Mock reviewer rejects → feedback string returned |
| `test_plan_reviewer_modify` | Mock reviewer returns modified plan |

### Unit tests — Lifecycle (`test_lifecycle.py`)

| Test | What it validates |
|------|------------------|
| `test_agent_config_minimal` | Only required fields, defaults for optional |
| `test_agent_config_with_manifest` | Permission manifest attached and serializable |
| `test_agent_result_success` | Successful result with output and tool calls |
| `test_agent_result_failure` | Failed result with error and partial output |
| `test_token_usage_model` | Token counts serialize/deserialize |
| `test_tool_call_record_model` | Tool call records with timestamp |
| `test_launcher_protocol_mock` | Mock launcher satisfies `AgentLauncher` protocol |

### Unit tests — Scheduler (`test_scheduler.py`)

| Test | What it validates |
|------|------------------|
| `test_tick_dispatches_ready_task` | Single ready task → launcher called with correct config |
| `test_tick_skips_blocked_tasks` | Task with unfinished deps → not dispatched |
| `test_tick_respects_dag_order` | A→B: A dispatched first, B only after A completes |
| `test_tick_no_ready_tasks` | All tasks blocked or done → tick returns empty |
| `test_run_completes_all_tasks` | Linear DAG → all tasks transition to done |
| `test_run_fails_on_task_failure` | Failed task → run reports failure, blocked tasks not dispatched |
| `test_scheduler_without_enforcer` | No security module → scheduler still works |
| `test_scheduler_with_enforcer` | Permission check failure → task not dispatched |
| `test_is_complete_true` | All tasks done → True |
| `test_is_complete_false` | Running tasks remain → False |
| `test_run_result_aggregates_cost` | Total cost = sum of individual task costs |

### Integration test — Full lifecycle

| Test | What it validates |
|------|------------------|
| `test_plan_to_execution_roundtrip` | Create plan → validate → store tasks → schedule → all complete |

Uses mock `AgentLauncher` and real `TaskStore` (in-memory SQLite). Validates that the planner's output can flow through the scheduler without data loss.

---

## Phase 0 → Phase 1 Evolution

| Area | Phase 0 | Phase 1 |
|------|---------|---------|
| Agent execution | `subprocess.run(["claude", ...])` | Docker container with `claude` CLI inside |
| Parallelism | Sequential — `tick()` dispatches one task | Concurrent — `tick()` dispatches all ready tasks via `asyncio.gather` |
| Plan approval | Human via CLI prompt | Parent agent via `PlanReviewer` protocol |
| Sub-agent delegation | Not implemented — all tasks are `execution="self"` | Scheduler spawns child schedulers for delegated subtasks |
| Context injection | Write `CLAUDE.md` to working dir before launch | Mount as read-only volume in container |

The `AgentLauncher`, `Planner`, and `PlanReviewer` protocols stay the same — only implementations change. The `Scheduler` gains concurrency but its `tick()` contract is unchanged.
