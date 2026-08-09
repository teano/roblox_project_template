# ADR-0041: Protect audio startup and keep disabled transport handlers

- Status: Accepted
- Date: 2026-08-07
- Deciders: Project maintainers
- Supersedes: ADR-0038
- Superseded by: None

## Context

ADR-0038 established the narrow local Luau configuration exception for the
audio playback feature, but it also required invalid configuration to disable
audio before transport handlers existed. The approved SFX requirements require
the exact hybrid Intent and Presentation handlers to be registered before
`ClientReady` even when the local audio runtime is disabled. Leaving a protocol
message without its handler can turn a contained audio failure into a
communication failure or resynchronization.

There is a second fail-soft boundary at manifest construction. If a manifest
directly requires the four audio configuration modules before the
initialization runner invokes the owning command, a missing, wrong-class, or
throwing module can abort the whole gameplay bootstrap before audio can publish
its disabled state.

## Decision

Preserve the local startup-configuration decision from ADR-0038 and replace its
startup/handler lifecycle with one protected manifest-owned boundary:

- `SoundCatalog.luau`, `AudioRuntimeConfig.luau`, `RoutingConfig.luau`, and
  `SpatialProfiles.luau` remain the only authored audio startup modules under
  `ReplicatedStorage.Shared.Configs.Audio`;
- server and client manifests pass roots, exact module names, the initialized
  side-owned `AssetRegistry`, `AudioSafetyLimits`, and `Logger` to one
  `AudioStartupInitializationCommand`; manifest constructors do not require or
  interpret the raw audio modules;
- after `Assets`, the command safely resolves the exact ModuleScripts, executes
  each `require` inside its protected `Initialize` boundary, exact-validates
  and deep-freezes one complete configuration/catalog candidate, and publishes
  one immutable `AudioStartupState` in the initialization context;
- a missing, wrong-class, unreadable, throwing, invalid, cross-reference-broken,
  or over-budget startup input publishes `{Enabled=false, ReasonCode=...}` and
  creates no audio pool, graph, preload request, or playback resource;
- after `Communication`, the ordinary audio initialization command registers
  the exact hybrid Intent and Presentation handlers before `ClientReady` for
  both enabled and disabled startup states;
- disabled handlers still exact-decode the transport envelope, then reject or
  no-op with stable `AudioDisabled`; they do not access catalog indexes, graph,
  pools, fanout, playback, retry, replay, or resync state;
- handler registration is the final non-yield installation step and belongs to
  the Communication registry until DataModel teardown. The first release does
  not add handler replacement, unregister/re-register, or production audio
  `Stop -> Initialize`.

`AudioSafetyLimits` remains reviewed code outside `Configs`. Audio startup data
still does not use Experience Config, Attributes, ValueObjects, network
projection, live refresh, or runtime mutation. ADR-0017 remains authoritative
for non-audio tunable configuration.

## Alternatives considered

### Leave handlers absent when audio is disabled

Rejected because protocol registration is part of bootstrap compatibility, not
proof that playback resources are available. A disabled no-op/reject boundary
contains the failure without exposing Communication to an unhandled message.

### Require raw audio modules in manifest constructors

Rejected because constructor-time errors occur outside the initialization
runner's fail-soft audio owner and can abort unrelated gameplay bootstrap.

### Register a second disabled-only protocol

Rejected because it would create parallel message IDs and divergent enabled
and disabled schemas. Both states use the same exact versioned contract.

## Consequences

### Positive

- Missing or malformed modules disable only audio instead of crashing general
  initialization.
- Communication always observes a complete registry before `ClientReady`.
- Enabled and disabled sides share one schema and one manifest order.
- No audio graph, pool, preload, or playback resource leaks from a failed
  startup candidate.

### Negative

- Disabled audio still installs two small transport handlers for the VM
  lifetime.
- Audio manifests and tests need an explicit protected module-loader boundary.
- The superseded ADR remains in history and readers must follow this decision.

## Enforcement

- Agent rules: `.agents/rules/audio.md`, `.agents/rules/initialization.md`,
  `.agents/rules/communication.md`, `.agents/rules/configuration.md`,
  `.agents/rules/architecture.md`, and `.agents/rules/testing.md`.
- Current documentation: `docs/AudioSystem.md`,
  `docs/InitializationAndSaveSystem.md`, `docs/ExperienceConfiguration.md`, and
  `docs/Features/template/sfx-system/technical-specification.md`.
- Code boundaries: server/client manifests,
  `AudioStartupInitializationCommand`, `AudioConfigValidator`,
  `HybridOneShotServerController`, `HybridOneShotClientController`, and the
  existing Communication registries.
- Tests: missing/wrong/throwing module fixtures, disabled startup identity,
  handler-before-ready assertions, disabled exact Intent/Presentation
  rejection, no-resource cleanup, `AudioIntegrationTestRunner`,
  `SystemTestRunner`, and clean server/client bootstrap verification.
