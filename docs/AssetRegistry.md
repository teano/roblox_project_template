# Static asset catalog

## Purpose and boundary

`AssetRegistry` replaces repeated service-relative asset lookup and repeated
tree traversal with one validated startup catalog. The server and every client
own separate registry instances under `Services.Assets`; they share one
side-neutral implementation.

The catalog indexes static authored Roblox `Instance` templates. It does not
own their runtime lifetime and is not a generic service locator. Roblox
services, ModuleScripts, remotes, characters, runtime world objects, player UI
copies, and pooled leases remain explicit dependencies of their owning
systems.

## Canonical roots

The Rojo project declares three persistent roots:

```text
ReplicatedStorage
└─ Assets
   ├─ Shared
   └─ Client

ServerStorage
└─ Assets
```

The registries receive these roots explicitly:

```text
Server registry
├─ Shared → ReplicatedStorage.Assets.Shared
└─ Server → ServerStorage.Assets

Client registry
├─ Shared → ReplicatedStorage.Assets.Shared
└─ Client → ReplicatedStorage.Assets.Client
```

The server can physically observe `ReplicatedStorage.Assets.Client`, but its
catalog intentionally does not index that namespace. The client cannot observe
`ServerStorage.Assets`.

Do not add `Workspace`, an entire service, `PlayerGui`, a character, or another
dynamic/streamed hierarchy as a root. A new root is an architectural change
and must be composed explicitly on the owning side.

## Folder and path rules

Each namespace root is itself addressable. Every descendant, including
folders and internal model descendants, receives a canonical path:

```text
Shared
Shared/Audio
Shared/Audio/UI
Shared/Audio/UI/Click
Client/UI/Inventory
Server/Enemies/Slime
```

Paths use `/` and are case-sensitive. A descendant path is derived from the
current names of all ancestors at initialization. Indexed names:

- must not be empty;
- must not be `.` or `..`;
- must not contain `/` or control characters;
- must be unique among siblings.

Roblox permits siblings with the same name, but the registry rejects them
because they create the same path. Folder names describe semantic ownership or
category. They never declare module initialization order.

`GetChildren(path)` returns direct children. `GetDescendants(path)` returns the
complete recursive subtree. `FindAll({ Under = path })` excludes the scope
Instance itself and recurses by default; set `Recursive = false` for direct
children only.

All list results are sorted by canonical path and returned as frozen copies, so
Roblox child order and caller mutation cannot change query behavior.

## Stable `AssetKey`

A path is useful for hierarchical lookup but changes when an asset or one of
its folders moves. Add the optional string attribute `AssetKey` when another
module needs a stable public identity:

```text
Name: Click
ClassName: Sound
Path: Shared/Audio/UI/Click
Attributes:
  AssetKey: ui.click
```

Keys:

- begin with a letter or digit;
- contain only letters, digits, `.`, `_`, and `-`;
- contain at most 128 characters;
- are unique across all namespaces indexed by one side.

Because `Shared` participates in both catalogs, its keys must not collide with
either `Client` or `Server` keys. Prefer readable domain keys such as
`enemy.slime.template` and `ui.inventory.open`, not generated GUIDs.

Assign keys to public resource templates, not automatically to every part,
attachment, or emitter inside a model. Moving or renaming an Instance changes
its path but does not change its key. Changing a key is a public contract
change and requires updating every consumer.

## Tags and metadata

Tags classify resources into groups such as `Preload`, `Effect`, or
`WeaponAsset`. Other attributes provide exact-match query metadata:

```text
AssetKey = effect.explosion.large
Quality = High
Theme = Fire
```

Tags and attributes are captured as part of the startup catalog contract.
They may select assets but must not choose module startup order. Attribute
queries use Roblox equality against the current attribute value; metadata is
therefore expected to remain unchanged after initialization.

## Initialization and immutability

The `Assets` initialization command performs one synchronous
`GetDescendants()` scan per explicit root. It builds all indexes in temporary
tables, validates the complete catalog, sorts lists by path, and publishes the
new indexes only if every check succeeds.

Initialization fails on:

- missing or overlapping roots;
- duplicate namespaces or logical paths;
- invalid path segments;
- a non-string, malformed, or duplicate `AssetKey`.

A successful call is idempotent. A failed registry remains failed. The
published registry is a startup snapshot: it does not subscribe to
`DescendantAdded`, `DescendantRemoving`, tag changes, or attribute changes.
Instances added after initialization are intentionally absent until the next
runtime starts.

Catalog Instances are static originals. Consumers normally use `Clone` or
clone the result of `Require`; they must not rename, reparent, destroy, or
mutate catalog originals during normal runtime. A system that owns dynamic
Instances maintains its own collection. A future explicit dynamic registry
would be a different subsystem.

## Public API

```lua
local assets = services.Assets

local click = assets:Require("Shared/Audio/UI/Click", "Sound")
local slime = assets:RequireByKey("enemy.slime.template", "Model")
local slimeClone = assets:Clone("Server/Enemies/Slime", "Model")

local directChildren = assets:GetChildren("Shared/Audio")
local completeTree = assets:GetDescendants("Shared/Effects")

local preloadedFireEffects = assets:FindAll({
	Under = "Shared/Effects",
	IsA = "ParticleEmitter",
	Tags = { "Preload" },
	Attributes = {
		Theme = "Fire",
	},
})
```

Lookup behavior:

- `Get(path)` and `GetByKey(key)` return `nil` when absent.
- `Require(path, expectedClass)` and
  `RequireByKey(key, expectedClass)` fail on absence or class mismatch.
- `GetPath(instance)` returns the captured canonical path or `nil`.
- `FindByName(name)` may return multiple results.
- `FindByClassName(className)` matches the exact `ClassName`.
- `FindAll({ IsA = "BasePart" })` includes subclasses accepted by `IsA`.
- `FindAll` combines name, exact class, `IsA`, all requested tags, and exact
  attribute values.

Never select the first result of a name query when behavior requires one
specific asset. Use a path or key with an expected class.

## Authoring workflow

Choose the root from real visibility:

- `Shared`: both server and client use the template;
- `Client`: presentation-only template used by clients;
- `Server`: authoritative or server-only template.

Then:

1. Create semantic category folders below the root.
2. Keep every sibling name unique.
3. Add the asset and decide whether it needs a stable `AssetKey`.
4. Add tags/metadata only when a real query consumes them.
5. Update path consumers after any ancestor rename or move.
6. Run the focused and system test suites in a fresh Play session.

The root folders are Rojo-managed and use `$ignoreUnknownInstances: true`.
Studio-authored descendants live in canonical `place.rbxl` and must be edited
and saved through Studio. Rojo-owned models must be declared explicitly in the
project mapping. Never represent the same Instance or property in both
sources.

Changing Studio-owned assets changes the binary place, so only one branch or
person should own that scene edit at a time. A validation `.rbxlx` build is not
a replacement for the canonical place.

## Pooling and preloading

`AssetRegistry` discovers static originals. `PoolModule` manages reusable
runtime clones with leases, budgets, reset, and cleanup. A domain module may
obtain one typed template from `Services.Assets`, then create and own a
homogeneous pool from that template.

Content loading may yield, while registry scanning and pool adapters may not.
Route it through the project `ContentPreloader` before pool warmup; do not add
yielding loading to `AssetRegistry:Initialize`, `FindAll`, or a pool adapter.
Production consumers do not call `ContentProvider:PreloadAsync()` directly.
See [ContentPreloading.md](ContentPreloading.md).

## Verification

Run a Rojo validation build:

```powershell
rojo build default.project.json --output $env:TEMP\roblox-template-validation.rbxlx
```

Run in a fresh server Studio Play session:

```lua
require(game.ServerScriptService.Tests.AssetRegistryTestRunner).runAll()
require(game.ServerScriptService.Tests.ContentPreloaderTestRunner).runAll()
require(game.ServerScriptService.Tests.SystemTestRunner).runAll()
```

Both results must report `failed = 0`. Inspect both server and client output
after changes to roots, mappings, manifests, or canonical assets.
