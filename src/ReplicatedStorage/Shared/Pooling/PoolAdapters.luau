--!strict

local PoolTypes = require(script.Parent.PoolTypes)

type PoolAdapter<T, TContext> = PoolTypes.PoolAdapter<T, TContext>

export type InstanceLifecycle<T, TContext> = {
	Acquire: (object: T, context: TContext) -> (),
	Release: (object: T) -> (),
	Destroy: ((object: T) -> ())?,
	IsValid: ((object: T) -> boolean)?,
	PoolParent: Instance?,
}

local PoolAdapters = {}

local function assertInstance(object: any): Instance
	assert(typeof(object) == "Instance", `Instance pool factory returned {typeof(object)}`)
	return object
end

local function defaultInstanceIsValid(object: Instance): boolean
	return pcall(function()
		local parent = object.Parent
		object.Parent = parent
	end)
end

function PoolAdapters.fromInstanceFactory<T, TContext>(
	factory: () -> T,
	lifecycle: InstanceLifecycle<T, TContext>
): PoolAdapter<T, TContext>
	assert(typeof(factory) == "function", "Instance pool factory must be a function")
	assert(typeof(lifecycle) == "table", "Instance lifecycle must be a table")
	assert(typeof(lifecycle.Acquire) == "function", "Instance lifecycle.Acquire must be a function")
	assert(typeof(lifecycle.Release) == "function", "Instance lifecycle.Release must be a function")

	return {
		Create = function(): T
			local object = factory()
			local instance = assertInstance(object)
			instance.Parent = lifecycle.PoolParent
			return object
		end,
		Acquire = lifecycle.Acquire,
		Release = function(object: T)
			lifecycle.Release(object)
			assertInstance(object).Parent = lifecycle.PoolParent
		end,
		Destroy = function(object: T)
			if lifecycle.Destroy then
				lifecycle.Destroy(object)
			else
				assertInstance(object):Destroy()
			end
		end,
		IsValid = function(object: T): boolean
			if lifecycle.IsValid then
				return lifecycle.IsValid(object)
			end
			return defaultInstanceIsValid(assertInstance(object))
		end,
	}
end

function PoolAdapters.fromInstanceTemplate<TContext>(
	template: Instance,
	lifecycle: InstanceLifecycle<Instance, TContext>
): PoolAdapter<Instance, TContext>
	assert(typeof(template) == "Instance", "Instance template must be an Instance")
	return PoolAdapters.fromInstanceFactory(function(): Instance
		local clone = template:Clone()
		assert(clone ~= nil, "Instance template is not Archivable")
		return clone
	end, lifecycle)
end

function PoolAdapters.fromPoolable<T, TContext>(factory: () -> T): PoolAdapter<T, TContext>
	assert(typeof(factory) == "function", "Poolable factory must be a function")
	return {
		Create = factory,
		Acquire = function(object: T, context: TContext)
			(object :: any):OnAcquire(context)
		end,
		Release = function(object: T)
			(object :: any):OnRelease()
		end,
		Destroy = function(object: T)
			(object :: any):Destroy()
		end,
		IsValid = function(object: T): boolean
			local validator = (object :: any).IsPoolableValid
			return validator == nil or validator(object)
		end,
	}
end

return table.freeze(PoolAdapters)
