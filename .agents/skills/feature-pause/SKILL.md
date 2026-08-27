---
name: feature-pause
description: Checkpoint an open repository feature when the user invokes $feature-pause or naturally asks to pause, stop for now, or hand off feature work. Do not infer Pause from a blocker or the end of a turn.
---

# Pause feature

Pause is a user-facing checkpoint, not a third feature state. The current
record remains `open`; the user does not need to run PowerShell.

1. Read `.agents/rules/feature-workflow.md` and resolve the requested writable
   feature with the read-only backend:

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/feature.ps1 status -RepositoryPath <exact-root> -Feature <ID-or-slug>
   ```

2. If the same message requests work before pausing, complete only that
   requested scope and its proportional checks first. Do not invent extra work
   or new verification solely to enrich a checkpoint.
3. Write or refresh `handoff.md` in the feature directory as a concise
   current summary with `State: open`, completed work, important decisions,
   checks run/not run, blockers, and one concrete next step. Preserve useful
   prior facts and append the checkpoint to `worklog.md` when that file exists.
4. Do not change `feature.json`, create a `paused` value, reserve a branch, or
   create a lease/dashboard. Report the feature ID and saved next step, then
   stop because the user asked to pause.

If the feature is already `done`, do not rewrite its current record or closed
handoff.
