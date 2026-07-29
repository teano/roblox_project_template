# Content preloading rules

## Scope

Apply to `ContentPreloader`, `ContentProvider`, `PreloadAsync`, preload tags and
groups, startup loading progress, or content loading before pool warmup.

Required context: `docs/ContentPreloading.md`, `docs/AssetRegistry.md`,
`docs/InitializationAndSaveSystem.md`, `docs/adr/README.md`, and every relevant
Accepted template and project ADR selected from the routed indexes.

## Ownership

- Application code MUST route content preloading through `ContentPreloader`.
- `ContentProvider:PreloadAsync()` MUST remain an injected implementation
  detail of `ContentPreloader`; production consumers MUST NOT call it directly.
- `ContentPreloader` MUST receive `AssetRegistry`, the content-provider
  backend, and optional logging through constructor injection.
- The shared implementation MUST remain side-neutral and MUST NOT own
  module-level mutable state.
- A runtime that needs preloading MUST own its own preloader instance.
- Creating a server instance MUST be justified by server-local content needs;
  server preloading MUST NOT be treated as preloading content for clients.

## Selection and startup

- Catalog-backed selection MUST use the immutable initialized
  `AssetRegistry`; the preloader MUST NOT rescan roots or runtime hierarchies.
- The client startup request MUST select every catalog asset with tag
  `Preload`.
- `StartupContentPreload` MUST run after `Assets` and before
  `ClientInitialized` is published.
- Startup preloading is best-effort: content delivery failures MUST be
  reported but MUST NOT fail client bootstrap.
- A caller MAY use `FailurePolicy = "Fail"` when its own feature cannot safely
  continue without every requested content item.
- Only essential startup content SHOULD receive the `Preload` tag.
  Deferred UI, effects, locations, and other domain content SHOULD be loaded
  explicitly near their first use.
- Pool warmup that depends on authored content MUST occur after the owning
  preload request completes.

## Request contract

- Named requests MUST use a non-empty stable `RequestId`.
- Repeated or concurrent calls with the same `RequestId`, target sequence, and
  failure policy MUST share one result.
- Reusing a `RequestId` with different targets or failure policy MUST fail.
- A completed named failure MUST remain sticky; retry requires a new
  `RequestId`.
- Anonymous requests MAY execute each time.
- Duplicate targets in one request MUST be removed without reordering the
  remaining targets.
- Results, failures, and catalog-path lists MUST be immutable.
- Progress MUST count resolved content IDs, not input Instances. One Instance
  can reference zero, one, or many content IDs.

## Forbidden patterns

- MUST NOT add yielding work to `AssetRegistry:Initialize`, catalog lookup, or
  pool adapters.
- MUST NOT preload an entire service, `Workspace`, asset root, or complete
  catalog by default.
- MUST NOT infer module startup order from asset folders, tags, or preload
  groups.
- MUST NOT duplicate Roblox content-property discovery by maintaining a
  project list of mesh, texture, audio, animation, or image properties.
- MUST NOT use `ContentProvider.RequestQueueSize` as completion or progress.
- MUST NOT silently retry a completed named request.

## Verification

- Rojo build to a temporary output path.
- `ContentPreloaderTestRunner`.
- `AssetRegistryTestRunner`.
- `SystemTestRunner`.
- Clean client/server Play output after manifest or startup-selection changes.
- `scripts/validate-repository-layout.ps1` after rule or ADR changes.
