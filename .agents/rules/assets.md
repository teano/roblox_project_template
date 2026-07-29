# Static asset catalog rules

## Scope

Apply to `AssetRegistry`, `AssetKey`, asset queries, asset folder mappings,
static templates, and code that discovers or clones authored resources.

Required context: `docs/AssetRegistry.md`, `docs/ContentPreloading.md`,
`docs/InitializationAndSaveSystem.md`, `docs/adr/README.md`, and every relevant
Accepted template and project ADR selected from the routed indexes.

This subsystem catalogs static authored `Instance` templates. It is distinct
from pooling and does not own runtime object lifetimes.

## Ownership and roots

- Server and client MUST own separate `AssetRegistry` instances composed
  through their explicit initialization manifests.
- Shared registry code MUST remain side-neutral and receive every root through
  constructor injection.
- The server registry MUST index only:
  - namespace `Shared` from `ReplicatedStorage.Assets.Shared`;
  - namespace `Server` from `ServerStorage.Assets`.
- The client registry MUST index only:
  - namespace `Shared` from `ReplicatedStorage.Assets.Shared`;
  - namespace `Client` from `ReplicatedStorage.Assets.Client`.
- Roots MUST be explicit, non-overlapping, and declared by the Rojo project
  mapping.
- Each manifest MUST expose its registry as `context.Services.Assets`, and
  consumers MUST NOT query it before the manifest-owned `Assets` command
  succeeds.

## Folder and path contract

- Each configured root is addressable by its namespace (`Shared`, `Client`, or
  `Server`), and every descendant is indexed by a `/`-separated path relative
  to that namespace.
- Every indexed descendant, including a `Folder` and a model's internal
  descendants, is addressable by path.
- Siblings under an indexed parent MUST have unique names. Roblox permits
  duplicates, but the catalog rejects them because they produce the same
  logical path.
- Indexed names MUST be non-empty, MUST NOT be `.` or `..`, MUST NOT contain
  `/`, and MUST NOT contain control characters.
- Folder hierarchy SHOULD express ownership and category, not startup order.
  Numeric or phase prefixes MUST NOT be used to infer initialization.
- Queries scoped `Under` a path exclude the scope itself. They recurse by
  default; `Recursive = false` selects only direct children.
- All list results MUST be sorted by canonical path and returned as immutable
  copies.
- An unknown path passed to `Require`, folder traversal, or `Under` MUST fail
  loudly. Optional `Get` and index lookups MAY return `nil`.

## Keys and metadata

- `AssetKey` is an optional string attribute for a stable public identity that
  survives renaming or moving the Instance.
- Keys MUST begin with a letter or digit, contain only letters, digits, `.`,
  `_`, and `-`, and be no longer than 128 characters.
- Every key MUST be unique across all namespaces visible to that side's
  registry.
- Assign `AssetKey` only to a resource that consumers address as a public
  template. Internal model parts SHOULD normally remain path-only.
- Tags MAY classify resources, and other attributes MAY provide query
  metadata. Tags and metadata MUST NOT choose module startup order.
- A consumer that requires one asset MUST use `Require`/`RequireByKey` with an
  expected Roblox class instead of selecting the first name match.

## Lifecycle

- Initialization MUST perform one complete synchronous scan, validate into
  temporary indexes, and publish the catalog atomically only on success.
- Successful initialization MUST be idempotent. A failed catalog MUST remain
  failed.
- The catalog is an immutable startup snapshot. Code MUST NOT rely on assets
  added, removed, renamed, reparented, retagged, or re-attributed after
  initialization.
- Catalog originals are static templates. Consumers SHOULD clone them and MUST
  NOT reparent or mutate originals in normal runtime behavior.
- Dynamic world objects, characters, player UI copies, and other runtime
  Instances belong to their domain owners, not to `AssetRegistry`.
- Yielding content preloading is a separate phase or module. It MUST NOT be
  hidden inside the synchronous scan or lookup API.
- Catalog-backed preloading MUST route through `ContentPreloader`; production
  consumers MUST NOT call `ContentProvider:PreloadAsync()` directly.
- The startup preload set uses tag `Preload`. This selects content only and
  MUST NOT define module startup order.

## Forbidden patterns

- MUST NOT scan an entire Roblox service, `DataModel`, `Workspace`,
  `PlayerGui`, character, or streamed hierarchy as a catalog root.
- MUST NOT put services, remotes, runtime entities, or dependency resolution
  behind `AssetRegistry`.
- MUST NOT dynamically `require` ModuleScripts by asset path or key.
- MUST NOT use name-only lookup when ambiguity would change behavior.
- MUST NOT subscribe to global descendant events or automatically refresh the
  catalog.
- MUST NOT confuse the static asset catalog with `PoolModule`; cloning and
  indexing do not imply reuse, reset, budgets, or cleanup.
- MUST NOT author the same asset Instance or property in both Rojo source and
  `place.rbxl`.

## Adding or moving assets

1. Choose `Shared`, `Client`, or `Server` from actual runtime visibility.
2. Place the asset below the matching explicit root.
3. Use folders for semantic ownership/category and keep sibling names unique.
4. Add a stable `AssetKey` only when another module needs a durable public
   reference.
5. Add tags and attributes only for real query metadata.
6. Save Studio-authored content in canonical `place.rbxl`, or declare
   Rojo-owned content explicitly, without dual ownership.
7. Update every path consumer when an indexed object or ancestor is renamed or
   moved. Key consumers do not change unless the key contract changes.
8. Add or update focused tests for every new catalog contract.

## Verification

- Rojo build to a temporary output path.
- `AssetRegistryTestRunner`.
- `ContentPreloaderTestRunner` after preload selection or integration changes.
- `SystemTestRunner`.
- Clean server/client bootstrap with no asset catalog errors after manifest,
  mapping, root, or canonical-place changes.
- `scripts/validate-repository-layout.ps1` after rule, ADR, mapping, or
  canonical-place changes.
