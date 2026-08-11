# Collaborative Audio Studio QA

## Purpose

This is the operator runbook for testing the production Audio system with one
agent and one human operator. The agent controls the QA modules, captures
objective graph/pool/settings evidence, and tells the operator exactly what to
do. The operator performs movement, camera, focus, respawn, and reconnect
actions and reports only what they actually hear.

The system combines two evidence tracks:

- deterministic runners cover catalog/config validation, bounds, pools,
  generations, failure containment, Communication, save rollback, and Music
  transition mutations;
- collaborative Studio scenarios cover real engine audio, two-client
  isolation/replication, attenuation, listener motion, client-independent
  state, background/foreground behavior, and hearing observations.

Neither track substitutes for the other. The canonical plan maps all
`PRD-AC-001..079` to one of these tracks and exposes every public playback,
Music, settings, graph, pooling, catalog, and transport capability.

## Reviewed live assets

Collaborative playback uses only these three production catalog pairs and
Studio-authored descriptors:

| Role | Exact catalog pair | Exact asset | Exact descriptor path |
|---|---|---|---|
| Nonspatial SFX | `Template.SFX.CartoonBubble / Default` | `rbxassetid://5852470908` | `Shared/Sounds/SFX/Cartoon bubble button Sound` |
| Spatial World SFX | `Template.World.OldCarEngine / Default` | `rbxassetid://137048982817372` | `Shared/Sounds/SFX/engine sound for old cars` |
| Music | `Template.Music.PrayerRiver / Default` | `rbxassetid://91760644839532` | `Shared/Sounds/Music/祈りの川` |

Both client drivers and the server driver fail during `Start` unless every
exact pair resolves to the expected player type, asset/content ID, resource
path, authored playback fields, and hybrid policy, and the descriptor at that
exact path is a `Sound` with the expected `SoundId`. A similarly named object,
a matching asset under another path, or a stale catalog row does not satisfy
this gate. The descriptor's authored `Looped` property is reported for
evidence, while the immutable catalog row remains authoritative for runtime
looping.

The first release has no reviewed live UI sound. UI routing and fader
boundaries therefore remain deterministic/objective coverage; collaborative
hearing claims use only the three assets above.

## Safety and architecture

The QA modules are manual `ModuleScript`s. Requiring them does nothing until
`Start` or `Execute` is called. After each production bootstrap succeeds in
Studio, that bootstrap installs one side-local `BindableFunction` below its
own existing bootstrap Script. The callback closes over that bootstrap VM's
actual initialized service table; an operator invocation forwards only a
whitelisted command and sanitized primitive data. The bridge is never a
server/client transport and never returns a service/module/Instance reference.
The drivers:

- run only in Studio while Play/Test Server is active;
- reuse the exact production service instances bound by the already completed
  client/server bootstrap, even when an operator command has an isolated
  ModuleScript cache;
- create no bootstrap, startup script, RemoteEvent, replay, or parallel audio
  implementation;
- use the production Communication path for hybrid playback;
- create only named transient marker/target Parts and remove them in cleanup;
- keep objective observations separate from human hearing confirmation.

Outside Studio the bootstraps do not require the QA drivers and create no
bridge. `scripts/validate-repository-layout.ps1` enforces the exact
post-success Studio gates without depending on whitespace or comments, absence
of any other bootstrap QA reference, the exact reviewed QA source inventory,
lexer-aware absence of executable remote creation/calls, and absence of
`.server`/`.client` Lua or Luau files anywhere under Tests/QA roots. The
deterministic `ShouldInstall(false)` assertion is only a companion unit check,
not runtime proof of the source path.

The frozen client whitelist is exactly `Start`, `Execute`, `Snapshot`, and
`Cleanup`; the frozen server whitelist adds `RecordScenario` and `Export`.
Unknown commands and representable unsafe, cyclic, sparse, excessive, or
non-finite payloads fail closed before handler dispatch. The caller-side
`Bridge.Invoke` also rejects metatables, coroutines, cycles, and mixed/sparse
tables before crossing the Bindable boundary. Roblox rejects a raw cyclic
table before `OnInvoke`; for other raw calls it strips metatable/frozen state,
normalizes a coroutine value to `nil`, drops the dictionary field of a mixed
table, stringifies a sparse numeric key, and copies the table. The handler
therefore cannot execute the caller's `__iter`, but cannot retrospectively
detect data already removed or transformed by Roblox. Direct raw Bindable
invocation is evidence of this engine boundary, not an accepted operator API;
operator commands use `Bridge.Invoke`. Both serializers accept only plain
tables and traverse them with raw `next`. Session cleanup releases QA-owned
playback handles, transient Parts, one-shot labels, Music entries, and settings
overrides. The bridge is owned by the Play DataModel and disappears with that
DataModel.

The server report evaluator refuses a `PASS` when an objective observation is
missing. A hearing-required scenario also refuses `PASS` unless the operator
explicitly confirmed the audible result. The agent must never infer hearing
from `IsReady`, `IsPlaying`, an active lease, or a clean output log.
The contract cannot cryptographically prove who typed a statement; it instead
rejects a bare `HumanPassed` boolean and requires explicit bounded metadata
with `Source="OperatorStatement"`, `Confirmed`, and the operator's actual
`Observation`. The agent may populate it only after the operator supplies that
observation.

## Required topology

Use the canonical project place and one existing matching Studio instance.
Start a Test Server with exactly one server and two clients, named `ClientA`
and `ClientB` in the report. Before the first Studio operation, follow the
repository Rojo preflight and instance-selection rules.

`ClientMusicSettingsSave` additionally requires a user-approved persistence
backend and controlled leave/rejoin. If that environment is unavailable,
record the scenario as `BLOCKED`; do not replace it with an in-memory result.
After rejoin, explicitly run `Client.Start` again with the same `RunId` and
client label before the first restored-state snapshot.

The canonical acoustic prerequisite must be `true`, and all three reviewed
assets must pass startup preload observation. If the run instead observes
`AcousticSimulationEnabled=false` or three preload delivery failures, report
those separately; the harness never mutates the scene, catalog, preload result,
or production runtime to hide them.

## Start a run

After both bootstraps are ready, execute on the server:

```lua
require(game.ServerScriptService.Tests.AudioManualQaServer).Start("TF0005-AUDIO-01")
```

Execute on Client A:

```lua
require(game.ReplicatedStorage.Shared.Tests.AudioManualQaClient).Start("TF0005-AUDIO-01", "ClientA")
```

Execute on Client B:

```lua
require(game.ReplicatedStorage.Shared.Tests.AudioManualQaClient).Start("TF0005-AUDIO-01", "ClientB")
```

Every call emits one JSON line prefixed with `[AudioManualQA]`. The payload is
primitive-only so an agent can capture and compare it without relying on the
Explorer UI. The same `RunId`, exact `PlaceId`, and exact `GameId` must appear
in all three start snapshots.

## Agent/operator protocol

For each scenario, the agent follows this sequence:

1. Read the scenario from `AudioManualQaPlan` and state the next operator
   action plus the expected audible distinction in one short instruction.
2. Wait for the operator to say they are ready before firing a short cue.
3. Invoke only the named server/client action and capture its JSON snapshot.
4. Ask one unambiguous hearing question. Record the answer verbatim or as a
   concise faithful summary.
5. Compare objective observations across server, Client A, and Client B.
6. Record `PASS`, `FAIL`, or `BLOCKED` on the server. Never downgrade a real
   failure to `BLOCKED` and never promote a missing observation to `PASS`.
7. Cleanup transient playback/targets/settings before the next scenario when
   the plan calls for isolation.

The canonical plan contains these complete scenario identities:

- `Studio-E2E-AUDIO-01`: `LocalOnly`, `HybridPrediction`,
  `ServerVariantOnce`, `ServerSingleAudibleReplication`,
  `HybridNoServerPlayer`;
- `Studio-E2E-AUDIO-02`: `NonSpatialInvariant`, `PointAttenuation`,
  `AttachedFollowOrientation`, `ServerAttachedReplication`,
  `CharacterPositionCameraOrientation`;
- `Studio-E2E-AUDIO-03`: `CategoryIsolation`,
  `ClientMusicSettingsSave`, `IndependentFaders`;
- `Studio-E2E-AUDIO-04`: `IndependentMusicStacks`,
  `BackgroundForegroundLifo`;
- `Studio-E2E-AUDIO-05`: `CleanGraphRuntime`.

## Driver commands

Invoke client actions from the selected client VM:

```lua
local QA = require(game.ReplicatedStorage.Shared.Tests.AudioManualQaClient)
QA.Execute("play_local_sfx", { Label = "local-1" })
QA.Execute("create_point_marker", { Distance = 12 })
QA.Execute("play_local_at_marker", { Label = "point-near" })
QA.Execute("create_attached_target", { Distance = 12 })
QA.Execute("play_local_attached", { Label = "attached-1" })
QA.Execute("move_attached_target", { X = 8, YawDegrees = 90 })
QA.Execute("play_hybrid_sfx", { Label = "hybrid-1" })
QA.Execute("play_hybrid_at_marker", { Label = "hybrid-point-1" })
QA.Execute("play_music", { Label = "A", Strategy = "Instant" })
QA.Execute("play_music", { Label = "B", Strategy = "SequentialFade" })
QA.Execute("play_music", { Label = "C", Strategy = "Crossfade" })
QA.Execute("stop_handle", { Label = "C", Strategy = "Crossfade" })
QA.Execute("stop_all_music")
QA.Execute("set_level", { Category = "SFX", Level = 0.25 })
QA.Execute("set_enabled", { Category = "UI", Enabled = false })
QA.Execute("validate_invalid_settings_snapshot")
QA.Execute("restore_settings")
QA.Execute("snapshot")
```

Invoke server actions from the server VM:

```lua
local QA = require(game.ServerScriptService.Tests.AudioManualQaServer)
QA.Execute("play_sfx", { Label = "server-1" })
QA.Execute("create_point_marker")
QA.Execute("play_at_marker", { Label = "server-point-1" })
QA.Execute("create_attached_target")
QA.Execute("play_attached", { Label = "server-attached-1" })
QA.Execute("move_attached_target", { X = 10, YawDegrees = 90 })
QA.Execute("snapshot")
```

All playback options accepted by the production APIs can be supplied as
`VolumeMultiplier`, `PlaybackSpeedMultiplier`, and `TimePosition`. The harness
does not relax or rewrite their validation.

## Objective observations

Client snapshots contain:

- the exact three catalog pair/asset/resource/descriptor identity records;
- runtime identity/readiness and exact server/client playback roots;
- per-type pool active/available/created/reused/released counts and limits;
- `AudioPlayer` asset, ready/playing/looping/volume/speed values;
- exact `SpatialAnchor` direct-child inventory, Parent-mode emitter, point
  set-once transform, attached full-transform follow, registry/cleanup, and
  route target facts without playback `PositionType`/`PositionInstance` access;
- fader volumes and AudioSettings levels/enabled values;
- listener position/rotation deltas, acoustic flag, interaction group, and
  output binding;
- the public sticky
  `ContentPreloader:GetRequestResult("AudioCatalog.Preload.v1")` counts and
  exact failure `ContentId`/`Status` pairs when that service is already bound;
  an unbound side reports `ServiceNotBound`, and backend error text is never
  exposed;
- Music pool active leases, public handle activity, and observable
  `MusicPlayback` players. Structural LIFO behavior is concluded only from the
  commanded public handles plus those runtime artifacts and hearing evidence;
  the driver does not inspect private Music state.

Server snapshots contain the published graph generation/readiness, five-fader
and four-route topology, canonical acoustic property, server pool statistics,
server playback roots, handles, accepted non-looping one-shot labels, transient
target positions, and the same exact three live-asset identity records. A
successful non-looping server one-shot legitimately has no public handle; it
is reported under `AcceptedOneShots` and never receives a fake handle.

These values are runtime proxies, not proof that a sound was heard.

## Record and export results

After combining objective observations with the operator answer, record the
scenario on the server:

```lua
local QA = require(game.ServerScriptService.Tests.AudioManualQaServer)
QA.RecordScenario(
    "Studio-E2E-AUDIO-01/LocalOnly",
    "PASS",
    true,
    {
        Source = "OperatorStatement",
        Confirmed = true,
        Observation = "Client A heard one cue; Client B heard none.",
    },
    "Client A heard one cue; Client B heard none; server playback delta stayed zero."
)
```

For a non-auditory scenario, pass `nil` as the operator-evidence argument. For
an unavailable save backend or topology, record `BLOCKED` with a concrete
reason. A bare `HumanPassed=true` field is ignored by evaluation and cannot
complete a hearing-required record. Export the aggregate report with:

```lua
require(game.ServerScriptService.Tests.AudioManualQaServer).Export()
```

`Overall="PASS"` is possible only when all 16 scenario records are valid. Any
failed or malformed record yields `FAIL`; an otherwise failure-free run with a
blocked scenario yields `BLOCKED`; missing scenarios yield `PENDING`.

At the end, run cleanup in both clients and the server before stopping Play:

```lua
require(game.ReplicatedStorage.Shared.Tests.AudioManualQaClient).Cleanup()
require(game.ServerScriptService.Tests.AudioManualQaServer).Cleanup()
```

Capture the final report and all server/client output before stopping Play.

## Deterministic companion gate

The collaborative run is valid only alongside the exact-revision deterministic
gate:

```lua
require(game.ServerScriptService.Tests.AudioCatalogTestRunner).runAll()
require(game.ServerScriptService.Tests.AudioPlaybackTestRunner).runAll()
require(game.ServerScriptService.Tests.AudioIntegrationTestRunner).runAll()
require(game.ServerScriptService.Tests.AudioManualQaTestRunner).runAll()
require(game.ServerScriptService.Tests.AllTestsRunner).runAll()
```

`AudioManualQaTestRunner` validates the plan, all 79 acceptance mappings,
public-capability coverage, mandatory scenarios, report precedence, and the
rule that human evidence cannot be fabricated. It does not claim any sound was
heard.
