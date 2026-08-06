# Feature handoff

- Feature: TF-0007 Agent-Agnostic Feature Workflow
- Status: ready / none
- Head: ab149070bf8dadaaa2859fa10038d98ef2d20597
- Updated: 2026-08-06T18:39:30.2939768+00:00

## Result and current state

Completed TF-0007 with an agent-neutral feature workflow and exclusive user authority over lifecycle state. Manifest schema v2, portable worklogs, feature-scoped leases, canonical template/project IDs and branches, derived-project guards, verification-free Finish, and user-authorization enforcement across rules, four lifecycle skills, metadata, validators, tests, PRD/spec, README, and ADR-0037 are complete. All repository changes remain uncommitted on the recorded TF-0007 branch.

## Important decisions and discussions

Only an explicit request in the current user message authorizes Start, Continue, Pause, Reopen, or Finish; this Finish is authorized by the current $feature-finish invocation. Unambiguous natural language is valid, while implementation or audit completion, checks, subagent output, end-of-turn, or a bare stop request never imply a transition. Ambiguous wording preserves state. Lifecycle skills remain non-implicit, the CLI remains an identity-free deterministic executor, the worklog is authoritative cross-chat context, new template branches use template-feature/tf-####-<slug>, project features use F-#### on feature/t-####-<slug>, and Finish records pre-existing evidence without running verification. ADR-0037 supersedes ADR-0036 while retaining its agent-neutral decisions. Rejected alternatives include generic agent identity tokens, transcript links as context, implicit state changes, embedded Finish verification, name-only derived-role detection, implicit project initialization, silent lease recreation, and renaming historical branches.

## Verification state

Completed before this user-authorized Finish: PowerShell parsing passed; quick_validate passed for all four lifecycle skills; the expanded isolated feature workflow suite passed in 46.8 seconds, including authorization-gate and implicit-invocation regressions; feature workflow validation passed; the all-namespace dashboard sync check passed; repository layout validation passed; git diff --check passed with line-ending warnings only; and a temporary Rojo build passed at 854699 bytes. Studio Play was not run because runtime source, Rojo mappings, bootstrap, networking, save, Players, scene, and DataModel behavior were unchanged. The verified temp build remains outside the repository at C:\Users\teano\AppData\Local\Temp\tf-0007-user-state-authority-20260806-001.rbxlx because host policy rejected deletion.

## Blockers

None.

## Next step

None; feature is ready.
