---
name: feature-start
description: Start or explicitly reopen tracked feature work only after the current user message directly requests that exact lifecycle transition. Use for `$feature-start` or an unambiguous user request to start or reopen a named feature; never infer authorization from implementation, planning, maintenance, review, audit, or Git work.
---

# Start feature

## User authorization gate

Only an explicit request in the current user message authorizes this lifecycle
transition. Do not infer Start or Reopen from a request to implement, change,
plan, review, audit, verify, commit, or push work. If the requested transition
is ambiguous, leave feature state unchanged and ask the user.

1. Read `AGENTS.md`, `.agents/rules/index.md`, and `.agents/rules/feature-workflow.md` completely. Read every rule and Accepted ADR selected by the intended feature scope before source edits.
2. Resolve the repository role fail-closed. An `upstream` remote counts as the derived-template upstream only when its URL points to `roblox_project_template`; stop on an unrelated remote with that name. In a derived repository, require completed initialization with `docs/adr/project/README.md` and `docs/Features/project/README.md` before a state-changing feature action.
3. Resolve the requested feature across `docs/Features/template/` and, in a derived repository, `docs/Features/project/`. Prefer the stable ID when a slug or title exists in both namespaces. Never infer a different feature from the branch name.
4. Inspect the current named branch, HEAD, and complete working tree. Do not use `-AdoptChanges` unless the user explicitly assigns every existing change to this feature.
5. Run from the repository root:

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/feature-workflow.ps1 -Action Start -Feature "<name-or-id>"
   ```

   For a new feature, pass `-Title` and an ASCII `-Slug` when its requested name cannot produce one. The command creates the owning namespace record and switches to its canonical branch: `TF-####` on `template-feature/tf-####-<slug>` in the template, or `F-####` on `feature/t-####-<slug>` in a derived game. For ready work, pass `-ReopenReason` only after explicit user authorization; reopen switches to the existing recorded branch, preserves historical names, refreshes handoff, and appends the reason/current state to worklog. Missing recorded branch/base metadata or a missing local recorded branch requires explicit metadata migration. A derived repository must never reopen or mutate an inherited template feature.
6. Do not collect, invent, or pass chat, task, session, host, or agent identifiers. The lifecycle is repository-owned and product-agnostic.
7. If product requirements or a technical specification are missing, keep their generated manifest blockers and use the applicable approved requirements/specification workflow before implementation. Do not treat generated service artifacts as product approval.
8. Confirm the namespace, assigned ID, canonical or preserved recorded branch, base commit, worklog path, blockers, and next allowed step before editing source.
