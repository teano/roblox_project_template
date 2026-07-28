--!strict

--[[
	Deterministic production-contract integration tests.

	require(game.ServerScriptService.Tests.ProductionIntegrationTestRunner).runAll()
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local CommunicationProtocol = require(ReplicatedStorage.Shared.Communication.CommunicationProtocol)
local CommunicationConfig = require(ReplicatedStorage.Shared.Communication.CommunicationConfig)
local CommunicationSerialize = require(ReplicatedStorage.Shared.Communication.CommunicationSerialize)
local CommunicationClient = require(ReplicatedStorage.Client.Communication.CommunicationClient)
local ClientSaveController = require(ReplicatedStorage.Client.Save.ClientSaveController)

local CommunicationServer = require(ServerScriptService.Modules.Communication.CommunicationServer)
local DataStoreStorage = require(ServerScriptService.Modules.Storage.DataStoreStorage)
local MemoryStorage = require(ServerScriptService.Modules.Storage.MemoryStorage)
local SessionLockingStorage = require(ServerScriptService.Modules.Storage.SessionLockingStorage)
local ServerSaveController = require(ServerScriptService.Modules.Save.ServerSaveController)
local ShutdownSaveCoordinator = require(ServerScriptService.Modules.Save.ShutdownSaveCoordinator)

local ProductionIntegrationTestRunner = {}

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

local function makeServerProvider(id: string, failValue: number?)
	local values = {}
	return {
		Id = id,
		Version = 1,
		Authority = "Server",
		MementoChanged = Signal.new(),
		CreateDefault = function()
			return { Value = 1 }
		end,
		ValidateMemento = function(_self, _player, value)
			return typeof(value) == "table" and typeof(value.Value) == "number", value, nil
		end,
		SetMemento = function(_self, player, value)
			values[player] = { Value = value.Value }
		end,
		GetMemento = function(_self, player)
			return { Value = values[player].Value }
		end,
		Run = function(_self, player)
			if failValue ~= nil and values[player].Value == failValue then
				error(`Provider {id} failed during Run`)
			end
		end,
		Stop = function(_self, player)
			values[player] = nil
		end,
		GetValue = function(_self, player)
			return if values[player] then values[player].Value else nil
		end,
	}
end

local function makeClientProvider(id: string, failValue: number?)
	local value = nil
	return {
		Id = id,
		Version = 1,
		Authority = "Server",
		ValidateMemento = function(_self, candidate)
			return typeof(candidate) == "table" and typeof(candidate.Value) == "number", candidate, nil
		end,
		SetMemento = function(_self, candidate)
			value = { Value = candidate.Value }
		end,
		GetMemento = function()
			return { Value = value.Value }
		end,
		Run = function()
			if failValue ~= nil and value.Value == failValue then
				error(`Client provider {id} failed during Run`)
			end
		end,
		Stop = function()
			value = nil
		end,
		GetValue = function()
			return if value then value.Value else nil
		end,
	}
end

function ProductionIntegrationTestRunner.runAll()
	local tests = {}

	local function test(name: string, callback: () -> ())
		table.insert(tests, { Name = name, Callback = callback })
	end

	test("server snapshot rolls back every provider after Run failure", function()
		local first = makeServerProvider("First", nil)
		local second = makeServerProvider("Second", 20)
		local memory = MemoryStorage.new()
		local storage = SessionLockingStorage.new(memory, { StaleLockSeconds = 1_800 })
		local controller = ServerSaveController.new({
			Id = "atomic_server",
			Providers = { first, second },
			Storage = storage,
			KeyResolver = function(player)
				return `Atomic_{player.UserId}`
			end,
		})
		local player = { UserId = 301 } :: any
		assertTrue(controller:Load(player).Ok, "initial server load failed")

		local applied = pcall(function()
			controller:ApplyMemento(player, {
				Revision = 2,
				Metadata = {},
				Providers = {
					First = { Version = 1, Data = { Value = 10 } },
					Second = { Version = 1, Data = { Value = 20 } },
				},
			})
		end)
		assertEqual(applied, false, "failing snapshot must throw")
		assertTrue(controller:IsLoaded(player), "rolled-back controller must remain loaded")
		assertEqual(first:GetValue(player), 1)
		assertEqual(second:GetValue(player), 1)
		assertEqual(controller:BuildSnapshot(player).Revision, 1)
		controller:Destroy(false)
	end)

	test("client snapshot rolls back data and revision after Run failure", function()
		local handlers = {}
		local communication = {
			RegisterHandler = function(_self, messageType, handler)
				handlers[messageType] = handler
			end,
			Queue = function()
				return true
			end,
		}
		local first = makeClientProvider("First", nil)
		local second = makeClientProvider("Second", 20)
		local controller = ClientSaveController.new({
			Id = "atomic_client",
			Providers = { first, second },
			Communication = communication,
		})
		controller:ApplySnapshot({
			ControllerId = "atomic_client",
			Revision = 4,
			Providers = {
				First = { Version = 1, Data = { Value = 1 } },
				Second = { Version = 1, Data = { Value = 1 } },
			},
		})

		local applied = pcall(function()
			controller:ApplySnapshot({
				ControllerId = "atomic_client",
				Revision = 5,
				Providers = {
					First = { Version = 1, Data = { Value = 10 } },
					Second = { Version = 1, Data = { Value = 20 } },
				},
			})
		end)
		assertEqual(applied, false)
		assertTrue(controller:IsReady(), "rolled-back client must remain ready")
		assertEqual(controller:GetRevision(), 4)
		assertEqual(first:GetValue(), 1)
		assertEqual(second:GetValue(), 1)
		controller:Destroy()
	end)

	test("two storage owners enforce lock loss and stale takeover", function()
		local memory = MemoryStorage.new()
		local config = { StaleLockSeconds = 60 }
		local first = SessionLockingStorage.new(memory, config)
		local second = SessionLockingStorage.new(memory, config)
		local firstLoad = first:Load("Shared")
		assertTrue(firstLoad.Ok, "first lock failed")
		assertEqual(second:Load("Shared").Code, "SessionLocked")

		memory:Update("Shared", function(document)
			document.Session.LastHeartbeatAt = os.time() - 61
			return document
		end)
		local takeover = second:Load("Shared")
		assertTrue(takeover.Ok and takeover.StaleTakeover, "stale takeover failed")
		assertEqual(first:Save("Shared", takeover.Document).Code, "LockLost")
		assertTrue(second:Release("Shared").Ok, "takeover release failed")
	end)

	test("DataStore retry succeeds within its bounded budget", function()
		local calls = 0
		local value = nil
		local fakeStore = {
			UpdateAsync = function(_self, _key, transform)
				calls += 1
				if calls < 3 then
					error("transient")
				end
				value = transform(value)
				return value
			end,
		}
		local storage = DataStoreStorage.new({
			DataStoreName = "Fake",
			Retry = {
				MaxAttempts = 3,
				BaseDelaySeconds = 0,
				MaxDelaySeconds = 0,
				JitterSeconds = 0,
			},
		}, nil, fakeStore)
		local result = storage:Update("Key", function()
			return { Saved = true }
		end)
		assertTrue(result.Ok, "retry should eventually succeed")
		assertEqual(calls, 3)
		assertEqual(result.Value.Saved, true)
	end)

	test("expired DataStore deadline prevents a new attempt", function()
		local calls = 0
		local storage = DataStoreStorage.new({
			DataStoreName = "Fake",
			Retry = {
				MaxAttempts = 3,
				BaseDelaySeconds = 0,
				MaxDelaySeconds = 0,
				JitterSeconds = 0,
			},
		}, nil, {
			UpdateAsync = function()
				calls += 1
			end,
		})
		local result = storage:Update("Key", function()
			return {}
		end, {
			Deadline = os.clock() - 1,
		})
		assertEqual(result.Code, "DeadlineExceeded")
		assertEqual(calls, 0)
	end)

	test("shutdown closes players concurrently within the configured cap", function()
		local active = 0
		local maxActive = 0
		local closed = 0
		local coordinator = ShutdownSaveCoordinator.new({
			BudgetSeconds = 1,
			MaxConcurrency = 2,
		})
		local controller = {
			Close = function(_self, _player, _save, options)
				assertTrue(options.Deadline > os.clock(), "worker received expired deadline")
				active += 1
				maxActive = math.max(maxActive, active)
				task.wait(0.02)
				active -= 1
				closed += 1
				return { Ok = true }
			end,
		}
		local players = {}
		for userId = 1, 12 do
			table.insert(players, { UserId = userId } :: any)
		end
		local result = coordinator:ClosePlayers(controller, players)
		assertEqual(result.TimedOut, false)
		assertEqual(result.Succeeded, 12)
		assertEqual(closed, 12)
		assertTrue(maxActive >= 2 and maxActive <= 2, "shutdown concurrency cap was not enforced")
	end)

	test("shutdown returns when the global deadline is exhausted", function()
		local coordinator = ShutdownSaveCoordinator.new({
			BudgetSeconds = 0.03,
			MaxConcurrency = 2,
		})
		local controller = {
			Close = function()
				task.wait(0.15)
				return { Ok = true }
			end,
		}
		local players = {}
		for userId = 1, 8 do
			table.insert(players, { UserId = userId } :: any)
		end
		local startedAt = os.clock()
		local result = coordinator:ClosePlayers(controller, players)
		assertTrue(result.TimedOut, "slow shutdown must report timeout")
		assertTrue(os.clock() - startedAt < 0.1, "coordinator exceeded its global budget")
	end)

	test("communication serializer accepts Vector3 and rejects Instances", function()
		local vectorValid = CommunicationSerialize.validate({
			Impulse = Vector3.new(1, 2, 3),
		})
		assertEqual(vectorValid, true)
		local part = Instance.new("Part")
		local instanceValid = CommunicationSerialize.validate({
			Part = part,
		})
		part:Destroy()
		assertEqual(instanceValid, false)
	end)

	test("server batch flush preserves Vector3 payloads", function()
		local server = CommunicationServer.new({
			PlayersModule = {
				PlayerRemoving = Signal.new(),
			},
		})
		local player = { UserId = 400 } :: any
		local capturedPlayer = nil
		local capturedBatch = nil
		server._serverToClient = {
			FireClient = function(_self, targetPlayer, batch)
				capturedPlayer = targetPlayer
				capturedBatch = batch
			end,
		}

		server:BeginSnapshot(player)
		server:SetClientReady(player)
		local queued = server:Queue(player, "Integration.Vector3", {
			Impulse = Vector3.new(1, 2, 3),
			Direction = Vector3.yAxis,
		}, nil, {
			Priority = CommunicationProtocol.Priorities.Critical,
		})
		server:_flush()

		assertEqual(queued, true)
		assertEqual(capturedPlayer, player)
		assertTrue(capturedBatch ~= nil, "flush did not emit a batch")
		assertEqual(typeof(capturedBatch.Messages[1].Payload.Impulse), "Vector3")
		assertEqual(capturedBatch.Messages[1].Payload.Impulse, Vector3.new(1, 2, 3))
		assertEqual(server:GetQueueStats(player).Messages, 0)
	end)

	test("client detects packet loss and accepts sequence one after resync", function()
		local client = CommunicationClient.new()
		local resyncs = 0
		local handled = 0
		client:RegisterHandler("Integration.Message", function()
			handled += 1
		end)
		client:SetResyncHandler(function()
			resyncs += 1
		end)
		client:ResumeAfterSnapshot(1)
		client:_handleBatch({
			Epoch = 1,
			Sequence = 2,
			Messages = {},
		})
		task.wait()
		assertEqual(resyncs, 1)
		assertEqual(client:GetQueueStats().PausedForResync, true)

		client:ResumeAfterSnapshot(2)
		client:_handleBatch({
			Epoch = 2,
			Sequence = 1,
			Messages = {
				{
					Type = "Integration.Message",
					Payload = {},
				},
			},
		})
		assertEqual(handled, 1)
		client:_handleBatch({
			Epoch = 1,
			Sequence = 99,
			Messages = {
				{
					Type = "Integration.Message",
					Payload = {},
				},
			},
		})
		assertEqual(handled, 1, "stale pre-resync packet must be ignored")
	end)

	test("server backpressure drops presentation before state", function()
		local playerRemoving = Signal.new()
		local server = CommunicationServer.new({
			PlayersModule = {
				PlayerRemoving = playerRemoving,
			},
		})
		local player = { UserId = 401 } :: any
		for index = 1, CommunicationConfig.MaxQueuedMessagesPerPeer + 20 do
			server:Queue(player, "Presentation", { Index = index }, nil, {
				Priority = CommunicationProtocol.Priorities.Presentation,
			})
		end
		local stats = server:GetQueueStats(player)
		assertTrue(stats.Messages <= CommunicationConfig.MaxQueuedMessagesPerPeer, "queue limit exceeded")
		assertTrue(stats.DroppedPresentation > 0, "presentation was not shed")
		assertEqual(stats.ResyncRequired, false)
	end)

	test("state overflow collapses queue to one resync request", function()
		local server = CommunicationServer.new({
			PlayersModule = {
				PlayerRemoving = Signal.new(),
			},
		})
		local player = { UserId = 402 } :: any
		for index = 1, CommunicationConfig.MaxQueuedMessagesPerPeer + 1 do
			server:Queue(player, "State", { Index = index }, nil, {
				Priority = CommunicationProtocol.Priorities.State,
			})
		end
		local stats = server:GetQueueStats(player)
		assertEqual(stats.ResyncRequired, true)
		assertEqual(stats.Messages, 1)
		server:BeginSnapshot(player)
		assertEqual(server:GetQueueStats(player).ResyncRequired, false)
	end)

	local passed = 0
	local failures = {}
	for _, entry in tests do
		local ok, testError = xpcall(entry.Callback, debug.traceback)
		if ok then
			passed += 1
		else
			table.insert(failures, `{entry.Name}: {tostring(testError)}`)
			warn(`[ProductionIntegrationTestRunner] FAIL {entry.Name}: {tostring(testError)}`)
		end
	end

	print(`[ProductionIntegrationTestRunner] passed={passed} failed={#failures} total={#tests}`)
	return {
		passed = passed,
		failed = #failures,
		failures = failures,
	}
end

return ProductionIntegrationTestRunner
