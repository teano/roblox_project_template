---
name: window-authoring
description: Author one project-owned cloud UI window from the repository data-only template and bind it to the canonical typed UI definition/config contract. Use when the user explicitly invokes `$window-authoring` or asks to add a concrete UI System window.
---

# Author a UI window

Create only the requested concrete window. Read `AGENTS.md`,
`.agents/rules/index.md`, `.agents/rules/ui.md`, `docs/UiSystem.md`, and the
current repository's `.agents/rules/template-workflow.md` only when project
initialization or an upstream update is actually involved. Read ADRs only when
the requested window changes a still-active durable decision.

## Resolve ownership and identity

1. Determine the repository role with the repository rules. In the reusable
   template, definitions belong under
   `src/ReplicatedStorage/Client/UI/Config/Definitions/` and are listed by
   `TemplateWindowConfig.luau`. In an initialized derived project, definitions
   belong under `src/ReplicatedStorage/Project/Client/UI/Definitions/` and are
   listed only by the exact project-owned
   `src/ReplicatedStorage/Project/Client/UI/DerivedWindowConfig.luau`.
2. Require one stable `WindowId`, a positive verified cloud `AssetId`, the
   concrete ViewModel contract, and the approved lifecycle, visibility,
   background, preload, and (for `Pool`) pool-budget decisions. Do not invent
   an AssetId or publish/attach an asset without explicit authorization.
3. Project actions may be added only at
   `src/ReplicatedStorage/Project/Client/UI/DerivedUiActionIds.luau`. Do not
   create that optional file when no `game.*` action is required.

## Author the data-only asset

1. Copy `.agents/templates/window-authoring/WindowTemplate.model.json` into a
   project-owned GUI asset. Preserve one `GuiObject` root and the named
   controlled-content container `Content`. Keep or remove the optional direct
   `Background` `GuiButton` according to `BackgroundPolicy`.
2. For input blocking, optionally add one direct `ObjectValue` named
   `BlockObjectRef` and point it to one full-screen transparent `GuiObject`
   input sink that remains a descendant of that exact same window root. Give
   the sink display/Z placement above every interactive descendant of the
   window so `InputSink = All` can actually intercept their input. Do not add
   a second blocker or a global input interceptor.
3. Keep the complete asset data-only: no `Script`, `LocalScript`,
   `ModuleScript`, or other `LuaSourceContainer`. Repo-owned Luau supplies all
   constructors, controllers, and behavior.
4. Give the intended owner/group load permission, keep the Experience setting
   `AllowInsertFreeAssets=false`, and record the exact approved AssetId. These
   are deployment evidence; runtime does not claim cloud-owner verification.

## Create the concrete repo-owned view

1. Create one Rojo-synchronized `--!strict` ModuleScript for the concrete
   window view. Derive its class from `BaseWindowView`, construct the base with
   the authored root, stable `WindowId`, final window `UIElementId`, and the
   injected `WindowConstructionContext.Elements`, and keep the concrete view
   as the owner of its runtime state and child controllers.
2. Define the concrete ViewModel type and validate its runtime shape in the
   view's `Initialize`. Build owned controllers and connect authored controls
   there; publish only approved semantic events through the inherited ownership
   chain. `Clear` must release the view's state, controllers, and connections.
3. Implement only the approved window behavior: override `Open`/`Close` for
   authored transitions, `Pause`/`Resume` for runtime behavior that must stop
   while covered, and use the inherited Add/Close APIs for navigation requests.
   Configure the authored default and directional navigation contracts before
   base initialization. Keep the base no-op lifecycle hooks when no override is
   required.

## Bind one canonical typed definition

1. Create exactly one `--!strict` per-window definition ModuleScript in the
   owner-specific `Definitions` directory. It returns the one
   `WindowDefinition<TView, TViewModel>` table containing `WindowId`, `AssetId`,
   repo-owned `CreateView`, `TryCastView`, and `InitializeView`, plus the
   approved policies and optional pool options. Bind those functions directly
   to the concrete module above: `CreateView` constructs that concrete view,
   `TryCastView` returns it only when its concrete runtime witness matches, and
   `InitializeView` invokes that view's typed `Initialize(viewModel)` exactly
   once and returns its result.
2. Add the exact returned table to the correct duplicate-preserving authoring
   sequence by directly requiring that module. Never substitute a copy,
   wrapper, map, dynamic lookup, second config, registry, or manifest.
3. Every typed caller directly requires the same per-window definition module
   and passes that same returned table to `AddWindowTypedAsync` or the typed
   replacement API. The compiler freezes that table in place.
4. Use `BaseWindowView` and the injected `UiElementContext`; do not create a
   bootstrap, remote, persistence path, HUD/toast registry, or runtime asset-ID
   input.

## Verify

Run the repository-mandated Rojo preflight immediately before Studio or
live-sync work; ordinary filesystem edits do not require it. Then run the
focused config identity, data-only prefab, factory/cast/
Initialize, lifecycle, pool, event, blocker/background, and navigation cases in
`UiSystemTestRunner`, followed by every release gate required by
`.agents/rules/ui.md` and `.agents/rules/testing.md`. Use only the already-open,
explicitly selected canonical Studio instance for Play or cloud evidence.
Record unavailable manual/cloud evidence as unavailable; do not replace it
with fake or build evidence.
