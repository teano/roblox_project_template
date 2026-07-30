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
| Save transaction | load/apply/run/save and revision updates | capture, set, run, persistence, rollback-cleanup failures | complete reverse/forward ordering, concurrent save/close | `ProductionIntegrationTestRunner`, `ProductionReadinessTestRunner` |
| Client-authority patch | accepted provider update | server-authority, unknown, malformed and invalid patch | lost acknowledgement retired by replacement snapshot | `ProductionReadinessTestRunner`, `ProductionIntegrationTestRunner` |
| Storage and session locks | owner refresh/release and stale takeover | contention, corrupt document, lost ownership | final `UpdateAsync` transform, retry/deadline limits | `ProductionIntegrationTestRunner`, `ProductionReadinessTestRunner` |
| Autosave and shutdown | due dirty save, bounded concurrent close | persistence failure and expired deadline | not-due/clean exclusion, stop during worker cycle | `ProductionReadinessTestRunner`, `ProductionIntegrationTestRunner` |
| Migrations | ordered applicable chain | invalid controller/source and migration failure isolation | same-version order and future-version exclusion | `ProductionReadinessTestRunner`, `SystemTestRunner` |
| Communication serialization | supported DTO and Roblox value shapes | malformed, cyclic, unsafe, oversized payloads | work/byte/depth caps and Vector3 batch preservation | `ProductionIntegrationTestRunner` |
| Communication flow control | queue, request, send, resync and recovery | invalid calls, throwing validators, packet loss, stale epoch | independent player buckets, byte pacing, burst/refill, backpressure | `ProductionIntegrationTestRunner` |
| Communication cleanup | normal stop and player removal | in-flight resync cancellation | sequence, epoch, queue and limiter reset | `ProductionIntegrationTestRunner` |
| Version provider | valid snapshot and actual upgrade | malformed semantic version and place version | equal/older version does not emit dirty | `ProductionReadinessTestRunner` |
| GameData client | ready, provider forwarding, lookup | timeout and duplicate provider | nil payload fields, destroy and singleton cleanup | `ProductionReadinessTestRunner` |
| Players lifecycle | existing/join/leave/character/lookup | removed membership and repeated cleanup | existing character plus respawn; idempotent stop | `ProductionReadinessTestRunner`, `SystemTestRunner` |
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
6. `SystemTestRunner`
7. `ProductionIntegrationTestRunner`
8. `ProductionReadinessTestRunner`

The aggregate and every suite must report `failed = 0`. Before release, also
run:

```powershell
rojo build default.project.json --output $env:TEMP\roblox-template-validation.rbxlx
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/validate-repository-layout.ps1
```

Then start one additional clean Play session without manually requiring test
modules. Verify the server and client bootstraps complete and the client
publishes `ClientInitialized=true`.

A clean or fresh Play session is a stop/start cycle inside the same explicitly
selected Studio instance when a matching project session is already open. If
MCP cannot determine whether a matching session exists, the gate is blocked:
do not launch Studio or reopen the place from incomplete connector data.

## Expected diagnostics during tests

The deterministic suites intentionally exercise error paths. Warnings or
errors are acceptable only when the owning test asserts the corresponding
behavior, including:

- an isolated signal listener failure;
- rejected malformed or rate-limited communication traffic;
- injected save, autosave, lock-refresh, migration, and rollback failures;
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
- Rojo build and repository-layout results;
- aggregate suite count, test count, passed count, and failed count;
- clean bootstrap result and server/client output inspection;
- integration `PlaceId`/`GameId`, smoke result, and cleanup result when the
  real DataStore gate was authorized;
- every omitted check with its concrete reason.

The evidence applies only to the recorded source state. Any subsequent source
or test change invalidates the prior test counts and requires the relevant gate
to be rerun.
