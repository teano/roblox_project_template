---
name: feature-start
description: Start or explicitly reopen tracked feature work in this repository. Use only when the user explicitly invokes `$feature-start` or directly asks to begin a named feature under the repository feature-work protocol; do not use for continuing paused work, maintenance, reviews, or unrelated Git operations.
---

# Start feature

1. Read `AGENTS.md`, `.agents/rules/index.md`, and `.agents/rules/feature-workflow.md` completely. Read every rule and Accepted ADR selected by the intended feature scope before source edits.
2. Resolve the requested feature across `docs/Features/template/` and, in a derived repository, `docs/Features/project/`. Prefer the stable ID when a slug or title exists in both namespaces. Never infer a different feature from the branch name.
3. Inspect the current named branch, HEAD, and complete working tree. Do not use `-AdoptChanges` unless the user explicitly assigns every existing change to this feature.
4. Run from the repository root:

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/feature-workflow.ps1 -Action Start -Feature "<name-or-id>"
   ```

   For a new feature, pass `-Title` and an ASCII `-Slug` when its requested name cannot produce one. The command creates it only in the repository's owning namespace (`TF-####` for the template, `PF-####` for a derived game). For ready work, pass `-ReopenReason` only after explicit user authorization. A derived repository must never reopen or mutate an inherited template feature.
5. Let the trusted `PreToolUse` hook inject the current task ID. Never invent or manually pass `-SessionId`. If the command reports missing hook context, stop and ask the user to review/trust the repository hooks.
6. If product requirements or a technical specification are missing, record that gap and use the applicable approved requirements/specification workflow before implementation. Do not treat generated service artifacts as product approval.
7. Confirm the namespace, assigned ID, branch, base commit, task link, blockers, and next allowed step before editing source.
