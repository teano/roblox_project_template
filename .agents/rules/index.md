# Agent rules index

This file is the mandatory router for project agent rules.

## Selection procedure

Before source edits:

1. Determine whether the repository is the reusable template or a derived game.
2. If a derived repository has no `docs/adr/project/README.md`, include
   `project-initialization.md` before its first source change.
3. Identify every affected path.
4. Identify every affected architectural concern, even when its implementation lives elsewhere.
5. Read all matching rule files completely.
6. Always include `testing.md`.
7. Include `architecture.md` for new modules, new commands, cross-system changes, ownership changes, or public contract changes.
8. For those architectural changes, include `architecture-decisions.md`, read
   `docs/adr/README.md`, and read all relevant Accepted ADRs selected from both
   indexes routed there.

Path matching alone is insufficient. For example, editing `WalletModule` also
affects save-provider and communication contracts.

## Path and concern mapping

| Trigger | Required rules |
|---|---|
| Request to create or initialize a project from a target repository URL | `project-initialization.md`, then every rule required by its initialization checklist |
| First source change in a derived repository without `docs/adr/project/README.md` | `project-initialization.md`, `architecture-decisions.md`, `rojo-project.md`, `domain-data.md`, `save-system.md`, `communication.md`, `testing.md` |
| Fetching, merging, reviewing, or resolving changes from template `upstream` | `template-updates.md`, `architecture-decisions.md`, `rojo-project.md`, `testing.md`, plus every affected subsystem rule |
| Modifying or deleting a path that also exists in template `upstream` | `template-updates.md`, `architecture-decisions.md`, plus every affected subsystem rule |
| New module, subsystem, service, public API, or ownership boundary | `architecture.md`, `initialization.md`, `testing.md` |
| `AssetRegistry`, `AssetKey`, static asset lookup, asset roots, or asset folder/query contracts | `assets.md`, `architecture.md`, `initialization.md`, `rojo-project.md`, `testing.md` |
| `ContentPreloader`, `ContentProvider`, `PreloadAsync`, preload tags/groups, startup content loading, or loading before pool warmup | `content-preloading.md`, `assets.md`, `architecture.md`, `initialization.md`, `testing.md` |
| Pool, pooling adapter, lease, reusable resource, or resource cleanup | `resource-management.md`, `architecture.md`, `testing.md` |
| `src/**/Initialization/**`, either bootstrap, initialization runner/types | `architecture.md`, `initialization.md`, `testing.md` |
| `src/**/Save/**`, storage, autosave, session locks, migration, version persistence | `architecture.md`, `save-system.md`, `testing.md` |
| Communication, RemoteEvent, RemoteFunction, DTO, protocol, serialization, rate limit, resync | `architecture.md`, `communication.md`, `testing.md` |
| Server or client Players modules, player/character lifecycle | `architecture.md`, `players.md`, `testing.md` |
| Wallet, Version, GameData, a save provider, or an authority change | `domain-data.md`, `save-system.md`, `communication.md`, `testing.md` |
| `ReplicatedFirst/Loading.client.luau` | `architecture.md`, `initialization.md`, `testing.md` |
| `default.project.json`, Rojo mappings, `.model.json`, executable script placement | `rojo-project.md`, `architecture.md`, `testing.md` |
| `place.rbxl`, Studio-authored scene data, or hybrid source ownership | `rojo-project.md`, `architecture.md`, `testing.md` |
| Any test runner or test contract | `testing.md` plus the tested subsystem rule |
| Documentation that describes runtime behavior | The corresponding subsystem rules |
| New or changed architecture decision record | `architecture-decisions.md`, `architecture.md` plus every affected subsystem rule |

## Available rule files

- `architecture.md`: dependency ownership, module boundaries, cross-system design.
- `architecture-decisions.md`: template/project ADR ownership, indexes,
  numbering, supersession, and reading/writing workflow.
- `project-initialization.md`: mandatory one-time setup for a repository
  derived from this template.
- `template-updates.md`: upstream inspection, project divergence ADRs, place
  preservation, conflict stopping rules, and merge reporting.
- `initialization.md`: runner, manifests, commands, bootstraps, loading completion.
- `save-system.md`: controllers, providers, lifecycle, rollback, storage, shutdown.
- `communication.md`: batching, validation, priorities, sequencing, epochs, resync.
- `players.md`: centralized player and character lifecycle.
- `domain-data.md`: Wallet, Version, GameData, provider extension and authority.
- `testing.md`: required verification and test authoring rules.
- `rojo-project.md`: source-of-truth and Roblox instance mapping rules.
- `assets.md`: side-owned static asset catalogs, roots, paths, keys, queries,
  folder rules, and startup immutability.
- `content-preloading.md`: the single preloading entry point, catalog-backed
  selection, named requests, progress, failure policy, and startup loading.
- `resource-management.md`: pooling ownership, adapters, leases, budgets, and cleanup.

## Architecture decision records

`docs/adr/README.md` is the decision router. Template-owned decisions and their
index live under `docs/adr/template/`. A derived repository creates and owns
its separate index and decisions under `docs/adr/project/`. ADRs explain why
durable architectural constraints exist; they do not replace agent rules or
current system documentation.

The template repository MUST NOT contain `docs/adr/project/`. Agents initialize
that namespace only in a derived repository by following
`project-initialization.md`.

Read relevant Accepted ADRs from both namespaces when a change:

- introduces or removes a subsystem;
- changes ownership, authority, lifecycle, persistence, or synchronization;
- reverses a previously rejected alternative;
- changes a public contract across module boundaries.

Do not require every ADR for a local implementation edit whose architecture is
unchanged.

Write a template decision only under `docs/adr/template/` and update only the
template index. Write a game-specific decision only under `docs/adr/project/`
and update only the project index. Never add numbered ADR entries directly to
the router.

## Ambiguous changes

When no row clearly matches, read `architecture.md` and `testing.md` first. If the change introduces a new architectural category, add a focused rule file and update this index in the same change.
