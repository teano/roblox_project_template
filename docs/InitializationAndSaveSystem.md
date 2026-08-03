# Initialization and Save System

## Initialization

`Shared/Initialization/InitializationRunner` executes an explicit manifest sequentially. Every command declares:

```lua
{
  Id = "GlobalSave",
  DependsOn = { "DomainData" },
  Initialize = function(self, context) ... end,
}
```

Dependencies are validation constraints: each referenced command must exist earlier in the manifest. A command failure stops the bootstrap and returns the same cached failure to every later `Initialize` call. Concurrent calls wait for the active run; a completed runner is idempotent.

A command taking longer than 30 seconds emits a watchdog error but is not cancelled. A module that intentionally starts background work owns that policy itself and may let its command complete immediately.

Server order:

```text
Assets → Pooling → Players → Communication → Teleport → TeleportValidationPad → Config → Save → Migration
       → DomainData → GlobalSave → PersistenceSchedule
```

Client order:

```text
Assets → StartupContentPreload → Pooling → Players → Communication
       → Teleport → Config → Save → DomainData → GlobalSave
```

`Config` loads one server-owned Experience Config snapshot, decodes every
explicit definition into an atomic immutable generation, and serves only
code-approved client projections through named bundles. The client decodes its
bootstrap bundle into a separate immutable generation before domain
initialization. See [ExperienceConfiguration.md](ExperienceConfiguration.md).

`Assets` builds an immutable side-owned catalog from explicit roots before
game systems consume static templates. The server indexes `Shared` and
`Server`; each client indexes `Shared` and `Client`. It discovers no startup
commands and does not scan runtime hierarchies. See
[AssetRegistry.md](AssetRegistry.md).

`StartupContentPreload` uses the client-owned `ContentPreloader` to select
catalog entries tagged `Preload` and route them through the injected Roblox
`ContentProvider`. The request completes before `ClientInitialized`; delivery
failures are logged under the best-effort startup policy. All production
preloading uses this module instead of calling `ContentProvider:PreloadAsync()`
directly. See
[ContentPreloading.md](ContentPreloading.md).

`Pooling` constructs no concrete pools during bootstrap. It initializes a
side-owned registry exposed as `context.Services.Pooling`; project modules
register their homogeneous pools explicitly through composition. The server
and every client therefore own separate pool state while sharing the same
side-neutral algorithm. See [ResourceManagement.md](ResourceManagement.md).

To add a system, create a side-specific command, declare its dependency, and place it in that side's manifest. Modules expose `Initialize`; they do not decide their global launch order.

`Teleport` establishes server-owned per-player session continuity and the
client read-only lifecycle projection after `Players` and `Communication` are
ready. Its client handlers are registered during manifest construction before
the bounded bootstrap request. Platform acceptance and source removal never
stand in for target arrival. See [Teleport.md](Teleport.md).

`TeleportValidationPad` is a server-only, runtime-created operator surface
after `Teleport`. `TeleportValidationConfig` is injected by the server manifest
and is disabled by default. A disabled, invalid, incomplete, inherited, or
current-DataModel-mismatched configuration returns from initialization before
it observes players or mutates `Workspace`. When explicitly enabled with one
exact GameId, directed PlaceId routes, and a tester allowlist, it observes
players through `PlayersModule`, batches the initial enumeration, and assigns
the single runtime pad to the lowest present allowlisted UserId independently
of observer order. The outer config must be an exact plain four-field
dictionary. The controller calls only the public Teleport service; it does not
widen `TeleportPolicy` and adds no startup Script, RemoteEvent, or canonical
scene object. The complete temporary enable/publish/E2E/disable procedure is
in [TeleportTesting.md](TeleportTesting.md).

`GlobalSave` captures the complete Teleport client projection in the same
communication snapshot generation as provider state. The client validates the
Teleport baseline before mutating provider state, applies providers
transactionally, installs the prepared Teleport projection, and resumes the
epoch only after both have succeeded. Each successful Teleport installation
publishes `ProjectionReconciled` after the atomic replacement so subscribers
can re-read the complete projection. Runtime resync repeats this path.

## Save controllers and layers

`SaveModule` is only a registry/factory. It does not know what a “global”, “session”, or “slot” layer means. A project-specific command uses `SaveControllerBuilder` to choose:

- controller ID and lifetime;
- storage and key resolver;
- ordered save providers;
- serialized-size limit.

The current `global_save` controller is created by
`GlobalSaveInitializationCommand` and registers, in order:

1. Wallet
2. Version

Projects insert additional ordinary domain providers before Version on both
server and client. Version remains last because its `Run` is the commit point
that advances the persisted game-version checkpoint only after every other
provider has installed and started successfully.

`wallet_config` supplies the one-time starting balances for a newly created
Wallet provider. Wallet memento version 2 persists `IsInitialized`; version 1
wallets reconcile as already initialized so existing balances never receive
the startup grant again.

`global_save_config` supplies the autosave interval, server snapshot-load
timeout, and bounded client snapshot retry policy. The client receives only
the two retry fields through the approved config bundle. Both configs are
validated and frozen before `DomainData` or `GlobalSave` starts.

This ordered provider collection is the player profile. The template does not
add a monolithic `ProfileModule`: projects extend the profile by registering
their own domain providers in both server and client commands.

A future session or game-slot controller can be built independently and removed through `SaveModule:RemoveSaveController`.

## Provider lifecycle

Server providers are stateless contracts whose methods receive `player`. Domain modules own their per-player runtime models. Client and server providers are separate implementations because their authority and data behavior differ.

Replacing a snapshot is atomic from the runtime's perspective:

```text
Validate/reconcile all target mementos
  → capture current mementos
  → Stop providers (reverse order)
  → SetMemento providers (forward order)
  → Run providers (forward order)
```

`Run` means every provider's data has already been installed, so runtime controllers may now be constructed. Closing captures and saves before `Stop`, preventing runtime changes from being lost.

Target mementos are reconciled and validated before runtime mutation. Current mementos are then captured before `Stop`. If any target `SetMemento` or `Run` fails, all partially installed providers are stopped and the complete previous memento set is restored before any provider is run again. A controller remains `Loaded` only when rollback fully succeeds; a cleanup or rollback failure moves it to `ApplyFailed`. Provider `Stop` must therefore be idempotent and safe after `SetMemento`, even if `Run` did not complete.

After reconciliation and default creation, the server validates and measures
the complete prepared persistence document before `Stop`, `SetMemento`, or
`Run`. Unsafe or oversized prepared state therefore aborts initial load and
releases its lock, or leaves an already loaded runtime unchanged; the game
never publishes a snapshot that is already impossible to persist.

`MementoChanged` only marks a provider dirty. The controller captures dirty mementos on Heartbeat, but it does not write to DataStore every frame.

## Persistence

Production storage uses:

- DataStore `PlayerData_v1`;
- `UpdateAsync`;
- bounded exponential retry with jitter;
- session lock heartbeat every 5 minutes;
- stale-lock takeover after 30 minutes;
- dirty-only autosave, staggered at the validated
  `global_save_config.autoSaveIntervalSeconds`;
- save on player exit and server shutdown.

Dirty capture is atomic across the selected providers: if any capture or
validation fails, the complete dirty set remains available for retry. Calls
that join an active `ForceSave` receive that operation's actual success or
failure instead of synthesizing success after the waiter wakes. A provider
dirtied while the storage write yields remains pending; `ForceSave` captures
and persists that newer state before it reports a clean success.

Player close is also single-flight. A close that overlaps lock acquisition or
snapshot application waits for that transition instead of removing the runtime
under the active operation. If the player leaves while storage load is still
in flight, the acquired lock is released without applying provider state.
Overlapping player-removal and shutdown closes share one result and emit one
`PlayerClosed` notification.

Lock acquisition treats a live `SessionLocked` result as a possible
cross-server teleport handoff. Production retries it with bounded exponential
delays for up to eight attempts (9.75 seconds of configured delay) while the
source server completes close, save, and release. Player removal cancels the
wait; confirmed cancellation never applies provider state, and a lock acquired
concurrently with cancellation is released by the existing load/close
coordination. Exhaustion still fails closed and never weakens the 30-minute
stale-lock takeover threshold.

Session-lock ownership is verified from the final document returned by
`UpdateAsync`. This matters because Roblox may invoke the transform repeatedly
after concurrent writes; an earlier candidate can never establish local
ownership by itself. New-profile and stale-takeover classification is also
carried by the owned `Session` document. If an attempt commits but loses its
response, a retry of the complete `UpdateAsync` operation with the same lock
therefore preserves the final `Created`/takeover result instead of
misclassifying the profile from callback-local state. A stale takeover also
preserves `Created` when the previous owner crashed before the new profile's
first provider save. Lock refresh preserves the marker, and an early release
removes active ownership while leaving the pending profile immediately
reacquirable. The first successful provider save replaces the transient marker.

A stored value whose root is not a table is treated as corruption. Lock
acquisition fails without replacing it with an empty profile, preserving the
value for operator recovery instead of turning corruption into silent data
loss.

Before persistence, save documents must contain valid UTF-8 and DataStore-safe
JSON shapes: tables are either string-keyed dictionaries or dense arrays, and
mixed/sparse tables, metatables, cycles, unsupported values, and non-finite
numbers are rejected. The 3.5 MB soft limit uses the actual `JSONEncode` byte
count rather than a heuristic estimate.

Shutdown uses a shared 20-second deadline and at most four concurrent close workers. The deadline is propagated into save, lock release, and DataStore retry waits. No new retry begins after expiration. An already executing Roblox `UpdateAsync` cannot be force-cancelled, so the coordinator returns at the global deadline and reports unfinished players instead of serially consuming the entire shutdown window.

Studio uses the same controller and locking behavior over `MemoryStorage`.

## Raw-document migrations

`MigrationModule` is a server-only ordered raw-document transformer. It is
initialized after the generic `SaveModule` registry and before domain
providers and `GlobalSave`. A player's migration runs later, inside
`ServerSaveController:Load`, after `SessionLockingStorage` has acquired the
profile lock and before provider reconciliation or `SetMemento`.

This placement is the Roblox equivalent of running a local-game migration
module before the save module consumes data. It prevents two servers from
migrating one profile and preserves the existing atomic snapshot boundary.
Provider `ReconcileMemento` remains the right tool for a local provider-schema
upgrade; `MigrationModule` handles game-version transitions that may rename,
split, combine, or otherwise coordinate any number of raw provider envelopes.

Concrete controllers are registered explicitly in
`ServerScriptService/Modules/Migration/MigrationManifest`. Each controller
declares:

```lua
{
  Id = "WalletCurrencySplitV2",
  TargetVersion = "2.0.0",
  Order = 10,
  Migrate = function(self, document, context)
    -- Mutate the isolated document copy, or return a replacement document.
  end,
}
```

For a stored checkpoint `S` and current game version `C`, every registered
controller in `(S, C]` executes. Target versions are ascending; controllers
for one target execute by `Order`, then stable `Id`. The context reports the
preceding applied target as `SourceVersion`, so a user moving from `1.0.0` to
`4.0.0` receives the complete `2.0.0`, `3.0.0`, then `4.0.0` chain.

The module deep-copies the loaded document before the first controller,
rejects malformed or newer-than-server checkpoints, prevents controllers from
editing `Version.PreviousVersion` or the storage-owned `Session` lock, and
validates the final DataStore shape and encoded-size limit. An existing
profile without a Version provider fails closed unless
`MigrationManifest.LegacyBaselineVersion` explicitly identifies a real
pre-checkpoint schema. With that baseline, early controllers may normalize a
legacy document that has no current `Providers` root, but the final chain must
produce a string-keyed provider dictionary before application. Only a profile
explicitly reported as newly created by lock storage starts at the current
version with no providers; an existing empty provider table is not treated as
proof of newness.

An exception aborts the load before runtime mutation and the controller
attempts to release its session lock, surfacing a release failure separately.
The release boundary also contains storage exceptions and malformed release
results. During a load/close race it publishes the cancelled state even when
that first release fails, allowing the coordinated close operation to retry
release instead of waiting forever on a stuck `Loading` runtime.
For an older checkpoint, the controller also refreshes the lock after the raw
chain and before provider application, so a server that lost ownership during
a yielding transform cannot start runtime state. `VersionModule:Run` advances
the checkpoint only after the full chain and atomic provider application
succeed. The load path then queues Version synchronously for dirty capture
before publishing success, ensuring that no save can persist transformed
provider data with the old checkpoint. Until that atomic save succeeds, a
later join safely retries the chain from the stored checkpoint.

Controllers may perform arbitrarily complex cross-provider table
transformations and may receive dependencies through constructors, but they
must be deterministic, bounded, retry-safe, stateless, and reentrant because
one controller may migrate several players concurrently. No irreversible
external side effects should be coupled to a transform that can be replayed.
Registration snapshots the scheduling metadata and callable so later external
table mutation cannot change the active plan.

A controller-returned replacement is validated as a complete DataStore-safe
document before it is deep-copied for isolation. This makes cycles and other
unsafe table shapes a bounded, migration-attributed failure rather than an
uncontrolled recursive copy.

The template registers no concrete migration because its old saves were test
data. Add one only for a real released transition. The controller contract,
legacy-baseline policy, deployment checklist, and example are documented in
[UserDataMigrations.md](UserDataMigrations.md).

## Client synchronization

Initial state and resync use `GlobalSnapshot` RemoteFunction:

```text
register client handlers
  → request snapshot
  → server pauses/buffers outgoing messages
  → client Stop/SetMemento/Run
  → client sends ClientReady
  → server flushes buffered messages in order
```

`CommunicationModule` handles ordinary runtime messages through RemoteEvents.
It batches messages once per Heartbeat, caps batch and queue sizes by both count
and estimated bytes, validates envelopes, and sequences each direction.
Continuously refilled token buckets authoritatively limit server inbound
invocations/messages/bytes, cooperatively pace the client to those same
budgets, and shape per-player server outbound batches/estimated bytes. Budget
exhaustion leaves unsent queue entries and sequence numbers unchanged until a
later Heartbeat.

The shared `Signal` module never crosses the client/server boundary. It is used
only for side-local notifications before a message is queued or after a Roblox
remote has delivered it. See [Communication.md](Communication.md) for the full
transport contract.

Outgoing messages declare `Critical`, `State`, or `Presentation` priority. On pressure, the server evicts the oldest presentation messages first. If state still cannot fit, the queue collapses to one `ResyncRequired` message and refuses further state until a snapshot starts. Every server snapshot increments a communication epoch; late packets from an older epoch are ignored instead of causing a resync loop. A current-epoch sequence gap or handler failure requests a full snapshot.

Communication serialization is separate from DataStore serialization. It
allows safe Roblox value types such as `Vector3` and `CFrame` only when every
numeric component is finite. Tables must be either dense arrays or
string-keyed dictionaries; mixed and sparse tables are rejected together with
`Instance`, cycles, unsupported types, oversized messages, and overlong
identifiers. Inspection work and issue collection are explicitly bounded.

Server inbound invocation limits are charged before deep validation, so
malformed envelopes cannot bypass rate limiting. Validators and handlers run
behind protected boundaries; a failure is contained and moves the client to
snapshot recovery.

The communication module also owns one bounded synchronous request
RemoteFunction for server-read startup boundaries such as the client config
bundle. Registered request handlers validate input and enforce request,
response, rate, and byte limits. It is not used for ordinary gameplay
mutations or notifications.

Snapshot requests allow only one in-flight operation per player, enforce a
cooldown, and bound the complete response envelope with a network-specific
estimated-byte cap independent of the DataStore serialization limit. Snapshot
construction and network validation complete before `BeginSnapshot` changes
the epoch or clears buffered output. `ClientReady` carries the exact snapshot
communication epoch; a stale acknowledgement cannot release a newer buffered
queue. Applying a replacement snapshot also retires pending client-authority
patch correlation from the previous baseline.

Normal gameplay does not replace whole provider tables. Server-authoritative
modules emit small operation/change messages, preserving client runtime object
identity. Client-authority providers may send dirty mementos; unknown,
server-authority, or invalid providers are rejected and logged.

Wallet balances are non-negative safe integers capped by
`WalletConfig.MaxBalance` (`2^53 - 1`). Startup configuration, persisted
mementos, client snapshots, and incremental changes enforce the same bound;
an addition that would cross it returns `BalanceLimitExceeded` without
changing state.

While the client is paused for snapshot recovery, ordinary outbound messages
from the stale baseline are rejected and cannot be flushed. Normal queuing
resumes only after the replacement snapshot is applied.

## Player lifecycle

`PlayersModule` is the single wrapper around Roblox `Players`. It owns player and character signals. The global save command subscribes to it for load and close; gameplay modules consume the same wrapper instead of independently scattering `Players` event subscriptions. Existing-player enumeration rechecks membership before delivery, and per-observer membership is retired on removal even when the consumer does not need a removal callback.

These notifications, initialization completion, and provider
`MementoChanged` events use the shared side-local signal contract. Listener
yields do not block publishers or later listeners, and disconnected callbacks
are released immediately. See [Signal.md](Signal.md).

## Logging

Initialization, persistence, communication, configuration, and client loading
use the shared side-neutral Logger. It emits bounded one-line structured
records, treats `Error` as a non-throwing severity, and leaves persistence or
transport to an explicitly added consumer. See [Logger.md](Logger.md).

## Loading screen

`ReplicatedFirst/Loading.client.luau` removes the default screen, displays initialization progress, and fades only after `ClientInitialized=true`. A failed bootstrap leaves a visible rejoin message.

## Tests

In Studio Play mode:

```lua
require(game.ServerScriptService.Tests.AllTestsRunner).runAll()
```

The production integration suite injects failures and verifies complete
server/client rollback, lock contention and stale takeover, bounded retry,
expired deadlines, shutdown concurrency, packet loss, stale epochs,
serialization, token-bucket pacing, queue overflow, and snapshot network-cap
failure safety. `RealDataStoreSmokeTest` is intentionally opt-in because Roblox
requires a published place with Studio API access. It creates a fresh
42-character `Smoke_<GUID>` key only in
`PlayerData_IntegrationTests_v1`, writes data, releases the session lock,
reloads and verifies the data, then removes the key. A run passes only when
both `Ok` and `CleanupOk` are true. See
[IntegrationTesting.md](IntegrationTesting.md) for the required environment
setup order. Autosave and session-lock workers expose injected clock, wait,
spawn, and random dependencies so their due/not-due, failure, and stop
contracts are deterministic. The complete persistence contract matrix is in
[TestCoverage.md](TestCoverage.md).
