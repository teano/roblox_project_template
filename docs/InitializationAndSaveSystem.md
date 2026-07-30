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

`CommunicationModule` handles ordinary runtime messages through RemoteEvents. It batches messages once per Heartbeat, caps batch and queue sizes by both count and estimated bytes, validates envelopes, applies message/byte rate limits, and sequences each direction.

Outgoing messages declare `Critical`, `State`, or `Presentation` priority. On pressure, the server evicts the oldest presentation messages first. If state still cannot fit, the queue collapses to one `ResyncRequired` message and refuses further state until a snapshot starts. Every server snapshot increments a communication epoch; late packets from an older epoch are ignored instead of causing a resync loop. A current-epoch sequence gap or handler failure requests a full snapshot.

Communication serialization is separate from DataStore serialization. It allows safe Roblox value types such as `Vector3` and `CFrame`, while rejecting `Instance`, cyclic tables, non-finite numbers, oversized messages, and overlong request IDs.

The communication module also owns one bounded synchronous request
RemoteFunction for server-read startup boundaries such as the client config
bundle. Registered request handlers validate input and enforce request,
response, rate, and byte limits. It is not used for ordinary gameplay
mutations or notifications.

Normal gameplay does not replace whole provider tables. Server-authoritative
modules emit small operation/change messages, preserving client runtime object
identity. Client-authority providers may send dirty mementos; unknown,
server-authority, or invalid providers are rejected and logged.

## Player lifecycle

`PlayersModule` is the single wrapper around Roblox `Players`. It owns player and character signals. The global save command subscribes to it for load and close; gameplay modules consume the same wrapper instead of independently scattering `Players` event subscriptions.

## Loading screen

`ReplicatedFirst/Loading.client.luau` removes the default screen, displays initialization progress, and fades only after `ClientInitialized=true`. A failed bootstrap leaves a visible rejoin message.

## Tests

In Studio Play mode:

```lua
require(game.ServerScriptService.Tests.SystemTestRunner).runAll()
require(game.ServerScriptService.Tests.ProductionIntegrationTestRunner).runAll()
```

The production integration suite injects failures and verifies complete server/client rollback, lock contention and stale takeover, bounded retry, expired deadlines, shutdown concurrency, packet loss, stale epochs, serialization and queue overflow. `RealDataStoreSmokeTest` is intentionally opt-in because Roblox requires a published place with Studio API access. It creates a fresh 42-character `Smoke_<GUID>` key only in `PlayerData_IntegrationTests_v1`, writes data, releases the session lock, reloads and verifies the data, then removes the key. A run passes only when both `Ok` and `CleanupOk` are true. See [IntegrationTesting.md](IntegrationTesting.md) for the required environment setup order.
