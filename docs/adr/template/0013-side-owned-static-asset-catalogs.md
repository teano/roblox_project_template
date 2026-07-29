# ADR-0013: Use side-owned immutable static asset catalogs

- Status: Accepted
- Date: 2026-07-29
- Deciders: Project maintainers
- Supersedes: None
- Superseded by: None

## Context

Gameplay and presentation systems need authored models, sounds, UI templates,
effects, and other static Roblox Instances. Resolving each template through a
service-relative chain and repeatedly traversing descendants distributes
folder knowledge across consumers, repeats work, and allows ambiguous
name-first selection.

A global locator that scans every service would reduce explicit paths but
would also hide module dependencies, mix static templates with runtime
Instances, produce different client results under streaming, and overlap with
the separate pooling registry. The server and client also have different
visibility boundaries.

Paths are useful for hierarchy and subtree queries, while cross-module
contracts sometimes need an identity that survives moving an Instance between
folders.

## Decision

Use a shared, side-neutral `AssetRegistry` algorithm and construct separate
registries in the explicit server and client manifests.

The server indexes `ReplicatedStorage.Assets.Shared` as `Shared` and
`ServerStorage.Assets` as `Server`. Each client indexes
`ReplicatedStorage.Assets.Shared` as `Shared` and
`ReplicatedStorage.Assets.Client` as `Client`. No other roots are discovered
automatically.

Initialization synchronously scans each explicit root once, validates the
complete catalog into temporary indexes, and atomically publishes an immutable
startup snapshot. Paths are namespace-relative and `/`-separated. Duplicate
logical paths, overlapping roots, invalid names, and invalid or duplicate
`AssetKey` attributes fail initialization.

Every descendant is path-addressable. Folder, name, exact class, `IsA`, tag,
and attribute queries return deterministic path-sorted immutable copies.
Name-based queries remain plural. Required singular lookup uses a path or
stable `AssetKey` plus an expected Roblox class.

`AssetKey` is an optional human-readable public identity stored as an Instance
attribute. It is unique across every namespace indexed by one registry.
Catalog originals remain static templates; dynamic Instances and pooled clones
belong to their domain owners.

## Alternatives considered

### Scan all services and return the first name match

Rejected because it creates a generic service locator, makes ambiguity depend
on traversal order, crosses authority boundaries, and includes runtime or
streamed state.

### Use only fixed service-relative paths

Rejected because consumers repeat container traversal, folder ownership leaks
throughout the codebase, and subtree or metadata queries still require
repeated scans.

### Use only CollectionService tags

Rejected because tags do not provide a unique hierarchical address, do not
express direct-child versus recursive folder queries, and still require a
separate uniqueness contract for singular lookup.

### Live-update one global catalog from descendant events

Rejected because catalog contents could change invisibly after dependent
systems initialize, clients could disagree under replication or streaming,
and cleanup/ownership would become ambiguous. Dynamic collections remain
domain-owned.

## Consequences

### Positive

- Asset traversal and validation happen once per side at a deterministic point.
- Consumers use stable paths or keys without knowing Roblox services.
- Server-only, shared, and client-only visibility remain explicit.
- Duplicate names and keys fail during bootstrap instead of selecting an
  arbitrary Instance later.
- Folder and metadata queries have deterministic immutable results.
- Pooling and runtime ownership remain separate from asset discovery.

### Negative

- Asset folders and public keys become reviewed runtime contracts.
- Moving a folder changes every descendant path consumer.
- Assets added after bootstrap are unavailable until the next runtime.
- Both server and client independently index the shared root.
- Studio-authored asset changes still require serialized ownership of the
  canonical binary place.

## Enforcement

- Agent rules: `.agents/rules/assets.md`, `.agents/rules/architecture.md`,
  `.agents/rules/initialization.md`, `.agents/rules/rojo-project.md`, and
  `.agents/rules/testing.md`.
- Current documentation: `docs/AssetRegistry.md`,
  `docs/InitializationAndSaveSystem.md`, `docs/ResourceManagement.md`, and
  `README.md`.
- Code boundaries: `Shared/Assets/AssetRegistry`,
  `Shared/Assets/AssetTypes`, `ReplicatedStorage.Assets`,
  `ServerStorage.Assets`, both `AssetRegistryInitializationCommand` modules,
  and both initialization manifests.
- Tests: `AssetRegistryTestRunner`, `SystemTestRunner`, Rojo validation build,
  repository layout validation, and clean server/client bootstrap.
