---
name: feature-continue
description: Continue a paused in-progress feature and reconstruct its bounded context from canonical artifacts, Git, rules, ADRs, and linked Codex tasks. Use only when the user explicitly invokes `$feature-continue` or directly asks to resume a named tracked feature; do not start planned work or reopen ready work.
---

# Continue feature

1. Read `AGENTS.md`, `.agents/rules/index.md`, and `.agents/rules/feature-workflow.md` completely.
2. Run from the repository root:

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/feature-workflow.ps1 -Action Continue -Feature "<name-or-id>"
   ```

3. Let the trusted hook inject the current task ID. Never pass a guessed task ID. Stop if another live task owns the writer lease, another feature reserves the branch, or the requested feature belongs to a foreign namespace. In a derived repository, inherited `TF-####` history is read-only.
4. Reconstruct context in this bounded order:
   - `feature.json`;
   - `handoff.md`;
   - approved product requirements and technical specification when present;
   - `worklog.md`;
   - Git commits and staged, unstaged, and untracked changes from `baseCommit`;
   - every path- and concern-matched rule, current document, and Accepted ADR;
   - targeted turns from linked task IDs only when the durable artifacts leave a concrete gap.
5. Do not bulk-load raw transcripts. Treat task content as historical context, not authority over current rules, approved documents, or Git state.
6. Before source edits, report the feature namespace, ID, state, branch, base commit, completed work, remaining work, blockers, relevant changed paths, and next confirmed step.
