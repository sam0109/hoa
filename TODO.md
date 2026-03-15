# HoA Development Roadmap

## Phase 0: Foundation

The absolute minimum to bootstrap a target repo, spawn agents in it, and observe what happens.

- [ ] **Project scaffolding**
  - [ ] Initialize Python project with pyproject.toml (Python 3.11+), managed by uv
  - [ ] Set up Ruff for linting/formatting and pre-commit hooks
  - [ ] Set up pytest for unit and integration tests
  - [ ] Set up Click or Typer for CLI framework
  - [ ] Establish directory structure per README (`src/hoa/` layout)

- [ ] **`hoa init` — Target repo bootstrap**
  - [ ] Interactive prompts: project name, description, language/stack, GitHub org, visibility (public/private)
  - [ ] Create GitHub repo via `gh repo create`
  - [ ] Run setup-github.sh against the new repo (labels, branch protection, templates, repo settings)
  - [ ] Generate and commit AGENTS.md from template (Jinja2) — agent workflow customized to the project's stack
  - [ ] Generate and commit CLAUDE.md from template — Claude Code instructions with project-specific rules
  - [ ] Generate and commit CI pipeline from template — language-appropriate linting, testing, type checking
  - [ ] Generate and commit sandbox Dockerfile from template — agent execution environment with required tooling
  - [ ] Generate and commit docker-compose.yml from template — container orchestration for agent instances
  - [ ] Store project config in HoA's local state (repo URL, stack, guardrails applied, run history)

- [ ] **Inspection layer (core)**
  - [ ] Define structured log schema (JSON) — must capture: agent ID, tier, target repo, timestamp, event type, full payload
  - [ ] Implement file-based structured logger (write logs to `~/.hoa/logs/<project>/`)
  - [ ] Log rotation and retention policy
  - [ ] Implement basic trace viewer CLI (`hoa inspect --repo <repo> <run-id>`)
  - [ ] Ensure every subsequent component logs through this layer from day one

- [ ] **Agent lifecycle (minimal)**
  - [ ] Implement `spawn` — launch a Claude Code instance in a sandbox container against the target repo
  - [ ] Implement `monitor` — poll/stream agent status
  - [ ] Implement `terminate` — graceful and forceful shutdown
  - [ ] Hook into CC to capture full input/output/tool-call telemetry
  - [ ] Define agent state machine: `spawning → planning → awaiting_approval → running → completing → retrospecting → done | failed`

- [ ] **Plan-as-DAG system**
  - [ ] Define plan schema — DAG of subtasks with: description, verification criteria, dependencies (edges), and self-execute vs. delegate decision
  - [ ] DAG validation — reject cycles, ensure all dependencies reference valid subtask IDs
  - [ ] DAG scheduler — topological sort, identify parallelizable subtasks, track completion
  - [ ] Plan approval protocol — agent submits plan to parent, parent approves/rejects/requests changes, iterate until accepted
  - [ ] Hook plan approval into CC's `AskUserQuestion`-style interaction (parent receives plan as structured choices)

- [ ] **Inter-agent communication (minimal)**
  - [ ] Define message protocol (JSON schema): direction messages, status reports, escalation requests
  - [ ] Escalation messages must include: what was attempted, what failed, blocker analysis, and **suggested next steps as selectable options**
  - [ ] Implement CLI tool: `hoa-msg send <target> <message>` — used by agents to communicate
  - [ ] Implement CLI tool: `hoa-msg recv` — agent polls for incoming messages
  - [ ] All messages logged to inspection layer with sender, receiver, timestamp, payload

- [ ] **`hoa run` — Basic orchestration (adaptive-depth proof of concept)**
  - [ ] Accept a task description and target repo
  - [ ] Tier 0 agent receives task, creates plan DAG, submits for human approval
  - [ ] Agent decides per-subtask: self-execute or delegate to sub-agent
  - [ ] Sub-agents clone target repo into sandbox containers, work on feature branches
  - [ ] Sub-agents report completion or escalate with options back to parent
  - [ ] Parent selects from escalation options or provides free-form direction
  - [ ] End-to-end test: `hoa init` a demo project, then `hoa run` a task that requires 2 levels in one branch and 1 level in another

- [ ] **Demo project 1**
  - [ ] Pick a simple project (e.g., CLI tool, REST API, static site generator)
  - [ ] Run `hoa init` + `hoa run` end to end
  - [ ] Document what fails, what succeeds, what's painful
  - [ ] Feed lessons back into HoA (new guardrails, improved templates, better prompts)

## Phase 1: Guardrails & Retrospection

Add the feedback loop that makes the system learn from mistakes.

- [ ] **Guardrail engine**
  - [ ] Define guardrail schema (YAML): mechanism (deterministic or agent_check), phase (pre/runtime/post), trigger condition, enforcement action, scope, metadata
  - [ ] Implement guardrail registry — CRUD for guardrail definitions, stored in `./guardrails/`
  - [ ] Implement deterministic guardrails — run shell commands/scripts that return pass/fail (linters, test suites, validators, ratchet counters)
  - [ ] Implement agent-check guardrails — present structured output + rule to an evaluator LLM, get pass/warn/fail with reasoning
  - [ ] Wire both mechanisms into pre-execution, runtime, and post-execution phases
  - [ ] Guardrail trigger logging — every trigger (pass, warn, block) logged to inspection layer, including evaluator reasoning for agent checks
  - [ ] CLI: `hoa guardrail add`, `hoa guardrail list`, `hoa guardrail disable`
  - [ ] Track agent-check agreement rate — flag guardrails where the evaluator is inconsistent

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
  - [ ] Define escalation protocol: what was attempted, what failed, blocker analysis, and **suggested next steps as selectable options**
  - [ ] Implement escalation routing — issues flow to parent as structured choices (AskUserQuestion pattern)
  - [ ] Parent can select a suggested option or provide free-form direction
  - [ ] Implement escalation summarization — each tier condenses and re-frames options before passing up
  - [ ] Tier 0 escalation surfaces to human operator (CLI prompt or webhook) with the same option-selection UX
  - [ ] Escalation timeout — if a tier doesn't respond within a threshold, auto-escalate
  - [ ] All escalations logged with full chain in inspection layer (including which option was selected at each tier)

- [ ] **Adaptive-depth hierarchy**
  - [ ] Agents at any tier can decide to self-execute or delegate — no fixed depth
  - [ ] Plan approval loop — agent submits DAG plan to parent, iterates until accepted
  - [ ] Uneven trees — different branches can have different depths based on subtask complexity
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
  - [ ] `hoa init` — create and configure a new target repo (interactive)
  - [ ] `hoa run --repo <repo> <task>` — start a hierarchy against a target repo
  - [ ] `hoa status --repo <repo>` — overview of active hierarchies on a target repo
  - [ ] `hoa pause <agent-id>` — pause an agent (hold messages, freeze execution)
  - [ ] `hoa resume <agent-id>` — resume a paused agent
  - [ ] `hoa kill <agent-id>` — terminate an agent and optionally its subtree
  - [ ] `hoa replay --repo <repo> <run-id>` — re-run a completed task with current guardrails
  - [ ] `hoa projects` — list all target repos managed by HoA
  - [ ] Configuration management — per-project configs, secrets handling

## Phase 5: Advanced Patterns

Higher-order orchestration strategies built on the core primitives.

- [ ] **Parallel execution strategies**
  - [ ] DAG-driven parallelism — independent subtasks in a plan DAG execute concurrently (this is the default, built into Phase 0)
  - [ ] Fan-out/fan-in — Tier N spawns multiple sub-agents in parallel, merges results
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

- [ ] **Cross-project learning**
  - [ ] Shared guardrail library across projects (promoted from project-specific to global)
  - [ ] Cross-project retrospective analysis — patterns that span multiple demo projects
  - [ ] Template evolution — improve AGENTS.md, CI, Dockerfile templates based on demo project outcomes
