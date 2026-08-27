---
name: feature-finish
description: Finish and close a repository feature when the user invokes $feature-finish or naturally asks to finish, complete, or close feature work. Verify the actual outcome before marking the record done.
---

# Finish feature

Finish is the user-facing completion workflow. `scripts/feature.ps1 close` is
only its bookkeeping backend; the user does not need to run PowerShell.

1. Read `AGENTS.md`, `.agents/rules/index.md`,
   `.agents/rules/feature-workflow.md`, the writable feature record and current
   handoff/worklog, then the rules and documentation for the affected paths.
2. Resolve current state. If it is already `done`, report the idempotent result
   without rewriting history.
3. Complete only the remaining work implied by the feature's accepted scope.
   Run the proportional checks required by `.agents/rules/testing.md` and the
   affected subsystem rules. Update current documentation when the delivered
   behavior made it stale.
4. If implementation, required evidence, documentation, or a reproducible
   blocker remains, do not close the record. Report the exact remaining item.
5. When the outcome is complete, write a concise final handoff/worklog receipt
   and invoke:

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/feature.ps1 close -RepositoryPath <exact-root> -Feature <ID-or-slug>
   ```

6. Confirm the current manifest is schema v3 with `state=done` and report the
   checks actually run. Do not commit, push, publish, tag, or release unless
   the user requested those separate mutations.

Do not start a specification or development pipeline merely to finish an
otherwise complete feature.
