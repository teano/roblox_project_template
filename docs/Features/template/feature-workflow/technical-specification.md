# Feature Work Management — Technical Specification

- Status: Approved
- Date: 2026-08-04

## Components

- `scripts/FeatureWorkflow.psm1` owns manifest validation, ID allocation,
  branch exclusion, atomic Git-common-dir writer leases, task history, handoff,
  worklog, namespace ownership, and dashboard rendering.
- `scripts/feature-workflow.ps1` exposes `Start`, `Continue`, `Pause`, `Finish`,
  and read-only `Context` actions.
- `scripts/sync-feature-index.ps1` writes or checks the generated dashboard.
- `scripts/validate-feature-workflow.ps1` validates all manifests, unique IDs,
  legal state combinations, branch reservations, and dashboard equality.
- `.agents/skills/feature-*` are explicit orchestration commands over the
  deterministic scripts.
- `scripts/codex-feature-hook.ps1` injects verified `session_id` into exact
  feature state-transition tool calls and supplies branch context at session
  start.
- `$feature-finish` explicitly runs deterministic repository, documentation,
  test, Git, Rojo, and required runtime gates from chat. Git commit and push do
  not trigger feature automation.

## Namespace contract

- `docs/Features/README.md` routes to the two namespaces and is never generated
  from feature manifests.
- `docs/Features/template/<feature>/feature.json` and
  `docs/Features/template/README.md` are template-owned and contain only
  `TF-####` records.
- `docs/Features/project/<feature>/feature.json` and
  `docs/Features/project/README.md` are derived-project-owned and contain only
  `PF-####` records. The template repository does not contain this directory.
- Repository role selects the only writable namespace. Discovery and branch
  exclusion inspect every visible namespace; lifecycle mutations and normal
  dashboard synchronization touch only the writable namespace.
- Full validation checks both dashboards. A derived repository may report
  template dashboard drift but cannot repair it through a project feature
  command.

## State transitions

`planned/none -> in_progress/active -> in_progress/paused ->
in_progress/active -> ready/none`.

Only one `in_progress` manifest may name a branch. Only one local lease may
name its root writer. Ready work may reopen through Start only with an explicit
reason retained in `recoveryLog`.

## Context contract

Continue reads manifest, handoff, approved requirements/specification,
worklog, Git range, matched rules and ADRs, then targeted linked-task turns.
Task transcripts are supplemental and never override current repository
authority.

## Failure behavior

Invalid state, detached HEAD, dirty new start, branch mismatch, non-ancestor
base, namespace/prefix mismatch, foreign-namespace mutation, duplicate ID or
same-namespace slug, dashboard drift, another feature reservation, another
writer, remaining blockers, or missing completion summaries fail closed
without advancing the feature state.
