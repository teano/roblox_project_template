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
