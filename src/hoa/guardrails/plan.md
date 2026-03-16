# Guardrail System — Design Plan

## Context

The guardrail module is a standalone constraint enforcement engine. It evaluates agent work products against a registry of rules — deterministic checks (linters, test suites, validators) and agent checks (LLM-based evaluation). It can run independently against any code change or agent output, with no dependency on the planner, inspection layer, or security module.

**Phase 0 scope:** Deterministic checks only (shell commands that return pass/fail). Agent checks (LLM-based evaluation) are Phase 1. The guardrail registry is a YAML file in `.hoa/guardrails/`. The engine runs checks and returns structured results.

---

## Public Interface

The guardrail module exposes four things: a `Guardrail` data model, a `GuardrailRegistry` for storage/retrieval, a `GuardrailEngine` that evaluates checks, and a `GuardrailResult` that reports outcomes.

### `Guardrail` — Rule definition (`types.py`)

```python
class Mechanism(str, Enum):
    DETERMINISTIC = "deterministic"     # shell command, returns exit code
    AGENT = "agent"                     # LLM evaluates against natural language rule

class Phase(str, Enum):
    PRE_EXECUTION = "pre"               # before agent acts
    RUNTIME = "runtime"                 # while agent works
    POST_EXECUTION = "post"             # after agent reports completion

class Scope(BaseModel):
    """Where this guardrail applies."""
    global_: bool = False               # applies to all tasks
    tiers: list[int] | None = None      # specific tiers (e.g., [0, 1])
    roles: list[str] | None = None      # specific roles (e.g., ["lead", "worker"])
    agent_ids: list[str] | None = None  # specific agents

    def matches(self, *, tier: int | None = None, role: str | None = None, agent_id: str | None = None) -> bool:
        """Return True if this scope applies to the given context."""

class Guardrail(BaseModel):
    """A single guardrail rule. Immutable, serializable."""
    id: str                              # ULID
    name: str                            # human-readable name
    description: str                     # what this guardrail checks
    mechanism: Mechanism
    phase: Phase
    scope: Scope
    enabled: bool = True

    # Deterministic-specific
    command: str | None = None           # shell command to run (exit 0 = pass)
    timeout_seconds: int = 30

    # Agent-specific (Phase 1)
    rule_prompt: str | None = None       # natural language rule for LLM evaluator
    evaluator_model: str | None = None   # which model to use for evaluation

    created_at: datetime
    updated_at: datetime
    tags: list[str] = []                 # for filtering (e.g., ["style", "security", "testing"])
```

**Design decisions:**
- `Guardrail` is a **flat model** — no subclasses for deterministic vs. agent. The `mechanism` field controls which fields are relevant. This simplifies serialization and registry storage.
- `Scope` uses a `matches()` method for runtime filtering. A guardrail with `global_=True` matches everything. Scopes can combine tier + role + agent_id for fine-grained targeting.
- Commands run in the project's working directory with the agent's output available. Convention: the command receives the working directory as CWD and can inspect any file.

### `GuardrailResult` — Check outcome (`types.py`)

```python
class Verdict(str, Enum):
    PASS = "pass"
    WARN = "warn"
    FAIL = "fail"
    ERROR = "error"                     # guardrail itself errored (not the agent)
    SKIP = "skip"                       # guardrail not applicable (scope mismatch)

class GuardrailResult(BaseModel):
    """Result of evaluating a single guardrail."""
    guardrail_id: str
    guardrail_name: str
    verdict: Verdict
    reason: str                          # human-readable explanation
    duration_seconds: float
    output: str | None = None            # stdout/stderr from command or LLM response
    timestamp: datetime
```

### `GuardrailRegistry` — Storage and retrieval (`registry.py`)

```python
class GuardrailRegistry(Protocol):
    """Stores and retrieves guardrail definitions. Swappable for testing."""
    def add(self, guardrail: Guardrail) -> None: ...
    def get(self, guardrail_id: str) -> Guardrail | None: ...
    def remove(self, guardrail_id: str) -> None: ...
    def list(self, *, phase: Phase | None = None, mechanism: Mechanism | None = None, enabled_only: bool = True) -> list[Guardrail]: ...
    def find_applicable(self, *, phase: Phase, tier: int | None = None, role: str | None = None, agent_id: str | None = None) -> list[Guardrail]: ...

class YamlFileRegistry:
    """Reads/writes guardrails as YAML files in a directory."""
    def __init__(self, guardrails_dir: Path): ...
    # Each guardrail is a separate YAML file: guardrails_dir/{id}.yaml

class InMemoryRegistry:
    """For testing."""
    def __init__(self): ...
```

**Design decisions:**
- `GuardrailRegistry` is a **Protocol**. Production uses YAML files in `.hoa/guardrails/`. Tests use `InMemoryRegistry`.
- Each guardrail is a separate file — easier to version control, diff, and review than a single monolithic config.
- `find_applicable()` combines phase filtering with scope matching in one call — the engine's primary query.

### `GuardrailEngine` — Evaluation (`engine.py`)

```python
class EvaluationContext(BaseModel):
    """Everything the engine needs to run guardrails."""
    working_dir: str                     # project directory (CWD for commands)
    task_id: str | None = None
    agent_id: str | None = None
    tier: int | None = None
    role: str | None = None
    phase: Phase                         # which phase we're evaluating

class GuardrailEngine:
    """Evaluates guardrails against agent work. Stateless except for the registry."""

    def __init__(
        self,
        registry: GuardrailRegistry,
        command_runner: CommandRunner | None = None,    # injectable for testing
    ): ...

    async def evaluate(self, context: EvaluationContext) -> list[GuardrailResult]:
        """Run all applicable guardrails for the given context. Returns results."""

    async def evaluate_single(self, guardrail: Guardrail, context: EvaluationContext) -> GuardrailResult:
        """Run a single guardrail. Useful for testing and debugging."""

class CommandRunner(Protocol):
    """Runs shell commands. Swappable for testing."""
    async def run(self, command: str, cwd: str, timeout: int) -> tuple[int, str, str]:
        """Returns (exit_code, stdout, stderr)."""

class SubprocessCommandRunner:
    """Real implementation using asyncio.create_subprocess_shell."""
    async def run(self, command: str, cwd: str, timeout: int) -> tuple[int, str, str]: ...

class MockCommandRunner:
    """For testing. Returns canned responses."""
    def __init__(self, responses: dict[str, tuple[int, str, str]]): ...
```

**Design decisions:**
- The engine is **stateless** — it takes a registry at construction and evaluates against it. No mutation, no side effects beyond running the shell commands.
- `CommandRunner` is a **Protocol**. Tests inject a mock that returns predetermined exit codes and output. Production uses `SubprocessCommandRunner`.
- `evaluate()` runs all applicable guardrails and returns all results — it does not short-circuit on first failure. The caller decides how to handle mixed pass/fail results.
- Each guardrail runs independently — no ordering between guardrails. This enables future parallel execution.

### `GuardrailLifecycle` — Creation and monitoring (`lifecycle.py`)

```python
class GuardrailStats(BaseModel):
    """Accumulated statistics for a guardrail."""
    guardrail_id: str
    total_runs: int = 0
    pass_count: int = 0
    warn_count: int = 0
    fail_count: int = 0
    error_count: int = 0
    avg_duration_seconds: float = 0.0
    last_run: datetime | None = None

class GuardrailLifecycleManager:
    """Manages guardrail creation, monitoring, and refinement."""

    def __init__(self, registry: GuardrailRegistry): ...

    def create_from_failure(self, *, name: str, description: str, command: str, phase: Phase, scope: Scope) -> Guardrail:
        """Create a new deterministic guardrail from a failure observation."""

    def update_stats(self, result: GuardrailResult) -> None:
        """Track pass/fail/warn rates for monitoring."""

    def get_stats(self, guardrail_id: str) -> GuardrailStats | None: ...

    def suggest_retirement(self, min_runs: int = 100, max_error_rate: float = 0.5) -> list[Guardrail]:
        """Suggest guardrails to retire based on high error rate (false positives)."""
```

---

## Integration Points

| Consumer | What it uses | How |
|----------|-------------|-----|
| `core/scheduler.py` | `GuardrailEngine.evaluate()` | Pre/post-execution guardrails run around task dispatch |
| `core/planner.py` | `GuardrailEngine.evaluate(phase=PRE)` | Plan approval can trigger pre-execution guardrails |
| `inspection/logger.py` | `GuardrailResult` | Results are logged as `GUARDRAIL_CHECK`/`GUARDRAIL_RESULT` events |
| `retro/aggregator.py` | `GuardrailStats` | Retrospection examines guardrail effectiveness |
| `cli/guardrail.py` | `GuardrailRegistry`, `GuardrailLifecycleManager` | CLI for listing, adding, removing guardrails |
| `security/permissions.py` | `CommandRunner` | Security module can delegate command checking to guardrails *(optional)* |

**Integration is optional.** The engine can evaluate guardrails without any other module present. Call `engine.evaluate(context)` and get `list[GuardrailResult]` back — no inspection, no security, no planner needed.

---

## Files to Create

| File | Purpose |
|------|---------|
| `src/hoa/guardrails/__init__.py` | Package init — exports `Guardrail`, `GuardrailEngine`, `GuardrailResult`, `GuardrailRegistry` |
| `src/hoa/guardrails/types.py` | `Guardrail`, `GuardrailResult`, `Verdict`, `Mechanism`, `Phase`, `Scope` |
| `src/hoa/guardrails/engine.py` | `GuardrailEngine`, `EvaluationContext`, `CommandRunner` protocol, `SubprocessCommandRunner`, `MockCommandRunner` |
| `src/hoa/guardrails/registry.py` | `GuardrailRegistry` protocol, `YamlFileRegistry`, `InMemoryRegistry` |
| `src/hoa/guardrails/lifecycle.py` | `GuardrailLifecycleManager`, `GuardrailStats` |
| `tests/unit/test_guardrail_types.py` | Model validation, scope matching |
| `tests/unit/test_guardrail_engine.py` | Evaluation logic with mock command runner |
| `tests/unit/test_guardrail_registry.py` | YAML persistence, filtering, find_applicable |
| `tests/unit/test_guardrail_lifecycle.py` | Stats tracking, retirement suggestions |

---

## Test Strategy

### Unit tests — Types (`test_guardrail_types.py`)

| Test | What it validates |
|------|------------------|
| `test_guardrail_model_roundtrip` | Serialize → deserialize is lossless |
| `test_scope_global_matches_everything` | `global_=True` matches any tier/role/agent |
| `test_scope_tier_filter` | `tiers=[0, 1]` matches tier 0, rejects tier 2 |
| `test_scope_role_filter` | `roles=["lead"]` matches "lead", rejects "worker" |
| `test_scope_agent_filter` | `agent_ids=["a1"]` matches "a1", rejects "a2" |
| `test_scope_combined_filter` | `tiers=[0] + roles=["lead"]` — must match both |
| `test_verdict_enum_values` | All verdict values are lowercase strings |
| `test_guardrail_result_model` | Result includes duration and timestamp |
| `test_guardrail_defaults` | New guardrail has `enabled=True`, `timeout_seconds=30` |

### Unit tests — Engine (`test_guardrail_engine.py`)

| Test | What it validates |
|------|------------------|
| `test_evaluate_single_pass` | Command exits 0 → verdict PASS |
| `test_evaluate_single_fail` | Command exits 1 → verdict FAIL |
| `test_evaluate_single_timeout` | Command exceeds timeout → verdict ERROR |
| `test_evaluate_single_command_error` | Command not found → verdict ERROR with reason |
| `test_evaluate_captures_stdout` | stdout/stderr captured in result |
| `test_evaluate_filters_by_phase` | Only matching-phase guardrails run |
| `test_evaluate_filters_by_scope` | Out-of-scope guardrails return SKIP |
| `test_evaluate_disabled_guardrail` | `enabled=False` → skipped |
| `test_evaluate_multiple_all_pass` | 3 guardrails all pass → 3 PASS results |
| `test_evaluate_multiple_mixed` | 2 pass + 1 fail → all results returned (no short-circuit) |
| `test_evaluate_empty_registry` | No applicable guardrails → empty results |
| `test_engine_with_mock_runner` | Mock runner returns canned exit codes |
| `test_engine_uses_context_cwd` | Command receives correct working directory |

### Unit tests — Registry (`test_guardrail_registry.py`)

| Test | What it validates |
|------|------------------|
| `test_add_and_get` | Add guardrail, retrieve by ID |
| `test_remove` | Remove guardrail, get returns None |
| `test_list_all` | List returns all enabled guardrails |
| `test_list_by_phase` | Filter by phase |
| `test_list_by_mechanism` | Filter by mechanism |
| `test_find_applicable` | Combines phase + scope matching |
| `test_find_applicable_none_match` | No guardrails match → empty list |
| `test_yaml_file_persistence` | Write to YAML → read back → matches |
| `test_yaml_file_roundtrip` | Multiple guardrails survive save/load cycle |
| `test_in_memory_registry` | Same behavior as YAML but in-memory |

### Unit tests — Lifecycle (`test_guardrail_lifecycle.py`)

| Test | What it validates |
|------|------------------|
| `test_create_from_failure` | Creates guardrail with correct fields |
| `test_update_stats_pass` | Stats increment pass_count |
| `test_update_stats_fail` | Stats increment fail_count |
| `test_suggest_retirement_high_error` | High error rate → suggested for retirement |
| `test_suggest_retirement_low_runs` | Below min_runs threshold → not suggested |
| `test_stats_avg_duration` | Average duration calculated correctly |

### Integration test

| Test | What it validates |
|------|------------------|
| `test_yaml_registry_with_engine` | Registry loads from YAML files, engine evaluates against them |

Uses `YamlFileRegistry` with `tmp_path`, real `SubprocessCommandRunner` with safe commands (`echo`, `true`, `false`).

---

## Phase 0 → Phase 1 Evolution

| Area | Phase 0 | Phase 1 |
|------|---------|---------|
| Mechanism | Deterministic only (shell commands) | + Agent checks (LLM evaluation) |
| Agent checks | Not implemented | `AgentCheckRunner` uses CC to evaluate against rule prompt |
| Registry | YAML files | YAML + optional SQLite for stats |
| Parallel execution | Sequential (one guardrail at a time) | `asyncio.gather` for independent guardrails |
| Ratchet counters | Manual threshold in command | Built-in ratchet type with stored baseline |
| Runtime guardrails | Command-level checking only | Intercept tool calls via CC hook |

The `Guardrail`, `GuardrailResult`, `GuardrailRegistry`, and `GuardrailEngine` interfaces stay the same — agent checks add a new code path inside `evaluate_single()` but don't change the contract.
