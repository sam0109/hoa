# HoA: Hierarchy of Agents

A framework for orchestrating large numbers of AI agents to build software — with Claude Code as the execution primitive.

HoA is an **orchestrator**, not a project template. It lives in its own repository and creates, configures, and manages agents that work in a **separate target repository**. All orchestration logic, guardrails, inspection tooling, and agent coordination live here in HoA. All project-specific code, tests, and CI live in the target repo.

## How It Works

```
┌─────────────────────────────────────────────────────────────────┐
│  HoA Repository (this repo)                                     │
│                                                                  │
│  • CLI: `hoa init`, `hoa run`, `hoa inspect`, `hoa guardrail`  │
│  • Orchestration engine (spawn, plan, schedule, escalate)       │
│  • Inspection layer (logs, traces, dashboards)                  │
│  • Guardrail engine (deterministic + agent checks)              │
│  • Retrospection system                                         │
│  • Project templates (AGENTS.md, Dockerfile, CI, etc.)          │
│  • Lessons learned across all projects                          │
└──────────────────────────┬──────────────────────────────────────┘
                           │
                           │  `hoa init` creates & configures
                           │  `hoa run`  orchestrates agents in
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│  Target Repository (created per project)                         │
│                                                                  │
│  • Project source code (whatever the agents are building)       │
│  • AGENTS.md (generated — agent workflow for this project)      │
│  • CI pipeline (generated — deterministic guardrails as checks) │
│  • Sandbox Dockerfile (generated — agent execution environment) │
│  • .github/ (labels, templates, branch protection — generated)  │
│  • Project-specific guardrails and configuration                │
└─────────────────────────────────────────────────────────────────┘
```

### Workflow

1. **`hoa init`** — Interactive setup. Prompts for project name, description, language/stack, and initial task. Creates a new GitHub repo, configures it with best-practice defaults (branch protection, labels, templates, CI skeleton, AGENTS.md, sandbox Dockerfile), and commits the scaffolding.

2. **`hoa run <task>`** — Kicks off a hierarchy. Tier 0 receives the task, plans a DAG, and orchestrates agents in the target repo. Agents clone the target repo into sandboxed containers, do their work on feature branches, open PRs, get reviewed, and merge — all within the target repo. HoA observes and coordinates from outside.

3. **Iterate** — When things fail (and they will), retrospectives surface what went wrong. New guardrails are added to HoA (if they're general) or to the target repo (if they're project-specific). Run `hoa run` again with the next task. The system gets smarter with each iteration.

### What lives where

| Concern | HoA repo | Target repo |
|---------|----------|-------------|
| Orchestration engine | ✓ | |
| Agent lifecycle management | ✓ | |
| Inspection / logging / traces | ✓ | |
| Guardrail engine + agent checks | ✓ | |
| Retrospection + pattern detection | ✓ | |
| CLI (`hoa init`, `hoa run`, etc.) | ✓ | |
| Project templates (AGENTS.md, etc.) | ✓ (templates) | ✓ (generated instances) |
| General lessons / best practices | ✓ | |
| Project source code | | ✓ |
| Project CI (deterministic checks) | | ✓ |
| Project-specific guardrails | | ✓ |
| Branch protection / labels / templates | | ✓ (configured by `hoa init`) |

## Development Approach

HoA is developed iteratively through **demo projects**. Each demo is a real (if small) software project built entirely by HoA-orchestrated agents. The purpose is to find where the system breaks, fix it, and try again:

1. Build HoA to the point where it can attempt a simple project.
2. Run `hoa init` + `hoa run` on a demo project.
3. Observe what fails — inspect logs, read retrospectives, identify patterns.
4. Improve HoA (better guardrails, better escalation, better plans).
5. Run a new demo project and see if the failure modes are gone.
6. Repeat.

## Core Principles

### 1. Deep Inspectability

Every agent interaction is logged with full fidelity. This is non-negotiable — when something goes wrong (and it will), you need to reconstruct exactly what happened.

**What gets logged:**
- Complete input context provided to each agent
- Full output and reasoning from each agent
- Every tool call made, with arguments and results
- All inter-agent messages (directions down, issues up)
- Errors, retries, and failure modes
- Token usage, timing, and cost data
- Guardrail triggers and enforcement actions

**How it's exposed:**
- Real-time streaming dashboard for active hierarchies
- Post-hoc trace viewer for completed runs (think: distributed tracing, but for agents)
- Structured log format (JSON) for programmatic analysis
- Diff view for comparing runs to identify regressions

### 2. Claude Code as the Primitive

HoA does not reinvent agent execution. Every agent in the hierarchy is a Claude Code instance. HoA adds the orchestration, logging, and coordination layers on top.

**What this means:**
- Agents inherit Claude Code's tool ecosystem (file I/O, shell, search, etc.)
- HoA hooks into CC's lifecycle to capture telemetry without modifying CC itself
- Agent capabilities are configured through CC's existing permission model
- Developers familiar with Claude Code can reason about agent behavior at any tier

**What HoA adds:**
- CLI tools for inter-agent communication (direction, escalation, status reporting)
- Lifecycle management (spawn, monitor, terminate agent subtrees)
- Context injection (guardrails, task specs, permissions manifests)
- Hooks for inspection and guardrail enforcement

### 3. Guardrails as a Learning System

When a failure mode is identified — whether by a human operator, a retrospective, or an automated check — a guardrail is created to prevent recurrence. Guardrails are not suggestions; they are enforced constraints validated against agent behavior.

**Guardrail mechanisms (how they run):**

Guardrails come in two fundamentally different flavors, and the system must support both:

- **Deterministic checks**: Hard, fast, automated — no LLM in the loop. These are programs that run against agent output and return pass/fail. Examples: linters, type checkers, unit test suites, config validators, file permission checks, regex pattern matches, ratchet counters (e.g., "passing test count must not decrease"). Deterministic checks are cheap, reliable, and should be preferred whenever possible. Think CI pipeline.
- **Agent checks**: An LLM evaluates structured output against a rule expressed in natural language. The agent's work product is presented to a separate evaluator agent along with the rule, and the evaluator returns a judgment (pass/warn/fail) with reasoning. Examples: "Does this code change maintain backward compatibility?", "Is the error message user-friendly?", "Does the API design follow RESTful conventions?" Agent checks are more expensive and less reliable than deterministic checks, but they can evaluate properties that are impossible to express as code.

Both mechanisms can be applied at any phase:

**Guardrail phases (when they run):**
- **Pre-execution**: Applied before the agent acts. Deterministic: validate the task spec is well-formed, check that required context files exist. Agent: review the task spec for ambiguity or scope creep.
- **Runtime**: Applied as the agent works. Deterministic: intercept shell commands against an allow-list, enforce file path restrictions. Agent: review intermediate output for quality drift.
- **Post-execution**: Applied after the agent reports completion. Deterministic: run the test suite, lint the output, check coverage thresholds, validate config files with parsers. Agent: review the final diff for correctness, style, and architectural conformance.

**Guardrail lifecycle:**
1. A failure or bad pattern is identified (via retrospective, human review, or automated detection).
2. A guardrail is authored — either as a deterministic script/command or as a natural-language rule for agent evaluation.
3. The guardrail is scoped — applied globally, to a specific tier, to a role, or to individual agents.
4. The guardrail is activated — deterministic checks are added to the agent's CI-like pipeline; agent checks are added to the evaluator's prompt.
5. The guardrail is monitored — trigger frequency, false-positive rate, and (for agent checks) evaluator agreement rate are tracked.
6. The guardrail is refined — adjusted or retired based on effectiveness data. When possible, agent checks that prove stable should be converted into deterministic checks for reliability and cost.

### 4. Issues Flow Up, Direction Flows Down

The hierarchy is not just an org chart — it defines strict communication channels.

**Direction (downward):**
- Tier 0 (the top) holds the full project context and creates the high-level plan.
- Tier 0 decomposes work into tasks and assigns them to Tier 1 agents.
- Each tier further decomposes and delegates to the tier below (see Adaptive Depth below).
- Direction includes: task specification, success criteria, relevant guardrails, and a permissions manifest.

**Issues (upward):**
- When an agent encounters a problem it cannot resolve at its tier, it escalates.
- Escalations are structured and **actionable**: what was attempted, what failed, what the agent thinks the blocker is, and **concrete suggestions for next steps** — including alternative approaches the agent considered but couldn't pursue without guidance.
- Escalations are presented to the tier above as a **choice** — using the same pattern as Claude Code's `AskUserQuestion` tool. The parent agent receives the issue along with a set of proposed options (e.g., "A: Retry with adjusted parameters, B: Restructure the approach to avoid X, C: Escalate further — I need more context about Y"). The parent can pick an option or provide free-form direction.
- This means the tier above is never handed a bare problem and expected to invent a solution from scratch — the escalating agent has already done the analysis and framed the decision. The parent's job is to **steer**, not to **solve**.
- If the parent can't resolve it, it re-summarizes and re-escalates with its own option set — each tier adds its perspective but keeps the message concise.
- Escalations propagate upward until they reach a tier with sufficient context/authority to resolve them.

**Status reporting:**
- Agents report progress on a configurable cadence.
- Status flows upward and is aggregated — Tier 0 sees a project-level dashboard, not per-file diffs.

### 5. Mandatory Retrospection

Every agent, at every tier, must reflect after completing a unit of work. This is not optional, and it is not an afterthought — it is a first-class primitive built into the task lifecycle.

**What a retrospective includes:**
- **What went well**: Patterns and approaches that worked. These feed into best-practice guardrails.
- **What went poorly**: Failures, dead ends, unexpected difficulties. These feed into preventive guardrails.
- **Time and cost analysis**: Was the work efficient? Could the decomposition have been better?
- **Suggestions**: Concrete recommendations for improving the process, tooling, or guardrails.

**How retrospectives are used:**
- Retrospectives are attached to the task record in the inspection layer.
- They flow upward like any other issue — the tier above reviews them.
- Patterns across retrospectives are surfaced: if 5 different agents report the same friction point, that's a systemic issue.
- Tier 0 (or the human operator) reviews aggregated retrospective data and decides which warrant new guardrails, process changes, or architectural adjustments.

### 6. Least-Privilege Security

Agents operate in sandboxes with the minimum permissions necessary. The permission model is hierarchical and strictly non-escalating.

**Permission model:**
- Each agent receives a permissions manifest from its parent at spawn time.
- The manifest specifies: file system access (paths and read/write), shell command allow-list, network access (endpoints and methods), tool access (which CC tools are available), and inter-agent communication scope.
- **An agent can only grant permissions it possesses.** Permissions get strictly tighter as you go down the hierarchy.
- Tier 0 starts with the full permission set defined by the human operator. Each delegation narrows the scope.

**Privilege escalation:**
- If an agent needs a permission it doesn't have, it issues a privilege escalation request to its parent.
- The request includes: what permission is needed, why, and for how long.
- The parent either grants it (if it has the permission and the justification is sound) or escalates further.
- Escalation propagates upward until it reaches an agent (or the human operator) that can grant it.
- All escalation requests are logged in the inspection layer.
- Grants can be time-boxed or task-scoped — they don't persist beyond their justification.

**Sandbox enforcement:**
- Agents run in isolated environments (containers, VMs, or sandboxed CC instances).
- File system isolation prevents agents from accessing each other's workspaces unless explicitly permitted.
- Network policies prevent unauthorized external access.
- Inter-agent communication is mediated through CLI tools that enforce the permission model and log all messages.

## Architecture Overview

### Adaptive Depth

The hierarchy is **not** a fixed N-tier structure. Depth is determined dynamically by task complexity.

When an agent receives a task, it follows this procedure:

1. **Plan**: Decompose the task into subtasks. The plan is a **DAG** (directed acyclic graph) — subtasks declare their dependencies so they can be executed in the correct order, with independent subtasks running in parallel.
2. **Decide depth**: For each subtask, the agent explicitly decides: "Can I do this myself, or does this need a sub-agent?" Simple subtasks (small bug fixes, single-file edits, running a command) are executed directly. Complex subtasks (multi-file features, design decisions, anything requiring further decomposition) are delegated to a new sub-agent.
3. **Submit plan for approval**: The plan (with the self-execute vs. delegate decision for each subtask) is sent to the tier above for review. The parent can approve, request changes, or restructure the plan. This is an iterative loop — the agent revises until the plan is accepted.
4. **Execute**: Once approved, the agent executes self-assigned subtasks and spawns sub-agents for delegated ones, respecting the DAG's dependency order.

This means:
- A trivial task might be: Human → Tier 0 → Tier 1 (executes directly). Two levels total.
- A complex task might be: Human → Tier 0 → Tier 1 → Tier 2 → Tier 3. Four levels, and only in the branches that need it.
- The tree is **uneven** — one branch might go 3 levels deep while a sibling branch is handled directly by Tier 1.
- Every plan at every level is a DAG, so HoA can schedule independent subtasks in parallel and enforce that dependencies are completed before dependents start.

```
                    ┌─────────────────┐
                    │  Human Operator  │
                    └────────┬────────┘
                             │ task + approval
                             ▼
                    ┌─────────────────┐
                    │    Tier 0       │
                    │  (Coordinator)  │  Plans a DAG, submits to human
                    └───┬────────┬────┘
                        │        │
              delegates │        │ delegates
                        ▼        ▼
                ┌──────────┐  ┌──────────┐
                │  Tier 1  │  │  Tier 1  │  Each plans a DAG,
                │ (Lead A) │  │ (Lead B) │  submits to Tier 0
                └──┬───┬───┘  └────┬─────┘
                   │   │           │
             T1-A  │   │ delegates │ executes directly
          executes │   ▼           │ (simple subtask)
          directly │ ┌────┐        │
          (simple) │ │ T2 │        │
                   │ └─┬──┘        │
                   │   │ executes  │
                   │   │ directly  │
                   │   │           │
                   ▼   ▼           ▼

    Depth varies per branch — driven by task complexity

         ─── Direction flows DOWN ───▶
         ◀─── Issues flow UP ────────

    ┌──────────────────────────────────────┐
    │          Inspection Layer             │
    │  (logs, traces, guardrails, retros)  │
    │  Captures EVERYTHING, queryable      │
    └──────────────────────────────────────┘
```

### Plan DAG Example

```
  Tier 1 agent receives: "Add user authentication to the API"

  Plan submitted to Tier 0 for approval:

  ┌─────────────────────┐
  │ A: Design auth schema│  (self — research + design doc)
  └──────────┬──────────┘
             │
     ┌───────┴────────┐
     ▼                ▼
  ┌──────────┐  ┌──────────────┐
  │B: JWT    │  │C: Password   │  (delegate — both are complex,
  │  middleware│  │  hashing     │   run in parallel, no dependency
  └────┬─────┘  └──────┬───────┘   between them)
       │               │
       └───────┬───────┘
               ▼
        ┌────────────┐
        │D: Integration│  (self — wiring, needs B and C done)
        │   tests      │
        └──────────────┘

  Tier 0 reviews: "Looks good, but add a subtask for rate limiting
  between C and D." Agent revises, resubmits, gets approval.
```

## Project Structure

```
hoa/                           # This repo — the orchestrator
├── README.md
├── TODO.md
├── LESSONS.md                 # Best practices from prior experiments
├── pyproject.toml
├── uv.lock
├── src/
│   └── hoa/
│       ├── __init__.py
│       ├── core/              # Core orchestration engine
│       │   ├── __init__.py
│       │   ├── hierarchy.py   # Hierarchy management (spawn, teardown, topology)
│       │   ├── planner.py     # Plan creation, DAG construction, dependency resolution
│       │   ├── scheduler.py   # Task scheduling respecting DAG order + parallelism
│       │   └── lifecycle.py   # Agent lifecycle (init, plan, approve, run, retro, terminate)
│       ├── comms/             # Inter-agent communication
│       │   ├── __init__.py
│       │   ├── channels.py    # Message channels (direction down, issues up)
│       │   ├── escalation.py  # Issue and privilege escalation logic
│       │   └── protocol.py    # Message format and validation
│       ├── inspection/        # Inspection and logging layer
│       │   ├── __init__.py
│       │   ├── logger.py      # Structured logging (all agent I/O)
│       │   ├── tracer.py      # Distributed tracing across the hierarchy
│       │   ├── dashboard.py   # Real-time monitoring interface
│       │   └── replay.py      # Post-hoc trace replay and analysis
│       ├── guardrails/        # Guardrail system
│       │   ├── __init__.py
│       │   ├── engine.py      # Guardrail evaluation engine (dispatches to deterministic or agent)
│       │   ├── deterministic.py # Deterministic checks (lint, test, validate, ratchet)
│       │   ├── agent_check.py # Agent-based evaluation (LLM judges output against a rule)
│       │   ├── registry.py    # Guardrail storage and retrieval
│       │   ├── types.py       # Guardrail definitions (mechanism × phase matrix)
│       │   └── lifecycle.py   # Guardrail creation, scoping, monitoring
│       ├── security/          # Permission and sandbox management
│       │   ├── __init__.py
│       │   ├── permissions.py # Permission model and manifest handling
│       │   ├── sandbox.py     # Sandbox creation and enforcement
│       │   └── escalation.py  # Privilege escalation request handling
│       ├── retro/             # Retrospection system
│       │   ├── __init__.py
│       │   ├── collector.py   # Retrospective collection from agents
│       │   ├── aggregator.py  # Pattern detection across retrospectives
│       │   └── reporter.py    # Retrospective summaries for upper tiers
│       └── cli/               # CLI interface
│           ├── __init__.py
│           ├── main.py        # Main CLI entrypoint (Click/Typer)
│           ├── init.py        # `hoa init` — create and configure a new target repo
│           ├── run.py         # `hoa run` — start a hierarchy on a target repo
│           ├── inspect.py     # `hoa inspect` — view logs/traces
│           ├── guardrail.py   # `hoa guardrail` — manage guardrails
│           └── retro.py       # `hoa retro` — view retrospectives
├── templates/                 # Files generated into target repos by `hoa init`
│   ├── AGENTS.md.j2           # Agent workflow template (Jinja2)
│   ├── Dockerfile.j2          # Sandbox container template
│   ├── docker-compose.yml.j2  # Agent container orchestration
│   ├── ci.yml.j2              # GitHub Actions CI template
│   ├── setup-github.sh        # Repo configuration script (labels, branch protection, etc.)
│   └── CLAUDE.md.j2           # Claude Code instructions template
├── guardrails/                # Global guardrail definitions (applied to all projects)
│   ├── global/
│   ├── tier/
│   └── role/
├── config/
│   ├── default.yaml           # Default HoA configuration
│   └── permissions/           # Permission manifest templates
├── scripts/                   # Developer/operator scripts
│   └── setup-github.sh        # Configure THIS repo's GitHub settings
└── tests/
    ├── unit/
    ├── integration/
    └── fixtures/
```

### What `hoa init` generates in the target repo

```
target-project/
├── AGENTS.md              # Agent workflow (generated from template, project-specific)
├── CLAUDE.md              # Claude Code instructions (project-specific rules)
├── Dockerfile             # Sandbox environment for agents
├── docker-compose.yml     # Container orchestration for agent instances
├── .github/
│   ├── workflows/
│   │   └── ci.yml         # CI pipeline (deterministic guardrails)
│   ├── PULL_REQUEST_TEMPLATE.md
│   ├── ISSUE_TEMPLATE/
│   │   ├── task.yml
│   │   ├── guardrail.yml
│   │   ├── escalation.yml
│   │   └── retrospective.yml
│   └── ...
└── (project source code — created by agents during `hoa run`)
```

## Getting Started

> **Status: Early Development** — HoA is not yet functional. See [TODO.md](./TODO.md) for the development roadmap.

```bash
# Clone HoA
git clone https://github.com/sam0109/hoa.git
cd hoa

# Install
uv sync

# Create a new project (interactive — asks for name, stack, initial task)
uv run hoa init

# Run a task against an existing project
uv run hoa run --repo owner/project "Add user authentication"

# Inspect what happened
uv run hoa inspect --repo owner/project --last
```

## License

MIT
