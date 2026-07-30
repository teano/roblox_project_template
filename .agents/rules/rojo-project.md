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
- Before using Studio tools, explicitly select the current canonical
  `place.rbxl` Studio instance. Treat `default.project.json` `name` only as
  the Rojo project/server identity and never require it to match
  `game.Name`. For a published project, verify stable `game.PlaceId` and
  `game.GameId` values recorded by the project or rely on a configured
  `servePlaceIds` allowlist when available.
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
- Open `place.rbxl` for normal Studio work; do not replace it with a
  source-only validation build.
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
