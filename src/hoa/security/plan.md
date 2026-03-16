# Least-Privilege Security — Design Plan

## Context

The security module is a standalone permission and sandboxing system. Given any agent execution — whether managed by HoA or invoked manually — it enforces permission boundaries, mediates privilege escalation, and provides container-based isolation. It has no dependency on the planner, guardrails, inspection, or retrospection modules.

**Phase 0 scope:** Permission manifests, manifest validation, permission subsetting (child ⊆ parent), and command allow-list checking. Container-based sandbox enforcement is Phase 1.

---

## Public Interface

The security module exposes three things to the rest of HoA: a `PermissionManifest` data model, a `PermissionEnforcer` that validates actions against a manifest, and a `SandboxFactory` that creates isolated execution environments.

### `PermissionManifest` — Data model (`permissions.py`)

```python
class FileAccess(BaseModel):
    path: str                    # glob pattern (e.g., "src/**/*.py")
    mode: Literal["read", "write", "read_write"]

class NetworkAccess(BaseModel):
    endpoint: str                # host or URL pattern
    methods: list[str]           # ["GET", "POST"] or ["*"]

class PermissionManifest(BaseModel):
    """Immutable permission boundary for a single agent."""
    file_access: list[FileAccess]
    command_allow_list: list[str]       # shell command prefixes (e.g., ["git", "python", "ruff"])
    network_access: list[NetworkAccess]
    tool_access: list[str]              # CC tool names (e.g., ["Read", "Write", "Bash"])
    max_cost_usd: float | None = None   # optional spending cap
    expires_at: datetime | None = None  # optional time-box

    def subset(self, child: "PermissionManifest") -> bool:
        """Return True if `child` is a valid subset of self (child ⊆ parent)."""

    def narrow(self, **restrictions) -> "PermissionManifest":
        """Return a new manifest that is this one with additional restrictions applied."""
```

**Design decisions:**
- Manifests are **immutable** Pydantic models. Narrowing returns a new instance.
- `subset()` is the core invariant — a parent can only delegate permissions it possesses.
- File access uses glob patterns matched with `fnmatch` for simplicity and auditability.
- Command allow-list matches prefixes: `"git"` allows `git status`, `git commit`, etc.

### `PermissionEnforcer` — Runtime validation (`permissions.py`)

```python
class PermissionEnforcer:
    """Validates individual actions against a manifest. Stateless."""

    def __init__(self, manifest: PermissionManifest): ...

    def check_file(self, path: str, mode: str) -> CheckResult: ...
    def check_command(self, command: str) -> CheckResult: ...
    def check_network(self, endpoint: str, method: str) -> CheckResult: ...
    def check_tool(self, tool_name: str) -> CheckResult: ...
    def check_cost(self, cost_usd: float) -> CheckResult: ...
    def check_expiry(self) -> CheckResult: ...

class CheckResult(BaseModel):
    allowed: bool
    reason: str                  # human-readable explanation of why allowed/denied
    manifest_rule: str | None    # which rule in the manifest matched (for logging)
```

**Design decisions:**
- The enforcer is **stateless** — it takes a manifest at construction and checks individual actions. No side effects, no logging (that's the inspection module's job).
- Every check returns a `CheckResult` with an explanation, not just a bool. This makes denials debuggable and loggable.
- The enforcer does not *intercept* actions. It is called by whatever system is mediating agent execution (the CC lifecycle hook in `core/`). Enforcement is the caller's responsibility.

### `SandboxFactory` — Isolated environments (`sandbox.py`)

```python
class SandboxConfig(BaseModel):
    manifest: PermissionManifest
    working_dir: str
    image: str = "hoa-sandbox:latest"
    memory_limit: str = "2g"
    cpu_limit: float = 1.0
    network_mode: str = "none"       # default: no network

class Sandbox(Protocol):
    """Abstract sandbox — could be a container, VM, or process jail."""
    async def start(self) -> None: ...
    async def exec(self, command: str) -> ExecResult: ...
    async def stop(self) -> None: ...
    @property
    def is_running(self) -> bool: ...

class SandboxFactory:
    """Creates sandboxes from configs. Phase 0: subprocess jail. Phase 1: Docker."""
    def create(self, config: SandboxConfig) -> Sandbox: ...
```

**Design decisions:**
- `Sandbox` is a **Protocol** (structural typing), not an ABC. This allows test doubles without inheritance.
- Phase 0 implementation is a subprocess-based jail (restricted `PATH`, `tempdir` working directory, no network). Phase 1 adds Docker container support.
- The factory is the only place that knows which implementation to use. Everything else depends on the `Sandbox` protocol.

### `EscalationRequest` — Privilege escalation (`escalation.py`)

```python
class EscalationRequest(BaseModel):
    requesting_agent_id: str
    permission_needed: str         # human-readable description
    reason: str                    # justification
    duration: Literal["task", "timed"] = "task"
    expires_after_seconds: int | None = None

class EscalationResult(BaseModel):
    granted: bool
    manifest_delta: PermissionManifest | None   # additional permissions if granted
    reason: str

class EscalationHandler(Protocol):
    """Decides whether to grant a privilege escalation."""
    async def handle(self, request: EscalationRequest, parent_manifest: PermissionManifest) -> EscalationResult: ...
```

**Design decisions:**
- The `EscalationHandler` is a **Protocol**. Phase 0: the human operator is prompted. Future: parent agents decide.
- `manifest_delta` is the *additional* permissions granted, not a replacement. The caller merges it with the existing manifest (and the merged result must still be ⊆ parent).

---

## Integration Points

| Consumer | What it uses | How |
|----------|-------------|-----|
| `core/lifecycle.py` | `PermissionManifest`, `PermissionEnforcer`, `SandboxFactory` | Creates enforcer from manifest, passes to sandbox, checks actions during agent execution |
| `inspection/logger.py` | `CheckResult` | Logs every permission check (allowed and denied) |
| `guardrails/engine.py` | `PermissionEnforcer.check_command()` | Runtime guardrails can delegate command-level checks to the security module |
| `comms/protocol.py` | `PermissionManifest.tool_access` | Communication scope checking *(future work)* |

**Integration is optional.** If no inspection module is present, `CheckResult` objects are returned but not logged. If no guardrail module is present, the enforcer still works — it just isn't called from guardrail evaluation. Each integration point is a function call, not a required dependency.

---

## Files to Create

| File | Purpose |
|------|---------|
| `src/hoa/security/__init__.py` | Package init — exports `PermissionManifest`, `PermissionEnforcer`, `SandboxFactory` |
| `src/hoa/security/permissions.py` | `PermissionManifest`, `FileAccess`, `NetworkAccess`, `PermissionEnforcer`, `CheckResult` |
| `src/hoa/security/sandbox.py` | `Sandbox` protocol, `SandboxConfig`, `SandboxFactory`, subprocess-based Phase 0 impl |
| `src/hoa/security/escalation.py` | `EscalationRequest`, `EscalationResult`, `EscalationHandler` protocol |
| `tests/unit/test_permissions.py` | Permission manifest tests |
| `tests/unit/test_sandbox.py` | Sandbox lifecycle tests |
| `tests/unit/test_escalation.py` | Escalation request handling tests |

---

## Test Strategy

### Unit tests (no external dependencies, no Docker, no filesystem side effects)

**`test_permissions.py`** — PermissionManifest and PermissionEnforcer:

| Test | What it validates |
|------|------------------|
| `test_subset_identical` | A manifest is a subset of itself |
| `test_subset_narrower_file_access` | Fewer paths ⊆ more paths |
| `test_subset_fails_wider_file_access` | Adding a path not in parent → False |
| `test_subset_mode_narrowing` | `read` ⊆ `read_write`, but `write` ⊄ `read` |
| `test_subset_command_allow_list` | Subset of commands ⊆ superset |
| `test_subset_empty_is_subset_of_anything` | Empty manifest ⊆ any manifest |
| `test_narrow_removes_paths` | `narrow(file_access=[...])` produces valid subset |
| `test_narrow_preserves_immutability` | Original manifest is not mutated |
| `test_check_file_allowed` | Glob match → allowed with reason |
| `test_check_file_denied` | No glob match → denied with reason |
| `test_check_command_prefix_match` | `"git status"` matches allow-list `"git"` |
| `test_check_command_no_match` | `"rm -rf"` denied when not in allow-list |
| `test_check_cost_under_limit` | Below `max_cost_usd` → allowed |
| `test_check_cost_over_limit` | Above `max_cost_usd` → denied |
| `test_check_expiry_not_expired` | Before `expires_at` → allowed |
| `test_check_expiry_expired` | After `expires_at` → denied |
| `test_manifest_roundtrip_json` | `model_dump_json()` → `model_validate_json()` is lossless |

**`test_sandbox.py`** — Sandbox protocol and factory:

| Test | What it validates |
|------|------------------|
| `test_sandbox_protocol_compliance` | Phase 0 impl satisfies `Sandbox` protocol (structural check) |
| `test_create_sandbox_from_config` | Factory returns a `Sandbox` from a `SandboxConfig` |
| `test_sandbox_lifecycle` | `start()` → `is_running` → `exec()` → `stop()` → not running |
| `test_sandbox_exec_returns_result` | `exec("echo hello")` returns stdout |
| `test_sandbox_exec_respects_command_allow_list` | Command not in allow-list → error |
| `test_sandbox_working_dir_isolation` | Sandbox can't access paths outside its working dir |

**`test_escalation.py`** — Escalation request handling:

| Test | What it validates |
|------|------------------|
| `test_escalation_request_roundtrip` | Serialization/deserialization |
| `test_grant_produces_valid_manifest_delta` | Granted delta ⊆ parent manifest |
| `test_grant_merge_respects_parent_boundary` | Merged manifest ⊆ parent |
| `test_deny_returns_reason` | Denied result includes explanation |
| `test_handler_protocol_with_mock` | A mock handler satisfies the protocol |

### Property-based tests (with Hypothesis)

| Property | What it validates |
|----------|------------------|
| `test_subset_is_reflexive` | ∀ m: m.subset(m) is True |
| `test_subset_is_transitive` | If a ⊆ b and b ⊆ c, then a ⊆ c |
| `test_narrow_always_produces_subset` | ∀ m, restrictions: m.narrow(**r).subset(m) is True |
| `test_empty_manifest_subset_of_any` | ∀ m: empty.subset(m) is True |

---

## Phase 0 → Phase 1 Evolution

| Area | Phase 0 | Phase 1 |
|------|---------|---------|
| Sandbox implementation | Subprocess jail (`subprocess.Popen` with restricted env) | Docker containers via `docker` SDK |
| Network isolation | `network_mode="none"` (no enforcement beyond convention) | Docker network policies |
| File isolation | `tempdir` working directory, path checks in enforcer | Docker volume mounts with read-only flags |
| Escalation handler | Human operator prompted via CLI | Parent agent decides via structured protocol |
| Manifest storage | In-memory, passed as function args | Persisted in `.hoa/state.db` alongside tasks |

The `PermissionManifest`, `PermissionEnforcer`, and `Sandbox` protocol stay the same — only implementations change.
