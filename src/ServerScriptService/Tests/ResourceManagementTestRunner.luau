--!strict

--[[
	Manual Studio harness for shared server/client pooling behavior.

	require(game.ServerScriptService.Tests.ResourceManagementTestRunner).runAll()
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Pool = require(ReplicatedStorage.Shared.Pooling.Pool)
local PoolAdapters = require(ReplicatedStorage.Shared.Pooling.PoolAdapters)
local PoolModule = require(ReplicatedStorage.Shared.Pooling.PoolModule)
local TestHarness = require(script.Parent.TestHarness)

local ResourceManagementTestRunner = {}

local function assertEqual(actual: any, expected: any, message: string?)
	if actual ~= expected then
		error(`{message or "assertEqual"}: expected={tostring(expected)} actual={tostring(actual)}`, 2)
	end
end

local function assertTrue(value: any, message: string)
	if not value then
		error(message, 2)
	end
end

local function makeTableAdapter(counters: any?)
	local state = counters or {
		Created = 0,
		Acquired = 0,
		Released = 0,
		Destroyed = 0,
	}
	return {
		Create = function()
			state.Created += 1
			return {
				Id = state.Created,
				Context = nil,
				Destroyed = false,
			}
		end,
		Acquire = function(object, context)
			state.Acquired += 1
			object.Context = context
		end,
		Release = function(object)
			state.Released += 1
			object.Context = nil
		end,
		Destroy = function(object)
			state.Destroyed += 1
			object.Destroyed = true
		end,
		IsValid = function(object)
			return not object.Destroyed
		end,
	}, state
end

function ResourceManagementTestRunner.runAll()
	local tests = {}

	local function test(name: string, callback: () -> ())
		table.insert(tests, { Name = name, Callback = callback })
	end

	test("warmup is idempotent and acquire reuses a released object", function()
		local adapter, counters = makeTableAdapter()
		local pool = Pool.new(adapter, {
			MaxRetained = 2,
			MaxActive = 3,
		})

		assertEqual(pool:Warmup(2), 2)
		assertEqual(pool:Warmup(1), 0)
		local lease = pool:GetFromPoolOrCreate("first")
		assertEqual(lease.Object.Context, "first")
		assertEqual(pool:GetStats().Available, 1)
		assertEqual(pool:GetStats().Active, 1)
		assertTrue(pool:ReleaseToPool(lease), "valid lease was not released")
		assertEqual(pool:GetStats().Available, 2)
		assertEqual(counters.Created, 2)
		assertEqual(counters.Released, 3)
		pool:Destroy()
		assertEqual(counters.Destroyed, 2)
	end)

	test("generation leases reject double, stale, and foreign release", function()
		local adapter = makeTableAdapter()
		local pool = Pool.new(adapter, {
			MaxRetained = 1,
			MaxActive = 2,
		})
		local otherPool = Pool.new(makeTableAdapter(), {
			MaxRetained = 1,
			MaxActive = 1,
		})

		local first = pool:Acquire("first")
		assertEqual(otherPool:TryReleaseToPool(first), false)
		local malformedLease = table.clone(first :: any)
		malformedLease.Object = 0 / 0
		assertEqual(pool:TryReleaseToPool(malformedLease), false)
		assertTrue(pool:IsLeaseActive(first), "malformed lease must not affect the valid lease")
		assertTrue(pool:ReleaseToPool(first), "first release failed")
		assertEqual(pool:TryReleaseToPool(first), false)

		local second = pool:Acquire("second")
		assertEqual(second.Object, first.Object, "pool did not reuse the released object")
		assertTrue(second.Generation ~= first.Generation, "reused object must receive a new generation")
		assertEqual(pool:TryReleaseToPool(first), false)
		assertTrue(pool:IsLeaseActive(second), "current lease must remain active")

		pool:Destroy()
		otherPool:Destroy()
		assertEqual(pool:IsLeaseActive(second), false)
	end)

	test("retention and active limits bound resource growth", function()
		local adapter, counters = makeTableAdapter()
		local pool = Pool.new(adapter, {
			MaxRetained = 1,
			MaxActive = 2,
		})

		local first = pool:Acquire(nil)
		local second = pool:Acquire(nil)
		local limitOk = pcall(function()
			pool:Acquire(nil)
		end)
		assertEqual(limitOk, false, "MaxActive must reject excess acquisition")

		pool:ReleaseToPool(first)
		pool:ReleaseToPool(second)
		assertEqual(pool:GetStats().Available, 1)
		assertEqual(counters.Destroyed, 1, "overflow object must be destroyed")
		pool:Destroy()
	end)

	test("failed acquire destroys the object without leaking active state", function()
		local destroyed = 0
		local pool = Pool.new({
			Create = function()
				return {}
			end,
			Acquire = function()
				error("expected acquire failure")
			end,
			Release = function() end,
			Destroy = function()
				destroyed += 1
			end,
		}, {
			MaxRetained = 1,
			MaxActive = 1,
		})

		local acquired = pcall(function()
			pool:Acquire(nil)
		end)
		assertEqual(acquired, false)
		assertEqual(pool:GetStats().Active, 0)
		assertEqual(destroyed, 1)
		pool:Destroy()
	end)

	test("Poolable adapter delegates the complete lifecycle", function()
		local lifecycle = {}
		local pool = Pool.new(PoolAdapters.fromPoolable(function()
			local object = {}
			function object:OnAcquire(context)
				table.insert(lifecycle, `Acquire:{context}`)
			end
			function object:OnRelease()
				table.insert(lifecycle, "Release")
			end
			function object:Destroy()
				table.insert(lifecycle, "Destroy")
			end
			return object
		end), {
			MaxRetained = 1,
			MaxActive = 1,
		})

		local lease = pool:Acquire("custom")
		pool:ReleaseToPool(lease)
		pool:Destroy()
		assertEqual(table.concat(lifecycle, ","), "Acquire:custom,Release,Destroy")
	end)

	test("Instance adapter reparents raw Roblox objects", function()
		local poolParent = Instance.new("Folder")
		local activeParent = Instance.new("Folder")
		poolParent.Name = "PoolParent"
		activeParent.Name = "ActiveParent"

		local pool = Pool.new(PoolAdapters.fromInstanceFactory(function()
			return Instance.new("Folder")
		end, {
			PoolParent = poolParent,
			Acquire = function(object, parent)
				object.Parent = parent
			end,
			Release = function(_object) end,
		}), {
			MaxRetained = 1,
			MaxActive = 1,
		})

		local lease = pool:Acquire(activeParent)
		assertEqual(lease.Object.Parent, activeParent)
		pool:ReleaseToPool(lease)
		assertEqual(lease.Object.Parent, poolParent)
		pool:Clear()
		poolParent:Destroy()
		activeParent:Destroy()
	end)

	test("registry clears idle objects and force-removes active objects", function()
		local module = PoolModule.new()
		module:Initialize()
		module:Initialize()

		local adapterA, countersA = makeTableAdapter()
		local adapterB, countersB = makeTableAdapter()
		local poolA = module:CreatePool("A", adapterA, {
			MaxRetained = 2,
			MaxActive = 2,
		})
		local poolB = module:CreatePool("B", adapterB, {
			MaxRetained = 1,
			MaxActive = 1,
		})

		poolA:Warmup(2)
		poolB:Warmup(1)
		local activeLease = poolA:Acquire(nil)
		assertTrue(module:ClearPool("A"), "registered pool was not cleared")
		assertEqual(countersA.Destroyed, 1, "clear must destroy only A's idle object")
		assertTrue(poolA:IsLeaseActive(activeLease), "clear must preserve active leases")
		assertEqual(countersB.Destroyed, 0, "specific clear affected another pool")

		assertEqual(module:ClearAllPools(), 2)
		assertEqual(countersB.Destroyed, 1)
		assertTrue(module:RemovePool("A"), "active pool was not removed")
		assertEqual(poolA:IsLeaseActive(activeLease), false)
		assertEqual(module:GetPool("A"), nil)
		module:Destroy()
		module:Destroy()
	end)

	test("primitive objects and Create failures never enter pool ownership", function()
		local primitivePool = Pool.new({
			Create = function()
				return 42
			end,
			Acquire = function() end,
			Release = function() end,
			Destroy = function() end,
		}, {
			MaxRetained = 1,
			MaxActive = 1,
		})
		local primitiveOk, primitiveError = pcall(function()
			primitivePool:Acquire(nil)
		end)
		assertEqual(primitiveOk, false)
		assertTrue(
			string.find(tostring(primitiveError), "stable identity", 1, true) ~= nil,
			"primitive rejection returned an unrelated error"
		)
		assertEqual(primitivePool:GetStats().Active, 0)
		primitivePool:Destroy()

		local createFailurePool = Pool.new({
			Create = function()
				error("expected create failure")
			end,
			Acquire = function() end,
			Release = function() end,
			Destroy = function() end,
		}, {
			MaxRetained = 1,
			MaxActive = 1,
		})
		local createOk = pcall(function()
			createFailurePool:Acquire(nil)
		end)
		assertEqual(createOk, false)
		assertEqual(createFailurePool:GetStats().Active, 0)
		createFailurePool:Destroy()
	end)

	test("Release and IsValid failures remove unsafe objects from circulation", function()
		local destroyed = 0
		local releasePool = Pool.new({
			Create = function()
				return {}
			end,
			Acquire = function() end,
			Release = function()
				error("expected release failure")
			end,
			Destroy = function()
				destroyed += 1
			end,
		}, {
			MaxRetained = 1,
			MaxActive = 1,
		})
		local lease = releasePool:Acquire(nil)
		local released, releaseError = releasePool:TryReleaseToPool(lease)
		assertEqual(released, false)
		assertTrue(string.find(releaseError or "", "Release failed", 1, true) ~= nil, "missing release failure")
		assertEqual(releasePool:GetStats().Active, 0)
		assertEqual(releasePool:GetStats().Available, 0)
		assertEqual(destroyed, 1)
		releasePool:Destroy()

		local validations = 0
		local invalidDestroyed = 0
		local validationPool = Pool.new({
			Create = function()
				return {}
			end,
			Acquire = function() end,
			Release = function() end,
			Destroy = function()
				invalidDestroyed += 1
			end,
			IsValid = function()
				validations += 1
				if validations >= 2 then
					error("expected IsValid failure")
				end
				return true
			end,
		}, {
			MaxRetained = 1,
			MaxActive = 1,
		})
		local validLease = validationPool:Acquire(nil)
		validationPool:ReleaseToPool(validLease)
		local validOk = pcall(function()
			validationPool:Acquire(nil)
		end)
		assertEqual(validOk, false)
		assertEqual(validationPool:GetStats().Active, 0)
		assertEqual(validationPool:GetStats().Available, 0)
		assertEqual(invalidDestroyed, 1)
		validationPool:Destroy()
	end)

	test("adapter re-entry fails closed and destroys the partially acquired object", function()
		local destroyed = 0
		local pool: any = nil
		pool = Pool.new({
			Create = function()
				return {}
			end,
			Acquire = function()
				pool:Acquire(nil)
			end,
			Release = function() end,
			Destroy = function()
				destroyed += 1
			end,
		}, {
			MaxRetained = 1,
			MaxActive = 2,
		})
		local ok, acquireError = pcall(function()
			pool:Acquire(nil)
		end)
		assertEqual(ok, false)
		assertTrue(
			string.find(tostring(acquireError), "re-enter", 1, true) ~= nil,
			"re-entry rejection returned an unrelated error"
		)
		assertEqual(pool:GetStats().Active, 0)
		assertEqual(destroyed, 1)
		pool:Destroy()
	end)

	return TestHarness.runAll("ResourceManagementTestRunner", tests)
end

return ResourceManagementTestRunner
