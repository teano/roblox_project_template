---
name: feature-continue
description: Continue a paused in-progress feature only after the current user message explicitly requests that transition, then reconstruct bounded context from repository artifacts, Git, rules, and ADRs. Never infer Continue from a new implementation request; do not start planned work or reopen ready work.
---

# Continue feature

## User authorization gate

Only an explicit request in the current user message authorizes this lifecycle
transition. A request for more implementation, fixes, review, or audit does not
implicitly reactivate a paused feature. If intent is ambiguous, leave feature
state unchanged and ask the user.

1. Read `AGENTS.md`, `.agents/rules/index.md`, and `.agents/rules/feature-workflow.md` completely.
2. Run from the repository root:

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/feature-workflow.ps1 -Action Continue -Feature "<name-or-id>"
   ```

3. Do not collect, invent, or pass chat, task, session, host, or agent identifiers. Stop if the feature is not paused, the recorded branch is not current, another feature reserves it, the feature-scoped lease conflicts, or the requested feature belongs to a foreign namespace. In a derived repository, inherited `TF-####` history is read-only.
4. Reconstruct context in this bounded order:
   - `feature.json`;
   - `handoff.md`;
   - approved product requirements and technical specification when present;
   - `worklog.md`;
   - Git commits and staged, unstaged, and untracked changes from `baseCommit`;
   - every path- and concern-matched rule, current document, and Accepted ADR.
5. Treat `worklog.md` as the complete cross-chat discussion history. If it lacks required context, record the gap as a blocker instead of relying on an unavailable transcript.
6. Before source edits, report the feature namespace, ID, state, branch, base commit, completed work, important prior decisions, remaining work, blockers, relevant changed paths, and next confirmed step.
