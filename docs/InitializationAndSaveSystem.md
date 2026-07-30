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
Assets → Pooling → Players → Communication → Config → Save → DomainData
       → GlobalSave → PersistenceSchedule
```

Client order:

```text
Assets → StartupContentPreload → Pooling → Players → Communication
       → Config → Save → DomainData → GlobalSave
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

## Save controllers and layers

`SaveModule` is only a registry/factory. It does not know what a “global”, “session”, or “slot” layer means. A project-specific command uses `SaveControllerBuilder` to choose:

- controller ID and lifetime;
- storage and key resolver;
- ordered save providers;
- serialized-size limit.

The current `global_save` controller is created by
`GlobalSaveInitializationCommand` and registers, in order:

1. Version
2. Wallet

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

Session-lock ownership is verified from the final document returned by
`UpdateAsync`. This matters because Roblox may invoke the transform repeatedly
after concurrent writes; an earlier candidate can never establish local
ownership by itself.

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

Old saves were test data, so no legacy migration is registered. `MigrationModule` remains an empty extension point for a future version that actually needs a migration.

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
