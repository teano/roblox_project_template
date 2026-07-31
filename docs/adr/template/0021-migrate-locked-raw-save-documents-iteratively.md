# ADR-0021: Migrate locked raw save documents through ordered version steps

- Status: Accepted
- Date: 2026-07-31
- Deciders: Project maintainers
- Supersedes: None
- Superseded by: None

## Context

Released games need to transform persisted player data when provider-local
reconciliation is insufficient. A transition may span providers, rename or
split data, or require several specialized operations for one release. A
player may skip multiple releases, so applying only the newest transform would
give it an input schema that the transform does not understand.

Unity-style migration before ordinary save consumption provides the useful
ordering model, but Roblox DataStores add distributed session ownership. A
transform that reads or writes outside the profile's acquired session lock can
race another server. Loading temporary save controllers for migrations would
also duplicate layer ownership and bypass the existing atomic provider
application boundary.

## Decision

Use one server-only `MigrationModule` as an explicitly initialized
raw-document transformation pipeline. The generic `SaveModule` initializes
first, then `Migration`, domain providers, and the project-specific
`GlobalSave` layer.

For each player, `GlobalSave` invokes migration after storage acquires the
session lock and before provider reconciliation and runtime mutation. The
module reads the stored `Version.PreviousVersion` checkpoint and selects every
registered controller with a target in `(storedVersion, currentVersion]`.
Controllers execute by ascending semantic target version, then non-negative
integer order, then stable unique ID.

Several narrow controllers may share one target version. Every controller
receives an isolated raw-document copy and a context containing the preceding
applied version, target version, current version, migration ID, save-layer ID,
and player. A controller may transform any provider envelopes, but cannot
change the owned version checkpoint.

The complete output must remain DataStore-safe. A malformed checkpoint, a
stored version newer than the server, a controller failure, checkpoint
mutation, or invalid output aborts load before provider runtime mutation and
releases the session lock. The Version provider advances the checkpoint only
after the entire chain and atomic provider application succeed, making an
unpersisted attempt safely replayable.

When an older checkpoint requires a commit, the save controller refreshes the
session lock after raw transformation and before provider application. After
successful application it synchronously queues Version for dirty capture
before publishing load success. This prevents stale-lock runtime creation and
prevents any save from persisting transformed provider data with the old
checkpoint. An explicitly configured legacy baseline may start from a raw
document without the current `Providers` root, but the completed chain must
reconstruct that root before application.

Provider `ReconcileMemento` continues to own simple provider-version schema
upgrades. The raw migration pipeline owns cross-provider or game-version
transitions.

## Alternatives considered

### Run migration before save and lock initialization

Rejected because two Roblox servers could transform the same profile and
because migration would need a second persistence path outside the save
controller.

### Build temporary save controllers for migration

Rejected because layer ownership, locks, provider lifecycle, and persistence
would be duplicated and could conflict with `GlobalSave`.

### Apply only the newest matching controller

Rejected because a player skipping releases would bypass the intermediate
schemas expected by later transforms.

### Put every migration in provider reconciliation

Rejected because reconciliation is intentionally provider-local and cannot
safely express coordinated changes across several provider envelopes.

## Consequences

### Positive

- Skipped releases execute a deterministic complete migration chain.
- Multiple focused controllers can compose one version transition.
- Cross-provider transforms occur before runtime state exists.
- Session locking and atomic snapshot application remain authoritative.
- Failed or unpersisted migrations can be retried without partial runtime
  mutation.

### Negative

- Released migrations become durable compatibility code.
- Controllers must be deterministic, bounded, and retry-safe.
- A downgrade or malformed checkpoint fails closed and requires operator
  intervention.
- Projects must distinguish provider reconciliation from game-version
  migration deliberately.

## Enforcement

- Agent rules: `.agents/rules/save-system.md`,
  `.agents/rules/architecture.md`, `.agents/rules/initialization.md`.
- Current documentation: `docs/InitializationAndSaveSystem.md`.
- Code boundaries: server `MigrationModule`, `MigrationManifest`,
  `MigrationInitializationCommand`, `GlobalSaveInitializationCommand`, and
  `VersionModule`.
- Tests: migration contracts in `SystemTestRunner` and
  `ProductionReadinessTestRunner`.
