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
  `upstream/main`, excluding `docs/adr/project/`.
- A **project divergence** is an intentional local modification, deletion, or
  rename of a template-owned path.
- An **empty project import** has no initialized project ADR namespace and no
  existing canonical `place.rbxl` before the first template merge.
- An **initialized project** has `docs/adr/project/README.md` and owns its
  current complete `place.rbxl`.

## Creating project divergence

Before or in the same change that modifies a template-owned path:

1. Identify the exact upstream baseline commit.
2. Read the affected template ADRs, subsystem rules, and current project ADRs.
3. Create a project ADR with the structured `Template divergence` section
   required by `architecture-decisions.md`.
4. List every changed template-owned path exactly.
5. State the project invariant and a future merge policy for each path.
6. Add or update tests that enforce the behavior.

An undocumented template divergence is a blocking defect. Do not guess its
historical intent during an upstream merge.

## Pre-merge inspection

Before merging:

1. Require a clean worktree and update local `main` from `origin` with a
   fast-forward-only pull.
2. Fetch `upstream` and record:
   - the pre-merge project commit;
   - the previous template merge-base;
   - the target `upstream/main` commit.
3. Inspect incoming template changes from the previous merge-base to
   `upstream/main`.
4. Inspect project divergences from the previous merge-base to the current
   project tree.
5. Intersect incoming paths with project-divergence paths.
6. For every intersection, locate and read the project ADR that names the
   exact path.
7. Stop before merging when a local template-owned change has no project ADR.

Perform the update in a dedicated branch. Do not merge directly into a dirty
or unreviewed `main`.

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

## Required merge report

Every user-facing completion message for a template merge MUST include:

- previous and new template commit IDs;
- incoming files or systems applied as-is;
- whether `place.rbxl` was imported or the project version was preserved;
- every locally changed template path, the project ADR consulted, and the
  chosen resolution;
- conflicts, stopped decisions, or manual follow-up;
- tests, Rojo build, Studio Play checks, and anything not run.

Do not report only “merged successfully.” The user must be able to see exactly
what happened to template and project-owned behavior.

## Verification

- `scripts/validate-repository-layout.ps1`.
- `git diff --check`.
- Rojo build to a temporary output.
- Every suite required by the affected subsystem rules.
- Clean Studio Play and server/client output inspection when bootstrap,
  networking, save, player lifecycle, executable placement, or canonical scene
  behavior is affected.
