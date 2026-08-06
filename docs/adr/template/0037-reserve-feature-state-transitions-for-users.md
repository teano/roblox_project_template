# ADR-0037: Reserve feature state transitions for users

- Status: Accepted
- Date: 2026-08-06
- Deciders: Project maintainers
- Supersedes: ADR-0036
- Superseded by: None

## Context

ADR-0036 makes feature context agent-neutral and turns `Finish` into a
documentation/state-finalization action, but it does not state who owns the
decision to invoke a lifecycle transition. An agent can therefore infer that a
successful implementation, completed audit, passing verification, empty
blocker list, or end of turn authorizes `Finish` or `Pause`. That inference
changes repository state without the user's decision and can mark work ready
before the user has accepted completion.

The lifecycle command cannot authenticate the author of a chat request without
reintroducing a product-specific identity dependency. Authorization therefore
belongs at the agent/skill boundary, while the command remains a deterministic
executor of an already authorized transition.

## Decision

Retain ADR-0036's agent-neutral worklogs, schema-v2 manifests,
feature-scoped leases, namespace isolation, canonical ID/branch formats, and
verification-free `Finish`. Add exclusive user authority over lifecycle state:

- only an explicit request in the current user message authorizes Start,
  Continue, Pause, Reopen, or Finish;
- a plain-language request is valid only when it unambiguously names the
  transition or resulting feature state; `$feature-*` remains the explicit
  shortcut;
- implementation, fixes, reviews, audits, tests, subagent results, blockers,
  completion, and the end of an agent turn never imply a transition;
- ambiguous wording preserves the current state and requires a user question;
  a bare request to stop the current response is not an implicit Pause;
- after completing work, an agent reports that outcome and waits for a separate
  user transition command instead of updating feature state;
- all lifecycle skills keep `policy.allow_implicit_invocation: false` and an
  explicit user-authorization gate;
- the lifecycle command does not claim to verify chat authorship and MUST be
  invoked only after the agent/skill authorization gate passes.

Read-only context inspection does not change feature state and does not require
a lifecycle transition command.

## Alternatives considered

### Automatically finish after every gate passes

Rejected because verification proves technical evidence, not user acceptance
or intent to change feature state.

### Automatically pause whenever an agent stops working

Rejected because ending a response, encountering a blocker, and intentionally
pausing a feature are different decisions. Automatic Pause also writes a
checkpoint and releases the lease without user authorization.

### Require a product user, chat, or session token in the lifecycle command

Rejected because the workflow must remain usable by different agents and
products. A caller-supplied token or boolean would not prove user intent and
would recreate the identity coupling removed by ADR-0036.

### Accept only literal `$feature-*` invocations

Rejected because an unambiguous natural-language user command such as
"reopen TF-0007" expresses the same authority. The important boundary is the
current user's explicit intent, not one UI syntax.

## Consequences

### Positive

- Feature state reflects user decisions instead of agent completion heuristics.
- Passing checks and successful subagent work cannot prematurely mark a
  feature ready.
- Agent-neutral lifecycle commands remain portable across products.
- Ambiguous stop/continue wording fails safely without repository mutation.

### Negative

- A technically complete feature can remain active until the user explicitly
  requests Finish.
- Agents must distinguish stopping a response from pausing feature state and
  may need one focused clarification for ambiguous wording.
- Enforcement at the agent boundary cannot cryptographically prove chat
  authorship; repository validation instead protects the required skill gates
  and non-implicit invocation policy.

## Enforcement

- Agent rules: `AGENTS.md`, `.agents/rules/feature-workflow.md`
- Current documentation: `README.md`, `docs/Features/README.md`,
  `docs/Features/template/agent-agnostic-feature-workflow/product-requirements.md`,
  `docs/Features/template/agent-agnostic-feature-workflow/technical-specification.md`
- Code boundaries: `.agents/skills/feature-*`,
  `scripts/validate-feature-workflow.ps1`
- Tests: `scripts/tests/feature-workflow.tests.ps1`,
  `scripts/validate-repository-layout.ps1`
