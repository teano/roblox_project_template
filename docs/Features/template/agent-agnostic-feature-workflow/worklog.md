# Feature worklog

## 2026-08-06T17:41:42.4469049+00:00 — finished

- Feature: TF-0007
- Head: ab149070bf8dadaaa2859fa10038d98ef2d20597

### Result and current state

Implemented an agent-neutral feature workflow with manifest schema version 2, portable repository context, feature-scoped leases, canonical branch creation, F-#### project numbering, direct worklog dashboard links, updated skills, rules, documentation, ADR-0036, migrations, and contract tests. All repository changes remain uncommitted on the canonical TF-0007 branch.

### Important decisions and discussions

The worklog is the complete cross-chat context and stores no chat/task/session identity. Pause and Finish require explicit result, decisions/discussions, verification, blockers, and next-step sections. Leases remain atomic but are owned by the feature rather than an agent. New template branches use template-feature/tf-####-<slug>; project features use F-#### on feature/t-####-<slug>; historical branch names remain unchanged. Finish records existing evidence and updates the documentation cascade but never executes verification. Four-digit numbering is retained for deterministic ordering and matches the requested tf-0007 format.

### Verification state

Completed before Finish: PowerShell parsing passed; all feature JSON parsed; quick_validate passed for feature-start, feature-continue, feature-pause, and feature-finish; isolated feature workflow contract suite passed; feature workflow validation passed; all visible dashboards were synchronized; repository layout validation passed; git diff --check passed; temporary Rojo build passed at 854699 bytes and was deleted. Studio Play was not run because Roblox runtime source, Rojo mappings, bootstrap, networking, save, Players, and the DataModel were unchanged.

### Blockers

None.

### Next step

None; feature is ready.

## 2026-08-06T18:03:45.1051439+00:00 — derived-project pipeline audit

- Feature: TF-0007
- Head: ab149070bf8dadaaa2859fa10038d98ef2d20597

### Result and current state

The independent derived-project pipeline audit is complete. Five defects were
fixed in repository role resolution, initialization gating, Pause/Finish
branch and lease enforcement, ready-feature reopening, and portable reopen
context. The expanded isolated suite now exercises project Start, Pause,
Continue, Finish, and Reopen with `F-####` IDs and
`feature/t-####-<slug>` branches. TF-0007 remains active for the main agent;
all changes remain uncommitted on its recorded branch.

### Important decisions and discussions

Repository role resolution fails closed unless the configured `upstream` URL
points to `roblox_project_template`; an unrelated remote name is insufficient.
Project lifecycle never substitutes for mandatory initialization and requires
both project ADR and feature dashboards. Pause and Finish mutate nothing until
the recorded branch is current and the exact schema-v2, identity-free lease is
present. Reopen preserves and switches to the existing recorded historical
branch, rejects missing branch/base history, and refreshes handoff/worklog so
portable state cannot remain stale at `ready/none`. Rejected alternatives were
name-only role detection, implicit namespace initialization, silently
recreating a missing lease, and canonicalizing historical branches.

### Verification state

Passed: PowerShell parser for the workflow module, lifecycle command, layout
validator, and isolated tests; three consecutive expanded derived-project suite
runs (latest 44.2 seconds); `quick_validate.py` for all four feature skills;
`validate-feature-workflow.ps1`; `sync-feature-index.ps1 -Check -Scope All`;
`validate-repository-layout.ps1`; `git diff --check` (line-ending warnings
only); and a temporary Rojo build at 854699 bytes, removed after inspection.
Studio Play was not run because no Roblox runtime source, Rojo mapping,
bootstrap, networking, save, Players, canonical scene, or DataModel behavior
changed.

### Blockers

None.

### Next step

The main agent should review this audit checkpoint, retain TF-0007 as active
until any desired follow-up is complete, and invoke Finish only after accepting
the recorded evidence.

## 2026-08-06T18:10:11.5337714+00:00 — finished

- Feature: TF-0007
- Head: ab149070bf8dadaaa2859fa10038d98ef2d20597

### Result and current state

Completed the independent derived-project feature-pipeline audit and fixed five defects: fail-closed upstream role resolution, mandatory project initialization gates, recorded-branch and strict lease enforcement for Pause/Finish, historical recorded-branch preservation during Reopen, and portable handoff/worklog refresh on Reopen. Expanded project lifecycle coverage is in place. All changes remain uncommitted on the recorded TF-0007 branch.

### Important decisions and discussions

Repository role requires an upstream URL resolving to roblox_project_template; an upstream name alone is ambiguous. Derived lifecycle never creates ownership namespaces in place of project initialization. Pause and Finish mutate nothing until the recorded branch is current and an exact identity-free schema-v2 lease is present. Reopen uses the existing recorded historical branch, refuses missing branch/base history, and writes current portable context. Rejected alternatives were name-only role detection, implicit initialization, silent lease recreation, and canonicalizing historical branch names.

### Verification state

Completed before Finish: the independent agent passed the expanded derived-project lifecycle suite three times (latest 44.2s), PowerShell parser, quick_validate for all four feature skills, feature-workflow validator, all-namespace dashboard sync check, repository-layout validator, git diff --check, and a temporary 854699-byte Rojo build that was deleted. The main agent reviewed the guards and documentation, then independently reran the PowerShell parser and expanded feature-workflow suite successfully in 42.9s. Studio Play was not run because Roblox runtime source, Rojo mappings, bootstrap, networking, save, Players, canonical scene, and DataModel behavior were unchanged.

### Blockers

None.

### Next step

None; feature is ready.

## 2026-08-06T18:21:49.2379107+00:00 — reopened

- Feature: TF-0007
- Head: ab149070bf8dadaaa2859fa10038d98ef2d20597

### Result and current state

Feature was explicitly reopened and is active on its preserved recorded branch. Prior completion evidence remains historical.

### Important decisions and discussions

Reopen reason: User explicitly ordered TF-0007 reopened to enforce that only an explicit user command may change feature lifecycle state.

### Verification state

No new verification has been completed for the reopened work; read the previous finished checkpoint as historical evidence only.

### Blockers

None.

### Next step

Audit the reopened scope and record new implementation and verification evidence.

## 2026-08-06T18:35:10.8669797+00:00 — user-state-authority-enforced

- Feature: TF-0007
- Head: ab149070bf8dadaaa2859fa10038d98ef2d20597

### Result and current state

Enforced exclusive user authority over every feature lifecycle transition. AGENTS, feature rules, all four lifecycle skills and their metadata, repository documentation, PRD/spec, superseding ADR-0037, validator enforcement, and regression tests now agree that agents and subagents cannot infer Start, Continue, Pause, Reopen, or Finish. TF-0007 remains in_progress/active on its recorded branch; no lifecycle transition was invoked after the user-authorized Reopen.

### Important decisions and discussions

Only an explicit request in the current user message authorizes a specific transition. Unambiguous natural language is valid, but implementation, audits, passing checks, subagent completion, end-of-turn, or a bare stop instruction are not authorization. Ambiguous wording preserves state and requires a user question. Lifecycle skills remain allow_implicit_invocation false. The product-neutral CLI remains a deterministic executor and does not pretend to authenticate chat authorship; enforcement belongs to rules, skill gates, metadata validation, and contract tests. ADR-0037 supersedes ADR-0036 while retaining its agent-neutral artifacts and branch conventions.

### Verification state

Passed before this checkpoint: PowerShell parser for changed validator/tests; quick_validate for feature-start, feature-continue, feature-pause, and feature-finish; expanded isolated feature workflow suite in 46.8 seconds, including rejection of a missing authorization gate and allow_implicit_invocation true; validate-feature-workflow; all-namespace dashboard sync check; repository-layout validator; git diff --check with line-ending warnings only; temporary Rojo build at 854699 bytes. Studio Play was not run because Roblox runtime, Rojo mappings, bootstrap, networking, save, Players, scene, and DataModel behavior were unchanged. Host policy rejected deletion of C:\Users\teano\AppData\Local\Temp\tf-0007-user-state-authority-20260806-001.rbxlx after the successful build; it remains outside the repository.

### Blockers

None.

### Next step

Leave TF-0007 in_progress/active. Perform no Pause, Finish, Continue, Reopen, or other state transition until the user explicitly requests that exact transition in a current message.

## 2026-08-06T18:39:30.3226551+00:00 — finished

- Feature: TF-0007
- Head: ab149070bf8dadaaa2859fa10038d98ef2d20597

### Result and current state

Completed TF-0007 with an agent-neutral feature workflow and exclusive user authority over lifecycle state. Manifest schema v2, portable worklogs, feature-scoped leases, canonical template/project IDs and branches, derived-project guards, verification-free Finish, and user-authorization enforcement across rules, four lifecycle skills, metadata, validators, tests, PRD/spec, README, and ADR-0037 are complete. All repository changes remain uncommitted on the recorded TF-0007 branch.

### Important decisions and discussions

Only an explicit request in the current user message authorizes Start, Continue, Pause, Reopen, or Finish; this Finish is authorized by the current $feature-finish invocation. Unambiguous natural language is valid, while implementation or audit completion, checks, subagent output, end-of-turn, or a bare stop request never imply a transition. Ambiguous wording preserves state. Lifecycle skills remain non-implicit, the CLI remains an identity-free deterministic executor, the worklog is authoritative cross-chat context, new template branches use template-feature/tf-####-<slug>, project features use F-#### on feature/t-####-<slug>, and Finish records pre-existing evidence without running verification. ADR-0037 supersedes ADR-0036 while retaining its agent-neutral decisions. Rejected alternatives include generic agent identity tokens, transcript links as context, implicit state changes, embedded Finish verification, name-only derived-role detection, implicit project initialization, silent lease recreation, and renaming historical branches.

### Verification state

Completed before this user-authorized Finish: PowerShell parsing passed; quick_validate passed for all four lifecycle skills; the expanded isolated feature workflow suite passed in 46.8 seconds, including authorization-gate and implicit-invocation regressions; feature workflow validation passed; the all-namespace dashboard sync check passed; repository layout validation passed; git diff --check passed with line-ending warnings only; and a temporary Rojo build passed at 854699 bytes. Studio Play was not run because runtime source, Rojo mappings, bootstrap, networking, save, Players, scene, and DataModel behavior were unchanged. The verified temp build remains outside the repository at C:\Users\teano\AppData\Local\Temp\tf-0007-user-state-authority-20260806-001.rbxlx because host policy rejected deletion.

### Blockers

None.

### Next step

None; feature is ready.
