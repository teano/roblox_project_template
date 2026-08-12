# Feature workflow rules

## Scope

Apply when starting, continuing, pausing, finishing, indexing, or validating
feature work, and when changing files under `docs/Features/`, `.agents/skills/`,
or the feature-workflow scripts.

For a Continue-only or Pause-only transition, required context is this rule
and the general repository instructions routed by the lifecycle skill. Do not
load `architecture.md`, `architecture-decisions.md`, `testing.md`, subsystem
rules/docs, Accepted ADRs, source, tests, or product artifacts only because of
that transition. Changes to feature-workflow behavior and separately requested
work still require `architecture.md`, `architecture-decisions.md`,
`testing.md`, `docs/adr/README.md`, current template/ADR-0044, and every rule
selected by their affected paths and architectural concerns.

## Canonical state

- Every tracked template feature MUST own exactly one
  `docs/Features/template/<feature-folder>/feature.json` manifest. Every
  tracked derived-game feature MUST own exactly one
  `docs/Features/project/<feature-folder>/feature.json` manifest.
- The reusable template allocates immutable `TF-####` IDs only in its
  `template` namespace. A derived repository independently allocates immutable
  `F-####` IDs only in its `project` namespace.
- `docs/Features/README.md` is a template-owned namespace router. The
  `template/README.md` and `project/README.md` dashboards are generated only
  from manifests in their own namespace; their generated blocks MUST NOT be
  edited by hand.
- The reusable template MUST NOT contain `docs/Features/project/`. Derived
  repositories MUST NOT mutate `docs/Features/template/`, including its
  dashboard and manifests. Template updates MUST preserve the complete project
  namespace without treating it as template divergence.
- Repository role resolution is fail-closed: `upstream` makes a repository a
  derived game only when its configured URL points to
  `roblox_project_template`. An unrelated remote named `upstream` is an
  ambiguous configuration, not permission to create project feature state.
- A derived repository MUST complete initialization, including
  `docs/adr/project/README.md` and `docs/Features/project/README.md`, before any
  state-changing feature action. Feature Start MUST NOT create those ownership
  namespaces as an implicit substitute for initialization.
- Durable state, handoff, append-only worklog, blockers, artifacts, and
  verification summaries live under the feature folder. Raw chat transcripts,
  chat links, task/session/host/agent identifiers, secrets, process IDs, and
  ephemeral locks MUST NOT be committed.
- `worklog.md` is the complete cross-chat history. Every pause and finish entry
  MUST include result/current state, important decisions and discussions,
  factual verification state, blockers, and next step. State explicitly when a
  section has no items.
- Unknown historical branches or commits remain `null` or omitted; agents MUST
  NOT guess them.

## Canonical dashboard and verification contract

- Every namespace dashboard is a complete generated projection of the valid
  `feature.json` manifests in that namespace. The renderer MUST produce the
  fixed namespace title and explanatory text, exactly one generated-marker
  pair, the existing summary and nine-column table, and exactly one row per
  manifest. Existing ordering, counters, labels, links, escaping, and field
  meanings remain unchanged.
- Manifest and dashboard input MUST be decoded as strict UTF-8 without
  replacement fallback. Manifest JSON timestamps remain strings, and JSON
  Unicode escapes MUST reject isolated or mismatched surrogate halves before
  rendering. Invalid manifest encoding, JSON, schema, or timestamp data fails
  before any dashboard mutation.
- `updatedAt` MUST be a complete RFC 3339 instant with an explicit `Z` or
  numeric offset. Its displayed value is the UTC calendar date formatted
  exactly as `yyyy-MM-dd` with invariant culture. Non-empty `startedAt` and
  `completedAt` use the same strict timestamp validation; culture, UI culture,
  local timezone, and host-specific JSON date coercion MUST NOT affect the
  result.
- Owning sync MUST validate and render the entire dashboard before mutation,
  encode it once as strict UTF-8 without BOM, and write canonical LF with
  exactly one terminal LF through the atomic dashboard writer. Missing,
  malformed, stale, CRLF/CR, or invalid-UTF-8 owning dashboards are replaced
  by the complete canonical output; a second sync with unchanged manifests
  MUST preserve the exact bytes.
- Check mode MUST build the same complete expected dashboard, remain
  read-only, and preserve every existing dashboard byte on both success and
  failure. Comparison normalizes only `CRLF -> LF` and then `CR -> LF`, using
  ordinal case-sensitive equality. It MUST NOT trim, fold whitespace or case,
  normalize Unicode, parse Markdown, or ignore terminal-newline count,
  markers, counters, ordering, or any other character difference.
- Check diagnostics MUST identify the namespace, path, and stable drift
  category (`missing`, `markers`, `encoding`, `content`, or `manifest`). An
  owning failure may direct the caller to the exact owning sync. A foreign
  template failure in a derived repository MUST instead direct the caller to
  approved upstream restoration and MUST NOT suggest or perform template
  sync.
- The two generated dashboard paths MUST retain exact `text eol=lf`
  attributes. This checkout policy does not weaken Check: logically identical
  LF, CRLF, CR, or mixed separators pass without rewrite, while every other
  full-file drift remains significant.
- The deterministic dashboard contract suite MUST run separately on the
  mandatory Windows 11 host under Windows PowerShell 5.1 and PowerShell 7.x,
  using the current host for child commands, and cover `en-US`, `ru-RU`,
  `core.autocrlf=false|true`, ownership, strict encoding, UTC boundaries, and
  LF/CRLF/CR/mixed fixtures. Windows 10 execution is optional best-effort
  evidence and does not affect the required pass/fail result; Studio Play is
  not required when Roblox source and the DataModel are unchanged.

## User authority over state

- Only an explicit request in the current user message authorizes a feature
  state transition. The user is the sole decision owner for Start, Continue,
  Pause, Reopen, and Finish.
- An agent, subagent, automation, test result, completed implementation,
  completed audit, absence of blockers, or end of turn MUST NOT be treated as
  authorization for a transition.
- A request to implement, fix, review, audit, verify, document, commit, push,
  or stop the current response does not implicitly authorize Pause or Finish.
- Plain-language authorization is valid only when it unambiguously names the
  intended transition or resulting feature state. When ambiguous, preserve the
  current state and ask the user instead of choosing a transition.
- Lifecycle skills MUST remain unavailable for implicit invocation. The
  lifecycle command is a deterministic executor, not an authority source; it
  does not prove who requested the action and MUST be called only after the
  user authorization gate has passed.
- After completing requested work, agents report completion and leave the
  feature state unchanged until the user issues a separate lifecycle command.

## State machine

- `planned -> in_progress/active` only through user-authorized
  `$feature-start`.
- `in_progress/active -> in_progress/paused` only through user-authorized
  `$feature-pause`.
- `in_progress/paused -> in_progress/active` only through user-authorized
  `$feature-continue`.
- `in_progress/active -> ready/none` only through user-authorized
  `$feature-finish` after the feature work, documentation cascade, and all
  required checks are already complete.
- Reopening `ready` work requires a current explicit user request followed by
  `$feature-start` with an explicit reopen reason. Prior worklog entries and
  completion evidence remain historical.

`$feature-finish` is not a synonym for ending an agent turn. An unfinished
feature is paused, never marked ready to release a branch reservation.

## IDs, branches, and writer exclusion

- Starting a new template feature allocates `TF-####` and creates
  `template-feature/tf-####-<slug>` from the current exact `HEAD`.
- Starting a new derived-project feature allocates `F-####` and creates
  `feature/t-####-<slug>` from the current exact `HEAD`.
- New branch creation MUST fail closed on a name collision. Existing historical
  branch names remain recorded and are not renamed merely to match the new
  convention. Reopening ready work switches to its existing recorded branch;
  missing branch/base metadata or a missing recorded branch requires an
  explicit metadata migration and MUST NOT be guessed from the caller branch.
- A named branch may have at most one manifest with status `in_progress`,
  including a paused feature, across both namespaces visible in a derived
  repository.
- Starting or continuing another feature on that branch MUST fail closed.
- The writer lease is an atomic local directory under the repository's Git
  common directory. It records only branch, feature ID, schema version, and
  creation time. It is guardrail state, not documentation, and MUST NOT be
  committed.
- Reacquiring a lease for the same feature is idempotent so another agent or
  chat can continue from repository context. A lease for another feature MUST
  NOT be stolen.
- Pause and Finish require the recorded branch to be current and the exact
  schema-v2 feature lease to exist before any artifact or manifest mutation.
  Missing, legacy, identity-bearing, or differently owned lease data fails
  closed.
- Feature start requires a named branch and a clean worktree unless the user
  explicitly authorizes adopting every existing change into that feature.
- `baseCommit` is the exact `HEAD` before the canonical feature branch is
  created and remains immutable. A rebase that makes it no longer an ancestor
  is a blocking metadata migration, not permission to silently replace it.

## Portable context

- Lifecycle commands MUST NOT read or accept Codex task IDs, session IDs,
  agent IDs, host IDs, usernames, or equivalent ownership tokens.
- Continue-only feature context consists exactly of the complete
  `feature.json` and complete `handoff.md`. Do not load PRD, specification,
  development plan, complete `worklog.md`, Git status/diff/history, controller
  state, source, tests, subsystem rules/docs, or Accepted ADR as recovery
  context.
- Do not load raw transcripts as workflow context. If the durable artifacts
  omit an important decision, report the missing detail without compensating
  through heavy context during Continue. A separately requested process owns
  any repair or deeper context load.
- Report the resolved namespace, feature ID/title, manifest state, branch,
  base commit, broad completed/current state, prior decisions, blockers, and
  recorded next step available from those two files. The next step is
  informational, not authorization.
- After the recovery report, Continue-only MUST end the turn without executing
  the recorded next step. It MUST NOT implement, review, audit, run a pipeline,
  edit source, run tests or validators, run Rojo preflight/build or Studio, or
  create or use subagents.
- A separately and explicitly requested process lazily loads only the PRD,
  specification, plan, controller state, worklog, Git, source, rules, docs,
  ADRs, and evidence that its own contract requires.

## Command gates

### Start

- Require a current explicit user request for Start or Reopen. Do not infer it
  from a request to implement, change, review, or audit work.
- Require unambiguous repository role and completed derived-project
  initialization before branch or artifact mutation.
- Reject `ready` work unless a reopen reason is explicit.
- Reject any attempt to start or reopen a feature outside the repository's
  owning namespace. New work is created only in that namespace.
- Allocate the owning ID, create the exact canonical branch, reject collisions,
  and reject a different `in_progress` feature on the target branch.
- Reopen ready work on its existing recorded branch without canonicalizing
  historical names; reject missing branch/base history instead of inventing it.
  Refresh handoff and append a worklog checkpoint with the explicit reopen
  reason so portable state cannot remain stale at `ready/none`.
- Create manifest, handoff, and worklog and acquire the feature-scoped lease
  before source edits. Missing product requirements or specification is a
  manifest blocker until the approved workflow resolves it.

### Continue

- Require a current explicit user request to continue the paused feature.
- Require `in_progress/paused`, the recorded branch, an ancestor `baseCommit`,
  and no conflicting feature lease.
- Acquire the feature-scoped lease, set activity to `active`, synchronize the
  owning dashboard, read only `feature.json` and `handoff.md`, report the basic
  recovery overview, and end the turn.

### Pause

- Require a current explicit user request to pause the feature. Do not infer
  Pause from the end of an agent turn or a generic stop instruction.
- Require `in_progress/active` on the recorded branch.
- Require a self-contained summary, important decisions/discussions, factual
  verification state, and one next confirmed step.
- Construct the checkpoint only from facts known before Pause. Do not inspect
  Git, source, controller state, tests, or other context merely to enrich it;
  do not create verification evidence, run work/checks, or use a subagent.
- Update `handoff.md` and append `worklog.md`, set activity to `paused`, release
  the feature-scoped lease, and retain `in_progress` so the branch remains
  reserved.

### Finish

- Require a current explicit user request to finish the feature. Passing all
  gates, completing implementation, or receiving a successful subagent report
  never authorizes Finish.
- Require `in_progress/active`, empty blockers, completed implementation, and
  factual evidence that all matched checks were completed before invocation.
- Update all affected current product/technical documents, system docs, test
  coverage descriptions, agent rules, and ADR indexes. Create an ADR only for
  a durable decision; never rewrite Accepted history.
- Require a self-contained final summary, important decisions/discussions, and
  the already completed verification evidence.
- `$feature-finish` and lifecycle `Finish` MUST NOT run tests, validators,
  builds, Rojo preflight, Studio operations, or other verification commands.
  Missing evidence keeps the feature `in_progress` and must be handled through
  `$feature-pause` or normal implementation work.
- Only a blocker-free completed feature becomes `ready`; then append the final
  worklog entry, update handoff/manifest, release the feature-scoped lease, and
  synchronize the owning dashboard.
- Git hooks are not part of this workflow. Commit and push do not mutate or
  validate feature state automatically.

## Verification before finish

Run the following during implementation and before invoking `$feature-finish`:

- `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/validate-feature-workflow.ps1`
- `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/sync-feature-index.ps1 -Check -Scope All`
- `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/validate-repository-layout.ps1`
- `git diff --check`
- Rojo build and every suite selected by affected subsystem rules.

Record exact results in the final checkpoint; do not rerun them from
`$feature-finish`.
