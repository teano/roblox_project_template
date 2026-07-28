# Rojo project rules

## Scope

Apply to `default.project.json`, `template_place.rbxl`, source placement,
Roblox instance mappings, `.model.json` assets, and executable
Script/LocalScript files.

## Source of truth

This repository intentionally uses hybrid ownership:

- `src/` and `default.project.json` are the source of truth for every
  Rojo-managed Instance, script, and property.
- `template_place.rbxl` is the tracked source of truth for Studio-authored
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
`template_place.rbxl`.

## Mandatory rules

- Preserve the existing top-level mappings unless an architectural change requires otherwise.
- New shared/client/server files MUST be placed under the correct mapped container.
- System startup code MUST remain limited to the two bootstraps plus the dedicated ReplicatedFirst loading LocalScript.
- Open `template_place.rbxl` for normal Studio work; do not replace it with a
  source-only validation build.
- Pull the latest branch and verify that the place has no unresolved Git
  change before beginning a new scene-editing session.
- Coordinate binary scene ownership so only one branch/person changes
  `template_place.rbxl` at a time.
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
- MUST NOT ignore `template_place.rbxl` while the repository uses partial
  Rojo synchronization.
- MUST NOT use Team Create as an undocumented second source of truth.
- MUST NOT commit temporary `.rbxlx` validation builds.
- MUST NOT add a new `.server.luau` or `.client.luau` to initialize an individual module.
- MUST NOT create fake folders/remotes only to silence an obsolete place-local Script.
- MUST NOT map broad Workspace replacement behavior that could delete user-authored world Instances without explicit approval.
- MUST NOT depend on unknown Instances that exist only in the currently open Studio place.

## Positive example

```json
"ReplicatedFirst": {
  "$path": "src/ReplicatedFirst"
}
```

The loading LocalScript is explicitly reproducible from source.

## Negative example

Adding a server Script only inside `template_place.rbxl` makes code behavior
invisible to review and non-reproducible from Rojo source.

Ignoring `template_place.rbxl` after adding an unmanaged map model means the
model exists only on one developer's machine.

## Verification

- Rojo build to a temporary output path.
- Confirm `template_place.rbxl` is tracked and not ignored.
- Confirm generated validation builds and `template_place.rbxl.lock` remain
  ignored.
- Inspect executable scripts with:

```powershell
rg --files src | Where-Object { $_ -match '\.(server|client)\.luau$' }
```

- Clean Play bootstrap after mapping, executable-placement, or canonical-scene
  changes.
