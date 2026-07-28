# ADR-0007: Use side-owned generation-safe object pools

- Status: Accepted
- Date: 2026-07-28
- Deciders: Project maintainers
- Supersedes: None
- Superseded by: None

## Context

Projects built from the template need reusable pools for raw Roblox instances
and custom controller objects. Pooling is useful on both the server and the
client, but those runtimes have different authority, containers, and resource
lifetimes. A single heterogeneous global pool would hide those boundaries.

Delayed events such as `Sound.Ended`, animation completion, or effect timers
can also outlive one use of an object. Releasing by raw object identity allows
an old callback to release a newer use of the same object. Unbounded idle
caches and ambiguous cleanup create additional memory and lifecycle risks.

## Decision

Use one shared, side-neutral `Pool<T, TContext>` algorithm and construct
separate `PoolModule` registries in the explicit server and client manifests.
Every concrete pool is homogeneous and delegates object-specific behavior to a
synchronous lifecycle adapter.

Acquisition returns an immutable generation lease. Release validates the pool,
object, and generation. Projects use an instance adapter for raw Roblox
instances and the structural `Poolable<TContext>` contract for custom wrapper
objects.

Every pool declares `MaxActive` and `MaxRetained`. Clear operations destroy
idle objects while preserving active leases. Forced removal and destruction
destroy all owned objects and invalidate outstanding leases.

## Alternatives considered

### One global heterogeneous Instance pool

Rejected because sounds, models, UI, particles, and controller wrappers need
different activation and reset rules. It also obscures server/client
ownership.

### Release by object identity or attached metadata

Rejected because identity alone cannot distinguish consecutive uses of the
same object, and Roblox instances cannot implement arbitrary Luau methods.
Attached metadata does not protect delayed callbacks from stale release.

### Separate core algorithms for server and client

Rejected because collection, budget, lease, and failure behavior are
side-neutral. Only concrete adapters, containers, authority, and composition
differ.

### Async acquire in the core pool

Rejected because reuse, `Instance.new`, and `Clone` are synchronous. Asset
loading and yielding construction belong in an explicit preload/provider phase
before warmup.

## Consequences

### Positive

- Server and clients have isolated ownership with one tested core algorithm.
- Stale, duplicate, and cross-pool releases cannot affect a current lease.
- Budgets and cleanup behavior are explicit.
- Raw instances and custom controllers share the same registry contract.
- Adapter failures remove unsafe objects from circulation.

### Negative

- Callers retain a lease in addition to the pooled object.
- Every concrete type still needs lifecycle reset code.
- Adapter callbacks cannot yield or re-enter their pool.
- Forced cleanup can invalidate active gameplay references and must be used
  only when that lifetime is intentionally ending.

## Enforcement

- Agent rules: `.agents/rules/resource-management.md`,
  `.agents/rules/architecture.md`, and `.agents/rules/initialization.md`.
- Current documentation: `docs/ResourceManagement.md` and
  `docs/InitializationAndSaveSystem.md`.
- Code boundaries: `Shared/Pooling/Pool`, `Shared/Pooling/PoolAdapters`,
  `Shared/Pooling/PoolModule`, and the two initialization manifests.
- Tests: `ResourceManagementTestRunner`, `SystemTestRunner`, and clean
  server/client bootstrap verification.
