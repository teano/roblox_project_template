# ADR-0046: Use direct template tooling and optional work records

- Status: Accepted
- Date: 2026-08-26
- Deciders: Project maintainers
- Supersedes: ADR-0009, ADR-0010, ADR-0011, ADR-0044
- Superseded by: None

## Context

The template process layer grew into overlapping lifecycle commands, generated
dashboards, leases, mandatory ADR gates, repository-wide prose validation, and
pre-edit Rojo work. Small client-project changes paid this cost even when no
runtime or DataModel behavior was involved. Template updates also depended on
the old workflow, so an existing derived project could not easily adopt the
version that replaced that workflow.

The runtime systems, canonical place, project identity, and project-owned
namespaces still require strong protection. Those guarantees do not require a
general development pipeline.

## Decision

Use direct, path-routed work as the default:

- `AGENTS.md` owns repository-wide safety and points only to rules matched by
  the paths and runtime concerns being changed.
- `scripts/template-project.ps1` is the single self-contained interface for
  `init`, `update`, and bounded structural `validate` operations.
- Primary `init` takes a target game URL and explicit destination, creates a
  shared-history checkout, configures game `origin` plus template `upstream`,
  and requires exactly one of `-Check` or `-Apply`. It commits and pushes only
  with explicit `-Push`; prepared-checkout mode remains available for legacy
  bootstrap.
- `update` takes an exact repository root and already-fetched target ref,
  requires exactly one of `-Check` or `-Apply`, and never fetches, pushes,
  force-pushes, publishes, or changes branches.
- An update is an atomic no-commit merge transaction. It preserves the
  complete project `place.rbxl` and README, project code/ADR/feature
  namespaces, and local Rojo/cloud identity, including an existing custom
  `servePort`. Conflicts and validation failures restore the recorded
  pre-state and emit a rollback receipt.
- A legacy checkout may extract this tool from the exact target ref into a
  temporary file and invoke it with `-RepositoryPath`; it does not run the
  checkout's retired workflow first.
- Feature records are optional context with only `open|done` state. They do
  not own branches, leases, tests, releases, chats, pipelines, or permissions.
  Legacy manifests are retained byte-for-byte in a sidecar when migrated.
- Template and project ADR namespaces remain available for genuinely durable
  decisions, but project initialization and per-path divergence no longer
  require an ADR.
- Generic validation is limited to cheap repository structure, identity, and
  a small changed-path ownership denylist. Runtime semantics remain with
  focused Luau and Studio suites.
- Rojo preflight is required before Studio/live-sync work, not before ordinary
  filesystem edits.

Where still-accepted runtime ADRs name the retired repository-layout validator,
this decision supersedes only that enforcement-mechanism reference. Their
runtime ownership, safety, and verification decisions remain active and their
status does not change.

## Consequences

Routine work has no mandatory lifecycle ceremony. Review and verification are
proportional to the changed risk. Existing derived projects can adopt this
cutover directly from a fetched target revision, while protected project state
and normal Git history survive updates.

Historical feature records and superseded ADRs remain readable. They explain
past work but no longer impose active commands, generated indexes, branch
reservation, leases, or prose validation. Ignored legacy artifacts remain
untouched unless they collide with an incoming tracked path; non-ignored
untracked paths fail closed before an update.

## Enforcement

- `AGENTS.md` and `.agents/rules/index.md` define the direct router.
- `.agents/rules/template-workflow.md` defines initialization, update, legacy
  bootstrap, protected data, and structural-validation boundaries.
- `.agents/rules/feature-workflow.md` defines optional feature records.
- Tooling tests cover PowerShell 5.1 and 7, check/apply/no-op behavior,
  rollback, identity preservation, namespace isolation, malformed `/tests`
  independence, legacy migration, and a second-update no-op.
- Focused runtime suites remain authoritative for existing game systems.
