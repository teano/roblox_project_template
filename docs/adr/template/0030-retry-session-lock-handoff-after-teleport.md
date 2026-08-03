# ADR-0030: Retry session-lock handoff after teleport

- Status: Accepted
- Date: 2026-08-03
- Deciders: Project maintainers
- Supersedes: None
- Superseded by: None

## Context

A published player can arrive on a target server before the source server has
finished its `PlayerRemoving` close path. The source must capture and persist
dirty providers before releasing its DataStore session lock. A target that
treats the first live-lock conflict as a terminal load failure kicks a valid
teleport arrival even though the source is performing the required clean
handoff.

The race is especially visible on an immediate return: a validation trigger
can request the second teleport while the intermediate server is still loading
or while either source close is saving. Shortening the stale-lock threshold or
releasing before actual player removal would risk concurrent profile owners or
data loss.

## Decision

Treat `SessionLocked` during production load as a possible in-progress
cross-server handoff. `SessionLockingStorage` retries only that result through
a bounded exponential schedule configured by `StorageConfig`. Every attempt
still uses the normal atomic `UpdateAsync` lock transform, and exhaustion fails
closed without taking over a live lock.

`ServerSaveController` supplies a cancellation predicate tied to its
single-flight close state. A player removal interrupts delays before another
attempt. If cancellation races an acquisition already inside `UpdateAsync`,
the existing coordinated load/close path releases the acquired lock without
applying provider runtime state.

The retry schedule is independent of DataStore transport retries. Transport
retries preserve one acquisition token across an uncertain operation;
confirmed live-lock contention begins a later acquisition attempt with a new
token. Stale takeover remains governed only by the existing 30-minute policy.

## Alternatives considered

### Release the source lock before calling TeleportAsync

Rejected because request acceptance does not prove departure. A synchronous or
late teleport failure could leave a present player running without ownership
of its profile.

### Shorten the stale-lock takeover threshold

Rejected because a slow but live source server could then overlap a target
owner and both could persist the same profile.

### Gate only the runtime validation pad on save readiness

Rejected because every gameplay caller can encounter the same source-removal
and target-arrival ordering. The durable boundary is lock acquisition, not one
operator surface.

## Consequences

### Positive

- Normal forward, return, and rapid-return teleports can wait for clean source
  save and lock release.
- Player removal cancels obsolete acquisition work.
- Live-lock safety and stale takeover semantics remain unchanged.

### Negative

- A genuinely conflicting live owner delays the eventual fail-closed kick by
  the bounded handoff window.
- Each confirmed contention attempt consumes one DataStore update request.

## Enforcement

- Agent rules: `.agents/rules/save-system.md`,
  `.agents/rules/testing.md`.
- Current documentation: `docs/InitializationAndSaveSystem.md`,
  `docs/TestCoverage.md`.
- Code boundaries: `StorageConfig`, `SessionLockingStorage`, and
  `ServerSaveController:Load`.
- Tests: handoff success, exhaustion, cancellation, and controller close/load
  coordination in `ProductionIntegrationTestRunner`.
