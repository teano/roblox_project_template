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
| Experience Config catalog | atomic decode, projection, refresh | missing/unknown/unsafe values, invalid refresh | min/max values, NaN/infinity, oversized projection | `ConfigCatalogTestRunner` |
| Side-local signals | connect, once, wait, disconnect, destroy | listener throws and owner destruction | yielding listeners, nested dispatch, nil arguments | `SystemTestRunner` |
| Initialization manifests | dependency order, idempotence, catalog composition | missing dependency, duplicate/malformed/out-of-order commands | concurrent callers, sticky failure, non-cancelling watchdog | `SystemTestRunner` |
| Wallet and base provider rules | initial value and persisted reload | unknown currency, invalid amounts/balances | zero no-op, safe-integer, NaN/fractional limits | `SystemTestRunner`, `ProductionIntegrationTestRunner` |
| Save transaction | load/apply/run/save and revision updates | capture, set, run, persistence, rollback-cleanup, unsafe prepared document, prepared size-limit, and cancelled-load release failures | complete reverse/forward ordering, pre-mutation persistence gate, concurrent save/close, throwing release retry after cancellation | `ProductionIntegrationTestRunner`, `ProductionReadinessTestRunner` |
| Client-authority patch | accepted provider update | server-authority, unknown, malformed and invalid patch | lost acknowledgement retired by replacement snapshot | `ProductionReadinessTestRunner`, `ProductionIntegrationTestRunner` |
| Storage and session locks | owner refresh/release, stale takeover, and bounded teleport handoff acquisition | contention exhaustion, cancellable handoff wait, negative/zero/fractional/NaN/infinite/string/over-cap handoff retry counts, corrupt document, lost ownership | minimum and maximum supported retry counts, final `UpdateAsync` transform, same-lock whole-operation retry classification, new-profile marker preservation across refresh, release, and abandoned takeover, retry/deadline limits | `ProductionIntegrationTestRunner`, `ProductionReadinessTestRunner` |
| Autosave and shutdown | due dirty save, bounded concurrent close | persistence failure and expired deadline | not-due/clean exclusion, stop during worker cycle | `ProductionReadinessTestRunner`, `ProductionIntegrationTestRunner` |
| Migrations | complete skipped-version chain plus immediate load/save/reload checkpoint | invalid controller/checkpoint, missing legacy baseline, existing empty pre-checkpoint profile, invalid provider dictionary, post-transform lock loss/release failure, unsafe or oversized output, cyclic replacement | same-version order, raw legacy root reconstruction, synchronous checkpoint capture, registration/replacement isolation, immutable checkpoint, future-version exclusion, oversized empty transition | `ProductionReadinessTestRunner`, `SystemTestRunner` |
| Communication serialization | supported DTO and Roblox value shapes | malformed, cyclic, unsafe, oversized payloads | work/byte/depth caps and Vector3 batch preservation | `ProductionIntegrationTestRunner` |
| Communication flow control | queue, request, send, resync and recovery | invalid calls, throwing validators, packet loss, stale epoch | independent player buckets, byte pacing, burst/refill, backpressure | `ProductionIntegrationTestRunner` |
| Communication cleanup | normal stop and player removal | in-flight resync cancellation | sequence, epoch, queue and limiter reset | `ProductionIntegrationTestRunner` |
| Version provider | valid snapshot and actual upgrade | malformed semantic version and place version | equal/older version does not emit dirty | `ProductionReadinessTestRunner` |
| GameData client | ready, provider forwarding, lookup | timeout and duplicate provider | nil payload fields, destroy and singleton cleanup | `ProductionReadinessTestRunner` |
| Players lifecycle | existing/join/leave/character/lookup | removed membership and repeated cleanup | existing character plus respawn; idempotent stop | `ProductionReadinessTestRunner`, `SystemTestRunner` |
| Teleport lifecycle | external/continued arrival, public/reserved requests, client bootstrap/events, two-client transport, exact two-place template policy, unpublished zero-identity inert bootstrap, explicit opt-in runtime validation pad and configured routing | untrusted envelope, invalid group/destination, synchronous/late/queue failure, private-field rejection, post-Stop delivery, unrecorded place in the template Experience, unpublished destination rejection, default-disabled validation, malformed/mismatched/metatable-bearing validation GameId/routes/tester allowlist, unknown validation-config fields, unauthorized touch | unique sessions, three-visit continuity, GameId-gated derived current-place-only policy, immutable yielding group success/failure, pre-return init-failure ordering and exception/removal/Stop/retry retirement, per-player partial failure, stale result correlation, validation-pad touch re-entry/removal/recreation/deterministic lowest-present tester selection/idempotent Stop, repeated cleanup, observable snapshot reconciliation for every lost lifecycle/presentation transition, maximum configured player capacity, initial queue clearing, handler-failure and backpressure resync | `TeleportModuleTestRunner`, `ProductionIntegrationTestRunner` |
| Save registries | registered controller construction | duplicate/unknown/malformed registration | removal and independent server/client registries | `ProductionReadinessTestRunner` |

## Deterministic Studio gate

Start a fresh Studio Play session and run from the server:

```lua
require(game.ServerScriptService.Tests.AllTestsRunner).runAll()
```

`AllTestsRunner` invokes these suites in a fixed order:

1. `LoggerTestRunner`
2. `ResourceManagementTestRunner`
3. `AssetRegistryTestRunner`
4. `ContentPreloaderTestRunner`
5. `ConfigCatalogTestRunner`
6. `TeleportModuleTestRunner`
7. `SystemTestRunner`
8. `ProductionIntegrationTestRunner`
9. `ProductionReadinessTestRunner`

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
- integration `PlaceId`/`GameId`, smoke result, and cleanup result when the
  real DataStore gate was authorized;
- every omitted check with its concrete reason.

The evidence applies only to the recorded source state. Any subsequent source
or test change invalidates the prior test counts and requires the relevant gate
to be rerun.
