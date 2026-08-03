# Published teleport testing

## Purpose and scope

This runbook tests real Roblox transport between two published places while
keeping the reusable template safe by default. `TeleportValidationPad` is only
an operator harness. It is not gameplay, it does not modify `place.rbxl`, and
the secondary project or place is only a test endpoint rather than a separate
release-readiness target.

Deterministic suites remain the authority for envelope validation, session GUID
continuity, negative paths, client recovery, and cleanup. The published run
adds evidence that Roblox can perform the forward, return, and rapid-repeat
transport with the same source revision and without a save-session-lock kick.

## Safe default

`src/ServerScriptService/Modules/Teleport/TeleportValidationConfig.luau` ships
with:

```luau
Enabled = false
GameId = 0
RoutesBySourcePlaceId = {}
AuthorizedUserIds = {}
```

In that state `TeleportValidationPad:Initialize()` does not install a player
observer, create a Part, or call Teleport. Do not change these defaults in a
public reusable-template commit merely to make one operator run convenient.

## Preconditions

1. Use two published places in the same dedicated test Experience. One is the
   primary project under validation; the other may be a sibling repository
   used only as the endpoint.
2. Both endpoints must use the same reviewed Teleport source revision. Scene
   content may differ and is outside this test unless it prevents bootstrap or
   teleport interaction.
3. The operator must know the intended tester UserId. A username is not a
   stable substitute.
4. Both exact Studio sessions must already be open and connected through their
   own MCP plugin when Studio operations are required. Never open a duplicate
   session because a connector is missing.
5. Run `scripts/ensure-rojo-server.ps1` from the repository being synchronized
   before source or Studio work. The preflight owns the single default Rojo
   endpoint, so rerun it whenever switching repositories.
6. A derived project must complete `.agents/rules/project-initialization.md`
   first. Remove inherited template `placeId`, `gameId`, and `servePlaceIds`
   before its first connection and record only independently observed identity.

## Prepare the two repository roles

Record the reviewed source baseline before changing either endpoint:

```powershell
git rev-parse HEAD
git status --short
```

The production implementation must be committed and the listed status must be
clean before creating or updating an endpoint. A commit SHA does not identify
uncommitted or untracked source. Temporary validation-config edits happen only
after this clean baseline and are recorded separately by exact file hash.

For template validation, this repository is the primary and the existing
sibling `roblox_project_template_second_place` is only the transport endpoint.
Fetch its template upstream and prove the reviewed template commit is an
ancestor of the endpoint before adding endpoint-owned divergence.

For a derived game, create a separate sibling endpoint repository from the
same clean primary-project commit, for example
`{primary-folder}_TeleportEndpoint`. Supply a distinct endpoint repository URL
and clone the primary repository's shared history at the recorded commit; do
not copy a working directory or its `.git` directory, and do not bootstrap the
endpoint from a bare template revision that omits project-owned production
changes. The recorded primary commit must be reachable from the clone source.
Before endpoint-owned divergence, verify `git rev-parse HEAD` is exactly the
recorded primary baseline and `git status --short` is empty. Preserve the
template `upstream`, replace the copied `origin` only after verifying the
distinct endpoint destination. After divergence, prove the baseline remains
in the exact endpoint history with both
`git cat-file -e <primary-baseline>^{commit}` and
`git merge-base --is-ancestor <primary-baseline> HEAD`; a merely similar tree
or a hash-equivalent file copy is not shared history.

The bodies of cloned Accepted project ADRs remain immutable. Find the active
ADR owner of the copied README and `default.project.json`, then add the next
endpoint-owned project ADR that explicitly supersedes those copied identity
decisions. Update only the old ADR lifecycle metadata and project index status
to record supersession. The new ADR's `Template divergence` section must name
the exact paths, primary/template baseline, endpoint Rojo-name and independent
cloud-identity invariants, future merge policy, and removal condition. Remove
copied primary or inherited template cloud IDs before the endpoint's first
Rojo preflight. The endpoint is not a second primary release candidate.

Before publishing, compare SHA-256 hashes for these production files in both
repository roots and require exact matches:

```text
src/ReplicatedStorage/Client/Teleport/TeleportClient.luau
src/ReplicatedStorage/Shared/Teleport/TeleportProtocol.luau
src/ReplicatedStorage/Shared/Teleport/TeleportTypes.luau
src/ServerScriptService/Modules/Teleport/TeleportModule.luau
src/ServerScriptService/Modules/Teleport/TeleportPolicy.luau
src/ServerScriptService/Modules/Teleport/TeleportValidationPad.luau
src/ServerScriptService/Modules/Save/ServerSaveController.luau
src/ServerScriptService/Modules/Storage/SessionLockingStorage.luau
src/ServerScriptService/Modules/Storage/StorageConfig.luau
```

Use `Get-FileHash -Algorithm SHA256` for each path and retain both result sets
with the test record. Identity, validation config, project policy composition,
ADRs, and scene content may differ; the production teleport and save-handoff
implementation listed above must not. If a derived endpoint needs a different
listed implementation, stop and review it as a separate change instead of
using it as equivalent transport evidence.

In a derived repository, create or reuse an Accepted project ADR before the
temporary run. It must own every changed template path, including
`src/ServerScriptService/Modules/Teleport/TeleportValidationConfig.luau` and
any manifest or policy-composition path, and state the baseline, invariant, and
future template-merge policy. The reusable template's temporary enabled values
must never be committed as its safe default.

## Record cloud identity

For each selected post-attachment DataModel, read the exact nonzero
`game.PlaceId` and `game.GameId`. Do not infer them from names, URLs, command
lines, or another repository. Both places must report the same GameId.

In each owning repository:

1. Set top-level `placeId` to that repository's selected place.
2. Set top-level `gameId` to the observed shared Experience ID.
3. Set `servePlaceIds` to the exact approved test-place set.
4. Record the decision in the owning ADR namespace: `template` for this
   reusable validation Experience, `project` for a derived game.
5. Rerun the Rojo preflight, reconnect, and re-read the DataModel IDs before
   Play, Experience Config, DataStore, or Publish.

Write each ID as a bare decimal JSON integer in `1..2^53-1`. Do not use a
fractional (`123.0`), exponent (`1.23e2`), quoted, or out-of-range spelling;
repository validation rejects representations that require numeric
normalization or can lose precision before identity comparison.

Do not use **Publish to Roblox As** to repair identity. Normal Publish is
allowed only after the selected DataModel matches the repository record.

## Configure the production destination policy

The operator harness never expands `TeleportPolicy`. The primary and endpoint
servers must independently allow both source/destination PlaceIds through
project composition.

- The dedicated template validation Experience already has its exact two-place
  policy in `TeleportPolicy.Template`.
- A derived project must compose its own `TeleportPolicy.new` allowlist or an
  equivalent project-owned policy value containing both observed PlaceIds.
  If this changes a template-owned path, create or reuse the project ADR that
  records the exact divergence and future merge policy.

Run `TeleportModuleTestRunner` after changing policy. A pad that appears while
the destination policy rejects its route is a failed setup, not permission to
bypass the policy.

## Temporarily enable the operator harness

Edit only `TeleportValidationConfig.luau` in each endpoint's synchronized
source so both use the same values:

```luau
local ENABLED = true
local GAME_ID = 1234567890

local ROUTES_BY_SOURCE_PLACE_ID = {
    [1111111111] = 2222222222,
    [2222222222] = 1111111111,
}

local AUTHORIZED_USER_IDS = {
    [3333333333] = true,
}
```

Replace every example number with an independently observed ID. Requirements:

- `GAME_ID` is one finite positive integer and exactly matches both DataModels;
- every route key and value is a different finite positive PlaceId;
- round-trip testing needs both directed entries;
- every tester key is a finite positive integer and its value is exactly
  `true`;
- keep the allowlist minimal and never treat the UserId as a secret;
- do not add a fallback by username, group membership, place name, or current
  `game.PlaceId` alone.

The controller snapshots and validates the configuration at construction.
Invalid, partial, inherited, or mismatched values produce no observer or pad.

After enablement, compute and retain the SHA-256 hash of
`TeleportValidationConfig.luau` in both repositories and require the hashes to
match. Record that temporary config hash alongside both clean baseline commit
SHAs and the production-file hash sets above. `HEAD` alone does not identify
the enabled validation artifact.

## Synchronize and publish

For the primary repository, then the endpoint repository:

1. Run the Rojo preflight from that repository.
2. Explicitly select the already-open Studio instance by its recorded
   `game.PlaceId` and `game.GameId`.
3. Connect the matching Rojo project and wait for synchronization to finish.
4. Confirm the DataModel IDs still match the repository record.
5. Run a fresh Play bootstrap and focused deterministic tests before Publish.
6. Stop Play and use normal **Publish to Roblox**. Record the published version.

Switch repositories deliberately: stop Play in the selected instance, run the
next repository's Rojo preflight so it owns port `34872`, enumerate Studio
instances, and select the endpoint only by its recorded PlaceId and GameId. A
running Studio process with an empty or disconnected connector response is not
proof that the endpoint is absent; stop and restore that connector rather than
opening or replacing Studio.

Do not edit either canonical `place.rbxl` for this test. Do not require the
endpoint's unrelated scene assets to satisfy the primary template's release
gate.

The template repository-layout validator intentionally rejects a temporarily
enabled reusable default. Run it successfully before enablement and again
after mandatory teardown; record the temporary rejection as an expected safety
guard rather than weakening the validator.

## Roblox-client E2E

Use a fresh Roblox client, not Studio Play:

1. Join the primary place as an allowlisted tester.
2. Confirm one labelled runtime pad appears near a `SpawnLocation` and names
   the configured endpoint PlaceId. A non-allowlisted player must not activate
   it.
3. Step onto the pad and confirm the endpoint loads without a kick.
4. Confirm the endpoint pad names the primary PlaceId, then return.
5. Repeat the round trip several times, including rapid returns after each
   destination becomes interactive.
6. Confirm there is no Error 267 save-load kick, no infinite loading state, no
   duplicate pad for one tester presence, and no in-scope Teleport/bootstrap
   error.

Record:

- source revision and published versions;
- shared GameId and both PlaceIds;
- tester UserId and the temporary config revision;
- forward, return, and rapid-repeat results;
- deterministic suite totals and primary fresh-bootstrap result;
- any omitted check and its reason.

The physical pad deliberately does not display or log `sessionId` or
`attemptId`. Session-envelope continuity is verified by the deterministic
arrival/envelope suites; the published run verifies the real Roblox transport
and handoff path. A game that needs additional presentation may subscribe to
the existing local Teleport projection, but must not add a diagnostic remote or
publish another player's identifiers.

## Mandatory teardown

After E2E, restore the reusable safe default in both synchronized endpoints:

```luau
local ENABLED = false
local GAME_ID = 0
local ROUTES_BY_SOURCE_PLACE_ID = {}
local AUTHORIZED_USER_IDS = {}
```

Then repeat the repository switch, Rojo sync, exact DataModel identity check,
and normal Publish for both endpoints. Join a fresh server as the former tester
and confirm no `TeleportValidationPad_To_*` Part appears. Existing servers may
retain their construction-time config until shutdown; only a fresh server is
valid teardown evidence.

Finally rerun `TeleportModuleTestRunner`, the repository-layout validator, and
a clean primary Play bootstrap. In a derived repository, confirm the temporary
config and composition diff is empty against the recorded baseline (or restored
to an ADR-approved disabled equivalent). The endpoint only needs to prove that
its synchronized bootstrap works; do not count its unrelated release checks as
primary readiness evidence.

## Troubleshooting

| Symptom | Check |
|---|---|
| No pad | `Enabled`, exact GameId, current source route, positive tester UserId, Rojo sync, fresh server |
| Pad appears but request is rejected | `TeleportPolicy` independently allows the destination |
| Wrong destination label | route entry for the current `game.PlaceId` |
| Teleport fails before target load | both places are published in the same Experience and the client is not running in Studio Play |
| Return causes Error 267 | source/target use the same save-handoff revision; inspect session-lock close/load diagnostics |
| Other players can trigger movement | verify touch resolves through `PlayersModule` and equals the allowlisted tester; do not broaden the allowlist |
| Pad remains after disabling | publish both endpoints and join a newly allocated server |
