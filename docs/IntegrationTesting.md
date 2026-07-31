# Dedicated integration testing

This checklist defines the required order for preparing and running tests
against real Roblox Experience Configs and DataStore APIs. The test
environment must remain separate from production.

## Terminology

- **Source project**: the repository state and Roblox Experience whose current
  behavior is being tested.
- **Integration project**: a sibling working copy named
  `{project_folder}_IntegrationTest`.
- **Test Experience**: a dedicated Roblox Experience used only by the
  integration project and real API tests.
- **Integration place**: the integration project's canonical `place.rbxl`
  after it is attached or published to the test Experience.

The local integration project and the Roblox test Experience are separate
objects. Preparing one does not prepare the other.

## Mandatory setup order

### 1. Create or update the integration project

Create the sibling `{project_folder}_IntegrationTest` project when it does not
exist. Before every integration run, update it from the exact source state
being tested, including:

- text source and project mappings;
- tests, scripts, rules, and documentation;
- the canonical `place.rbxl`;
- all project-owned configuration contracts.

Keep its Rojo project name repository-specific, do not add `servePort`, and run
the repository Rojo preflight and validation build. Create or confirm a
dedicated Roblox test Experience, but do not attach the integration place yet.

### 2. Transfer and publish Experience Configs

Inventory the required keys from the server config manifest. Copy every
required config from the source Experience into the test Experience.

The template currently requires:

| Key | Native type | Runtime use |
|---|---|---|
| `wallet_config` | `JSON` | one-time starting balances for a new Wallet |
| `global_save_config` | `JSON` | autosave, snapshot timeout, and client retry policy |

For each config:

1. Create or update the same key in the test Experience.
2. Select the native Experience Config type `JSON` for structured data.
   `String` containing serialized JSON is the wrong type.
3. Copy the current published JSON value from the source Experience.
4. Stage and publish the test value.
5. In the Published view, verify the key, the `JSON` type, and the complete
   value.

Do not rely on an old test value, a staged-only value, or a visually similar
string. The test Experience is ready only when all required keys are present
and published with the correct native types.

### 3. Attach the place to the test Experience

Only after the configs are published, attach or publish the integration
project's canonical `place.rbxl` to the dedicated test Experience.

If the integration repository was created from this template, remove the
template validation `placeId`, `gameId`, and `servePlaceIds` before its first
Rojo preflight or Studio connection. Those inherited values never identify the
integration project.

Then:

1. Read the exact nonzero `game.PlaceId` and `game.GameId` from the selected
   post-attachment DataModel, then record and verify them. Do not infer or
   copy newly assigned IDs from the destination name, URL, process command
   line, or prior expectation.
2. Configure the integration project's top-level `placeId`, `gameId`, and
   `servePlaceIds` in `default.project.json`; the allowlist contains only the
   dedicated integration place.
3. Create or update the owning project ADR for the attachment identity and
   `default.project.json` divergence.
4. Run the Rojo preflight from the integration project.
5. Open the dedicated cloud place through My Experiences/`EditPlace`, or open
   the canonical local file and connect verified Rojo before any Play or
   cloud-dependent operation.
6. Explicitly select the Studio instance with those stable nonzero IDs and
   re-read both IDs to verify them against the recorded values.
7. Confirm Rojo is serving `{project_folder}_IntegrationTest`, not the source
   or production project.

Never publish the source project's production place into the test Experience,
and never run real DataStore smoke tests in production.

## Run prerequisites

After the three setup steps:

1. Enable Studio access to API Services for the dedicated test Experience.
2. Reuse an already-open integration Studio session when its stable `PlaceId`
   and `GameId` match the recorded test Experience. Run the Rojo preflight,
   list Studio instances through MCP, and explicitly select that matching
   instance. Ignore sessions belonging to other projects.
3. Start a clean Play DataModel inside that same selected Studio instance.
4. Verify server and client bootstrap complete and the config catalogs report
   the expected config counts.
5. Run the deterministic suites required by `.agents/rules/testing.md`.
6. Run `RealDataStoreSmokeTest` from the server DataModel.

Open a new integration Studio session only when reliable enumeration proves no
matching session exists. If MCP cannot see or retain a potentially matching
existing instance, stop and restore the connector in that session. Do not
treat an empty or disconnected MCP result as permission to reopen the
integration place, create another place tab, republish or reattach the place,
or use UI automation as a substitute for explicit MCP selection.

The real DataStore test is successful only when:

```lua
result.Ok == true and result.CleanupOk == true
```

It must use `PlayerData_IntegrationTests_v1`, generate a fresh 42-character
`Smoke_<GUID>` key below Roblox's 50-character key limit, and remove that key
afterward. Report cleanup failure separately.

## Ready-to-test gate

Do not start integration testing until all statements are true:

- the integration project matches the intended source state;
- the dedicated test Experience is not production;
- every required Experience Config is published with native type `JSON`;
- the integration place is attached to the test Experience;
- the selected Studio DataModel has the recorded `PlaceId` and `GameId`;
- MCP has explicitly selected that already-open Studio instance, without a
  replacement process, window, or place tab;
- Rojo is serving the integration project;
- Studio API access is enabled for the test Experience.
