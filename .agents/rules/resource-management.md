# Resource management rules

## Scope

Apply to object pools, reusable runtime resources, pool adapters, leases,
resource cleanup, and server/client pooling registries.

Required context: `docs/ResourceManagement.md`, `docs/adr/README.md`, and every
relevant Accepted template and project ADR selected from the routed indexes.

## Mandatory rules

- Every pool MUST be homogeneous: one object type, one context type, and one
  lifecycle adapter.
- Every concrete pool MUST have one explicit domain owner that defines its
  adapter, budgets, lifetime, and public access contract.
- Server and client MUST own separate `PoolModule` instances composed through
  their explicit initialization manifests.
- Shared pooling code MUST remain side-neutral and MUST NOT access
  `ServerStorage`, `Workspace`, `PlayerGui`, or another side-owned container.
- Pooled values MUST have stable identity: `Instance`, table, or userdata.
  Primitive Luau values MUST NOT be accepted as pooled objects.
- Every pool MUST declare finite or explicitly unbounded `MaxRetained` and
  `MaxActive` budgets.
- Acquisition MUST return a generation lease. Delayed callbacks MUST release
  through that lease, never through a raw object reference.
- Adapter callbacks MUST be synchronous, non-yielding, and non-reentrant for
  their pool.
- `Release` MUST reset all mutable state that can leak into the next lease,
  including connections, physics, playback, particles, UI state, and parentage
  as applicable.
- `Release`/`OnRelease` MUST be safe immediately after `Create`, because
  `Warmup` normalizes newly created objects before retaining them.
- `Destroy` MUST tolerate partially acquired or partially released objects,
  because adapter failures are removed from circulation through destruction.
- `Clear` MUST preserve active leases and destroy only retained idle objects.
- Forced pool removal and module destruction MUST invalidate active leases and
  destroy every object owned by the affected pool.
- Adapter failures MUST invalidate or destroy the affected object rather than
  returning it to circulation.
- Pooling a server-owned object MUST NOT be described as eliminating
  replication spawn/despawn or instance-streaming behavior.

## Forbidden patterns

- MUST NOT create one heterogeneous global `Pool<Instance>`.
- MUST NOT treat `PoolModule:GetPool(id)` as type discovery or as a generic
  service locator. Pool IDs are side-local registry keys, not object types.
- MUST NOT release by looking up mutable metadata attached to a Roblox
  `Instance`.
- MUST NOT use `_G`, a module-level mutable singleton, or automatic discovery
  as the pool registry.
- MUST NOT hide yielding asset loading inside the synchronous pool algorithm.
- MUST NOT retain an unbounded idle cache by omission; `math.huge` must be an
  explicit project decision.
- MUST NOT make a shared adapter choose server- or client-owned containers.

## Adding a concrete pool

1. Choose the side that owns the resource and obtain its initialized
   `PoolModule` through explicit composition.
2. Choose the domain module that owns the concrete pool and expose a typed
   domain API or explicitly injected typed pool reference to consumers.
3. Define one adapter and one acquire-context type for the pooled object.
4. Set explicit active and retained budgets based on measured workload.
5. Use `PoolAdapters.fromInstanceFactory` for raw Roblox instances or
   `PoolAdapters.fromPoolable` for wrapper objects.
6. Warm the pool only after required assets are loaded.
7. Retain the returned lease until release and use `TryReleaseToPool` from
   delayed callbacks.
8. Add focused lifecycle, stale-lease, failure-cleanup, and budget tests.

## Verification

- Rojo build.
- `ResourceManagementTestRunner`.
- `SystemTestRunner` and clean server/client bootstrap when manifest
  composition changes.
- A clean Studio Play check for concrete pools that touch rendering, sound,
  physics, replication, or player UI.
