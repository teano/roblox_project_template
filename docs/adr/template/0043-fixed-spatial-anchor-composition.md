# ADR-0043: Use one fixed SpatialAnchor composition

- Status: Accepted
- Date: 2026-08-11
- Deciders: Project maintainers
- Supersedes: None
- Superseded by: None

## Context

Ordinary World playback needs one positioning model that works for client-local
and server-owned leases without depending on the gated
`AudioEmitter.PositionType=Instance` capability. The prior implementation
parents an emitter to an unpositioned `Folder`, selects Instance mode, and
points `PositionInstance` either at a point proxy or at a gameplay target.
That produces two topology variants, permits cross-tree wiring, and makes
Attached cleanup depend on per-playback target state.

The approved SFX product and technical contracts instead require a fixed,
bounded four-Instance wrapper whose complete server subtree can replicate as
one lease. Point must remain static without a frame subscription, while every
Attached lease must follow full position and orientation without creating a
connection owner per wrapper. ADR-0040 continues to own the one-shot audio
graph, native server replication, and global acoustic policy.

## Decision

Every active World playback wrapper is one colocated composition rooted at an
invisible anchored, non-collidable `Part` named `SpatialAnchor`. The root is
parented directly to the side's injected `Workspace` only while its lease is
active. Its exact direct children are one `AudioPlayer`, one `AudioEmitter`,
and one `Wire`; the wire connects that player to that emitter. The emitter
uses its default Parent positioning and playback code never reads or writes
`AudioEmitter.PositionType` or `AudioEmitter.PositionInstance`.

Point playback assigns `SpatialAnchor.CFrame = CFrame.new(position)` once and
does not enter a frame registry. Attached playback copies the full transform
of a validated source: `Attachment.WorldCFrame`, `Camera.CFrame`, or
`PVInstance:GetPivot()`.

Each server VM and each client VM owns exactly one manifest-composed
`SpatialAnchorBindingRegistry` and one injected frame subscription for all
active Attached leases on that side. The client injects render-frame cadence;
the server injects Heartbeat cadence. Registrations carry wrapper and lease
generation identity. Release unregisters the current generation before
clearing playback state or returning the wrapper to its pool. Target removal,
transform-read failure, and stale frame callbacks converge on the existing
single wrapper completion owner; the registry never owns a lease or performs
a second release.

A server-all World request creates one server wrapper and lease, parents its
complete anchor subtree to server `Workspace`, and relies only on native
Roblox replication. It does not create client mirrors, application fanout, or
another positioning path. Idle wrappers remain unparented, reset, and retain
no source reference or active registry entry.

## Alternatives considered

### PositionType Instance with PositionInstance

Rejected because it depends on a separately gated capability, permits the
emitter to point outside its owned subtree, and preserves multiple positioning
paths instead of the approved fixed composition.

### Per-wrapper frame connections

Rejected because connection lifetime would scale with active playback and
would create many cleanup owners racing pool generations.

### Client mirrors or application fanout for server playback

Rejected because server-all delivery is one authoritative server lease whose
instances and play state already use native replication.

### Runtime strategy, capability probe, or fallback

Rejected because a configurable or detected alternative would make object
cost, cleanup, public behavior, and evidence depend on runtime topology.

## Consequences

### Positive

- Every World wrapper has one exact four-Instance inventory and colocated wire.
- Parent positioning no longer depends on playback access to the gated
  Position properties.
- Point has zero frame registrations; Attached work shares one subscription
  per side and remains generation-safe.
- Server-all preserves one native replicated lease without mirrors or fanout.

### Negative

- Every retained World wrapper owns an anchored Part in addition to its audio
  objects, though the complete subtree remains unparented while idle.
- Attached updates perform one bounded registry pass per side frame.
- A future positioning topology requires a new superseding decision and a new
  object-budget/evidence review.

## Enforcement

- Agent rules: `.agents/rules/audio.md`, `.agents/rules/architecture.md`,
  `.agents/rules/initialization.md`, `.agents/rules/resource-management.md`,
  `.agents/rules/rojo-project.md`, and `.agents/rules/testing.md`.
- Current documentation: `docs/AudioSystem.md`, `docs/AudioManualQA.md`,
  `docs/TestCoverage.md`, and the approved SFX technical specification.
- Code boundaries: `AudioPlaybackWrapper`, `SpatialAnchorBindingRegistry`,
  `OrdinaryPlaybackCore`, both Ordinary services, commands, and manifests.
- Tests: fixed-spatial static/config/playback identities,
  `AudioPlaybackTestRunner`, `AudioIntegrationTestRunner`,
  `AudioManualQaTestRunner`, repository layout validation, clean Play, and
  `Studio-E2E-AUDIO-01..05`.
