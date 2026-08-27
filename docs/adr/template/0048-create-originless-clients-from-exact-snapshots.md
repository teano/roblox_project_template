# ADR-0048: Create originless clients from exact template snapshots

- Status: Accepted
- Date: 2026-08-27
- Deciders: Project maintainers
- Supersedes: None
- Superseded by: None

## Context

Some local client projects intentionally do not have a Git repository. Copying
the template working tree would leak ignored or unfinished local files, while
silently creating a repository or custom baseline metadata would change the
client's ownership model. These clients still need deterministic initialization
and convenient feature bookkeeping.

## Decision

Add one originless `init` route alongside the existing Git workflows. It
requires an exact local template Git root, a full commit ID, and an absent or
empty destination outside every Git worktree. Apply exports that tracked commit
with `git archive`, performs the existing project-name, cloud-identity, README,
and derived-UI transforms in guarded sibling staging, validates and builds the
candidate, then publishes it atomically. It creates no `.git`, remote, commit,
push, marker, schema, originless update, or originless repair mechanism.

The feature backend recognizes such a root only as a derived project and only
when it has a non-template Rojo name plus the exact project-owned
`DerivedWindowConfig.luau` path. Broken Git metadata and nesting inside another
worktree fail closed; inherited template feature records remain read-only.

## Alternatives considered

### Copy the template working directory

Rejected because ignored, untracked, and unfinished files would make the
result depend on local machine state instead of the selected commit.

### Create hidden Git or baseline metadata

Rejected because the requested client is originless and does not need a second
update model or persistent synchronization state.

## Consequences

### Positive

- Local client creation is deterministic and leaves no repository artifacts.
- Failed initialization restores the exact absent or empty destination state.
- Optional `F-####` records work without asking the user to run PowerShell.

### Negative

- Originless clients do not receive automated template update or repair.
- Creating another snapshot requires another empty destination.

## Enforcement

- Agent rules: `AGENTS.md`, `.agents/rules/template-workflow.md`,
  `.agents/rules/feature-workflow.md`.
- Current documentation: `README.md`, `docs/TemplateWorkflow.md`,
  `docs/FeatureDevelopmentForBeginners.md`.
- Code boundaries: `scripts/template-project.ps1`, `scripts/feature.ps1`.
- Tests: `scripts/tests/template-tools.tests.ps1` under Windows PowerShell 5.1
  and PowerShell 7.
