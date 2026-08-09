# ADR-0040: Own the audio graph and acoustic policy at bootstrap

- Status: Accepted
- Date: 2026-08-07
- Deciders: Project maintainers
- Supersedes: None
- Superseded by: None

## Context

Roblox Advanced Audio requires a persistent graph of players, emitters,
listeners, faders, wires, and device output. Partial publication can produce
double output, silent spatial paths, or clients bound to different graph
generations. Character/camera rebinding and per-client settings also need
clear ownership without moving platform lifecycle into the graph.

`SoundService.AcousticSimulationEnabled` is a global DataModel property. If a
runtime module toggles or restores it, unrelated audio and another graph
generation can observe hidden global state. Supporting production
`Stop -> Initialize` would require a replacement protocol for persistent
instances, listeners, settings bindings, active leases, and network handlers
that the first release does not need.

## Decision

Make `AudioGraph` a manifest-owned one-shot bootstrap subsystem:

- the server builds replicated persistent category/Master faders, static
  wires, the private interaction group contract, and one graph generation in
  an unpublished temporary container, then publishes it atomically;
- each client binds exactly that server generation and owns its local
  `AudioListener`, `AudioDeviceOutput`, listener/device edges, character/camera
  rebinding, and personal fader values;
- world playback always traverses source → lease-owned `AudioEmitter` → client
  listener → World fader → Master; UI/SFX/Music never bypass their category
  fader;
- repeated `Initialize` in one bootstrap returns the same ready or disabled
  result, and every partial failure destroys unpublished resources;
- the first release exposes playback/handle cleanup and `StopAllMusic`, but no
  production whole-system `Stop -> Initialize` or graph replacement lifecycle.

The canonical `place.rbxl` ships with
`SoundService.AcousticSimulationEnabled = true`. Runtime source treats that
value as an authoring prerequisite and never writes, toggles, or restores the
global property. Any change to it is an explicitly authorized Studio edit to
the canonical place and is verified before Play.

## Alternatives considered

### Let each playback create its own graph and output

Rejected because routing, interaction groups, settings, and output ownership
would be duplicated and could produce double playback.

### Toggle AcousticSimulationEnabled during initialization or shutdown

Rejected because a domain module would mutate global DataModel policy and make
cleanup/reinitialization order observable by unrelated audio.

### Support production Stop and graph reinitialization in the first release

Rejected because safe replacement requires a broader lifecycle and migration
contract for active leases, replicated instances, handlers, and saved settings.

## Consequences

### Positive

- Consumers observe either one complete graph generation or a stable disabled
  boundary.
- Server replication and per-client presentation/settings ownership remain
  explicit.
- Global acoustic policy is reviewable in the canonical scene and cannot drift
  through runtime cleanup.
- Initialization and delayed callback behavior remain generation-safe and
  testable.

### Negative

- Changing the acoustic property requires serialized Studio ownership of
  `place.rbxl`.
- A failed side remains audio-disabled until a fresh bootstrap.
- A future production reinitialization feature needs a new ADR and broader
  lifecycle protocol.

## Enforcement

- Agent rules: `.agents/rules/audio.md`, `.agents/rules/architecture.md`,
  `.agents/rules/initialization.md`, `.agents/rules/players.md`,
  `.agents/rules/resource-management.md`, `.agents/rules/rojo-project.md`, and
  `.agents/rules/testing.md`.
- Current documentation: `docs/AudioSystem.md`,
  `docs/InitializationAndSaveSystem.md`, `docs/ResourceManagement.md`, and
  `docs/Features/template/sfx-system/technical-specification.md`.
- Code boundaries: server/client audio graph modules and initialization
  commands, server/client manifests, `PlayersModule` integration,
  `SoundService`, and canonical `place.rbxl`.
- Tests: `AudioPlaybackTestRunner`, `AudioIntegrationTestRunner`,
  `SystemTestRunner`, aggregate `AllTestsRunner`, clean server/client Play, and
  mandatory multi-client audio scenarios.
