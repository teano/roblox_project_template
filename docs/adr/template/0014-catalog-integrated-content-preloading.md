# ADR-0014: Route content preloading through a catalog-integrated module

- Status: Accepted
- Date: 2026-07-29
- Deciders: Project maintainers
- Supersedes: None
- Superseded by: None

## Context

Roblox provides `ContentProvider:PreloadAsync()`, while the template provides
side-owned immutable `AssetRegistry` catalogs. Calling the engine service
directly from initialization and domain modules would distribute selection,
progress, error policy, and request coordination across the codebase.

Putting yielding loading inside `AssetRegistry` would mix immutable synchronous
catalog construction with external content delivery. Automatically preloading
the complete catalog would also increase startup latency and memory use for
content that may not be needed.

The project needs one application contract that can preload catalog selections
and explicit non-catalog targets while retaining the engine as the actual
content loader.

## Decision

Use the side-neutral `ContentPreloader` as the only production entry point for
content preloading. Inject `AssetRegistry`, the Roblox content-provider
backend, and logging through its constructor. Direct
`ContentProvider:PreloadAsync()` calls remain confined to this adapter.

Expose catalog query, stable-key, and explicit-target requests. Pass Instances
and content IDs to Roblox instead of reproducing the engine's content-property
discovery.

Named requests are single-flight and sticky. The same ID, ordered normalized
targets, and failure policy share one immutable result; incompatible reuse
fails. Anonymous requests execute each time. Progress and result counts refer
to distinct resolved content IDs, not input Instance count.

Support `Warn` and `Fail` policies. `Warn` returns a report after delivery
failures; `Fail` records the report and raises. Retries require a new request
ID.

Construct a client-owned instance in the client manifest. After the `Assets`
command, run `StartupContentPreload`, selecting every catalog entry tagged
`Preload`. The request is best-effort and completes before `ClientInitialized`.
A server instance is added only for a justified server-local need and never
represents client preloading.

## Alternatives considered

### Let every module call ContentProvider directly

Rejected because request identity, failure policy, progress, catalog selection,
and diagnostics would become inconsistent and difficult to test.

### Add Preload methods to AssetRegistry

Rejected because catalog initialization and lookup are synchronous immutable
operations, while content delivery yields and can fail for external reasons.

### Preload every catalog entry automatically

Rejected because catalog membership means addressability, not startup
criticality. Loading all content increases join time and memory pressure.

### Maintain a project list of every content-bearing property

Rejected because it would duplicate engine behavior and drift as Roblox adds
content types and properties.

## Consequences

### Positive

- Production preloading has one injected, testable entry point.
- Catalog tags, metadata, keys, and queries select authored preload sets.
- Startup readiness, progress, failures, and repeated requests have explicit
  contracts.
- Pool warmup and domain loading can depend on named preload requests.
- The engine continues to own content-property discovery and low-level cache.

### Negative

- Domain modules must depend on `ContentPreloader` instead of using the Roblox
  service directly.
- Named request IDs and preload groups become reviewed public contracts.
- Startup content delivery adds to client initialization time.
- Best-effort startup can still show fallback or missing content after a
  delivery failure.

## Enforcement

- Agent rules: `.agents/rules/content-preloading.md`,
  `.agents/rules/assets.md`, `.agents/rules/initialization.md`, and
  `.agents/rules/testing.md`.
- Current documentation: `docs/ContentPreloading.md`,
  `docs/AssetRegistry.md`, `docs/InitializationAndSaveSystem.md`, and
  `docs/ResourceManagement.md`.
- Code boundaries: `Shared/ContentPreloading/ContentPreloader`,
  `Shared/ContentPreloading/ContentPreloadTypes`,
  `Client/Initialization/Commands/StartupContentPreloadCommand`, and
  `Client/Initialization/ClientManifest`.
- Tests: `ContentPreloaderTestRunner`, `AssetRegistryTestRunner`,
  `SystemTestRunner`, repository layout validation, Rojo build, and clean
  client/server bootstrap.
