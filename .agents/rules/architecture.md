# Architecture rules

## Scope

Apply to new modules, cross-module changes, dependency ownership, public APIs, runtime responsibility, and changes spanning server/client/shared code.

Required context: `docs/InitializationAndSaveSystem.md` and, for architectural
changes, `docs/adr/README.md` plus relevant Accepted template and project ADRs
routed there.

## Intent

Keep systems independently testable, explicitly composed, and owned by the module responsible for their runtime behavior.

## Mandatory rules

- A module MUST own its runtime state and domain behavior.
- Cross-system dependencies MUST be passed explicitly through constructors, commands, or the initialization context.
- Shared modules MUST contain side-neutral contracts, configuration, serialization, or pure behavior.
- Server-authoritative behavior MUST remain on the server.
- Client modules MAY cache replicated state and own presentation state, but MUST NOT become the authority for server data.
- Public lifecycle methods MUST be idempotent where repeated calls are expected.
- A new long-lived module MUST be registered through the appropriate initialization manifest.
- Side-specific implementations of the same contract SHOULD remain separate when their data or authority behavior differs.
- Architectural changes MUST update relevant documentation and enforcement tests.
- A durable decision that constrains multiple modules or rejects plausible
  alternatives MUST be captured in a new ADR.
- Reversing an Accepted ADR MUST be expressed by a new superseding ADR; the old
  record remains intact.

## Forbidden patterns

- MUST NOT add standalone startup Scripts or LocalScripts for individual modules.
- MUST NOT use `_G`, shared mutable module globals, or ad-hoc folders as dependency injection.
- MUST NOT move domain runtime state into save controllers, communication
  modules, presentation modules, or initialization commands.
- MUST NOT make shared code require server-only or client-only containers.
- MUST NOT introduce a generic service locator to avoid explicit dependencies.
- MUST NOT duplicate a platform lifecycle subscription already centralized by a project wrapper.
- MUST NOT rewrite an Accepted ADR to conceal or retroactively change its
  original decision.

## Integration procedure

For a new subsystem:

1. Define its authority and runtime-state owner.
2. Place shared contracts/configuration under `ReplicatedStorage/Shared` only if both sides need them.
3. Create separate server/client modules when behavior differs.
4. Inject dependencies through constructors.
5. Add explicit initialization commands and manifest entries.
6. Add the service to `context.Services` only when downstream commands require it.
7. Add focused tests and update the rules index if this is a new architectural category.
8. Create or supersede an ADR when the change establishes a durable
   cross-module decision, then link its enforcement rules and tests.

## Positive example

```lua
local module = InventoryModule.new(communication, playersModule)
local command = InventoryInitializationCommand.new(module)
```

The manifest owns composition and ordering; `InventoryModule` owns inventory runtime state.

## Audio playback architecture

- Audio startup is owned by one protected `AudioStartup` command after
  `Assets`; manifests inject roots and constants but MUST NOT require raw audio
  configs in constructor phase.
- `AudioGraph` is one manifest-owned generation. The server publishes one
  validated `ReplicatedStorage.AudioRuntime`; clients bind the exact complete
  generation and own only local listener/output/settings edges.
- Disabled audio owns no pools, graph, preload, or playback, but exact hybrid
  handlers remain registered after `Communication` and reject/no-op before
  `ClientReady` as required by ADR-0041.
- Ordinary and Music remain separate runtime owners. Shared catalog/config
  models do not imply shared pools, public APIs, cleanup, or network state.
- Read `.agents/rules/audio.md` and ADR-0039, ADR-0040, and ADR-0041 for any
  audio architecture change.

## Negative example

```lua
task.spawn(function()
	require(game.ServerScriptService.Modules.Inventory):Initialize()
end)
```

This hides startup order, bypasses the manifest, and creates an independent entry point.

## Verification

- Rojo build.
- Clean server/client bootstrap when composition changes.
- Unit tests for the module contract.
- Production integration tests for cross-system failure behavior.
