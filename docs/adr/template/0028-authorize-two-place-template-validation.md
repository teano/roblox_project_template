# ADR-0028: Authorize two-place template validation within one Experience

- Status: Accepted
- Date: 2026-08-03
- Deciders: Project maintainers
- Supersedes: ADR-0023
- Superseded by: None

## Context

The Teleport lifecycle requires published multi-place evidence that Studio Play
cannot provide. The maintainers explicitly authorized normal publishing and
cross-place validation between two existing places whose selected DataModels
reported the same Experience identity:

- primary Place ID `91045933836846`;
- secondary Place ID `101736951773632`;
- Universe/Experience ID `10596427617`.

Rojo live sync and the runtime Teleport destination policy are separate trust
boundaries. Both must name the same exact destinations before either place can
participate in validation. Expanding either boundary without the shared GameId
gate would let a derived project accidentally inherit template destinations.

## Decision

Both template validation repositories record their own top-level `placeId`, the
shared `gameId`, and this exact `servePlaceIds` set:

```json
[91045933836846, 101736951773632]
```

`TeleportPolicy.Template` allows both places only when `game.GameId` is exactly
`10596427617` and the current place is one of the two recorded places. An
unrecorded place in that Experience fails closed. Every other Experience,
including a correctly initialized derived game, receives a current-place-only
policy until its own composition explicitly authorizes additional places.

The authorization covers normal Publish to these two existing places. It does
not authorize Publish As, creating or attaching places, renaming cloud places,
or changing the canonical binary scene.

The template identity remains non-inheritable. Derived-project initialization
removes all inherited `placeId`, `gameId`, and `servePlaceIds` fields before its
first Rojo or Studio connection.

## Alternatives considered

### Keep a single validation place

Rejected because it cannot prove real target arrival or multi-visit session
continuity.

### Gate only by the two PlaceIds

Rejected because a copied policy must also prove it is running in the recorded
Experience before it expands its destination set.

### Allow every place in the validation Experience

Rejected because the approved scope contains exactly two existing places.

## Consequences

### Positive

- Published tests can prove real cross-place session continuity.
- Rojo and runtime policy enforce the same exact destination set.
- Derived projects remain current-place-only by default.

### Negative

- Both repositories must keep their allowlists and policy constants aligned.
- Adding or replacing a validation place requires a new explicit decision.

## Enforcement

- Agent rules: `AGENTS.md`, `.agents/rules/rojo-project.md`,
  `.agents/rules/project-initialization.md`, `.agents/rules/teleport.md`.
- Runtime composition: `TeleportPolicy.Template(game.PlaceId, game.GameId)`.
- Configuration: both repositories' `default.project.json` files.
- Tests: `TeleportModuleTestRunner` and
  `scripts/validate-repository-layout.ps1`.
- Runtime evidence: exact DataModel identity re-check, normal Publish to both
  existing places, and published Roblox-client multi-place E2E.
