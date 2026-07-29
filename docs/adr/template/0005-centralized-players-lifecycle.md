# ADR-0005: Centralize Roblox player lifecycle behind PlayersModule

- Status: Accepted
- Date: 2026-07-28
- Deciders: Project maintainers
- Supersedes: None
- Superseded by: None

## Context

Save loading, cleanup, character-bound systems, communication, and gameplay all
need player or character lifecycle events. Direct subscriptions across modules
make startup races, already-present players, connection cleanup, and overlapping
shutdown/player-removal paths difficult to handle consistently.

The wrapper must centralize platform interaction without becoming a god module
that owns save or gameplay behavior.

## Decision

Server and client use their side-specific `PlayersModule` as the single wrapper
around Roblox player and character lifecycle APIs. It owns platform
subscriptions, exposes project signals and lookup/observation helpers, handles
already-present players, and provides idempotent cleanup.

Save, communication, character-bound presentation, and gameplay modules remain
consumers. Their domain logic and resource lifetimes do not move into
`PlayersModule`.

## Alternatives considered

### Direct Players subscriptions in each module

Rejected because each consumer would need to solve initialization races,
existing-player enumeration, and duplicate cleanup independently.

### Put save and gameplay orchestration inside PlayersModule

Rejected because the wrapper would couple unrelated systems and reverse the
dependency direction.

### One global application coordinator for all lifecycle behavior

Rejected because it would centralize domain behavior rather than only
centralizing the Roblox service boundary.

## Consequences

### Positive

- Platform lifecycle behavior has one adapter per side.
- Existing-player and cleanup semantics are consistent.
- Tests can inject or observe a project-level lifecycle contract.
- Domain modules remain focused consumers.

### Negative

- Consumers depend on an additional wrapper abstraction.
- The wrapper must preserve enough of Roblox lifecycle semantics for all
  consumers.
- New lifecycle capabilities require extending a shared contract carefully.

## Enforcement

- Agent rules: `.agents/rules/players.md`,
  `.agents/rules/architecture.md`.
- Current documentation: `docs/InitializationAndSaveSystem.md`.
- Code boundaries: server/client `PlayersModule`, initialization commands, and
  constructor injection into lifecycle consumers.
- Tests: existing-player observation, join/leave, respawn, repeated cleanup,
  and save/shutdown lifecycle coverage.
