# Initialization and Save System

## Initialization

`Shared/Initialization/InitializationRunner` executes an explicit manifest sequentially. Every command declares:

```lua
{
  Id = "GlobalSave",
  DependsOn = { "DomainData", "Teleport", "Statistics" },
  Initialize = function(self, context) ... end,
}
```

Dependencies are validation constraints: each referenced command must exist earlier in the manifest. A command failure stops the bootstrap and returns the same cached failure to every later `Initialize` call. Concurrent calls wait for the active run; a completed runner is idempotent.

A command taking longer than 30 seconds emits a watchdog error but is not cancelled. A module that intentionally starts background work owns that policy itself and may let its command complete immediately.

Server order:

```text
Assets → Pooling → Players → Communication → Teleport → TeleportValidationPad → Config → Statistics
       → Save → Migration → DomainData → GlobalSave → PersistenceSchedule
```

Client order:

```text
Assets → StartupContentPreload → Pooling → Players → Communication → Statistics
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

### TF-0005 audio composition contract

The audio implementation extends the relative order without adding a second
runner:

```text
Server: Assets -> AudioStartup -> Pooling -> Players -> Communication
        -> AudioGraph -> OrdinarySound

Client: Assets -> AudioStartup -> StartupContentPreload -> Pooling -> Players
        -> Communication -> AudioGraph -> OrdinarySound -> Music
```

Manifest constructors pass roots and exact module names; only protected
`AudioStartup.Initialize` resolves/requires the four raw audio modules and
publishes immutable enabled/disabled state. Enabled and disabled hybrid
handlers register after `Communication` and before `ClientReady`. Disabled
handlers reject/no-op with `AudioDisabled` while owning no pools, graph,
preload, or playback. See [AudioSystem.md](AudioSystem.md) and
[ADR-0041](adr/template/0041-protect-audio-startup-and-keep-disabled-transport-handlers.md).

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
2. Statistics
3. Version

Projects insert additional ordinary domain providers before Version on both
server and client. Version remains last because its `Run` is the commit point
that advances the persisted game-version checkpoint only after every other
provider has installed and started successfully.

TF-0005 adds client-authority `AudioSettings` before `Version` and introduces
optional provider-specific controller hooks. Server `ValidateEnvelope` receives
`(player, envelope)`; client `ValidateEnvelope` receives `(envelope)`. Both
return only acceptance plus an optional reason, never sanitize input, and fail
closed before mutation on false or exception. The AudioSettings client also
implements `ReconcileSnapshotEnvelope(envelope?)`: a missing provider or
missing known data fields receive defaults, while unknown/invalid present data
is rejected. Present envelope validation runs before reconciliation, and the
returned envelope is validated again before `ValidateMemento`. Providers
without these hooks keep the existing mandatory-envelope behavior.

`wallet_config` supplies the one-time starting balances for a newly created
Wallet provider. Wallet memento version 3 persists `IsInitialized` and the
server-only `LastTransactionSequence`; versions 1 and 2 reconcile without
changing balances or replaying startup grants.

`Statistics` is a server-authoritative provider omitted from every client save
snapshot. It owns bounded Global, Teleport Session, Place, and configured
custom statistic snapshots. Its required native-JSON `statistics_config`
supplies snapshot types, retention, filters, projections, storage limits, and
the requested-save cooldown. Current built-in client reads use a separate
deny-by-default projection. See [Statistics.md](Statistics.md).

`global_save_config` supplies the autosave interval, server snapshot-load
timeout, and bounded client snapshot retry policy. The client receives only
the two retry fields through the approved config bundle. All three required
native-JSON Experience Config values -- `wallet_config`, `statistics_config`,
and `global_save_config` -- are validated and frozen before `DomainData` or
`GlobalSave` starts.

This ordered provider collection is the player profile. The template does not
add a monolithic `ProfileModule`: projects extend the profile by registering
their own domain providers in both server and client commands.

A future session or game-slot controller can be built independently and
removed through `SaveModule:RemoveSaveController`. The server composition
registers a synchronous removal callback that unregisters the controller from
both `AutoSaveModule` and `SessionLockModule` only after terminal provider
cleanup and server lock release succeed. A failed single or bulk removal
retains the controller in all three registries, keeps retry scheduling and
signals owned, and can be retried after the cleanup failure is resolved.
Successful unregistration is idempotent and clears periodic autosave and lock
refresh scheduling, pending requested saves, per-player state, and the
controller's `PlayerClosed` connection. Session-lock registration is
identity-based, so rebuilding a removed controller installs exactly one live
scheduler entry and an already registered controller cannot be appended twice.
String-ID removal intentionally addresses the current registry member. The
controller-object form instead requires exact object identity, so a stale
reference cannot remove or tear down a same-ID replacement on either side.

On the client, `SaveModule` owns one `Save.ClientPatchResult` communication
handler for its VM lifetime. Result envelopes carry `ControllerId`; the module
resolves that ID against its live registry and then forwards the response to
the matching controller, whose request ID gate rejects stale responses. A
failed controller destroy retains that route for cleanup retry, while a
successful removal revokes it. Rebuilding the ID therefore cannot retain an
old controller closure, and multiple controller identities neither duplicate
the fixed communication handler nor receive one another's patch results.

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

Statistics treats an installed Global/Session/Place set that already matches
the current trusted Teleport session and current PlaceId as lifecycle-ready.
The save transaction marks its internal `Stop`/`SetMemento`/`Run` restart
explicitly, which makes snapshot application and rollback an exact resume with
no Session/Place replacement, dirty mark, or lifecycle event. An identical
memento installed by a cold load is not marked as a restart; cold load, closed
handoff state, or mismatched trusted session/place therefore still performs
the normal lifecycle resolution before load success.

Target mementos are reconciled and validated before runtime mutation. Current mementos are then captured before `Stop`. If any target `SetMemento` or `Run` fails, all partially installed providers are stopped and the complete previous memento set is restored before any provider is run again. A controller remains `Loaded` only when rollback fully succeeds; a cleanup or rollback failure moves it to `ApplyFailed`. Provider `Stop` must therefore be idempotent and safe after `SetMemento`, even if `Run` did not complete.

The server reserves one generation-scoped lifecycle operation across the full
yieldable `Load`, `ApplyMemento`, `ForceSave`, `Close`, Heartbeat capture,
`FlushDirty`, or `BuildSnapshot` sequence. Snapshot projection remains inside
the same operation. Every resumed provider hook and storage acknowledgement
verifies that it still owns the same runtime and generation before changing
dirty maps, the document/revision, persistence acknowledgement, lifecycle
state, or ownership. A replacement therefore cannot start under any older
capture/save/close, and an older continuation cannot overwrite replacement
state, release the lock, or remove the runtime.

Both save controllers track each provider that may have started independently
of the aggregate `Running`/ready flag. A `Run` attempt is tracked before the
call and is cleared only after a successful `Stop`. Terminal server close and
client destroy reverse-stop that tracked set even after failed transaction
cleanup or rollback. The server retains the runtime and session lock when a
terminal provider stop fails, so provider work is never knowingly orphaned
after lock release or runtime removal. Storage-release failure also retains the
runtime and controller for retry. Server/client controller destruction reports
explicit success only after this cleanup completes; registry removal is
conditional on that result.

A retained server runtime in `CloseFailed` is not gameplay-ready and cannot
capture, snapshot, patch, or save provider state. It does, however, retain one
narrow session-lock heartbeat responsibility while terminal cleanup remains
retryable. `ShouldRefreshLock` exposes that exact scheduler predicate: a normal
`Loaded` runtime is eligible only before close is requested, and a
`CloseFailed` runtime is eligible only while that close request still owns the
retained runtime. `RefreshLock` reserves the same generation-scoped lifecycle
operation as save and close, validates runtime/state ownership after the
storage yield, and updates its monotonic refresh timestamp only while that
ownership remains current. A concurrent close therefore waits behind an
already-started refresh; a later refresh cannot enter an active close; Stop or
Release failure resumes only heartbeat ownership; and successful Release plus
runtime removal makes all later scheduler observations no-ops. If storage
authoritatively reports `LockLost` or `NoSessionLock`, the controller clears
the retry-retained heartbeat flag without reopening the runtime: terminal
provider cleanup may still be retried, but gameplay/save work and further
heartbeat scheduling remain fail-closed.

The scheduler discovers these owners from each registered controller rather
than from the live `Players:GetPlayers()` collection. A player that has already
crossed the real removal boundary therefore remains discoverable while its
runtime still owns a lock or retryable terminal cleanup. Every enumerated owner
carries its opaque runtime identity back into the refresh/retry rechecks. The
scheduler refreshes a retained lock before cleanup and makes at most three
automatic cleanup attempts; exhaustion leaves the runtime as a fail-closed
terminal owner for explicit diagnosis rather than reopening gameplay or
silently abandoning the runtime. Successful release removes the owner, so no
later scheduler cycle can refresh it.

Cleanup attempt ownership is keyed by the registered controller plus that
opaque runtime identity, never by `Player`. Exhausting an older runtime's
three-attempt budget therefore cannot debit a same-UserId replacement. A late
result clears or updates only its originating runtime; reload and controller
unregistration discard the stale budget without touching the replacement.
The scheduler revalidates the exact registered entry after every controller
or logger yield and before retry counters, diagnostics, retry, or fail-closed
finalization. A yielded third attempt from an unregistered controller is
therefore discarded, while a rebuilt entry receives a fresh full budget.

The Global controller also owns one injected, provider-agnostic close-
preparation callback. Production composition binds it to
`StatisticsModule:PrepareForProfileClose`, so player removal and shutdown enter
the same generation-scoped Close reservation before preparation can yield or
fail. A preparation failure retains the runtime, pending save intent, and lock
heartbeat while rejecting gameplay. Statistics failures are retryable because
the rejected candidate never mutates provider data and is not memoized. After
three unsuccessful automatic preparation retries, the scheduler performs one
explicit fail-closed finalization that saves the still-valid current memento
before Stop/Release; shutdown performs the same bounded handoff. Ordinary save
failure never takes this fallback and remains no-loss/fail-closed.
Shutdown snapshots an identity-deduplicated union of live players and exact
controller-retained runtime owners before the heartbeat scheduler stops. The
same worker that owns a player close also owns its bounded preparation retry
and optional finalization under one absolute deadline, so departed retained
owners cannot disappear merely because the live `Players` enumeration is
empty.

Close failures before provider stop are failure-atomic. A deadline while
waiting for Saving, Capturing, Snapshotting, Applying, or any other current
lifecycle reservation withdraws only the same runtime/request/generation close
owner and reopens normal mutation and refresh ownership regardless of the
transient state observed at request time. Completion or failure of the
yieldable operation then restores `Loaded`, and a later close remains valid.
Capture failure or any unsuccessful save result—including deadline,
serialization, size, retry exhaustion, storage loss, and unexpected exception
codes—instead enters retry-retained `CloseFailed`, preserves whether the close
still requires a save, and never reaches provider Stop or storage Release.
Owned locks keep the guarded heartbeat; authoritative `LockLost`/
`NoSessionLock` stays fail-closed without claiming a heartbeat. Gameplay/save
mutation remains rejected until a later close retry completes. This prevents
both unsaved release and the contradictory `Loaded + CloseRequested` state.
A deadline close that waits behind a retained-owner refresh restores the exact
pre-existing close/save/preparation/heartbeat flags under the same runtime,
close-token, and operation generation; it cannot withdraw another cleanup
owner. Public provider mutation is separately admitted by the controller.
Wallet rejects `Add`, `TrySpend`, and zero-delta calls while terminal cleanup
is retained, without changing balance, transaction sequence, signals, or
queued client state, while provider capture remains available for retry.

After reconciliation and default creation, the server validates and measures
the complete prepared persistence document before `Stop`, `SetMemento`, or
`Run`. Unsafe or oversized prepared state therefore aborts initial load and
releases its lock, or leaves an already loaded runtime unchanged; the game
never publishes a snapshot that is already impossible to persist.

When the prepared provider envelope differs from the stored envelope because
of default creation, version reconciliation, or safe policy reconciliation,
the controller advances the document revision and keeps it dirty. The next
save therefore persists the prepared generation instead of leaving a
runtime-only reconciliation that would repeat or disappear on reload.

`MementoChanged` only marks a provider dirty. The controller captures dirty
mementos on Heartbeat, but it does not write to DataStore every frame. An
identical capture does not advance document revision. Close performs one full
provider capture before persistence so a valid final change is not dependent
on a prior dirty signal.

## Persistence

Production storage uses:

- DataStore `PlayerData_v1`;
- `UpdateAsync`;
- bounded exponential retry with jitter;
- session lock heartbeat every 5 minutes;
- stale-lock takeover after 30 minutes;
- dirty-only autosave, staggered at the validated
  `global_save_config.autoSaveIntervalSeconds`;
- per-controller/player requested saves coalesced behind a configured cooldown;
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

Client-authority patches participate in the same generation-scoped lifecycle
reservation. Provider envelope validation, memento validation, and provider
application may yield, so the controller rechecks runtime identity and open
authority after each boundary. Close requests wait for an already-started
patch, later patches cannot enter closing state, and a patch that observes a
close request returns no accepted-provider acknowledgement. If a provider had
already mutated before yielding, the waiting close captures that state before
save/release rather than leaving an unowned mutation.

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
Storage acknowledgements are accepted only when the adapter returns a table
whose `Ok` field is a boolean. Any malformed truthy result becomes stable
`SaveFailed`; providers stay running, the lock stays owned, and Stop/Release
remain unreachable until a valid retry.

Shutdown uses a shared 20-second deadline and at most four concurrent close
workers. The deadline is propagated through preparation, capture, save,
provider stop, lock release, retained retry, and finalization. No stage or
retry begins at or after expiration, and retries remain inside their owning
worker rather than escaping the concurrency cap. An already executing Roblox
`UpdateAsync` cannot be force-cancelled, so the coordinator returns an
immutable result snapshot at the global deadline and reports unfinished
players instead of serially consuming the entire shutdown window.

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
