# Testing and verification

## Principles

- Verify the public behavior that changed. Do not test private implementation
  details or duplicate runtime semantics with prose/token parsers.
- Add a focused regression for a production defect when the behavior is
  executable.
- Deterministic tests use fresh instances, injected clocks/schedulers/storage/
  transports, finite timeouts, and failure-safe cleanup.
- Do not weaken a failing contract test to match a bug.
- Unexpected server or client errors and warnings fail the relevant runtime
  gate. Expected diagnostics must be asserted or documented.
- Test runners remain ModuleScripts invoked manually in Studio Play; do not
  add auto-running test Scripts.

## Proportional gate

| Actual change | Required verification |
|---|---|
| Prose, rules, ADRs, or links only | link/reference scan, relevant documentation/tool check, `git diff --check`; no Rojo or Studio by default |
| Template init/update/feature tooling | focused PowerShell tool suite under Windows PowerShell 5.1 and PowerShell 7, bounded structural validator, `git diff --check` |
| Luau module with unchanged composition | temporary Rojo build and the smallest focused suite that owns the contract |
| Initialization manifests or bootstrap composition | temporary Rojo build, `SystemTestRunner`, aggregate suite, clean server/client bootstrap |
| Assets or startup preload | owning focused runner plus `SystemTestRunner`; clean bootstrap when startup composition changed |
| Pools or side-local signals | owning focused runner plus `SystemTestRunner`; clean Play only when Roblox resources or composition changed |
| Save, providers, storage, migrations, locks, autosave, shutdown | `SystemTestRunner`, `ProductionIntegrationTestRunner`, `ProductionReadinessTestRunner` |
| Communication, DTOs, remotes, sequencing, epochs, resync | `ProductionIntegrationTestRunner` and clean client/server Play |
| Experience Config transport/composition | `ConfigCatalogTestRunner`, `SystemTestRunner`; add Production and clean Play when transport/manifests changed |
| Players lifecycle | `SystemTestRunner`, `ProductionReadinessTestRunner`, join/leave/respawn Play checks |
| Teleport | checks in `teleport.md` and `docs/TeleportTesting.md` |
| Audio | focused and collaborative checks in `audio.md`, `docs/AudioSystem.md`, and `docs/AudioManualQA.md` |
| UI | `UiSystemTestRunner` plus only affected dependency suites; clean Play for runtime composition/input changes |
| Rojo mapping, executable placement, or canonical scene behavior | temporary Rojo build and clean bootstrap; add affected focused suites |
| Rojo server/preflight tooling | bounded structural validator and two consecutive `ensure-rojo-server.ps1` runs in an authorized environment |

Use a temporary output path for builds:

```powershell
rojo build default.project.json --output $env:TEMP\roblox-template-validation.rbxlx
```

Do not write validation builds into the repository. Generic structural
validation is for repository shape, identity, and small changed-path ownership
predicates; it must not scan unchanged runtime source or parse PRDs,
specifications, ignored `/tests`, Luau runners, or required prose tokens.

## Studio suites

From the server in Play mode:

```lua
require(game.ServerScriptService.Tests.AllTestsRunner).runAll()
```

Every aggregate and suite result must have `failed = 0`. Use focused runners
first when they shorten diagnosis; registration in the aggregate is not
passing evidence.

## Studio session safety

- Immediately before Studio work, run `scripts/ensure-rojo-server.ps1`,
  enumerate instances, and explicitly select the matching project.
- Reuse an already-open matching Studio session. Never inspect another
  project or open a duplicate because the connector is empty or disconnected.
- Identify an unpublished project by canonical local `place.rbxl`. Identify a
  published project by exact recorded nonzero `game.PlaceId` and `game.GameId`,
  with matching `default.project.json` identity and `servePlaceIds`.
- Do not Play in a published local-file session until the verified Rojo
  connection has restored those IDs and the selected DataModel is rechecked.
- A newly attached place is not test-ready until its actual resulting
  DataModel IDs are recorded and verified. Supplied, expected, URL-derived, or
  name-derived values are not evidence.
- A fresh Play session is stop/start inside the same selected Studio instance.
  Do not reopen Studio, republish, or change Experience attachment as test
  setup.
- Record selected instance, place identity, Rojo project identity, source
  revision, results, and unexpected output.

## Real DataStore

`RealDataStoreSmokeTest` is opt-in. Run it only in a dedicated published test
Experience with Studio API access, the non-production
`PlayerData_IntegrationTests_v1` store, and a fresh `Smoke_<GUID>` key. A pass
requires both `Ok = true` and `CleanupOk = true`. Never run it merely because
save code changed when the environment has not been proven safe.

The complete environment procedure is in `docs/IntegrationTesting.md`.

## Evidence

Report the source revision, exact commands/runners, counts and failures,
matching Studio identity when used, output inspection, cleanup, and every
omitted check with its reason. Static review, a Rojo build, or an old test run
does not prove current runtime behavior.
