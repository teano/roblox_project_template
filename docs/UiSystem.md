# UI System

## Boundary and startup

`ReplicatedStorage.Client.UI.UiSystem` is the client-owned facade for the game
UI after early loading. `ClientManifest` constructs it with the existing
client `PlayersModule`; `UiInitializationCommand` runs as command `UI` after
`StartupContentPreload`, `Pooling`, and `Players`. A structural failure is
adapted at that command boundary to `UiInitializationFailed:<Code>`, allowing
the existing initialization runner and client bootstrap to stop normally.

The reusable template ships an empty `TemplateWindowConfig`, so initialization
still creates no window automatically. A concrete project may list canonical
per-window definitions in that duplicate-preserving authoring sequence. The
exact optional derived source is
`ReplicatedStorage.Project.Client.UI.DerivedWindowConfig`; its absence is the
empty derived sequence and is not a runtime repository-kind check.

## Root ownership

Initialization publishes one `UiRoot` `ScreenGui` under the local player's
`PlayerGui`, with `ResetOnSpawn=false`, `CoreUISafeInsets`, device-safe-area
clipping, sibling Z ordering, and three full-area hosts:

1. `HudHost` (`ZIndex=10`)
2. `ToastHost` (`ZIndex=20`)
3. `WindowHost` (`ZIndex=30`)

The candidate is built and validated off-tree, then parented once. A compatible
existing root is accepted idempotently; a duplicate or malformed root returns
`UiRootMalformed` without publishing partial UI state. Character respawn does
not initialize, clear, or replace the root. Early `ReplicatedFirst` loading UI
remains separate.

Project-specific HUD and toast systems receive their host and the same frozen
`UiElementContext` through explicit client composition. They own their content,
state, subscriptions, visibility, and cleanup; UI supplies no `HudId`, HUD
registry, toast queue, timer, or lifecycle facade.

## Controller identity and events

Every controller has one final `UIElementId`, a represented `GuiObject`, and a
list of direct `NestedUiElements`. Dynamic subtree attachment collision-checks
the complete claim set before updating parent links. Removal releases only
claims owned by that exact controller. Repeated items use the byte-length
prefixed form:

```text
ui.runtime/<path-bytes>:<stable-path>/<key-bytes>:<stable-key>
```

`Clear` is synchronous, idempotent, recursively attempts children and owned
connections, and never chooses whether a root window is destroyed or pooled.

Semantic actions bubble synchronously through direct owners. Reusable children
do not know `WindowId`; `BaseWindowView` adds it at the window boundary. The
root validates catalog membership, identifiers, and the complete envelope with
the existing communication serializer, shallow-freezes the owned envelope,
and publishes through the existing non-blocking side-local `Signal`. Consumers
receive only `Connect` and `Once`. TextBox events never carry entered text;
form logic reads field values directly.

The template catalog uses named lowercase `ui.*` identifiers for pointer,
button, TextBox, form, and window lifecycle actions. The catalog is validated
and frozen during initialization and has no mutation API.

## Canonical window definitions

`WindowConfigCompiler` validates both authoring sequences completely before it
freezes the exact definition tables, their optional pool budgets, the ordered
sequence, and the `WindowId` lookup. A definition binds one logical `WindowId`
to one positive allowlisted cloud `AssetId`, repo-owned `CreateView`,
`TryCastView`, `InitializeView`, lifecycle/visibility/background policies, and
optional eager preload. `PoolOptions` is required only for `Pool` lifecycle.
There is no runtime mutation API, second registry, `TemplateId`, arbitrary
AssetId input, or runtime owner-verification claim.

Typed callers directly require the same per-window definition ModuleScript
listed by the authoring source and pass that exact table to
`AddWindowTypedAsync`. Universal callers use `AddWindowAsync(WindowId,
unknown)`. Both routes use the same frozen config and the same runtime
definition identity.

## Loading, window lifecycle, and handles

`WindowAssetLoader` calls only the injected `AssetService:LoadAssetAsync` for
the definition's allowlisted `AssetId`. It requires one `GuiObject` root,
rejects every `LuaSourceContainer` recursively, and routes relevant content
through anonymous `ContentPreloader:Preload(..., FailurePolicy="Fail")`.
Successful templates are cached for one `UiSystem` lifetime and cloned
synchronously; failures are retryable. At most one non-cancellable physical
attempt exists per `WindowId`, and stale or timed-out results cannot populate
the cache. `Preload=true` starts a best-effort three-second eager attempt during
UI initialization without turning delivery failure into bootstrap failure.

An empty-stack request creates the first Active window. After that, only the
exact current Active view may add, close, or replace a window. Adding pauses
the previous top; closing resumes the remaining top; replacement prepares its
candidate off-tree and never restores the removed window. `HideBelow` and
`KeepBelow` are evaluated from the final stack once per operation. Applied
state publishes the shared opened, paused, resumed, shown, hidden, and closed
catalog actions, with closed published before identity cleanup.

Every operation owns one generation and one absolute three-second deadline.
There is no queue, Back history, or intermediate lower-prefix recomputation.
The generation-safe `WindowHandle` remains valid while its window is paused,
but `IsActiveWindow` is false; removal or cleanup invalidates it before a
pooled object can be issued again.

Destroy definitions clone and destroy each issue. Pool definitions use one
existing homogeneous `PoolModule` pool named `Ui.Window/<WindowId>`, pass the
frozen `MaxActive`/`MaxRetained` budgets unchanged, keep the exact generation
lease, and run UI `Clear` before the ordinary release. A UI use token prevents
stale cleanup from marking a later issue clean. Timed-out continuing pooled
transition hooks retain their dirty lease in navigator-owned quarantine until
the hook settles, then clear and release through the existing pool API.

## Input blocking and Background

Each `BaseWindowView` owns one `WindowInputBlocker`. A valid direct
`BlockObjectRef` pointing inside the same window makes independently acquired
manual or system handles effective; the sink stays `All` until the last token
releases and returns to `None` afterward. Missing, nil, foreign, or malformed
references produce permanently inert acquired handles and never fail window
initialization. `Clear` invalidates all handles, restores the sink, and removes
owned observers.

`BackgroundPolicy=None` requires no object. `Absorb` and `CloseOnActivate`
bind the exact direct full-window `GuiButton` named `Background`; activation is
ignored while the window is blocked or lacks Active authority, and the close
variant requests only that window's own close. No global input interceptor is
introduced.

## Gamepad navigation

Each window owns one `WindowNavigationRegistry`. It records authored
`Selectable`, `Interactable`, and directional-link baselines for registered
`UINavigationEnabled` descendants, plus the current default and last selected
object. Only an Active and effectively unblocked window enables those members.
Pause or blocking clears owned focus and disables interaction; resume or final
token release restores the last valid member or the required default.

Dynamic attachment from zero eligible members requires the two-argument
`AddNestedUiElement(child, nominatedDefault)` form. Removing the current
default while eligible members remain similarly requires an exact remaining
replacement. Validation occurs before identity, hierarchy, binding, or
navigation mutation, so an invalid nomination leaves all surfaces unchanged.
`Clear` restores authored baselines and forgets all per-generation focus state.

## Window authoring and derived projects

Start a concrete window with
`.agents/templates/window-authoring/WindowTemplate.model.json` and the
explicit `$window-authoring` skill. The template is a non-executable `Frame`
seed with direct `Content` and optional `Background`; an optional direct
`BlockObjectRef` may point to a full-screen transparent input sink. The cloud
asset remains data-only, while a repo-owned `BaseWindowView` and one canonical
typed definition ModuleScript own all behavior.

Template definitions live below
`Client/UI/Config/Definitions` and are directly listed in
`TemplateWindowConfig`. Initialized derived projects instead own the exact
`Project/Client/UI/DerivedWindowConfig.luau` and sibling `Definitions`
directory. `scripts/template-project.ps1 init` creates the strict UTF-8 empty
sequence only when the config is missing. Prepared and legacy initialization
preserves an already-authored config byte-for-byte. For an already initialized
legacy derived project with project-owned identity but no config, explicit
`scripts/template-project.ps1 repair` creates only that missing empty sequence
and preserves project config, README, place, and namespaces. Repository
validation requires the config in a derived repository and rejects the
reserved project namespace in this reusable template. Upstream updates
preserve the complete project namespace. There is no alternate config, runtime
repository-kind marker, or automatic empty action source.

Release evidence uses the checked-in data-only `WindowAssetFixture`, its fixed
`ui.test.window-asset-fixture`/`1001` definition, the production config compiler,
and the production loader with a clone-only local backend. The production cloud
capability remains unchanged. A cloud smoke is conditional on an already
approved external fixture and AssetId; without one it is recorded as not run,
not fabricated or treated as a failure. Exact-place read-only deployment
evidence must still show `AllowInsertFreeAssets=false`; runtime does not claim
cloud-owner verification.

## Verification

`UiSystemTestRunner` owns the deterministic runtime coverage for `TS-TEST-001`
through `TS-TEST-011` plus `TS-TEST-013`, `TS-TEST-014`, and `TS-TEST-015`.
`TS-TEST-012` is the selected-device Play checklist driven by the test-only
`WindowAssetFixturePlaySetup.start()`/`Finish()` session. `TS-TEST-016` is the
deterministic local data-only loader/config proof. `TS-STATIC-001` is the raw
Studio Script Analysis partition gate, and `TS-EVIDENCE-ALLOWINSERT-001` is a
separate read-only exact-place setting observation. None of these identities is
replaced by a Rojo build or a fabricated cloud result.

Run the focused suite before `SystemTestRunner` and the aggregate
`AllTestsRunner`, followed by repository validation and a temporary Rojo
build. The SLICE-004 candidate's focused run passed 17/17 and the aggregate run
passed 397/397 across 15 suites in the selected canonical Studio place
(`PlaceId=91045933836846`, `GameId=10596427617`). The fresh Xbox One Play
observed the production safe-area root, actual pointer, keyboard, and Studio
Virtual Controller gamepad navigation, respawn persistence, and complete
`Finish()` teardown. The same executable focused run included the bounded
`TS-TEST-009` post-yield Open/Close owner, generation, deadline, and destroyed-
navigator regression; this behavior is backed by Studio Play execution, not
static inspection alone. The then-current repository tooling and temporary
Rojo build passed on that historical candidate. Read-only Experience Settings
inspection at
`2026-08-25T05:33:26.033Z` showed “Allow Loading Third Party Assets” disabled.
No publish, deployment, attachment, cloud load, or settings mutation was part
of that run.
