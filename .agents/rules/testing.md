# Testing and verification rules

## Scope

Apply to every source change and all test code.

## General rules

- Tests MUST assert intended public contracts, not private implementation details.
- A failing contract test MUST NOT be weakened to match a bug.
- Use fresh module instances and injected fakes for stateful dependencies.
- Deterministic suites MUST NOT depend on real DataStore, external players, random timing, or network availability.
- Test runners remain ModuleScripts invoked manually in Studio Play; do not add auto-running test Scripts.
- Add a regression test for every fixed production defect when the behavior is testable.
- Tests must clean up Instances, connections, controllers, locks, and temporary state they create.

## Required static check

After any source or Rojo mapping change:

```powershell
rojo build default.project.json --output $env:TEMP\roblox-template-validation.rbxlx
```

Do not write validation builds into the repository.

## Studio suites

Run in Play mode from the server:

```lua
require(game.ServerScriptService.Tests.SystemTestRunner).runAll()
require(game.ServerScriptService.Tests.ProductionIntegrationTestRunner).runAll()
```

Expected: every result has `failed = 0`.

## Change-to-suite mapping

| Change | Required suites/checks |
|---|---|
| Initialization, manifests, module composition | System + clean server/client bootstrap |
| Save, providers, storage, locks, autosave, shutdown | System + Production |
| Communication, DTO, serializer, remotes, resync | Production + clean client/server Play |
| Wallet, Version, GameData, or another provider | System + Production |
| Project-specific gameplay or presentation | Its focused suite plus Production when communication or persistence is involved |
| Players lifecycle | System + Production + join/leave/respawn Play checks |
| Rojo mapping or executable placement | Rojo build + clean bootstrap |

## Real DataStore

`RealDataStoreSmokeTest` is opt-in only:

- use a published dedicated test place;
- enable Studio API access;
- use `PlayerData_IntegrationTests_v1`, never the production store;
- use a GUID key;
- remove the test key afterward;
- report cleanup failure explicitly.

Do not run this test merely because DataStore code changed when the environment is not explicitly safe.

## Output inspection

For startup/network/save changes, inspect server and client console output. Treat unexpected errors and warnings as failures. Distinguish unrelated place-local Scripts from project source, remove obsolete test objects instead of creating compatibility objects that hide their errors, and rerun from a fresh Play session to clear ModuleScript cache.
