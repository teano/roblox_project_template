# Initialization rules

## Scope

Apply to `InitializationRunner`, server/client manifests, commands, bootstraps, loading completion, and startup dependencies.

Required context: `docs/InitializationAndSaveSystem.md`.

## Mandatory rules

- The server and client MUST keep separate manifests and bootstrap entry points.
- Both sides MUST use the shared `InitializationRunner`.
- Every command MUST declare a unique `Id`, explicit `DependsOn`, and `Initialize(context)`.
- Dependencies MUST appear earlier in the same manifest.
- Commands MUST execute sequentially through the runner.
- A command MUST NOT decide whether the global bootstrap continues after its failure; thrown errors stop the runner.
- Optional background initialization is owned by the specific module. Its command MAY return after deliberately starting background work.
- The 30-second watchdog logs slow commands but MUST NOT cancel them.
- Repeated runner initialization MUST share the active result and remain idempotent after completion.
- `ClientInitialized` MUST be set only after the complete client manifest, including initial snapshot application, succeeds.
- `ClientInitializationFailed` MUST be set when client bootstrap fails.

## Forbidden patterns

- MUST NOT add critical/deferred groups to the runner.
- MUST NOT initialize a module by requiring it from an unrelated Script.
- MUST NOT infer ordering from filesystem names, child order, tags, or discovery scanning.
- MUST NOT silently catch a command failure and report bootstrap success.
- MUST NOT start snapshot-dependent gameplay or presentation before the global
  snapshot is atomically applied.

## Adding a module

1. Construct the module in the side manifest.
2. Add it to the service table if another command needs it.
3. Create a focused initialization command.
4. Declare the minimum real dependency set.
5. Place the command after all declared dependencies.
6. Test manifest validation, bootstrap success, and failure behavior.

## Positive example

```lua
return setmetatable({
	Id = "Inventory",
	DependsOn = { "GlobalSave" },
	_module = inventoryModule,
}, Command)
```

## Negative example

```lua
script.Parent.Name = "07_Inventory"
require(script.Parent.InventoryModule):Initialize()
```

Filename ordering is not an initialization contract.

## Audio initialization

Audio manifests use the exact relative order and dependencies in the approved
technical specification: `Assets -> AudioStartup`, then preload/pooling/player/
communication owners before graph and playback. Raw audio ModuleScripts are
loaded only inside protected `AudioStartup.Initialize`. Enabled and disabled
hybrid handlers register after `Communication` and before `ClientReady`; a
disabled handler is a protocol-compatible no-op/reject boundary, not a second
bootstrap. See ADR-0041 and `.agents/rules/audio.md`.

## Verification

- `SystemTestRunner`.
- Clean Play session with complete server and client command logs.
- Loading screen disappears only after `ClientInitialized`.
