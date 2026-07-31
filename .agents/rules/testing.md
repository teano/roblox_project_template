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
- Every isolated test runs through `TestHarness`, has a finite timeout, and
  registers failure-safe cleanup with its supplied scope when it owns state
  that can outlive the callback.
- Production schedulers, clocks, waits, randomness, and transports must be
  injected in deterministic tests. Do not make correctness depend on a
  heartbeat race or wall-clock delay.
- Expected diagnostic records must be asserted or documented. Unexpected
  server or client warnings and errors fail the release gate.
- Keep `docs/TestCoverage.md` current when adding a production subsystem,
  changing a critical contract, or changing the required release gate.

## Required static check

After any source or Rojo mapping change:

```powershell
rojo build default.project.json --output $env:TEMP\roblox-template-validation.rbxlx
```

Do not write validation builds into the repository.

Validate repository-owned file and ADR boundaries:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/validate-repository-layout.ps1
```

Run this check after canonical place, ADR, agent-rule, repository-layout,
project-initialization, template-divergence, or upstream-merge changes.

## Studio suites

Run in Play mode from the server:

```lua
require(game.ServerScriptService.Tests.AllTestsRunner).runAll()
```

Expected: the aggregate result and every suite result have `failed = 0`.
`AllTestsRunner` excludes the opt-in real DataStore smoke test.

## Studio session preservation

- Reuse an already-open Studio instance when it owns the current project:
  canonical local `place.rbxl` identity for an unpublished project, or the
  recorded stable cloud place identity for a published project. Never open a
  duplicate session for the same project. Studio sessions for other projects
  are out of scope.
- Run the Rojo preflight, call the Studio instance-list operation, and
  explicitly select the matching instance before starting or stopping Play,
  executing Luau, reading the DataModel, or using any Studio UI.
- For a published place, require exact nonzero recorded `game.PlaceId` and
  `game.GameId`, matching top-level `placeId`/`gameId`, and a
  `servePlaceIds` allowlist containing the selected place. For an unpublished
  place, use the canonical file identity. Never choose by
  `default.project.json` `name` or by an MCP heuristic.
- A newly attached or published place is not test-ready until the agent has
  read the actual post-attachment DataModel IDs, recorded them in
  `default.project.json` and the owning project ADR, rerun the Rojo preflight,
  and verified the selected DataModel against those recorded values. Supplied,
  expected, URL-derived, or name-derived IDs do not satisfy this gate.
- Do not start Play or a test suite in a published project opened as a local
  file until the verified Rojo connection has restored the configured IDs and
  exact DataModel identity has been checked. A zero or mismatched ID blocks
  the test; republishing is not a test setup step.
- Open a new canonical Studio session only after reliable instance enumeration
  proves that no matching project session exists. If no instance is returned
  while Studio is running, the selected instance disconnects, or multiple
  candidates cannot be distinguished safely, stop the test run. Ask the user
  to restore MCP in the existing session. Do not treat missing MCP data as
  permission to launch Studio, reopen the place, use `Start-Process`, use shell
  file association, or bypass explicit selection with Computer Use.
- A fresh Play session is a stop/start cycle within the same selected Studio
  instance. Do not close/reopen Studio, publish or attach the place, change
  Experience identity, or restart Rojo as a substitute for a fresh Play
  DataModel.
- Record the matching selected Studio instance identity, place identity, and
  Rojo project identity with the test evidence. If any identity changes during
  the run, discard the results and stop until the intended existing session is
  restored.

## Change-to-suite mapping

| Change | Required suites/checks |
|---|---|
| Initialization, manifests, module composition | System + clean server/client bootstrap |
| Asset registry, roots, paths, keys, tags, metadata, or asset folder mappings | AssetRegistry + System + clean server/client bootstrap |
| Content preloader, preload selectors, progress, policies, or startup preload command | ContentPreloader + AssetRegistry + System + clean server/client bootstrap |
| Pool core, adapters, leases, registry, or resource cleanup | ResourceManagement + System; add clean Play when manifests or concrete Roblox resources change |
| Save, providers, storage, locks, autosave, shutdown | System + Production + ProductionReadiness |
| Communication, DTO, serializer, remotes, resync | Production + clean client/server Play |
| Experience Config catalog, codecs, bundles, projections, refresh, or config request transport | ConfigCatalog + System; add Production + clean client/server Play when transport or manifests change |
| Wallet, Version, GameData, or another provider | System + Production + ProductionReadiness |
| Project-specific gameplay or presentation | Its focused suite plus Production when communication or persistence is involved |
| Players lifecycle | System + ProductionReadiness + join/leave/respawn Play checks |
| Rojo mapping or executable placement | Rojo build + clean bootstrap |
| Rojo server process, endpoint ownership, or Studio preflight | Repository layout validator + two consecutive `ensure-rojo-server.ps1` runs |

## Real DataStore

`RealDataStoreSmokeTest` is opt-in only:

- use a published dedicated test place;
- enable Studio API access;
- use `PlayerData_IntegrationTests_v1`, never the production store;
- use a fresh `Smoke_<GUID>` key, which is 42 characters and remains below the
  Roblox DataStore 50-character key limit;
- remove the test key afterward;
- report cleanup failure explicitly.

Do not run this test merely because DataStore code changed when the environment is not explicitly safe.

## Dedicated integration environment

Create or rebuild a real integration-test environment in this mandatory order:

1. Create or update a sibling project named
   `{project_folder}_IntegrationTest` from the exact source state being
   tested, and create or confirm its dedicated Roblox test Experience.
2. Copy every required Experience Config into the test Experience before
   attaching the place. Structured configs MUST use the native Experience
   Config type `JSON`, never `String` containing JSON. Copy the current
   published values, publish the test configs, and verify every key, type, and
   value in the Published view; staged-only configs are not ready for testing.
3. Only after the configs are published, attach or publish the integration
   project's canonical `place.rbxl` to the dedicated test Experience. Record
   and verify the resulting stable `game.PlaceId` and `game.GameId`, configure
   matching top-level `placeId`/`gameId`, and restrict the Rojo connection
   with `servePlaceIds`.

After setup, enable Studio API access only for the dedicated test Experience,
run a clean server/client bootstrap, then run the deterministic suites and the
opt-in smoke test. A real DataStore run passes only when its result has both
`Ok = true` and `CleanupOk = true`.

Do not attach the production place, use a production Experience, continue with
missing or staged-only configs, or represent a required JSON config as a
string.

The complete operator checklist is documented in
`docs/IntegrationTesting.md`.

## Output inspection

For startup/network/save changes, inspect server and client console output. Treat unexpected errors and warnings as failures. Distinguish unrelated place-local Scripts from project source, remove obsolete test objects instead of creating compatibility objects that hide their errors, and rerun from a fresh Play session to clear ModuleScript cache.
