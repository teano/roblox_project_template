# Resource management

## Ownership

`PoolModule` is the registry and lifetime owner for object pools. The server
manifest and each client manifest construct and initialize separate registry
instances under `Services.Pooling`. The implementation class is shared through
`ReplicatedStorage`, but it has no module-level mutable state, so no pool or
lease crosses the server/client runtime boundary.

Concrete projects decide which side owns each pool:

- server pools: authoritative NPC controllers, physical pickups, and
  server-simulated projectiles;
- client pools: sounds, visual effects, damage numbers, HUD elements, and
  presentation-only projectiles.

A server pool can avoid repeated server-side cloning and controller setup, but
moving a server object out of and back into `Workspace` still participates in
normal replication and instance-streaming behavior.

## Concrete pool ownership and access

`PoolModule` is the technical lifetime owner of registered pools. One domain
module is the semantic owner of each concrete pool: it defines the adapter,
acquire-context type, budgets, reset contract, and the point at which the pool
is removed or destroyed.

Consumers should normally use a typed API exposed by that owner, or receive a
typed pool reference through explicit composition. `PoolModule:GetPool(id)` is
an escape hatch for side-local registry lookup; it does not discover a pool by
object type and does not preserve generic type information on its own. Multiple
pools may contain the same Roblox class while using different contexts and
reset behavior.

Pool IDs and objects are local to one runtime. The same ID on the server and on
two different clients identifies three unrelated pools. A server can send a
message that causes each client to acquire a local presentation object, but it
cannot acquire from or release to either client's pool.

## Layers

The pooling subsystem has three side-neutral layers:

1. `Pool<T, TContext>` owns one homogeneous collection and its safety state.
2. `PoolAdapters` translates an object-specific lifecycle into the generic
   `Create`, `Acquire`, `Release`, `Destroy`, and optional `IsValid` contract.
3. `PoolModule` registers named pools and provides per-pool or all-pool cleanup.

Raw Roblox instances use an instance adapter. Complex resources can implement
the structural `Poolable<TContext>` contract with `OnAcquire`, `OnRelease`,
`Destroy`, and optional `IsPoolableValid`.

The core accepts only values with stable identity: Roblox `Instance`, table, or
userdata. Primitive numbers, strings, and booleans are intentionally rejected;
pooling them provides no reusable object identity for lease validation.

## Lifecycle and state reset

The adapter is created once when the domain owner creates a concrete pool. A
consumer does not provide reset behavior on every acquisition.

The first acquisition follows this sequence:

```text
validate MaxActive
  → reuse a valid idle object, or call Create
  → assign a new generation and mark the object active
  → call Acquire(object, context)
  → return an immutable lease
```

Release validates the lease owner, object identity, and generation before it
touches the object:

```text
ReleaseToPool(lease)
  → call Release(object) to reset all per-use state
  → retain the idle object when below MaxRetained
  → otherwise call Destroy(object)
```

The generic pool cannot infer a clean state. The concrete `Release` or
`OnRelease` implementation must disconnect per-lease signals, stop asynchronous
work, reset physics/playback/particles/UI/controller fields, and remove
references to the previous context. The instance adapter moves the object to
`PoolParent` only after the object-specific release callback succeeds.

`Warmup` calls `Create` followed immediately by `Release` before retaining a
new object. Release callbacks must therefore be safe for a newly created object
that has never been acquired. `Destroy` must also tolerate partially acquired
or partially released state because the pool destroys an object after adapter
failure. If `Acquire` or `Release` raises, that object is never returned to the
idle collection.

## Lease safety

Acquisition returns an immutable lease:

```lua
local lease = soundPool:Acquire({
	Parent = workspace,
	Volume = 0.8,
})

lease.Object.Ended:Once(function()
	soundPool:TryReleaseToPool(lease)
end)
```

Every acquisition receives a new generation. A lease from a previous use,
another pool, a double release, or a destroyed pool is rejected without
touching the currently active object. `ReleaseToPool` raises on misuse;
`TryReleaseToPool` returns `false, reason` and is intended for delayed callbacks
that can legitimately become stale.

Adapter callbacks are synchronous by contract. They must not yield or call
back into the same pool. The pool guards re-entry and destroys an object after
a failed acquire or release instead of returning partially reset state to
circulation.

## Budgets and cleanup

Every pool declares both budgets explicitly:

- `MaxActive` caps simultaneous leases;
- `MaxRetained` caps idle objects retained for reuse.

When a valid release would exceed `MaxRetained`, the released object is
destroyed. `Warmup(targetAvailable)` ensures a target idle count without
exceeding the retained budget and is idempotent for an already-warm pool.

Cleanup has deliberately different strengths:

- `pool:Clear()`, `PoolModule:ClearPool(id)`, and
  `PoolModule:ClearAllPools()` destroy idle objects only;
- `PoolModule:RemovePool(id)`, `pool:Destroy()`, and
  `PoolModule:Destroy()` destroy both idle and active objects and invalidate
  every outstanding lease.

`Destroy` is idempotent. A destroyed pool rejects new acquisition.

## Public API summary

### `Pool<T, TContext>`

- `Acquire(context)` / `GetFromPoolOrCreate(context)` returns a new
  generation lease.
- `TryReleaseToPool(lease)` returns `false, reason` for stale or invalid
  release and is appropriate for delayed callbacks.
- `ReleaseToPool(lease)` raises when release is invalid.
- `IsLeaseActive(lease)` checks whether the exact generation remains active.
- `Warmup(targetAvailable)` creates and resets idle objects up to
  `MaxRetained`.
- `Clear()` destroys idle objects only and returns the number removed.
- `Destroy()` destroys idle and active objects and invalidates all leases.
- `GetStats()` returns frozen counters and current budget usage.

### `PoolModule`

- `CreatePool(id, adapter, options)` registers one homogeneous pool.
- `CreatePoolablePool(id, factory, options)` creates a pool through the
  structural Poolable adapter.
- `GetPool(id)` performs side-local ID lookup.
- `ClearPool(id)` and `ClearAllPools()` preserve active leases.
- `RemovePool(id)` and `Destroy()` force-destroy active and idle objects.

`ClearAllPools()` returns the number of pools cleared, not the number of
objects destroyed. Cleanup visits pools in sorted ID order and aggregates
errors so the failing pool is identified.

## Raw Roblox instance example

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local PoolAdapters = require(ReplicatedStorage.Shared.Pooling.PoolAdapters)

local pooling = services.Pooling
local assets = services.Assets
local template = assets:RequireByKey("enemy.slime.template", "Model")

local poolParent = Instance.new("Folder")
poolParent.Name = "EnemyPools"
poolParent.Parent = ServerStorage

type SpawnContext = {
	Parent: Instance,
	CFrame: CFrame,
}

local adapter = PoolAdapters.fromInstanceFactory(function(): Model
	return template:Clone()
end, {
	PoolParent = poolParent,
	Acquire = function(model: Model, context: SpawnContext)
		model:PivotTo(context.CFrame)
		model.Parent = context.Parent
	end,
	Release = function(model: Model)
		for _, descendant in model:GetDescendants() do
			if descendant:IsA("BasePart") then
				descendant.AssemblyLinearVelocity = Vector3.zero
				descendant.AssemblyAngularVelocity = Vector3.zero
			end
		end
	end,
})

local slimePool = pooling:CreatePool("Slime", adapter, {
	MaxActive = 40,
	MaxRetained = 20,
})
slimePool:Warmup(10)
```

`PoolParent` is assigned on creation and after the object-specific `Release`
callback. `Acquire` owns activation and active parentage. `AssetRegistry`
supplies the static template; the owning domain module still owns the runtime
pool container, adapter, budgets, and cleanup.

## Custom Poolable example

```lua
local effectPool = pooling:CreatePoolablePool("CoinBurst", function()
	return EffectController.new(effectTemplate:Clone(), clientPoolParent)
end, {
	MaxActive = 32,
	MaxRetained = 16,
})

local lease = effectPool:Acquire({
	CFrame = CFrame.new(0, 5, 0),
	EmitCount = 12,
})
```

`EffectController:OnRelease()` must disconnect per-lease signals, disable and
clear emitters, reset mutable state, and return its model to the client pool
container. Asset preloading belongs before `Warmup`; the core pool does not
provide an async acquire API.

## Verification

Run in a server Studio Play session:

```lua
require(game.ServerScriptService.Tests.ResourceManagementTestRunner).runAll()
require(game.ServerScriptService.Tests.SystemTestRunner).runAll()
```

Every result must report `failed = 0`.
