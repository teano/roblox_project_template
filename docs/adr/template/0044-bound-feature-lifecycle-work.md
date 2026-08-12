# ADR-0044: Bound feature lifecycle work and recover context lazily

- Status: Accepted
- Date: 2026-08-12
- Deciders: Project maintainers
- Supersedes: ADR-0037
- Superseded by: None

## Context

ADR-0037 reserves feature state transitions for explicit user requests, but
the Continue contract still requires loading PRD, specification, complete
worklog, Git changes, rules, documentation, and ADRs. It also describes the
recovery report as something that occurs before source edits. A Continue-only
request can therefore consume a large context window and be mistaken for
authorization to start the recorded next step in the same turn.

Pause has a similar scope risk when an agent performs new investigation or
delegates a checkpoint merely to make its verification summary more complete.
Short numeric feature references also need deterministic behavior when both
template and project namespaces are visible.

## Decision

Retain ADR-0037's exclusive user authority, agent-neutral artifacts,
schema-v2 leases, branch reservation, namespace isolation, owning-dashboard
synchronization, and verification-free Finish. Add these boundaries:

- Continue-only performs only `paused -> active`, lease recovery, manifest and
  owning-dashboard synchronization, then reads the complete `feature.json` and
  `handoff.md` for a basic overview;
- the recorded next step is informational, and the Continue-only turn ends
  after its recovery report without implementation, review, audit, pipeline,
  source edits, checks, Rojo/Studio operations, or subagents;
- PRD, specification, plan, full worklog, Git, controller state, source,
  subsystem rules/docs/ADRs, and evidence are loaded lazily by a separately
  requested process according to that process's contract;
- Pause records a factual checkpoint from information already known before
  invocation; it does not create new evidence, run new work or checks, inspect
  extra context merely to enrich the checkpoint, or use a subagent;
- a reference consisting of exactly four ASCII digits resolves only when one
  visible canonical `TF-####` or `F-####` ID matches. Zero or multiple matches
  fail before lifecycle mutation; ambiguous diagnostics list candidates in a
  stable order.

The lifecycle executor remains deterministic and cannot authenticate user
intent. Agent and skill authorization gates remain mandatory.

## Alternatives considered

### Load all durable context during Continue

Rejected because Continue does no implementation work. The future process is
better placed to select only the context it needs.

### Automatically execute the handoff next step

Rejected because a checkpoint recommendation is neither user authorization
nor a request for a particular implementation or verification process.

### Delegate Pause checkpoint creation

Rejected because a normal checkpoint summarizes the current agent's already
known state. Delegation duplicates context and can introduce unsupported
evidence.

### Resolve a numeric suffix using repository role or current branch

Rejected because those heuristics silently choose between visible namespace
owners. Ambiguity must remain explicit and fail closed.

## Consequences

### Positive

- Continue context cost is bounded by manifest and handoff size.
- Lifecycle transitions cannot silently expand into implementation or checks.
- Later processes load context proportionally to their own work.
- Pause remains a cheap, factual state capture.
- Numeric shorthand is convenient only when deterministic.

### Negative

- An incomplete handoff yields an incomplete basic overview until a later
  explicitly requested process repairs or enriches durable context.
- Users must issue a separate request for the next work process.
- Ambiguous numeric suffixes require a full canonical ID.

## Enforcement

- Agent rules: `AGENTS.md`, `.agents/rules/index.md`,
  `.agents/rules/feature-workflow.md`
- Skills: `.agents/skills/feature-continue/SKILL.md`,
  `.agents/skills/feature-pause/SKILL.md`
- Code boundaries: `scripts/FeatureWorkflow.psm1`,
  `scripts/feature-workflow.ps1`, `scripts/validate-feature-workflow.ps1`
- Current documentation: `README.md`, `docs/Features/README.md`,
  `docs/FeatureDevelopmentForBeginners.md`,
  `docs/Features/template/feature-workflow-optimization/product-requirements.md`,
  `docs/Features/template/feature-workflow-optimization/technical-specification.md`
- Tests: `scripts/tests/feature-workflow.tests.ps1`,
  `scripts/validate-repository-layout.ps1`
