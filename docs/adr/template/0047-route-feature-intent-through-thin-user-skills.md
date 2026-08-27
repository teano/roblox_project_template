# ADR-0047: Route feature intent through thin user skills

- Status: Accepted
- Date: 2026-08-27
- Deciders: Project maintainers
- Supersedes: None
- Superseded by: None

## Context

ADR-0046 removed the mandatory feature state machine and retained a small
`open|done` repository record. Removing the user-facing skills at the same
time exposed PowerShell as the apparent interface and made natural requests
such as “pause” or “continue” unreliable. That reduced ceremony for the agent
but made the template less convenient for its user.

## Decision

Keep `$feature-start`, `$feature-pause`, `$feature-continue`, and
`$feature-finish` as automatically discoverable, thin user-facing routers over
the optional feature record:

- Start creates or reuses an `open` record and may continue requested work in
  the same turn.
- Pause writes a handoff while state remains `open`.
- Continue restores relevant context and resumes work without a state
  transition.
- Finish completes proportional verification and closes the record as `done`.

`scripts/feature.ps1` remains the deterministic bookkeeping backend. Users are
not required to invoke it. The skills do not own branches, leases, dashboards,
pipelines, releases, or permissions for unrelated mutations.

## Alternatives considered

### PowerShell-only interface

This keeps repository machinery small but transfers mechanical work to the
user and prevents reliable natural-language routing.

### Restore the previous lifecycle engine

This restores familiar command names but also restores the complexity removed
by ADR-0046: paused/active states, leases, reserved branches, dashboards, and
separate no-work turns.

## Consequences

### Positive

- Users can speak naturally or invoke stable `$feature-*` names.
- Agents own backend invocation and can continue useful work in the same turn.
- Cross-chat pause/continue remains useful without expanding the state model.

### Negative

- Four small skill contracts and their metadata must remain aligned with the
  backend and active feature rule.
- Pause checkpoints are documentation maintained by the agent rather than a
  separate state transition.

## Enforcement

- Agent rules: `AGENTS.md`, `.agents/rules/feature-workflow.md`.
- Current documentation: `README.md`, `docs/TemplateWorkflow.md`,
  `docs/FeatureDevelopmentForBeginners.md`.
- Code boundaries: `.agents/skills/feature-*/`, `scripts/feature.ps1`.
- Tests: `scripts/tests/template-tools.tests.ps1` and skill quick validation.
