# Template architecture decision records

This index contains decisions owned by the reusable Roblox project template.
Repositories derived from the template receive these records from their
`upstream` remote and must not edit this file or the template ADRs.

## Decision index

| ID | Decision | Status |
|---|---|---|
| [ADR-0001](0001-explicit-initialization-manifests.md) | Use explicit side-specific initialization manifests | Accepted |
| [ADR-0002](0002-layer-agnostic-save-module.md) | Keep SaveModule independent of save-layer meaning | Accepted |
| [ADR-0003](0003-domain-owned-runtime-and-atomic-snapshots.md) | Domain modules own runtime state and snapshots apply atomically | Accepted |
| [ADR-0004](0004-compact-batched-communication-and-resync.md) | Use compact batched runtime messages with snapshot resync | Accepted |
| [ADR-0005](0005-centralized-players-lifecycle.md) | Centralize Roblox player lifecycle behind PlayersModule | Accepted |
| [ADR-0006](0006-hybrid-rojo-and-studio-place-ownership.md) | Track one canonical Studio place alongside partial Rojo source | Superseded by ADR-0008 |
| [ADR-0007](0007-side-owned-generation-safe-object-pools.md) | Use side-owned generation-safe object pools | Accepted |
| [ADR-0008](0008-canonical-place-filename.md) | Use one project-neutral canonical place filename | Accepted |
| [ADR-0009](0009-separate-template-and-project-adrs.md) | Separate template and project ADR namespaces | Accepted |
| [ADR-0010](0010-adr-grounded-upstream-merges.md) | Use ADR-grounded upstream merges and preserve the project place | Accepted |
| [ADR-0011](0011-user-selected-template-update-branch.md) | Let the user choose the template update destination branch | Accepted |
| [ADR-0012](0012-project-specific-rojo-server-ports.md) | Assign and preserve project-specific Rojo server ports | Superseded by ADR-0015 |
| [ADR-0013](0013-side-owned-static-asset-catalogs.md) | Use side-owned immutable static asset catalogs | Accepted |
| [ADR-0015](0015-default-rojo-port-with-project-overrides.md) | Use Rojo's default port with optional project overrides | Accepted |

## Ownership and numbering

- Template ADRs use the next available four-digit number in this directory.
- Template changes update this index and never the project ADR index.
- Derived projects treat this directory as upstream-owned.
- Accepted ADR bodies are historical records. Supersede a decision with a new
  template ADR instead of rewriting it.

Copy `../_template.md` when creating a template ADR.
