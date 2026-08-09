# Audio playback system

## Status and authority

The audio playback feature is tracked as `TF-0005 / sfx-system`. This page is
the current subsystem guide for implementation and maintenance; it does not
replace the approved
[product requirements](Features/template/sfx-system/product-requirements.md)
or the exact
[technical specification](Features/template/sfx-system/technical-specification.md).

The durable architecture is owned by:

- [ADR-0039](adr/template/0039-allow-deterministic-audio-only-asset-key-first-wins.md)
  for the exact AssetRegistry duplicate-key exception;
- [ADR-0040](adr/template/0040-own-audio-graph-and-acoustic-policy-at-bootstrap.md)
  for graph, listener/output, and canonical acoustic ownership;
- [ADR-0041](adr/template/0041-protect-audio-startup-and-keep-disabled-transport-handlers.md)
  for protected local configuration loading and disabled transport handlers.

ADR-0041 supersedes ADR-0038. Read `.agents/rules/audio.md` before changing
audio configuration, assets, graph, playback, networking, settings, tests, or
the canonical place.

## Ownership map

| Boundary | Owner |
|---|---|
| Global startup order | Existing server/client manifests and `InitializationRunner` |
| Raw audio module loading and normalized startup state | `AudioStartupInitializationCommand` on each side |
| Static physical Sound discovery | Side-owned immutable `AssetRegistry` |
| Preload execution | Existing client `StartupContentPreloadCommand` and `ContentPreloader` |
| Persistent replicated faders/static wires/runtime root | `AudioGraphServer` |
| Local listener, transform, device output, local wires and personal fader values | One `AudioGraphClient` per client |
| Ordinary server-all pools and API | `OrdinarySoundServer` |
| Ordinary local/hybrid pools, predicted playback and handles | `OrdinarySoundClient` |
| Hybrid Intent validation/fanout | `HybridOneShotServerController` |
| Hybrid Intent send and Presentation receive | `HybridOneShotClientController` |
| Music pools, stack and transition scheduler | `MusicClient` |
| User levels/enabled state and save provider | `AudioSettingsModule` / `AudioSettingsClient` |

There is no second bootstrap, direct audio remote, audio service locator,
audio-owned player lifecycle, shared server/client pool, or production whole
audio `Stop -> Initialize` lifecycle.

## Startup and disabled state

Manifests pass `ReplicatedStorage`, exact config path/module names, the
initialized `AssetRegistry`, `AudioSafetyLimits`, and `Logger` to one side-local
`AudioStartupInitializationCommand`. They do not require raw audio config in
constructor phase.

After `Assets`, the command resolves and protected-requires exactly:

```text
ReplicatedStorage.Shared.Configs.Audio.SoundCatalog
ReplicatedStorage.Shared.Configs.Audio.AudioRuntimeConfig
ReplicatedStorage.Shared.Configs.Audio.RoutingConfig
ReplicatedStorage.Shared.Configs.Audio.SpatialProfiles
```

It validates exact schemas, cross-references and code-owned ceilings, builds
the physical/generated catalog, materializes defaults, and deep-freezes one
complete `AudioStartupState`:

```lua
{ Enabled = true, Config = validatedConfig, Catalog = audioCatalog }
-- or
{ Enabled = false, ReasonCode = reasonCode }
```

Missing, wrong-class, throwing, malformed, routing-invalid, or over-budget
inputs disable only that side before audio preload, pools, graph, or playback
resources exist. After `Communication`, the exact hybrid handlers still
register before `ClientReady`. In disabled mode they exact-decode and return
`AudioDisabled` without graph, pools, fanout, playback, retry, replay, or
resync work.

Required relative order:

```text
Server: Assets -> AudioStartup -> Pooling -> Players -> Communication
        -> AudioGraph -> OrdinarySound

Client: Assets -> AudioStartup -> StartupContentPreload -> Pooling -> Players
        -> Communication -> AudioGraph -> OrdinarySound -> Music
```

Existing unrelated commands keep their documented order. `AudioSettings`
provider composition occurs through the existing Save/DomainData/GlobalSave
lifecycle and completes before `ClientReady`.

## Authoring configuration and catalog

The authored source is `configs/audio/Sounds.csv`; it generates
`ReplicatedStorage.Shared.Configs.Audio.SoundCatalog` deterministically in
array mode. Authors do not hand-edit the generated Luau module.

The three static modules are versioned exact local tables:

- `AudioRuntimeConfig` owns player budgets, readiness timeouts, source/speed
  ranges, hybrid type budgets, Music stack budget and fader gain profiles;
- `RoutingConfig` owns player-to-fader routes, fader parent links and the
  private interaction-group ID;
- `SpatialProfiles` owns the spatial profile registry and default World
  profile ID.

`AudioSafetyLimits` is reviewed code outside `Configs`. Authored values cannot
raise its type, fader, route, profile, pool, object-cost, protocol, path, rate,
fanout, transition, or graph-wait ceilings. Audio config does not use
Experience Config, Attributes, ValueObjects, client projection, live refresh,
or runtime mutation.

Each valid generated row becomes a frozen normalized `CatalogVariant` with all
defaults materialized and a normalized decimal `AssetId`/`ContentId`. Catalog
indexes support `CueId`, `AssetId`, `AssetKey`, `ResourcePath`, and recursive
`FolderPath`. Weighted Cue/folder selection uses injected randomness and
side-local anti-repeat state. Selection divides eligible weights by their
maximum and uses compensated CDF sums, with exact zero selecting the first
eligible catalog row. Valid samples in `[0, 1)` are never clamped; strict CDF
comparison preserves half-open intervals and assigns an exact boundary to the
following catalog-order row. This avoids aggregate overflow, preserves every
representable tiny tail (including high samples), and adds no authoring
ceiling; ordinary small-weight boundaries and anti-repeat behavior remain
unchanged. Invalid catalog rows are skipped with stable
diagnostics; invalid routing topology disables the side. An invalid spatial
profile record/reference removes only affected variants. Generated row keys
must be positive integers; zero, negative, fractional, and non-numeric keys
are isolated as `CatalogRowSkipped/InvalidRow`.

## Physical Sounds and preloading

`ReplicatedStorage.Assets.Shared.Sounds` is the only physical audio root and is
indexed as `Shared/Sounds`. Its folder mapping uses
`$ignoreUnknownInstances=true`; physical `Sound` descendants remain
Studio-owned descriptors in canonical `place.rbxl`. Runtime never mutates or
reparents those descriptors and never duplicates them in Rojo source.

ADR-0039 permits first-wins only when every colliding `AssetKey` candidate is a
`Sound` below `Shared/Sounds`. Canonical paths are validated and ordinal-sorted
before choosing the winner. Later candidates remain path-addressable. Any
other duplicate remains fatal under the normal AssetRegistry contract.

The client builds a unique sorted preload list from valid variants/descriptors
with `Preload=true`. Existing `StartupContentPreloadCommand` executes request
`AudioCatalog.Preload.v1` through `ContentPreloader` with `Warn`. Audio code
does not call `ContentProvider:PreloadAsync()` directly and adds no retry or
second preload manager.

## Graph and spatial listener

The server constructs an unpublished candidate and parents it into
`ReplicatedStorage` only after full validation. The stable handoff is:

```text
ReplicatedStorage.AudioRuntime
├─ PublishedGraph
│  ├─ Faders
│  │  ├─ Master
│  │  ├─ UI
│  │  ├─ SFX
│  │  ├─ World
│  │  └─ Music
│  └─ Wires
└─ ServerPlayback
```

The runtime root carries exact `CompositionId="AudioGraph.v1"`,
`SchemaVersion=1`, `Generation=1`, and `Ready=true` attributes. Clients wait at
most ten seconds for the complete exact composition; Roblox descendant
replication order is not treated as atomic. A mismatch, replacement, missing
child, or timeout creates a cleaned-up local no-op graph and never binds a
partial source/output path.

Every World source follows:

```text
AudioPlayer -> lease-owned AudioEmitter -> client AudioListener
            -> World fader -> Master -> AudioDeviceOutput
```

Point and Attached sources both set
`AudioEmitter.PositionType=Enum.EmitterPositionType.Instance` before
`PositionInstance`. Point uses a lease-owned nondirectional anchor. Attached
uses the validated `PVInstance`, `Attachment`, or `Camera`, including its
orientation for `AngleCurve`. Release clears `PositionInstance` and restores
`PositionType=Parent` before reuse.

Each client owns one invisible anchored listener transform. The listener binds
its immutable `PositionInstance` to that anchor; runtime never reads or writes
the feature-gated `AudioListener.PositionType`. While bound, matching parent
placement keeps the current engine's effective acoustic transform aligned with
the same anchor without replacing the `PositionInstance` lifecycle contract.
An injected render-frame driver places the anchor at the current character
`HumanoidRootPart` and applies only the current camera rotation. Camera
translation is ignored, so zoom does not change distance attenuation. Missing
character/root/camera clears `PositionInstance` and parks the listener under
the unpositioned local graph, silencing only World without invalidating the
rest of the graph. Rebinding restores the same anchor and binding.
`PlayersModule` owns character lifecycle; cleanup clears the binding,
disconnects the frame driver, and destroys local graph objects.

`SoundService.AcousticSimulationEnabled=true` is authored only in canonical
`place.rbxl`. Runtime never writes or restores it. A valid client listener
enables its capability once; each lease-owned emitter applies only its selected
profile flag/curves.

## Playback families

Ordinary APIs are intentionally separate:

- client-local affects only the caller;
- server-all creates one server lease and relies on native Roblox replication;
- client-hybrid predicts one local non-looping nonspatial/point one-shot and
  sends one exact best-effort Intent through existing Communication.

Public client failure always returns only an inert `PlaybackHandle` or
`MusicHandle`; no extra reason return is part of v1. Server APIs return
`DispatchResult`. Public play never yields. Readiness, timeout, completion,
target removal, FIFO eviction and late callbacks converge on one idempotent
generation-checked release owner.

Hybrid sends only version, exact `CueId + VariantId`, validated scalar
overrides and `None|Point`. The server revalidates catalog membership/policy,
derives the initiator from transport context, excludes it, and atomically
checks type/owner/server/fanout budgets before atomically enqueuing Presentation
for all other currently ready clients. A recipient queue rejection restores
every queue touched by that fan-out and logs `HybridQueueRejected`; there is no
partial audience delivery. There is no attached form, loop, Music, `Instance`,
raw asset key/path, recipient identity, request/playback ID, acknowledgement,
retry, replay, snapshot, resync, or stop protocol. A client Queue rejection
logs `HybridQueueRejected`, preserves prediction, and does not retry.

The exact HybridIntentV1 schema has two 128-byte identifiers and bounded scalar
and spatial fields, so a schema-valid v1 value is smaller than the independent
2048-byte serializer ceiling. The production codec still always supplies that
ceiling (plus its node/issue bounds) before exact schema validation. Focused
evidence observes this serializer boundary through an injected validator so
removing the 2048-byte argument fails independently of identifier, shape,
spatial, or scalar rejection.

## Pools, Music and settings

Server and every client own separate `PoolModule` registries. Pools are
homogeneous per side, subsystem, player type and wrapper shape. Ordinary
capacity evicts the oldest active/pending entry before replacement acquire.
Music never uses ordinary FIFO: a full stack rejects the new request without
changing entries, leases, transition, generations, or audible incumbent.

Music is client-only and keeps a bounded LIFO stack. `Top Music entry` is the
structural top; `Audible Music incumbent` may remain below it while the new top
is pending. `Instant`, `SequentialFade`, and `Crossfade` are the only v1
strategies, with at most two adjacent playing participants. Every mutation
cancels stale transition callbacks. On `IsReady` loss, the affected entry is
first stopped and excluded, then the highest remaining ready entry becomes the
only incumbent or the result is silence. Accepted `PlayOptions` are normalized
into an immutable private entry snapshot, so caller mutation cannot alter a
later readiness reload's volume, speed, or starting-position policy.

`AudioSettings` is a normal client-authority save/domain provider with levels
for Master/UI/SFX/World/Music and enabled flags for UI/SFX/World/Music. It uses
the existing snapshot, rollback, resync, dirty patch and persistence flow.
TF-0005 adds side-specific optional `ValidateEnvelope` hooks and one client-only
`ReconcileSnapshotEnvelope` hook, implemented only by AudioSettings. Validation
never sanitizes the outer envelope; reconciliation creates defaults only for a
missing provider or missing known data fields and rejects unknown/invalid
present data. False or exception fails before mutation, while providers without
the hooks keep their existing mandatory-envelope behavior. `Run` applies
restored/default settings before connecting Master to the device output and
before `ClientReady`.

## Verification and release evidence

The implementation registers these focused suites in this order before broad suites:

1. `AudioCatalogTestRunner`
2. `AudioPlaybackTestRunner`
3. `AudioIntegrationTestRunner`

Then run the complete `AllTestsRunner`, repository validators, a Rojo build,
and a clean server/client Play. Because the feature touches graph replication,
Communication, save, player lifecycle and canonical scene ownership, also run
all multi-client `Studio-E2E-AUDIO-01..05` scenarios from the technical
specification. Evidence is valid only for the exact reviewed source/tree and
must cover every `PRD-AC-001..079`; unexpected server/client warnings or errors
fail the gate.

Focused runners are executable evidence only when their recorded exact-source
run passes. The multi-client Studio scenarios remain explicit runtime gates and
must not be inferred from documentation or isolated tests.

The focused fixtures prove only their named deterministic paths. In particular,
`AudioPlaybackTestRunner` executes the push/stop/end/readiness-loss/StopAll and
late-callback matrix in all SequentialFade/Crossfade phases;
`AudioIntegrationTestRunner` executes client preflight and Queue rejection,
atomic enqueue rollback/exact-pair reuse, listener dependency loss/rebind/
cleanup, and both real save-controller settings paths. Audible multi-client
replication, leave/rejoin persistence, and listener perception remain the
separate Studio E2E scenarios above.

`AudioCatalog/StartupPreloadSet` executes in `ContentPreloaderTestRunner`, not
the catalog runner: it enables the production startup command and verifies the
exact sorted unique list, `AudioCatalog.Preload.v1`, `Warn` failure
continuation, and sticky result reuse.
