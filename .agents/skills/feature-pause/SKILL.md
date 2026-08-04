---
name: feature-pause
description: Checkpoint and pause the current root writer session for an unfinished tracked feature. Use only when the user explicitly invokes `$feature-pause` or asks to stop current feature work without declaring the feature ready; do not use as a completion shortcut.
---

# Pause feature

1. Read `.agents/rules/feature-workflow.md` and resolve the active feature owned by the current task in the repository's writable namespace. Foreign template history in a derived repository is read-only.
2. Inspect Git status and capture a concise durable summary: completed work, uncommitted state, tests run or not run, blockers, and one next confirmed step. Do not claim checks that were not executed.
3. Run from the repository root:

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/feature-workflow.ps1 -Action Pause -Feature "<name-or-id>" -Summary "<summary>" -NextStep "<next-step>"
   ```

4. Let the lifecycle script read the current task ID directly from the app-provided `CODEX_THREAD_ID`. Never invent, override, or manually pass a task ID; repository hooks are not part of this workflow.
5. Verify that the manifest is `in_progress/paused`, `activeSessionId` is null, the worklog and handoff contain the checkpoint, the writer lease is gone, and only the owning namespace dashboard was synchronized.
6. Report that the branch remains reserved by the paused feature. Do not start another feature on it.
