---
name: feature-continue
description: Activate a paused in-progress feature only after the current user explicitly requests Continue, restore its writer lease, report a basic repository-artifact overview, and stop. Never infer Continue from implementation work, start planned work, or reopen ready work.
---

# Continue feature

## User authorization gate

Only an explicit request in the current user message authorizes this lifecycle
transition. A request for more implementation, fixes, review, or audit does not
implicitly reactivate a paused feature. If intent is ambiguous, leave feature
state unchanged and ask the user.

1. Read `AGENTS.md`, `.agents/rules/index.md`, and `.agents/rules/feature-workflow.md` completely. Do not load architecture, testing, subsystem, source, or feature-product context merely because Continue was requested.
2. Run from the repository root:

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/feature-workflow.ps1 -Action Continue -Feature "<name-or-id>"
   ```

3. Do not collect, invent, or pass chat, task, session, host, or agent identifiers. Stop if the feature is not paused, the recorded branch is not current, another feature reserves it, the feature-scoped lease conflicts, or the requested feature belongs to a foreign namespace. In a derived repository, inherited `TF-####` history is read-only.

## Continue-only context boundary

Continue-only context: read only feature.json and handoff.md as feature-specific recovery context.

After the transition, read those two files completely. Report only the available namespace, ID/title, current manifest state, recorded branch, base commit, broad completed/current state, prior decisions, blockers, and recorded next step. Do not read PRD, specification, development plan, complete worklog, Git status/diff/history, controller state, source, tests, subsystem rules, system documentation, or Accepted ADR as recovery context. Missing detail stays missing until a separately requested process loads the context it owns.

## Continue-only terminal fence

Continue-only terminal fence: after the recovery report, end the turn without executing the recorded next step.

Continue-only forbidden work: do not implement, review, audit, run a pipeline, edit source, run tests or validators, run Rojo or Studio, or create or use subagents.

State explicitly that the recorded next step is informational and needs a separate user request. The later explicitly requested process owns its own context loading and preflight.
