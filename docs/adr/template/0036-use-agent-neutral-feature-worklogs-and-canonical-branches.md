# ADR-0036: Use agent-neutral feature worklogs and canonical branches

- Status: Accepted
- Date: 2026-08-06
- Deciders: Project maintainers
- Supersedes: ADR-0034
- Superseded by: ADR-0037

## Context

ADR-0034 removes repository hooks but still binds every state-changing feature
action to `CODEX_THREAD_ID`. Manifests retain `activeSessionId` and full task
history, worklogs link checkpoints to Codex sessions, and the local writer
lease names the active session. Another agent product cannot supply that
identity or recover the linked transcript, so the nominally repository-owned
workflow remains Codex-specific.

The former `$feature-finish` also owns the complete test, build, runtime, Git,
documentation, and ADR audit. This duplicates checks already completed during
implementation and makes a state/documentation transition responsible for
executing unrelated subsystem verification.

Feature branches are not created by the lifecycle engine and their naming is
inconsistent. Derived-project IDs use `PF-####`, while the required public
project convention is `F-####` with a separate branch prefix.

## Decision

Keep ADR-0034's separate template/project registries and repository-wide branch
reservation, but replace task ownership with portable repository context:

- manifest schema version 2 removes `activeSessionId`, `sessions`, `threadId`,
  `hostId`, and all agent/chat ownership fields;
- lifecycle commands neither read nor accept `CODEX_THREAD_ID` or an
  equivalent identity token;
- the Git-common-dir writer lease is feature-scoped and contains only schema
  version, branch, feature ID, and creation time;
- `worklog.md` is the complete append-only cross-chat history. Every pause and
  finish checkpoint records result/current state, important decisions and
  discussions, verification state, blockers, and next step;
- `handoff.md` is only the latest checkpoint projection; `Continue` recovers
  context from repository artifacts, Git, rules, current documentation, and
  ADRs without transcript lookup;
- dashboards link directly to worklog instead of displaying session counts.

The lifecycle engine creates canonical branches when it starts new work:

- template: `TF-####` on `template-feature/tf-####-<slug>`;
- derived project: `F-####` on `feature/t-####-<slug>`.

Existing historical branch names remain recorded. New creation fails closed
when the canonical branch already exists.

`$feature-finish` is a documentation and state-finalization workflow. It reads
existing evidence, requires empty blockers and completed implementation,
updates the complete documentation/ADR cascade, writes the final checkpoint,
and marks the feature ready. It does not run tests, validators, builds, Rojo
preflight, or Studio operations; those gates run before finish under the
affected subsystem rules.

## Alternatives considered

### Replace Codex task IDs with generic agent IDs

Rejected because usernames, host IDs, product task IDs, and random owner tokens
still make durable state depend on one agent runtime and do not provide the
missing discussion context.

### Keep task links and add summaries beside them

Rejected because future agents would still treat unavailable transcripts as a
context source, while the repository worklog would remain incomplete.

### Remove the writer lease entirely

Rejected because an atomic feature-scoped lease still prevents two different
features from claiming one branch without restricting which agent may continue
the same feature.

### Let finish rerun a minimal validator set

Rejected because even a minimal embedded set obscures which subsystem gates
were required and creates two owners for verification. Finish records evidence;
the implementation workflow executes it.

## Consequences

### Positive

- Any compatible agent or chat can continue from committed repository state.
- Important design discussion survives chat loss as explicit worklog prose.
- Feature state contains no external task identity or transcript dependency.
- New feature IDs and branches are deterministic and namespace-specific.
- Finish is fast, deterministic, and cannot accidentally repeat runtime work.

### Negative

- Agents must write a more complete checkpoint at every pause and finish.
- A feature-scoped lease does not distinguish simultaneous agents working on
  the same feature; they must coordinate through the shared branch/worklog.
- Existing manifests and checkpoint metadata require a one-time schema-v2
  migration.
- Derived repositories with legacy `PF-####` history must migrate their owned
  project manifests when adopting this lifecycle contract.

## Enforcement

- Agent rules: `AGENTS.md`, `.agents/rules/feature-workflow.md`,
  `.agents/rules/project-initialization.md`,
  `.agents/rules/template-updates.md`
- Current documentation: `README.md`, `docs/Features/README.md`,
  `docs/Features/template/agent-agnostic-feature-workflow/product-requirements.md`,
  `docs/Features/template/agent-agnostic-feature-workflow/technical-specification.md`
- Code boundaries: `.agents/skills/feature-*`,
  `docs/Features/_schema/feature-manifest.schema.json`,
  `scripts/FeatureWorkflow.psm1`, `scripts/feature-workflow.ps1`
- Tests: `scripts/tests/feature-workflow.tests.ps1`,
  `scripts/validate-feature-workflow.ps1`,
  `scripts/validate-repository-layout.ps1`
