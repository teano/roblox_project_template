# Feature workflow rules

## Scope

Apply when starting, continuing, pausing, finishing, indexing, or validating
feature work, and when changing files under `docs/Features/`, `.agents/skills/`,
`.codex/` lifecycle hooks, or the feature-workflow scripts.

Required context: `architecture.md`, `architecture-decisions.md`, `testing.md`,
`docs/adr/README.md`, template/ADR-0032, and every subsystem rule selected by
the feature's affected paths and architectural concerns.

## Canonical state

- Every tracked feature MUST own exactly one
  `docs/Features/<feature-folder>/feature.json` manifest.
- A manifest ID is immutable and unique. The reusable template allocates
  `TF-####`; a derived repository allocates `PF-####`.
- `docs/Features/README.md` is a human dashboard generated only from manifests.
  Its generated block MUST NOT be edited by hand.
- Durable state, linked task IDs, handoff, worklog, blockers, artifacts, and
  verification summaries live under the feature folder. Raw Codex transcripts,
  secrets, process IDs, and ephemeral locks MUST NOT be committed.
- Unknown historical task IDs, branches, or commits remain `null` or omitted;
  agents MUST NOT guess them.

## State machine

- `planned -> in_progress/active` only through `$feature-start`.
- `in_progress/active -> in_progress/paused` only through `$feature-pause`.
- `in_progress/paused -> in_progress/active` only through
  `$feature-continue`.
- `in_progress/active -> ready/none` only through `$feature-finish` after all
  required gates pass.
- Reopening `ready` work requires `$feature-start` with an explicit reopen
  reason. The prior sessions and completion evidence remain historical.

`$feature-finish` is not a synonym for ending a Codex turn. An unfinished
feature is paused, never marked ready to release a branch reservation.

## Branch and writer exclusion

- A named branch may have at most one manifest with status `in_progress`,
  including a paused feature.
- Starting or continuing another feature on that branch MUST fail closed.
- An active feature has one root writer task. Review, requirements, QA, and
  subagent tasks may be linked, but they do not acquire a second writer lease.
- The writer lease is an atomic local directory under the repository's Git
  common directory. It is guardrail state, not documentation, and MUST NOT be
  committed.
- A live lease owned by another task MUST NOT be stolen. Recovery from a stale
  or unavailable task requires an explicit reason recorded in the manifest and
  worklog.
- Feature start requires a named branch and a clean worktree unless the user
  explicitly authorizes adopting the existing changes into that feature.
- `baseCommit` is the exact `HEAD` at first start and remains immutable. A
  rebase that makes it no longer an ancestor is a blocking metadata migration,
  not permission to silently replace it.

## Context and task links

- Codex task IDs come from lifecycle-hook input or verified app/task APIs.
- Continue context is loaded in this order: manifest, `handoff.md`, approved
  PRD and specification when present, `worklog.md`, Git changes from
  `baseCommit`, matched rules and ADRs, then targeted linked-task history only
  for unresolved gaps.
- Do not load every raw transcript by default. Prefer durable handoff and
  worklog summaries and read only the task turns needed to resolve a gap.
- Before editing after continue, report the resolved feature ID, state, branch,
  base commit, completed work, remaining work, blockers, and next confirmed
  step.

## Command gates

### Start

- Reject `ready` work unless a reopen reason is explicit.
- Reject a different `in_progress` feature on the branch.
- Create missing service artifacts and acquire the writer lease before source
  edits. Missing product requirements or specification remains a documented
  blocker until the applicable requirements/specification workflow resolves it.

### Continue

- Require `in_progress/paused`, the recorded branch, an ancestor
  `baseCommit`, and no conflicting lease.
- Register the new sequential root task, acquire the lease, synchronize the
  dashboard, and reconstruct context before source edits.

### Pause

- Require ownership by the current root task.
- Update `handoff.md` and `worklog.md`, close the session as paused, clear
  `activeSessionId`, release the writer lease, and retain `in_progress` so the
  branch remains reserved.

### Finish

- Require ownership by the current root task and a complete scope audit.
- Update all affected current documentation, tests, manifests, rules, and ADR
  indexes. Create an ADR only for a durable decision; never rewrite Accepted
  history.
- Run every matched verification gate. Missing Studio, user, environment, or
  evidence gates keep the feature `in_progress` and are recorded as blockers.
- Only a blocker-free verified feature becomes `ready`; then close the session,
  release the lease, and synchronize the dashboard.
- Git hooks are not part of this workflow. The agent runs all finish gates
  explicitly from the chat command; commit and push do not mutate or validate
  feature state automatically.

## Verification

- `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/validate-feature-workflow.ps1`
- `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/sync-feature-index.ps1 -Check`
- `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/validate-repository-layout.ps1`
- `git diff --check`
- Rojo build and every suite selected by affected subsystem rules.
