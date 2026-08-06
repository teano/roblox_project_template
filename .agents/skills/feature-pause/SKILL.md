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
2. Inspect Git status and prepare a self-contained checkpoint for an agent with no access to this chat. Include completed work and uncommitted state; every important decision, rejected alternative, and discussion outcome; checks run or not run; blockers; and one next confirmed step. State explicitly when a section has no items.
3. Run from the repository root:

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/feature-workflow.ps1 -Action Pause -Feature "<name-or-id>" -Summary "<result-and-state>" -Decisions "<important-decisions-and-discussions>" -VerificationSummary "<checks-run-and-not-run>" -NextStep "<next-step>"
   ```

4. Do not include chat links or task/session/agent identifiers. Verify that the manifest is `in_progress/paused`, the worklog and handoff contain every checkpoint section, the feature-scoped lease is gone, and only the owning namespace dashboard was synchronized.
5. Report that the branch remains reserved by the paused feature. Do not start another feature on it.
