# Content preloading

## Purpose and boundary

`ContentPreloader` is the single application entry point for Roblox content
preloading. Domain modules and initialization commands do not call
`ContentProvider:PreloadAsync()` directly.

The module composes two existing responsibilities without absorbing either:

- `AssetRegistry` selects immutable authored templates by path, key, tag, and
  metadata;
- Roblox `ContentProvider` discovers and fetches content referenced by the
  selected Instances.

`ContentPreloader` owns named-request coordination, progress, immutable
results, and failure policy. It does not index Instances, clone templates, own
runtime objects, warm pools, reproduce Roblox content-property discovery, or
guarantee that server-side loading affects a client.

The implementation is side-neutral and receives all dependencies through its
constructor. The template currently constructs one client-owned instance:

```lua
local preloader = ContentPreloader.new({
	Assets = assetRegistry,
	ContentProvider = ContentProvider,
	Logger = logger,
})

services.ContentPreloader = preloader
```

A server may construct a separate instance only for a concrete server-local
need. It remains unrelated to every client instance.

## Public API

### Catalog query

```lua
local result = preloader:PreloadQuery({
	Under = "Client/UI",
	Attributes = {
		PreloadGroup = "Menu",
	},
}, {
	RequestId = "Menu",
	FailurePolicy = "Warn",
})
```

The query is evaluated by the initialized `AssetRegistry`. The preloader does
not scan Roblox roots again.

### Stable keys

```lua
preloader:PreloadByKeys({
	"ui.inventory",
	"effect.explosion",
}, {
	RequestId = "Inventory",
})
```

Unknown keys fail through the registry's required lookup contract.

### Explicit targets

```lua
preloader:Preload({
	imageLabel,
	"rbxassetid://123456",
}, {
	RequestId = "RoundIntro",
	FailurePolicy = "Fail",
})
```

Explicit targets are the controlled escape hatch for Instances outside the
static catalog and direct content IDs. The list accepts only Instances and
non-empty strings. Exact duplicate targets are removed while the order of the
remaining targets is preserved.

## Named requests and idempotence

`RequestId` is optional. A named request is single-flight and sticky:

- concurrent callers with the same target sequence and policy share one
  execution;
- a completed caller receives the same immutable result;
- reusing the ID with different targets or policy fails;
- a completed strict failure remains failed and is not retried implicitly.

Use a new request ID for an intentional retry. Anonymous requests execute on
every call.

The preloader relies on Roblox for low-level content caching. It does not
extract every mesh, texture, image, animation, or audio property into a second
project cache.

## Results, progress, and failures

Every successful or best-effort call returns:

```lua
{
	RequestId = "Menu",
	RequestedTargets = 4,
	RequestedCatalogPaths = {
		"Client/UI/Inventory",
	},
	ResolvedContent = 6,
	Loaded = 5,
	Failed = 1,
	Failures = {
		{
			ContentId = "rbxassetid://123456",
			Status = "Failure",
		},
	},
	DurationSeconds = 0.42,
}
```

`RequestedTargets` counts normalized input values. `ResolvedContent`, `Loaded`,
`Failed`, and `Progress` count distinct content IDs reported by Roblox. These
numbers are deliberately different because one Instance may contain zero,
one, or several content references.

`Progress` fires after each distinct content ID resolves.
`RequestCompleted` fires once with the final result. Result tables, failure
lists, and catalog path lists are immutable.

Both notifications use the shared side-local event lifecycle documented in
[Signal.md](Signal.md). An in-flight request fires its internal completion
signal before destroying it so concurrent `Wait` callers resume.

Failure policies:

- `Warn` records and logs failures, then returns the result;
- `Fail` records the result and raises after completion when any content item
  fails.

Roblox asset delivery failures normally arrive through the callback status.
An exception raised by an injected backend is recorded as request status
`Exception`.

## Startup selection

The client manifest runs:

```text
Assets → StartupContentPreload → Pooling → Players → ...
```

`StartupContentPreload` selects:

```lua
{
	Tags = { "Preload" },
}
```

and executes named request `Startup` with policy `Warn`.
`ClientInitialized` is not published until this request has finished, so the
existing loading screen remains visible during startup preloading. Delivery
failures are visible in logs but do not trap the player on the loading screen.

Only essential loading-screen, initial-menu, and spawn-area content should
receive the `Preload` tag. Load larger feature sets explicitly near first use.
Do not tag an entire catalog root or preload all of `Workspace`.

Tags and attributes select content; they do not establish initialization
ordering. The manifest command's explicit `DependsOn = { "Assets" }` owns that
ordering.

### TF-0005 audio startup request

The audio implementation inserts `AudioStartup` after `Assets` and makes the
existing `StartupContentPreloadCommand` depend on that normalized state. In
addition to request `Startup`, the same command executes exactly one sorted,
deduplicated request `AudioCatalog.Preload.v1` with `Warn`, derived only from
valid catalog/physical descriptors marked `Preload=true`. Invalid audio startup
skips the request and publishes its disabled boundary; it does not create a
second preloader or retry loop. See [AudioSystem.md](AudioSystem.md).

## Pooling

Preloading must finish before a domain module warms a pool whose template
references that content:

```text
AssetRegistry selection
  → ContentPreloader request
  → domain-owned pool construction
  → Warmup
```

`Pool`, `PoolAdapters`, and `PoolModule` remain synchronous and do not call the
preloader internally. The domain composition command owns the dependency.

## Verification

Run a Rojo validation build:

```powershell
rojo build default.project.json --output $env:TEMP\roblox-template-validation.rbxlx
```

Run in a fresh server Studio Play session:

```lua
require(game.ServerScriptService.Tests.ContentPreloaderTestRunner).runAll()
require(game.ServerScriptService.Tests.AssetRegistryTestRunner).runAll()
require(game.ServerScriptService.Tests.SystemTestRunner).runAll()
```

Every result must report `failed = 0`. After startup command or manifest
changes, inspect both client and server output in a clean Play session.
TF-0005 preload changes additionally require `AudioCatalogTestRunner`,
`AudioIntegrationTestRunner`, and the aggregate suite. The exact enabled
production-path fixture is `AudioCatalog/StartupPreloadSet` in
`ContentPreloaderTestRunner`; it proves the sorted unique
`PreloadContentIds`, request ID `AudioCatalog.Preload.v1`, `Warn` continuation,
and sticky reuse. Catalog-only tests do not substitute for that command-path
fixture.
