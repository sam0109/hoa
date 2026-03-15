# Best Practices — Lessons from chem_sim Agent Coordination Experiments

This document captures every actionable lesson learned from running multi-agent coordination experiments on the [chem_sim](https://github.com/sam0109/chem_sim) project. These lessons directly inform HoA's design and should be treated as requirements or strong defaults for the framework.

---

## 1. Planning Before Execution

### Problem: Agents that jump straight into coding produce worse, more scattered output
Without a plan, agents make more mid-course corrections, commit unrelated changes together, and are harder to review.

### Solution: Mandatory plan-then-execute workflow
- Every agent must post a structured plan **before writing any code**.
- Each plan step must be completable in isolation and have a **verification criterion**.
- Steps are ordered: data/types first, logic second, tests third, UI last.
- Plan includes a "Step 0: Understand the current code" (read before write).
- Plan includes a final step to run the full test suite.

### Lesson for HoA
Plans are a form of pre-execution guardrail. HoA should require agents to emit a plan artifact before beginning work, and that plan should be inspectable and (optionally) approvable by the tier above. The plan format should be standardized and machine-parseable so HoA can track plan accuracy metrics.

### Observed metric: Plan accuracy
Across all chem_sim issues, plans were remarkably accurate — most completed with 0 steps added or removed. When a plan was wrong, it was almost always because the agent skipped Step 0 (understanding existing code).

---

## 2. One Concern Per Commit

### Problem: Mixed commits (refactoring + features, formatting + logic) are impossible to review and hard to revert

### Solution: Strict commit discipline
- One logical change per commit.
- Never mix refactoring with new features.
- Commit messages reference the issue number.

### Lesson for HoA
This should be a default guardrail. HoA can enforce it by checking commit diffs for mixed concerns (heuristic: if a commit touches both test files and production logic in different modules, flag it).

---

## 3. Test Ratchet — Never Regress

### Problem: Agents "fix" failing tests by weakening tolerances or removing assertions

### Solution: Physics test ratchet
- A `.physics-test-count` file records the current number of passing tests.
- CI fails if the count decreases.
- **Tests must NEVER be weakened to make a change pass.** If a change breaks a test, fix the change.
- Known-failing tests are marked as `KNOWN_FAILURES` with issue references rather than deleted or loosened.

### Lesson for HoA
The test ratchet pattern is generalizable. HoA should support "ratchet guardrails" — metrics that must be monotonically non-decreasing (test count, coverage percentage, lint error count). The ratchet is post-execution and automated, requiring no human judgment. This was one of the most effective guardrails in chem_sim.

---

## 4. Sub-Agent Code Review

### Problem: Self-review is unreliable — the agent that wrote the code has the same blind spots

### Solution: Spawn a separate agent to review each PR
The reviewing agent:
1. Reads the full diff
2. Checks domain correctness (physics equations, units)
3. Checks test quality (would tests fail if the feature were removed?)
4. Checks architecture (forbidden imports, magic numbers)
5. Runs the tests locally
6. Posts an approve or request-changes review

### What the reviews actually caught
- YAML comment parsing bugs (# in unquoted strings)
- Missing `continue-on-error` on CI jobs with pre-existing failures
- File permission issues (644 vs 755 on scripts)
- Dead code in Docker Compose config
- Unnecessary modifications to test output format (existing output was already parseable)
- Robustness improvements (e.g., `tail -1` instead of `tail -n 1`)

### Lesson for HoA
Sub-agent review is extremely high-value. Every PR produced by an agent should be reviewed by a different agent (or the tier above). The reviewer should have a structured checklist. Review findings should feed into the guardrail system — if reviewers keep catching the same class of bug, that's a guardrail candidate. Review round count (how many rounds before approval) is a useful quality metric.

---

## 5. Mandatory Retrospection Produces Real Signal

### Problem: Without structured reflection, agents repeat the same mistakes across issues

### Solution: Every issue ends with a structured retrospective
Every retrospective included:
- **What went well** — patterns that worked
- **What went poorly** — failures and friction
- **Lessons for future agents** — actionable advice
- **Metrics** — plan accuracy, test impact, review rounds, follow-up issues
- **Time estimate vs actual**

### Patterns that emerged from aggregating retrospectives

**Recurring friction points:**
- Merge conflicts from concurrent agents (hit on issues #45, #47, #48, #51)
- `npx` auto-downloading packages when checking tool existence (#53)
- YAML validation failures caught too late (#44, #52, #53)
- Pre-existing lint errors blocking unrelated changes (#45, #57)
- Three.js canvas intercepting clicks on overlaid UI elements (#48)

**Recurring successes:**
- The plan-first approach was consistently praised — plans were accurate across all issues
- Gradient consistency tests (finite difference checks) caught zero bugs — proving the force functions were solid
- Sub-agent reviews caught real bugs on nearly every PR

### Lesson for HoA
Retrospection works. The key is making it **mandatory and structured** — not optional free-text. HoA should:
1. Inject the retrospection prompt automatically after task completion (not rely on the agent remembering).
2. Parse retrospectives into structured data for aggregation.
3. Surface patterns across retrospectives automatically (e.g., "merge conflicts mentioned in 4 of 11 retrospectives").
4. Use pattern detection to suggest guardrails.

---

## 6. Pre-Commit Hooks as a Safety Net

### Problem: Agents commit code that fails basic checks (lint, format, type errors)

### Solution: Pre-commit hooks (Husky + lint-staged)
- Every commit runs ESLint and Prettier on staged files.
- This catches formatting issues and obvious errors before they reach CI.
- lint-staged only processes staged files, so pre-existing issues in unmodified files don't block.

### Lesson for HoA
Pre-execution and commit-time guardrails are the cheapest form of quality assurance. HoA should support injecting pre-commit hooks into agent workspaces. This is a form of "fail fast" — catching problems at commit time is cheaper than catching them at PR review time, which is cheaper than catching them after merge.

---

## 7. Environment & Tooling Assumptions Fail

### Problem: Agents assume tools/runtimes exist that aren't present

**Specific failures:**
- `pip`/`pyyaml` not available for YAML validation — had to fall back to `npx js-yaml`
- `grep -oP` (Perl regex) works on Linux CI but not on macOS dev machines
- `npx <tool> --version` triggers remote package download instead of checking local install — must check `node_modules/<pkg>` instead
- `gh auth setup-git` needed before git push (not automatic)

### Lesson for HoA
HoA's permission manifest should include an **environment declaration** — what tools/runtimes are available in the agent's sandbox. Agents should be told what they have, not left to discover it by failing. Environment mismatches between dev machines and CI are a specific guardrail candidate: "commands must work on both macOS and Linux" or explicitly scope to one.

---

## 8. Concurrent Agents Need Merge Conflict Strategy

### Problem: When multiple agents work in parallel, merge conflicts are inevitable

**Observed frequency:** Merge conflicts came up in 4 of 11 guardrails issues (36%).

**Specific pain points:**
- `package.json` / `package-lock.json` conflicts when two agents add different dependencies
- Code formatting PR conflicting with feature PRs
- Accidentally rebasing onto the wrong branch (agent was on main instead of feature branch)

### Solutions that emerged
- Always `git fetch origin main` before pushing to detect conflicts early.
- For `package.json` / lock file conflicts: take theirs for lock file, manually resolve `package.json`, then `npm install` to regenerate.
- Use `git branch -f <branch> HEAD && git reset --hard origin/main` as a recovery when rebase goes wrong.
- Rebase onto latest main before every merge — with up to 3 retries if automerge is cancelled by a conflict.

### Lesson for HoA
HoA needs a built-in merge coordination strategy. Options:
1. **Serialize merges** — only one agent merges at a time (simple but slow).
2. **Optimistic concurrency with auto-rebase** — agents merge freely; HoA auto-rebases when conflicts arise.
3. **Workspace isolation** — each agent works in a separate worktree/container, conflicts only surface at merge time.

chem_sim used option 3 (worktrees/containers) with manual conflict resolution. HoA should automate the rebase-retry loop.

---

## 9. PR Checklist as a Guardrail

### Problem: Agents forget to verify important properties (tests pass, no regressions, architecture respected)

### Solution: A 25-item PR template checklist
Categories: Purpose, Physics Accuracy, Code Quality, Testing, Performance, Documentation, Follow-ups.

**Key items:**
- "This change contributes toward a stated goal" (no scope creep)
- "No test tolerance was weakened"
- "Tests would FAIL if the feature were broken" (no tautological tests)
- "No unnecessary O(N^2) in hot loops"
- "Follow-up issues created for out-of-scope work"

### Lesson for HoA
PR checklists should be auto-generated from the active guardrails for an agent's scope. Rather than a static template, HoA should compose the checklist dynamically based on: global guardrails + tier-specific guardrails + task-specific guardrails. The checklist is a pre-merge gate: the reviewing agent (or an automated check) must confirm each item.

---

## 10. Known Failures Must Be Explicit, Not Hidden

### Problem: Agents either ignore pre-existing failures or try to "fix" them by weakening tests

### Solution: `KNOWN_FAILURES` pattern
- Skip failing tests with a clear comment linking to the issue that will fix them.
- Skipped tests show up in output: `SKIP: NVE-02 — Methane NVE (see #1)`.
- The test ratchet tracks only non-skipped tests, so skipping doesn't game the count.

### Alternative approach observed: Seeding the PRNG
For flaky tests caused by random initial conditions, seeding `Math.random` with a deterministic PRNG (mulberry32) eliminated flakiness **without weakening tolerances**. This preserved the test's integrity while making it reproducible.

### Lesson for HoA
HoA should distinguish between "this test fails because of a known bug" and "this test is flaky." Both need handling, but the strategies differ:
- Known bugs → `KNOWN_FAILURES` with issue tracking
- Flakiness → deterministic seeding, retry, or environment stabilization

A guardrail should prevent agents from weakening test assertions. This can be detected by diffing test files and flagging tolerance increases or assertion removals.

---

## 11. Docker/Container Isolation for Agents

### Problem: Agents using shared filesystems (even with git worktrees) can interfere with each other

### Solution: Each agent runs in its own Docker container
- Fresh `git clone` per agent (complete isolation)
- Dependencies installed per container
- `host.docker.internal` for reaching host services (Anthropic proxy)
- `--rm` flag for automatic cleanup
- Container includes all needed tools: Node, gh CLI, Claude Code

### Gotchas discovered
- Linux Docker needs `extra_hosts: host.docker.internal:host-gateway` (macOS/Windows auto-maps this)
- Always include the AI tool (Claude Code) in the Docker image — don't assume manual install
- The `--dangerously-skip-permissions` flag is needed for fully autonomous agents (interactive ones don't need it)

### Lesson for HoA
Containerized isolation is the right default for HoA agents. Each agent's sandbox should be:
1. A fresh clone (not a shared worktree) for maximum isolation
2. Pre-built with all required tools in the image
3. Network-restricted to only approved endpoints
4. Ephemeral — destroyed after the task completes
5. Logged at the container level (stdout/stderr captured by HoA's inspection layer)

---

## 12. Pool Management for Multi-Agent Runs

### Solution observed: `launch-agents.py`
- Maintains N concurrent agents at all times.
- When one finishes, a replacement launches immediately (if unclaimed issues remain).
- Agents use the claim-hash protocol to avoid duplicates.
- Ctrl-C once = drain (let running agents finish, don't start new ones). Ctrl-C twice = force stop.
- Streams formatted logs from all agents with `[agent-N]` prefixes.

### Lesson for HoA
HoA's Tier 0 effectively IS a pool manager. The chem_sim pool manager was simple — it just maintained a count. HoA should add:
- Dynamic scaling based on available work (not just a fixed N)
- Priority-based scheduling (the issue priority system was `P1 > P2 > ... > P5`)
- Health monitoring (detect stuck agents, not just finished ones)
- Graceful drain on shutdown

---

## 13. Follow-Up Issue Hygiene

### Problem: Agents create duplicate follow-up issues, or create issues that overlap with existing ones

### Solution: Search-before-create protocol
1. Search existing issues by keyword before creating.
2. If a matching issue exists, add a comment instead of creating a new one.
3. Never create an issue that is a subset of an existing issue.
4. If partial overlap, reference both issues and explain what's distinct.

### Lesson for HoA
When agents propagate issues upward, HoA should de-duplicate them. This is similar to the "escalation summarization" principle — the tier above should recognize that 3 different agents reporting "merge conflict with main" is one systemic issue, not three.

---

## Summary: Top Guardrails for HoA (Ranked by Impact)

Based on what actually prevented the most failures in chem_sim:

| Rank | Guardrail | Type | Impact |
|------|-----------|------|--------|
| 1 | Test ratchet (never regress) | Post-execution, automated | Prevented silent test erosion |
| 2 | Mandatory plan before execution | Pre-execution | Dramatically improved agent focus and output quality |
| 3 | Sub-agent code review | Post-execution | Caught real bugs in nearly every PR |
| 4 | Mandatory retrospection | Post-execution | Surfaced systemic issues and produced actionable lessons |
| 5 | PR checklist (dynamic) | Pre-merge gate | Ensured agents checked important properties |
| 6 | Pre-commit hooks | Runtime, automated | Caught formatting and lint issues at commit time |
| 7 | Known-failures pattern | Process | Prevented both test-hiding and tolerance-weakening |
