# ADR-0020: Shape communication traffic and bound network snapshots

- Status: Accepted
- Date: 2026-07-30
- Deciders: Project maintainers
- Supersedes: None
- Superseded by: None

## Context

ADR-0004 centralizes compact batched runtime messages, queue backpressure,
sequencing, epochs, and snapshot resync. Queue bounds limit retained work at
one instant, but they do not limit sustained traffic: a server or legitimate
client can drain every available batch on each Heartbeat and refill the queue
before the next frame.

Fixed one-second inbound and request windows also allow two complete bursts
around a window boundary. This weakens protection of validation, handlers, and
structured logging even though the authoritative server already rejects
invalid payloads.

The snapshot RemoteFunction previously derived its response allowance from the
DataStore soft serialization limit. Persistence capacity is not an appropriate
normal network response target, and snapshot failure must not change the
communication epoch or discard buffered state before the response is known to
be safe to send.

Roblox documents approximate RemoteEvent invocation throttling and recommends
limiting frequent or large remote traffic, but does not publish an exact hard
payload limit for ordinary reliable RemoteEvents. Application estimates
therefore cannot be treated as actual wire sizes or engine hard limits.

## Decision

Use continuously refilled token buckets for communication rate budgets that
are sensitive to sustained traffic or fixed-window boundary bursts.

The server authoritatively limits client-originated batch invocations, message
count, estimated bytes, synchronous request invocations, and combined request
and response estimated bytes. Invocation budget is charged before deep
validation so malformed calls cannot bypass expensive-work limiting.

The client cooperatively paces its batch invocations, message count, and
estimated bytes against matching server budgets. Client pacing is not a
security boundary; the server remains authoritative.

The server independently shapes server-to-client batch invocations and
estimated bytes per player. Budget exhaustion leaves unsent messages queued
and does not advance sequence. Existing bounded backpressure remains
responsible for evicting Presentation before State or Critical and for
collapsing important overflow to resync.

Use a network-specific estimated-byte cap for the complete snapshot response,
independent of DataStore serialization limits. Build and inspect the response
before `BeginSnapshot` changes the epoch or clears the outgoing queue. Every
snapshot exit releases the in-flight guard. Treat all configured byte values
as application-level estimates rather than Roblox wire sizes.

## Alternatives considered

### Keep fixed one-second windows

Rejected because adjacent windows permit a double burst and make behavior
depend on an arbitrary boundary instead of elapsed time.

### Rely only on bounded queues

Rejected because a queue can be completely drained and refilled every
Heartbeat while remaining within its instantaneous bounds.

### Use the DataStore soft limit for snapshots

Rejected because persistence capacity does not establish a safe or desirable
RemoteFunction response size and couples unrelated operational boundaries.

### Add acknowledgements, unreliable delivery, or chunked snapshots

Rejected because the template has no demonstrated high-frequency lossy traffic
or supported profile that exceeds the network snapshot cap. Existing
sequence, epoch, resync, and reliable RemoteEvent semantics remain sufficient.

## Consequences

### Positive

- Sustained traffic is bounded without a fixed-window boundary burst.
- Legitimate clients pace themselves below the authoritative server boundary.
- Temporary outbound exhaustion preserves important queued messages and
  sequence continuity.
- Snapshot size policy is explicit, network-specific, and failure-safe.
- Players own independent budgets, so one peer cannot consume another peer's
  allowance.

### Negative

- Burst capacity, refill rate, and estimated-byte capacity must be tuned
  together so one valid maximum-size batch can be sent.
- Estimated bytes intentionally differ from actual Roblox wire size.
- Temporarily budget-limited messages can remain queued for additional
  Heartbeats and may trigger existing backpressure under sustained overload.

## Enforcement

- Agent rules: `.agents/rules/communication.md`.
- Current documentation: `docs/Communication.md`,
  `docs/InitializationAndSaveSystem.md`, and `README.md`.
- Code boundaries: `Shared/Communication/TokenBucket`,
  `Shared/Communication/CommunicationConfig`, `CommunicationServer`,
  `CommunicationClient`, and `GlobalSaveInitializationCommand`.
- Tests: token refill and burst, independent player budgets, malformed
  invocation charging, client/server pacing, byte-budget independence,
  sequence preservation, cleanup, priority backpressure, snapshot cap and
  guard release, packet loss, stale epoch, and resync coverage in
  `ProductionIntegrationTestRunner`.
