---
name: feature-finish
description: Perform the complete documentation, ADR, test, evidence, and Git audit for the active tracked feature and mark it ready only when every gate passes. Use only when the user explicitly invokes `$feature-finish` or asks to finalize a named feature; do not use merely to end a turn or pause unfinished work.
---

# Finish feature

1. Read `AGENTS.md`, `.agents/rules/index.md`, `.agents/rules/feature-workflow.md`, the feature manifest, handoff, worklog, approved requirements/specification, and every affected rule and Accepted ADR. Confirm that the feature belongs to the repository's writable namespace before any completion mutation.
2. Freeze the complete feature inventory before remediation: linked tasks, Git range from `baseCommit`, commits, staged/unstaged/untracked files, affected systems, acceptance criteria, documentation, ADR decisions, tests, runtime gates, and blockers. Continue after the first finding.
3. Resolve the complete frozen batch. Cascade updates through current product and technical documents, system docs, test coverage, agent rules, and ADR indexes. Create or supersede an ADR only for a durable decision; never rewrite Accepted history.
4. Run every matched test and verification command yourself, including the feature workflow validator, checks for every visible namespace dashboard, repository-layout validator, `git diff --check`, Rojo build, and required Studio/runtime gates. Record missing external evidence as blockers; do not mark ready or rewrite a foreign dashboard.
5. Resweep the entire feature scope. Proceed only when blockers are empty and all required evidence is current.
6. Run from the repository root with concise factual summaries:

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/feature-workflow.ps1 -Action Finish -Feature "<name-or-id>" -Summary "<delivered-outcome>" -VerificationSummary "<commands-and-results>"
   ```

7. Let the lifecycle script read the current task ID directly from the app-provided `CODEX_THREAD_ID`. Never invent, override, or manually pass a task ID; repository hooks are not part of this workflow.
8. Verify `ready/none`, closed task history, released writer lease, updated handoff/worklog, and synchronized visible dashboards. Report every check not run and its concrete reason.
