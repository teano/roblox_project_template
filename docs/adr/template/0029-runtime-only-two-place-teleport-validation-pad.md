# ADR-0029: Use a runtime-only two-place teleport validation pad

- Status: Accepted
- Date: 2026-08-03
- Deciders: Project maintainers
- Supersedes: None
- Superseded by: ADR-0031

## Context

ADR-0028 authorizes published validation between two exact places in one
template Experience. Deterministic suites prove the Teleport state machine,
but a Roblox client still needs a safe physical operator surface to initiate
the real cross-place request and repeat the return leg. Adding a Part to the
canonical binary place would change Studio-owned scene source in two
repositories and make the reusable template carry a permanent operator object.

A validation surface can also become an accidental gameplay backdoor if it is
available to other users, copied Experiences, derived games, unrecorded places,
or arbitrary destinations. Direct TeleportService calls would bypass the
server-owned lifecycle and its session envelope.

## Decision

Compose a server-only `TeleportValidationPad` through the explicit server
manifest after `Players` and `Teleport`. The controller creates its anchored,
touch-enabled Part only at runtime and only when all identity gates match:

- GameId `10596427617`;
- current PlaceId `91045933836846` or `101736951773632`;
- present UserId `11330628810`.

The destination is the opposite member of that exact place pair and always
uses the public `Services.Teleport:Teleport` facade with a `Public`
destination. Presence and touch-character lookup use `PlayersModule`. One
attempt is latched for the authorized player until removal, preventing body
part touch repetition and re-entry while the platform call yields.

The runtime Part is labelled with its destination and placed near the first
spawn found by deterministic bounded traversal, with a fixed bounded fallback.
Player removal and `Stop` destroy the pad idempotently; target arrival creates a
new pad through the same manifest lifecycle. The controller creates no remote,
standalone Script, canonical place object, or session/attempt diagnostic.

## Alternatives considered

### Author a pad in both canonical place files

Rejected because it mutates Studio-owned binary scene source and permanently
ships an operator object that is needed only during exact validation.

### Let any player or place use the trigger

Rejected because the surface is a validation capability, not reusable game
policy, and must not widen ADR-0028's trust boundary.

### Call TeleportService directly from the touch handler

Rejected because it would bypass TeleportModule session continuity, attempt
events, envelope validation, and client projection.

### Add a client button or RemoteEvent

Rejected because server collision already supplies the required intent and a
new remote would duplicate the communication and authority boundaries.

## Consequences

### Positive

- The exact authorized tester can start both legs of published E2E without a
  canonical place edit.
- Every request exercises the production Teleport facade and session envelope.
- Copied Experiences, derived games, other places, and other users see no pad.
- Touch repetition and cleanup have deterministic tests.

### Negative

- The operator must join with the exact authorized account.
- A failed attempt remains latched until that player leaves and rejoins, so the
  validation surface never implements automatic retry policy.
- Runtime placement uses a bounded fallback when no spawn is found within the
  traversal budget.

## Enforcement

- Agent rules: `.agents/rules/teleport.md`, `.agents/rules/initialization.md`,
  `.agents/rules/players.md`, `.agents/rules/testing.md`.
- Current documentation: `docs/Teleport.md`,
  `docs/InitializationAndSaveSystem.md`, `docs/TestCoverage.md`.
- Code boundaries:
  `src/ServerScriptService/Modules/Teleport/TeleportValidationPad.luau`,
  `src/ServerScriptService/Initialization/Commands/TeleportValidationPadInitializationCommand.luau`,
  and `src/ServerScriptService/Initialization/ServerManifest.luau`.
- Static enforcement: `scripts/validate-repository-layout.ps1`.
- Tests: `src/ServerScriptService/Tests/TeleportModuleTestRunner.luau` and
  clean server/client bootstrap in both exact validation places.
