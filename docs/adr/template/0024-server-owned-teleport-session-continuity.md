# ADR-0024: Keep teleport session continuity server-owned

- Status: Accepted
- Date: 2026-08-03
- Deciders: Project maintainers
- Supersedes: None
- Superseded by: None

## Context

Reusable game systems need one observable teleport lifecycle across servers
and places without confusing platform request acceptance, source departure,
and actual target arrival. Roblox teleport data is visible to clients and
untrusted. Group requests can also fail for one participant after the platform
accepted the request for the group.

Scattered direct player subscriptions or domain-specific remotes would repeat
arrival races, transport validation, ordering, recovery, and privacy policy.
A group-level result would erase per-player partial failure. Treating the
session identifier as protected state would make client-visible correlation
data a security boundary it cannot satisfy.

## Decision

Use one server `TeleportModule` as the authority that creates and continues
canonical correlation GUIDs and invokes `TeleportAsync`. It consumes arrival
and removal through `PlayersModule`, creates a fresh module-owned
`TeleportOptions`, and continues a session only after validating the official
source place, exact versioned envelope, allowed-place policy, and arriving
user's entry.

The envelope carries the shared request's canonical attempt ID in addition to
the per-user session map. `TeleportInitFailed` returns a newly constructed
`TeleportOptions`, so the module reads that copied envelope token instead of
using Instance identity. This prevents a stale failure from terminating a
newer request.

Each player owns a separate active-attempt record even when one group call
shares an attempt ID. Platform return publishes `Accepted`, never target
arrival. A synchronous failure or correlated `TeleportInitFailed` clears only
the affected attempt and preserves the session. Removal publishes only source
departure. Validated processing on the target server is the sole source of a
`Teleported` arrival.

Use the existing communication boundary for client projection. Own lifecycle
state uses `State`; other-player appearance and departure use `Presentation`
and exclude session IDs, attempt details, selectors, access codes, and failure
details. The client registers handlers before a bounded bootstrap request,
owns only a read-only projection, and rejects impossible transition order so
communication resync can restore a valid baseline.

## Alternatives considered

### Treat platform acceptance or source removal as success

Rejected because neither proves that the target server admitted the player.

### Use one group attempt record

Rejected because late failure is reported per player and must not change the
state of participants that are still teleporting.

### Add teleport-specific remotes or direct Players subscriptions

Rejected because ADR-0004 and ADR-0005 already centralize the transport and
player lifecycle boundaries.

### Persist or authorize gameplay with the session GUID

Rejected because teleport data is untrusted, client-visible correlation data
and does not prove entitlement or durable progress.

## Consequences

### Positive

- Arrival, acceptance, failure, departure, and target confirmation are
  unambiguous.
- Partial group failure is isolated per player.
- Derived games consume a complete server/client contract without adding
  remotes or modifying the base module.
- Shared presentation remains compact and privacy-preserving.

### Negative

- Every allowed place must be explicitly composed into policy.
- Real success still requires published Roblox-client multi-place evidence;
  deterministic Studio tests cannot certify that platform path.
- Client projections must recover when payload ordering or shape is invalid.

## Enforcement

- Agent rules: `AGENTS.md`, `.agents/rules/index.md`,
  `.agents/rules/teleport.md`, `.agents/rules/architecture.md`,
  `.agents/rules/players.md`, `.agents/rules/communication.md`.
- Current documentation: `docs/Teleport.md`, `docs/Communication.md`,
  `docs/InitializationAndSaveSystem.md`, `docs/TestCoverage.md`.
- Code boundaries: `src/ServerScriptService/Modules/Teleport/`,
  `src/ReplicatedStorage/Shared/Teleport/`,
  `src/ReplicatedStorage/Client/Teleport/`, and the side-specific
  initialization manifests and commands.
- Tests: `src/ServerScriptService/Tests/TeleportModuleTestRunner.luau`,
  `src/ServerScriptService/Tests/AllTestsRunner.luau`, and
  `scripts/validate-repository-layout.ps1`.
