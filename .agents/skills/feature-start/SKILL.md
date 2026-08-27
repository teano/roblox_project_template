---
name: feature-start
description: Start and track a repository feature when the user invokes $feature-start or naturally asks to start, begin, create, or track a feature. Do not use for an ordinary fix that the user did not ask to track.
---

# Start feature

Use this skill as the user-facing router for the optional feature record. The
user does not need to run PowerShell.

1. Read `AGENTS.md`, `.agents/rules/index.md`, and
   `.agents/rules/feature-workflow.md`. Resolve the exact root and writable
   template/project namespace from canonical remotes, or from the narrow
   non-Git derived-project evidence defined by the feature rule.
2. Resolve any supplied feature ID, slug, or title. Reuse an existing `open`
   record instead of creating a duplicate. Never reopen or overwrite `done`
   history; ask before allocating a new record for follow-up work.
3. When a new record is needed, invoke the repository backend:

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/feature.ps1 new -RepositoryPath <exact-root> -Title <title> [-Slug <slug>]
   ```

4. Report the allocated `TF-####` or `F-####` ID. The record does not create
   or switch a branch and does not authorize unrelated work.
5. If the same user message requests implementation, planning, or another
   concrete action, continue with that work in the same turn under the normal
   path-routed rules. Creating the record is not a terminal fence and must not
   force the user to send a second message.

Do not start a pipeline, create a lease/dashboard, or require PRD/spec/ADR
ceremony merely because a feature record exists.
