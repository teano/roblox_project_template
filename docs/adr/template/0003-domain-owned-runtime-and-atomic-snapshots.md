# ADR-0003: Domain modules own runtime state and snapshots apply atomically

- Status: Accepted
- Date: 2026-07-28
- Deciders: Project maintainers
- Supersedes: None
- Superseded by: None

## Context

Wallet and future domain systems need stable runtime models and may build
controllers around those models. Treating the persisted document as live
runtime state makes domain invariants, event emission, and controller identity
easy to bypass. Replacing provider tables incrementally can leave modules
observing a mixture of old and new snapshot data.

Save infrastructure still needs a common way to validate, capture, install,
start, stop, and persist each domain's data.

## Decision

Domain modules own per-player runtime models and all domain mutations. Server
save providers are stateless contracts whose methods receive `player`; save
controllers own ordered provider orchestration and persistence, not the
runtime models themselves. Client and server provider implementations remain
separate because their authority differs.

A snapshot is prepared and validated before runtime mutation. Application then
captures current state, stops providers in reverse order, installs every target
memento in forward order, and runs providers in forward order. `Run` means all
provider data is already installed and runtime logic may now be constructed.

If target `SetMemento` or `Run` fails, partial target state is stopped and the
complete previous memento set is restored before providers run again. A cleanup
or rollback failure leaves the controller in `ApplyFailed`, not `Loaded`.
Closing captures and saves before stopping providers.

## Alternatives considered

### Persisted document as the live runtime model

Rejected because arbitrary table mutation bypasses domain validation, dirty
tracking, semantic events, and controller ownership.

### Save controller owns domain tables

Rejected because persistence infrastructure would absorb domain behavior and
become layer-specific.

### Apply providers independently without rollback

Rejected because consumers could observe a partially updated cross-provider
snapshot.

### Replace client runtime tables on every change

Rejected because it breaks object identity, can detach runtime controllers, and
is unnecessarily expensive.

## Consequences

### Positive

- Domain invariants have one mutation boundary.
- Runtime object identity survives ordinary synchronization.
- Snapshot replacement has an explicit all-or-rollback contract.
- Persistence can evolve without owning gameplay behavior.

### Negative

- Providers need explicit lifecycle, validation, and copy boundaries.
- Rollback logic and failure states add complexity.
- Cross-domain operations require a separate orchestration/transaction module.

## Enforcement

- Agent rules: `.agents/rules/save-system.md`,
  `.agents/rules/domain-data.md`.
- Current documentation: `docs/InitializationAndSaveSystem.md`.
- Code boundaries: `MementoTransaction`, server/client save controllers,
  `WalletModule`, and current/future client providers.
- Tests: atomic apply/rollback, provider lifecycle, dirty capture, and domain
  mutation coverage in `SystemTestRunner` and
  `ProductionIntegrationTestRunner`.
