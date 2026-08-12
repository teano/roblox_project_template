---
name: feature-pause
description: Record a complete cross-chat checkpoint and pause unfinished tracked feature work only after the current user message explicitly requests Pause. Never infer Pause from the end of a turn, a generic stop instruction, unfinished work, a blocker, or agent convenience; do not use it as a completion shortcut.
---

# Pause feature

## User authorization gate

Only an explicit request in the current user message authorizes this lifecycle
transition. The end of an agent turn, a blocker, unfinished work, or a bare
request to stop the current response does not implicitly authorize Pause. If
intent is ambiguous, stop the response while leaving feature state unchanged
and ask the user whether Pause is desired.

1. Read `.agents/rules/feature-workflow.md` and resolve the active feature in the repository's writable namespace. Foreign template history in a derived repository is read-only. Require the recorded branch to be current and its exact schema-v2 feature lease to exist before checkpoint mutation.
2. Prepare a self-contained checkpoint from facts already known before Pause. Include completed work and already known uncommitted state; every important decision, rejected alternative, and discussion outcome; checks already run or known not to have run; blockers; and one informational next step. State explicitly when a section has no items.
3. Run from the repository root:

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/feature-workflow.ps1 -Action Pause -Feature "<name-or-id>" -Summary "<result-and-state>" -Decisions "<important-decisions-and-discussions>" -VerificationSummary "<checks-run-and-not-run>" -NextStep "<next-step>"
   ```

4. Do not include chat links or task/session/agent identifiers.
5. After the command succeeds, report only that the feature is paused, its branch remains reserved, and the factual checkpoint was written. Do not reread or separately verify the manifest, handoff, complete worklog, lease, or dashboard.

## Pause-only factual checkpoint boundary

Pause-only factual checkpoint: use only facts already known before Pause; do not create new verification evidence, run new work or checks, or create or use subagents.

Pause-only post-command boundary: after successful Pause, report the command result without new reads or checks.

Do not inspect Git, source, controller state, tests, or other context merely to enrich the checkpoint. Do not run implementation, review, audit, pipeline, validators, Rojo preflight/build, or Studio. Unknown or not-run verification remains explicitly factual; it is not a reason to expand Pause scope.
