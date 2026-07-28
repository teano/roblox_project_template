--!strict

local Pool = require(script.Parent.Pool)
local PoolAdapters = require(script.Parent.PoolAdapters)
local PoolTypes = require(script.Parent.PoolTypes)

type PoolAdapter<T, TContext> = PoolTypes.PoolAdapter<T, TContext>
type PoolOptions = PoolTypes.PoolOptions
type PoolType<T, TContext> = PoolTypes.Pool<T, TContext>

local PoolModule = {}
PoolModule.__index = PoolModule

local function validateId(id: string)
	assert(typeof(id) == "string" and id ~= "", "Pool id must be a non-empty string")
end

local function sortedPoolIds(pools: { [string]: any }): { string }
	local ids = {}
	for id in pools do
		table.insert(ids, id)
	end
	table.sort(ids)
	return ids
end

local function aggregateErrors(prefix: string, errors: { string }): string
	return `{prefix}:\n{table.concat(errors, "\n")}`
end

function PoolModule.new()
	return setmetatable({
		_pools = {},
		_initialized = false,
		_destroyed = false,
	}, PoolModule)
end

function PoolModule:Initialize()
	assert(not self._destroyed, "PoolModule is destroyed")
	self._initialized = true
end

function PoolModule:CreatePool<T, TContext>(
	id: string,
	adapter: PoolAdapter<T, TContext>,
	options: PoolOptions
): PoolType<T, TContext>
	assert(self._initialized, "PoolModule is not initialized")
	assert(not self._destroyed, "PoolModule is destroyed")
	validateId(id)
	assert(self._pools[id] == nil, `Pool '{id}' already exists`)

	local pool = Pool.new(adapter, options)
	self._pools[id] = pool
	return pool
end

function PoolModule:CreatePoolablePool<T, TContext>(
	id: string,
	factory: () -> T,
	options: PoolOptions
): PoolType<T, TContext>
	return self:CreatePool(id, PoolAdapters.fromPoolable(factory), options)
end

function PoolModule:GetPool(id: string)
	validateId(id)
	return self._pools[id]
end

function PoolModule:ClearPool(id: string): boolean
	validateId(id)
	local pool = self._pools[id]
	if pool == nil then
		return false
	end
	pool:Clear()
	return true
end

function PoolModule:ClearAllPools(): number
	local cleared = 0
	local errors = {}
	for _, id in sortedPoolIds(self._pools) do
		local ok, clearError = xpcall(function()
			self._pools[id]:Clear()
		end, debug.traceback)
		if ok then
			cleared += 1
		else
			table.insert(errors, `{id}: {tostring(clearError)}`)
		end
	end
	if #errors > 0 then
		error(aggregateErrors("PoolModule clear failed", errors), 2)
	end
	return cleared
end

function PoolModule:RemovePool(id: string): boolean
	validateId(id)
	local pool = self._pools[id]
	if pool == nil then
		return false
	end

	self._pools[id] = nil
	pool:Destroy()
	return true
end

function PoolModule:Destroy()
	if self._destroyed then
		return
	end
	self._destroyed = true

	local pools = self._pools
	self._pools = {}
	local errors = {}
	for _, id in sortedPoolIds(pools) do
		local ok, destroyError = xpcall(function()
			pools[id]:Destroy()
		end, debug.traceback)
		if not ok then
			table.insert(errors, `{id}: {tostring(destroyError)}`)
		end
	end
	if #errors > 0 then
		error(aggregateErrors("PoolModule destroy failed", errors), 2)
	end
end

return PoolModule
