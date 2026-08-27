# Optional feature records

## Purpose

Feature records are lightweight optional bookkeeping for work that benefits
from a durable repository identifier. They are not authorization, branch
ownership, a development pipeline, a release gate, or a prerequisite for
editing source.

The user interacts through `$feature-start`, `$feature-pause`,
`$feature-continue`, `$feature-finish`, or equivalent natural language. The
skills invoke `scripts/feature.ps1` as an internal backend; users are not
expected to run PowerShell. Ordinary implementation proceeds without a record
unless the user asks to track it.

## Model

A current record has only two states:

- `open`: work remains;
- `done`: the tracked outcome is complete.

The current manifest stores schema version, stable ID, slug, title, state, and
created/updated timestamps. It does not store branch, base commit, lease,
agent/session identity, blockers, artifact approvals, or verification payloads.

Template records use `TF-####` under `docs/Features/template/`. Derived-game
records use `F-####` under `docs/Features/project/`. A derived repository may
read inherited template history but never migrates or mutates it.

A completely non-Git derived-project root uses the same `F-####` ownership
when `default.project.json` has a non-empty non-template name and the exact
project-owned `src/ReplicatedStorage/Project/Client/UI/DerivedWindowConfig.luau`
exists. Broken `.git` metadata and paths nested inside another Git worktree
fail closed. A non-Git template root is never inferred.

## User-facing skills

- Start creates or reuses an `open` record. Work requested in the same message
  continues immediately; record creation is not a separate activation turn.
- Pause writes a factual handoff/checkpoint while the current state remains
  `open`.
- Continue restores relevant context and resumes work in the same turn; it
  does not mutate feature state.
- Finish performs the remaining scoped work and proportional verification,
  then closes the record only when the result is complete.

Natural language is sufficient when intent is unambiguous. Do not infer Pause
from a blocker or end of turn, and do not infer Finish merely because checks
passed. Creation and closure remain user-authorized mutations.

## Backend commands

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/feature.ps1 new -RepositoryPath <exact-root> <arguments>
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/feature.ps1 status -RepositoryPath <exact-root>
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/feature.ps1 close -RepositoryPath <exact-root> -Feature <ID>
```

- `new` allocates an ID in the owning namespace and creates one manifest. It
  does not create or switch a Git branch.
- `status` is read-only and reports current records without generating a
  dashboard.
- `close` changes one owning `open` record to `done`. It does not run checks,
  rewrite product documents, commit, push, or release.

Marking a record done is a bookkeeping action. Verification and release claims
must still cite the checks actually run for the underlying change.

## Legacy history

Legacy schema-v2 manifests, handoffs, worklogs, requirements, specifications,
and plans remain historical evidence. A migration must preserve the exact old
manifest before replacing its active state and must not discard the other
files.

When legacy migration is requested:

- `planned` and `in_progress` map to `open`;
- `ready` maps to `done`;
- the exact old manifest is retained as `feature.legacy.json`;
- an existing legacy sidecar is never overwritten;
- only the repository's owning namespace is changed.

Historical `paused` or `active` text may remain in the archived manifest or
worklog, but it is not current state. The current manifest and current handoff
must not contradict the final `open|done` result.

No generated dashboard, writer lease, hook, or Pause/Continue state is part of
the current contract. The thin user-facing skills route intent; they do not
restore the retired lifecycle state machine or pipeline.
