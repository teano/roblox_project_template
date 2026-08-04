# Feature Work Management — Product Requirements

- Status: Approved
- Date: 2026-08-04

## Outcome

Give maintainers a visible, synchronized feature dashboard and four explicit
commands that start, continue, pause, and finish feature work without allowing
two in-progress features or two root writers on one branch.

## Requirements

- Each feature has one stable manifest ID, state, activity, branch, base
  commit, linked tasks, blockers, artifacts, handoff, and worklog.
- The dashboard is generated from manifests and fails validation on drift.
- Template and derived project IDs use independent `TF-####` and `PF-####`
  sequences.
- Start rejects dirty or already-reserved branches unless existing changes are
  explicitly adopted.
- Continue restores bounded durable context before targeted task history.
- Pause closes the writer task but retains the branch reservation.
- Finish performs the documentation, ADR, test, runtime-evidence, and Git gates
  and cannot mark blocked work ready.
- Codex hooks supply verified task identity and startup context. Git hooks are
  not installed; the explicit finish chat command owns all completion gates.
- Raw transcripts and local locks are never committed.

## Acceptance

- Positive, negative, boundary, recovery, and state-transition script tests
  pass in isolated temporary repositories.
- All four skills validate and require explicit invocation.
- Existing Teleport and Players work plus planned Statistic Collection appear
  in the generated dashboard with verified task IDs and no invented data.
- Repository layout, dashboard synchronization, Git whitespace, and Rojo build
  gates pass.
