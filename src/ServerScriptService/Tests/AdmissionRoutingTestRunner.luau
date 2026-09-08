--!strict

local AdmissionRouting = require(game.ServerScriptService.Modules.PlayerAdmission.AdmissionRouting)
local TestHarness = require(script.Parent.TestHarness)

local Runner = {}

local function equal(actual: any, expected: any, message: string?)
	if actual ~= expected then error(`{message or "assertEqual"}: expected={tostring(expected)} actual={tostring(actual)}`, 2) end
end

local function truthy(value: any, message: string)
	if not value then error(message, 2) end
end

local function copy(value: any): any
	if typeof(value) ~= "table" then return value end
	local result = {}
	for key, item in value do result[key] = copy(item) end
	return result
end

-- Simulates a shared sorted map with optimistic concurrency. A competing update
-- between transform and commit invalidates the snapshot and reruns transform.
local function makeWorld(scope: any): any
	local world: any = { Time = 100000, Tick = 0, Sequence = 0, Calls = 0, Creates = 0, Retries = 0,
		Rows = {}, Versions = {}, BeforeCommit = nil, AfterCommit = nil, Suspended = {}, Threads = {} }
	local function read(key: string): any
		local row = world.Rows[key]
		if row and row.Expiry <= world.Time then
			world.Rows[key] = nil
			world.Versions[key] = (world.Versions[key] or 0) + 1
			return nil
		end
		return row
	end
	world.Store = {
		UpdateAsync = function(_self: any, key: string, transform: any, expiration: number): any
			world.Calls += 1
			for _ = 1, 20 do
				local old = read(key)
				local version = world.Versions[key] or 0
				local candidate, sortKey = transform(if old then copy(old.Value) else nil, if old then old.SortKey else nil)
				if candidate == nil then return nil end
				if world.BeforeCommit then world.BeforeCommit(key, candidate) end
				if (world.Versions[key] or 0) ~= version then world.Retries += 1; continue end
				world.Rows[key] = { Value = copy(candidate), SortKey = sortKey or 0, Expiry = world.Time + expiration }
				world.Versions[key] = version + 1
				if world.AfterCommit then world.AfterCommit(key, candidate) end
				return copy(candidate)
			end
			error("FakeStoreContentionLimit")
		end,
		GetAsync = function(_self: any, key: string): any
			world.Calls += 1
			local row = read(key)
			return if row then copy(row.Value) else nil
		end,
		GetRangeAsync = function(_self: any, _direction: any, count: number): any
			world.Calls += 1
			local entries = {}
			for key in world.Rows do
				local row = read(key)
				if row then table.insert(entries, { key = key, value = copy(row.Value), sortKey = row.SortKey }) end
			end
			table.sort(entries, function(left, right)
				return if left.sortKey == right.sortKey then left.key < right.key else left.sortKey > right.sortKey
			end)
			while #entries > count do table.remove(entries) end
			return entries
		end,
	}
	world.Spawn = function(callback: any)
		local thread = coroutine.create(callback)
		table.insert(world.Threads, thread)
		local ok, message = coroutine.resume(thread)
		if not ok then error(message, 2) end
	end
	world.Wait = function(seconds: number)
		world.Tick += math.max(seconds, 0.001)
		if world.Tick > 100 then error("FakeSchedulerLimit") end
	end
	world.Resume = function()
		local suspended = world.Suspended
		world.Suspended = {}
		for _, thread in suspended do
			if coroutine.status(thread) == "suspended" then
				local ok, message = coroutine.resume(thread)
				if not ok then error(message, 2) end
			end
		end
	end
	world.Suspend = function()
		table.insert(world.Suspended, coroutine.running())
		coroutine.yield()
	end
	scope:Defer(function()
		for _, thread in world.Threads do
			if coroutine.status(thread) == "suspended" then coroutine.close(thread) end
		end
	end)
	return world
end

local function makeRouting(scope: any, world: any, jobId: string, options: any?): any
	options = options or {}
	local routing = AdmissionRouting.new({
		Store = world.Store,
		TeleportModule = { ReserveServer = function(_self: any, placeId: number)
			equal(placeId, 10)
			world.Creates += 1
			return { Ok = true, PrivateServerId = `private-{world.Creates}`, AccessCode = `access-{world.Creates}` }
		end },
		GenerateId = function() world.Sequence += 1; return `id-{world.Sequence}` end,
		PlaceId = 10, JobId = jobId, PrivateServerId = options.PrivateServerId,
		MatchmakingType = options.MatchmakingType,
		Clock = function() return world.Time end,
		MonotonicClock = function() return world.Tick end,
		Spawn = world.Spawn, Wait = world.Wait, AutoRefresh = false,
		RecordLifetimeSeconds = 60, ReservationLifetimeSeconds = 30,
		OperationTimeoutSeconds = 0.1, RouteTimeoutSeconds = 0.5,
	})
	scope:Defer(function() routing:Stop() end)
	if not options.DeferInitialize then routing:Initialize(options.Enabled ~= false, options.SlotIds or { 1 }) end
	return routing
end

function Runner.runAll()
	local tests = {}
	local function test(name: string, callback: any) table.insert(tests, { Name = name, Callback = callback }) end

	test("first Roblox server registers empty capacity and admits its first owner locally", function(scope)
		local world = makeWorld(scope)
		local server = makeRouting(scope, world, "first")
		local result = server:AcquireLocal(101, 1)
		truthy(result.Ok, "first local owner rejected")
		truthy(server:IsClaimCurrent(result.Claim), "first local claim is not current")
		equal(world.Creates, 0)
		equal(world.Rows["public:first"].Value.Slots["1"].State, "Occupied")
	end)

	test("disabled routing performs no storage or reserved server calls", function(scope)
		local world = makeWorld(scope)
		local server = makeRouting(scope, world, "disabled", { Enabled = false })
		equal(server:IsEnabled(), false)
		equal(server:AcquireLocal(1, 1).Ok, false)
		equal(server:ReserveDestination(1).Ok, false)
		equal(server:ResolveFriendDestination("friend").Destination.ServerInstanceId, "friend")
		server:Refresh(); server:Stop()
		equal(world.Calls, 0); equal(world.Creates, 0)
	end)

	test("two sources contending for the last slot cannot both reserve it", function(scope)
		local world = makeWorld(scope)
		makeRouting(scope, world, "target")
		local first = makeRouting(scope, world, "first")
		local second = makeRouting(scope, world, "second")
		truthy(first:AcquireLocal(101, 1).Ok, "source not filled")
		truthy(second:AcquireLocal(102, 1).Ok, "source not filled")
		local competing: any = nil
		world.BeforeCommit = function(key: string, candidate: any)
			if key == "public:target" and typeof(candidate.Slots["1"]) == "table" and candidate.Slots["1"].UserId == 201 then
				world.BeforeCommit = nil
				competing = second:ReserveDestination(202)
			end
		end
		local result = first:ReserveDestination(201)
		truthy(competing and competing.Ok, "competing reserve failed")
		equal(competing.Claim.ServerKey, "public:target")
		truthy(result.Ok, "losing source did not find another server")
		truthy(result.Claim.ServerKey ~= competing.Claim.ServerKey, "both sources reserved the same slot")
		equal(world.Rows["public:target"].Value.Slots["1"].UserId, 202)
		truthy(world.Retries > 0, "test did not force atomic retry")
	end)

	test("remote reserve wins atomic race against an ordinary local owner", function(scope)
		local world = makeWorld(scope)
		local target = makeRouting(scope, world, "target")
		local source = makeRouting(scope, world, "source")
		truthy(source:AcquireLocal(100, 1).Ok, "source not filled")
		local remote: any = nil
		world.BeforeCommit = function(key: string, candidate: any)
			if key == "public:target" and candidate.Slots["1"].State == "Occupied" then
				world.BeforeCommit = nil
				remote = source:ReserveDestination(200)
			end
		end
		equal(target:AcquireLocal(201, 1).Ok, false)
		truthy(remote and remote.Ok, "remote reservation failed")
		equal(world.Rows["public:target"].Value.Slots["1"].State, "Reserved")
		truthy(target:AcquireLocal(200, 1, remote.Continuation).Ok, "winner cannot arrive")
	end)

	test("late source release cannot erase an occupied arrival", function(scope)
		local world = makeWorld(scope)
		local target = makeRouting(scope, world, "target")
		local source = makeRouting(scope, world, "source")
		truthy(source:AcquireLocal(100, 1).Ok, "source not filled")
		local reserve = source:ReserveDestination(200)
		truthy(reserve.Ok, "reservation failed")
		local arrival = target:AcquireLocal(200, 1, reserve.Continuation)
		truthy(arrival.Ok, "arrival failed")
		truthy(arrival.Claim.Token ~= reserve.Claim.Token, "reservation token was not consumed")
		source:Release(reserve.Claim)
		equal(world.Rows["public:target"].Value.Slots["1"].State, "Occupied")
		truthy(target:IsClaimCurrent(arrival.Claim), "late source release invalidated arrival")
		target:Release(arrival.Claim)
		equal(world.Rows["public:target"].Value.Slots["1"], false)
	end)

	test("concurrent all-full sources create one shared reserved server", function(scope)
		local world = makeWorld(scope)
		local first = makeRouting(scope, world, "first", { SlotIds = { 1, 2 } })
		local second = makeRouting(scope, world, "second", { SlotIds = { 1, 2 } })
		for slotId = 1, 2 do
			truthy(first:AcquireLocal(100 + slotId, slotId).Ok, "source not filled")
			truthy(second:AcquireLocal(200 + slotId, slotId).Ok, "source not filled")
		end
		local competing: any = nil
		world.BeforeCommit = function(key: string, _candidate: any)
			if key == "launch:Default" then
				world.BeforeCommit = nil
				competing = second:ReserveDestination(302)
			end
		end
		local result = first:ReserveDestination(301)
		truthy(result.Ok and competing and competing.Ok, "concurrent creation did not finish")
		equal(world.Creates, 1)
		equal(result.Claim.ServerKey, competing.Claim.ServerKey)
		truthy(result.Claim.SlotId ~= competing.Claim.SlotId, "shared startup slot was reserved twice")
		equal(result.Destination.Kind, "ReservedServer")
		equal(result.Destination.ReservedServerAccessCode, "access-1")
	end)

	test("reserved first startup preserves generation and resolves friend destination directly", function(scope)
		local world = makeWorld(scope)
		local source = makeRouting(scope, world, "source")
		truthy(source:AcquireLocal(100, 1).Ok, "source not filled")
		local reserve = source:ReserveDestination(200)
		truthy(reserve.Ok, "reserved creation failed")
		local target = makeRouting(scope, world, "reserved-job", { PrivateServerId = "private-1" })
		local result = target:AcquireLocal(200, 1, reserve.Continuation)
		truthy(result.Ok, "first reserved arrival rejected")
		equal(result.Claim.Generation, reserve.Continuation.Generation)
		local destination = source:ResolveFriendDestination("reserved-job")
		truthy(destination.Ok, "reserved friend route missing")
		equal(destination.Destination.Kind, "ReservedServer")
		equal(destination.Destination.ReservedServerAccessCode, "access-1")
	end)

	test("expired record recovery preserves occupied slots and rejects old arrival generations", function(scope)
		local world = makeWorld(scope)
		local target = makeRouting(scope, world, "target", { SlotIds = { 1, 2 } })
		local source = makeRouting(scope, world, "source", { SlotIds = { 1, 2 } })
		truthy(source:AcquireLocal(100, 1).Ok, "source not filled")
		truthy(source:AcquireLocal(101, 2).Ok, "source not filled")
		local occupied = target:AcquireLocal(200, 1)
		truthy(occupied.Ok, "target owner failed")
		local reserved = source:ReserveDestination(201)
		truthy(reserved.Ok, "target reserve failed")
		local oldGeneration = reserved.Continuation.Generation
		world.Time += 61
		truthy(target:Refresh(), "expired server could not recover")
		truthy(occupied.Claim.Generation ~= oldGeneration, "generation not changed on recovery")
		equal(world.Rows["public:target"].Value.Slots["1"].UserId, 200)
		equal(target:AcquireLocal(202, 1).Ok, false)
		equal(target:AcquireLocal(201, 2, reserved.Continuation).Error, "InvalidReservation")
		truthy(target:IsClaimCurrent(occupied.Claim), "recovery lost an admitted owner")
	end)

	test("expired reservation permits a new local owner but rejects delayed reserved arrival", function(scope)
		local world = makeWorld(scope)
		local target = makeRouting(scope, world, "target")
		local source = makeRouting(scope, world, "source")
		truthy(source:AcquireLocal(100, 1).Ok, "source not filled")
		local reserve = source:ReserveDestination(200)
		world.Time += 31
		equal(target:AcquireLocal(200, 1, reserve.Continuation).Error, "InvalidReservation")
		truthy(target:AcquireLocal(201, 1).Ok, "expired reservation still blocks ordinary owner")
	end)

	test("same reserved identity in separate platform partitions cannot overwrite another server", function(scope)
		local world = makeWorld(scope)
		local first = makeRouting(scope, world, "first", { PrivateServerId = "shared", MatchmakingType = "Default" })
		local second = makeRouting(scope, world, "second", { PrivateServerId = "shared", MatchmakingType = "Console" })
		local firstClaim = first:AcquireLocal(100, 1)
		local secondClaim = second:AcquireLocal(200, 1)
		truthy(firstClaim.Ok and secondClaim.Ok, "platform partitions blocked one another")
		truthy(firstClaim.Claim.ServerKey ~= secondClaim.Claim.ServerKey, "reserved key collided across platform partitions")
		truthy(first:Refresh() and second:Refresh(), "partition refresh failed")
		equal(world.Rows[firstClaim.Claim.ServerKey].Value.Slots["1"].UserId, 100)
		equal(world.Rows[secondClaim.Claim.ServerKey].Value.Slots["1"].UserId, 200)
	end)

	test("generation recovery before a pending acquisition returns cannot admit its old claim", function(scope)
		local world = makeWorld(scope)
		local target = makeRouting(scope, world, "target")
		world.AfterCommit = function(key: string, candidate: any)
			if key == "public:target" and typeof(candidate.Slots["1"]) == "table" then
				world.AfterCommit = nil
				world.Time += 61
				truthy(target:Refresh(), "generation recovery failed")
			end
		end
		equal(target:AcquireLocal(200, 1).Ok, false)
		equal(world.Rows["public:target"].Value.Slots["1"], false)
		truthy(target:AcquireLocal(201, 1).Ok, "old generation cleanup damaged recovered server")
	end)

	test("timeout after accepted storage write releases late acquisition instead of resurrecting it", function(scope)
		local world = makeWorld(scope)
		local target = makeRouting(scope, world, "target")
		world.AfterCommit = function(key: string, candidate: any)
			if key == "public:target" and typeof(candidate.Slots["1"]) == "table" then
				world.AfterCommit = nil
				world.Suspend()
			end
		end
		equal(target:AcquireLocal(200, 1).Error, "Unavailable")
		equal(world.Rows["public:target"].Value.Slots["1"].State, "Occupied")
		world.Resume()
		equal(world.Rows["public:target"].Value.Slots["1"], false)
		truthy(target:AcquireLocal(201, 1).Ok, "late cleanup failed to restore capacity")
	end)

	test("Stop retires an accepted pending acquisition and late return cannot restore live state", function(scope)
		local world = makeWorld(scope)
		local target = makeRouting(scope, world, "target")
		world.AfterCommit = function(key: string, candidate: any)
			if key == "public:target" and typeof(candidate.Slots["1"]) == "table" then
				world.AfterCommit = nil
				target:Stop()
			end
		end
		equal(target:AcquireLocal(200, 1).Error, "Unavailable")
		equal(target:Refresh(), false)
		equal(world.Rows["public:target"].Value.AliveUntil, 0)
		equal(target:AcquireLocal(201, 1).Ok, false)
	end)

	test("failed reserved job address publication prevents admission until publication succeeds", function(scope)
		local world = makeWorld(scope)
		world.BeforeCommit = function(key: string, _candidate: any)
			if key == "job:reserved-job" then error("expected injected address publication failure") end
		end
		local target = makeRouting(scope, world, "reserved-job", { PrivateServerId = "private-test" })
		equal(target:AcquireLocal(200, 1).Ok, false)
		world.BeforeCommit = nil
		truthy(target:Refresh(), "address publication did not recover")
		truthy(target:AcquireLocal(200, 1).Ok, "owner could not enter after address publication")
	end)

	test("first registration accepted after Stop is retired by the late completion", function(scope)
		local world = makeWorld(scope)
		local target = makeRouting(scope, world, "target", { DeferInitialize = true })
		world.BeforeCommit = function(key: string, _candidate: any)
			if key == "public:target" then
				world.BeforeCommit = nil
				target:Stop()
			end
		end
		target:Initialize(true, { 1 })
		truthy(world.Rows["public:target"] ~= nil, "test did not accept registration after Stop")
		equal(world.Rows["public:target"].Value.AliveUntil, 0)
		equal(target:Refresh(), false)
		equal(target:AcquireLocal(200, 1).Ok, false)
	end)

	test("malformed reserved job address acknowledgement cannot mark routing ready", function(scope)
		for _, patch in { { Kind = "Other" }, { ServerKey = "wrong-server" }, { AliveUntil = 0 } } do
			local world = makeWorld(scope)
			world.AfterCommit = function(key: string, candidate: any)
				if key == "job:reserved-job" then
					for field, value in patch do candidate[field] = value end
				end
			end
			local target = makeRouting(scope, world, "reserved-job", { PrivateServerId = "private-test" })
			equal(target:AcquireLocal(200, 1).Ok, false)
		end
	end)

	test("refresh accepted before Stop cannot become live again when its suspended response arrives", function(scope)
		local world = makeWorld(scope)
		local target = makeRouting(scope, world, "target")
		world.AfterCommit = function(key: string, _candidate: any)
			if key == "public:target" then
				world.AfterCommit = nil
				world.Suspend()
			end
		end
		equal(target:Refresh(), false)
		target:Stop()
		world.Resume()
		equal(world.Rows["public:target"].Value.AliveUntil, 0)
		equal(target:AcquireLocal(200, 1).Ok, false)
	end)

	return TestHarness.runAll("AdmissionRoutingTestRunner", tests)
end

return Runner
