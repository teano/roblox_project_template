--!strict

local PoolTypes = require(script.Parent.PoolTypes)

type PoolAdapter<T, TContext> = PoolTypes.PoolAdapter<T, TContext>
type PoolOptions = PoolTypes.PoolOptions
type Lease<T> = PoolTypes.Lease<T>
type PoolType<T, TContext> = PoolTypes.Pool<T, TContext>

type InternalPool<T, TContext> = {
	_adapter: PoolAdapter<T, TContext>,
	_available: { T },
	_availableSet: { [any]: boolean },
	_active: { [any]: number },
	_activeCount: number,
	_maxRetained: number,
	_maxActive: number,
	_nextGeneration: number,
	_leaseOwner: {},
	_mutating: boolean,
	_destroyed: boolean,
	_createdCount: number,
	_reusedCount: number,
	_destroyedCount: number,
	_acquiredCount: number,
	_releasedCount: number,
}

local Pool = {}
Pool.__index = Pool

local function validateLimit(value: number, name: string): number
	assert(typeof(value) == "number", `{name} must be declared`)
	assert(
		value == math.huge or (value >= 0 and value % 1 == 0),
		`{name} must be a non-negative integer or math.huge`
	)
	return value
end

local function assertIdentityObject(object: any)
	local objectType = typeof(object)
	assert(
		objectType == "Instance" or objectType == "table" or objectType == "userdata",
		`Pool objects must have stable identity; received {objectType}`
	)
end

local function beginMutation(self: any)
	assert(not self._destroyed, "Pool is destroyed")
	assert(not self._mutating, "Pool adapter callbacks must not yield or re-enter the same pool")
	self._mutating = true
end

local function destroyObject(self: any, object: any): (boolean, string?)
	local ok, destroyError = xpcall(function()
		self._adapter.Destroy(object)
	end, debug.traceback)
	if ok then
		self._destroyedCount += 1
		return true, nil
	end
	return false, tostring(destroyError)
end

local function isObjectValid(self: any, object: any): (boolean, string?)
	if self._adapter.IsValid == nil then
		return true, nil
	end

	local ok, validOrError = xpcall(function()
		return self._adapter.IsValid(object)
	end, debug.traceback)
	if not ok then
		return false, tostring(validOrError)
	end
	return validOrError == true, nil
end

local function aggregateErrors(prefix: string, errors: { string }): string
	return `{prefix}:\n{table.concat(errors, "\n")}`
end

function Pool.new<T, TContext>(
	adapter: PoolAdapter<T, TContext>,
	options: PoolOptions
): PoolType<T, TContext>
	assert(typeof(adapter) == "table", "Pool adapter must be a table")
	assert(typeof(adapter.Create) == "function", "Pool adapter.Create must be a function")
	assert(typeof(adapter.Acquire) == "function", "Pool adapter.Acquire must be a function")
	assert(typeof(adapter.Release) == "function", "Pool adapter.Release must be a function")
	assert(typeof(adapter.Destroy) == "function", "Pool adapter.Destroy must be a function")
	assert(adapter.IsValid == nil or typeof(adapter.IsValid) == "function", "Pool adapter.IsValid must be a function")

	assert(typeof(options) == "table", "Pool options must declare MaxRetained and MaxActive")
	local self: InternalPool<T, TContext> = {
		_adapter = adapter,
		_available = {},
		_availableSet = {},
		_active = {},
		_activeCount = 0,
		_maxRetained = validateLimit(options.MaxRetained, "MaxRetained"),
		_maxActive = validateLimit(options.MaxActive, "MaxActive"),
		_nextGeneration = 0,
		_leaseOwner = {},
		_mutating = false,
		_destroyed = false,
		_createdCount = 0,
		_reusedCount = 0,
		_destroyedCount = 0,
		_acquiredCount = 0,
		_releasedCount = 0,
	}
	return setmetatable(self, Pool) :: any
end

function Pool.Acquire<T, TContext>(self: InternalPool<T, TContext>, context: TContext): Lease<T>
	beginMutation(self)

	if self._activeCount >= self._maxActive then
		self._mutating = false
		error("Pool MaxActive limit reached", 2)
	end

	local object: T? = nil
	while #self._available > 0 do
		local candidate = table.remove(self._available) :: T
		self._availableSet[candidate :: any] = nil

		local valid, validationError = isObjectValid(self, candidate)
		if validationError ~= nil then
			local _, destroyError = destroyObject(self, candidate)
			self._mutating = false
			local suffix = if destroyError then `; cleanup failed: {destroyError}` else ""
			error(`Pool adapter.IsValid failed: {validationError}{suffix}`, 2)
		end
		if valid then
			object = candidate
			self._reusedCount += 1
			break
		end

		local destroyed, destroyError = destroyObject(self, candidate)
		if not destroyed then
			self._mutating = false
			error(`Invalid pooled object cleanup failed: {destroyError}`, 2)
		end
	end

	if object == nil then
		local created, objectOrError = xpcall(function()
			return self._adapter.Create()
		end, debug.traceback)
		if not created then
			self._mutating = false
			error(`Pool adapter.Create failed: {tostring(objectOrError)}`, 2)
		end

		object = objectOrError :: T
		local identityOk, identityError = pcall(assertIdentityObject, object)
		if not identityOk then
			self._mutating = false
			error(tostring(identityError), 2)
		end
		if self._active[object :: any] ~= nil or self._availableSet[object :: any] then
			self._mutating = false
			error("Pool adapter.Create returned an object already owned by this pool", 2)
		end

		local valid, validationError = isObjectValid(self, object)
		if validationError ~= nil or not valid then
			local _, destroyError = destroyObject(self, object)
			self._mutating = false
			local reason = validationError or "adapter rejected the new object"
			local suffix = if destroyError then `; cleanup failed: {destroyError}` else ""
			error(`Pool created an invalid object: {reason}{suffix}`, 2)
		end
		self._createdCount += 1
	end

	self._nextGeneration += 1
	local generation = self._nextGeneration
	self._active[object :: any] = generation
	self._activeCount += 1

	local acquired, acquireError = xpcall(function()
		self._adapter.Acquire(object :: T, context)
	end, debug.traceback)
	if not acquired then
		self._active[object :: any] = nil
		self._activeCount -= 1
		local _, destroyError = destroyObject(self, object)
		self._mutating = false
		local suffix = if destroyError then `; cleanup failed: {destroyError}` else ""
		error(`Pool adapter.Acquire failed: {tostring(acquireError)}{suffix}`, 2)
	end

	self._acquiredCount += 1
	self._mutating = false
	return table.freeze({
		Object = object :: T,
		Generation = generation,
		_owner = self._leaseOwner,
	}) :: any
end

function Pool.GetFromPoolOrCreate<T, TContext>(
	self: InternalPool<T, TContext>,
	context: TContext
): Lease<T>
	return Pool.Acquire(self, context)
end

local function validateLease(self: any, lease: any): (boolean, string?)
	if typeof(lease) ~= "table" then
		return false, "Lease must be a lease returned by this pool"
	end
	if lease._owner ~= self._leaseOwner then
		return false, "Lease belongs to another pool"
	end
	local objectType = typeof(lease.Object)
	if objectType ~= "Instance" and objectType ~= "table" and objectType ~= "userdata" then
		return false, "Lease contains an invalid object"
	end
	if typeof(lease.Generation) ~= "number" then
		return false, "Lease contains an invalid generation"
	end
	if self._active[lease.Object] ~= lease.Generation then
		return false, "Lease is stale or already released"
	end
	return true, nil
end

function Pool.IsLeaseActive<T, TContext>(self: InternalPool<T, TContext>, lease: Lease<T>): boolean
	if self._destroyed then
		return false
	end
	local valid = validateLease(self, lease)
	return valid
end

function Pool.TryReleaseToPool<T, TContext>(
	self: InternalPool<T, TContext>,
	lease: Lease<T>
): (boolean, string?)
	if self._destroyed then
		return false, "Pool is destroyed"
	end
	if self._mutating then
		return false, "Pool adapter callbacks must not yield or re-enter the same pool"
	end

	self._mutating = true
	local valid, leaseError = validateLease(self, lease)
	if not valid then
		self._mutating = false
		return false, leaseError
	end

	local object = (lease :: any).Object :: T
	local released, releaseError = xpcall(function()
		self._adapter.Release(object)
	end, debug.traceback)

	self._active[object :: any] = nil
	self._activeCount -= 1
	if not released then
		local _, destroyError = destroyObject(self, object)
		self._mutating = false
		local suffix = if destroyError then `; cleanup failed: {destroyError}` else ""
		return false, `Pool adapter.Release failed: {tostring(releaseError)}{suffix}`
	end

	self._releasedCount += 1
	if #self._available < self._maxRetained then
		self._availableSet[object :: any] = true
		table.insert(self._available, object)
	else
		local destroyed, destroyError = destroyObject(self, object)
		if not destroyed then
			self._mutating = false
			return false, `Pool overflow cleanup failed: {destroyError}`
		end
	end

	self._mutating = false
	return true, nil
end

function Pool.ReleaseToPool<T, TContext>(self: InternalPool<T, TContext>, lease: Lease<T>): boolean
	local released, releaseError = Pool.TryReleaseToPool(self, lease)
	if not released then
		error(releaseError, 2)
	end
	return true
end

function Pool.Warmup<T, TContext>(self: InternalPool<T, TContext>, targetAvailable: number): number
	assert(
		targetAvailable >= 0 and targetAvailable % 1 == 0,
		"Warmup targetAvailable must be a non-negative integer"
	)
	beginMutation(self)

	local target = math.min(targetAvailable, self._maxRetained)
	local createdCount = 0
	while #self._available < target do
		local created, objectOrError = xpcall(function()
			return self._adapter.Create()
		end, debug.traceback)
		if not created then
			self._mutating = false
			error(`Pool adapter.Create failed during warmup: {tostring(objectOrError)}`, 2)
		end

		local object = objectOrError :: T
		local identityOk, identityError = pcall(assertIdentityObject, object)
		if not identityOk then
			self._mutating = false
			error(tostring(identityError), 2)
		end
		if self._active[object :: any] ~= nil or self._availableSet[object :: any] then
			self._mutating = false
			error("Pool adapter.Create returned an object already owned by this pool", 2)
		end

		local valid, validationError = isObjectValid(self, object)
		if validationError ~= nil or not valid then
			local _, destroyError = destroyObject(self, object)
			self._mutating = false
			local reason = validationError or "adapter rejected the new object"
			local suffix = if destroyError then `; cleanup failed: {destroyError}` else ""
			error(`Pool created an invalid object during warmup: {reason}{suffix}`, 2)
		end

		local released, releaseError = xpcall(function()
			self._adapter.Release(object)
		end, debug.traceback)
		if not released then
			local _, destroyError = destroyObject(self, object)
			self._mutating = false
			local suffix = if destroyError then `; cleanup failed: {destroyError}` else ""
			error(`Pool adapter.Release failed during warmup: {tostring(releaseError)}{suffix}`, 2)
		end

		self._createdCount += 1
		self._availableSet[object :: any] = true
		table.insert(self._available, object)
		createdCount += 1
	end

	self._mutating = false
	return createdCount
end

function Pool.Clear<T, TContext>(self: InternalPool<T, TContext>): number
	if self._destroyed then
		return 0
	end
	beginMutation(self)

	local available = self._available
	self._available = {}
	table.clear(self._availableSet)

	local errors = {}
	for _, object in available do
		local destroyed, destroyError = destroyObject(self, object)
		if not destroyed then
			table.insert(errors, tostring(destroyError))
		end
	end

	self._mutating = false
	if #errors > 0 then
		error(aggregateErrors("Pool clear failed", errors), 2)
	end
	return #available
end

function Pool.Destroy<T, TContext>(self: InternalPool<T, TContext>)
	if self._destroyed then
		return
	end
	assert(not self._mutating, "Pool adapter callbacks must not yield or re-enter the same pool")

	self._mutating = true
	self._destroyed = true
	local objects = self._available
	for object in self._active do
		table.insert(objects, object :: T)
	end
	self._available = {}
	table.clear(self._availableSet)
	table.clear(self._active)
	self._activeCount = 0

	local errors = {}
	for _, object in objects do
		local destroyed, destroyError = destroyObject(self, object)
		if not destroyed then
			table.insert(errors, tostring(destroyError))
		end
	end

	self._mutating = false
	if #errors > 0 then
		error(aggregateErrors("Pool destroy failed", errors), 2)
	end
end

function Pool.GetStats<T, TContext>(self: InternalPool<T, TContext>)
	return table.freeze({
		Available = #self._available,
		Active = self._activeCount,
		MaxRetained = self._maxRetained,
		MaxActive = self._maxActive,
		Created = self._createdCount,
		Reused = self._reusedCount,
		Destroyed = self._destroyedCount,
		Acquired = self._acquiredCount,
		Released = self._releasedCount,
		IsDestroyed = self._destroyed,
	})
end

return Pool
