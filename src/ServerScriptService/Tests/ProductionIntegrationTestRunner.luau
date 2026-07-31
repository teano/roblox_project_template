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
local SaveSerialize = require(ReplicatedStorage.Shared.Save.SaveSerialize)
local TokenBucket = require(ReplicatedStorage.Shared.Communication.TokenBucket)
local CommunicationClient = require(ReplicatedStorage.Client.Communication.CommunicationClient)
local ClientSaveController = require(ReplicatedStorage.Client.Save.ClientSaveController)
local WalletClient = require(ReplicatedStorage.Client.Wallet.WalletClient)

local GlobalSaveInitializationCommand =
	require(ServerScriptService.Initialization.Commands.GlobalSaveInitializationCommand)
local CommunicationServer = require(ServerScriptService.Modules.Communication.CommunicationServer)
local DataStoreStorage = require(ServerScriptService.Modules.Storage.DataStoreStorage)
local MemoryStorage = require(ServerScriptService.Modules.Storage.MemoryStorage)
local SessionLockingStorage = require(ServerScriptService.Modules.Storage.SessionLockingStorage)
local ServerSaveController = require(ServerScriptService.Modules.Save.ServerSaveController)
local ShutdownSaveCoordinator = require(ServerScriptService.Modules.Save.ShutdownSaveCoordinator)
local WalletModule = require(ServerScriptService.Modules.Wallet.WalletModule)
local TestHarness = require(script.Parent.TestHarness)

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

local function makeLogger()
	local entries = {}
	local function record(level: string, message: string, fields: any?)
		table.insert(entries, {
			Level = level,
			Message = message,
			Fields = fields,
		})
	end
	return {
		Debug = function(_self, message, fields)
			record("debug", message, fields)
		end,
		Info = function(_self, message, fields)
			record("info", message, fields)
		end,
		Warn = function(_self, message, fields)
			record("warn", message, fields)
		end,
		Error = function(_self, message, fields)
			record("error", message, fields)
		end,
	}, entries
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

	test("new wallet startup balance persists once across reload", function()
		local memory = MemoryStorage.new()
		local player = { UserId = 303 } :: any

		local function makeWallet(startingCoins: number)
			local wallet = WalletModule.new({
				Queue = function()
					return true
				end,
			}, {
				GetRequired = function(_self, configId)
					assertEqual(configId, "Wallet")
					return {
						StartingBalances = {
							Coins = startingCoins,
							Gems = 2,
						},
					}
				end,
			})
			wallet:Initialize()
			return wallet
		end

		local firstWallet = makeWallet(25)
		local first = ServerSaveController.new({
			Id = "wallet_startup",
			Providers = { firstWallet },
			Storage = SessionLockingStorage.new(memory, { StaleLockSeconds = 1_800 }),
			KeyResolver = function()
				return "WalletStartup_303"
			end,
		})
		assertTrue(first:Load(player).Ok, "new wallet load failed")
		assertEqual(firstWallet:GetBalance(player, "Coins"), 25)
		assertEqual(firstWallet:GetMemento(player).IsInitialized, true)
		assertTrue(first:Close(player, true).Ok, "new wallet close failed")
		first:Destroy(false)

		local persisted = memory:Read("WalletStartup_303")
		assertEqual(persisted.Providers.Wallet.Version, 2)
		assertEqual(persisted.Providers.Wallet.Data.IsInitialized, true)
		assertEqual(persisted.Providers.Wallet.Data.Coins, 25)

		local secondWallet = makeWallet(999)
		local second = ServerSaveController.new({
			Id = "wallet_reload",
			Providers = { secondWallet },
			Storage = SessionLockingStorage.new(memory, { StaleLockSeconds = 1_800 }),
			KeyResolver = function()
				return "WalletStartup_303"
			end,
		})
		assertTrue(second:Load(player).Ok, "persisted wallet reload failed")
		assertEqual(secondWallet:GetBalance(player, "Coins"), 25, "startup grant repeated on reload")
		assertTrue(second:Close(player, true).Ok, "persisted wallet close failed")
		second:Destroy(false)
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
		assertEqual(
			takeover.Created,
			true,
			"stale takeover forgot that the abandoned lock had created an unsaved profile"
		)
		assertEqual(first:Save("Shared", takeover.Document).Code, "LockLost")
		assertTrue(second:Release("Shared").Ok, "takeover release failed")
	end)

	test("session ownership follows only the final UpdateAsync transform", function()
		local function makeReplayBase(replayConflict: boolean)
			local base = {
				ReplayConflict = replayConflict,
				Stored = nil,
			}
			function base:Update(_key, transform)
				local candidate = transform(self.Stored)
				if self.ReplayConflict then
					local finalCandidate = transform({
						FormatVersion = 1,
						Revision = 0,
						Providers = {},
						Metadata = {},
						Session = {
							LockId = "foreign-live-lock",
							LastHeartbeatAt = os.time(),
						},
					})
					if finalCandidate ~= nil then
						self.Stored = finalCandidate
					end
					return {
						Ok = true,
						Value = finalCandidate,
					}
				end
				if candidate ~= nil then
					self.Stored = candidate
				end
				return {
					Ok = true,
					Value = candidate,
				}
			end
			return base
		end

		local blockedBase = makeReplayBase(true)
		local blocked = SessionLockingStorage.new(blockedBase, { StaleLockSeconds = 1_800 })
		assertEqual(blocked:Load("Replay").Code, "SessionLocked")
		assertEqual(blocked:HasLock("Replay"), false)

		local replayExistingBase = {
			FirstUpdate = true,
			Stored = nil,
		}
		function replayExistingBase:Update(_key, transform)
			if self.FirstUpdate then
				self.FirstUpdate = false
				transform(nil)
				self.Stored = transform({
					FormatVersion = 1,
					Revision = 0,
					Providers = {},
					Metadata = {},
					Session = nil,
				})
			else
				local candidate = transform(self.Stored)
				if candidate ~= nil then
					self.Stored = candidate
				end
			end
			return {
				Ok = true,
				Value = self.Stored,
			}
		end
		local replayExisting = SessionLockingStorage.new(replayExistingBase, {
			StaleLockSeconds = 1_800,
		})
		local replayExistingLoad = replayExisting:Load("ReplayExisting")
		assertTrue(replayExistingLoad.Ok, "final existing candidate did not acquire its lock")
		assertEqual(
			replayExistingLoad.Created,
			false,
			"an earlier nil callback misclassified the final existing document as new"
		)
		assertTrue(replayExisting:Release("ReplayExisting").Ok, "replayed existing lock release failed")

		local retryCreatedBase = {
			ReplayNextUpdate = true,
			Stored = nil,
		}
		function retryCreatedBase:Update(_key, transform)
			local candidate = transform(self.Stored)
			if self.ReplayNextUpdate then
				self.ReplayNextUpdate = false
				-- Simulate an UpdateAsync attempt that committed but lost its
				-- response, followed by a whole-operation retry with the same lock.
				self.Stored = candidate
				candidate = transform(self.Stored)
			end
			if candidate ~= nil then
				self.Stored = candidate
			end
			return {
				Ok = true,
				Value = candidate,
			}
		end
		local retryCreated = SessionLockingStorage.new(retryCreatedBase, {
			StaleLockSeconds = 1_800,
		})
		local retryCreatedLoad = retryCreated:Load("RetryCreated")
		assertTrue(retryCreatedLoad.Ok, "retried new-profile lock acquisition failed")
		assertEqual(
			retryCreatedLoad.Created,
			true,
			"a whole-operation retry forgot that this lock created the profile"
		)
		assertTrue(retryCreated:Release("RetryCreated").Ok, "retried new-profile lock release failed")

		local retryTakeoverBase = {
			ReplayNextUpdate = true,
			Stored = {
				FormatVersion = 1,
				Revision = 0,
				Providers = {},
				Metadata = {},
				Session = {
					LockId = "stale-foreign-lock",
					LastHeartbeatAt = os.time() - 1_801,
				},
			},
		}
		function retryTakeoverBase:Update(_key, transform)
			local candidate = transform(self.Stored)
			if self.ReplayNextUpdate then
				self.ReplayNextUpdate = false
				self.Stored = candidate
				candidate = transform(self.Stored)
			end
			if candidate ~= nil then
				self.Stored = candidate
			end
			return {
				Ok = true,
				Value = candidate,
			}
		end
		local retryTakeover = SessionLockingStorage.new(retryTakeoverBase, {
			StaleLockSeconds = 1_800,
		})
		local retryTakeoverLoad = retryTakeover:Load("RetryTakeover")
		assertTrue(retryTakeoverLoad.Ok, "retried stale takeover failed")
		assertEqual(
			retryTakeoverLoad.StaleTakeover,
			true,
			"a whole-operation retry forgot the stale takeover classification"
		)
		assertTrue(retryTakeover:Release("RetryTakeover").Ok, "retried stale takeover release failed")

		local saveBase = makeReplayBase(false)
		local saveOwner = SessionLockingStorage.new(saveBase, { StaleLockSeconds = 1_800 })
		local loaded = saveOwner:Load("Replay")
		assertTrue(loaded.Ok, "save replay owner did not acquire initial lock")
		saveBase.ReplayConflict = true
		assertEqual(saveOwner:Save("Replay", loaded.Document).Code, "LockLost")
		assertEqual(saveOwner:HasLock("Replay"), false)

		local refreshBase = makeReplayBase(false)
		local refreshOwner = SessionLockingStorage.new(refreshBase, { StaleLockSeconds = 1_800 })
		assertTrue(refreshOwner:Load("Replay").Ok, "refresh replay owner did not acquire initial lock")
		refreshBase.ReplayConflict = true
		assertEqual(refreshOwner:Refresh("Replay").Code, "LockLost")
		assertEqual(refreshOwner:HasLock("Replay"), false)
	end)

	test("lock refresh preserves new-profile classification until first save", function()
		local memory = MemoryStorage.new()
		local firstOwner = SessionLockingStorage.new(memory, {
			StaleLockSeconds = 0,
		})
		local secondOwner = SessionLockingStorage.new(memory, {
			StaleLockSeconds = 0,
		})

		local firstLoad = firstOwner:Load("RefreshBeforeFirstSave")
		assertTrue(firstLoad.Ok, "first owner did not acquire the new profile")
		assertEqual(firstLoad.Created, true)
		assertTrue(firstOwner:Refresh("RefreshBeforeFirstSave").Ok, "new-profile refresh failed")
		assertEqual(
			memory:Read("RefreshBeforeFirstSave").Session.AcquiredFromNewProfile,
			true,
			"refresh discarded the authoritative new-profile marker"
		)

		local takeover = secondOwner:Load("RefreshBeforeFirstSave")
		assertTrue(takeover.Ok, "stale takeover after refresh failed")
		assertEqual(takeover.StaleTakeover, true)
		assertEqual(
			takeover.Created,
			true,
			"takeover misclassified a refreshed but never-saved new profile"
		)

		assertTrue(firstOwner:Release("RefreshBeforeFirstSave").Ok, "old owner cleanup failed")
		assertTrue(
			secondOwner:Save("RefreshBeforeFirstSave", takeover.Document).Ok,
			"takeover owner could not complete the first profile save"
		)
		local savedSession = memory:Read("RefreshBeforeFirstSave").Session
		assertEqual(savedSession.AcquiredFromNewProfile, nil, "first save retained the new-profile marker")
		assertEqual(savedSession.AcquiredByStaleTakeover, nil, "first save retained the takeover marker")
		assertTrue(secondOwner:Release("RefreshBeforeFirstSave").Ok, "takeover owner cleanup failed")
	end)

	test("lock release preserves never-saved new-profile classification", function()
		local memory = MemoryStorage.new()
		local firstOwner = SessionLockingStorage.new(memory, {
			StaleLockSeconds = 1_800,
		})
		local secondOwner = SessionLockingStorage.new(memory, {
			StaleLockSeconds = 1_800,
		})

		assertEqual(firstOwner:Load("ReleaseBeforeFirstSave").Created, true)
		assertTrue(firstOwner:Release("ReleaseBeforeFirstSave").Ok, "new-profile release failed")
		local releasedSession = memory:Read("ReleaseBeforeFirstSave").Session
		assertEqual(releasedSession.LockId, nil, "release retained active lock ownership")
		assertEqual(
			releasedSession.AcquiredFromNewProfile,
			true,
			"release discarded the never-saved profile marker"
		)

		local reacquired = secondOwner:Load("ReleaseBeforeFirstSave")
		assertTrue(reacquired.Ok, "released new profile could not be reacquired immediately")
		assertEqual(reacquired.Created, true)
		assertEqual(reacquired.StaleTakeover, false)
		assertTrue(secondOwner:Release("ReleaseBeforeFirstSave").Ok, "reacquired profile cleanup failed")
	end)

	test("session locking rejects a corrupted document root without replacing it", function()
		local base = {
			Stored = "corrupted-profile",
		}
		function base:Update(_key, transform)
			local candidate = transform(self.Stored)
			if candidate ~= nil then
				self.Stored = candidate
			end
			return {
				Ok = true,
				Value = candidate,
			}
		end

		local storage = SessionLockingStorage.new(base, { StaleLockSeconds = 1_800 })
		local result = storage:Load("Corrupt")
		assertEqual(result.Ok, false)
		assertEqual(result.Code, "InvalidDocument")
		assertEqual(base.Stored, "corrupted-profile")
		assertEqual(storage:HasLock("Corrupt"), false)
	end)

	test("concurrent ForceSave callers receive the active save failure", function()
		local saveStarted = false
		local releaseSave = false
		local saveCalls = 0
		local storage = {
			Load = function()
				return {
					Ok = true,
					Document = {
						FormatVersion = 1,
						Revision = 0,
						Providers = {},
						Metadata = {
							CreatedAt = os.time(),
							UpdatedAt = os.time(),
						},
					},
				}
			end,
			Save = function()
				saveCalls += 1
				saveStarted = true
				while not releaseSave do
					task.wait()
				end
				return {
					Ok = false,
					Code = "InjectedFailure",
					Error = "expected",
				}
			end,
			Release = function()
				return { Ok = true }
			end,
		}
		local provider = makeServerProvider("SingleFlight", nil)
		local controller = ServerSaveController.new({
			Id = "single_flight",
			Providers = { provider },
			Storage = storage,
			KeyResolver = function()
				return "SingleFlight"
			end,
		})
		local player = { UserId = 4_211 } :: any
		assertTrue(controller:Load(player).Ok, "single-flight controller load failed")

		local firstResult = nil
		local secondResult = nil
		task.spawn(function()
			firstResult = controller:ForceSave(player, "First")
		end)
		while not saveStarted do
			task.wait()
		end
		task.spawn(function()
			secondResult = controller:ForceSave(player, "Second")
		end)
		task.wait()
		releaseSave = true
		while firstResult == nil or secondResult == nil do
			task.wait()
		end

		assertEqual(firstResult.Ok, false)
		assertEqual(secondResult.Ok, false)
		assertEqual(firstResult.Code, "InjectedFailure")
		assertEqual(secondResult.Code, "InjectedFailure")
		assertEqual(saveCalls, 1)
		controller:Destroy(false)
	end)

	test("player close cancels an in-flight load without applying provider state", function()
		local loadStarted = false
		local releaseLoad = false
		local releaseCalls = 0
		local storage = {
			Load = function()
				loadStarted = true
				while not releaseLoad do
					task.wait()
				end
				return {
					Ok = true,
					Document = {
						FormatVersion = 1,
						Revision = 0,
						Providers = {},
						Metadata = {
							CreatedAt = os.time(),
							UpdatedAt = os.time(),
						},
					},
				}
			end,
			Save = function()
				error("a cancelled load must not save")
			end,
			Release = function()
				releaseCalls += 1
				return { Ok = true }
			end,
		}
		local provider = makeServerProvider("LoadCloseRace", nil)
		local controller = ServerSaveController.new({
			Id = "load_close_race",
			Providers = { provider },
			Storage = storage,
			KeyResolver = function()
				return "LoadCloseRace"
			end,
		})
		local player = { UserId = 4_214 } :: any
		local loadResult = nil
		local closeResult = nil
		task.spawn(function()
			loadResult = controller:Load(player)
		end)
		while not loadStarted do
			task.wait()
		end
		task.spawn(function()
			closeResult = controller:Close(player, true)
		end)
		task.wait()
		assertEqual(loadResult, nil, "load unexpectedly completed before storage resumed")
		assertEqual(closeResult, nil, "close must wait for in-flight lock acquisition")

		releaseLoad = true
		while loadResult == nil or closeResult == nil do
			task.wait()
		end
		assertEqual(loadResult.Ok, false)
		assertEqual(loadResult.Code, "LoadCancelled")
		assertTrue(closeResult.Ok, "close failed after cancelling an in-flight load")
		assertTrue(releaseCalls >= 1, "cancelled load did not release its acquired lock")
		assertEqual(provider:GetValue(player), nil, "cancelled load applied provider runtime state")
		assertEqual(controller:GetState(player), "NotLoaded")
		controller:Destroy(false)
	end)

	test("cancelled load surfaces a throwing lock release and lets close retry", function()
		local loadStarted = false
		local releaseLoad = false
		local releaseCalls = 0
		local storage = {
			Load = function()
				loadStarted = true
				while not releaseLoad do
					task.wait()
				end
				return {
					Ok = true,
					Document = {
						FormatVersion = 1,
						Revision = 0,
						Providers = {},
						Metadata = {
							CreatedAt = os.time(),
							UpdatedAt = os.time(),
						},
					},
				}
			end,
			Save = function()
				error("a cancelled load must not save")
			end,
			Release = function()
				releaseCalls += 1
				if releaseCalls == 1 then
					error("injected cancelled-load release failure")
				end
				return { Ok = true }
			end,
		}
		local provider = makeServerProvider("LoadCloseReleaseRetry", nil)
		local controller = ServerSaveController.new({
			Id = "load_close_release_retry",
			Providers = { provider },
			Storage = storage,
			KeyResolver = function()
				return "LoadCloseReleaseRetry"
			end,
		})
		local player = { UserId = 4_215 } :: any
		local loadResult = nil
		local closeResult = nil
		task.spawn(function()
			loadResult = controller:Load(player)
		end)
		while not loadStarted do
			task.wait()
		end
		task.spawn(function()
			closeResult = controller:Close(player, true)
		end)
		task.wait()

		releaseLoad = true
		while loadResult == nil or closeResult == nil do
			task.wait()
		end
		assertEqual(loadResult.Ok, false)
		assertEqual(loadResult.Code, "LoadCancelled")
		assertEqual(loadResult.LockReleaseOk, false)
		assertEqual(loadResult.LockReleaseCode, "ReleaseFailed")
		assertTrue(
			string.find(loadResult.Error, "injected cancelled-load release failure", 1, true) ~= nil,
			"cancelled-load release exception was not surfaced"
		)
		assertTrue(closeResult.Ok, "close did not retry lock release after cancellation failure")
		assertEqual(releaseCalls, 2)
		assertEqual(provider:GetValue(player), nil, "cancelled load applied provider runtime state")
		assertEqual(controller:GetState(player), "NotLoaded")
		controller:Destroy(false)
	end)

	test("concurrent player closes share one close operation", function()
		local saveStarted = false
		local releaseSave = false
		local releaseCalls = 0
		local storage = {
			Load = function()
				return {
					Ok = true,
					Document = {
						FormatVersion = 1,
						Revision = 0,
						Providers = {},
						Metadata = {
							CreatedAt = os.time(),
							UpdatedAt = os.time(),
						},
					},
				}
			end,
			Save = function()
				saveStarted = true
				while not releaseSave do
					task.wait()
				end
				return { Ok = true }
			end,
			Release = function()
				releaseCalls += 1
				return { Ok = true }
			end,
		}
		local provider = makeServerProvider("ConcurrentClose", nil)
		local controller = ServerSaveController.new({
			Id = "concurrent_close",
			Providers = { provider },
			Storage = storage,
			KeyResolver = function()
				return "ConcurrentClose"
			end,
		})
		local player = { UserId = 4_215 } :: any
		assertTrue(controller:Load(player).Ok, "concurrent-close controller load failed")

		local closedEvents = 0
		controller.PlayerClosed:Connect(function(closedPlayer)
			assertEqual(closedPlayer, player)
			closedEvents += 1
		end)
		local firstResult = nil
		local secondResult = nil
		task.spawn(function()
			firstResult = controller:Close(player, true)
		end)
		while not saveStarted do
			task.wait()
		end
		task.spawn(function()
			secondResult = controller:Close(player, true)
		end)
		task.wait()
		releaseSave = true
		while firstResult == nil or secondResult == nil do
			task.wait()
		end
		task.wait()

		assertTrue(firstResult.Ok and secondResult.Ok, "concurrent close did not share success")
		assertEqual(releaseCalls, 1, "concurrent close released storage more than once")
		assertEqual(closedEvents, 1, "concurrent close emitted PlayerClosed more than once")
		assertEqual(controller:GetState(player), "NotLoaded")
		controller:Destroy(false)
	end)

	test("ForceSave captures a provider dirtied while persistence is in flight", function()
		local values = {}
		local provider = {
			Id = "SaveRace",
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
			Run = function() end,
			Stop = function(_self, player)
				values[player] = nil
			end,
		}

		local saveStarted = false
		local releaseFirstSave = false
		local savedValues = {}
		local storage = {
			Load = function()
				return {
					Ok = true,
					Document = {
						FormatVersion = 1,
						Revision = 0,
						Providers = {},
						Metadata = {
							CreatedAt = os.time(),
							UpdatedAt = os.time(),
						},
					},
				}
			end,
			Save = function(_self, _key, document)
				table.insert(savedValues, document.Providers.SaveRace.Data.Value)
				if #savedValues == 1 then
					saveStarted = true
					while not releaseFirstSave do
						task.wait()
					end
				end
				return { Ok = true }
			end,
			Release = function()
				return { Ok = true }
			end,
		}
		local controller = ServerSaveController.new({
			Id = "save_race",
			Providers = { provider },
			Storage = storage,
			KeyResolver = function()
				return "SaveRace"
			end,
		})
		local player = { UserId = 4_213 } :: any
		assertTrue(controller:Load(player).Ok, "save-race controller load failed")

		local saveResult = nil
		task.spawn(function()
			saveResult = controller:ForceSave(player, "Race")
		end)
		while not saveStarted do
			task.wait()
		end

		values[player] = { Value = 2 }
		controller:MarkDirty(player, provider.Id)
		releaseFirstSave = true
		while saveResult == nil do
			task.wait()
		end

		assertTrue(saveResult.Ok, "save-race ForceSave failed")
		assertEqual(#savedValues, 2, "dirty state created during Save was not persisted before success")
		assertEqual(savedValues[1], 1)
		assertEqual(savedValues[2], 2)
		controller:Destroy(false)
	end)

	test("failed dirty capture retains the complete provider set", function()
		local captureControl = {
			FailB = true,
			ThrowValidationC = false,
		}
		local function makeCaptureProvider(id: string)
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
					if id == "C" and captureControl.ThrowValidationC then
						error(`validation failed for {id}`)
					end
					return typeof(value) == "table" and typeof(value.Value) == "number", value, nil
				end,
				SetMemento = function(_self, player, value)
					values[player] = value
				end,
				GetMemento = function(_self, player)
					if id == "B" and captureControl.FailB then
						error(`capture failed for {id}`)
					end
					return values[player]
				end,
				Run = function() end,
				Stop = function(_self, player)
					values[player] = nil
				end,
				SetValue = function(_self, player, value)
					values[player] = { Value = value }
				end,
			}
		end

		local providers = {
			makeCaptureProvider("A"),
			makeCaptureProvider("B"),
			makeCaptureProvider("C"),
			makeCaptureProvider("D"),
		}
		local storage = SessionLockingStorage.new(MemoryStorage.new(), { StaleLockSeconds = 1_800 })
		local controller = ServerSaveController.new({
			Id = "dirty_capture",
			Providers = providers,
			Storage = storage,
			KeyResolver = function()
				return "DirtyCapture"
			end,
		})
		local player = { UserId = 4_212 } :: any
		assertTrue(controller:Load(player).Ok, "dirty capture controller load failed")
		for index, provider in providers do
			provider:SetValue(player, index + 10)
			controller:MarkDirty(player, provider.Id)
		end

		local captured = controller:FlushDirty(player)
		assertEqual(captured, false)
		captureControl.FailB = false
		local retried = controller:FlushDirty(player)
		assertEqual(retried, true)
		local snapshot = controller:BuildSnapshot(player)
		for index, provider in providers do
			assertEqual(
				snapshot.Providers[provider.Id].Data.Value,
				index + 10,
				`dirty provider {provider.Id} was lost after retry`
			)
		end

		for index, provider in providers do
			provider:SetValue(player, index + 20)
			controller:MarkDirty(player, provider.Id)
		end
		captureControl.ThrowValidationC = true
		assertEqual(controller:FlushDirty(player), false)
		captureControl.ThrowValidationC = false
		assertEqual(controller:FlushDirty(player), true)
		local validationRetrySnapshot = controller:BuildSnapshot(player)
		for index, provider in providers do
			assertEqual(
				validationRetrySnapshot.Providers[provider.Id].Data.Value,
				index + 20,
				`dirty provider {provider.Id} was lost after validation exception`
			)
		end
		controller:Destroy(false)
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

	test("save serializer rejects unsafe JSON shapes and measures encoded bytes", function()
		local mixedValid, mixedIssues = SaveSerialize.validate({
			[1] = "array",
			Named = "dictionary",
		})
		assertEqual(mixedValid, false)
		assertEqual(mixedIssues[1].Reason, "mixed_table_keys")

		local sparseValid, sparseIssues = SaveSerialize.validate({
			[1] = "first",
			[3] = "third",
		})
		assertEqual(sparseValid, false)
		assertEqual(sparseIssues[1].Reason, "sparse_array")

		local utf8Valid, utf8Issues = SaveSerialize.validate(string.char(255))
		assertEqual(utf8Valid, false)
		assertEqual(utf8Issues[1].Reason, "invalid_utf8")

		local document = {
			Message = string.rep("ю", 64),
		}
		local measured, bytes = SaveSerialize.measureEncodedSize(document)
		assertTrue(measured, "valid save document must be JSON encodable")
		local encoded = game:GetService("HttpService"):JSONEncode(document)
		assertEqual(bytes, #encoded, "save limit must use actual JSON byte count")
	end)

	test("wallet client rejects balances outside the safe integer range", function()
		local wallet = WalletClient.new({
			RegisterHandler = function() end,
		})
		local valid = wallet:ValidateMemento({
			Coins = 9_007_199_254_740_992,
			Gems = 0,
		})
		assertEqual(valid, false)
	end)

	test("communication serializer rejects non-finite compounds and unsafe table shapes", function()
		local vectorValid, vectorIssues = CommunicationSerialize.validate({
			Impulse = Vector3.new(0 / 0, 2, 3),
		})
		assertEqual(vectorValid, false)
		assertEqual(vectorIssues[1].Reason, "non_finite_component:1")

		local mixedValid, mixedIssues = CommunicationSerialize.validate({
			[1] = "array",
			Named = "dictionary",
		})
		assertEqual(mixedValid, false)
		assertEqual(mixedIssues[1].Reason, "mixed_table_keys")

		local sparseValid, sparseIssues = CommunicationSerialize.validate({
			[1] = "first",
			[3] = "third",
		})
		assertEqual(sparseValid, false)
		assertEqual(sparseIssues[1].Reason, "sparse_array")

		local metatableValid, metatableIssues = CommunicationSerialize.validate(setmetatable({}, {}))
		assertEqual(metatableValid, false)
		assertEqual(metatableIssues[1].Reason, "table_metatable")
	end)

	test("communication serializer stops at configured work and byte limits", function()
		local nodeValid, nodeIssues = CommunicationSerialize.validate({
			A = {
				B = {
					C = true,
				},
			},
		}, {
			MaxNodes = 3,
		})
		assertEqual(nodeValid, false)
		assertEqual(nodeIssues[1].Reason, "maximum_nodes_exceeded")

		local byteValid, byteIssues = CommunicationSerialize.validate(string.rep("x", 100), {
			MaxBytes = 16,
		})
		assertEqual(byteValid, false)
		assertEqual(byteIssues[1].Reason, "maximum_estimated_bytes_exceeded")

		local invalidKeys = {}
		for index = 1, 100 do
			invalidKeys[-index] = true
		end
		local invalidKeyValid, invalidKeyIssues = CommunicationSerialize.validate(invalidKeys, {
			MaxNodes = 4,
			MaxIssues = 4,
		})
		assertEqual(invalidKeyValid, false)
		local reachedNodeLimit = false
		for _, issue in invalidKeyIssues do
			if issue.Reason == "maximum_nodes_exceeded" then
				reachedNodeLimit = true
				break
			end
		end
		assertTrue(reachedNodeLimit, "invalid keys must still consume the inspection work budget")
	end)

	test("token bucket permits configured burst and refills continuously", function()
		local now = 0
		local bucket = TokenBucket.new(10, 4, function()
			return now
		end)

		for _ = 1, 4 do
			assertEqual(bucket:TryConsume(1), true)
		end
		assertEqual(bucket:TryConsume(1), false, "burst capacity exceeded")

		now = 0.2
		assertEqual(bucket:TryConsume(2), true, "continuous refill did not restore budget")
		assertEqual(bucket:TryConsume(1), false)

		now = 0.4
		assertEqual(bucket:TryConsume(2), true)
		assertEqual(bucket:TryConsume(1), false, "bucket must not double-burst at a time boundary")
	end)

	test("players own independent communication buckets", function()
		local now = 0
		local server = CommunicationServer.new({
			PlayersModule = {
				PlayerRemoving = Signal.new(),
			},
			Clock = function()
				return now
			end,
		})
		local firstPlayer = { UserId = 3961 } :: any
		local secondPlayer = { UserId = 3962 } :: any
		local handled = {} :: { [any]: number }
		server:RegisterHandler("Integration.Rate", function(payload)
			return true, payload, nil
		end, function(player)
			handled[player] = (handled[player] or 0) + 1
		end)

		for sequence = 1, CommunicationConfig.BatchInvocationBurst do
			server:ReceiveBatch(firstPlayer, {
				Sequence = sequence,
				Messages = {
					{
						Type = "Integration.Rate",
						Payload = {},
					},
				},
			})
		end
		server:ReceiveBatch(firstPlayer, {
			Sequence = CommunicationConfig.BatchInvocationBurst + 1,
			Messages = {},
		})
		server:ReceiveBatch(secondPlayer, {
			Sequence = 1,
			Messages = {
				{
					Type = "Integration.Rate",
					Payload = {},
				},
			},
		})
		assertEqual(handled[firstPlayer], CommunicationConfig.BatchInvocationBurst)
		assertEqual(handled[secondPlayer], 1)

		now = 1 / CommunicationConfig.MaxBatchInvocationsPerSecond
		server:ReceiveBatch(firstPlayer, {
			Sequence = CommunicationConfig.BatchInvocationBurst + 1,
			Messages = {
				{
					Type = "Integration.Rate",
					Payload = {},
				},
			},
		})
		assertEqual(handled[firstPlayer], CommunicationConfig.BatchInvocationBurst + 1, "player bucket did not refill")
	end)

	test("server rejects dictionary batches without advancing sequence", function()
		local logger = makeLogger()
		local server = CommunicationServer.new({
			PlayersModule = {
				PlayerRemoving = Signal.new(),
			},
			Logger = logger,
		})
		local player = { UserId = 397 } :: any
		local handled = 0
		server:RegisterHandler("Integration.Dense", function(payload)
			return typeof(payload) == "table", payload, nil
		end, function()
			handled += 1
		end)

		server:ReceiveBatch(player, {
			Sequence = 1,
			Messages = {
				First = {
					Type = "Integration.Dense",
					Payload = {},
				},
			},
		})
		assertEqual(handled, 0)

		server:ReceiveBatch(player, {
			Sequence = 1,
			Messages = {
				{
					Type = "Integration.Dense",
					Payload = {},
				},
			},
		})
		assertEqual(handled, 1)
	end)

	test("malformed communication calls consume invocation budgets and deduplicate logs", function()
		local now = 0
		local logger, entries = makeLogger()
		local server = CommunicationServer.new({
			PlayersModule = {
				PlayerRemoving = Signal.new(),
			},
			Logger = logger,
			Clock = function()
				return now
			end,
		})
		local player = { UserId = 398 } :: any

		for _ = 1, CommunicationConfig.BatchInvocationBurst + 5 do
			server:ReceiveBatch(player, "invalid")
		end
		assertEqual(#entries, 2, "invalid batch and rate-limit logs must each be cooldown-bounded")

		local lastResponse
		for _ = 1, CommunicationConfig.RequestInvocationBurst + 1 do
			lastResponse = server:HandleRequest(player, "invalid")
		end
		assertEqual(lastResponse.Code, "RateLimited")

		now = 1
		local resetResponse = server:HandleRequest(player, "invalid")
		assertEqual(resetResponse.Code, "Unavailable")
	end)

	test("client pacing retains unsent batches and advances sequence only after send", function()
		local now = 0
		local batches = {}
		local client = CommunicationClient.new(nil, function()
			return now
		end, nil, {
			ClientToServer = {
				FireServer = function(_self, batch)
					table.insert(batches, batch)
				end,
			},
		})

		for index = 1, CommunicationConfig.BatchInvocationBurst do
			assertEqual(client:Queue("Integration.Paced", { Value = index }), true)
			client:Flush()
		end
		assertEqual(#batches, CommunicationConfig.BatchInvocationBurst)
		assertEqual(client:Queue("Integration.Paced", { Value = 1 }), true)
		client:Flush()
		assertEqual(#batches, CommunicationConfig.BatchInvocationBurst)
		assertEqual(client:GetQueueStats().Messages, 1)
		assertEqual(client:GetQueueStats().OutgoingSequence, CommunicationConfig.BatchInvocationBurst)

		now = 1 / CommunicationConfig.MaxBatchInvocationsPerSecond
		client:Flush()
		assertEqual(#batches, CommunicationConfig.BatchInvocationBurst + 1)
		assertEqual(client:GetQueueStats().Messages, 0)
		assertEqual(client:GetQueueStats().OutgoingSequence, CommunicationConfig.BatchInvocationBurst + 1)
		assertEqual(batches[#batches].Sequence, CommunicationConfig.BatchInvocationBurst + 1)
	end)

	test("message validator failures are contained and force resync", function()
		local logger = makeLogger()
		local server = CommunicationServer.new({
			PlayersModule = {
				PlayerRemoving = Signal.new(),
			},
			Logger = logger,
		})
		local player = { UserId = 3981 } :: any
		server:RegisterHandler("Integration.ThrowingValidator", function()
			error("validator failed")
		end, function() end)

		local callOk = pcall(function()
			server:ReceiveBatch(player, {
				Sequence = 1,
				Messages = {
					{
						Type = "Integration.ThrowingValidator",
						Payload = {},
					},
				},
			})
		end)
		assertTrue(callOk, "validator failure must not escape the communication boundary")
		assertEqual(server:GetQueueStats(player).ResyncRequired, true)
	end)

	test("snapshot guard limits concurrency and request frequency", function()
		local now = 10
		local server = CommunicationServer.new({
			PlayersModule = {
				PlayerRemoving = Signal.new(),
			},
			Clock = function()
				return now
			end,
		})
		local player = { UserId = 3982 } :: any

		local firstAllowed = server:TryBeginSnapshotRequest(player)
		assertEqual(firstAllowed, true)
		local concurrentAllowed, concurrentCode = server:TryBeginSnapshotRequest(player)
		assertEqual(concurrentAllowed, false)
		assertEqual(concurrentCode, "Busy")

		server:EndSnapshotRequest(player)
		local immediateAllowed, immediateCode = server:TryBeginSnapshotRequest(player)
		assertEqual(immediateAllowed, false)
		assertEqual(immediateCode, "RateLimited")

		now += CommunicationConfig.SnapshotRequestCooldownSeconds
		assertEqual(server:TryBeginSnapshotRequest(player), true)
		server:EndSnapshotRequest(player)
	end)

	test("snapshot network cap is checked before epoch mutation and guard always releases", function()
		local logger, entries = makeLogger()
		local inFlight = false
		local epoch = 7
		local beginCalls = 0
		local endCalls = 0
		local communication = {
			TryBeginSnapshotRequest = function()
				if inFlight then
					return false, "Busy"
				end
				inFlight = true
				return true, nil
			end,
			EndSnapshotRequest = function()
				inFlight = false
				endCalls += 1
			end,
			GetNextSnapshotEpoch = function()
				return epoch + 1
			end,
			BeginSnapshot = function()
				beginCalls += 1
				epoch += 1
				return epoch
			end,
		}
		local snapshotValue: any = string.rep("x", CommunicationConfig.MaxSnapshotNetworkEstimatedBytes)
		local controller = {
			IsLoaded = function()
				return true
			end,
			GetState = function()
				return "Loaded"
			end,
			BuildSnapshot = function()
				if snapshotValue == "Throw" then
					error("snapshot build failed")
				end
				return {
					Value = snapshotValue,
				}
			end,
		}
		local command = GlobalSaveInitializationCommand.new({
			Communication = communication,
			Logger = logger,
		} :: any)
		local player = { UserId = 3983 } :: any

		local oversized = command:HandleSnapshotRequest(controller, player, 1)
		assertEqual(oversized.Ok, false)
		assertEqual(oversized.Code, "SnapshotTooLarge")
		assertEqual(beginCalls, 0, "oversized snapshot must not begin a new epoch")
		assertEqual(epoch, 7)
		assertEqual(inFlight, false)
		assertEqual(endCalls, 1)
		assertEqual(#entries, 1, "oversized snapshot must emit one bounded structured log")
		assertEqual(entries[1].Message, "snapshot_response_rejected")

		snapshotValue = "Normal"
		local normal = command:HandleSnapshotRequest(controller, player, 1)
		assertEqual(normal.Ok, true)
		assertEqual(normal.CommunicationEpoch, 8)
		assertEqual(beginCalls, 1)
		assertEqual(inFlight, false)

		snapshotValue = "Throw"
		local failed = command:HandleSnapshotRequest(controller, player, 1)
		assertEqual(failed.Ok, false)
		assertEqual(failed.Code, "InternalError")
		assertEqual(inFlight, false, "snapshot guard remained in flight after error")
		assertEqual(endCalls, 3)
	end)

	test("bounded communication request validates type and response", function()
		local server = CommunicationServer.new({
			PlayersModule = {
				PlayerRemoving = Signal.new(),
			},
		})
		server:RegisterRequestHandler("Integration.Read", function(payload)
			if typeof(payload) ~= "table" or typeof(payload.Id) ~= "string" then
				return false, nil, "invalid"
			end
			return true, { Id = payload.Id }, nil
		end, function(_player, payload)
			return true, {
				Id = payload.Id,
				Value = 42,
			}, nil
		end)
		local player = { UserId = 399 } :: any

		local response = server:HandleRequest(player, {
			Type = "Integration.Read",
			Payload = { Id = "Allowed" },
		})
		assertEqual(response.Ok, true)
		assertEqual(response.Payload.Id, "Allowed")
		assertEqual(response.Payload.Value, 42)

		local invalid = server:HandleRequest(player, {
			Type = "Integration.Read",
			Payload = { Id = 5 },
		})
		assertEqual(invalid.Ok, false)
		assertEqual(invalid.Code, "Unavailable")

		local unknown = server:HandleRequest(player, {
			Type = "Integration.Unknown",
			Payload = {},
		})
		assertEqual(unknown.Ok, false)
		assertEqual(unknown.Code, "Unavailable")

		server:RegisterRequestHandler("Integration.Failure", function(payload)
			return true, payload, nil
		end, function()
			return false, nil, string.rep("x", CommunicationConfig.MaxSingleMessageEstimatedBytes)
		end)
		local oversizedFailure = server:HandleRequest(player, {
			Type = "Integration.Failure",
			Payload = {},
		})
		assertEqual(oversizedFailure.Ok, false)
		assertEqual(oversizedFailure.Code, "InternalError")
	end)

	test("server batch flush preserves Vector3 payloads", function()
		local capturedPlayer = nil
		local capturedBatch = nil
		local server = CommunicationServer.new({
			PlayersModule = {
				PlayerRemoving = Signal.new(),
			},
			Transport = {
				ClientToServer = {},
				ServerToClient = {
					FireClient = function(_self, targetPlayer, batch)
						capturedPlayer = targetPlayer
						capturedBatch = batch
					end,
				},
				Request = {},
			},
		})
		local player = { UserId = 400 } :: any

		local epoch = server:BeginSnapshot(player)
		assertEqual(server:SetClientReady(player, epoch + 1), false)
		assertEqual(server:SetClientReady(player, epoch), true)
		local queued = server:Queue(player, "Integration.Vector3", {
			Impulse = Vector3.new(1, 2, 3),
			Direction = Vector3.yAxis,
		}, nil, {
			Priority = CommunicationProtocol.Priorities.Critical,
		})
		server:Flush()

		assertEqual(queued, true)
		assertEqual(capturedPlayer, player)
		assertTrue(capturedBatch ~= nil, "flush did not emit a batch")
		assertEqual(typeof(capturedBatch.Messages[1].Payload.Impulse), "Vector3")
		assertEqual(capturedBatch.Messages[1].Payload.Impulse, Vector3.new(1, 2, 3))
		assertEqual(server:GetQueueStats(player).Messages, 0)
	end)

	test("server outbound byte budget drains a queue across heartbeats", function()
		local now = 0
		local batches = {}
		local server = CommunicationServer.new({
			PlayersModule = {
				PlayerRemoving = Signal.new(),
			},
			Clock = function()
				return now
			end,
			Transport = {
				ClientToServer = {},
				ServerToClient = {
					FireClient = function(_self, _targetPlayer, batch)
						table.insert(batches, batch)
					end,
				},
				Request = {},
			},
		})
		local player = { UserId = 4001 } :: any

		local epoch = server:BeginSnapshot(player)
		assertEqual(server:SetClientReady(player, epoch), true)
		for index = 1, 5 do
			assertEqual(server:Queue(player, "Integration.Large", {
				Index = index,
				Value = string.rep("x", 40 * 1024),
			}), true)
		end

		server:Flush()
		local firstHeartbeatBatches = #batches
		assertTrue(firstHeartbeatBatches > 0, "initial outbound burst sent nothing")
		assertTrue(
			firstHeartbeatBatches < CommunicationConfig.ServerToClientBatchBurst,
			"byte budget must constrain independently of batch budget"
		)
		local firstHeartbeatStats = server:GetQueueStats(player)
		assertEqual(firstHeartbeatStats.Messages, 5 - firstHeartbeatBatches)
		assertEqual(firstHeartbeatStats.OutgoingSequence, firstHeartbeatBatches)

		now = 1
		server:Flush()
		assertEqual(#batches, 5)
		assertEqual(server:GetQueueStats(player).Messages, 0)
		assertEqual(server:GetQueueStats(player).OutgoingSequence, 5)
	end)

	test("communication limiter state is cleared for a player and on stop", function()
		local sentToPlayers = 0
		local server = CommunicationServer.new({
			PlayersModule = {
				PlayerRemoving = Signal.new(),
			},
			Transport = {
				ClientToServer = {},
				ServerToClient = {
					FireClient = function()
						sentToPlayers += 1
					end,
				},
				Request = {},
			},
		})
		local firstPlayer = { UserId = 4002 } :: any
		local secondPlayer = { UserId = 4003 } :: any
		local handled = 0
		server:RegisterHandler("Integration.Cleanup", function(payload)
			return true, payload, nil
		end, function()
			handled += 1
		end)
		server:ReceiveBatch(firstPlayer, {
			Sequence = 1,
			Messages = {
				{
					Type = "Integration.Cleanup",
					Payload = {},
				},
			},
		})
		server:HandleRequest(firstPlayer, "invalid")
		local epoch = server:BeginSnapshot(firstPlayer)
		server:SetClientReady(firstPlayer, epoch)
		server:Queue(firstPlayer, "Integration.Cleanup.Out", {})
		server:Flush()
		assertEqual(sentToPlayers, 1)
		server:ForgetPlayer(firstPlayer)
		local forgottenStats = server:GetQueueStats(firstPlayer)
		assertEqual(forgottenStats.Messages, 0)
		assertEqual(forgottenStats.OutgoingSequence, 0)
		assertEqual(forgottenStats.Epoch, 0)
		server:ReceiveBatch(firstPlayer, {
			Sequence = 1,
			Messages = {
				{
					Type = "Integration.Cleanup",
					Payload = {},
				},
			},
		})
		assertEqual(handled, 2, "forgotten player must restart at incoming sequence one")

		local response
		for _ = 1, CommunicationConfig.RequestInvocationBurst + 1 do
			response = server:HandleRequest(secondPlayer, "invalid")
		end
		assertEqual(response.Code, "RateLimited")
		server:Stop()
		assertEqual(server:HandleRequest(secondPlayer, "invalid").Code, "Unavailable")

		local now = 0
		local sent = 0
		local clientToServer = {
			FireServer = function()
				sent += 1
			end,
		}
		local client = CommunicationClient.new(nil, function()
			return now
		end, nil, {
			ClientToServer = clientToServer,
			ServerToClient = {
				OnClientEvent = Signal.new(),
			},
			Request = {
				InvokeServer = function()
					return { Ok = false, Code = "Unavailable" }
				end,
			},
		})
		for index = 1, CommunicationConfig.BatchInvocationBurst do
			client:Queue("Integration.BeforeStop", { Index = index })
			client:Flush()
		end
		assertEqual(sent, CommunicationConfig.BatchInvocationBurst)
		client:Stop()
		client:Initialize()
		assertEqual(client:Queue("Integration.AfterStop", {}), true)
		client:Flush()
		assertEqual(sent, CommunicationConfig.BatchInvocationBurst + 1, "client Stop must reset outbound limiter state")
		client:Stop()
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
		client:ReceiveBatch({
			Epoch = 1,
			Sequence = 2,
			Messages = {},
		})
		task.wait()
		assertEqual(resyncs, 1)
		assertEqual(client:GetQueueStats().PausedForResync, true)

		client:ResumeAfterSnapshot(2)
		client:ReceiveBatch({
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
		client:ReceiveBatch({
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

	test("late resync handler starts recovery for an already paused client", function()
		local logger = makeLogger()
		local client = CommunicationClient.new(logger)
		local resyncs = 0

		client:ResumeAfterSnapshot(1)
		client:ReceiveBatch({
			Epoch = 1,
			Sequence = 2,
			Messages = {},
		})
		assertEqual(client:GetQueueStats().PausedForResync, true)

		client:SetResyncHandler(function()
			resyncs += 1
		end)
		task.wait()
		assertEqual(resyncs, 1)
		client:Stop()
	end)

	test("client rejects ordinary outbound messages while paused for resync", function()
		local client = CommunicationClient.new()
		client:SetResyncHandler(function()
			error("keep recovery paused")
		end)
		client:ResumeAfterSnapshot(1)
		client:ReceiveBatch({
			Epoch = 1,
			Sequence = 2,
			Messages = {},
		})
		task.wait()

		local queued = client:Queue("Integration.Intent", {
			Value = 1,
		})
		assertEqual(queued, false)
		assertEqual(client:GetQueueStats().Messages, 0)
		client:Stop()
	end)

	test("failed client resync retries with backoff and can recover", function()
		local scheduledDelay = nil
		local scheduledCallback = nil
		local client = CommunicationClient.new(nil, nil, function(delaySeconds, callback)
			scheduledDelay = delaySeconds
			scheduledCallback = callback
		end)
		local attempts = 0
		client:SetResyncHandler(function()
			attempts += 1
			if attempts == 1 then
				error("transient snapshot failure")
			end
			client:ResumeAfterSnapshot(2)
		end)
		client:ResumeAfterSnapshot(1)
		client:ReceiveBatch({
			Epoch = 1,
			Sequence = 2,
			Messages = {},
		})
		task.wait()

		assertEqual(attempts, 1)
		assertEqual(scheduledDelay, CommunicationConfig.ResyncRetryBaseDelaySeconds)
		assertTrue(scheduledCallback ~= nil, "failed resync did not schedule a retry")
		local retryCallback = assert(scheduledCallback)
		retryCallback()
		task.wait()
		assertEqual(attempts, 2)
		assertEqual(client:GetQueueStats().PausedForResync, false)
		client:Stop()
	end)

	test("stale resync retry callbacks cannot block a newer recovery generation", function()
		local scheduledCallbacks = {}
		local client = CommunicationClient.new(nil, nil, function(_delaySeconds, callback)
			table.insert(scheduledCallbacks, callback)
		end)
		local attempts = 0
		client:SetResyncHandler(function()
			attempts += 1
			if attempts < 3 then
				error(`transient snapshot failure {attempts}`)
			end
			client:ResumeAfterSnapshot(3)
		end)

		client:ResumeAfterSnapshot(1)
		client:ReceiveBatch({
			Epoch = 1,
			Sequence = 2,
			Messages = {},
		})
		task.wait()
		assertEqual(attempts, 1)
		assertTrue(scheduledCallbacks[1] ~= nil, "first recovery did not schedule a retry")

		client:ResumeAfterSnapshot(2)
		client:ReceiveBatch({
			Epoch = 2,
			Sequence = 2,
			Messages = {},
		})
		task.wait()
		assertEqual(attempts, 2)
		assertTrue(scheduledCallbacks[2] ~= nil, "new recovery did not schedule its own retry")

		scheduledCallbacks[1]()
		task.wait()
		assertEqual(attempts, 2, "stale retry callback started a recovery in the new generation")
		assertEqual(client:GetQueueStats().PausedForResync, true)

		scheduledCallbacks[2]()
		task.wait()
		assertEqual(attempts, 3)
		assertEqual(client:GetQueueStats().PausedForResync, false)
		client:Stop()
	end)

	test("stopping communication cancels an in-flight resync handler", function()
		local handlerStarted = false
		local releaseHandler = false
		local client = CommunicationClient.new()
		client:SetResyncHandler(function()
			handlerStarted = true
			while not releaseHandler do
				task.wait()
			end
			client:ResumeAfterSnapshot(99)
		end)

		client:ResumeAfterSnapshot(1)
		client:ReceiveBatch({
			Epoch = 1,
			Sequence = 2,
			Messages = {},
		})
		while not handlerStarted do
			task.wait()
		end

		client:Stop()
		releaseHandler = true
		task.wait()
		local stats = client:GetQueueStats()
		assertEqual(stats.PausedForResync, false)
		assertEqual(stats.Epoch, 0, "cancelled resync handler resumed a stopped client")
	end)

	test("successful snapshot clears a lost client-authority patch", function()
		local queued = 0
		local communication = {
			RegisterHandler = function() end,
			Queue = function()
				queued += 1
				return true
			end,
		}
		local changed = Signal.new()
		local value = 1
		local provider = {
			Id = "ClientOwned",
			Version = 1,
			Authority = "Client",
			MementoChanged = changed,
			ValidateMemento = function(_self, candidate)
				return typeof(candidate) == "table" and typeof(candidate.Value) == "number", candidate, nil
			end,
			SetMemento = function(_self, candidate)
				value = candidate.Value
			end,
			GetMemento = function()
				return { Value = value }
			end,
			Run = function() end,
			Stop = function() end,
			SetLocalValue = function(_self, nextValue)
				value = nextValue
				changed:Fire()
			end,
		}
		local controller = ClientSaveController.new({
			Id = "client_authority",
			Providers = { provider },
			Communication = communication,
		})
		local function snapshot(revision: number, snapshotValue: number)
			return {
				ControllerId = "client_authority",
				Revision = revision,
				Providers = {
					ClientOwned = {
						Version = 1,
						Data = { Value = snapshotValue },
					},
				},
			}
		end

		controller:ApplySnapshot(snapshot(1, 1))
		provider:SetLocalValue(2)
		task.wait()
		controller:FlushClientChanges()
		assertEqual(queued, 1)

		controller:ApplySnapshot(snapshot(2, 3))
		controller:FlushClientChanges()
		assertEqual(queued, 1, "snapshot must retire the lost pending patch and its dirty generation")

		provider:SetLocalValue(4)
		task.wait()
		controller:FlushClientChanges()
		assertEqual(queued, 2, "changes after resync must be sendable")
		controller:Destroy()
		changed:Destroy()
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

	return TestHarness.runAll("ProductionIntegrationTestRunner", tests, 10)
end

return ProductionIntegrationTestRunner
