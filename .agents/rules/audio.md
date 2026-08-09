# Audio system rules

## Scope

Apply to audio catalogs/configuration, `AudioPlayer`, `AudioEmitter`,
`AudioListener`, `AudioFader`, `Wire`, `AudioDeviceOutput`, ordinary or Music
playback, audio pools, audio settings, audio preloading, hybrid audio DTOs, the
`Shared/Sounds` asset root, and `SoundService.AcousticSimulationEnabled`.

Required context: `docs/AudioSystem.md`, `docs/AssetRegistry.md`,
`docs/ContentPreloading.md`, `docs/ResourceManagement.md`,
`docs/InitializationAndSaveSystem.md`, the approved SFX product requirements
and technical specification, and template ADR-0039, ADR-0040, and ADR-0041.
Also read every existing subsystem rule selected by the concrete change.

## Configuration and catalog authority

- Audio startup data MUST be limited to the reviewed modules under
  `ReplicatedStorage.Shared.Configs.Audio`: generated `SoundCatalog`,
  `AudioRuntimeConfig`, `RoutingConfig`, and `SpatialProfiles`.
- `SoundCatalog` MUST be generated deterministically from
  `configs/audio/Sounds.csv`; authors edit the CSV, not the generated Luau.
- Server and client manifests MUST NOT require or interpret raw audio config in
  constructor phase. One `AudioStartupInitializationCommand` after `Assets`
  MUST protected-resolve, require, independently exact-validate, and deep-freeze
  the same modules before publishing `AudioStartupState`.
- `AudioSafetyLimits` MUST remain reviewed code outside `Configs`. Authored
  values MUST NOT raise its per-type, aggregate, protocol, path, or graph
  ceilings.
- Audio startup data MUST NOT use Experience Config, Attributes, ValueObjects,
  network projection, live refresh, or runtime mutation.
- An invalid config, top-level cross-reference, or ceiling MUST yield one stable
  side-disabled audio boundary before audio pools, graph publication, preload,
  or playback exist. Partial valid config MUST NOT be published. Exact hybrid
  handlers MUST still register after `Communication` and before `ClientReady`;
  disabled handlers decode then reject/no-op with `AudioDisabled` and MUST NOT
  access graph, pools, fanout, playback, retry, replay, or resync state.
- Public identifiers and paths MUST follow the grammar, normalization, length,
  finite-number, and exact-shape limits in the approved specification.

## AssetRegistry and physical Sounds

- `ReplicatedStorage.Assets.Shared.Sounds` is the only physical audio root and
  is indexed as `Shared/Sounds` by each side-owned immutable `AssetRegistry`.
- Physical `Sound` descendants are static descriptors, not runtime players.
  Playback MUST use a pooled `AudioPlayer` wrapper and MUST NOT mutate or
  reparent catalog originals.
- The ADR-0039 first-wins exception applies only when every colliding
  `AssetKey` candidate is a `Sound` under `Shared/Sounds`.
- Eligible collisions MUST be ordered by validated canonical path using
  ordinal comparison. The first candidate owns the key index; later candidates
  remain path-addressable and emit a bounded stable diagnostic.
- Any collision involving another class/root, every duplicate logical path,
  and all other AssetRegistry validation failures remain fatal.
- Audio first-wins MUST NOT depend on Roblox child order and MUST NOT weaken
  the default AssetRegistry policy outside the exact audio boundary.
- AssetRegistry MUST NOT become an audio graph locator, live descendant
  watcher, runtime-world registry, ModuleScript resolver, remote registry, or
  generic service locator.

## Preloading and pools

- Production audio preloading MUST route through `ContentPreloader`; audio code
  MUST NOT call `ContentProvider:PreloadAsync()` directly.
- The startup audio request MUST use stable ID `AudioCatalog.Preload.v1`, sort
  and deduplicate normalized content IDs, use `Warn`, and finish before audio
  readiness. It MUST NOT add retries or a second preload manager.
- The server and every client MUST use their own existing `PoolModule` registry.
  Ordinary and Music pools, sides, player types, and concrete wrapper types
  MUST remain separate and homogeneous.
- Each pool MUST declare finite configured active/retained budgets that fit all
  code-owned side aggregate and worst-case object ceilings.
- Every acquire MUST return a generation lease. Readiness, timeout, `Ended`,
  target removal, FIFO eviction, transition completion, and all delayed
  callbacks MUST capture and verify the current generation.
- One idempotent completion owner MUST perform disconnect, stop, full mutable
  reset, lease release, and partial-construction cleanup. A stale callback is a
  no-op.
- Ordinary capacity MUST evict the oldest active or pending playback before
  replacement acquire. Music MUST use its bounded LIFO stack and MUST NOT use
  ordinary FIFO eviction.

## Graph and spatial ownership

- `AudioGraph` MUST be constructed by explicit server/client manifest commands
  and published atomically as one generation. Repeated initialization in one
  bootstrap returns the same ready or disabled result.
- The exact replicated handoff root is `ReplicatedStorage.AudioRuntime`; it
  carries the reviewed `AudioGraph.v1`, schema-version, generation, and ready
  markers and contains immutable `PublishedGraph` plus dynamic
  `ServerPlayback`. Clients MUST bounded-wait and validate the complete exact
  composition before binding any local source or output wire.
- The server owns replicated persistent category/Master faders, static wires,
  and the graph-generation container. Each client owns its local listener,
  device output edge, character/camera binding, and personal fader values.
- UI, SFX, World, Music, and Master category contracts are mandatory. Source,
  user-fader, and Music-transition multipliers MUST remain separate values.
- A World source MUST traverse its lease-owned `AudioEmitter`, the client
  `AudioListener`, World fader, and Master. It MUST NOT wire directly to World,
  Master, or output.
- Point playback accepts only a validated `Vector3`; attached playback accepts
  only a side-valid positionable `Instance`. Emitters and point anchors remain
  owned by the playback wrapper and MUST NOT be parented into the target.
- Character lifecycle MUST be consumed through the side-specific
  `PlayersModule`. Missing/replaced characters silence or rebind only the World
  path; nonspatial categories continue.
- The client listener MUST use one feature-owned transform Instance updated by
  an injected render-frame driver: position comes from current
  `HumanoidRootPart`, rotation comes from current camera, and camera translation
  is ignored. Cleanup MUST disconnect the driver, clear `PositionInstance`, and
  destroy the transform and local graph objects.
- `SoundService.AcousticSimulationEnabled=true` is a canonical `place.rbxl`
  authoring prerequisite. Runtime source MUST NOT write, toggle, or restore it.
- A malformed top-level spatial registry MAY disable the side, but an invalid
  profile record or missing/invalid profile reference MUST skip only every
  affected catalog variant with a stable warning. Unrelated variants and
  nonspatial categories remain available.
- The first release MUST NOT implement production whole-audio
  `Stop -> Initialize` or graph generation replacement.

## Playback and communication boundaries

- Ordinary sound and Music MUST remain separate runtime owners. Music is
  client-only, nonspatial, and owns its pool, LIFO stack, handles, and
  transition scheduler.
- Public ordinary APIs MUST keep separate local, server-all, and client-hybrid
  families; a generic delivery-mode parameter is forbidden.
- Server-all playback MUST create one server-owned wrapper/lease and rely on
  native Roblox replication. It MUST NOT send per-recipient application play
  commands.
- Client-hybrid is best-effort, non-looping, nonspatial-or-point one-shot only.
  It MUST use the existing `Communication` Presentation path and send one exact
  versioned `CueId + VariantId` pair with validated scalar overrides.
- Hybrid payloads MUST NOT contain an `Instance`, folder/resource/asset key,
  raw asset ID, attached source, player identity, recipient list, request ID,
  loop/stack state, distributed playback ID, acknowledgement, retry, replay,
  snapshot, resync, or stop protocol.
- The server obtains the initiator from transport context, revalidates catalog
  membership/policy, excludes the initiator, computes the complete ready
  recipient set, and applies per-type, per-owner, accepted-event, and atomic
  fanout token buckets before queueing any recipient.
- A hybrid reject MUST leave the initiator's predicted one-shot unchanged and
  MUST NOT create a server `AudioPlayer` or lease.
- Client `Communication:Queue` rejection MUST preserve predicted playback,
  log stable `HybridQueueRejected`, and MUST NOT retry, requeue, or cancel the
  local handle.

## Music and settings

- Music stack entries MUST retain generation-safe leases and saved positions
  for LIFO resume. A full stack rejects the new push without evicting existing
  entries.
- `Instant`, `SequentialFade`, and `Crossfade` are the only first-release
  transitions. At most two adjacent entries participate in a transition.
- Every stack mutation MUST synchronously cancel and rebase the prior
  transition before advancing stack/scheduler generations. Old tween,
  readiness, timeout, or `Ended` callbacks MUST NOT change the new state.
- `AudioSettings` is a client-authority domain/save provider with exact
  versioned data. It MUST use normal SaveModule snapshot, rollback,
  `MementoChanged`, `SaveClientPatch`, revision, and persistence contracts.
- Provider registration MUST be explicit on server/client and precede Version.
  Save controllers MUST NOT own audio runtime state.
- `AudioSettings:Run` MUST synchronously apply restored/default levels and
  enabled values before connecting Master to device output and before
  `ClientReady`.
- Invalid settings snapshots/patches MUST preserve the complete current
  settings and revision. Settings MUST NOT use a separate store or audio
  remote.
- TF-0005 MUST add optional provider-specific `ValidateEnvelope` hooks to the
  existing controllers and implement them only for `AudioSettings`: server
  `(player, envelope) -> (boolean, reason?)`, client
  `(envelope) -> (boolean, reason?)`. The hooks MUST NOT sanitize or mutate the
  envelope; false or exception MUST fail closed before provider mutation.
- `AudioSettings` MUST also implement the client-only optional
  `ReconcileSnapshotEnvelope(envelope?) -> (boolean, envelope?, reason?)` hook.
  It may create defaults for a missing provider and fill only missing known
  data fields. Unknown fields, invalid present values, and wrong versions MUST
  be rejected. Client order is present-envelope validation, reconciliation,
  returned-envelope validation, then memento validation. Providers without
  these hooks MUST retain the current mandatory-envelope/no-reconciliation
  behavior.

## Logging and failure containment

- Audio diagnostics MUST use the shared Logger with stable reason codes,
  bounded safe fields, and no direct `print` or `warn`.
- Raw untrusted payloads, full asset URLs, save data, secrets, and stack traces
  for expected rejects MUST NOT be logged.
- A failure MUST be contained at the smallest defined boundary: row skip,
  playback rejection/release, hybrid reject, settings transaction reject, or
  complete side-disabled startup. Silent partial publication is forbidden.
- Audio MUST NOT add a separate diagnostics pipeline, warning limiter, retry
  loop, LRU cache, cooldown, or distributed desired-state registry beyond the
  approved token buckets and catalog anti-repeat state.

## Rojo and authoring

- The `Sounds` folder mapping MUST create only the canonical folder and keep
  `$ignoreUnknownInstances=true`; physical `Sound` descendants remain
  Studio-owned in `place.rbxl`.
- Source and the canonical place MUST NOT both author the same Sound instance
  or property. Generated validation builds and `sourcemap.json` are not source.
- Scene changes, including Acoustic Simulation, require an explicitly
  authorized Studio edit to canonical `place.rbxl` and binary ownership
  coordination. Never patch the binary programmatically.

## Verification

- Run generated-catalog preview/apply/re-preview freshness and exact hash
  checks.
- Run `AudioCatalogTestRunner`, `AudioPlaybackTestRunner`, and
  `AudioIntegrationTestRunner` through `TestHarness`, then the complete
  `AllTestsRunner` aggregate.
- Preserve existing `AssetRegistry`, `ContentPreloader`, `ResourceManagement`,
  `System`, `ProductionIntegration`, and `ProductionReadiness` coverage for
  every touched boundary.
- Run a Rojo build, repository validators, and clean server/client Play with no
  unexpected diagnostics after source or mapping changes.
- Run the approved multi-client audio scenarios for local isolation,
  server-all replication, hybrid exclusion/fanout, spatial/listener behavior,
  settings persistence, Music independence, and canonical acoustic policy.
