# ADR-0025: Include Teleport projection in communication snapshot generations

- Status: Accepted
- Date: 2026-08-03
- Deciders: Project maintainers
- Supersedes: None
- Superseded by: None

## Context

ADR-0024 gives Teleport its own bounded bootstrap request and requires handler
failures to recover through communication resync. The global snapshot boundary
previously captured only save providers. `CommunicationServer:BeginSnapshot`
clears the previous epoch's queue, so a Teleport Started, Accepted, Failed, or
presentation message queued before that call could be discarded after the
standalone Teleport bootstrap. Runtime resync had the same weakness because it
never replaced Teleport projection.

Retaining the domain state while losing its projection can leave the client on
an older attempt and can make a later valid transition fail against the wrong
prior state.

## Decision

Include a complete client-safe Teleport projection in every global snapshot
response. The server captures provider state and Teleport state before
`BeginSnapshot`. The client validates the Teleport snapshot without mutation,
applies the provider transaction, installs the prepared Teleport projection,
and only then resumes communication and acknowledges the exact epoch.

The same generation-scoped path owns initial synchronization and every runtime
resync. Own-player Teleport State queue failure explicitly asks
`CommunicationServer` to collapse delivery to `ResyncRequired`; presentation
loss continues to follow the existing lower-priority policy and is repaired by
the next required snapshot.

Teleport keeps its bounded standalone bootstrap as an early module bootstrap
and public request boundary. The later global generation is authoritative for
communication resume and replaces any state that changed before
`BeginSnapshot` cleared the old queue.

`TeleportClient` communication callbacks use a terminal stopped guard. Stop
clears its projection and signals; retained callbacks cannot restore state.

## Alternatives considered

### Preserve the standalone bootstrap as the only Teleport baseline

Rejected because it completes before `BeginSnapshot` and cannot recover state
discarded by initial queue clearing or a later resync.

### Request Teleport bootstrap after the global snapshot response

Rejected because two independent round trips complicate atomic validation and
can leave provider state applied while Teleport recovery repeatedly fails.

### Ignore failed Teleport State queueing

Rejected because a later transition then evaluates against stale client state
without a guaranteed recovery trigger.

## Consequences

### Positive

- Initial queue clearing and runtime recovery restore one coherent client
  baseline.
- Backpressure and handler failures cannot permanently strand Teleport
  projection on an older attempt.
- The server remains authoritative and no save provider or direct remote is
  introduced for Teleport.
- Stop remains terminal even though communication handlers are retained.

### Negative

- Global snapshot composition now depends on Teleport state on both sides.
- Snapshot validation includes a small additional client-safe payload.
- The early Teleport bootstrap may be replaced once by the later global
  generation before client initialization completes.

## Enforcement

- Agent rules: `.agents/rules/teleport.md`,
  `.agents/rules/communication.md`, `.agents/rules/initialization.md`.
- Current documentation: `docs/Teleport.md`, `docs/Communication.md`,
  `docs/InitializationAndSaveSystem.md`, `docs/TestCoverage.md`.
- Code boundaries: `TeleportModule:BuildClientSnapshot`,
  `TeleportClient:PrepareSnapshot`, `TeleportClient:ApplyPreparedSnapshot`,
  both `GlobalSaveInitializationCommand` implementations, and
  `CommunicationServer:RequireResync`.
- Tests: `TeleportModuleTestRunner`, `ProductionIntegrationTestRunner`,
  `SystemTestRunner`, `ProductionReadinessTestRunner`, and `AllTestsRunner`.
