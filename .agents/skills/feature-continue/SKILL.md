---
name: feature-continue
description: Resume an open repository feature when the user invokes $feature-continue or naturally asks to continue, resume, or pick up feature work. Continue the work in the same turn instead of requiring a separate activation message.
---

# Continue feature

Continue restores context; it is not a state transition. An unfinished feature
already remains `open`, and the user does not need to run PowerShell.

1. Read `AGENTS.md`, `.agents/rules/index.md`, and
   `.agents/rules/feature-workflow.md`. Resolve the requested writable record:

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/feature.ps1 status -RepositoryPath <exact-root> -Feature <ID-or-slug>
   ```

2. Require current state `open`. In a derived project, inherited template
   feature history is read-only.
3. Read the current `handoff.md` and only the worklog, requirements,
   specification, plan, rules, source, and tests needed for the requested or
   recorded next step. Do not load all history by default.
4. Resume the requested work in this same turn. If the user only says
   “continue”, follow a concrete safe next step from the handoff; ask one
   concise question only when no reliable next step can be recovered.
5. Run proportional checks for the work actually performed and refresh the
   handoff/worklog when useful. Do not create an `active` value, lease,
   dashboard, branch transition, or pipeline run.
