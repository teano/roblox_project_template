--!strict

export type PoolAdapter<T, TContext> = {
	Create: () -> T,
	Acquire: (object: T, context: TContext) -> (),
	Release: (object: T) -> (),
	Destroy: (object: T) -> (),
	IsValid: ((object: T) -> boolean)?,
}

export type Poolable<TContext> = {
	OnAcquire: (self: any, context: TContext) -> (),
	OnRelease: (self: any) -> (),
	Destroy: (self: any) -> (),
	IsPoolableValid: ((self: any) -> boolean)?,
}

export type Lease<T> = {
	Object: T,
	Generation: number,
}

export type PoolOptions = {
	MaxRetained: number,
	MaxActive: number,
}

export type PoolStats = {
	Available: number,
	Active: number,
	MaxRetained: number,
	MaxActive: number,
	Created: number,
	Reused: number,
	Destroyed: number,
	Acquired: number,
	Released: number,
	IsDestroyed: boolean,
}

export type Pool<T, TContext> = {
	Acquire: (self: Pool<T, TContext>, context: TContext) -> Lease<T>,
	GetFromPoolOrCreate: (self: Pool<T, TContext>, context: TContext) -> Lease<T>,
	ReleaseToPool: (self: Pool<T, TContext>, lease: Lease<T>) -> boolean,
	TryReleaseToPool: (self: Pool<T, TContext>, lease: Lease<T>) -> (boolean, string?),
	IsLeaseActive: (self: Pool<T, TContext>, lease: Lease<T>) -> boolean,
	Warmup: (self: Pool<T, TContext>, targetAvailable: number) -> number,
	Clear: (self: Pool<T, TContext>) -> number,
	Destroy: (self: Pool<T, TContext>) -> (),
	GetStats: (self: Pool<T, TContext>) -> PoolStats,
}

return {}
