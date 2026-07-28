# Architecture decision records

Architecture decision records (ADRs) preserve why durable project constraints
exist. Current behavior belongs in system documentation, mandatory editing
constraints belong in `.agents/rules/`, and ADRs preserve the decision and its
tradeoffs.

## Decision index

| ID | Decision | Status |
|---|---|---|
| [ADR-0001](0001-explicit-initialization-manifests.md) | Use explicit side-specific initialization manifests | Accepted |
| [ADR-0002](0002-layer-agnostic-save-module.md) | Keep SaveModule independent of save-layer meaning | Accepted |
| [ADR-0003](0003-domain-owned-runtime-and-atomic-snapshots.md) | Domain modules own runtime state and snapshots apply atomically | Accepted |
| [ADR-0004](0004-compact-batched-communication-and-resync.md) | Use compact batched runtime messages with snapshot resync | Accepted |
| [ADR-0005](0005-centralized-players-lifecycle.md) | Centralize Roblox player lifecycle behind PlayersModule | Accepted |
| [ADR-0006](0006-hybrid-rojo-and-studio-place-ownership.md) | Track one canonical Studio place alongside partial Rojo source | Accepted |
| [ADR-0007](0007-side-owned-generation-safe-object-pools.md) | Use side-owned generation-safe object pools | Accepted |

## When an ADR is required

Create an ADR when a decision:

- changes ownership, authority, lifecycle, persistence, or synchronization
  across module boundaries;
- introduces or removes a subsystem or public architectural contract;
- chooses between plausible alternatives with meaningful long-term cost;
- intentionally reverses an Accepted decision.

Do not create an ADR for a local refactor, bug fix, naming choice, dependency
update, or implementation detail that does not constrain future design.

## Lifecycle

Use one of these statuses:

- `Proposed`: under discussion and not yet an active constraint.
- `Accepted`: approved and currently applicable.
- `Deprecated`: retained for history but no longer recommended.
- `Superseded by ADR-XXXX`: replaced by a later decision.
- `Rejected`: considered but never adopted.

The decision body of an Accepted ADR is immutable as a historical record except
for spelling, broken links, or clarifications that do not change meaning.
Status metadata may change only to reflect deprecation or supersession. To
reverse a decision:

1. Create a new ADR that names the old ADR under `Supersedes`.
2. Change the old status to `Superseded by ADR-XXXX`.
3. Update this index, applicable agent rules, current documentation, and
   enforcement tests in the same architectural change.

## Naming and numbering

- Copy `_template.md`.
- Allocate the next four-digit ID; never reuse a removed or rejected ID.
- Use `NNNN-short-kebab-case-title.md`.
- Write the decision in present tense and the context in terms of constraints,
  not a transcript of the discussion.
- Link concrete rules, documentation, code boundaries, and tests under
  `Enforcement`.

## Reading policy

Before an architectural change, select every ADR related to the affected
ownership, lifecycle, authority, persistence, or synchronization concern.
Local edits that preserve architecture do not require reading the entire ADR
set.

If an ADR conflicts with current agent rules, code, tests, or system
documentation, report the drift instead of silently choosing whichever version
is easier to implement.
