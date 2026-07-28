# ADR-0004: Use compact batched runtime messages with snapshot resync

- Status: Accepted
- Date: 2026-07-28
- Deciders: Project maintainers
- Supersedes: None
- Superseded by: None

## Context

Normal gameplay produces small changes and presentation events. Sending a full
Wallet or another provider table for each change wastes bandwidth and can
replace objects used by client runtime controllers. Direct remotes per domain
also duplicate validation, ordering, limits, and failure handling.

Initial load and recovery from packet loss still require a complete consistent
view. RemoteFunctions are appropriate for that synchronous boundary but cannot
be accumulated into frame batches.

## Decision

Use `CommunicationServer` and `CommunicationClient` for ordinary runtime
RemoteEvent messages. Domain modules enqueue compact semantic changes; the
communication layer validates and flushes ordered batches once per Heartbeat.

Messages have `Critical`, `State`, or `Presentation` priority and are bounded
by count and estimated bytes. Under pressure, presentation is evicted first.
State overflow collapses to `ResyncRequired` rather than silently losing
authoritative state.

The dedicated snapshot RemoteFunction is used only for initial state and
explicit resync. Epochs reject stale pre-snapshot packets, sequence gaps or
handler failures trigger resync, and client handlers compare expected prior
state when ordering matters.

Communication serialization remains separate from DataStore serialization and
explicitly supports safe required Roblox value types while rejecting unsafe or
unbounded values.

## Alternatives considered

### Send full provider tables after every mutation

Rejected because it is bandwidth-heavy and overwrites runtime identity for a
small change.

### Give every domain its own direct remotes

Rejected because ordering, backpressure, validation, and observability would be
implemented inconsistently across modules.

### Use RemoteFunctions for ordinary events

Rejected because synchronous calls serialize gameplay work and cannot provide
the desired frame batching for notifications.

### Share the persistence serializer

Rejected because network-safe Roblox values and DataStore-safe values have
different contracts and limits.

## Consequences

### Positive

- Small changes produce small network payloads.
- Ordering, validation, rate limiting, and pressure policy are centralized.
- Runtime object identity is preserved.
- Full snapshots provide an explicit recovery path.

### Negative

- Every message type requires a protocol and handler.
- Clients must detect mismatches and tolerate resync.
- Batching introduces up to roughly one frame of delivery latency.
- Sequence, epoch, and pressure state increase transport complexity.

## Enforcement

- Agent rules: `.agents/rules/communication.md`,
  `.agents/rules/domain-data.md`.
- Current documentation: `docs/InitializationAndSaveSystem.md`.
- Code boundaries: shared communication protocol/serializer,
  `CommunicationServer`, `CommunicationClient`, and domain message handlers.
- Tests: sequencing, epochs, packet loss, overflow, rate limits, serialization,
  and Vector3 batch-flush coverage in `ProductionIntegrationTestRunner`.
