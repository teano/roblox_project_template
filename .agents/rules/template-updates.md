# Template upstream update rules

## Scope

Apply in a derived repository when:

- fetching, reviewing, merging, or resolving the template `upstream`;
- modifying, deleting, or renaming a path also supplied by the template;
- deciding whether an incoming template file or the project version wins.

Required context: `architecture-decisions.md`, `rojo-project.md`,
`testing.md`, the template ADR index, the project ADR index, every project ADR
that documents a touched template path, and every affected subsystem rule.

## Definitions

- A **template-owned path** is a path present in the merge-base or fetched
  `upstream/main`, excluding `docs/adr/project/` and
  `docs/Features/project/`.
- A **project divergence** is an intentional local modification, deletion, or
  rename of a template-owned path.
- An **active owning ADR** has status `Accepted`, names the exact path in its
  `Template divergence` `Paths` list, and has not been superseded.
- An **empty project import** has no initialized project ADR namespace and no
  existing canonical `place.rbxl` before the first template merge.
- An **initialized project** has `docs/adr/project/README.md` and owns its
  current complete `place.rbxl`.

## Creating project divergence

Before or in the same change that modifies a template-owned path:

1. Identify the exact upstream baseline commit.
2. Read the affected template ADRs, subsystem rules, and current project ADRs.
3. Search active owning project ADRs for the exact path.
4. When an active ADR already owns the path and its invariant and upstream
   merge policy still describe the intended change, reuse that ADR. Do not
   create another ADR and do not rewrite the Accepted record.
5. When no active ADR owns a newly diverged path, create one project ADR with
   the structured `Template divergence` section required by
   `architecture-decisions.md`.
6. When the invariant or upstream merge policy changes, create a new project
   ADR that supersedes the previous owning ADR.
7. In a new ADR, list every newly owned template path exactly and state the
   project invariant and future merge policy for each path.
8. Add or update tests that enforce the behavior.

An undocumented template divergence is a blocking defect. Do not guess its
historical intent during an upstream merge. Multiple active ADRs owning the
same exact template path are also a blocking defect; resolve the decision
lifecycle instead of choosing one arbitrarily.

## Pre-merge inspection

Before merging:

1. Require a clean worktree and a named current branch. Stop on detached
   `HEAD`; do not invent a destination branch.
2. Fetch `upstream`.
3. Check whether `upstream/main` is already an ancestor of the current `HEAD`.
   If it is, report that the current branch already contains the latest
   template commit and stop without creating a branch or running a merge.
4. When an update exists, record:
   - the pre-merge project commit;
   - the previous template merge-base;
   - the target `upstream/main` commit.
5. Inspect incoming template changes from the previous merge-base to
   `upstream/main`.
6. Inspect project divergences from the previous merge-base to the current
   project tree.
7. Intersect incoming paths with project-divergence paths.
8. For every intersection, locate and read the project ADR that names the
   exact path.
9. Stop before merging when a local template-owned change has no project ADR.

Do not switch branches or start the merge until the user chooses one of these
destinations:

- merge `upstream/main` into the current named branch;
- create a deterministic update branch from the current `HEAD`, switch to it,
  and merge there.

For a shared history, name the update branch
`template-update/{commit_from}_{commit_to}`, where both values are the first 12
hexadecimal characters of the recorded merge-base and target template commit.
For the reviewed first import with unrelated histories, use
`template-update/initial_{commit_to}`. If that local branch name already exists,
do not reset, overwrite, reuse, or switch to it automatically; report the
collision and ask the user.

The user's branch choice changes only where the merge is performed. It does not
waive clean-worktree, ADR, conflict-resolution, canonical-place, verification,
or reporting requirements. Do not pull another branch, push the result, or
open a pull request unless the user's request separately authorizes that
action.

## Merge policy

### Canonical place

- During an empty project import, accept template `place.rbxl` unchanged.
- In an initialized or otherwise non-empty project, preserve the exact complete
  pre-merge project `place.rbxl`, even when only upstream changed the file and
  Git reports no conflict.
- Restore the whole file from the recorded pre-merge project commit. Never
  combine, patch, or hex-edit binary place content.
- Report that an incoming template place was ignored. If its scene changes are
  desired, replay them manually in Roblox Studio as a separate authorized
  project change.

### Rojo project identity, cloud identity, and shared default endpoint

- Treat the initialized project's `default.project.json` `name` and required
  absence of `servePort` as project-owned values documented by project
  ADR-0001. When the project is published, also treat its recorded `placeId`,
  `gameId`, and `servePlaceIds` as project-owned values documented by the
  active owning project ADR.
- When upstream also changes `default.project.json`, reconcile the JSON
  structure and apply compatible incoming mappings or settings. Preserve the
  project's current `name`, keep `servePort` absent, and preserve the exact
  published cloud identity fields when present.
- Template `placeId`, `gameId`, and `servePlaceIds` values are non-inheritable.
  Never copy them into a derived repository during an upstream merge. Preserve
  the derived project's own verified values when published; when its identity
  is unresolved, keep all three fields absent.
- If an existing project ADR still requires a custom `servePort`, report
  architectural drift and create a superseding project decision before
  removing it; do not silently rewrite Accepted project history.
- If the active owning project ADR does not name `default.project.json`, does
  not state the name/shared-endpoint invariant, omits existing cloud identity
  fields, or disagrees with the current values, stop and ask the user instead
  of guessing which identity policy should win.

### Text source, scripts, services, rules, and documentation

- Apply incoming template additions, modifications, and deletions as delivered
  when the project has no local divergence on those paths.
- When the project changed a touched template-owned path, use its project ADR
  to preserve the stated invariant and follow its merge policy.
- If the ADR is missing, ambiguous, stale, contradicted by code/tests, or does
  not explain a safe durable resolution, stop with the merge uncommitted and
  ask the user what outcome should own the path.
- Do not silently choose `ours` or `theirs`, discard project behavior, or add a
  compatibility workaround that the ADR does not justify.
- If resolution changes the durable project invariant or future merge policy,
  create a new project ADR that supersedes the previous decision.

Project ADR files and their index are project-owned and MUST NOT be replaced by
template content.

Project feature manifests, artifacts, and `docs/Features/project/README.md`
are also project-owned and MUST NOT be replaced, regenerated from template
features, or added to a project divergence ADR. Incoming template feature
history applies only under `docs/Features/template/`; its generated dashboard
must contain only `TF-####` records. Project-owned feature history uses
`F-####` records and remains under `docs/Features/project/`. After the merge,
validate both namespace dashboards without rewriting the foreign namespace.

## Required merge report

Every user-facing completion message for a template merge MUST include:

- previous and new template commit IDs;
- incoming files or systems applied as-is;
- whether `place.rbxl` was imported or the project version was preserved;
- every locally changed template path touched by the incoming update, the
  existing project ADR consulted, and the chosen resolution;
- conflicts, stopped decisions, or manual follow-up;
- tests, Rojo build, Studio Play checks, and anything not run.

Do not report only “merged successfully.” The user must be able to see exactly
what happened to template and project-owned behavior. Do not enumerate an
untouched divergence merely because it exists; mention it only when incoming
changes touched its path, its ADR guided a resolution, or verification found a
problem there.

## Verification

- `scripts/validate-repository-layout.ps1`.
- `git diff --check`.
- Rojo build to a temporary output.
- Every suite required by the affected subsystem rules.
- Clean Studio Play and server/client output inspection when bootstrap,
  networking, save, player lifecycle, executable placement, or canonical scene
  behavior is affected.
