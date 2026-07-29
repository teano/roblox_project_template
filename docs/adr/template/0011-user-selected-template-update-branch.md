# ADR-0011: Let the user choose the template update destination branch

- Status: Accepted
- Date: 2026-07-29
- Deciders: Project maintainers
- Supersedes: None
- Superseded by: None

## Context

A derived project may already use a branch created by its maintainer for
reviewing a template update. Always forcing a new dedicated branch disregards
that workflow. Merging directly without confirmation is also unsafe because
the current branch may be protected, shared, or intended for unrelated work.
Allowing an agent to invent a branch name makes repeated updates difficult to
identify and reproduce.

No merge is necessary when the current project commit already contains the
latest fetched `upstream/main`. Branch selection must therefore happen only
after the agent establishes that an update exists.

## Decision

Before a template merge, require a clean worktree and a named current branch,
fetch `upstream`, and check whether `upstream/main` is an ancestor of the
current `HEAD`. When it is, report that the project is current and make no
merge or branch change.

When an update exists, record the current project commit, its merge-base with
`upstream/main`, and the target template commit. Show that context and ask the
user to choose between:

1. merging into the current branch;
2. creating an update branch from the current `HEAD` and merging there.

The generated branch name is
`template-update/{commit_from}_{commit_to}`, using the first 12 hexadecimal
characters of the merge-base and target template commit. A reviewed first
import with unrelated histories uses
`template-update/initial_{commit_to}`. An existing branch with that name is a
blocking collision and is never reset, overwritten, reused, or selected
without further user direction.

The selected destination does not change the ADR-grounded merge, canonical
place preservation, conflict, verification, or reporting requirements defined
by ADR-0010. Branch selection does not implicitly authorize pulling another
branch, pushing the result, or opening a pull request.

## Alternatives considered

### Always create a dedicated branch

Rejected because the user may already have created and selected the branch
that should own the merge.

### Always merge into the current branch

Rejected because it can modify a protected, shared, or otherwise unintended
branch without explicit confirmation.

### Let the agent choose any branch name

Rejected because arbitrary names make update attempts harder to recognize,
repeat, and audit.

### Ask before checking whether an update exists

Rejected because it prompts the user for a choice that has no effect when the
current branch already contains the latest template commit.

## Consequences

### Positive

- Project maintainers retain control over their branching workflow.
- Up-to-date projects are left untouched.
- Agent-created update branches have reproducible, auditable names.
- Repeated or stale update attempts are visible as branch-name collisions.

### Negative

- A real update requires one explicit user decision before the merge starts.
- Existing deterministic branch names require another user decision.
- Detached `HEAD` and dirty-worktree states block automated updates.

## Enforcement

- Agent rules: `AGENTS.md`, `.agents/rules/template-updates.md`
- Current documentation: `README.md`
- Code boundaries: Git current branch, `HEAD`, `upstream/main`
- Tests: `scripts/validate-repository-layout.ps1`, `git diff --check`
