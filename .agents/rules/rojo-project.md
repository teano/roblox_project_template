# Rojo project rules

## Scope

Apply to `default.project.json`, `place.rbxl`, source placement,
Roblox instance mappings, `.model.json` assets, and executable
Script/LocalScript files.

## Source of truth

This repository intentionally uses hybrid ownership:

- `src/` and `default.project.json` are the source of truth for every
  Rojo-managed Instance, script, and property.
- `place.rbxl` is the tracked source of truth for Studio-authored
  scene data that is outside the Rojo mappings.
- `default.project.json` MUST set `$ignoreUnknownInstances` to `true` on
  filesystem-backed containers while hybrid ownership is active. This prevents
  live sync from deleting Studio-authored children that are absent from `src/`.
- Generated `.rbxlx`/`.rbxl` validation builds, Roblox Studio lock files, and
  generated `sourcemap.json` are not source.
- Validation builds belong in a temporary directory.

If an Instance or property is described by `default.project.json` or `src/`,
the text source wins. Do not make a competing place-only edit to it. Everything
else in the scene is preserved by saving and committing
`place.rbxl`.

## Mandatory rules

- Before the first source-code edit in a task and again before the first
  Roblox Studio operation, run
  `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/ensure-rojo-server.ps1`.
  Do not continue unless it confirms that the current repository's
  `default.project.json` `name` owns Rojo's default endpoint
  `127.0.0.1:34872`.
- The preflight MAY replace another Rojo server on the default port after
  verifying the listener process is Rojo. It MUST refuse to terminate a
  non-Rojo listener.
- Before using Studio tools, explicitly select the current project's Studio
  instance. An unpublished project is identified by the canonical local
  `place.rbxl`; a published project is identified by its project-recorded
  stable `game.PlaceId` and `game.GameId`. Treat `default.project.json` `name`
  only as the Rojo project/server identity and never require it to match
  `game.Name`.
- Every published repository MUST configure top-level `placeId`, `gameId`, and
  `servePlaceIds` in `default.project.json`. `placeId` and `gameId` MUST match
  the recorded cloud place and Experience, and `servePlaceIds` MUST be a
  non-empty duplicate-free array that contains `placeId`, every approved
  live-sync destination, and no unrelated place. Every JSON identity value MUST
  be a bare decimal integer token in Roblox's exact safe-integer range
  `1..2^53-1`; fractional, exponent, floating-point, decimal-normalized, and
  out-of-range values fail closed.
- The reusable template's configured IDs identify only its dedicated validation
  Experience and its two explicitly approved places. A derived checkout MUST
  remove all inherited `placeId`, `gameId`, and
  `servePlaceIds` fields before its first Rojo preflight, Studio connection, or
  Studio operation, then leave them absent or replace them with that derived
  project's independently verified identity. Never connect a derived project
  while the template IDs remain configured.
- Immediately after a user-authorized first publish or attachment, read the
  exact nonzero `game.PlaceId` and `game.GameId` from the selected resulting
  DataModel. That post-attachment DataModel is the authoritative source for
  recording identity; names, URLs, requested destinations, process arguments,
  and expected IDs are not substitutes.
- Before any subsequent Play, Experience Config, DataStore, test, publish, or
  other cloud-dependent operation, write the observed IDs to top-level
  `placeId`/`gameId`, update `servePlaceIds` to the exact approved allowlist,
  and create the required ADR in the repository's owning namespace for the
  attachment decision and `default.project.json` identity. Rerun the Rojo
  preflight, reconnect if needed, and verify the DataModel reports the recorded
  IDs exactly.
- If the post-attachment IDs cannot be read, are zero, or do not match the
  user-authorized destination, stop. Do not guess, partially record identity,
  continue under an unresolved attachment, or use another publish to repair
  it.
- Open a published project either from Roblox cloud (`EditPlace` or My
  Experiences), or from canonical `place.rbxl` only when the verified Rojo
  connection will restore the configured `placeId`/`gameId` before any Play,
  Experience Config, DataStore, publishing, or other cloud-dependent
  operation. Verify `game.PlaceId` and `game.GameId` after connection and stop
  on any mismatch or zero value.
- Reuse an existing Studio session for tests and Studio work when it owns the
  canonical place of the current project. Never open a duplicate session for
  that project, and never inspect or change sessions belonging to other
  projects. The Rojo preflight confirms endpoint ownership but does not
  authorize replacing a matching session, republishing the place, or changing
  its Experience attachment.
- Open a canonical session only after reliable enumeration proves no matching
  project session exists. If Studio MCP cannot list or retain the intended
  existing instance while Studio is running, stop before all Studio and UI
  operations. Do not open a replacement via `Start-Process`, file association,
  Computer Use, or another fallback. Ask the user to restore the connector in
  the already-open canonical session.
- "Fresh Play" always means a new Play DataModel inside the same selected
  Studio instance, never a new Studio process, window, place tab, or
  Experience attachment.
- Preserve the existing top-level mappings unless an architectural change requires otherwise.
- New shared/client/server files MUST be placed under the correct mapped container.
- System startup code MUST remain limited to the two bootstraps plus the dedicated ReplicatedFirst loading LocalScript.
- For an unpublished project, open `place.rbxl` for normal Studio work. For a
  published project, follow the cloud-identity launch procedure above and
  export/save Studio-authored scene state back to the exact canonical
  `place.rbxl`; do not replace it with a source-only validation build.
- Pull the latest branch and verify that the place has no unresolved Git
  change before beginning a new scene-editing session.
- Coordinate binary scene ownership so only one branch/person changes
  `place.rbxl` at a time.
- Make authorized scene edits through Roblox Studio, save the exact canonical
  file, and include it in the same change that depends on the scene update.
- When a binary conflict occurs, choose one complete place version and
  manually replay the other scene change in Studio. Never auto-merge it.
- Runtime-created remotes MUST use stable protocol names and validate existing instance classes.
- Authored Roblox assets MAY use `.model.json`; code behavior belongs in Luau modules.
- When removing a legacy place-only Script, remove the obsolete Instance from Studio and ensure it is not present in Rojo source.
- After changing mappings, build from `default.project.json` and inspect the resulting hierarchy.

## Forbidden patterns

- MUST NOT programmatically or hex-edit binary `.rbxl` files.
- MUST NOT ignore `place.rbxl` while the repository uses partial
  Rojo synchronization.
- MUST NOT use Team Create as an undocumented second source of truth.
- MUST NOT commit temporary `.rbxlx` validation builds.
- MUST NOT add a new `.server.luau` or `.client.luau` to initialize an individual module.
- MUST NOT create fake folders/remotes only to silence an obsolete place-local Script.
- MUST NOT map broad Workspace replacement behavior that could delete user-authored world Instances without explicit approval.
- MUST NOT depend on unknown Instances that exist only in the currently open Studio place.
- MUST NOT define `servePort`, pass `--port`, or edit the endpoint field in the
  Studio Rojo plugin. Projects share the default endpoint and switch the
  active server through `scripts/ensure-rojo-server.ps1`.
- MUST NOT launch a published project as an unidentified local file and then
  Play, access Experience services, or publish while `game.PlaceId` or
  `game.GameId` is zero or mismatched.
- MUST NOT use `Publish to Roblox As` to guess, repair, or silently change a
  project's cloud identity. Publishing or attaching a place requires explicit
  user authorization and an exact recorded destination.
- MUST NOT infer or record `placeId`/`gameId` from a project name, DataModel
  name, URL, Creator Hub path, command line, requested destination, or another
  repository. Only the actual selected post-attachment DataModel can supply
  newly assigned IDs.
- MUST NOT launch or reopen Studio as an implicit fallback for missing or
  disconnected Studio MCP data when a matching project session may exist.

## Positive example

```json
"ReplicatedFirst": {
  "$path": "src/ReplicatedFirst"
}
```

The loading LocalScript is explicitly reproducible from source.

## Negative example

Adding a server Script only inside `place.rbxl` makes code behavior
invisible to review and non-reproducible from Rojo source.

Ignoring `place.rbxl` after adding an unmanaged map model means the
model exists only on one developer's machine.

## Verification

- Rojo build to a temporary output path.
- Run `scripts/ensure-rojo-server.ps1` twice. The first run MAY switch the
  server; the second MUST report that the current project is already serving
  without restarting it.
- Confirm `place.rbxl` is tracked and not ignored.
- Confirm generated validation builds and `place.rbxl.lock` remain
  ignored.
- Inspect executable scripts with:

```powershell
rg --files src | Where-Object { $_ -match '\.(server|client)\.luau$' }
```

- Clean Play bootstrap after mapping, executable-placement, or canonical-scene
  changes.
