# HoA: Hierarchy of Agents

A framework for orchestrating large numbers of AI agents into reliable, inspectable, self-correcting hierarchies — with Claude Code as the execution primitive.

## Why HoA?

Getting a single AI agent to reliably complete a complex task is hard. Getting *dozens* of them to coordinate on a large project without human babysitting is an unsolved problem. HoA is an opinionated framework born from extensive experimentation with multi-agent architectures. It tackles the core failure modes head-on:

- Agents silently go off the rails with no way to diagnose what happened.
- Errors compound across agents because there's no feedback loop.
- The same mistakes recur because nothing enforces learned lessons.
- Agents accumulate permissions and access they don't need, creating blast radius.
- Human operators get buried in low-level details instead of steering high-level direction.

HoA addresses all of these through a strict hierarchical model with deep inspection, automatic guardrails, structured escalation, mandatory retrospection, and least-privilege security.

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

When a failure mode is identified — whether by a human operator, a retrospective, or an automated check — a guardrail is created to prevent recurrence. Guardrails are not suggestions; they are enforced constraints injected into agent context and validated against agent behavior.

**Guardrail types:**
- **Pre-execution**: Injected into agent system prompts and task context. These set boundaries before the agent acts. Examples: "Never modify files outside your assigned directory," "Always run tests before reporting completion."
- **Runtime**: Checked against agent actions as they happen. These can warn, block, or escalate. Examples: "Flag any shell command that would delete more than 10 files," "Reject tool calls to endpoints outside the allow-list."
- **Post-execution**: Validated against agent output after a task completes. These catch subtle policy violations. Examples: "Output must include a test plan," "Modified files must pass linting."

**Guardrail lifecycle:**
1. A failure or bad pattern is identified (via retrospective, human review, or automated detection).
2. A guardrail is authored — a structured rule with a trigger condition and enforcement action.
3. The guardrail is scoped — applied globally, to a specific tier, to a role, or to individual agents.
4. The guardrail is activated — injected into relevant agents on their next task.
5. The guardrail is monitored — trigger frequency and false-positive rate are tracked.
6. The guardrail is refined — adjusted or retired based on effectiveness data.

### 4. Issues Flow Up, Direction Flows Down

The hierarchy is not just an org chart — it defines strict communication channels.

**Direction (downward):**
- Tier 0 (the top) holds the full project context and creates the high-level plan.
- Tier 0 decomposes work into tasks and assigns them to Tier 1 agents.
- Each tier further decomposes and delegates to the tier below.
- Direction includes: task specification, success criteria, relevant guardrails, and a permissions manifest.

**Issues (upward):**
- When an agent encounters a problem it cannot resolve at its tier, it escalates.
- Escalations are structured: what was attempted, what failed, what the agent thinks the blocker is.
- The tier above receives the escalation and either resolves it (adjusting direction) or escalates further.
- Escalations propagate upward until they reach a tier with sufficient context/authority to resolve them.
- Crucially, escalations are *summarized* at each tier — Tier 0 should never be buried in low-level stack traces. It should receive "the database migration strategy is incompatible with the zero-downtime requirement" not a raw error log.

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

```
                    ┌─────────────────┐
                    │  Human Operator  │
                    └────────┬────────┘
                             │ configures & monitors
                             ▼
                    ┌─────────────────┐
                    │    Tier 0       │
                    │  (Coordinator)  │◄──── Full project context
                    └───┬────────┬────┘      Highest permissions
                        │        │
              direction │        │ direction
                        ▼        ▼
                ┌──────────┐  ┌──────────┐
                │  Tier 1  │  │  Tier 1  │◄── Scoped context
                │ (Lead A) │  │ (Lead B) │    Narrowed permissions
                └──┬───┬───┘  └──┬───┬───┘
                   │   │        │   │
                   ▼   ▼        ▼   ▼
                ┌────┐┌────┐ ┌────┐┌────┐
                │ T2 ││ T2 │ │ T2 ││ T2 │◄── Task-specific context
                └────┘└────┘ └────┘└────┘     Minimal permissions


         ─── Direction flows DOWN ───▶
         ◀─── Issues flow UP ────────

    ┌──────────────────────────────────────┐
    │          Inspection Layer             │
    │  (logs, traces, guardrails, retros)  │
    │  Captures EVERYTHING, queryable      │
    └──────────────────────────────────────┘
```

## Project Structure

```
hoa/
├── README.md              # This file
├── TODO.md                # Development roadmap
├── pyproject.toml         # Project config, dependencies, tool settings
├── uv.lock                # Locked dependency versions (managed by uv)
├── src/
│   └── hoa/
│       ├── __init__.py
│       ├── core/              # Core orchestration engine
│       │   ├── __init__.py
│       │   ├── hierarchy.py   # Hierarchy management (spawn, teardown, topology)
│       │   ├── scheduler.py   # Task decomposition and assignment
│       │   └── lifecycle.py   # Agent lifecycle (init, run, retro, terminate)
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
│       │   ├── engine.py      # Guardrail evaluation engine
│       │   ├── registry.py    # Guardrail storage and retrieval
│       │   ├── types.py       # Pre/runtime/post guardrail definitions
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
│       └── cli/               # CLI tools for agents and operators
│           ├── __init__.py
│           ├── main.py        # Main CLI entrypoint (Click/Typer)
│           ├── spawn.py       # Spawn agent subcommand
│           ├── escalate.py    # Escalate issue subcommand
│           ├── report.py      # Report status subcommand
│           ├── inspect.py     # Inspect logs/traces subcommand
│           └── guardrail.py   # Manage guardrails subcommand
├── guardrails/            # Guardrail definitions (YAML/JSON)
│   ├── global/            # Applied to all agents
│   ├── tier/              # Applied to specific tiers
│   └── role/              # Applied to specific roles
├── config/                # Configuration
│   ├── default.yaml       # Default HoA configuration
│   └── permissions/       # Permission manifest templates
└── tests/                 # Test suite
    ├── unit/
    ├── integration/
    └── fixtures/
```

## Getting Started

> **Status: Early Development** — HoA is not yet functional. See [TODO.md](./TODO.md) for the development roadmap.

```bash
# Clone the repository
git clone https://github.com/sam0109/hoa.git
cd hoa

# Install dependencies (coming soon)
uv sync

# Run HoA (coming soon)
uv run hoa --help
```

## License

MIT
