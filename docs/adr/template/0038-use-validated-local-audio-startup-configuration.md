# ADR-0038: Use validated local audio startup configuration

- Status: Superseded
- Date: 2026-08-07
- Deciders: Project maintainers
- Supersedes: None
- Superseded by: ADR-0041

## Context

ADR-0017 makes Roblox Experience Configs the source of tunable project
configuration and exposes client data only through server-owned projections.
The SFX System has a different bootstrap constraint: both server and client
must construct the same audio catalog, player budgets, routing ports, and
spatial profiles before ordinary playback or client readiness, without a
server projection becoming the audio schema authority.

Audio authoring also contains a generated catalog whose exact Git revision must
be reviewed together with code, while hard capacity ceilings must remain
unmodifiable by game-authored configuration. Treating these contracts as live
Experience Config values would add a network/bootstrap dependency and allow a
published value to exceed the implementation's proven resource envelope.

## Decision

Create one narrowly scoped configuration exception for the SFX System under
`ReplicatedStorage.Shared.Configs.Audio`:

- `SoundCatalog.luau` is generated deterministically from
  `configs/audio/Sounds.csv`;
- `AudioRuntimeConfig.luau`, `RoutingConfig.luau`, and
  `SpatialProfiles.luau` are reviewed local Luau startup tables;
- the server and each client require the same modules independently, validate
  exact shapes and cross-references into a temporary model, and publish only a
  frozen complete candidate;
- `AudioSafetyLimits` remains reviewed code outside `Configs` and places hard
  per-type, aggregate, protocol, path, and graph bounds above every authored
  value;
- invalid or over-budget configuration returns one stable side-disabled audio
  boundary before audio pools, graph publication, handlers, or playback exist.

Audio configuration is startup-only. It is not loaded from `ConfigService`,
projected through `ExperienceConfigCatalog`, updated over the network, refreshed
inside a running bootstrap, or mutated after validation. ADR-0017 remains the
default authority for all other tunable configuration.

## Alternatives considered

### Put the audio tables in Experience Configs

Rejected because both sides need one Git-reviewed schema before playback, the
generated catalog belongs to the repository revision, and live publication
must not raise code-owned resource ceilings.

### Let each audio consumer require and interpret raw tables

Rejected because validation, defaulting, cross-references, freezing, and
failure containment would diverge across server/client modules.

### Store audio tuning as Attributes, ValueObjects, or place JSON

Rejected because it would create a parallel mutable representation, weaken
reviewability, and conflict with the explicit local-module boundary.

## Consequences

### Positive

- Server and clients use one reviewable startup contract without an audio-only
  bootstrap projection protocol.
- Invalid configuration is contained before runtime resources are published.
- Generated catalog bytes and runtime code can be reviewed and versioned
  together.
- Game-authored values cannot raise code-owned safety ceilings.

### Negative

- Audio tuning changes require a repository change and a new bootstrap.
- Both sides perform independent validation of the same modules.
- The template now has one documented exception to the general Experience
  Config ownership policy.

## Enforcement

- Agent rules: `.agents/rules/audio.md`, `.agents/rules/configuration.md`,
  `.agents/rules/initialization.md`, `.agents/rules/architecture.md`, and
  `.agents/rules/testing.md`.
- Current documentation: `docs/AudioSystem.md`,
  `docs/ExperienceConfiguration.md`, `docs/InitializationAndSaveSystem.md`, and
  `docs/Features/template/sfx-system/technical-specification.md`.
- Code boundaries: `configs/audio/Sounds.csv`,
  `ReplicatedStorage/Shared/Configs/Audio`, shared audio validation/catalog
  modules, `AudioSafetyLimits`, and the server/client initialization manifests.
- Tests: `AudioCatalogTestRunner`, `AudioIntegrationTestRunner`,
  `SystemTestRunner`, generated-catalog freshness checks, and clean
  server/client bootstrap verification.
