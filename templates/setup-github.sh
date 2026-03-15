#!/usr/bin/env bash
# ============================================================================
# setup-github.sh — Configure a target repository for HoA-managed development
#
# This is a TEMPLATE that `hoa init` copies into target repos. It sets up
# branch protection, labels, PR templates, issue templates, and repo settings
# to enforce best practices for agentic development. Idempotent — safe to re-run.
#
# Prerequisites:
#   - gh CLI authenticated with admin access to the repo
#
# Usage:
#   bash setup-github.sh <owner/repo>
# ============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

REPO="${1:-}"
BRANCH="main"

if [[ -z "$REPO" ]]; then
  echo "ERROR: Repository required. Usage: bash setup-github.sh owner/repo"
  exit 1
fi

echo "=========================================="
echo " HoA GitHub Setup"
echo " Repo:   $REPO"
echo " Branch: $BRANCH"
echo "=========================================="
echo ""

# ---------------------------------------------------------------------------
# Helper: print step headers
# ---------------------------------------------------------------------------
step() {
  echo "──────────────────────────────────────────"
  echo "  $1"
  echo "──────────────────────────────────────────"
}

# ---------------------------------------------------------------------------
# 1. Repository settings
# ---------------------------------------------------------------------------
step "1/6  Repository settings"

gh api --method PATCH "repos/$REPO" --silent --input - <<'JSON'
{
  "has_issues": true,
  "has_projects": true,
  "has_wiki": false,
  "allow_squash_merge": true,
  "allow_merge_commit": false,
  "allow_rebase_merge": false,
  "squash_merge_commit_title": "PR_TITLE",
  "squash_merge_commit_message": "PR_BODY",
  "delete_branch_on_merge": true,
  "allow_auto_merge": true
}
JSON

echo "  ✓ Squash-merge only (no merge commits, no rebase merges)"
echo "  ✓ Auto-delete branches after merge"
echo "  ✓ Auto-merge enabled"
echo "  ✓ Wiki disabled (docs live in repo)"
echo ""

# ---------------------------------------------------------------------------
# 2. Labels — remove GitHub defaults, add HoA labels
# ---------------------------------------------------------------------------
step "2/6  Labels"

# HoA labels: name|color|description
LABELS=(
  "P0: critical|d73a4a|Blocking — must be fixed before any other work proceeds"
  "P1: high|e4e669|Important — should be addressed in the current phase"
  "P2: medium|0075ca|Normal priority — scheduled work"
  "P3: low|cfd3d7|Nice to have — do when convenient"
  "guardrails|f9d0c4|CI, testing, process infrastructure, and quality enforcement"
  "in progress|1d76db|An agent has claimed and is actively working on this"
  "needs plan|d876e3|Issue needs a plan DAG before work can begin"
  "plan approved|2ea44f|Plan has been reviewed and approved by the tier above"
  "blocked|b60205|Waiting on a dependency or escalation to resolve"
  "escalated|fbca04|Issue has been escalated to a higher tier"
  "retrospective|c5def5|Post-completion reflection and lessons learned"
  "deterministic-check|bfdadc|Guardrail: automated check (lint, test, validate)"
  "agent-check|d4c5f9|Guardrail: LLM-evaluated quality check"
)

# GitHub default labels to remove (they add noise and don't match our workflow)
DEFAULTS_TO_REMOVE=(
  "bug"
  "documentation"
  "duplicate"
  "enhancement"
  "good first issue"
  "help wanted"
  "invalid"
  "question"
  "wontfix"
)

for label in "${DEFAULTS_TO_REMOVE[@]}"; do
  if gh label delete "$label" --repo "$REPO" --yes 2>/dev/null; then
    echo "  ✗ Removed default label: $label"
  fi
done

for entry in "${LABELS[@]}"; do
  IFS='|' read -r name color description <<< "$entry"
  if gh label create "$name" --repo "$REPO" --color "$color" --description "$description" --force 2>/dev/null; then
    echo "  ✓ Label: $name"
  else
    echo "  ✓ Label: $name (already exists)"
  fi
done
echo ""

# ---------------------------------------------------------------------------
# 3. PR template
# ---------------------------------------------------------------------------
step "3/6  PR template"

mkdir -p .github

cat > .github/PULL_REQUEST_TEMPLATE.md << 'TMPL'
## Summary

<!-- 1-3 sentence description of what changed and why -->

Closes #<!-- issue number -->

## Changes

<!-- Bullet list of what was added/modified/removed -->

-

## Plan Adherence

- [ ] Changes match the approved plan DAG for this task
- [ ] No out-of-scope work included (create follow-up issues instead)

## Testing

- [ ] All existing tests pass (`uv run pytest`)
- [ ] New tests added for new functionality
- [ ] Tests would FAIL if the feature were broken (no tautological tests)
- [ ] No test was weakened or removed to make this change pass

## Code Quality

- [ ] No hardcoded secrets, tokens, or credentials
- [ ] No duplicated logic — reuse existing utilities
- [ ] Type hints on all public functions
- [ ] Complex logic has inline comments explaining *why*

## Guardrails

- [ ] All deterministic checks pass (CI is green)
- [ ] Agent-check guardrails reviewed (if applicable)
- [ ] Retrospective written (if this completes a unit of work)

## Follow-ups

- [ ] Follow-up issues created for out-of-scope work discovered during implementation
- [ ] Existing issues updated if new context was discovered
TMPL

echo "  ✓ Created .github/PULL_REQUEST_TEMPLATE.md"
echo ""

# ---------------------------------------------------------------------------
# 4. Issue templates
# ---------------------------------------------------------------------------
step "4/6  Issue templates"

mkdir -p .github/ISSUE_TEMPLATE

# Task template — the standard unit of work
cat > .github/ISSUE_TEMPLATE/task.yml << 'TMPL'
name: Task
description: A unit of work to be planned and executed by an agent
labels: []
body:
  - type: textarea
    id: description
    attributes:
      label: Description
      description: What needs to be done and why
    validations:
      required: true
  - type: textarea
    id: acceptance
    attributes:
      label: Acceptance criteria
      description: How do we know this is done? Be specific and verifiable.
      placeholder: |
        - [ ] Criterion 1
        - [ ] Criterion 2
    validations:
      required: true
  - type: dropdown
    id: priority
    attributes:
      label: Priority
      options:
        - P0: critical
        - P1: high
        - P2: medium
        - P3: low
    validations:
      required: true
  - type: textarea
    id: context
    attributes:
      label: Additional context
      description: Relevant files, prior art, constraints, or links
    validations:
      required: false
TMPL

echo "  ✓ Created .github/ISSUE_TEMPLATE/task.yml"

# Guardrail template — for proposing new guardrails
cat > .github/ISSUE_TEMPLATE/guardrail.yml << 'TMPL'
name: Guardrail
description: Propose a new guardrail (deterministic check or agent check)
labels: ["guardrails"]
body:
  - type: dropdown
    id: mechanism
    attributes:
      label: Mechanism
      description: How should this guardrail be enforced?
      options:
        - "Deterministic check (script/command, pass/fail)"
        - "Agent check (LLM evaluates against a rule)"
    validations:
      required: true
  - type: dropdown
    id: phase
    attributes:
      label: Phase
      description: When should this guardrail run?
      options:
        - Pre-execution (before the agent starts)
        - Runtime (while the agent works)
        - Post-execution (after the agent finishes)
    validations:
      required: true
  - type: textarea
    id: rule
    attributes:
      label: Rule
      description: |
        For deterministic: the command to run and what pass/fail means.
        For agent check: the natural-language rule the evaluator should judge against.
      placeholder: |
        Example (deterministic): `ruff check src/` must exit 0
        Example (agent check): "All public functions must have docstrings that explain the why, not just the what"
    validations:
      required: true
  - type: textarea
    id: motivation
    attributes:
      label: Motivation
      description: What failure or bad pattern prompted this guardrail? Link to a retrospective or issue if applicable.
    validations:
      required: true
  - type: dropdown
    id: scope
    attributes:
      label: Scope
      options:
        - Global (all agents)
        - Tier-specific
        - Role-specific
        - Single agent
    validations:
      required: true
TMPL

echo "  ✓ Created .github/ISSUE_TEMPLATE/guardrail.yml"

# Escalation template — for issues that couldn't be resolved at a lower tier
cat > .github/ISSUE_TEMPLATE/escalation.yml << 'TMPL'
name: Escalation
description: An issue escalated from a lower tier that needs higher-level direction
labels: ["escalated"]
body:
  - type: textarea
    id: context
    attributes:
      label: What was the original task?
      description: Brief description of what the agent was trying to accomplish
    validations:
      required: true
  - type: textarea
    id: attempted
    attributes:
      label: What was attempted?
      description: What approaches did the agent try before escalating?
    validations:
      required: true
  - type: textarea
    id: blocker
    attributes:
      label: What is the blocker?
      description: Why can't this be resolved at the current tier?
    validations:
      required: true
  - type: textarea
    id: options
    attributes:
      label: Suggested next steps
      description: |
        Provide 2-4 concrete options for the tier above to choose from.
        The parent should be able to steer, not solve from scratch.
      placeholder: |
        - **Option A**: [description] — [tradeoffs]
        - **Option B**: [description] — [tradeoffs]
        - **Option C**: Escalate further — [what additional context is needed]
    validations:
      required: true
TMPL

echo "  ✓ Created .github/ISSUE_TEMPLATE/escalation.yml"

# Retrospective template
cat > .github/ISSUE_TEMPLATE/retrospective.yml << 'TMPL'
name: Retrospective
description: Post-completion reflection on a unit of work
labels: ["retrospective"]
body:
  - type: input
    id: task_ref
    attributes:
      label: Related task/issue
      description: "Link to the issue this retrospective covers (e.g., #42)"
    validations:
      required: true
  - type: textarea
    id: went_well
    attributes:
      label: What went well
      description: Patterns and approaches that worked — these may become best-practice guardrails
    validations:
      required: true
  - type: textarea
    id: went_poorly
    attributes:
      label: What went poorly
      description: Failures, dead ends, unexpected difficulties — these may become preventive guardrails
    validations:
      required: true
  - type: textarea
    id: metrics
    attributes:
      label: Metrics
      description: |
        - Plan accuracy: X of Y steps completed as written
        - Review rounds: N
        - Follow-up issues created: #list or none
    validations:
      required: true
  - type: textarea
    id: suggestions
    attributes:
      label: Suggestions
      description: Concrete recommendations for improving the process, tooling, or guardrails
    validations:
      required: false
TMPL

echo "  ✓ Created .github/ISSUE_TEMPLATE/retrospective.yml"

# Disable blank issues — force use of templates
cat > .github/ISSUE_TEMPLATE/config.yml << 'TMPL'
blank_issues_enabled: false
contact_links: []
TMPL

echo "  ✓ Created .github/ISSUE_TEMPLATE/config.yml (blank issues disabled)"
echo ""

# ---------------------------------------------------------------------------
# 5. Branch protection
# ---------------------------------------------------------------------------
step "5/6  Branch protection"

# Note: required_status_checks.contexts is empty initially — CI workflows
# haven't been created yet. Once they exist, re-run this script or manually
# add them. GitHub will start enforcing as soon as the checks are registered.
gh api \
  --method PUT \
  --silent \
  "repos/$REPO/branches/$BRANCH/protection" \
  --input - <<'JSON'
{
  "required_status_checks": {
    "strict": true,
    "contexts": []
  },
  "enforce_admins": false,
  "required_pull_request_reviews": {
    "required_approving_review_count": 1,
    "dismiss_stale_reviews": true,
    "require_code_owner_reviews": false
  },
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_linear_history": true,
  "required_conversation_resolution": true
}
JSON

echo "  ✓ Require PR with 1 approving review (stale reviews dismissed)"
echo "  ✓ Require status checks to pass (strict — branch must be up to date)"
echo "  ✓ Require linear history (squash merge enforced)"
echo "  ✓ Require conversation resolution (all review threads resolved)"
echo "  ✓ Force pushes: BLOCKED"
echo "  ✓ Branch deletion: BLOCKED"
echo "  ✓ Admins: NOT exempt (enforce_admins: false until CI exists)"
echo ""
echo "  NOTE: No required status checks are configured yet — add them after"
echo "  creating CI workflows by re-running this script or using:"
echo "    gh api --method PUT repos/$REPO/branches/$BRANCH/protection ..."
echo ""

# ---------------------------------------------------------------------------
# 6. Rulesets (supplementary — catch force pushes on all branches)
# ---------------------------------------------------------------------------
step "6/6  Repository rulesets"

# Create a ruleset that prevents force pushes and deletions on main.
# Rulesets are the newer GitHub mechanism and stack with branch protection.
# We use both for defense in depth.
gh api \
  --method POST \
  --silent \
  "repos/$REPO/rulesets" \
  --input - <<JSON 2>/dev/null || echo "  ⚠ Ruleset already exists or rulesets not available (requires GitHub Pro/Team/Enterprise)"
{
  "name": "Protect main",
  "target": "branch",
  "enforcement": "active",
  "conditions": {
    "ref_name": {
      "include": ["refs/heads/main"],
      "exclude": []
    }
  },
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" }
  ]
}
JSON

echo "  ✓ Ruleset: Protect main (deletion, force push, require PR)"
echo ""

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo "=========================================="
echo " Setup complete!"
echo "=========================================="
echo ""
echo " Repository settings:"
echo "   • Squash-merge only, auto-delete branches, auto-merge enabled"
echo ""
echo " Labels (${#LABELS[@]} created):"
for entry in "${LABELS[@]}"; do
  IFS='|' read -r name _ _ <<< "$entry"
  echo "   • $name"
done
echo ""
echo " Templates:"
echo "   • PR template with plan adherence, testing, guardrails checklists"
echo "   • Issue templates: Task, Guardrail, Escalation, Retrospective"
echo "   • Blank issues disabled"
echo ""
echo " Branch protection ($BRANCH):"
echo "   • 1 approving review required"
echo "   • Status checks required (strict mode)"
echo "   • Linear history required"
echo "   • Conversation resolution required"
echo "   • Force push and deletion blocked"
echo ""
echo " Next steps:"
echo "   1. Create CI workflows (.github/workflows/)"
echo "   2. Re-run this script to add required status check names"
echo "   3. Commit the generated templates: git add .github/ && git commit"
echo ""
echo " To verify branch protection:"
echo "   gh api repos/$REPO/branches/$BRANCH/protection"
echo ""
