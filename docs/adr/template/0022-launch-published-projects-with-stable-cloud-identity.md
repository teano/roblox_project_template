# ADR-0022: Launch published projects with stable cloud identity

- Status: Superseded
- Date: 2026-07-31
- Deciders: Project maintainers
- Supersedes: ADR-0018
- Superseded by: ADR-0023

## Context

The hybrid repository tracks `place.rbxl` as the binary source of
Studio-authored scene state. Opening that file directly uses Studio's local
`EditFile` mode. A local DataModel has no durable cloud identity by itself, so
`game.PlaceId` and `game.GameId` are zero until identity is restored.

This creates a repeated failure mode for a published project: a developer
opens the canonical file as instructed, temporarily reattaches or republishes
it, closes Studio, and sees the identity disappear again on the next local
open. Experience Config, DataStore, publishing, and identity-sensitive tests
then run against an unidentified DataModel.

ADR-0018 selects published sessions by stable IDs but still describes the
session as being opened from canonical `place.rbxl`. It does not define how a
published project restores those IDs or prevent cloud-dependent work before
restoration.

Roblox Studio distinguishes opening a published place (`EditPlace` with Place
and Universe IDs) from opening a local file (`EditFile`). Rojo project files
support top-level `placeId`, `gameId`, and `servePlaceIds`; on connection they
can restore the current DataModel IDs and restrict live-sync destinations.

## Decision

Keep `place.rbxl` as the canonical repository source for Studio-authored scene
data, but treat file identity and cloud identity as separate contracts.

An unpublished template or local prototype opens canonical `place.rbxl` and
is expected to have zero cloud IDs.

A published derived project records its exact Place ID and
Universe/Experience ID in a project ADR and configures top-level `placeId`,
`gameId`, and `servePlaceIds` in `default.project.json`. The allowlist contains
only approved destinations for that Rojo project. These project-owned values
survive template merges.

A published project opens by either of two supported flows:

1. Open the published place from My Experiences/Creator Hub or Studio
   `EditPlace` using the recorded IDs, then connect the verified Rojo project.
2. Open canonical `place.rbxl`, connect the verified Rojo project so its
   configured `placeId`/`gameId` restore DataModel identity, then verify both
   IDs before any Play, Experience Config, DataStore, testing, or publishing
   operation.

A zero or mismatched ID blocks cloud-dependent work. `Publish to Roblox As`
is never an automatic recovery mechanism because selecting a destination is a
destructive external-state choice that requires explicit user authorization.

After Studio-authored scene changes, the developer explicitly saves or
exports the complete scene back to canonical `place.rbxl` for Git. Updating
the cloud place and updating the repository binary are separate deliberate
operations.

## Alternatives considered

### Always open the local file and republish it

Rejected because local `EditFile` sessions repeatedly lose cloud context,
encourage destination guessing, and break Experience-scoped services before
republishing.

### Always open only the cloud place

Rejected as the sole workflow because the repository still needs an explicit
complete `place.rbxl` artifact for Studio-owned scene data and offline or
unpublished projects have no cloud identity.

### Infer identity from project or DataModel names

Rejected because names are mutable and do not identify a Place or Universe.

### Store fixed IDs in the reusable template

Rejected because every derived game and integration environment owns different
cloud destinations. IDs become mandatory only when a derived project is
actually published.

## Consequences

### Positive

- Published projects reopen with deterministic cloud identity.
- Experience Config, DataStore, tests, and publishing see the intended
  Experience instead of an unidentified local DataModel.
- `servePlaceIds` guards Rojo live sync against the wrong published place.
- The canonical binary scene remains versioned in Git.

### Negative

- Derived projects must maintain cloud IDs as project-owned configuration.
- Scene changes may require both an explicit cloud save/publish and an explicit
  canonical-file export.
- A newly published project needs a project ADR and configuration update
  before normal cloud-dependent work.

## Enforcement

- Agent rules: `AGENTS.md`, `.agents/rules/rojo-project.md`,
  `.agents/rules/testing.md`, `.agents/rules/project-initialization.md`.
- Current documentation: `README.md`, `docs/IntegrationTesting.md`.
- Code boundaries: `default.project.json`, canonical `place.rbxl`,
  `scripts/ensure-rojo-server.ps1`.
- Tests: `scripts/validate-repository-layout.ps1`, Rojo validation build,
  explicit Studio ID verification, and clean Play bootstrap.
