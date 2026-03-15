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
