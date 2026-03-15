# HoA Development Roadmap

## Phase 0: Foundation

The absolute minimum to run a two-tier hierarchy with logging.

- [ ] **Project scaffolding**
  - [ ] Initialize Python project with pyproject.toml (Python 3.11+), managed by uv
  - [ ] Set up Ruff for linting/formatting and pre-commit hooks
  - [ ] Set up pytest for unit and integration tests
  - [ ] Set up Click or Typer for CLI framework
  - [ ] Establish directory structure per README (`src/hoa/` layout)

- [ ] **Inspection layer (core)**
  - [ ] Define structured log schema (JSON) — must capture: agent ID, tier, timestamp, event type, full payload
  - [ ] Implement file-based structured logger (write logs to `./hoa-logs/`)
  - [ ] Log rotation and retention policy
  - [ ] Implement basic trace viewer CLI (`hoa inspect <run-id>`)
  - [ ] Ensure every subsequent component logs through this layer from day one

- [ ] **Agent lifecycle (minimal)**
  - [ ] Implement `spawn` — launch a Claude Code instance with a task prompt and permissions manifest
  - [ ] Implement `monitor` — poll/stream agent status
  - [ ] Implement `terminate` — graceful and forceful shutdown
  - [ ] Hook into CC to capture full input/output/tool-call telemetry
  - [ ] Define agent state machine: `spawning → running → completing → retrospecting → done | failed`

- [ ] **Inter-agent communication (minimal)**
  - [ ] Define message protocol (JSON schema): direction messages, status reports, escalation requests
  - [ ] Implement CLI tool: `hoa-msg send <target> <message>` — used by agents to communicate
  - [ ] Implement CLI tool: `hoa-msg recv` — agent polls for incoming messages
  - [ ] All messages logged to inspection layer with sender, receiver, timestamp, payload

- [ ] **Basic hierarchy (two-tier proof of concept)**
  - [ ] Tier 0 agent spawns Tier 1 agents with task specifications
  - [ ] Tier 1 agents report completion or failure back to Tier 0
  - [ ] Tier 0 agent can react to Tier 1 failures (retry, reassign, or fail the run)
  - [ ] End-to-end test: Tier 0 decomposes a simple coding task, Tier 1 agents execute, results are merged

## Phase 1: Guardrails & Retrospection

Add the feedback loop that makes the system learn from mistakes.

- [ ] **Guardrail engine**
  - [ ] Define guardrail schema (YAML): trigger condition, enforcement action, scope, metadata
  - [ ] Implement guardrail registry — CRUD for guardrail definitions, stored in `./guardrails/`
  - [ ] Implement pre-execution guardrails — injected into agent system prompts before task starts
  - [ ] Implement runtime guardrails — intercept tool calls and validate against rules
  - [ ] Implement post-execution guardrails — validate agent output against acceptance criteria
  - [ ] Guardrail trigger logging — every trigger (pass, warn, block) logged to inspection layer
  - [ ] CLI: `hoa guardrail add`, `hoa guardrail list`, `hoa guardrail disable`

- [ ] **Retrospection system**
  - [ ] Define retrospective schema: what went well, what went poorly, time/cost, suggestions
  - [ ] Inject retrospection prompt into agent lifecycle — runs automatically after task completion
  - [ ] Collect retrospectives and store in inspection layer
  - [ ] Implement upward flow — retrospectives summarized and sent to parent tier
  - [ ] Pattern detection — flag recurring issues across multiple retrospectives
  - [ ] CLI: `hoa retro <run-id>` — view retrospectives for a run
  - [ ] CLI: `hoa retro patterns` — view detected patterns across runs

- [ ] **Guardrail-from-retro pipeline**
  - [ ] When a pattern is detected, suggest a guardrail to the operator
  - [ ] Operator approves/edits/rejects the suggestion
  - [ ] Approved guardrails are automatically scoped and activated

## Phase 2: Escalation & Deep Hierarchies

Extend from two tiers to N tiers with proper escalation.

- [ ] **Issue escalation**
  - [ ] Define escalation protocol: what was attempted, what failed, proposed blocker
  - [ ] Implement escalation routing — issues flow to parent, parent resolves or re-escalates
  - [ ] Implement escalation summarization — each tier condenses the escalation before passing up
  - [ ] Tier 0 escalation surfaces to human operator (CLI prompt or webhook)
  - [ ] Escalation timeout — if a tier doesn't respond within a threshold, auto-escalate
  - [ ] All escalations logged with full chain in inspection layer

- [ ] **N-tier hierarchy support**
  - [ ] Generalize hierarchy management — arbitrary depth, configurable topology
  - [ ] Task decomposition at each tier — parent breaks work into subtasks for children
  - [ ] Status aggregation — each tier rolls up status from below into a summary for above
  - [ ] Subtree management — spawn, monitor, and tear down entire branches

- [ ] **Privilege escalation**
  - [ ] Define privilege escalation request format: what permission, why, for how long
  - [ ] Implement request routing — flows up until an agent with the permission is found
  - [ ] Implement grant/deny with justification logging
  - [ ] Time-boxed and task-scoped grants — permissions expire automatically
  - [ ] All privilege changes logged to inspection layer

## Phase 3: Security Hardening

Lock down the sandbox model and permission enforcement.

- [ ] **Permission model**
  - [ ] Define permissions manifest schema: filesystem paths (r/w), shell allow-list, network endpoints, tool access, comms scope
  - [ ] Manifest validation — reject manifests that grant more than the parent possesses
  - [ ] Manifest templates — reusable permission profiles for common roles
  - [ ] CLI: `hoa perms show <agent-id>`, `hoa perms diff <a> <b>`

- [ ] **Sandbox enforcement**
  - [ ] Filesystem isolation — agents can only access paths in their manifest
  - [ ] Shell command filtering — only allow-listed commands execute
  - [ ] Network policy enforcement — block unauthorized outbound requests
  - [ ] Tool access control — restrict which CC tools are available per agent
  - [ ] Sandbox violation logging and alerting

- [ ] **Inter-agent communication security**
  - [ ] Agents can only message agents in their direct lineage (parent, children)
  - [ ] Message authentication — verify sender identity
  - [ ] Message size limits — prevent context-bombing attacks
  - [ ] Rate limiting on escalation requests

## Phase 4: Observability & Tooling

Make the system pleasant to operate and debug.

- [ ] **Dashboard**
  - [ ] Real-time hierarchy visualization — show all agents, their states, and communication
  - [ ] Live log streaming — filter by agent, tier, event type
  - [ ] Cost tracking — token usage and estimated cost per agent, per tier, per run
  - [ ] Guardrail effectiveness dashboard — trigger rates, false positives, coverage

- [ ] **Trace viewer**
  - [ ] Full trace replay — step through an agent's execution with all context
  - [ ] Cross-agent trace correlation — follow a task from Tier 0 through all sub-agents
  - [ ] Diff view — compare two runs of the same task to identify regressions
  - [ ] Export traces for external analysis

- [ ] **Operational tooling**
  - [ ] `hoa run <task>` — start a new hierarchy from a task description
  - [ ] `hoa status` — overview of all active hierarchies
  - [ ] `hoa pause <agent-id>` — pause an agent (hold messages, freeze execution)
  - [ ] `hoa resume <agent-id>` — resume a paused agent
  - [ ] `hoa kill <agent-id>` — terminate an agent and optionally its subtree
  - [ ] `hoa replay <run-id>` — re-run a completed task with current guardrails
  - [ ] Configuration management — environment-specific configs, secrets handling

## Phase 5: Advanced Patterns

Higher-order orchestration strategies built on the core primitives.

- [ ] **Parallel execution strategies**
  - [ ] Fan-out/fan-in — Tier N spawns multiple Tier N+1 agents in parallel, merges results
  - [ ] Competitive execution — multiple agents attempt the same task, best result wins
  - [ ] Pipeline execution — agents in sequence, output of one feeds into the next

- [ ] **Self-healing**
  - [ ] Automatic retry with adjusted parameters on failure
  - [ ] Automatic guardrail generation from repeated failures (without human approval for low-risk rules)
  - [ ] Dead agent detection and subtree recovery

- [ ] **Context management**
  - [ ] Smart context windowing — agents receive only the context relevant to their task
  - [ ] Context inheritance — child agents receive parent's relevant context automatically
  - [ ] Context summarization — long-running tasks get periodic context compression

- [ ] **Multi-project support**
  - [ ] Run multiple independent hierarchies simultaneously
  - [ ] Shared guardrail library across projects
  - [ ] Cross-project retrospective analysis
