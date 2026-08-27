# Template project workflow

## Scope

Apply when creating a game from this template, repairing a supported legacy
checkout, validating repository structure, or bringing a derived project to a
newer template revision.

The self-contained `scripts/template-project.ps1` command owns this workflow.
Do not require feature lifecycle, pipelines, CodeGraph, project ADRs, or manual
per-path divergence records before using it.

## Commands

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/template-project.ps1 init -OriginUrl <game-url> -Destination <exact-path> -Check
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/template-project.ps1 init -OriginUrl <game-url> -Destination <exact-path> -Apply [-Push]
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/template-project.ps1 repair -RepositoryPath <exact-root> -TargetRef <fetched-ref> -Check
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/template-project.ps1 repair -RepositoryPath <exact-root> -TargetRef <fetched-ref> -Apply
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/template-project.ps1 update -RepositoryPath <exact-root> -TargetRef <fetched-ref> -Check
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/template-project.ps1 update -RepositoryPath <exact-root> -TargetRef <fetched-ref> -Apply
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/template-project.ps1 validate -RepositoryPath <exact-root> [-RepositoryRole Auto|Template|Project]
```

Primary `init` requires the target game `-OriginUrl` and an explicit
`-Destination`; `-TemplateUrl` may override the canonical template URL.
Prepared-checkout compatibility mode accepts `-RepositoryPath` and
`-TargetRef`. `repair`, `update`, and `validate` always require an exact
repository root; repair and update targets must be already-fetched refs.

`init`, `repair`, and `update` require exactly one of `-Check` or `-Apply`;
`validate` accepts neither. `-Check` reports the expected transaction without
changing the checkout. `-Apply` authorizes the requested local mutation. Only
an explicit init `-Push` authorizes its initialization commit and push; no
command force-pushes, publishes, attaches a place, or enables production
DataStore.

## New project

- Primary init clones the template into the explicit destination, renames the
  template remote to `upstream`, adds the supplied game URL as `origin`, and
  keeps shared Git history so normal future merges work.
- `-Check` validates an empty target/destination without writing. `-Apply`
  refuses a non-empty unrelated destination or non-empty target repository.
- Set the initial Rojo project name from the destination directory.
- Remove inherited template `placeId`, `gameId`, and `servePlaceIds`. Leave the
  identity absent until the derived project's own exact IDs are verified.
- Create the project-owned
  `src/ReplicatedStorage/Project/Client/UI/DerivedWindowConfig.luau` required by
  the current UI authoring boundary. Do not create alternate registries.
- Project ADR and feature namespaces are optional and are created only when the
  project actually records a decision or feature.
- Validate and perform a temporary Rojo build before accepting initialization.
  Do not commit or push unless the invocation explicitly includes `-Push`.

## Compatibility repair

Use `repair` only for an existing derived project that already has a
project-owned non-template Rojo name but predates the required
`src/ReplicatedStorage/Project/Client/UI/DerivedWindowConfig.luau`. It is not a
general substitute for `init` or `update`, and it refuses to overwrite an
existing config. Cloud identity must be either entirely absent for an
unpublished project or a complete valid project-owned `placeId`/`gameId`/
`servePlaceIds` tuple. A partial tuple or template validation identity is
ineligible.

Repair requires a named branch, clean tracked state and index, no non-ignored
untracked paths, and an already-fetched template ref. `-Check` reports the
single-file repair without writing. `-Apply` creates only the strict
frozen-empty derived UI config, validates the resulting project, and performs
a temporary Rojo build. It preserves `default.project.json` including name,
cloud-identity absence or the complete project tuple, and existing `servePort`;
`README.md`; `place.rbxl`; and every existing project namespace. On failure it
removes the new file and verifies restoration of the exact pre-repair HEAD,
index, and worktree state. It never commits or pushes.

## Update transaction

Before applying an update, require a named branch, a clean tracked worktree and
index, and no non-ignored untracked paths. Ignored legacy output is not deleted
or rewritten, but an incoming target that collides with it must fail closed.

The update command:

1. resolves the already-fetched exact target template ref;
2. returns a no-op when the target is already contained in `HEAD`;
3. records the pre-update HEAD, index/tree state, protected-path hashes, and
   target commit;
4. performs a no-fast-forward, no-commit merge transaction;
5. restores or reconciles the protected project-owned data below;
6. validates the staged working tree before creating the merge commit;
7. aborts and restores the recorded pre-state on any conflict, validation
   failure, or exception, and reports a rollback receipt.

The command operates on the user's current branch. It does not invent or
switch branches. A user who wants an update branch creates or selects it before
`-Apply`.

## Protected project data

Every derived-project update preserves:

- the complete pre-update `place.rbxl`;
- the project root `README.md`;
- `src/ReplicatedStorage/Project/**`;
- `docs/adr/project/**` when present;
- `docs/Features/project/**` when present;
- the derived project's own `default.project.json` identity fields.

For `default.project.json`, accept compatible incoming mappings and settings,
then overlay the local project `name`; exact local `placeId`, `gameId`, and
`servePlaceIds` when present; and an existing local `servePort`. If local cloud
identity is absent, remove all incoming template cloud identity fields. Never
copy template validation IDs into a game.

All other paths use ordinary three-way merge behavior. Non-overlapping local
changes survive without documentation ceremony. An unresolved overlap aborts
atomically and is reported for a focused user decision; the command never
silently chooses ours or theirs.

## Updating a legacy derived project

A checkout that does not yet contain the new tool may fetch the target ref,
extract that ref's single self-contained `scripts/template-project.ps1` to a
temporary file, and invoke it with the explicit repository path. Use Windows
PowerShell 5.1-compatible syntax. Do not execute the checkout's old lifecycle,
ADR-divergence workflow, validators, or pipeline state as a prerequisite.

Incoming deletion may untrack obsolete template-owned process artifacts.
Local untracked history remains untouched. Existing project feature and ADR
namespaces remain protected even when their legacy format is no longer
required by the template.

## Structural validation

Generic validation is bounded to repository structure, identity, and a small
set of source ownership deny predicates applied only to project-changed paths.
It must not scan unchanged runtime source or parse PRDs, specifications,
Markdown prose, Luau runner registrations, or ignored `/tests` and pipeline
evidence. Runtime behavior belongs to focused Luau and Studio suites.

The same staged filesystem content must have the same structural result before
and after the merge commit. A successful update is followed by a second update
check that reports no-op.

`validate -RepositoryRole Auto` detects ownership from the canonical remotes
and is the default. Explicit `Project` requires the canonical template
`upstream`. Explicit `Template` is a fail-closed escape hatch for a verified
template checkout whose canonical origin is temporarily unavailable; it is
rejected when an `upstream` remote exists. Validation is always read-only.

## Report

Report the previous and target template commits, applied outcome, protected
paths, conflicts or rollback, validation result, and whether the second check
was a no-op. Report omitted runtime checks according to `testing.md`; do not
run Studio merely because rules or repository tooling changed.
