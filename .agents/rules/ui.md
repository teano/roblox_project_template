# UI system rules

## Scope

Apply to `ReplicatedStorage/Client/UI/**`, UI initialization, UI actions,
controller identity, ownership bubbling, window navigation, and UI authoring.

Required context: `docs/UiSystem.md`, `docs/InitializationAndSaveSystem.md`,
ADR-0045, and the rules for every injected subsystem whose contract is used.

## Mandatory rules

- `UiSystem` is the single client owner of `UiRoot`, `WindowHost`, window
  navigation, the immutable action/config catalogs, and the root event stream.
- `UiRoot` is one `ScreenGui` with `ResetOnSpawn=false` and safe-area
  projection. Its direct hosts remain `HudHost < ToastHost < WindowHost`.
- Project systems own the concrete HUD and toast content they place in the
  injected hosts. UI must not introduce a HUD registry or toast scheduler.
- UI modules use `--!strict`, constructor injection, and the existing client
  manifest. Do not create another bootstrap or standalone `LocalScript`.
- A reusable UI controller owns its direct children, connections, and final
  `UIElementId`; it must not store a containing `WindowId`.
- Identity registration and dynamic subtree attachment/detachment must be
  collision-checked before observable publication. Never auto-suffix an ID.
- Ownership bubbling is synchronous child-to-parent. `BaseWindowView` adds
  `WindowId` at the window boundary; only the root publishes through the
  private side-local `Signal`.
- Root subscribers receive only `Connect` and `Once`. A yielded or failed
  subscriber must not block publication or other subscribers.
- Root event payloads must pass the existing communication serializer's
  bounded value inspection and must never contain `Instance`, functions,
  cycles, or TextBox text.
- `Clear` is synchronous, idempotent, recursively attempts every child and
  owned resource, and reports aggregate cleanup failure without choosing a
  root window's destroy/pool policy.
- Player and Character access must use the injected client `PlayersModule`.
  Respawn must not recreate or clear `UiSystem` or `UiRoot`.
- Concrete cloud windows start from the repository data-only authoring
  template and contain no `LuaSourceContainer`. Every window has one canonical
  owner-specific typed definition ModuleScript; its authoring sequence and
  every typed caller directly require the same returned table.
- The reusable template must not contain the project-owned
  `src/ReplicatedStorage/Project/Client/UI/DerivedWindowConfig.luau`. An
  initialized derived project must contain that exact strict UTF-8 sequence;
  no alternate config, registry, manifest, or repository-kind runtime marker
  is accepted.

## Forbidden patterns

- Do not place early `ReplicatedFirst` loading UI under `UiRoot`.
- Do not add remotes, analytics, persistence, arbitrary asset loading, a
  generic service locator, high-frequency raw input events, or TextBox text to
  the semantic stream.
- Do not let HUD/toast content enter the window stack or give it window
  lifecycle APIs.
- Do not expose the root signal's `Fire`, `Wait`, or `Destroy` methods.
- Do not create an empty optional `DerivedUiActionIds.luau`; create that exact
  project path only when real `game.*` actions are authored.

## Verification

- `UiSystemTestRunner`, `SystemTestRunner`, and `AllTestsRunner`.
- Temporary Rojo build and repository-layout validation.
- Data-only template, authoring-skill, and derived-layout validation.
- Clean selected canonical Studio Play for bootstrap, one root, three hosts,
  safe-area behavior, respawn persistence, and clean server/client output.
