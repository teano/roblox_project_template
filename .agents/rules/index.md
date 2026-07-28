# Agent rules index

This file is the mandatory router for project agent rules.

## Selection procedure

Before source edits:

1. Identify every affected path.
2. Identify every affected architectural concern, even when its implementation lives elsewhere.
3. Read all matching rule files completely.
4. Always include `testing.md`.
5. Include `architecture.md` for new modules, new commands, cross-system changes, ownership changes, or public contract changes.
6. For those architectural changes, read `docs/adr/README.md` and all relevant
   Accepted ADRs selected from its index.

Path matching alone is insufficient. For example, editing `WalletModule` also
affects save-provider and communication contracts.

## Path and concern mapping

| Trigger | Required rules |
|---|---|
| New module, subsystem, service, public API, or ownership boundary | `architecture.md`, `initialization.md`, `testing.md` |
| Pool, pooling adapter, lease, reusable resource, or resource cleanup | `resource-management.md`, `architecture.md`, `testing.md` |
| `src/**/Initialization/**`, either bootstrap, initialization runner/types | `architecture.md`, `initialization.md`, `testing.md` |
| `src/**/Save/**`, storage, autosave, session locks, migration, version persistence | `architecture.md`, `save-system.md`, `testing.md` |
| Communication, RemoteEvent, RemoteFunction, DTO, protocol, serialization, rate limit, resync | `architecture.md`, `communication.md`, `testing.md` |
| Server or client Players modules, player/character lifecycle | `architecture.md`, `players.md`, `testing.md` |
| Wallet, Version, GameData, a save provider, or an authority change | `domain-data.md`, `save-system.md`, `communication.md`, `testing.md` |
| `ReplicatedFirst/Loading.client.luau` | `architecture.md`, `initialization.md`, `testing.md` |
| `default.project.json`, Rojo mappings, `.model.json`, executable script placement | `rojo-project.md`, `architecture.md`, `testing.md` |
| `template_place.rbxl`, Studio-authored scene data, or hybrid source ownership | `rojo-project.md`, `architecture.md`, `testing.md` |
| Any test runner or test contract | `testing.md` plus the tested subsystem rule |
| Documentation that describes runtime behavior | The corresponding subsystem rules |
| New or changed architecture decision record | `architecture.md` plus every affected subsystem rule |

## Available rule files

- `architecture.md`: dependency ownership, module boundaries, cross-system design.
- `initialization.md`: runner, manifests, commands, bootstraps, loading completion.
- `save-system.md`: controllers, providers, lifecycle, rollback, storage, shutdown.
- `communication.md`: batching, validation, priorities, sequencing, epochs, resync.
- `players.md`: centralized player and character lifecycle.
- `domain-data.md`: Wallet, Version, GameData, provider extension and authority.
- `testing.md`: required verification and test authoring rules.
- `rojo-project.md`: source-of-truth and Roblox instance mapping rules.
- `resource-management.md`: pooling ownership, adapters, leases, budgets, and cleanup.

## Architecture decision records

`docs/adr/README.md` is the decision router. ADRs explain why durable
architectural constraints exist; they do not replace agent rules or current
system documentation.

Read relevant Accepted ADRs when a change:

- introduces or removes a subsystem;
- changes ownership, authority, lifecycle, persistence, or synchronization;
- reverses a previously rejected alternative;
- changes a public contract across module boundaries.

Do not require every ADR for a local implementation edit whose architecture is
unchanged.

## Ambiguous changes

When no row clearly matches, read `architecture.md` and `testing.md` first. If the change introduces a new architectural category, add a focused rule file and update this index in the same change.
