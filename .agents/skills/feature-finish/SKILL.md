---
name: feature-finish
description: Document and close already completed tracked feature work without running verification, but only after the current user message explicitly requests Finish. Never infer Finish from completed implementation, passing checks, an empty blocker list, an audit or subagent result, or the end of a turn.
---

# Finish feature

## User authorization gate

Only an explicit request in the current user message authorizes this lifecycle
transition. Completed implementation, passing checks, an empty blocker list,
audit completion, a successful subagent report, or the end of an agent turn
never authorizes Finish. Without a current explicit user request, report that
the work is ready for the user's decision and leave feature state unchanged.

1. Read `AGENTS.md`, `.agents/rules/index.md`, `.agents/rules/feature-workflow.md`, the feature manifest, handoff, complete worklog, approved requirements/specification, and every affected current rule, system document, and Accepted ADR. Confirm the feature belongs to the writable namespace, is `in_progress/active` on the recorded current branch, and owns the exact schema-v2 feature lease before any final artifact mutation.
2. Do not run tests, validators, builds, Studio operations, or other verification commands. Read the existing evidence and blocker state. If implementation or required checks are unfinished, report that state and wait for the user; do not invoke Pause without a separate explicit user request, manufacture evidence, or mark the feature ready.
3. Update the feature worklog context and every document made stale by the completed work: product requirements, technical specification, affected system docs, test coverage descriptions, agent rules, and ADR/indexes. Create or supersede an ADR only for a durable decision; never rewrite Accepted history.
4. Prepare a self-contained final checkpoint for an agent with no access to this chat. Include delivered outcome and final repository state; every important decision, rejected alternative, and discussion outcome; factual checks already run and checks not run; blockers; and the absence of a next implementation step. State explicitly when a section has no items.
5. Proceed only when blockers are empty, required documentation is current, and existing evidence shows the feature work is complete. Run:

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/feature-workflow.ps1 -Action Finish -Feature "<name-or-id>" -Summary "<delivered-outcome>" -Decisions "<important-decisions-and-discussions>" -VerificationSummary "<previously-completed-checks>"
   ```

6. Do not include chat links or task/session/agent identifiers. Confirm `ready/none`, released feature-scoped lease, complete final handoff/worklog entry, and synchronized owning dashboard. Report the recorded evidence without rerunning it.
