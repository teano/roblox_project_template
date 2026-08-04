# ADR-0032: Track feature work with canonical manifests and explicit lifecycle commands

- Status: Accepted
- Date: 2026-08-04
- Deciders: Project maintainers
- Supersedes: None
- Superseded by: ADR-0033

## Context

Feature work spans Codex tasks, Git commits, uncommitted files, product and
technical documents, ADRs, tests, and runtime evidence. Git alone shows what
changed but not which feature owns the change, whether another task is already
writing that feature, which context must be restored, or whether the
documentation cascade and verification gates are complete.

A single mutable summary document would be convenient for people but would
duplicate per-feature state and drift. Raw chat transcripts are local,
potentially sensitive, and not a stable repository interface. Automatically
rewriting documentation from a Git hook would also hide agentic edits inside a
commit or push operation.

The reusable template and derived games additionally need independent feature
ID allocation, just as they require independent ADR ownership.

## Decision

Track each feature through one canonical JSON manifest under
`docs/Features/<feature-folder>/feature.json`. Generate the human-readable
`docs/Features/README.md` dashboard from those manifests. Template features use
immutable `TF-####` IDs; derived-game features use independently allocated
`PF-####` IDs.

Use four explicit repo-scoped Codex skills:

- `$feature-start` creates or starts planned work;
- `$feature-continue` restores a paused feature and its bounded context;
- `$feature-pause` checkpoints an unfinished writer session;
- `$feature-finish` performs the documentation, ADR, test, and evidence gates
  before marking the feature ready.

One `in_progress` manifest reserves its branch even while paused. One atomic
local lease under Git's common directory identifies the active root writer.
Linked requirements, review, QA, and historical tasks remain evidence but do
not create additional writers.

Codex lifecycle hooks provide verified current task IDs and startup context.
Git hooks are deliberately absent. The explicit `$feature-finish` chat command
runs deterministic manifest, dashboard, documentation, test, Git, Rojo, and
required runtime gates before marking work ready. Commit and push remain normal
user operations and never mutate feature documentation.

Durable handoff and worklog summaries are committed; raw transcripts and local
leases are not. Continue reads durable artifacts first and fetches targeted
task history only when a documented context gap remains.

## Alternatives considered

### Keep one hand-edited feature table

Rejected because human rows and per-feature evidence would become competing
sources of truth and concurrent updates would lose data.

### Infer a feature from branch and working-directory chats

Rejected because one repository can contain unrelated tasks, sequential
features, reviews, and paused work. Directory equality is not feature
ownership.

### Run an agent that mutates documentation inside Git hooks

Rejected because it is slow and nondeterministic, can unexpectedly alter the
index, and hides reviewable documentation changes inside a commit or push.

### Store every chat transcript in the repository

Rejected because transcript formats are not stable interfaces and may contain
irrelevant or sensitive context.

## Consequences

### Positive

- Maintainers can scan one synchronized table for project state.
- Feature ownership, branch baseline, sessions, blockers, and handoff survive
  chat boundaries.
- Parallel feature writers on one branch fail closed.
- Completion gates update documentation and ADRs before readiness is recorded.
- Template and derived feature identifiers do not collide.

### Negative

- Feature work requires explicit start, continue, pause, and finish commands.
- Repo-local Codex lifecycle hooks must be reviewed and trusted by each Codex
  installation so task identity cannot be guessed.
- Historical imports may contain unknown branch, time, or task fields.
- A paused feature continues to reserve its branch until finished or explicitly
  recovered elsewhere.

## Enforcement

- Agent rules: `AGENTS.md`, `.agents/rules/index.md`,
  `.agents/rules/feature-workflow.md`, `.agents/rules/testing.md`
- Current documentation: `docs/Features/README.md`,
  `docs/Features/feature-workflow/product-requirements.md`,
  `docs/Features/feature-workflow/technical-specification.md`
- Code boundaries: `.agents/skills/feature-*`, `.codex/config.toml`,
  `scripts/FeatureWorkflow.psm1`, `scripts/feature-workflow.ps1`,
  `docs/Features/*/feature.json`
- Tests: `scripts/tests/feature-workflow.tests.ps1`,
  `scripts/validate-feature-workflow.ps1`,
  `scripts/validate-repository-layout.ps1`
