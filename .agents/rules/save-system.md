# Save system rules

## Scope

Apply to save modules/controllers/builders, providers, mementos, storage adapters, autosave, session locks, migrations, shutdown, and snapshot application.

Required context: `docs/InitializationAndSaveSystem.md`.

## Ownership

- `SaveModule` owns controller registration, lookup, construction entry, and removal.
- A project-specific command or builder owns the meaning and lifetime of a save layer.
- A save controller owns provider ordering, memento lifecycle, dirty capture, persistence, and snapshot construction.
- Domain modules own per-player runtime models.

## Mandatory provider contract

- Server providers MUST be stateless contracts whose methods receive `player`; per-player models belong in the domain module.
- Providers MUST have stable unique IDs and explicit versions.
- `ValidateMemento` MUST reject or sanitize unsafe data.
- `CreateDefault` and reconciliation MUST produce valid isolated data.
- `GetMemento` and `SetMemento` MUST not expose mutable internal tables.
- `MementoChanged` MUST only mark real authoritative changes dirty.
- `Stop` MUST be idempotent and safe after `SetMemento` even when `Run` did not complete.
- `Run` means all provider mementos have already been installed and runtime logic may now be constructed.

## Atomic application

Snapshot replacement MUST follow:

1. Reconcile and validate every target memento without mutating runtime.
2. Capture current dirty state and every current memento.
3. Stop current providers in reverse order.
4. Set all target mementos in forward order.
5. Run all providers in forward order.
6. On any Set/Run failure, stop partial target state and restore the complete previous set before running providers again.

A controller MUST remain `Loaded` only after full success or full rollback. Failed cleanup or rollback MUST move it to `ApplyFailed`.

## Persistence rules

- Runtime changes mark providers dirty; they MUST NOT write DataStore immediately.
- Dirty providers are captured separately from persistence scheduling.
- `AutoSaveModule` decides when to call `ForceSave`; save controllers do not own autosave timing.
- Player close MUST capture/save before provider Stop.
- Close MUST coordinate with in-flight load or snapshot application; it MUST NOT remove a runtime while lock acquisition or provider application is still active.
- Concurrent close callers for one player MUST share one close operation and one `PlayerClosed` notification.
- A load cancelled by player close after acquiring a session lock MUST release that lock without applying provider runtime state.
- Production persistence MUST use `UpdateAsync`, bounded retry, validation, actual JSON-encoded byte limits, and session locking.
- A session-lock transform may be invoked more than once by `UpdateAsync`; ownership MUST be derived from the final returned document, never from sticky callback side effects.
- A non-table stored document root MUST fail closed and remain unchanged; it
  MUST NOT be replaced with a newly initialized profile.
- Save tables MUST be UTF-8-safe string-keyed dictionaries or dense arrays; mixed/sparse tables, metatables, cycles, unsupported values, and non-finite numbers MUST be rejected.
- A failed multi-provider capture MUST retain every dirty provider needed for a complete retry.
- Concurrent `ForceSave` callers waiting on one active operation MUST receive that operation's real result.
- A provider dirtied while persistence is in flight MUST remain dirty and be
  captured before that `ForceSave` reports a clean successful result.
- Shutdown MUST use the shared deadline and bounded-concurrency coordinator.
- No new retry may begin after the propagated deadline.
- Existing test saves MUST NOT cause speculative legacy migrations. Add a migration only for a real released-version transition.
- Raw-document migrations MUST run on the server after the session lock is
  acquired and before provider reconciliation or runtime mutation.
- Migration controllers MUST be registered explicitly before
  `MigrationModule:Initialize()`, use a stable unique ID, declare a strict
  canonical `MAJOR.MINOR.PATCH` target and non-negative integer order, and be
  deterministic, retry-safe, stateless, and reentrant across concurrent
  player loads. Scheduling metadata and the callable are snapshotted when
  registered.
- Every controller whose target is in `(storedVersion, currentVersion]` MUST
  run in ascending target-version order; controllers sharing a target run by
  order and then ID. This complete chain is mandatory when a player skips
  releases.
- Migrations MUST operate on an isolated raw-document copy, MUST NOT mutate
  the storage-owned Session lock or the Version provider's `PreviousVersion`
  checkpoint, and MUST produce a DataStore-safe document within the
  controller's serialized-size limit. Any migration, checkpoint, downgrade,
  or output validation failure MUST abort load before provider runtime is
  changed and attempt to release the acquired session lock; a release failure
  MUST be surfaced separately.
- A replacement document returned by a migration controller MUST be validated
  as DataStore-safe before the pipeline copies it for isolation, so cyclic or
  otherwise unsafe controller-owned tables fail with a bounded migration
  diagnostic instead of entering a recursive copy.
- A migration chain that requires a checkpoint commit MUST revalidate session
  lock ownership after raw transformation and before provider application.
  After successful application, the Version provider MUST be queued
  synchronously for dirty capture before load success is published; no save
  may persist transformed provider data with the old checkpoint.
- An empty new profile without a Version provider starts at the current
  version only when storage explicitly reports that it created the profile;
  an empty `Providers` table alone MUST NOT be used to infer newness. An
  existing pre-checkpoint profile MUST fail closed unless the project
  explicitly configures its known legacy baseline version. With that baseline,
  migrations MAY rebuild a missing legacy `Providers` root, but the final raw
  result MUST contain a string-keyed provider dictionary before application.
- Session-lock refresh and pre-save release MUST preserve the storage-owned
  new-profile acquisition marker until the first successful profile save
  removes it. Release MUST remove active lock ownership while allowing the
  pending new profile to be reacquired immediately. A crash after a refresh or
  cancellation before the first save MUST still classify the document as new.
- The Version checkpoint MUST advance only after the complete migration chain
  and atomic provider application succeed, so an unpersisted chain is retried
  from its stored version.
- Released migration controllers MUST remain durable compatibility code while
  retained production profiles may still require them. Correct a released
  transform with a later migration instead of rewriting its historical input
  contract.

## Authority rules

- Server-authority providers MUST ignore client dirty events.
- Unknown, server-authority, or invalid client patch providers MUST be rejected and logged.
- Client and server provider implementations remain separate.

## Forbidden patterns

- MUST NOT add `GlobalSave` or another layer name inside `SaveModule`.
- MUST NOT store domain runtime tables in a save controller.
- MUST NOT save on every domain mutation or every Heartbeat.
- MUST NOT replace client runtime models with full tables for ordinary gameplay changes.
- MUST NOT call Stop before capturing closing data.
- MUST NOT weaken validation to make corrupted data load.

## Positive example

```lua
local controller = saveModule:BuildSaveController("session_save")
	:WithStorage(storage)
	:WithKeyResolver(resolveKey)
	:WithSaveProvider(inventoryModule)
	:Build()
```

## Negative example

```lua
function SaveModule:LoadGlobalPlayer(player)
	self._domainData[player] = data
end
```

This couples the generic registry to a concrete layer and steals domain ownership.

## Verification

- `SystemTestRunner`.
- `ProductionIntegrationTestRunner`, including rollback, lock contention, retry/deadline, and shutdown tests.
- Opt-in `RealDataStoreSmokeTest` only in a published dedicated test place with API access.
