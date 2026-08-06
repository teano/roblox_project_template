# Feature Work Management — Product Requirements

- Status: Superseded by TF-0007
- Date: 2026-08-04

Current requirements: [TF-0007 product requirements](../agent-agnostic-feature-workflow/product-requirements.md).

## Outcome

Give template maintainers and derived-game teams one shared feature lifecycle
with separately owned, synchronized feature registries, so upstream template
updates cannot rewrite or conflict with a game's feature set while branch and
writer exclusion still apply across the complete repository.

## Requirements

- Each feature has one stable manifest ID, state, activity, branch, base
  commit, linked tasks, blockers, artifacts, handoff, and worklog.
- Template manifests and artifacts live only under `docs/Features/template/`;
  derived-game manifests and artifacts live only under
  `docs/Features/project/`.
- Each namespace has its own generated dashboard and fails validation on drift.
  The root `docs/Features/README.md` is a stable namespace router.
- Template and derived project IDs use independent `TF-####` and `PF-####`
  sequences. Lifecycle mutations write only the repository's owning namespace.
- A derived repository can read template feature history but cannot start,
  reopen, continue, pause, finish, or regenerate a template feature.
- Upstream merge handling preserves the complete project feature namespace and
  does not classify it as template divergence.
- Start rejects dirty or already-reserved branches unless existing changes are
  explicitly adopted.
- Continue restores bounded durable context before targeted task history.
- Pause closes the writer task but retains the branch reservation.
- Finish performs the documentation, ADR, test, runtime-evidence, and Git gates
  and cannot mark blocked work ready.
- Lifecycle commands resolve verified task identity directly from the
  app-provided `CODEX_THREAD_ID`. Codex and Git hooks are not installed; the
  explicit skills own context recovery and all completion gates.
- Raw transcripts and local locks are never committed.

## Acceptance

- Positive, negative, boundary, recovery, and state-transition script tests
  pass in isolated temporary repositories.
- A derived-repository fixture allocates `PF-0001` under the project namespace,
  leaves the template dashboard byte-identical, rejects mutation of `TF-####`,
  and detects foreign-dashboard drift without rewriting it.
- All four skills validate, require explicit invocation, and work without
  repository hook trust or installation.
- Existing Teleport and Players work plus planned Statistic Collection appear
  only in the generated template dashboard with verified task IDs and no
  invented data.
- Repository layout, dashboard synchronization, Git whitespace, and Rojo build
  gates pass.
