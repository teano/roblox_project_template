# ADR-0026: Observe Teleport snapshot reconciliation at configured player capacity

- Status: Accepted
- Date: 2026-08-03
- Deciders: Project maintainers
- Supersedes: None
- Superseded by: None

## Context

ADR-0025 places the complete Teleport client projection inside every initial
and recovery communication snapshot. Replacing the internal projection repairs
lost lifecycle and presentation messages, but getter-only repair is not
observable to a subscriber that already derived UI or gameplay state from the
missed event. Synthesizing historical Started, Accepted, Failed, appearance,
and departure transitions would invent an ordering that the replacement
snapshot does not contain.

Teleport request groups have a platform cap of 50 participants. A server's
safe present-player projection is a different collection and can contain every
other player up to the configured `Players.MaxPlayers` capacity. Reusing the
request cap for snapshots rejects valid larger servers even when the complete
snapshot fits the existing communication network bounds.

The validated caller group also crosses the yielding `TeleportAsync` boundary.
Retaining the caller-owned array there allows concurrent mutation to remove a
participant from attempt completion without removing the already-installed
Started record.

## Decision

After validating a complete teleport group, copy it into a module-owned dense
frozen participant array. Use only that snapshot to install attempts, construct
the envelope, invoke `TeleportAsync`, and publish every synchronous success or
failure transition.

Expose a client-local `ProjectionReconciled` signal. Fire it only after a
validated Teleport snapshot has atomically replaced arrival, attempt, and
present-player projection. Subscribers respond by re-reading the public
getters; snapshot replacement does not synthesize or replay historical
lifecycle events.

Inject `Players.MaxPlayers` into the client Teleport composition and accept at
most `MaxPlayers - 1` other-player appearances in bootstrap and recovery
snapshots. Keep that limit independent of the 50-player teleport request cap.
The communication layer's complete snapshot byte and node limits continue to
reject a capacity-valid response before `BeginSnapshot` when it is not safe to
send.

## Alternatives considered

### Synthesize all transitions from the old and new snapshot

Rejected because a snapshot contains current state, not a trustworthy event
history. Diff-generated callbacks could imply ordering or intermediate states
that never occurred.

### Keep replacement observable only through getters

Rejected because a subscriber has no bounded way to know when its derived state
must be refreshed after recovery.

### Reuse the 50-player request cap for presentation snapshots

Rejected because teleport request size and server capacity are different
platform constraints.

### Trust the caller not to mutate the validated group

Rejected because `TeleportAsync` yields and the module already owns the
attempts installed for every validated participant.

## Consequences

### Positive

- Caller mutation cannot strand a participant in Started.
- Every successful snapshot repair has one explicit subscriber notification.
- Subscribers observe one complete current projection without fabricated event
  history.
- Valid servers above 51 players can bootstrap and recover Teleport projection.

### Negative

- Consumers that maintain derived Teleport state must subscribe to
  `ProjectionReconciled` and re-read the required getters.
- Client construction needs the configured maximum player capacity.
- Capacity-valid snapshots can still be rejected by the independent network
  limit, requiring operators to reduce projection size or revise that policy
  deliberately.

## Enforcement

- Agent rules: `.agents/rules/teleport.md`,
  `.agents/rules/communication.md`, `.agents/rules/testing.md`.
- Current documentation: `docs/Teleport.md`, `docs/Communication.md`,
  `docs/InitializationAndSaveSystem.md`, `docs/TestCoverage.md`.
- Code boundaries: `TeleportModule:Teleport`,
  `TeleportProtocol.ValidateBootstrapResponse`,
  `TeleportClient:PrepareSnapshot`,
  `TeleportClient:ApplyPreparedSnapshot`, and `ClientManifest`.
- Tests: yielding caller-group mutation, subscriber reconciliation for lost
  lifecycle and presentation transitions, configured maximum-capacity
  bootstrap/resync in `TeleportModuleTestRunner`, and observable recovery in
  `ProductionIntegrationTestRunner`.
