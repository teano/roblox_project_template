# Production test coverage

## Purpose

This document is the traceability matrix and release gate for the reusable
template. It records behavioral coverage, not a line-coverage percentage.
Production-ready means that critical contracts have positive, negative, and
boundary coverage; isolated tests are deterministic and failure-safe; and a
clean server/client bootstrap succeeds.

## Test contract

- Tests exercise public module contracts. Transport adapters may be injected,
  but private fields and private methods are not assertions.
- Every isolated test is run by `TestHarness` with a finite timeout.
- A test that creates a connection, controller, worker, lock, signal, or
  Instance registers cleanup with its scope. Cleanup runs after success,
  failure, and timeout, in reverse registration order.
- Time, waits, task spawning, randomness, storage, Roblox services, and
  communication transports are injected where they affect correctness.
- Fresh instances and fakes isolate tests. Suite order is stable and a test
  must not depend on state left by an earlier test.
- Intentional failure diagnostics are part of the assertion or the expected
  diagnostics below. Any other error or warning in server or client output is
  a release-gate failure.

## Contract-to-suite matrix

| Production contract | Positive coverage | Negative coverage | Boundary and concurrency coverage | Primary suite |
|---|---|---|---|---|
| Structured logging | severity routing, child context | hostile values and failing sinks | field and line caps, control characters | `LoggerTestRunner` |
| Object pools and leases | warmup, acquire/release, adapters | stale/foreign/double release, adapter failures | active/idle caps, re-entry, forced removal | `ResourceManagementTestRunner` |
| Immutable asset catalog | paths, keys, tags, metadata, typed lookup | duplicates, overlaps, invalid scopes and types | empty/dot/control path segments, key length | `AssetRegistryTestRunner` |
| Content preloading | catalog selectors, keys, raw IDs, caching | invalid IDs, keys, policies, backend failures | empty targets, duplicates, concurrent same-name request | `ContentPreloaderTestRunner` |
| Audio startup and catalog (TF-0005 gate) | protected module load, exact normalized config/catalog, paths, selection, plus the enabled production preload command | physical Sounds-root absence/class mismatch, registry query faults, invalid/non-positive rows, profiles/routing, duplicate keys, and preload backend failure | profile/path/ID boundaries, client/server config parity, sorted unique preload IDs, exact request identity, Warn continuation, sticky reuse, full-domain tiny/huge order and zero/smallest-positive selection, huge-equal exact midpoint, representable high-sample tiny tail, reversed catalog order, anti-repeat, and small-weight parity | `AudioCatalogTestRunner`, `ContentPreloaderTestRunner` |
| Audio graph, pools and playback (TF-0005 gate) | ordinary playback, fixed four-object `SpatialAnchor` composition, static Point, full-transform Attached through one side registry, native one-server-lease delivery, and all Music transition phases | target/readiness/transform loss, invalid regions/profiles, partial construction, unregister-first cleanup, stop/end during transitions and late frame/playback callbacks | FIFO hard capacity, LIFO rejection, exact object ceiling, one subscription per side, zero Point registration, generation authorization, phase mutations and StopAll | `AudioPlaybackTestRunner` |
| Audio integration and settings (TF-0005 gate) | exact client graph/listener lifecycle, hybrid prediction/fanout, real save-controller snapshot/patch/rollback paths | graph failure, every client preflight gate, Queue rejection, hook false/exception and malformed settings | atomic recipient enqueue rollback, exact pair reuse and two independent settings controllers | `AudioIntegrationTestRunner` |
| Collaborative Audio Studio QA (TF-0005 gate) | all public Audio capabilities and `PRD-AC-001..079` mapped to deterministic or collaborative evidence; exact live playback uses CartoonBubble, OldCarEngine, and PrayerRiver through production bootstrap services; public preload evidence uses exactly `AudioCatalog.Preload.v1` and exposes only counts plus failure `ContentId`/`Status` | wrong/missing exact catalog pair, asset ID, descriptor path/SoundId, unknown bridge request, bare human boolean, objective observation, or required operator statement cannot pass; `Bridge.Invoke` rejects unsafe caller data before transport; raw Bindable evidence proves cycles are engine-rejected, while Roblox strips metatable/frozen state, normalizes coroutines and mixed/sparse keys, copies tables, and does not execute `__iter`; every representable unsafe raw argument and every unsafe handler result rejects before handler dispatch; non-Studio and unavailable topology/backend stay closed/blocked | exact frozen client/server whitelists, side-local placement/schema, actual service-closure binding, raw and wrapped bidirectional deep-copy isolation, cleanup, exact CueId refs, accepted server one-shots without fake handles, explicit rejoin Start, exact `Studio-E2E-AUDIO-05` anchor, exact three-live-asset and 16-scenario identity, report precedence; lexer-aware repository validation independently enforces the formatting-tolerant post-success Studio-only require/install path, exact QA inventory, absence of executable remote structures, and no `.server`/`.client` Lua/Luau source in Tests/QA roots | `AudioManualQaTestRunner`, `scripts/validate-repository-layout.ps1`, plus [AudioManualQA.md](AudioManualQA.md) |
| Experience Config catalog | atomic decode, projection, refresh | missing/unknown/unsafe values, invalid refresh, mandatory Statistics identifier mismatch, impossible dedupe capacity | min/max values, NaN/infinity, oversized projection, accepted Wallet GUID and practical dedupe boundaries | `ConfigCatalogTestRunner` |
| Side-local signals | connect, once, wait, disconnect, destroy | listener throws and owner destruction | yielding listeners, nested dispatch, nil arguments | `SystemTestRunner` |
| Initialization manifests | dependency order, idempotence, catalog composition | missing dependency, duplicate/malformed/out-of-order commands | concurrent callers, sticky failure, non-cancelling watchdog | `SystemTestRunner` |
| Wallet and base provider rules | initial value and persisted reload | unknown currency, invalid amounts/balances, retained-close public mutation | zero no-op, safe-integer, NaN/fractional limits, normal Loaded admission, real Statistics preparation failure, rejected retained add/spend/no-op without signals/queue, and retry capture/order | `SystemTestRunner`, `StatisticsTestRunner`, `ProductionReadinessTestRunner`, `ProductionIntegrationTestRunner` |
| Statistics snapshots | built-in/custom lifecycle, formulas, both Wallet currencies, Teleport continuation, projected reads | malformed metadata/operations, malformed retention candidates, non-finite and overflow results, invalid lifecycle, rejected Wallet facts, mismatch, private-field and client-mutation rejection | omitted/allow-only/allow-all-except filters, retention 0/N and cross-generation newest-only reconciliation/persistence, exact rollback restart, accepted and failed Teleport source preservation with final facts, atomic byte failure, mandatory Wallet GUID identifier boundary, aggregate dedupe capacity, dedupe across every eligible built-in snapshot, common client fact/read rate policy, no per-operation storage writes, positive-cooldown rapid-close save coalescing, close capture, diagnostic classes/redaction, copy isolation | `StatisticsTestRunner`, `TeleportModuleTestRunner`, `ConfigCatalogTestRunner`, `SystemTestRunner`, `ProductionIntegrationTestRunner` |
| Save transaction | load/apply/run/save and revision updates | capture, set, run, persistence, rollback-cleanup, unsafe prepared document, prepared size-limit, cancelled-load release, terminal Stop, lock-release failure, close preparation/capture failure, every local/public save failure code, malformed truthy `Ok`, and close wait/save deadlines | complete reverse/forward ordering, pre-mutation persistence gate, concurrent save/close, every Saving/Capturing/Snapshotting/Applying success/failure yield boundary, request/generation-safe deadline withdrawal, exact retained-owner restoration behind refresh, retry-retained preparation/capture/save ownership with preserved save intent and mutation rejection, and save-before-Stop/Release terminal retry | `AudioIntegrationTestRunner`, `ProductionIntegrationTestRunner`, `ProductionReadinessTestRunner` |
| Client-authority patch | accepted provider update | server-authority, unknown, malformed, invalid, busy, closing, and terminally closed patch | lost acknowledgement retired by replacement snapshot, patch-first/close-second provider yield with captured mutation but no post-close acknowledgement, and close-first/patch-second rejection | `ProductionReadinessTestRunner`, `ProductionIntegrationTestRunner` |
| Storage and session locks | owner refresh/release, stale takeover, and bounded teleport handoff acquisition | contention exhaustion, cancellable handoff wait, negative/zero/fractional/NaN/infinite/string/over-cap handoff retry counts, corrupt document, lost ownership, close preparation/save failure, and concurrent close/refresh | minimum and maximum supported retry counts, final `UpdateAsync` transform, same-lock whole-operation retry classification, new-profile marker preservation across refresh, release, and abandoned takeover, exact expiry-boundary refresh, repeated `CloseFailed` refresh after Stop/Release failure, controller-owned departed-player discovery with empty live Players enumeration, controller+opaque-runtime three-attempt budgets, yielded third-attempt unregister/rebuild revocation, real Statistics retry/finalization/rejoin, authoritative loss, retry release, shutdown parity, and no post-release refresh | `ProductionIntegrationTestRunner`, `ProductionReadinessTestRunner` |
| Autosave and shutdown | due dirty save, bounded concurrent live/retained close | persistence/preparation failure, exact/expired deadline, removed-controller request rejection | pre-stop identity-deduplicated live plus departed retained target snapshot, one absolute preparation/capture/save/stop/release/retry/finalize deadline, retry inside worker concurrency, not-due/clean exclusion, stop during worker cycle, idle/pending controller unregistration and idempotent cleanup | `ProductionReadinessTestRunner`, `ProductionIntegrationTestRunner` |
| Migrations | complete skipped-version chain plus immediate load/save/reload checkpoint | invalid controller/checkpoint, missing legacy baseline, existing empty pre-checkpoint profile, invalid provider dictionary, post-transform lock loss/release failure, unsafe or oversized output, cyclic replacement | same-version order, raw legacy root reconstruction, synchronous checkpoint capture, registration/replacement isolation, immutable checkpoint, future-version exclusion, oversized empty transition | `ProductionReadinessTestRunner`, `SystemTestRunner` |
| Communication serialization | supported DTO and Roblox value shapes | malformed, cyclic, unsafe, oversized payloads | work/byte/depth caps and Vector3 batch preservation | `ProductionIntegrationTestRunner` |
| Communication flow control | queue, request, send, resync and recovery | invalid calls, throwing validators, packet loss, stale epoch | independent player buckets, byte pacing, burst/refill, backpressure | `ProductionIntegrationTestRunner` |
| Communication cleanup | normal stop and player removal | in-flight resync cancellation | sequence, epoch, queue and limiter reset | `ProductionIntegrationTestRunner` |
| Version provider | valid snapshot and actual upgrade | malformed semantic version and place version | equal/older version does not emit dirty | `ProductionReadinessTestRunner` |
| GameData client | ready, provider forwarding, lookup | timeout and duplicate provider | nil payload fields, destroy and singleton cleanup | `ProductionReadinessTestRunner` |
| Players lifecycle | existing/join/leave/character/lookup, stable public signal surface, bounded delivery | removed membership, acquisition failure, callback failure, stale/duplicate character events, terminal wait cancellation | existing character plus respawn, subscribe-enumerate races, reentrant initialization/stop, idempotent terminal cleanup | `ProductionReadinessTestRunner`, `SystemTestRunner` |
| Teleport lifecycle | external/continued arrival, public/reserved requests, client bootstrap/events, two-client transport including negative Studio simulated-player UserIds, exact two-place template policy, unpublished zero-identity inert bootstrap, explicit opt-in runtime validation pad and configured routing | untrusted envelope, invalid group/destination, synchronous/late/queue failure, zero/fractional presentation UserId rejection, private-field rejection, post-Stop delivery, unrecorded place in the template Experience, unpublished destination rejection, default-disabled validation, malformed/mismatched/metatable-bearing validation GameId/routes/tester allowlist, unknown validation-config fields, unauthorized touch | unique sessions, three-visit continuity, GameId-gated derived current-place-only policy, immutable yielding group success/failure, pre-return init-failure ordering and exception/removal/Stop/retry retirement, per-player partial failure, stale result correlation, validation-pad touch re-entry/removal/recreation/deterministic lowest-present tester selection/idempotent Stop, repeated cleanup, observable snapshot reconciliation for every lost lifecycle/presentation transition, negative-ID peer departure followed by handler-failure snapshot recovery, maximum configured player capacity, initial queue clearing, handler-failure and backpressure resync | `TeleportModuleTestRunner`, `ProductionIntegrationTestRunner` |
| Save registries | registered controller construction | duplicate/unknown/malformed registration, permanent terminal Stop failure, and stale object-form removal | single/mixed-bulk retry after failure, exact autosave/runtime/provider/signal/lock retention, successful lifecycle handoff, string-ID compatibility, same-ID replacement survival across server autosave/session-lock and client central dispatch, two simultaneous real-client pending routes, crossed/correct results, survivor removal, same-ID stale-result rejection, and independent server/client registries | `ProductionReadinessTestRunner` |

## Deterministic Studio gate

Start a fresh Studio Play session and run from the server:

```lua
require(game.ServerScriptService.Tests.AllTestsRunner).runAll()
```

`AllTestsRunner` invokes these suites in a fixed order:

1. `AudioCatalogTestRunner`
2. `AudioPlaybackTestRunner`
3. `AudioIntegrationTestRunner`
4. `AudioManualQaTestRunner`
5. `LoggerTestRunner`
6. `ResourceManagementTestRunner`
7. `AssetRegistryTestRunner`
8. `ContentPreloaderTestRunner`
9. `ConfigCatalogTestRunner`
10. `StatisticsTestRunner`
11. `TeleportModuleTestRunner`
12. `SystemTestRunner`
13. `ProductionIntegrationTestRunner`
14. `ProductionReadinessTestRunner`

`AllTestsRunner` registers `AudioCatalogTestRunner`, `AudioPlaybackTestRunner`,
and `AudioIntegrationTestRunner` before `AudioManualQaTestRunner` and the broad
suites. The manual-plan runner validates coverage/report contracts only; it
does not replace the two-client run in [AudioManualQA.md](AudioManualQA.md).
Registration is not passing evidence; focused, plan, aggregate, and
collaborative runs must succeed on the recorded exact source revision.

The exact `AudioCatalog/StartupPreloadSet` fixture remains in
`ContentPreloaderTestRunner`, because only that runner executes the real
`StartupContentPreloadCommand -> ContentPreloader -> ContentProvider` path. It
asserts ordered temporary unparented, non-playing `Sound` targets with exact
`SoundId` values, per-content callback accounting, actual destroyed state,
exceptional cleanup/rethrow, and one backend call across repeated command
initialization after the sticky result completes.

The aggregate and every suite must report `failed = 0`. Before release, also
run:

```powershell
rojo build default.project.json --output $env:TEMP\roblox-template-validation.rbxlx
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/validate-repository-layout.ps1
```

Then start one additional clean Play session without manually requiring test
modules. Verify the server and client bootstraps complete and the client
publishes `ClientInitialized=true`.

The layout validator also runs adversarial parser fixtures. Block comments,
comment-based token splicing, executable long/quoted strings, nested
reassignment, or return-field replacement cannot spoof the exact closed
default-disabled `TeleportValidationConfig`. Derived cloud identity is either
fully absent or a complete independent positive identity with a non-empty
duplicate-free `servePlaceIds` array; partial, scalar, duplicate, or
template-identity fixtures are rejected. Precision-losing fractional JSON
numbers above the exact IEEE-754 integer range, decimal/exponent numeric forms,
unsupported CLR numeric representations, and integers outside `1..2^53-1` are
rejected instead of being normalized into apparently valid place or Experience
IDs.

A clean or fresh Play session is a stop/start cycle inside the same explicitly
selected Studio instance when a matching project session is already open. A
published session must have exact nonzero project-recorded `game.PlaceId` and
`game.GameId`, matching `default.project.json` `placeId`/`gameId`, and an
allowing `servePlaceIds` entry before Play begins. If MCP cannot determine
whether a matching session exists, the gate is blocked: do not launch Studio
or reopen the place from incomplete connector data.

## Expected diagnostics during tests

The deterministic suites intentionally exercise error paths. Warnings or
errors are acceptable only when the owning test asserts the corresponding
behavior, including:

- an isolated signal listener failure;
- rejected malformed or rate-limited communication traffic;
- injected save, autosave, lock-refresh, lock-release, migration, and rollback
  failures;
- rejected invalid or oversized configuration, asset, preload, and serialized
  payloads;
- injected resync handler failures before a successful retry.
- asserted audio config/catalog/profile/graph failures, `AudioDisabled`,
  `HybridQueueRejected`, rate/fanout rejection, readiness/region/target loss,
  stale generations, Music capacity, AudioSettings envelope-hook
  false/exception, missing-provider/known-field reconciliation, and invalid
  present AudioSettings without mutation.

Diagnostic volume must remain bounded by the tested cooldown and deduplication
contracts. A diagnostic outside the currently executing negative test, an
unbounded repeat, a stack trace from an uncaught task, or any bootstrap
diagnostic is unexpected and fails the gate.

## Real DataStore gate

`RealDataStoreSmokeTest` is deliberately not part of `AllTestsRunner`. Run it
only in the dedicated published integration Experience described in
[IntegrationTesting.md](IntegrationTesting.md), with Studio API access enabled
and the non-production `PlayerData_IntegrationTests_v1` store. It passes only
when both `Ok = true` and `CleanupOk = true`. If the environment has not been
verified safe, record the smoke test as **not run**, never as passed.

## Release evidence

Record this evidence in the release task or pull request:

- source commit SHA and UTC timestamp;
- selected Studio instance, canonical place identity, stable
  `PlaceId`/`GameId` when published, and Rojo project identity;
- for the template multi-place gate, both exact PlaceIds, their shared GameId,
  the same session GUID across visits, and the supported terminal-failure recovery;
- for an enabled validation harness, the exact temporary config revision,
  tester allowlist, forward/return and rapid-repeat evidence, followed by a
  fresh-server check after restoring and publishing `Enabled=false`;
- Rojo build and repository-layout results;
- aggregate suite count, test count, passed count, and failed count;
- clean bootstrap result and server/client output inspection;
- for TF-0005, exact reviewed specification hash, all 79 acceptance identities,
  the exact CartoonBubble/OldCarEngine/PrayerRiver catalog and physical
  descriptor identity gate,
  and `Studio-E2E-AUDIO-01..05` multi-client graph/replication/settings/Music/
  canonical-acoustic observations, including the exported collaborative report
  described in [AudioManualQA.md](AudioManualQA.md);
- integration `PlaceId`/`GameId`, smoke result, and cleanup result when the
  real DataStore gate was authorized;
- every omitted check with its concrete reason.

The evidence applies only to the recorded source state. Any subsequent source
or test change invalidates the prior test counts and requires the relevant gate
to be rerun.
