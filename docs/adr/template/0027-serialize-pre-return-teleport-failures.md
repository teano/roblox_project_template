# ADR-0027: Serialize teleport failures that arrive before platform return

- Status: Accepted
- Date: 2026-08-03
- Deciders: Project maintainers
- Supersedes: None
- Superseded by: None

## Context

`TeleportAsync` yields. Roblox can dispatch a matching `TeleportInitFailed`
for one participant before that yielding call returns or throws. The public
attempt state is still `Started` at that point because platform acceptance is
defined only by a successful return. Ignoring the event loses a real failure;
publishing it immediately would send `Failed` before the required `Accepted`
transition if the call later returns successfully.

The same race overlaps removal, module shutdown, duplicate platform events,
and a later attempt for a player who rejoined. A delayed result must never
publish twice or terminate replacement state.

## Decision

Each per-player active attempt record serializes the return/event race. The
first correlated `TeleportInitFailed` received while its state is `Started`
is retained as a pending failure without publishing a terminal transition.

If `TeleportAsync` returns successfully, each still-owned record first moves
to `Accepted` and publishes that transition, then publishes its retained
`Failed` exactly once and clears the record. If the protected platform call
throws, `TeleportRequestFailed` is the only terminal transition and any
retained platform failure is discarded with the record.

Record identity and attempt-ID correlation scope pending results. Removal,
`Stop`, a stale or duplicate result, and a newer attempt cannot consume or be
terminated by an older pending failure. The network contract remains the
existing ordered `Started`, `Accepted`, and `Failed` messages, so client
projection and communication resync need no new DTO or transport.

## Alternatives considered

### Ignore failures until the attempt is Accepted

Rejected because an event that arrives during the yielding call may not be
repeated, leaving the player and client projection stuck in `Accepted`.

### Publish Failed immediately from Started

Rejected because a successful return would then require either suppressing
the observable `Accepted` stage or publishing it after a terminal failure,
both of which violate the existing client transition contract.

### Treat any pre-return platform event as the synchronous result

Rejected because the protected `TeleportAsync` call remains authoritative for
whether acceptance returned or a synchronous exception occurred. Conflating
the two sources can double-publish failure and misclassify the call result.

## Consequences

### Positive

- A matching pre-return failure cannot be lost.
- Successful calls preserve deterministic `Accepted` then `Failed` order.
- Synchronous exceptions and duplicate events remain exactly once.
- Removal, shutdown, and retries cannot leak an old failure into new state.

### Negative

- Active attempt records retain one small sanitized failure while the
  platform call is yielding.
- Server tests must exercise interleavings around a yielding platform fake.

## Enforcement

- Agent rules: `.agents/rules/teleport.md`, `.agents/rules/testing.md`.
- Current documentation: `docs/Teleport.md`, `docs/TestCoverage.md`.
- Code boundaries: `TeleportModule:_onTeleportInitFailed`,
  `TeleportModule:Teleport`, and the per-player attempt record.
- Tests: pre-return success, synchronous exception, removal/retry/stale, and
  Stop regressions in `TeleportModuleTestRunner`.
