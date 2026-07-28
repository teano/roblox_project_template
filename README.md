# Roblox Template Project

Production-oriented foundation for modular Roblox games built with
[Rojo](https://rojo.space/). The repository contains reusable infrastructure,
one working Wallet provider, tests, architecture documentation, agent rules,
and architecture decision records.

It deliberately contains no game-specific gameplay, map, HUD, VFX, SFX, or
third-party packages.

## Included systems

- Deterministic server and client initialization with explicit manifests,
  dependencies, sticky failures, idempotent results, and a non-cancelling
  30-second watchdog.
- A `ReplicatedFirst` loading screen that closes only after the complete client
  bootstrap and initial snapshot succeed.
- Centralized server/client wrappers around Roblox player and character
  lifecycle.
- Ordered RemoteEvent batching with validation, byte/count limits, rate
  limiting, priorities, sequence numbers, snapshot epochs, backpressure, and
  automatic resynchronization.
- Layer-independent save-controller registry and builders.
- Atomic provider snapshot application with rollback.
- DataStore persistence through `UpdateAsync`, bounded retry, serialized-size
  validation, session locking, autosave, player-exit save, and bounded shutdown.
- Version metadata and an empty migration registry ready for real released
  migrations.
- Server-authoritative Wallet with configurable currencies and compact client
  updates.
- Read-only client `GameDataClient` facade.
- Memory-backed Studio persistence and an opt-in real DataStore smoke test.
- Agent rules and ADRs that preserve the architecture while the template
  evolves.

## Non-goals

The template does not provide gameplay systems, UI, purchases, inventory,
analytics, VFX/SFX, matchmaking, or a generic service locator. Add those as
separate modules with explicit dependencies and initialization commands.

## Requirements

- Roblox Studio
- [Rokit](https://github.com/rojo-rbx/rokit), or a compatible installation of
  Rojo 7.7
- Rojo Studio plugin

Install the pinned toolchain:

```powershell
rokit install
```

## Quick start

1. Create a repository from this template.
2. Open the tracked `template_place.rbxl` in Roblox Studio.
3. Run `rojo serve default.project.json` and connect the Studio plugin.
4. Change the project name in `default.project.json`.
5. Review `VersionConfig.CurrentVersion`.
6. Choose the production DataStore name and persistence limits in
   `StorageConfig`.
7. Configure currencies and defaults in `WalletConfig`.

Use a Rojo build for validation or source-only inspection:

```powershell
rojo build default.project.json --output $env:TEMP\roblox-template-validation.rbxlx
```

Do not replace `template_place.rbxl` with that generated build: the build does
not contain Studio-authored scene data that lives only in the canonical place.
Publish a dedicated experience before enabling real DataStore testing.

## Hybrid Studio and Rojo workflow

The template currently uses partial Rojo synchronization. Both kinds of source
must be preserved:

| Source | Owns |
|---|---|
| `src/` and `default.project.json` | Rojo-managed scripts, Instances, mappings, and declared properties |
| `template_place.rbxl` | Studio-authored map, models, and other scene data not represented in Rojo source |

Filesystem-backed Rojo mappings use `$ignoreUnknownInstances: true`, so live
sync preserves Studio-authored children that are not present under `src`.
This is a safety boundary, not permission to keep code only in the place:
scripts and mapped properties must still be changed in text source.

Team workflow for scene changes:

1. Finish or commit unrelated work, then pull the latest branch before opening
   the place.
2. Coordinate with the team so only one person/branch edits
   `template_place.rbxl` at a time.
3. Make scene changes in Studio and save them to that exact file.
4. Commit the changed place together with any source that depends on it.
5. Never commit `template_place.rbxl.lock` or generated validation builds.

Git treats `.rbxl` as binary and cannot merge concurrent scene changes. If a
conflict occurs, keep one complete place version and manually replay the other
change in Studio. Team Create may be adopted later, but it must not silently
become a second source of truth while the tracked place is canonical.

## Architecture

There is one executable bootstrap per side:

```text
ServerScriptService/Bootstrap.server.luau
StarterPlayerScripts/Bootstrap.client.luau
```

Both use the shared `InitializationRunner`, while composition remains
side-specific.

Server initialization:

```text
Players → Communication → Save → DomainData → GlobalSave
        → PersistenceSchedule
```

Client initialization:

```text
Players → Communication → Save → DomainData → GlobalSave
```

The global player profile is an ordered composition of independent providers:

```text
Version → Wallet → project providers
```

`SaveModule` does not know what a global, session, or slot save means.
`GlobalSaveInitializationCommand` creates the current layer explicitly.
Projects can create additional controllers with different storage, provider
sets, keys, and lifetimes.

Detailed lifecycle and extension documentation:
[docs/InitializationAndSaveSystem.md](docs/InitializationAndSaveSystem.md).

## Repository layout

```text
src/
├── ReplicatedFirst/                  loading screen
├── ReplicatedStorage/
│   ├── Client/                       client implementations and manifest
│   └── Shared/                       side-neutral contracts and utilities
├── ServerScriptService/
│   ├── Initialization/               server manifest and commands
│   ├── Modules/                      server implementations
│   └── Tests/                        manual Studio test runners
└── StarterPlayerScripts/             client bootstrap
docs/
├── adr/                              architecture decision records
└── InitializationAndSaveSystem.md
.agents/rules/                        mandatory project editing rules
```

## Adding a module

1. Decide which side owns authority and runtime state.
2. Put only side-neutral contracts/configuration under
   `ReplicatedStorage/Shared`.
3. Inject dependencies through the module constructor.
4. Create a focused server and/or client initialization command.
5. Declare real dependencies and add the command to the explicit manifest.
6. Expose the module through `context.Services` only when later commands need
   it.
7. Add focused tests and update documentation/rules when the public
   architecture changes.

Modules do not self-start and must not add standalone bootstrap Scripts.

## Adding profile data

Do not add fields to one global mutable profile table. Create a domain module
that owns its runtime state and implements the save-provider lifecycle:

```text
CreateDefault
ReconcileMemento
ValidateMemento
SetMemento
GetMemento
BeforeMementoGet
Run
Stop
ToClientMemento
MementoChanged
```

Give the provider a stable `Id`, `Version`, and `Authority`. Register it in the
same intentional order in the server and client global-save commands. Add it to
`GameDataClient` only when the client is allowed to read it.

Snapshot replacement validates all providers before mutation, captures the
current state, stops in reverse order, installs and runs in forward order, and
restores the complete previous state if installation fails.

## Communication

Normal runtime synchronization uses compact semantic messages:

```lua
communication:Queue(player, "Inventory.ItemAdded", payload, requestId, {
	Priority = CommunicationProtocol.Priorities.State,
})
```

Register and validate every client-originated message on the server before
mutating domain state. Do not send full provider tables for small changes and
do not create direct gameplay remotes beside the communication module.

The full snapshot RemoteFunction is reserved for initial load and explicit
resynchronization. Runtime communication and DataStore serialization use
separate validators.

## Wallet

`WalletModule` is server-authoritative. The client receives ordered compact
changes but never sends balances. Purchase modules should send an intention to
the server, validate the transaction there, and call:

```lua
walletModule:Add(player, "Coins", amount, reason, metadata)
walletModule:TrySpend(player, "Coins", price, reason, metadata)
```

Customize supported currency IDs and default balances in
`ReplicatedStorage/Shared/Wallet/WalletConfig.luau`.

## Persistence configuration

Production defaults live in
`ServerScriptService/Modules/Storage/StorageConfig.luau`.

Studio uses `MemoryStorage` by default, so normal Play sessions do not touch
DataStore. Production uses `DataStoreStorage` wrapped by
`SessionLockingStorage`. Autosave targets dirty controllers every 60 seconds;
exit and shutdown paths save explicitly.

Do not run the real DataStore smoke test against a production place or store.

## Tests

Build validation:

```powershell
rojo build default.project.json --output $env:TEMP\roblox-template-validation.rbxlx
```

Run deterministic suites in Studio Play mode from the server command bar:

```lua
require(game.ServerScriptService.Tests.SystemTestRunner).runAll()
require(game.ServerScriptService.Tests.ProductionIntegrationTestRunner).runAll()
```

Every returned result must have `failed = 0`.

The opt-in smoke test requires a published dedicated test place with Studio API
access:

```lua
require(game.ServerScriptService.Tests.RealDataStoreSmokeTest).run()
```

It writes a GUID key only to `PlayerData_IntegrationTests_v1` and attempts to
remove it afterward.

## Project governance

- [AGENTS.md](AGENTS.md) is the mandatory entry point for coding agents.
- [.agents/rules/index.md](.agents/rules/index.md) routes changes to focused
  positive and negative implementation rules.
- [docs/adr/README.md](docs/adr/README.md) indexes durable architectural
  decisions and rejected alternatives.

Rules describe how the project must be changed. ADRs preserve why lasting
decisions were made. Current runtime behavior belongs in system documentation
and tests.

## License

Source code and documentation are available under the [MIT License](LICENSE).
Only add assets that you own or are allowed to redistribute under compatible
terms.
