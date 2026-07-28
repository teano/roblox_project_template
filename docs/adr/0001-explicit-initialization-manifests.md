# ADR-0001: Use explicit side-specific initialization manifests

- Status: Accepted
- Date: 2026-07-28
- Deciders: Project maintainers
- Supersedes: None
- Superseded by: None

## Context

The game needs one predictable initialization mechanism that can grow as
modules are added. Server and client have different implementations and order,
while still needing the same execution guarantees. Filesystem discovery,
self-starting modules, and increasingly granular startup phases make ordering
hard to inspect and failures hard to reproduce.

Some modules may intentionally continue background work, but that is a property
of the module rather than a global critical/deferred classification.

## Decision

Keep one executable bootstrap per side and one explicit manifest per side. Both
manifests run through the shared sequential `InitializationRunner`.

Each command has a unique `Id`, declares `DependsOn`, and implements
`Initialize(context)`. Dependencies are validated against earlier entries in
the same manifest. A command error stops bootstrap. The 30-second watchdog logs
but does not cancel a running command.

Repeated initialization calls share an active result and return the cached
result after completion. A module that intentionally initializes in the
background may let its own command return, accepting responsibility for that
lifecycle internally.

## Alternatives considered

### Self-starting modules and standalone scripts

Rejected because startup order and ownership become distributed across the
instance tree and are no longer reviewable in one composition root.

### Automatic discovery through names, tags, or folders

Rejected because inferred ordering hides dependencies and makes filesystem
layout part of the runtime contract.

### Global critical/deferred phases or parallel dependency execution

Rejected because a growing phase graph is difficult to reason about and safe
parallelism depends on module-specific behavior. Modules retain that choice
locally.

## Consequences

### Positive

- Server and client composition and ordering are explicit.
- Startup failures have one deterministic propagation path.
- Commands and modules remain independently testable.
- Adding a module has a visible integration point.

### Negative

- Every long-lived module requires explicit manifest work.
- Manifest ordering and dependency declarations contain some deliberate
  redundancy.
- Background readiness beyond command completion needs a module-specific
  contract.

## Enforcement

- Agent rules: `.agents/rules/initialization.md`,
  `.agents/rules/architecture.md`.
- Current documentation: `docs/InitializationAndSaveSystem.md`.
- Code boundaries: `Shared/Initialization/InitializationRunner`,
  `ServerScriptService/Initialization/ServerManifest`,
  `ReplicatedStorage/Client/Initialization/ClientManifest`, and the two
  bootstrap scripts.
- Tests: `SystemTestRunner` and clean server/client bootstrap verification.
