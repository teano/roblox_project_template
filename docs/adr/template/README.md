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
| [ADR-0014](0014-catalog-integrated-content-preloading.md) | Route content preloading through a catalog-integrated module | Accepted |
| [ADR-0015](0015-default-rojo-port-with-project-overrides.md) | Use Rojo's default port with optional project overrides | Superseded by ADR-0016 |
| [ADR-0016](0016-switch-single-rojo-server-by-project.md) | Switch one default-port Rojo server to the active project | Superseded by ADR-0018 |
| [ADR-0017](0017-server-owned-experience-config-catalog.md) | Use a server-owned Experience Config catalog with explicit client projections | Accepted |
| [ADR-0018](0018-identify-studio-target-by-stable-place-identity.md) | Identify Studio targets without comparing mutable names | Superseded by ADR-0022 |
| [ADR-0019](0019-side-local-non-blocking-signals.md) | Use one side-local non-blocking Signal contract | Accepted |
| [ADR-0020](0020-shape-communication-traffic-and-bound-snapshots.md) | Shape communication traffic and bound network snapshots | Accepted |
| [ADR-0021](0021-migrate-locked-raw-save-documents-iteratively.md) | Migrate locked raw save documents through ordered version steps | Accepted |
| [ADR-0022](0022-launch-published-projects-with-stable-cloud-identity.md) | Launch published projects with stable cloud identity | Superseded by ADR-0023 |
| [ADR-0023](0023-publish-template-with-non-inheritable-cloud-identity.md) | Publish the template with non-inheritable cloud identity | Superseded by ADR-0028 |
| [ADR-0024](0024-server-owned-teleport-session-continuity.md) | Keep teleport session continuity server-owned | Accepted |
| [ADR-0025](0025-include-teleport-in-communication-snapshot-generations.md) | Include Teleport projection in communication snapshot generations | Accepted |
| [ADR-0026](0026-observe-teleport-reconciliation-at-player-capacity.md) | Observe Teleport snapshot reconciliation at configured player capacity | Accepted |
| [ADR-0027](0027-serialize-pre-return-teleport-failures.md) | Serialize teleport failures that arrive before platform return | Accepted |
| [ADR-0028](0028-authorize-two-place-template-validation.md) | Authorize two-place template validation within one Experience | Accepted |
| [ADR-0029](0029-runtime-only-two-place-teleport-validation-pad.md) | Use a runtime-only two-place teleport validation pad | Superseded by ADR-0031 |
| [ADR-0030](0030-retry-session-lock-handoff-after-teleport.md) | Retry session-lock handoff after teleport | Accepted |
| [ADR-0031](0031-disable-teleport-validation-pad-by-default.md) | Disable the teleport validation pad by default | Accepted |
| [ADR-0032](0032-track-feature-work-with-manifests.md) | Track feature work with canonical manifests and explicit lifecycle commands | Superseded by ADR-0033 |
| [ADR-0033](0033-separate-template-and-project-feature-registries.md) | Separate template and project feature registries | Superseded by ADR-0034 |
| [ADR-0034](0034-resolve-feature-task-identity-without-hooks.md) | Resolve feature task identity without repository hooks | Superseded by ADR-0036 |
| [ADR-0035](0035-server-owned-statistics-snapshots.md) | Collect statistics in server-owned bounded snapshots | Accepted |
| [ADR-0036](0036-use-agent-neutral-feature-worklogs-and-canonical-branches.md) | Use agent-neutral feature worklogs and canonical branches | Superseded by ADR-0037 |
| [ADR-0037](0037-reserve-feature-state-transitions-for-users.md) | Reserve feature state transitions for users | Accepted |
| [ADR-0038](0038-use-validated-local-audio-startup-configuration.md) | Use validated local audio startup configuration | Superseded by ADR-0041 |
| [ADR-0039](0039-allow-deterministic-audio-only-asset-key-first-wins.md) | Allow deterministic audio-only AssetKey first-wins | Accepted |
| [ADR-0040](0040-own-audio-graph-and-acoustic-policy-at-bootstrap.md) | Own the audio graph and acoustic policy at bootstrap | Accepted |
| [ADR-0041](0041-protect-audio-startup-and-keep-disabled-transport-handlers.md) | Protect audio startup and keep disabled transport handlers | Accepted |
| [ADR-0042](0042-bind-studio-audio-qa-through-existing-bootstraps.md) | Bind Studio Audio QA through existing bootstraps | Accepted |
| [ADR-0043](0043-fixed-spatial-anchor-composition.md) | Use one fixed SpatialAnchor composition | Accepted |

## Ownership and numbering

- Template ADRs use the next available four-digit number in this directory.
- Template changes update this index and never the project ADR index.
- Derived projects treat this directory as upstream-owned.
- Accepted ADR bodies are historical records. Supersede a decision with a new
  template ADR instead of rewriting it.

Copy `../_template.md` when creating a template ADR.
