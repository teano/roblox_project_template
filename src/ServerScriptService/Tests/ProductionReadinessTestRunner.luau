--!strict

--[[
	Deterministic contract coverage for production lifecycle boundaries that do
	not belong to one of the older focused runners.

	require(game.ServerScriptService.Tests.ProductionReadinessTestRunner).runAll()
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local CommunicationClient = require(ReplicatedStorage.Client.Communication.CommunicationClient)
local ClientGameData = require(ReplicatedStorage.Client.GameData.GameDataClient)
local ClientPlayersModule = require(ReplicatedStorage.Client.Players.PlayersModule)
local ClientSaveModule = require(ReplicatedStorage.Client.Save.SaveModule)
local VersionClient = require(ReplicatedStorage.Client.Version.VersionClient)
local CommunicationProtocol = require(ReplicatedStorage.Shared.Communication.CommunicationProtocol)
local SaveSerialize = require(ReplicatedStorage.Shared.Save.SaveSerialize)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local TableUtil = require(ReplicatedStorage.Shared.Util.TableUtil)
local VersionConfig = require(ReplicatedStorage.Shared.Version.VersionConfig)
local AutoSaveModule = require(ServerScriptService.Modules.AutoSave.AutoSaveModule)
local MigrationModule = require(ServerScriptService.Modules.Migration.MigrationModule)
local ServerPlayersModule = require(ServerScriptService.Modules.Players.PlayersModule)
local ServerSaveController = require(ServerScriptService.Modules.Save.ServerSaveController)
local ServerSaveModule = require(ServerScriptService.Modules.Save.SaveModule)
local MemoryStorage = require(ServerScriptService.Modules.Storage.MemoryStorage)
local SessionLockingStorage = require(ServerScriptService.Modules.Storage.SessionLockingStorage)
local SessionLockModule = require(ServerScriptService.Modules.Storage.SessionLockModule)
local StatisticsModule = require(ServerScriptService.Modules.Statistics.StatisticsModule)
local WalletModule = require(ServerScriptService.Modules.Wallet.WalletModule)
local VersionModule = require(ServerScriptService.Modules.Version.VersionModule)
local TestHarness = require(script.Parent.TestHarness)

local ProductionReadinessTestRunner = {}

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

local function assertThrows(callback: () -> (), expected: string?)
	local ok, testError = pcall(callback)
	assertEqual(ok, false, "expected callback to throw")
	if expected ~= nil then
		assertTrue(
			string.find(tostring(testError), expected, 1, true) ~= nil,
			`error did not contain '{expected}'`
		)
	end
end

local function assertOperationsThrow(operations: { [string]: () -> () }, expected: string)
	for name, operation in operations do
		local ok, operationError = pcall(operation)
		assertEqual(ok, false, `{name} unexpectedly succeeded`)
		assertTrue(
			string.find(tostring(operationError), expected, 1, true) ~= nil,
			`{name} did not report {expected}`
		)
	end
end

local function waitUntil(predicate: () -> boolean)
	while not predicate() do
		task.wait()
	end
end

local function makeLogger()
	local entries = {}
	return {
		Info = function(_self, event, fields)
			table.insert(entries, { Level = "Info", Event = event, Fields = fields })
		end,
		Warn = function(_self, event, fields)
			table.insert(entries, { Level = "Warn", Event = event, Fields = fields })
		end,
		Error = function(_self, event, fields)
			table.insert(entries, { Level = "Error", Event = event, Fields = fields })
		end,
	}, entries
end

local function makeProvider(id: string, authority: string, behavior: any?)
	local values = {}
	local changed = Signal.new()
	local provider = {
		Id = id,
		Version = 1,
		Authority = authority,
		MementoChanged = changed,
		Active = {},
		RunCalls = 0,
		StopCalls = 0,
		CreateDefault = function()
			return { Value = 1 }
		end,
		ValidateMemento = function(_self, _player, value)
			if typeof(value) ~= "table" or typeof(value.Value) ~= "number" then
				return false, nil, "Value must be a number"
			end
			return true, { Value = value.Value }, nil
		end,
		SetMemento = function(_self, player, value)
			if behavior and behavior.FailSetValue == value.Value then
				error("injected SetMemento failure")
			end
			values[player] = { Value = value.Value }
		end,
		GetMemento = function(_self, player)
			local value = values[player]
			return if value then { Value = value.Value } else nil
		end,
		Run = function(_self, player)
			_self.RunCalls += 1
			if behavior and behavior.FailRunValue == values[player].Value then
				error("injected Run failure")
			end
			_self.Active[player] = true
		end,
		Stop = function(_self, player)
			_self.StopCalls += 1
			if behavior and behavior.FailStopValue == (values[player] and values[player].Value) then
				error("injected Stop failure")
			end
			_self.Active[player] = nil
		end,
		ApplyClientMemento = function(_self, player, value)
			values[player] = { Value = value.Value }
		end,
		GetValue = function(_self, player)
			return values[player] and values[player].Value
		end,
		Destroy = function()
			changed:Destroy()
		end,
	}
	return provider
end

local function makeController(id: string, providers: { any }, softSerializedBytesLimit: number?)
	return ServerSaveController.new({
		Id = id,
		Providers = providers,
		Storage = SessionLockingStorage.new(MemoryStorage.new(), {
			StaleLockSeconds = 1_800,
		}),
		KeyResolver = function(player)
			return `{id}_{player.UserId}`
		end,
		SoftSerializedBytesLimit = softSerializedBytesLimit,
		Logger = makeLogger(),
	})
end

local function makeInstrumentedEvent()
	local signal = Signal.new()
	local connections = {}
	local event = {
		ConnectCalls = 0,
		FireCalls = 0,
		FailConnectAt = nil :: number?,
		OnConnect = nil :: (() -> ())?,
	}

	function event:Connect(callback)
		self.ConnectCalls += 1
		if self.FailConnectAt == self.ConnectCalls then
			error(`injected connection failure {self.ConnectCalls}`)
		end
		local connection = signal:Connect(callback)
		table.insert(connections, connection)
		if self.OnConnect then
			self.OnConnect()
		end
		return connection
	end

	function event:Fire(...)
		self.FireCalls += 1
		signal:Fire(...)
	end

	function event:ActiveCount(): number
		local active = 0
		for _, connection in connections do
			if connection.Connected then
				active += 1
			end
		end
		return active
	end

	function event:Destroy()
		signal:Destroy()
	end

	return event
end

local function makePlayersService()
	local players = {}
	local service = {
		PlayerAdded = makeInstrumentedEvent(),
		PlayerRemoving = makeInstrumentedEvent(),
		GetPlayersCalls = 0,
		GetPlayerByUserIdCalls = 0,
		GetPlayerFromCharacterCalls = 0,
		GetPlayersHook = nil :: (() -> ())?,
		FailGetPlayers = false,
	}
	function service:GetPlayers()
		self.GetPlayersCalls += 1
		if self.FailGetPlayers then
			error("injected GetPlayers failure")
		end
		if self.GetPlayersHook then
			self.GetPlayersHook()
		end
		return table.clone(players)
	end
	function service:GetPlayerByUserId(userId)
		self.GetPlayerByUserIdCalls += 1
		for _, player in players do
			if player.UserId == userId then
				return player
			end
		end
		return nil
	end
	function service:GetPlayerFromCharacter(character)
		self.GetPlayerFromCharacterCalls += 1
		for _, player in players do
			if player.Character == character then
				return player
			end
		end
		return nil
	end
	function service:Add(player)
		table.insert(players, player)
		self.PlayerAdded:Fire(player)
	end
	function service:Remove(player)
		local index = table.find(players, player)
		if index then
			table.remove(players, index)
		end
		self.PlayerRemoving:Fire(player)
	end
	function service:Replace(oldPlayer, newPlayer)
		local index = table.find(players, oldPlayer)
		assert(index ~= nil, "replacement source player missing")
		players[index] = newPlayer
	end
	function service:Destroy()
		self.PlayerAdded:Destroy()
		self.PlayerRemoving:Destroy()
	end
	return service
end

local function makePlayer(userId: number, character: any?)
	local characterAdded = makeInstrumentedEvent()
	local characterRemoving = makeInstrumentedEvent()
	return {
		UserId = userId,
		Character = character,
		CharacterAdded = characterAdded,
		CharacterRemoving = characterRemoving,
		Destroy = function(self)
			self.CharacterAdded:Destroy()
			self.CharacterRemoving:Destroy()
		end,
	} :: any
end

function ProductionReadinessTestRunner.runAll()
	local tests = {}

	local function test(name: string, callback: (any) -> ())
		table.insert(tests, { Name = name, Callback = callback })
	end

	test("autosave processes only due dirty players with injected deterministic scheduling", function(scope)
		local now = 100
		local spawned = nil
		local waitCalls = 0
		local forceSaved = {}
		local module
		module = AutoSaveModule.new(makeLogger(), {
			Clock = function()
				return now
			end,
			Random = function()
				return 0
			end,
			Spawn = function(callback)
				spawned = callback
			end,
			Wait = function(seconds)
				waitCalls += 1
				if waitCalls == 4 then
					module:Stop()
				end
				return seconds or 0
			end,
		})
		scope:Defer(function()
			module:Stop()
		end)

		local due = { UserId = 1 }
		local notDue = { UserId = 2 }
		module:RegisterController({
			GetDirtyPlayers = function()
				return { due, notDue }
			end,
			GetLastSavedAt = function(_self, player)
				return if player == due then 90 else 91
			end,
			ForceSave = function(_self, player, reason)
				table.insert(forceSaved, { Player = player, Reason = reason })
				return { Ok = true }
			end,
		}, {
			IntervalSeconds = 10,
		})
		module:Initialize()
		module:Initialize()
		assertTrue(spawned ~= nil, "autosave did not schedule its worker")
		local worker = assert(spawned)
		worker()

		assertEqual(#forceSaved, 1)
		assertEqual(forceSaved[1].Player, due)
		assertEqual(forceSaved[1].Reason, "Autosave")
	end)

	test("autosave reports persistence failures and stops without another cycle", function(scope)
		local logger, entries = makeLogger()
		local spawned = nil
		local waitCalls = 0
		local module
		module = AutoSaveModule.new(logger, {
			Clock = function()
				return 50
			end,
			Random = function()
				return 0
			end,
			Spawn = function(callback)
				spawned = callback
			end,
			Wait = function(seconds)
				waitCalls += 1
				if waitCalls == 3 then
					module:Stop()
				end
				return seconds or 0
			end,
		})
		scope:Defer(function()
			module:Stop()
		end)
		module:RegisterController({
			GetDirtyPlayers = function()
				return { { UserId = 7 } }
			end,
			GetLastSavedAt = function()
				return 0
			end,
			ForceSave = function()
				return { Ok = false, Code = "Injected", Error = "expected" }
			end,
		}, {
			IntervalSeconds = 5,
		})
		module:Initialize()
		local worker = assert(spawned)
		worker()
		assertEqual(#entries, 1)
		assertEqual(entries[1].Event, "autosave_failed")
	end)

	test("save controller removal unregisters idle and pending autosave state", function(scope)
		local scheduled = {}
		local logger, entries = makeLogger()
		local autoSave = AutoSaveModule.new(logger, {
			Clock = function() return 100 end,
			Random = function() return 0 end,
			Spawn = function(callback) table.insert(scheduled, callback) end,
			Wait = function(seconds) return seconds end,
		})
		scope:Defer(function() autoSave:Stop() end)
		local saveModule = ServerSaveModule.new({
			OnControllerRemoving = function(controller)
				autoSave:UnregisterController(controller)
			end,
		})
		saveModule:Initialize()
		local provider = makeProvider("RemovalProvider", "Server")
		scope:Defer(function() provider:Destroy() end)
		scope:Defer(function() saveModule:RemoveAllSaveControllers(false) end)

		local function buildController(id)
			return saveModule:BuildSaveController(id)
				:WithSaveProvider(provider)
				:WithStorage(SessionLockingStorage.new(MemoryStorage.new(), { StaleLockSeconds = 1_800 }))
				:WithKeyResolver(function(player) return `{id}_{player.UserId}` end)
				:Build()
		end

		local pendingController = buildController("pending_removal")
		autoSave:RegisterController(pendingController, { IntervalSeconds = 60 })
		local player = { UserId = 8_001 } :: any
		assertEqual(autoSave:RequestSave(pendingController, player, "PendingRemoval", 200).Code, "Queued")
		assertEqual(#scheduled, 1)
		assertEqual(saveModule:RemoveSaveController(pendingController, false), true)
		scheduled[1]()
		assertEqual(#entries, 0, "removed controller's pending save still executed")
		assertEqual(autoSave:UnregisterController(pendingController), false)
		assertThrows(function()
			autoSave:RequestSave(pendingController, player, "Removed", 0)
		end, "not registered")

		local idleController = buildController("idle_removal")
		autoSave:RegisterController(idleController, { IntervalSeconds = 60 })
		saveModule:RemoveAllSaveControllers(false)
		assertEqual(autoSave:UnregisterController(idleController), false)
	end)

	test("session lock scheduler refreshes only due loaded players and logs failure", function(scope)
		local logger, entries = makeLogger()
		local spawned = nil
		local now = 100
		local module
		module = SessionLockModule.new(20, logger, {
			Clock = function()
				return now
			end,
			Spawn = function(callback)
				spawned = callback
			end,
			Wait = function(seconds)
				module:Stop()
				return seconds or 0
			end,
		})
		scope:Defer(function()
			module:Stop()
		end)
		local due = { UserId = 10 }
		local notDue = { UserId = 11 }
		local notLoaded = { UserId = 12 }
		local staleChecks = 0
		local staleController = {
			GetLockOwners = function() error("removed scheduler entry was enumerated") end,
			ShouldRefreshLock = function()
				staleChecks += 1
				return true
			end,
			ShouldRetryClose = function() return false end,
			GetLastLockRefreshAt = function() return 0 end,
			RefreshLock = function() error("removed scheduler entry was polled") end,
			RetryClose = function() error("removed scheduler entry was retried") end,
		}
		assertEqual(module:RegisterController(staleController), true)
		assertEqual(module:RegisterController(staleController), false, "duplicate scheduler registration was accepted")
		assertEqual(module:UnregisterController(staleController), true)
		assertEqual(module:UnregisterController(staleController), false)
		local revokedDuringEnumerationChecks = 0
		local revokedDuringEnumeration = nil :: any
		revokedDuringEnumeration = {
			GetLockOwners = function()
				assertEqual(module:UnregisterController(revokedDuringEnumeration), true)
				return {
					{ Player = due, Runtime = {} },
				}
			end,
			ShouldRefreshLock = function()
				revokedDuringEnumerationChecks += 1
				return true
			end,
			ShouldRetryClose = function() return false end,
			GetLastLockRefreshAt = function() return 0 end,
			RefreshLock = function() error("revoked scheduler entry was polled") end,
			RetryClose = function() error("revoked scheduler entry was retried") end,
		}
		assertEqual(module:RegisterController(revokedDuringEnumeration), true)

		local refreshed = {}
		local rebuiltController = {
			GetLockOwners = function()
				return {
					{ Player = due, Runtime = due },
					{ Player = notDue, Runtime = notDue },
					{ Player = notLoaded, Runtime = notLoaded },
				}
			end,
			ShouldRefreshLock = function(_self, player)
				return player ~= notLoaded
			end,
			ShouldRetryClose = function() return false end,
			GetLastLockRefreshAt = function(_self, player)
				return if player == due then 80 else 81
			end,
			RefreshLock = function(_self, player)
				table.insert(refreshed, player)
				return { Ok = false, Code = "Injected", Error = "expected" }
			end,
			RetryClose = function() error("loaded controller was retried") end,
		}
		assertEqual(module:RegisterController(rebuiltController), true)
		assertEqual(module:RegisterController(rebuiltController), false, "rebuilt controller was registered twice")
		module:Initialize()
		module:Initialize({})
		local worker = assert(spawned)
		worker()

		assertEqual(#refreshed, 1)
		assertEqual(refreshed[1], due)
		assertEqual(staleChecks, 0, "removed controller retained a stale scheduler reference")
		assertEqual(
			revokedDuringEnumerationChecks,
			0,
			"controller revoked during player enumeration was still polled"
		)
		assertEqual(entries[1].Event, "lock_refresh_failed")
	end)

	test("CloseFailed retains guarded session-lock heartbeat ownership through retry", function(scope)
		local now = 0
		local staleSeconds = 20
		local lastHeartbeat = 0
		local lockOwned = false
		local failRelease = true
		local yieldNextRefresh = true
		local yieldedRefreshThread = nil :: thread?
		local refreshCalls = 0
		local releaseCalls = 0
		local storage = {
			Load = function()
				lockOwned = true
				lastHeartbeat = now
				return {
					Ok = true,
					Document = {
						FormatVersion = 1,
						Revision = 4,
						Providers = {
							HeartbeatProvider = { Version = 1, Data = { Value = 2 } },
						},
						Metadata = { CreatedAt = 1, UpdatedAt = 1 },
					},
				}
			end,
			Save = function()
				return { Ok = true }
			end,
			Refresh = function()
				if yieldNextRefresh then
					yieldNextRefresh = false
					yieldedRefreshThread = coroutine.running()
					coroutine.yield()
				end
				if not lockOwned then
					return { Ok = false, Code = "LockLost", Error = "test lock was released" }
				end
				refreshCalls += 1
				lastHeartbeat = now
				return { Ok = true }
			end,
			Release = function()
				releaseCalls += 1
				if failRelease then
					return { Ok = false, Code = "InjectedReleaseFailure", Error = "expected" }
				end
				lockOwned = false
				return { Ok = true }
			end,
		}
		local behavior = { FailStopValue = 2 }
		local provider = makeProvider("HeartbeatProvider", "Server", behavior)
		local heartbeat = Signal.new()
		local controller = ServerSaveController.new({
			Id = "retry_retained_heartbeat",
			Providers = { provider },
			Storage = storage,
			KeyResolver = function() return "retry_retained_heartbeat" end,
			Logger = makeLogger(),
			Heartbeat = heartbeat,
			Clock = function() return now end,
		})
		local player = { UserId = 30_001 } :: any
		scope:Defer(function()
			behavior.FailStopValue = nil
			failRelease = false
			controller:Close(player, false)
			controller:Destroy(false)
			heartbeat:Destroy()
			provider:Destroy()
		end)
		assertTrue(controller:Load(player).Ok, "retry-retained heartbeat fixture did not load")
		assertTrue(controller:IsLoaded(player), "fresh runtime was not gameplay-ready")
		assertTrue(controller:ShouldRefreshLock(player), "fresh lock was not refreshable")

		now = 10
		local refreshResult = nil :: any
		local closeResult = nil :: any
		task.spawn(function()
			refreshResult = controller:RefreshLock(player)
		end)
		waitUntil(function() return yieldedRefreshThread ~= nil end)
		assertEqual(controller:ShouldRefreshLock(player), false, "in-flight refresh remained scheduler-eligible")
		task.spawn(function()
			closeResult = controller:Close(player, false)
		end)
		waitUntil(function()
			local runtime = controller._runtimes[player]
			return runtime ~= nil and runtime.CloseRequested == true
		end)
		assertEqual(controller:ShouldRefreshLock(player), false, "close/refresh overlap exposed scheduler ownership")
		assertEqual(controller:RefreshLock(player).Code, "NotLoaded", "close admitted a second refresh")
		task.spawn(yieldedRefreshThread :: thread)
		waitUntil(function() return refreshResult ~= nil and closeResult ~= nil end)
		assertEqual(refreshResult.Code, "LockRefreshClosed", "post-yield refresh mutated a closing runtime")
		assertEqual(closeResult.Code, "ProviderStopFailed")
		assertEqual(controller:GetState(player), "CloseFailed")
		assertEqual(controller:IsLoaded(player), false, "CloseFailed runtime reopened gameplay mutation")
		assertTrue(controller:ShouldRefreshLock(player), "Stop failure did not retain heartbeat ownership")
		assertTrue(lockOwned, "Stop failure released the storage lock")
		assertEqual(releaseCalls, 0, "Stop failure reached storage release")
		assertEqual(controller:GetLastLockRefreshAt(player), 0, "closing refresh changed controller timestamp post-yield")

		-- A later shutdown deadline may overlap a retained-owner heartbeat. Its
		-- withdrawn close request must restore, rather than erase, the original
		-- CloseFailed cleanup/save/preparation/refresh ownership.
		yieldNextRefresh = true
		yieldedRefreshThread = nil
		local retainedRefreshResult = nil :: any
		local retainedRuntime = controller._runtimes[player]
		local retainedFlags = {
			CloseRequested = retainedRuntime.CloseRequested,
			CloseSaveRequired = retainedRuntime.CloseSaveRequired,
			ClosePreparationRequired = retainedRuntime.ClosePreparationRequired,
			LockRefreshRetained = retainedRuntime.LockRefreshRetained,
		}
		task.spawn(function()
			retainedRefreshResult = controller:RefreshLock(player, nil, retainedRuntime)
		end)
		waitUntil(function() return yieldedRefreshThread ~= nil end)
		local withdrawnRetainedClose = controller:Close(player, false, { Deadline = now }, retainedRuntime)
		assertEqual(withdrawnRetainedClose.Code, "DeadlineExceeded")
		assertEqual(retainedRuntime.CloseRequested, retainedFlags.CloseRequested)
		assertEqual(retainedRuntime.CloseSaveRequired, retainedFlags.CloseSaveRequired)
		assertEqual(retainedRuntime.ClosePreparationRequired, retainedFlags.ClosePreparationRequired)
		assertEqual(retainedRuntime.LockRefreshRetained, retainedFlags.LockRefreshRetained)
		task.spawn(yieldedRefreshThread :: thread)
		waitUntil(function() return retainedRefreshResult ~= nil end)
		assertTrue(retainedRefreshResult.Ok, "withdrawn retained close invalidated the pre-existing heartbeat owner")
		assertTrue(controller:ShouldRetryClose(player, retainedRuntime), "withdrawn retained close lost cleanup retry ownership")
		assertEqual(controller:BuildSnapshot(player), nil, "CloseFailed runtime built a gameplay snapshot")
		assertEqual(select(1, controller:FlushDirty(player)), false, "CloseFailed runtime captured dirty data")
		assertEqual(controller:ForceSave(player).Code, "NotLoaded", "CloseFailed runtime admitted persistence mutation")
		assertThrows(function()
			controller:ApplyMemento(player, {
				FormatVersion = 1,
				Revision = 5,
				Providers = {},
				Metadata = { CreatedAt = 1, UpdatedAt = 1 },
			})
		end, "blocked by close")

		local spawned = {}
		local sessionLock = nil :: any
		sessionLock = SessionLockModule.new(10, makeLogger(), {
			Clock = function() return now end,
			Spawn = function(callback) table.insert(spawned, callback) end,
			Wait = function(seconds)
				sessionLock:Stop()
				return seconds
			end,
		})
		scope:Defer(function() sessionLock:Stop() end)
		assertEqual(sessionLock:RegisterController(controller), true)
		local function runSchedulerCycle()
			sessionLock:Initialize({ GetPlayers = function() return {} end })
			local worker = table.remove(spawned, 1)
			assert(worker ~= nil)
			worker()
		end
		local function challengerCanAcquire(): boolean
			return not lockOwned or now - lastHeartbeat >= staleSeconds
		end

		for _, expiryBoundary in { 30, 50 } do
			now = expiryBoundary
			assertEqual(now - lastHeartbeat, staleSeconds, "fixture did not reach exact expiry boundary")
			runSchedulerCycle()
			assertEqual(challengerCanAcquire(), false, "retained lock expired before cleanup retry")
			assertEqual(lastHeartbeat, now, "scheduler did not refresh at the exact expiry boundary")
		end
		assertEqual(refreshCalls, 4, "Stop-failed runtime did not receive repeated safe refreshes")

		behavior.FailStopValue = nil
		local releaseFailure = controller:Close(player, false)
		assertEqual(releaseFailure.Code, "InjectedReleaseFailure")
		assertEqual(controller:GetState(player), "CloseFailed")
		assertTrue(controller:ShouldRefreshLock(player), "Release failure did not retain heartbeat ownership")
		assertTrue(lockOwned, "Release failure dropped storage ownership")
		assertTrue(provider.Active[player] == nil, "successful provider cleanup was reopened after Release failure")

		now = 70
		assertEqual(now - lastHeartbeat, staleSeconds)
		runSchedulerCycle()
		assertEqual(refreshCalls, 5, "Release-failed runtime was not refreshed")
		assertEqual(challengerCanAcquire(), false, "Release-failed lock became stealable")

		lockOwned = false
		local lockLost = controller:RefreshLock(player)
		assertEqual(lockLost.Code, "LockLost")
		assertEqual(controller:GetState(player), "CloseFailed", "lock loss reopened terminal runtime state")
		assertEqual(controller:ShouldRefreshLock(player), false, "fail-closed lock loss kept scheduling heartbeats")
		assertEqual(controller:IsLoaded(player), false, "fail-closed lock loss reopened gameplay mutation")
		local refreshesBeforeFailClosedCycle = refreshCalls
		local releasesBeforeFailClosedCycle = releaseCalls
		now = 80
		runSchedulerCycle()
		assertEqual(refreshCalls, refreshesBeforeFailClosedCycle, "fail-closed runtime kept refreshing a lost lock")
		assertEqual(releaseCalls, releasesBeforeFailClosedCycle, "bounded scheduler exceeded its cleanup retry budget")

		failRelease = false
		local retry = controller:Close(player, false)
		assertTrue(retry.Ok, "terminal cleanup retry did not release the retained lock")
		assertEqual(controller:GetState(player), "NotLoaded")
		assertEqual(controller:ShouldRefreshLock(player), false, "released runtime retained heartbeat ownership")
		assertEqual(lockOwned, false, "successful retry left the storage lock owned")
		assertEqual(releaseCalls, 3, "release retry count drifted")
		local refreshesBeforeReleasedCycle = refreshCalls
		now = 90
		runSchedulerCycle()
		assertEqual(refreshCalls, refreshesBeforeReleasedCycle, "released runtime was refreshed")
		assertEqual(controller:RefreshLock(player).Code, "NotLoaded", "released runtime accepted direct refresh")
	end)

	test("departed PlayersModule owners retain bounded refresh and cleanup scheduling", function(scope)
		local now = 0
		local staleSeconds = 20
		local lastHeartbeat = 0
		local lockOwned = false
		local refreshCalls = 0
		local releaseCalls = 0
		local storage = {
			Load = function()
				lockOwned = true
				lastHeartbeat = now
				return {
					Ok = true,
					Document = {
						FormatVersion = 1,
						Revision = 0,
						Providers = {
							DepartedProvider = { Version = 1, Data = { Value = 1 } },
						},
						Metadata = { CreatedAt = 1, UpdatedAt = 1 },
					},
				}
			end,
			Save = function() return { Ok = true } end,
			Refresh = function()
				if not lockOwned then
					return { Ok = false, Code = "LockLost", Error = "authoritative test loss" }
				end
				refreshCalls += 1
				lastHeartbeat = now
				return { Ok = true }
			end,
			Release = function()
				releaseCalls += 1
				lockOwned = false
				return { Ok = true }
			end,
		}
		local behavior = { FailStopValue = 1 }
		local provider = makeProvider("DepartedProvider", "Server", behavior)
		local heartbeat = Signal.new()
		local controller = ServerSaveController.new({
			Id = "departed_cleanup_owner",
			Providers = { provider },
			Storage = storage,
			KeyResolver = function() return "departed_cleanup_owner" end,
			Logger = makeLogger(),
			Heartbeat = heartbeat,
			Clock = function() return now end,
		})
		local service = makePlayersService()
		local player = makePlayer(30_002)
		service:Add(player)
		local playersModule = ServerPlayersModule.new(service)
		playersModule:Initialize()
		local removalResult = nil :: any
		local disconnect = playersModule:ObservePlayers(function(observedPlayer)
			assertTrue(controller:Load(observedPlayer).Ok, "production removal fixture did not load")
		end, function(observedPlayer)
			removalResult = controller:Close(observedPlayer, true)
		end)
		local spawned = {}
		local sessionLock = nil :: any
		sessionLock = SessionLockModule.new(10, makeLogger(), {
			Clock = function() return now end,
			Spawn = function(callback) table.insert(spawned, callback) end,
			Wait = function(seconds)
				sessionLock:Stop()
				return seconds
			end,
		})
		assertEqual(sessionLock:RegisterController(controller), true)
		scope:Defer(function()
			behavior.FailStopValue = nil
			disconnect()
			sessionLock:Stop()
			controller:Close(player, false)
			controller:Destroy(false)
			playersModule:Stop()
			service:Destroy()
			player:Destroy()
			heartbeat:Destroy()
			provider:Destroy()
		end)

		service:Remove(player)
		assertEqual(#playersModule:GetPlayers(), 0, "production service still enumerated the departed player")
		assertEqual(removalResult.Code, "ProviderStopFailed")
		assertEqual(controller:GetState(player), "CloseFailed")
		assertTrue(controller:ShouldRefreshLock(player), "departed retained owner was not refreshable")

		local function runSchedulerCycle()
			sessionLock:Initialize(playersModule)
			local worker = table.remove(spawned, 1)
			assertTrue(worker ~= nil, "session-lock worker was not scheduled")
			worker()
			assertEqual(#playersModule:GetPlayers(), 0, "scheduler cycle repopulated live Players")
		end

		for _, expiryBoundary in { 20, 40 } do
			now = expiryBoundary
			assertEqual(now - lastHeartbeat, staleSeconds, "fixture missed exact expiry boundary")
			runSchedulerCycle()
			assertEqual(lastHeartbeat, now, "departed owner was not refreshed at expiry")
			assertTrue(lockOwned, "retained owner lost its lock before bounded retry completed")
		end
		assertEqual(refreshCalls, 2, "departed owner did not receive repeated controller-owned refreshes")

		behavior.FailStopValue = nil
		lockOwned = false
		now = 60
		runSchedulerCycle()
		assertEqual(controller:GetState(player), "NotLoaded", "bounded cleanup retry did not finish")
		assertEqual(releaseCalls, 1, "cleanup retry did not execute exactly one release")
		assertEqual(controller:ShouldRefreshLock(player), false, "released owner remained refreshable")
		local refreshesAfterRelease = refreshCalls
		now = 80
		runSchedulerCycle()
		assertEqual(refreshCalls, refreshesAfterRelease, "released departed owner received a later refresh")
	end)

	test("session-lock cleanup budgets belong to opaque runtime generations", function(scope)
		local spawned = {}
		local module = nil :: any
		module = SessionLockModule.new(10, makeLogger(), {
			Clock = function() return 0 end,
			Spawn = function(callback) table.insert(spawned, callback) end,
			Wait = function(seconds)
				module:Stop()
				return seconds
			end,
		})
		scope:Defer(function() module:Stop() end)
		local player = { UserId = 30_008 } :: any
		local firstRuntime = {}
		local secondRuntime = {}
		local staleRuntime = {}
		local replacementRuntime = {}
		local currentRuntime: any = firstRuntime
		local replaceDuringRetry = false
		local attempts = {
			[firstRuntime] = 0,
			[secondRuntime] = 0,
			[staleRuntime] = 0,
			[replacementRuntime] = 0,
		}
		local controller = {
			GetLockOwners = function()
				return if currentRuntime then { { Player = player, Runtime = currentRuntime } } else {}
			end,
			ShouldRefreshLock = function() return false end,
			GetLastLockRefreshAt = function() return 0 end,
			RefreshLock = function() error("cleanup budget fixture unexpectedly refreshed") end,
			ShouldRetryClose = function(_self, ownerPlayer, runtime)
				return ownerPlayer == player and runtime == currentRuntime
			end,
			RetryClose = function(_self, ownerPlayer, runtime)
				assertEqual(ownerPlayer, player)
				assertEqual(runtime, currentRuntime, "stale runtime was retried")
				attempts[runtime] += 1
				if replaceDuringRetry then
					replaceDuringRetry = false
					currentRuntime = replacementRuntime
				end
				return { Ok = false, Code = "ProviderStopFailed", Error = "expected" }
			end,
		}
		assertEqual(module:RegisterController(controller), true)

		local function runCycle()
			module:Initialize()
			local worker = table.remove(spawned, 1)
			assertTrue(worker ~= nil, "cleanup budget worker was not scheduled")
			worker()
		end

		for _ = 1, 3 do runCycle() end
		assertEqual(attempts[firstRuntime], 3, "first runtime did not consume its exact budget")
		runCycle()
		assertEqual(attempts[firstRuntime], 3, "exhausted runtime exceeded its exact budget")

		currentRuntime = secondRuntime
		runCycle()
		assertEqual(attempts[secondRuntime], 1, "same-player replacement inherited the stale runtime budget")
		for _ = 1, 2 do runCycle() end
		assertEqual(attempts[secondRuntime], 3, "replacement runtime did not receive a fresh full budget")

		currentRuntime = staleRuntime
		replaceDuringRetry = true
		runCycle()
		assertEqual(attempts[staleRuntime], 1, "stale completion did not remain charged to its original runtime")
		assertEqual(attempts[replacementRuntime], 0, "stale completion debited the reloaded runtime")
		runCycle()
		assertEqual(attempts[replacementRuntime], 1, "reloaded runtime did not begin with a fresh budget")

		currentRuntime = nil
		runCycle()
		assertEqual(module:UnregisterController(controller), true)
		assertEqual(module:UnregisterController(controller), false)
	end)

	test("session-lock third cleanup attempt is revoked before finalization", function(scope)
		local spawned = {}
		local logger, logEntries = makeLogger()
		local module = nil :: any
		module = SessionLockModule.new(10, logger, {
			Clock = function() return 0 end,
			Spawn = function(callback) table.insert(spawned, callback) end,
			Wait = function(seconds) module:Stop(); return seconds end,
		})
		scope:Defer(function() module:Stop() end)
		local player = { UserId = 30_011 } :: any
		local runtime = {}
		local attempts = 0
		local finalizations = 0
		local yieldedThread = nil :: thread?
		local workerDone = false
		local controller = {
			GetLockOwners = function() return { { Player = player, Runtime = runtime } } end,
			ShouldRefreshLock = function() return false end,
			GetLastLockRefreshAt = function() return 0 end,
			RefreshLock = function() error("revocation fixture unexpectedly refreshed") end,
			ShouldRetryClose = function(_self, ownerPlayer, ownerRuntime)
				return ownerPlayer == player and ownerRuntime == runtime
			end,
			RetryClose = function()
				attempts += 1
				if attempts == 3 then
					yieldedThread = coroutine.running()
					coroutine.yield()
				end
				return { Ok = false, Code = "ClosePreparationFailed", Error = "injected" }
			end,
			FinalizeRetainedClose = function()
				finalizations += 1
				return { Ok = true }
			end,
		}
		assertTrue(module:RegisterController(controller), "revocation fixture did not register")
		local function runCycle(async: boolean?)
			module:Initialize()
			local worker = table.remove(spawned, 1)
			assertTrue(worker ~= nil, "revocation worker was not scheduled")
			if async then
				task.spawn(function() worker(); workerDone = true end)
			else
				worker()
			end
		end

		runCycle()
		runCycle()
		assertEqual(attempts, 2)
		local entriesBeforeRevokedAttempt = #logEntries
		runCycle(true)
		waitUntil(function() return yieldedThread ~= nil end)
		assertEqual(module:UnregisterController(controller), true)
		assertEqual(module:RegisterController(controller), true, "controller entry was not rebuilt")
		task.spawn(yieldedThread :: thread)
		waitUntil(function() return workerDone end)
		assertEqual(finalizations, 0, "revoked third attempt finalized through the rebuilt entry")
		assertEqual(#logEntries, entriesBeforeRevokedAttempt, "revoked third attempt emitted a stale failure log")

		for expectedAttempt = 4, 6 do
			runCycle()
			assertEqual(attempts, expectedAttempt, "rebuilt entry did not receive a fresh cleanup attempt")
			assertEqual(finalizations, if expectedAttempt == 6 then 1 else 0)
		end
	end)

	test("real Statistics removal hands failed preparation to bounded terminal cleanup", function(scope)
		local statisticsConfig = {
			SnapshotTypes = {
				Global = { Retention = 0, Filter = { Mode = "AllowAllExcept", StatisticIds = {} } },
				Session = { Retention = 4, Filter = { Mode = "AllowAllExcept", StatisticIds = {} } },
				Place = { Retention = 8, Filter = { Mode = "AllowAllExcept", StatisticIds = {} } },
			},
			PublicProjection = {
				Global = { StatisticIds = {}, MetadataKeys = {} },
				Session = { StatisticIds = {}, MetadataKeys = {} },
				Place = { StatisticIds = {}, MetadataKeys = {} },
			},
			Limits = {
				MaxSnapshotTypes = 16,
				MaxRetentionPerType = 32,
				MaxStatisticIdsPerSnapshot = 256,
				MaxStatisticIdLength = 64,
				MaxSnapshotTypeLength = 48,
				MaxSnapshotEncodedBytes = 24_576,
				MaxMetadataDepth = 6,
				MaxMetadataNodes = 128,
				MaxMetadataEncodedBytes = 4_096,
				MaxMetadataKeyLength = 64,
				MaxMetadataStringLength = 256,
				MaxDedupSources = 16,
				MaxEventIdsPerSource = 64,
				MaxProviderEncodedBytes = 524_288,
				MaxClientResponseEstimatedBytes = 49_152,
				MaxHistoryReadCount = 32,
			},
			SaveRequestCooldownSeconds = 30,
		}
		local failPreparation = true
		local statistics = StatisticsModule.new({
			Config = { GetRequired = function() return statisticsConfig end },
			Teleport = {
				GetSession = function()
					return {
						SessionId = "00000000-0000-4000-8000-000000000008",
						EntryKind = "External",
					}
				end,
			},
			AutoSave = {},
			PlaceId = 91045933836846,
			MeasureEncodedSize = function(value)
				if failPreparation
					and typeof(value) == "table"
					and typeof(value.PendingSession) == "table"
				then
					return true, statisticsConfig.Limits.MaxProviderEncodedBytes + 1, nil
				end
				return SaveSerialize.measureEncodedSize(value)
			end,
			Logger = makeLogger(),
		})
		statistics:Initialize()
		local queuedWalletChanges = 0
		local wallet = WalletModule.new({
			Queue = function()
				queuedWalletChanges += 1
				return true
			end,
		}, {
			GetRequired = function(_self, configId)
				assertEqual(configId, "Wallet")
				return { StartingBalances = { Coins = 10, Gems = 0 } }
			end,
		})
		wallet:Initialize()
		local walletChanged = 0
		local walletChangedConnection = wallet.Changed:Connect(function()
			walletChanged += 1
		end)

		local now = 0
		local lockOwned = false
		local releaseCalls = 0
		local savedDocument = nil :: any
		local storage = {
			Load = function()
				assertEqual(lockOwned, false, "rejoin overlapped an unreleased retained lock")
				lockOwned = true
				return { Ok = true, Document = savedDocument, Created = savedDocument == nil }
			end,
			Save = function(_self, _key, document)
				savedDocument = TableUtil.deepCopy(document)
				return { Ok = true }
			end,
			Refresh = function()
				return if lockOwned then { Ok = true } else { Ok = false, Code = "LockLost" }
			end,
			Release = function()
				releaseCalls += 1
				lockOwned = false
				return { Ok = true }
			end,
		}
		local controller = ServerSaveController.new({
			Id = "real_statistics_close_handoff",
			Providers = { wallet, statistics },
			Storage = storage,
			KeyResolver = function(player) return `real_statistics_{player.UserId}` end,
			Logger = makeLogger(),
			Clock = function() return now end,
		})
		statistics:BindSaveController(controller)
		controller:SetClosePreparation(function(player)
			return statistics:PrepareForProfileClose(player)
		end)

		local service = makePlayersService()
		local playersModule = ServerPlayersModule.new(service)
		playersModule:Initialize()
		local removalResults = {} :: { [any]: any }
		local disconnect = playersModule:ObservePlayers(function(player)
			assertTrue(controller:Load(player).Ok, "real Statistics fixture did not load")
		end, function(player)
			removalResults[player] = controller:Close(player, true)
		end)
		local spawned = {}
		local sessionLock = nil :: any
		sessionLock = SessionLockModule.new(10, makeLogger(), {
			Clock = function() return now end,
			Spawn = function(callback) table.insert(spawned, callback) end,
			Wait = function(seconds) sessionLock:Stop(); return seconds end,
		})
		assertEqual(sessionLock:RegisterController(controller), true)
		scope:Defer(function()
			failPreparation = false
			disconnect()
			sessionLock:Stop()
			for _, owner in controller:GetLockOwners() do
				controller:FinalizeRetainedClose(owner.Player, owner.Runtime)
			end
			controller:Destroy(false)
			walletChangedConnection:Disconnect()
			wallet.MementoChanged:Destroy()
			wallet.Changed:Destroy()
			statistics:Destroy()
			playersModule:Stop()
			service:Destroy()
		end)

		local function runCycle()
			sessionLock:Initialize(playersModule)
			local worker = table.remove(spawned, 1)
			assertTrue(worker ~= nil, "real Statistics cleanup worker was not scheduled")
			worker()
		end

		local first = makePlayer(30_009)
		scope:Defer(function() first:Destroy() end)
		service:Add(first)
		assertTrue(wallet:Add(first, "Coins", 1, "normal_loaded_behavior").Ok, "normal Loaded wallet mutation failed")
		assertEqual(wallet:GetBalance(first, "Coins"), 11)
		service:Remove(first)
		assertEqual(#playersModule:GetPlayers(), 0, "departed player remained in the live Players list")
		assertEqual(removalResults[first].Code, "ClosePreparationFailed")
		assertEqual(controller:GetState(first), "CloseFailed")
		assertEqual(statistics._closeResults[first], nil, "failed Statistics preparation was memoized")
		assertTrue(controller:ShouldRefreshLock(first), "preparation failure lost heartbeat ownership")
		assertEqual(
			statistics:ApplyOperation(first, { Operation = "Inc", StatisticId = "Closed", Operand = 1 }).Code,
			"Closing",
			"failed preparation reopened Statistics gameplay mutation"
		)
		local retainedBalance = wallet:GetBalance(first, "Coins")
		local retainedSequence = wallet:GetMemento(first).LastTransactionSequence
		local changedBeforeRejectedMutation = walletChanged
		local queuedBeforeRejectedMutation = queuedWalletChanges
		assertEqual(wallet:Add(first, "Coins", 1, "retained_add").Code, "Closing")
		assertEqual(wallet:TrySpend(first, "Coins", 1, "retained_spend").Code, "Closing")
		assertEqual(wallet:Add(first, "Coins", 0, "retained_noop").Code, "Closing")
		assertEqual(wallet:GetBalance(first, "Coins"), retainedBalance, "retained Wallet balance mutated")
		assertEqual(wallet:GetMemento(first).LastTransactionSequence, retainedSequence, "retained Wallet sequence mutated")
		assertEqual(walletChanged, changedBeforeRejectedMutation, "retained Wallet emitted a public change")
		assertEqual(queuedWalletChanges, queuedBeforeRejectedMutation, "retained Wallet queued a client mutation")
		now = 10
		runCycle()
		assertEqual(controller:GetState(first), "CloseFailed", "first bounded retry unexpectedly escaped failure")
		assertTrue(lockOwned, "failed bounded retry released the lock")
		failPreparation = false
		assertTrue(statistics:PrepareForProfileClose(first).Ok, "real Statistics preparation did not recover")
		now = 20
		runCycle()
		assertEqual(controller:GetState(first), "NotLoaded", "transient preparation retry did not close")
		assertEqual(lockOwned, false, "successful preparation retry left a perpetual lock")
		assertEqual(savedDocument.Providers.Wallet.Data.Coins, 11, "retained Wallet capture/order was not persisted")

		local replacement = makePlayer(30_009)
		scope:Defer(function() replacement:Destroy() end)
		service:Add(replacement)
		assertTrue(controller:IsLoaded(replacement), "same-key rejoin could not acquire after terminal cleanup")
		assertTrue(controller:Close(replacement, true).Ok, "same-key replacement did not close cleanly")
		assertEqual(releaseCalls, 2, "rejoin lifecycle release count drifted")

		failPreparation = false
		local persistent = makePlayer(30_010)
		scope:Defer(function() persistent:Destroy() end)
		service:Add(persistent)
		assertTrue(controller:IsLoaded(persistent), "persistent preparation fixture did not load")
		failPreparation = true
		service:Remove(persistent)
		for _, boundary in { 30, 40, 50 } do
			now = boundary
			runCycle()
		end
		assertEqual(
			controller:GetState(persistent),
			"NotLoaded",
			"persistent preparation failure did not reach bounded fail-closed finalization"
		)
		assertEqual(lockOwned, false, "persistent preparation failure retained a perpetual lock")
		assertEqual(releaseCalls, 3, "persistent fail-closed release count drifted")
	end)

	test("client patches accept only valid client-authority providers", function(scope)
		local serverProvider = makeProvider("ServerOwned", "Server")
		local clientProvider = makeProvider("ClientOwned", "Client")
		scope:Defer(function()
			serverProvider:Destroy()
			clientProvider:Destroy()
		end)
		local controller = makeController("client_patch_contract", { serverProvider, clientProvider })
		scope:Defer(function()
			controller:Destroy(false)
		end)
		local player = { UserId = 20 } :: any
		assertTrue(controller:Load(player).Ok, "controller load failed")

		local result = controller:ApplyClientPatch(player, {
			Providers = {
				ServerOwned = { Data = { Value = 2 } },
				ClientOwned = { Data = { Value = 3 } },
				Unknown = { Data = { Value = 4 } },
				Invalid = "not-an-envelope",
			},
		})
		assertTrue(table.find(result.AcceptedProviders, "ClientOwned") ~= nil, "client provider was rejected")
		assertTrue(table.find(result.RejectedProviders, "ServerOwned") ~= nil, "server provider was accepted")
		assertTrue(table.find(result.RejectedProviders, "Unknown") ~= nil, "unknown provider was accepted")
		assertTrue(table.find(result.RejectedProviders, "Invalid") ~= nil, "malformed provider was accepted")
		assertEqual(clientProvider:GetValue(player), 3)
		assertEqual(serverProvider:GetValue(player), 1)

		local invalid = controller:ApplyClientPatch(player, {
			Providers = {
				ClientOwned = { Data = { Value = "bad" } },
			},
		})
		assertTrue(table.find(invalid.RejectedProviders, "ClientOwned") ~= nil, "invalid client data was accepted")
		assertEqual(clientProvider:GetValue(player), 3)
	end)

	test("client patch and close own reciprocal yield-safe lifecycle reservations", function(scope)
		local provider = makeProvider("YieldingClient", "Client")
		local originalApply = provider.ApplyClientMemento
		local yieldedApplyThread = nil :: thread?
		local shouldYieldApply = true
		provider.ApplyClientMemento = function(self, player, value)
			originalApply(self, player, value)
			if shouldYieldApply then
				shouldYieldApply = false
				yieldedApplyThread = coroutine.running()
				coroutine.yield()
			end
		end
		local memory = MemoryStorage.new()
		local controller = ServerSaveController.new({
			Id = "yielding_client_patch",
			Providers = { provider },
			Storage = SessionLockingStorage.new(memory, { StaleLockSeconds = 1_800 }),
			KeyResolver = function() return "yielding_client_patch" end,
			Logger = makeLogger(),
		})
		local player = { UserId = 30_003 } :: any
		scope:Defer(function()
			if yieldedApplyThread ~= nil and coroutine.status(yieldedApplyThread :: thread) == "suspended" then
				task.spawn(yieldedApplyThread :: thread)
			end
			controller:Close(player, false)
			controller:Destroy(false)
			provider:Destroy()
		end)
		assertTrue(controller:Load(player).Ok, "yielding patch fixture did not load")

		local patchResult = nil :: any
		local closeResult = nil :: any
		task.spawn(function()
			patchResult = controller:ApplyClientPatch(player, {
				Providers = {
					YieldingClient = { Version = 1, Data = { Value = 2 } },
				},
			})
		end)
		waitUntil(function() return yieldedApplyThread ~= nil end)
		task.spawn(function()
			closeResult = controller:Close(player, true)
		end)
		waitUntil(function()
			local runtime = controller._runtimes[player]
			return runtime ~= nil and runtime.CloseRequested
		end)
		assertEqual(closeResult, nil, "close bypassed the active patch lifecycle reservation")
		task.spawn(yieldedApplyThread :: thread)
		waitUntil(function() return patchResult ~= nil and closeResult ~= nil end)
		assertEqual(#patchResult.AcceptedProviders, 0, "patch acknowledged a provider after close was requested")
		assertTrue(
			table.find(patchResult.RejectedProviders, "YieldingClient") ~= nil,
			"closing patch did not return a non-acknowledging rejection"
		)
		assertTrue(closeResult.Ok, "close did not complete after the patch relinquished ownership")
		assertEqual(controller:GetState(player), "NotLoaded")
		assertEqual(
			memory:Read("yielding_client_patch").Providers.YieldingClient.Data.Value,
			2,
			"close did not capture the mutation that preceded the provider yield"
		)

		local secondProvider = makeProvider("CloseFirstClient", "Client")
		local second = makeController("close_first_patch", { secondProvider })
		local secondPlayer = { UserId = 30_004 } :: any
		scope:Defer(function()
			second:Close(secondPlayer, false)
			second:Destroy(false)
			secondProvider:Destroy()
		end)
		assertTrue(second:Load(secondPlayer).Ok, "close-first patch fixture did not load")
		assertTrue(second:Close(secondPlayer, false).Ok, "close-first terminal cleanup failed")
		local afterClose = second:ApplyClientPatch(secondPlayer, {
			Providers = {
				CloseFirstClient = { Version = 1, Data = { Value = 3 } },
			},
		})
		assertEqual(#afterClose.AcceptedProviders, 0, "terminally closed runtime acknowledged a later patch")
		assertEqual(secondProvider:GetValue(secondPlayer), 1, "close-first patch mutated a stopped provider")
	end)

	test("pre-release close failures are failure-atomic and retry-owned", function(scope)
		local captureProvider = makeProvider("CaptureClient", "Client")
		local failCapture = true
		captureProvider.BeforeMementoGet = function()
			if failCapture then error("injected close capture failure") end
		end
		local captureMemory = MemoryStorage.new()
		local captureController = ServerSaveController.new({
			Id = "capture_close_failure",
			Providers = { captureProvider },
			Storage = SessionLockingStorage.new(captureMemory, { StaleLockSeconds = 1_800 }),
			KeyResolver = function() return "capture_close_failure" end,
			Logger = makeLogger(),
		})
		local capturePlayer = { UserId = 30_005 } :: any
		scope:Defer(function()
			failCapture = false
			captureController:Close(capturePlayer, false)
			captureController:Destroy(false)
			captureProvider:Destroy()
		end)
		assertTrue(captureController:Load(capturePlayer).Ok, "capture failure fixture did not load")
		local captureFailure = captureController:Close(capturePlayer, true)
		assertEqual(captureFailure.Code, "CaptureFailed")
		assertEqual(captureController:GetState(capturePlayer), "CloseFailed")
		assertEqual(captureController:IsLoaded(capturePlayer), false)
		assertTrue(captureController:ShouldRefreshLock(capturePlayer), "capture failure lost heartbeat ownership")
		assertTrue(captureController:RefreshLock(capturePlayer).Ok, "capture failure lock was not refreshable")
		assertEqual(captureController:ForceSave(capturePlayer).Code, "NotLoaded")
		assertEqual(captureController:BuildSnapshot(capturePlayer), nil)
		local rejectedPatch = captureController:ApplyClientPatch(capturePlayer, {
			Providers = {
				CaptureClient = { Version = 1, Data = { Value = 9 } },
			},
		})
		assertEqual(#rejectedPatch.AcceptedProviders, 0, "capture-failed runtime admitted gameplay mutation")
		assertEqual(captureProvider:GetValue(capturePlayer), 1)
		failCapture = false
		assertTrue(captureController:Close(capturePlayer, false).Ok, "capture failure retry did not finish")
		assertEqual(
			captureMemory:Read("capture_close_failure").Providers.CaptureClient.Data.Value,
			1,
			"capture retry did not preserve the original save intent"
		)

		local deadlineProvider = makeProvider("DeadlineProvider", "Server")
		local deadlineController = makeController("save_deadline_close", { deadlineProvider })
		local deadlinePlayer = { UserId = 30_006 } :: any
		scope:Defer(function()
			deadlineController:Close(deadlinePlayer, false)
			deadlineController:Destroy(false)
			deadlineProvider:Destroy()
		end)
		assertTrue(deadlineController:Load(deadlinePlayer).Ok, "save deadline fixture did not load")
		local deadlineFailure = deadlineController:Close(deadlinePlayer, true, {
			Deadline = os.clock() - 1,
		})
		assertEqual(deadlineFailure.Code, "DeadlineExceeded")
		assertEqual(deadlineController:GetState(deadlinePlayer), "CloseFailed")
		assertTrue(deadlineController:ShouldRefreshLock(deadlinePlayer), "save deadline lost heartbeat ownership")
		assertEqual(deadlineController:ForceSave(deadlinePlayer).Code, "NotLoaded")
		assertTrue(deadlineController:Close(deadlinePlayer, false).Ok, "save deadline retry did not finish")

		local waitProvider = makeProvider("WaitDeadlineClient", "Client")
		local originalValidate = waitProvider.ValidateMemento
		local yieldedValidationThread = nil :: thread?
		local yieldValidation = true
		waitProvider.ValidateMemento = function(self, player, value)
			if yieldValidation and value.Value == 7 then
				yieldValidation = false
				yieldedValidationThread = coroutine.running()
				coroutine.yield()
			end
			return originalValidate(self, player, value)
		end
		local waitController = makeController("wait_deadline_close", { waitProvider })
		local waitPlayer = { UserId = 30_007 } :: any
		scope:Defer(function()
			if yieldedValidationThread ~= nil and coroutine.status(yieldedValidationThread :: thread) == "suspended" then
				task.spawn(yieldedValidationThread :: thread)
			end
			waitController:Close(waitPlayer, false)
			waitController:Destroy(false)
			waitProvider:Destroy()
		end)
		assertTrue(waitController:Load(waitPlayer).Ok, "wait deadline fixture did not load")
		local waitPatch = nil :: any
		task.spawn(function()
			waitPatch = waitController:ApplyClientPatch(waitPlayer, {
				Providers = {
					WaitDeadlineClient = { Version = 1, Data = { Value = 7 } },
				},
			})
		end)
		waitUntil(function() return yieldedValidationThread ~= nil end)
		local waitFailure = waitController:Close(waitPlayer, true, { Deadline = os.clock() - 1 })
		assertEqual(waitFailure.Code, "DeadlineExceeded")
		assertTrue(waitController:IsLoaded(waitPlayer), "wait deadline did not fully reopen the runtime")
		task.spawn(yieldedValidationThread :: thread)
		waitUntil(function() return waitPatch ~= nil end)
		assertTrue(
			table.find(waitPatch.AcceptedProviders, "WaitDeadlineClient") ~= nil,
			"reopened lifecycle did not resume its reserved mutation"
		)
		assertEqual(waitProvider:GetValue(waitPlayer), 7)
		assertTrue(waitController:ShouldRefreshLock(waitPlayer), "reopened wait deadline lost heartbeat ownership")
		assertTrue(waitController:Close(waitPlayer, true).Ok, "reopened wait deadline was not retryable")
	end)

	test("close wait withdrawal is request and generation safe for every transient operation", function(scope)
		local function runCase(kind: string, failAfterYield: boolean)
			local provider = makeProvider(`Withdrawal{kind}{if failAfterYield then "Failure" else "Success"}`, "Client")
			local originalValidate = provider.ValidateMemento
			local yieldedThread = nil :: thread?
			local triggerBoundary = false
			local operationDone = false
			local operationSucceeded = false

			local function boundary()
				if not triggerBoundary then return end
				triggerBoundary = false
				yieldedThread = coroutine.running()
				coroutine.yield()
				if failAfterYield then
					error(`injected {kind} post-yield failure`)
				end
			end

			if kind == "Capturing" then
				provider.BeforeMementoGet = boundary
			elseif kind == "Snapshotting" then
				provider.ToClientMemento = function(_self, _player, value)
					boundary()
					return value
				end
			elseif kind == "Applying" then
				provider.ValidateMemento = function(self, player, value)
					if triggerBoundary and value.Value == 2 then boundary() end
					return originalValidate(self, player, value)
				end
			end

			local storage = {
				Load = function()
					return {
						Ok = true,
						Document = {
							FormatVersion = 1,
							Revision = 0,
							Providers = {
								[provider.Id] = { Version = 1, Data = { Value = 1 } },
							},
							Metadata = { CreatedAt = 1, UpdatedAt = 1 },
						},
					}
				end,
				Save = function()
					if kind == "Saving" then
						boundary()
					end
					return { Ok = true }
				end,
				Refresh = function() return { Ok = true } end,
				Release = function() return { Ok = true } end,
			}
			local controller = ServerSaveController.new({
				Id = `withdrawal_{kind}_{tostring(failAfterYield)}`,
				Providers = { provider },
				Storage = storage,
				KeyResolver = function() return `withdrawal_{kind}_{tostring(failAfterYield)}` end,
				Logger = makeLogger(),
			})
			local player = { UserId = 31_000 + #kind + (if failAfterYield then 100 else 0) } :: any
			scope:Defer(function()
				if yieldedThread ~= nil and coroutine.status(yieldedThread :: thread) == "suspended" then
					task.spawn(yieldedThread :: thread)
				end
				controller:Close(player, false)
				controller:Destroy(false)
				provider:Destroy()
			end)
			assertTrue(controller:Load(player).Ok, `{kind} withdrawal fixture did not load`)
			triggerBoundary = true

			task.spawn(function()
				if kind == "Saving" then
					provider:ApplyClientMemento(player, { Value = 2 })
					provider.MementoChanged:Fire(player)
					operationSucceeded = controller:ForceSave(player).Ok
				elseif kind == "Capturing" then
					provider.MementoChanged:Fire(player)
					operationSucceeded = select(1, controller:FlushDirty(player))
				elseif kind == "Snapshotting" then
					operationSucceeded = controller:BuildSnapshot(player) ~= nil
				else
					operationSucceeded = pcall(function()
						controller:ApplyMemento(player, {
							FormatVersion = 1,
							Revision = 1,
							Providers = {
								[provider.Id] = { Version = 1, Data = { Value = 2 } },
							},
							Metadata = { CreatedAt = 1, UpdatedAt = 1 },
						})
					end)
				end
				operationDone = true
			end)
			waitUntil(function() return yieldedThread ~= nil end)
			local runtime = controller._runtimes[player]
			assertEqual(runtime.State, kind, `{kind} fixture did not expose the intended transient state`)
			local closeFailure = controller:Close(player, true, { Deadline = os.clock() - 1 })
			assertEqual(closeFailure.Code, "DeadlineExceeded", `{kind} wait did not honor its deadline`)
			assertEqual(runtime.CloseRequested, false, `{kind} wait left close requested after withdrawal`)
			assertEqual(runtime.ActiveClose, nil, `{kind} wait retained the withdrawn request owner`)
			task.spawn(yieldedThread :: thread)
			waitUntil(function() return operationDone end)
			assertEqual(operationSucceeded, not failAfterYield, `{kind} post-yield result drifted`)
			assertTrue(controller:IsLoaded(player), `{kind} completion did not restore gameplay authority`)
			assertTrue(controller:ShouldRefreshLock(player), `{kind} withdrawal lost heartbeat ownership`)
			assertTrue(controller:RefreshLock(player).Ok, `{kind} withdrawal could not refresh its lock`)
			assertTrue(controller:Close(player, true).Ok, `{kind} runtime could not close after withdrawal`)
		end

		for _, kind in { "Saving", "Capturing", "Snapshotting", "Applying" } do
			runCase(kind, false)
			runCase(kind, true)
		end
	end)

	test("every save failure retains data providers and lock before terminal retry", function(scope)
		local function runStorageFailure(code: string, throws: boolean?, malformedResult: any?)
			local provider = makeProvider(`SaveFailure{code}`, "Server")
			local failing = true
			local saveCalls = 0
			local releaseCalls = 0
			local storage = {
				Load = function()
					return {
						Ok = true,
						Document = {
							FormatVersion = 1,
							Revision = 0,
							Providers = { [provider.Id] = { Version = 1, Data = { Value = 1 } } },
							Metadata = { CreatedAt = 1, UpdatedAt = 1 },
						},
					}
				end,
				Save = function()
					saveCalls += 1
					if failing then
						if throws then error("injected storage exception") end
						if malformedResult ~= nil then return malformedResult end
						return { Ok = false, Code = code, Error = "injected save failure" }
					end
					return { Ok = true }
				end,
				Refresh = function() return { Ok = true } end,
				Release = function()
					releaseCalls += 1
					return { Ok = true }
				end,
			}
			local controller = ServerSaveController.new({
				Id = `save_failure_{code}`,
				Providers = { provider },
				Storage = storage,
				KeyResolver = function() return `save_failure_{code}` end,
				Logger = makeLogger(),
			})
			local player = { UserId = 32_000 + #code } :: any
			scope:Defer(function()
				failing = false
				controller:Close(player, false)
				controller:Destroy(false)
				provider:Destroy()
			end)
			assertTrue(controller:Load(player).Ok, `{code} fixture did not load`)
			provider:ApplyClientMemento(player, { Value = 2 })
			provider.MementoChanged:Fire(player)
			local result = controller:Close(player, true)
			assertEqual(result.Code, if throws then "SaveFailed" else code, `{code} result semantics drifted`)
			assertEqual(controller:GetState(player), "CloseFailed", `{code} did not retain terminal ownership`)
			assertEqual(provider.StopCalls, 0, `{code} stopped providers before a successful save`)
			assertEqual(releaseCalls, 0, `{code} released the lock before a successful save`)
			local authoritativeLoss = code == "LockLost" or code == "NoSessionLock"
			assertEqual(
				controller:ShouldRefreshLock(player),
				not authoritativeLoss,
				`{code} heartbeat ownership did not match authoritative lock state`
			)
			if not authoritativeLoss then
				assertTrue(controller:RefreshLock(player).Ok, `{code} retained lock could not refresh`)
			end
			failing = false
			assertTrue(controller:RetryClose(player, controller._runtimes[player]).Ok, `{code} retry did not close`)
			assertEqual(saveCalls, 2, `{code} retry did not reattempt the save exactly once`)
			assertEqual(provider.StopCalls, 1, `{code} retry did not stop the provider exactly once`)
			assertEqual(releaseCalls, 1, `{code} retry did not release exactly once`)
		end

		for _, code in { "RetryExhausted", "NoSessionLock", "LockLost", "TransformFailed" } do
			runStorageFailure(code)
		end
		runStorageFailure("SaveFailed", true)
		for _, malformed in { true, "truthy", { Ok = "true" }, { Ok = 1 }, {} } do
			runStorageFailure("SaveFailed", false, malformed)
		end

		local function runLocalFailure(expectedCode: string, mutate: (any, any, any) -> (() -> ())?)
			local provider = makeProvider(`LocalFailure{expectedCode}`, "Server")
			local saveCalls = 0
			local releaseCalls = 0
			local storage = {
				Load = function()
					return {
						Ok = true,
						Document = {
							FormatVersion = 1,
							Revision = 0,
							Providers = { [provider.Id] = { Version = 1, Data = { Value = 1 } } },
							Metadata = { CreatedAt = 1, UpdatedAt = 1 },
						},
					}
				end,
				Save = function() saveCalls += 1; return { Ok = true } end,
				Refresh = function() return { Ok = true } end,
				Release = function() releaseCalls += 1; return { Ok = true } end,
			}
			local controller = ServerSaveController.new({
				Id = `local_failure_{expectedCode}`,
				Providers = { provider },
				Storage = storage,
				KeyResolver = function() return `local_failure_{expectedCode}` end,
				Logger = makeLogger(),
			})
			local player = { UserId = 33_000 + #expectedCode } :: any
			scope:Defer(function()
				controller._softLimit = 3_500_000
				local envelope = controller._runtimes[player]
					and controller._runtimes[player].Document.Providers[provider.Id]
				if envelope then envelope.Data.Bad = nil end
				controller:Close(player, false)
				controller:Destroy(false)
				provider:Destroy()
			end)
			assertTrue(controller:Load(player).Ok, `{expectedCode} fixture did not load`)
			local runtime = controller._runtimes[player]
			local restoreMutation = mutate(controller, runtime, provider)
			runtime.Dirty = true
			local result = controller:Close(player, true)
			assertEqual(result.Code, expectedCode)
			assertEqual(provider.StopCalls, 0, `{expectedCode} stopped providers before save acceptance`)
			assertEqual(saveCalls, 0, `{expectedCode} reached storage despite local rejection`)
			assertEqual(releaseCalls, 0, `{expectedCode} released the lock despite local rejection`)
			assertTrue(controller:ShouldRefreshLock(player), `{expectedCode} lost heartbeat ownership`)
			if restoreMutation then restoreMutation() end
			controller._softLimit = 3_500_000
			runtime.Document.Providers[provider.Id].Data.Bad = nil
			assertTrue(controller:RetryClose(player, runtime).Ok, `{expectedCode} retry did not finish`)
			assertEqual(saveCalls, 1)
			assertEqual(releaseCalls, 1)
		end

		runLocalFailure("SerializeInvalid", function(_controller, _runtime, provider)
			local originalGet = provider.GetMemento
			local originalValidate = provider.ValidateMemento
			provider.GetMemento = function()
				return { Value = 1, Bad = function() end }
			end
			provider.ValidateMemento = function(_self, _player, value)
				return true, value, nil
			end
			return function()
				provider.GetMemento = originalGet
				provider.ValidateMemento = originalValidate
			end
		end)
		runLocalFailure("SizeLimit", function(controller, _runtime, _provider)
			controller._softLimit = 1
			return nil
		end)
	end)

	test("SetMemento failure rolls back every provider and preserves Loaded state", function(scope)
		local first = makeProvider("First", "Server")
		local second = makeProvider("Second", "Server", { FailSetValue = 2 })
		scope:Defer(function()
			first:Destroy()
			second:Destroy()
		end)
		local controller = makeController("set_rollback", { first, second })
		scope:Defer(function()
			controller:Destroy(false)
		end)
		local player = { UserId = 21 } :: any
		assertTrue(controller:Load(player).Ok, "controller load failed")

		assertThrows(function()
			controller:ApplyMemento(player, {
				Revision = 1,
				Providers = {
					First = { Version = 1, Data = { Value = 2 } },
					Second = { Version = 1, Data = { Value = 2 } },
				},
				Metadata = {},
			})
		end, "Snapshot transaction failed and was rolled back")
		assertEqual(controller:GetState(player), "Loaded")
		assertEqual(first:GetValue(player), 1)
		assertEqual(second:GetValue(player), 1)
	end)

	test("rollback cleanup failure moves the controller to ApplyFailed", function(scope)
		local first = makeProvider("First", "Server")
		local second = makeProvider("Second", "Server", {
			FailRunValue = 2,
			FailStopValue = 2,
		})
		scope:Defer(function()
			first:Destroy()
			second:Destroy()
		end)
		local controller = makeController("cleanup_failure", { first, second })
		scope:Defer(function()
			controller:Destroy(false)
		end)
		local player = { UserId = 22 } :: any
		assertTrue(controller:Load(player).Ok, "controller load failed")

		assertThrows(function()
			controller:ApplyMemento(player, {
				Revision = 1,
				Providers = {
					First = { Version = 1, Data = { Value = 2 } },
					Second = { Version = 1, Data = { Value = 2 } },
				},
				Metadata = {},
			})
		end, "Rollback cleanup failed")
		assertEqual(controller:GetState(player), "ApplyFailed")
	end)

	test("oversized prepared snapshots fail before mutating loaded runtime", function(scope)
		local provider = makeProvider("Test", "Server")
		local controller = makeController("prepared_size_limit", { provider }, 512)
		scope:Defer(function()
			controller:Destroy(false)
			provider:Destroy()
		end)
		local player = { UserId = 33 } :: any
		assertTrue(controller:Load(player).Ok, "initial controller load failed")
		assertEqual(provider:GetValue(player), 1)

		assertThrows(function()
			controller:ApplyMemento(player, {
				Revision = 1,
				Providers = {
					Test = { Version = 1, Data = { Value = 2 } },
				},
				Metadata = {},
				Padding = string.rep("x", 1_000),
			})
		end, "exceeds the 512-byte soft size limit")
		assertEqual(controller:GetState(player), "Loaded")
		assertEqual(provider:GetValue(player), 1, "oversized target mutated provider runtime")

		assertThrows(function()
			controller:ApplyMemento(player, {
				Revision = 2,
				Providers = {
					Test = { Version = 1, Data = { Value = 3 } },
				},
				Metadata = {},
				Unsafe = 0 / 0,
			})
		end, "not DataStore-safe")
		assertEqual(controller:GetState(player), "Loaded")
		assertEqual(provider:GetValue(player), 1, "unsafe target mutated provider runtime")
	end)

	test("migration chains every skipped version and orders specialized same-version controllers", function()
		local migration = MigrationModule.new(nil, {
			CurrentVersion = "3.0.0",
		})
		local order = {}
		local contexts = {}
		local function controller(targetVersion, controllerOrder, name, returnsDocument)
			return {
				Id = name,
				TargetVersion = targetVersion,
				Order = controllerOrder,
				Migrate = function(_self, document, context)
					table.insert(order, name)
					table.insert(contexts, `{context.SourceVersion}>{context.TargetVersion}:{context.MigrationId}`)
					document[name] = true
					return if returnsDocument then document else nil
				end,
			}
		end
		migration:Register(controller("2.0.0", 20, "SecondForV2", false))
		migration:Register(controller("1.0.0", 0, "ForV1", true))
		migration:Register(controller("2.0.0", 10, "FirstForV2", false))
		migration:Register(controller("3.0.0", 0, "ForV3", true))
		migration:Register(controller("4.0.0", 0, "Future", true))
		migration:Initialize()

		local source = {
			Providers = {
				Version = {
					Data = {
						PreviousVersion = "0.0.0",
					},
				},
			},
		}
		local result, checkpointCommitRequired = migration:Migrate(source)
		assertEqual(table.concat(order, ","), "ForV1,FirstForV2,SecondForV2,ForV3")
		assertEqual(
			table.concat(contexts, ","),
			"0.0.0>1.0.0:ForV1,1.0.0>2.0.0:FirstForV2,"
				.. "1.0.0>2.0.0:SecondForV2,2.0.0>3.0.0:ForV3"
		)
		assertEqual(result.Future, nil)
		assertEqual(source.ForV1, nil, "migration mutated its source document")
		assertEqual(checkpointCommitRequired, true)
	end)

	test("migration registration and semantic versions fail closed", function()
		local migration = MigrationModule.new(nil, {
			CurrentVersion = "2.0.0",
		})
		migration:Register({
			Id = "Valid",
			TargetVersion = "2.0.0",
			Order = 0,
			Migrate = function(_self, document)
				return document
			end,
		})
		assertThrows(function()
			migration:Register({
				Id = "Valid",
				TargetVersion = "2.0.0",
				Order = 1,
				Migrate = function() end,
			})
		end, "Duplicate migration Id")
		assertThrows(function()
			migration:Register({
				Id = "MalformedVersion",
				TargetVersion = "2.x.0",
				Order = 0,
				Migrate = function() end,
			})
		end, "MAJOR.MINOR.PATCH")
		assertThrows(function()
			migration:Register({
				Id = "NonCanonicalVersion",
				TargetVersion = "02.0.0",
				Order = 0,
				Migrate = function() end,
			})
		end, "canonical")
		assertThrows(function()
			migration:Register({
				Id = "UnsafeOrder",
				TargetVersion = "2.0.0",
				Order = 9_007_199_254_740_992,
				Migrate = function() end,
			})
		end, "safe integer")
		migration:Initialize()
		assertThrows(function()
			migration:Register({
				Id = "Late",
				TargetVersion = "2.0.0",
				Order = 2,
				Migrate = function() end,
			})
		end, "before Initialize")
		assertThrows(function()
			migration:GetPlan("3.0.0")
		end, "newer than server version")
		assertThrows(function()
			migration:Migrate({
				Providers = {
					Version = {
						Data = {
							PreviousVersion = "bad",
						},
					},
				},
			})
		end, "Stored PreviousVersion")
	end)

	test("migration snapshots scheduling metadata and callable at registration", function()
		local implementation: any = {
			Id = "Original",
			TargetVersion = "1.0.0",
			Order = 0,
			Migrate = function(_self, document)
				document.Original = true
			end,
		}
		local migration = MigrationModule.new({ implementation }, {
			CurrentVersion = "1.0.0",
		})
		implementation.Id = "Mutated"
		implementation.TargetVersion = "9.0.0"
		implementation.Order = 999
		implementation.Migrate = function()
			error("mutated callable must not execute")
		end
		migration:Initialize()

		local plan = migration:GetPlan("0.0.0")
		assertEqual(#plan, 1)
		assertEqual(plan[1].Id, "Original")
		local result = migration:Migrate({
			Providers = {
				Version = {
					Data = {
						PreviousVersion = "0.0.0",
					},
				},
			},
		})
		assertEqual(result.Original, true)
	end)

	test("migration isolates replacement documents returned by controllers", function()
		local sharedReplacement = {
			Providers = {
				Version = {
					Data = {
						PreviousVersion = "0.0.0",
					},
				},
			},
		}
		local migration = MigrationModule.new({
			{
				Id = "ReturnReplacement",
				TargetVersion = "1.0.0",
				Order = 0,
				Migrate = function()
					return sharedReplacement
				end,
			},
			{
				Id = "MutateReplacement",
				TargetVersion = "1.0.0",
				Order = 1,
				Migrate = function(_self, document)
					document.Migrated = true
				end,
			},
		}, {
			CurrentVersion = "1.0.0",
		})
		migration:Initialize()

		local result = migration:Migrate({
			Providers = {
				Version = {
					Data = {
						PreviousVersion = "0.0.0",
					},
				},
			},
		})
		assertEqual(result.Migrated, true)
		assertEqual(
			sharedReplacement.Migrated,
			nil,
			"a later controller mutated a replacement table owned outside the migration run"
		)
	end)

	test("migration rejects cyclic replacement documents before isolation copy", function()
		local cyclicReplacement = {
			Providers = {
				Version = {
					Data = {
						PreviousVersion = "0.0.0",
					},
				},
			},
		}
		cyclicReplacement.Self = cyclicReplacement
		local migration = MigrationModule.new({
			{
				Id = "CyclicReplacement",
				TargetVersion = "1.0.0",
				Order = 0,
				Migrate = function()
					return cyclicReplacement
				end,
			},
		}, {
			CurrentVersion = "1.0.0",
		})
		migration:Initialize()

		assertThrows(function()
			migration:Migrate({
				Providers = {
					Version = {
						Data = {
							PreviousVersion = "0.0.0",
						},
					},
				},
			})
		end, "Migration 'CyclicReplacement' returned an unsafe replacement document")
	end)

	test("migration failure isolates the source and rejects checkpoint or unsafe output", function()
		local function sourceDocument()
			return {
				Providers = {
					Version = {
						Data = {
							PreviousVersion = "1.0.0",
						},
					},
				},
				Value = 1,
			}
		end

		local failing = MigrationModule.new({
			{
				Id = "Throws",
				TargetVersion = "2.0.0",
				Order = 0,
				Migrate = function(_self, document)
					document.Value = 2
					error("injected migration failure")
				end,
			},
		}, {
			CurrentVersion = "2.0.0",
		})
		failing:Initialize()
		local source = sourceDocument()
		assertThrows(function()
			failing:Migrate(source)
		end, "Migration 'Throws' failed")
		assertEqual(source.Value, 1, "failed migration leaked mutations into its source")

		local checkpoint = MigrationModule.new({
			{
				Id = "Checkpoint",
				TargetVersion = "2.0.0",
				Order = 0,
				Migrate = function(_self, document)
					document.Providers.Version.Data.PreviousVersion = "2.0.0"
				end,
			},
		}, {
			CurrentVersion = "2.0.0",
		})
		checkpoint:Initialize()
		assertThrows(function()
			checkpoint:Migrate(sourceDocument())
		end, "must not modify")

		local unsafe = MigrationModule.new({
			{
				Id = "Unsafe",
				TargetVersion = "2.0.0",
				Order = 0,
				Migrate = function(_self, document)
					document.Value = 0 / 0
				end,
			},
		}, {
			CurrentVersion = "2.0.0",
		})
		unsafe:Initialize()
		assertThrows(function()
			unsafe:Migrate(sourceDocument())
		end, "not DataStore-safe")

		local invalidProviders = MigrationModule.new({
			{
				Id = "ArrayProviders",
				TargetVersion = "2.0.0",
				Order = 0,
				Migrate = function(_self, document)
					table.insert(document.Providers, {
						Version = 1,
						Data = {},
					})
				end,
			},
		}, {
			CurrentVersion = "2.0.0",
		})
		invalidProviders:Initialize()
		assertThrows(function()
			invalidProviders:Migrate(sourceDocument())
		end, "string-keyed dictionary")

		local lockMutation = MigrationModule.new({
			{
				Id = "LockMutation",
				TargetVersion = "2.0.0",
				Order = 0,
				Migrate = function(_self, document)
					document.Session.LockId = "stolen"
				end,
			},
		}, {
			CurrentVersion = "2.0.0",
		})
		lockMutation:Initialize()
		local lockedSource: any = sourceDocument()
		lockedSource.Session = {
			LockId = "owned",
		}
		assertThrows(function()
			lockMutation:Migrate(lockedSource)
		end, "storage-owned Session lock")

		local oversized = MigrationModule.new({
			{
				Id = "Oversized",
				TargetVersion = "2.0.0",
				Order = 0,
				Migrate = function(_self, document)
					document.Payload = string.rep("x", 2_000)
				end,
			},
		}, {
			CurrentVersion = "2.0.0",
			MaxSerializedBytes = 1_000,
		})
		oversized:Initialize()
		assertThrows(function()
			oversized:Migrate(sourceDocument())
		end, "exceeds the 1000-byte save limit")

		local oversizedEmptyTransition = MigrationModule.new(nil, {
			CurrentVersion = "2.0.0",
			MaxSerializedBytes = 1_000,
		})
		oversizedEmptyTransition:Initialize()
		local oversizedWithoutController = sourceDocument()
		oversizedWithoutController.Payload = string.rep("x", 2_000)
		assertThrows(function()
			oversizedEmptyTransition:Migrate(oversizedWithoutController)
		end, "exceeds the 1000-byte save limit")
	end)

	test("migration requires an explicit baseline for non-empty pre-checkpoint profiles", function()
		local source = {
			Providers = {
				Test = {
					Version = 1,
					Data = {
						Value = 1,
					},
				},
			},
		}
		local strict = MigrationModule.new(nil, {
			CurrentVersion = "1.0.0",
		})
		strict:Initialize()
		assertThrows(function()
			strict:Migrate(source)
		end, "configure LegacyBaselineVersion explicitly")
		assertThrows(function()
			strict:Migrate({
				Providers = {},
				LegacyValue = 1,
			})
		end, "configure LegacyBaselineVersion explicitly")
		local newProfile, checkpointCommitRequired = strict:Migrate({
			Providers = {},
		}, {
			IsNewProfile = true,
		})
		assertEqual(next(newProfile.Providers), nil)
		assertEqual(checkpointCommitRequired, false)

		local migrated = MigrationModule.new({
			{
				Id = "Legacy",
				TargetVersion = "1.0.0",
				Order = 0,
				Migrate = function(_self, document)
					document.Providers.Test.Data.Value = 2
				end,
			},
		}, {
			CurrentVersion = "1.0.0",
			LegacyBaselineVersion = "0.0.0",
		})
		migrated:Initialize()
		local result = migrated:Migrate(source)
		assertEqual(result.Providers.Test.Data.Value, 2)
		assertEqual(result.Providers.Version, nil, "migration created its owned checkpoint")

		local rawLegacy = MigrationModule.new({
			{
				Id = "ReadLegacyRoot",
				TargetVersion = "1.0.0",
				Order = 0,
				Migrate = function(_self, document)
					document.IntermediateValue = document.LegacyValue + 1
				end,
			},
			{
				Id = "CreateProviderRoot",
				TargetVersion = "1.0.0",
				Order = 1,
				Migrate = function(_self, document)
					document.Providers = {
						Test = {
							Version = 1,
							Data = {
								Value = document.IntermediateValue,
							},
						},
					}
					document.LegacyValue = nil
					document.IntermediateValue = nil
				end,
			},
		}, {
			CurrentVersion = "1.0.0",
			LegacyBaselineVersion = "0.0.0",
		})
		rawLegacy:Initialize()
		local rawResult = rawLegacy:Migrate({
			LegacyValue = 40,
		})
		assertEqual(rawResult.Providers.Test.Data.Value, 41)
		assertEqual(rawResult.LegacyValue, nil)

		local checkpointCreator = MigrationModule.new({
			{
				Id = "CheckpointCreator",
				TargetVersion = "1.0.0",
				Order = 0,
				Migrate = function(_self, document)
					document.Providers.Version = {
						Data = {
							PreviousVersion = "0.0.0",
						},
					}
				end,
			},
		}, {
			CurrentVersion = "1.0.0",
			LegacyBaselineVersion = "0.0.0",
		})
		checkpointCreator:Initialize()
		assertThrows(function()
			checkpointCreator:Migrate(source)
		end, "must not create")
	end)

	test("successful migration persists atomically and is skipped after checkpoint reload", function(scope)
		local key = "migration_success_28"
		local memory = MemoryStorage.new({
			[key] = {
				FormatVersion = 1,
				Revision = 7,
				Providers = {
					Version = {
						Version = 1,
						Data = {
							InstallationVersion = "0.0.0",
							PreviousVersion = "0.0.0",
							PlaceVersion = 0,
						},
					},
					Test = {
						Version = 1,
						Data = {
							Value = 10,
						},
					},
				},
				Metadata = {
					CreatedAt = 1,
					UpdatedAt = 1,
				},
				Session = nil,
			},
		})
		local storage = SessionLockingStorage.new(memory, {
			StaleLockSeconds = 1_800,
		})
		local executions = 0
		local migration = MigrationModule.new({
			{
				Id = "IncrementTest",
				TargetVersion = VersionConfig.CurrentVersion,
				Order = 0,
				Migrate = function(_self, document)
					executions += 1
					document.Providers.Test.Data.Value += 1
				end,
			},
		}, {
			CurrentVersion = VersionConfig.CurrentVersion,
			MaxSerializedBytes = 3_500_000,
		})
		migration:Initialize()

		local function buildController()
			local version = VersionModule.new()
			local provider = makeProvider("Test", "Server")
			local controller = ServerSaveController.new({
				Id = "migration_success",
				Providers = { provider, version },
				Storage = storage,
				KeyResolver = function()
					return key
				end,
				Logger = makeLogger(),
			})
			scope:Defer(function()
				controller:Destroy(false)
				version.MementoChanged:Destroy()
				provider:Destroy()
			end)
			return controller, provider
		end

		local firstController, firstProvider = buildController()
		local player = { UserId = 28 } :: any
		local firstLoad = firstController:Load(player, function(document)
			local migratedDocument, checkpointCommitRequired = migration:Migrate(document)
			return migratedDocument, if checkpointCommitRequired then { VersionConfig.ProviderId } else nil
		end)
		assertTrue(firstLoad.Ok, "first migrated load failed")
		assertEqual(firstProvider:GetValue(player), 11)
		assertEqual(executions, 1)
		local saveResult = firstController:ForceSave(player, "MigrationTest")
		assertTrue(saveResult.Ok, "migrated document failed to save immediately after load")
		assertTrue(firstController:Close(player, false).Ok, "first migrated close failed")

		local persisted = memory:Read(key)
		assertEqual(persisted.Providers.Test.Data.Value, 11)
		assertEqual(persisted.Providers.Version.Data.PreviousVersion, VersionConfig.CurrentVersion)
		assertEqual(persisted.Session, nil)

		local secondController, secondProvider = buildController()
		local secondLoad = secondController:Load(player, function(document)
			local migratedDocument, checkpointCommitRequired = migration:Migrate(document)
			return migratedDocument, if checkpointCommitRequired then { VersionConfig.ProviderId } else nil
		end)
		assertTrue(secondLoad.Ok, "checkpoint reload failed")
		assertEqual(secondProvider:GetValue(player), 11)
		assertEqual(executions, 1, "persisted migration executed again")
		assertTrue(secondController:Close(player, false).Ok, "checkpoint reload close failed")
	end)

	test("Version checkpoint does not advance when an earlier provider fails to run", function(scope)
		local key = "migration_provider_failure_27"
		local memory = MemoryStorage.new({
			[key] = {
				FormatVersion = 1,
				Revision = 1,
				Providers = {
					Test = {
						Version = 1,
						Data = {
							Value = 2,
						},
					},
					Version = {
						Version = 1,
						Data = {
							InstallationVersion = "0.0.0",
							PreviousVersion = "0.0.0",
							PlaceVersion = 0,
						},
					},
				},
				Metadata = {
					CreatedAt = 1,
					UpdatedAt = 1,
				},
				Session = nil,
			},
		})
		local storage = SessionLockingStorage.new(memory, {
			StaleLockSeconds = 1_800,
		})
		local provider = makeProvider("Test", "Server", {
			FailRunValue = 2,
		})
		local version = VersionModule.new()
		local checkpointChanges = 0
		version.MementoChanged:Connect(function()
			checkpointChanges += 1
		end)
		local controller = ServerSaveController.new({
			Id = "migration_provider_failure",
			Providers = { provider, version },
			Storage = storage,
			KeyResolver = function()
				return key
			end,
			Logger = makeLogger(),
		})
		scope:Defer(function()
			controller:Destroy(false)
			version.MementoChanged:Destroy()
			provider:Destroy()
		end)

		local player = { UserId = 27 } :: any
		local result = controller:Load(player)
		assertEqual(result.Ok, false)
		assertEqual(result.Code, "ApplyFailed")
		task.wait()
		assertEqual(checkpointChanges, 0, "Version committed before all domain providers ran")
		assertEqual(storage:HasLock(key), false)
		assertEqual(memory:Read(key).Providers.Version.Data.PreviousVersion, "0.0.0")
	end)

	test("migration failure aborts load before provider runtime and releases the session lock", function(scope)
		local provider = makeProvider("Test", "Server")
		scope:Defer(function()
			provider:Destroy()
		end)
		local memory = MemoryStorage.new()
		local storage = SessionLockingStorage.new(memory, {
			StaleLockSeconds = 1_800,
		})
		local controller = ServerSaveController.new({
			Id = "migration_failure",
			Providers = { provider },
			Storage = storage,
			KeyResolver = function(player)
				return `migration_failure_{player.UserId}`
			end,
			Logger = makeLogger(),
		})
		scope:Defer(function()
			controller:Destroy(false)
		end)
		local player = { UserId = 29 } :: any
		local result = controller:Load(player, function()
			error("injected raw migration failure")
		end)
		assertEqual(result.Ok, false)
		assertEqual(result.Code, "ApplyFailed")
		assertEqual(result.LockReleaseOk, true)
		assertEqual(controller:GetState(player), "LoadFailed")
		assertEqual(provider:GetValue(player), nil, "provider runtime changed before migration completed")
		assertEqual(storage:HasLock("migration_failure_29"), false, "failed migration leaked its session lock")
	end)

	test("persistent pre-apply transforms revalidate lock ownership before runtime application", function(scope)
		local provider = makeProvider("Test", "Server")
		local ownedStorage = SessionLockingStorage.new(MemoryStorage.new(), {
			StaleLockSeconds = 1_800,
		})
		local refreshCalls = 0
		local releaseCalls = 0
		local storage = {
			Load = function(_self, key)
				return ownedStorage:Load(key)
			end,
			Refresh = function()
				refreshCalls += 1
				return {
					Ok = false,
					Code = "LockLost",
					Error = "injected ownership loss",
				}
			end,
			Release = function(_self, key)
				releaseCalls += 1
				return ownedStorage:Release(key)
			end,
		}
		local controller = ServerSaveController.new({
			Id = "migration_lock_revalidation",
			Providers = { provider },
			Storage = storage,
			KeyResolver = function()
				return "migration_lock_revalidation_32"
			end,
			Logger = makeLogger(),
		})
		scope:Defer(function()
			controller:Destroy(false)
			provider:Destroy()
		end)

		local player = { UserId = 32 } :: any
		local result = controller:Load(player, function(document)
			document.Transformed = true
			return document, { "Test" }
		end)
		assertEqual(result.Ok, false)
		assertEqual(result.Code, "ApplyFailed")
		assertTrue(
			string.find(result.Error, "Session lock could not be confirmed", 1, true) ~= nil,
			"lock revalidation failure was not surfaced"
		)
		assertEqual(refreshCalls, 1)
		assertEqual(releaseCalls, 1)
		assertEqual(provider:GetValue(player), nil, "runtime applied after lock ownership was lost")
	end)

	test("load failure surfaces a session-lock release failure", function(scope)
		local provider = makeProvider("Test", "Server")
		scope:Defer(function()
			provider:Destroy()
		end)
		local ownedStorage = SessionLockingStorage.new(MemoryStorage.new(), {
			StaleLockSeconds = 1_800,
		})
		local storage = {
			Load = function(_self, key)
				return ownedStorage:Load(key)
			end,
			Release = function()
				return {
					Ok = false,
					Code = "RetryExhausted",
					Error = "injected release failure",
				}
			end,
		}
		local controller = ServerSaveController.new({
			Id = "migration_release_failure",
			Providers = { provider },
			Storage = storage,
			KeyResolver = function(player)
				return `migration_release_failure_{player.UserId}`
			end,
			Logger = makeLogger(),
		})
		scope:Defer(function()
			ownedStorage:Release("migration_release_failure_31")
			controller:Destroy(false)
		end)
		local player = { UserId = 31 } :: any
		local result = controller:Load(player, function()
			error("injected raw migration failure")
		end)
		assertEqual(result.Ok, false)
		assertEqual(result.Code, "ApplyFailed")
		assertEqual(result.LockReleaseOk, false)
		assertEqual(result.LockReleaseCode, "RetryExhausted")
		assertTrue(
			string.find(result.Error, "Session lock release also failed", 1, true) ~= nil,
			"release failure was hidden from load result"
		)
	end)

	test("load failure normalizes a malformed session-lock release result", function(scope)
		local provider = makeProvider("Test", "Server")
		local ownedStorage = SessionLockingStorage.new(MemoryStorage.new(), {
			StaleLockSeconds = 1_800,
		})
		local storage = {
			Load = function(_self, key)
				return ownedStorage:Load(key)
			end,
			Release = function()
				return nil
			end,
		}
		local controller = ServerSaveController.new({
			Id = "migration_malformed_release",
			Providers = { provider },
			Storage = storage,
			KeyResolver = function()
				return "migration_malformed_release_33"
			end,
			Logger = makeLogger(),
		})
		scope:Defer(function()
			ownedStorage:Release("migration_malformed_release_33")
			controller:Destroy(false)
			provider:Destroy()
		end)

		local result = controller:Load({ UserId = 33 } :: any, function()
			error("injected raw migration failure")
		end)
		assertEqual(result.Ok, false)
		assertEqual(result.Code, "ApplyFailed")
		assertEqual(result.LockReleaseOk, false)
		assertEqual(result.LockReleaseCode, "ReleaseFailed")
		assertTrue(
			string.find(result.Error, "Storage Release returned an invalid result", 1, true) ~= nil,
			"malformed release result was not normalized"
		)
	end)

	test("Version providers reject malformed data and emit dirty only for real upgrades", function(scope)
		local server = VersionModule.new()
		local client = VersionClient.new()
		scope:Defer(function()
			server.MementoChanged:Destroy()
		end)
		local player = { UserId = 30 } :: any
		local dirty = 0
		server.MementoChanged:Connect(function()
			dirty += 1
		end)

		local current = {
			InstallationVersion = VersionConfig.CurrentVersion,
			PreviousVersion = VersionConfig.CurrentVersion,
			PlaceVersion = game.PlaceVersion,
		}
		assertTrue(server:ValidateMemento(player, current), "server rejected current Version data")
		assertTrue(client:ValidateMemento(current), "client rejected current Version data")
		assertEqual(client:ValidateMemento({
			InstallationVersion = "invalid",
			PreviousVersion = "1.0.0",
			PlaceVersion = 0,
		}), false)
		assertEqual(client:ValidateMemento({
			InstallationVersion = "1.0.0",
			PreviousVersion = "1.0.0",
			PlaceVersion = 0.5,
		}), false)
		assertEqual(client:ValidateMemento({
			InstallationVersion = "01.0.0",
			PreviousVersion = "1.0.0",
			PlaceVersion = 0,
		}), false)
		assertEqual(client:ValidateMemento({
			InstallationVersion = "1.0.0",
			PreviousVersion = "1.0.0",
			PlaceVersion = math.huge,
		}), false)

		server:SetMemento(player, current)
		server:Run(player)
		task.wait()
		assertEqual(dirty, 0)
		server:Stop(player)

		server:SetMemento(player, {
			InstallationVersion = "0.1.0",
			PreviousVersion = "0.1.0",
			PlaceVersion = math.max(0, game.PlaceVersion - 1),
		})
		server:Run(player)
		waitUntil(function()
			return dirty == 1
		end)
		server:Stop(player)
	end)

	test("GameData forwards isolated changes, supports deterministic timeout, and cleans up", function(scope)
		local ready = Signal.new()
		local changed = Signal.new()
		scope:Defer(function()
			ready:Destroy()
			changed:Destroy()
		end)
		local revision = 4
		local controllerReady = false
		local now = 0
		local controller = {
			Ready = ready,
			IsReady = function()
				return controllerReady
			end,
			GetRevision = function()
				return revision
			end,
		}
		local providerValue = { Coins = 5 }
		local provider = {
			Id = "Wallet",
			Changed = changed,
			GetMemento = function()
				return table.clone(providerValue)
			end,
		}
		local gameData = ClientGameData.new(controller, { provider }, {
			Clock = function()
				return now
			end,
			Wait = function(seconds)
				now += seconds or 0
				return seconds or 0
			end,
		})
		scope:Defer(function()
			gameData:Destroy()
		end)
		ClientGameData.set(gameData)

		local observedReady = nil
		local observedChange = nil
		gameData.Ready:Connect(function(value)
			observedReady = value
		end)
		gameData.ItemChanged:Connect(function(value)
			observedChange = value
		end)
		ready:Fire(revision)
		changed:Fire({
			ProviderId = "Wallet",
			Path = { "Coins" },
			NewValue = 6,
		})
		waitUntil(function()
			return observedReady ~= nil and observedChange ~= nil
		end)
		assertEqual(observedReady, 4)
		assertEqual(observedChange.ItemId, "Wallet")
		assertEqual(observedChange.ProfileRevision, 4)
		assertEqual(gameData:GetValue("Wallet", { "Coins" }), 5)
		assertEqual(gameData:WaitUntilReady(0.1), false)
		controllerReady = true
		assertEqual(gameData:WaitUntilReady(0.1), true)
		assertEqual(ClientGameData.get(), gameData)
		gameData:Destroy()
		assertThrows(function()
			ClientGameData.get()
		end, "not initialized")
	end)

	test("client PlayersModule delivers existing character, respawn, and idempotent cleanup", function(scope)
		local existingCharacter = {} :: any
		local nextCharacter = {} :: any
		local player = makePlayer(40, existingCharacter)
		local service = {
			LocalPlayer = player,
		}
		scope:Defer(function()
			player:Destroy()
		end)
		local module = ClientPlayersModule.new(service)
		scope:Defer(function()
			module:Stop()
		end)
		assertThrows(function()
			module:GetLocalPlayer()
		end, "PlayersModuleNotInitialized")
		assertThrows(function()
			module.CharacterAdded:Connect(function() end)
		end, "PlayersModuleNotInitialized")
		module:Initialize()
		module:Initialize()
		assertEqual(module:GetLocalPlayer(), player)
		assertEqual(
			(module :: any).LocalPlayer,
			nil,
			"client PlayersModule exposed mutable LocalPlayer state outside its getter-only public contract"
		)
		assertEqual(module:GetCharacter(), existingCharacter)
		assertEqual(module:WaitForCharacter(), existingCharacter)
		local added = {}
		local removed = {}
		local addedConnection = module.CharacterAdded:Connect(function(character)
			table.insert(added, character)
		end)
		module.CharacterRemoving:Connect(function(character)
			table.insert(removed, character)
		end)
		player.CharacterRemoving:Fire(existingCharacter)
		player.Character = nextCharacter
		player.CharacterAdded:Fire(nextCharacter)
		waitUntil(function()
			return #added == 1 and #removed == 1
		end)
		assertEqual(module:GetLocalPlayer(), player)
		assertEqual(module:GetCharacter(), nextCharacter)
		assertEqual(module:WaitForCharacter(), nextCharacter)
		module:Stop()
		module:Stop()
		assertEqual(addedConnection.Connected, false)
		assertEqual((module.CharacterAdded :: any).Wait, nil)
		assertEqual((module.CharacterAdded :: any).Fire, nil)
		assertEqual((module.CharacterAdded :: any).Destroy, nil)
		assertThrows(function()
			module:GetCharacter()
		end, "PlayersModuleTerminal")
		assertThrows(function()
			module:Initialize()
		end, "PlayersModuleTerminal")
		player.CharacterAdded:Fire({} :: any)
		task.wait()
		assertEqual(#added, 1, "stopped client player wrapper leaked a connection")
	end)

	test("PlayersModule public state matrices reject every unsupported operation", function(scope)
		local service = makePlayersService()
		local player = makePlayer(4_410)
		local model = {} :: any
		scope:Defer(function()
			service:Destroy()
			player:Destroy()
		end)

		local server = ServerPlayersModule.new(service)
		scope:Defer(function()
			server:Stop()
		end)
		local function serverOperations(includeInitialize: boolean): { [string]: () -> () }
			local operations = {
				GetPlayers = function() server:GetPlayers() end,
				GetPlayerByUserId = function() server:GetPlayerByUserId(player.UserId) end,
				GetPlayerFromCharacter = function() server:GetPlayerFromCharacter(model) end,
				ObservePlayers = function() server:ObservePlayers(function() end) end,
				PlayerAddedConnect = function() server.PlayerAdded:Connect(function() end) end,
				PlayerAddedOnce = function() server.PlayerAdded:Once(function() end) end,
				PlayerRemovingConnect = function() server.PlayerRemoving:Connect(function() end) end,
				PlayerRemovingOnce = function() server.PlayerRemoving:Once(function() end) end,
				CharacterAddedConnect = function() server.CharacterAdded:Connect(function() end) end,
				CharacterAddedOnce = function() server.CharacterAdded:Once(function() end) end,
				CharacterRemovingConnect = function() server.CharacterRemoving:Connect(function() end) end,
				CharacterRemovingOnce = function() server.CharacterRemoving:Once(function() end) end,
			}
			if includeInitialize then
				operations.Initialize = function() server:Initialize() end
			end
			return operations
		end
		assertOperationsThrow(serverOperations(false), "PlayersModuleNotInitialized")
		assertEqual((server.PlayerAdded :: any).Wait, nil)
		assertEqual((server.PlayerAdded :: any).Fire, nil)
		assertEqual((server.PlayerAdded :: any).Destroy, nil)
		server:Stop()
		server:Stop()
		assertOperationsThrow(serverOperations(true), "PlayersModuleTerminal")

		local activeService = makePlayersService()
		scope:Defer(function()
			activeService:Destroy()
		end)
		local activeServer = ServerPlayersModule.new(activeService)
		scope:Defer(function()
			activeServer:Stop()
		end)
		activeServer:Initialize()
		local playerAddedConnections = activeService.PlayerAdded:ActiveCount()
		local playerRemovingConnections = activeService.PlayerRemoving:ActiveCount()
		assertThrows(function()
			activeServer:ObservePlayers(nil :: any)
		end, "onAdded required")
		assertEqual(activeService.PlayerAdded:ActiveCount(), playerAddedConnections)
		assertEqual(activeService.PlayerRemoving:ActiveCount(), playerRemovingConnections)
		local failedObserverCalls = 0
		activeService.FailGetPlayers = true
		assertThrows(function()
			activeServer:ObservePlayers(function()
				failedObserverCalls += 1
			end)
		end, "injected GetPlayers failure")
		activeService.FailGetPlayers = false
		local firstObserverCalls = 0
		local secondObserverCalls = 0
		local firstDisconnect = nil :: (() -> ())?
		firstDisconnect = activeServer:ObservePlayers(function()
			firstObserverCalls += 1
			assert(firstDisconnect ~= nil)
			local disconnectFirst = firstDisconnect :: () -> ()
			disconnectFirst()
		end)
		local secondDisconnect = activeServer:ObservePlayers(function()
			secondObserverCalls += 1
		end)
		scope:Defer(secondDisconnect)
		local firstObserved = makePlayer(4_413)
		local secondObserved = makePlayer(4_414)
		scope:Defer(function()
			firstObserved:Destroy()
			secondObserved:Destroy()
		end)
		activeService:Add(firstObserved)
		activeService:Add(secondObserved)
		waitUntil(function()
			return firstObserverCalls == 1 and secondObserverCalls == 2
		end)
		task.wait()
		assertEqual(failedObserverCalls, 0, "failed observer registration retained its callback")

		local client = ClientPlayersModule.new({ LocalPlayer = player })
		scope:Defer(function()
			client:Stop()
		end)
		local function clientOperations(includeInitialize: boolean): { [string]: () -> () }
			local operations = {
				GetLocalPlayer = function() client:GetLocalPlayer() end,
				GetCharacter = function() client:GetCharacter() end,
				WaitForCharacter = function() client:WaitForCharacter() end,
				CharacterAddedConnect = function() client.CharacterAdded:Connect(function() end) end,
				CharacterAddedOnce = function() client.CharacterAdded:Once(function() end) end,
				CharacterRemovingConnect = function() client.CharacterRemoving:Connect(function() end) end,
				CharacterRemovingOnce = function() client.CharacterRemoving:Once(function() end) end,
			}
			if includeInitialize then
				operations.Initialize = function() client:Initialize() end
			end
			return operations
		end
		assertOperationsThrow(clientOperations(false), "PlayersModuleNotInitialized")
		assertEqual((client.CharacterAdded :: any).Wait, nil)
		assertEqual((client.CharacterAdded :: any).Fire, nil)
		assertEqual((client.CharacterAdded :: any).Destroy, nil)
		client:Stop()
		client:Stop()
		assertOperationsThrow(clientOperations(true), "PlayersModuleTerminal")
	end)

	test("PlayersModule terminal cleanup suppresses later callback entry without joining started work", function(scope)
		local service = makePlayersService()
		local player = makePlayer(4_411)
		scope:Defer(function()
			service:Destroy()
			player:Destroy()
		end)
		local server = ServerPlayersModule.new(service)
		scope:Defer(function()
			server:Stop()
		end)
		server:Initialize()
		local serverThread = nil :: thread?
		local serverFinished = false
		local laterServerCalls = 0
		server.PlayerAdded:Connect(function()
			serverThread = coroutine.running()
			server:Stop()
			coroutine.yield()
			serverFinished = true
		end)
		server.PlayerAdded:Connect(function()
			laterServerCalls += 1
		end)
		service:Add(player)
		assert(serverThread ~= nil)
		assertEqual(serverFinished, false)
		assertEqual(laterServerCalls, 0, "server callback entered after terminal cleanup")
		task.spawn(serverThread :: thread)
		waitUntil(function()
			return serverFinished
		end)

		local clientPlayer = makePlayer(4_412)
		scope:Defer(function()
			clientPlayer:Destroy()
		end)
		local client = ClientPlayersModule.new({ LocalPlayer = clientPlayer })
		scope:Defer(function()
			client:Stop()
		end)
		client:Initialize()
		local clientThread = nil :: thread?
		local clientFinished = false
		local laterClientCalls = 0
		client.CharacterAdded:Connect(function()
			clientThread = coroutine.running()
			client:Stop()
			coroutine.yield()
			clientFinished = true
		end)
		client.CharacterAdded:Connect(function()
			laterClientCalls += 1
		end)
		local character = {} :: any
		clientPlayer.Character = character
		clientPlayer.CharacterAdded:Fire(character)
		assert(clientThread ~= nil)
		assertEqual(clientFinished, false)
		assertEqual(laterClientCalls, 0, "client callback entered after terminal cleanup")
		task.spawn(clientThread :: thread)
		waitUntil(function()
			return clientFinished
		end)
	end)

	test("server PlayersModule owns join, leave, character, lookup, and repeated cleanup", function(scope)
		local service = makePlayersService()
		local player = makePlayer(41)
		local character = {} :: any
		scope:Defer(function()
			service:Destroy()
			player:Destroy()
		end)
		local module = ServerPlayersModule.new(service)
		scope:Defer(function()
			module:Stop()
		end)
		assertThrows(function()
			module:GetPlayers()
		end, "PlayersModuleNotInitialized")
		assertThrows(function()
			module.PlayerAdded:Connect(function() end)
		end, "PlayersModuleNotInitialized")
		module:Initialize()
		module:Initialize()
		local added = 0
		local removed = 0
		local charactersAdded = 0
		local charactersRemoved = 0
		module.PlayerAdded:Connect(function()
			added += 1
		end)
		module.PlayerRemoving:Connect(function()
			removed += 1
		end)
		module.CharacterAdded:Connect(function()
			charactersAdded += 1
		end)
		module.CharacterRemoving:Connect(function()
			charactersRemoved += 1
		end)
		service:Add(player)
		waitUntil(function()
			return added == 1
		end)
		player.Character = character
		player.CharacterAdded:Fire(character)
		waitUntil(function()
			return charactersAdded == 1
		end)
		assertEqual(module:GetPlayerByUserId(41), player)
		assertEqual(module:GetPlayerFromCharacter(character), player)
		service:Remove(player)
		waitUntil(function()
			return removed == 1 and charactersRemoved == 1
		end)
		module:Stop()
		module:Stop()
		assertThrows(function()
			module:GetPlayerByUserId(41)
		end, "PlayersModuleTerminal")
		assertThrows(function()
			module:Initialize()
		end, "PlayersModuleTerminal")
		service:Add(player)
		task.wait()
		assertEqual(added, 1, "stopped server player wrapper leaked a connection")
	end)

	test("server PlayersModule tracks an existing character through removal and respawn", function(scope)
		local service = makePlayersService()
		local firstCharacter = {} :: any
		local secondCharacter = {} :: any
		local player = makePlayer(4_101, firstCharacter)
		service:Add(player)
		scope:Defer(function()
			service:Destroy()
			player:Destroy()
		end)

		local module = ServerPlayersModule.new(service)
		scope:Defer(function()
			module:Stop()
		end)
		module:Initialize()
		assertEqual(player.CharacterAdded:ActiveCount(), 1, "existing player was not tracked during Initialize")
		assertEqual(player.CharacterRemoving:ActiveCount(), 1, "existing character removal was not observed")

		local removals = {}
		local additions = {}
		module.CharacterRemoving:Connect(function(observedPlayer, character)
			table.insert(removals, { Player = observedPlayer, Character = character })
		end)
		module.CharacterAdded:Connect(function(observedPlayer, character)
			table.insert(additions, { Player = observedPlayer, Character = character })
		end)

		player.Character = nil
		player.CharacterRemoving:Fire(firstCharacter)
		waitUntil(function()
			return #removals == 1
		end)
		assertEqual(removals[1].Player, player)
		assertEqual(removals[1].Character, firstCharacter)

		player.Character = secondCharacter
		player.CharacterAdded:Fire(secondCharacter)
		waitUntil(function()
			return #additions == 1
		end)
		assertEqual(additions[1].Player, player)
		assertEqual(additions[1].Character, secondCharacter)

		player.CharacterAdded:Fire(secondCharacter)
		task.wait()
		assertEqual(#removals, 1, "existing character removal was duplicated")
		assertEqual(#additions, 1, "respawn character add was duplicated")
	end)

	test("server terminal Stop releases observers and public listeners", function(scope)
		local service = makePlayersService()
		local player = makePlayer(42)
		scope:Defer(function()
			service:Destroy()
			player:Destroy()
		end)
		service:Add(player)
		local module = ServerPlayersModule.new(service)
		scope:Defer(function()
			module:Stop()
		end)
		module:Initialize()

		local publicCalls = 0
		local observerCalls = 0
		local publicConnection = module.PlayerAdded:Once(function()
			publicCalls += 1
		end)
		local disconnect = module:ObservePlayers(function()
			observerCalls += 1
		end)
		assertEqual(observerCalls, 1)
		module:Stop()
		module:Stop()
		assertEqual(publicConnection.Connected, false)
		disconnect()
		disconnect()

		local latePlayer = makePlayer(43)
		scope:Defer(function()
			latePlayer:Destroy()
		end)
		service:Add(latePlayer)
		task.wait()
		assertEqual(publicCalls, 0)
		assertEqual(observerCalls, 1)
		assertEqual(service.PlayerAdded:ActiveCount(), 0)
		assertEqual(service.PlayerRemoving:ActiveCount(), 0)
		assertEqual(player.CharacterAdded:ActiveCount(), 0)
		assertEqual(player.CharacterRemoving:ActiveCount(), 0)
		assertThrows(function()
			module:ObservePlayers(function() end)
		end, "PlayersModuleTerminal")
	end)

	test("server initialization failures roll back and remain terminal", function(scope)
		local firstConnectionService = makePlayersService()
		firstConnectionService.PlayerAdded.FailConnectAt = 1
		scope:Defer(function()
			firstConnectionService:Destroy()
		end)
		local firstConnectionFailure = ServerPlayersModule.new(firstConnectionService)
		scope:Defer(function()
			firstConnectionFailure:Stop()
		end)
		assertThrows(function()
			firstConnectionFailure:Initialize()
		end, "injected connection failure")
		assertEqual(firstConnectionService.PlayerAdded:ActiveCount(), 0)
		assertEqual(firstConnectionService.PlayerRemoving:ActiveCount(), 0)
		assertThrows(function()
			firstConnectionFailure:Initialize()
		end, "PlayersModuleTerminal")

		local service = makePlayersService()
		service.PlayerRemoving.FailConnectAt = 1
		scope:Defer(function()
			service:Destroy()
		end)
		local module = ServerPlayersModule.new(service)
		scope:Defer(function()
			module:Stop()
		end)
		assertThrows(function()
			module:Initialize()
		end, "injected connection failure")
		assertEqual(service.PlayerAdded:ActiveCount(), 0)
		assertEqual(service.PlayerRemoving:ActiveCount(), 0)
		assertThrows(function()
			module:Initialize()
		end, "PlayersModuleTerminal")
		assertThrows(function()
			module:GetPlayers()
		end, "PlayersModuleTerminal")
		assertOperationsThrow({
			GetPlayerByUserId = function() module:GetPlayerByUserId(1) end,
			GetPlayerFromCharacter = function() module:GetPlayerFromCharacter({} :: any) end,
			ObservePlayers = function() module:ObservePlayers(function() end) end,
			PlayerAddedConnect = function() module.PlayerAdded:Connect(function() end) end,
			PlayerAddedOnce = function() module.PlayerAdded:Once(function() end) end,
			PlayerRemovingConnect = function() module.PlayerRemoving:Connect(function() end) end,
			PlayerRemovingOnce = function() module.PlayerRemoving:Once(function() end) end,
			CharacterAddedConnect = function() module.CharacterAdded:Connect(function() end) end,
			CharacterAddedOnce = function() module.CharacterAdded:Once(function() end) end,
			CharacterRemovingConnect = function() module.CharacterRemoving:Connect(function() end) end,
			CharacterRemovingOnce = function() module.CharacterRemoving:Once(function() end) end,
		}, "PlayersModuleTerminal")

		local freshService = makePlayersService()
		scope:Defer(function()
			freshService:Destroy()
		end)
		local fresh = ServerPlayersModule.new(freshService)
		scope:Defer(function()
			fresh:Stop()
		end)
		fresh:Initialize()
		assertEqual(#fresh:GetPlayers(), 0)

		local characterService = makePlayersService()
		local characterPlayer = makePlayer(4_401)
		characterPlayer.CharacterRemoving.FailConnectAt = 1
		characterService:Add(characterPlayer)
		scope:Defer(function()
			characterService:Destroy()
			characterPlayer:Destroy()
		end)
		local characterFailure = ServerPlayersModule.new(characterService)
		scope:Defer(function()
			characterFailure:Stop()
		end)
		assertThrows(function()
			characterFailure:Initialize()
		end, "injected connection failure")
		assertEqual(characterService.PlayerAdded:ActiveCount(), 0)
		assertEqual(characterService.PlayerRemoving:ActiveCount(), 0)
		assertEqual(characterPlayer.CharacterAdded:ActiveCount(), 0)
		assertEqual(characterPlayer.CharacterRemoving:ActiveCount(), 0)

		local firstCharacterService = makePlayersService()
		local firstCharacterPlayer = makePlayer(4_404)
		firstCharacterPlayer.CharacterAdded.FailConnectAt = 1
		firstCharacterService:Add(firstCharacterPlayer)
		scope:Defer(function()
			firstCharacterService:Destroy()
			firstCharacterPlayer:Destroy()
		end)
		local firstCharacterFailure = ServerPlayersModule.new(firstCharacterService)
		scope:Defer(function()
			firstCharacterFailure:Stop()
		end)
		assertThrows(function()
			firstCharacterFailure:Initialize()
		end, "injected connection failure")
		assertEqual(firstCharacterService.PlayerAdded:ActiveCount(), 0)
		assertEqual(firstCharacterService.PlayerRemoving:ActiveCount(), 0)
		assertEqual(firstCharacterPlayer.CharacterAdded:ActiveCount(), 0)
		assertEqual(firstCharacterPlayer.CharacterRemoving:ActiveCount(), 0)
		assertThrows(function()
			firstCharacterFailure:GetPlayers()
		end, "PlayersModuleTerminal")

		local enumerationService = makePlayersService()
		enumerationService.FailGetPlayers = true
		scope:Defer(function()
			enumerationService:Destroy()
		end)
		local enumerationFailure = ServerPlayersModule.new(enumerationService)
		scope:Defer(function()
			enumerationFailure:Stop()
		end)
		assertThrows(function()
			enumerationFailure:Initialize()
		end, "injected GetPlayers failure")
		assertEqual(enumerationService.PlayerAdded:ActiveCount(), 0)
		assertEqual(enumerationService.PlayerRemoving:ActiveCount(), 0)
		assertThrows(function()
			enumerationFailure:Initialize()
		end, "PlayersModuleTerminal")

		local interruptedService = makePlayersService()
		local interrupted = nil :: any
		local reentrantError = nil :: any
		interruptedService.PlayerAdded.OnConnect = function()
			local ok, result = pcall(function()
				return interrupted:GetPlayers()
			end)
			assertEqual(ok, false)
			reentrantError = result
			interrupted:Stop()
		end
		interrupted = ServerPlayersModule.new(interruptedService)
		scope:Defer(function()
			interruptedService:Destroy()
			interrupted:Stop()
		end)
		assertThrows(function()
			interrupted:Initialize()
		end, "PlayersModuleTerminal")
		assertTrue(string.find(tostring(reentrantError), "PlayersModuleInitializing", 1, true) ~= nil, "server reentrant state was not observable")
		assertEqual(interruptedService.PlayerAdded:ActiveCount(), 0)
	end)

	test("client initialization failures and waiters terminate cleanly", function(scope)
		local nilModule = ClientPlayersModule.new({ LocalPlayer = nil })
		scope:Defer(function()
			nilModule:Stop()
		end)
		assertThrows(function()
			nilModule:Initialize()
		end, "LocalPlayer is not available")
		assertThrows(function()
			nilModule:GetLocalPlayer()
		end, "PlayersModuleTerminal")

		local firstConnectionPlayer = makePlayer(4_405)
		firstConnectionPlayer.CharacterAdded.FailConnectAt = 1
		local firstConnectionModule = ClientPlayersModule.new({ LocalPlayer = firstConnectionPlayer })
		scope:Defer(function()
			firstConnectionPlayer:Destroy()
			firstConnectionModule:Stop()
		end)
		assertThrows(function()
			firstConnectionModule:Initialize()
		end, "injected connection failure")
		assertEqual(firstConnectionPlayer.CharacterAdded:ActiveCount(), 0)
		assertEqual(firstConnectionPlayer.CharacterRemoving:ActiveCount(), 0)
		assertThrows(function()
			firstConnectionModule:GetLocalPlayer()
		end, "PlayersModuleTerminal")

		local partialPlayer = makePlayer(4_402)
		partialPlayer.CharacterRemoving.FailConnectAt = 1
		local partialModule = ClientPlayersModule.new({ LocalPlayer = partialPlayer })
		scope:Defer(function()
			partialPlayer:Destroy()
			partialModule:Stop()
		end)
		assertThrows(function()
			partialModule:Initialize()
		end, "injected connection failure")
		assertEqual(partialPlayer.CharacterAdded:ActiveCount(), 0)
		assertEqual(partialPlayer.CharacterRemoving:ActiveCount(), 0)
		assertThrows(function()
			partialModule:GetCharacter()
		end, "PlayersModuleTerminal")
		assertOperationsThrow({
			Initialize = function() partialModule:Initialize() end,
			GetLocalPlayer = function() partialModule:GetLocalPlayer() end,
			WaitForCharacter = function() partialModule:WaitForCharacter() end,
			CharacterAddedConnect = function() partialModule.CharacterAdded:Connect(function() end) end,
			CharacterAddedOnce = function() partialModule.CharacterAdded:Once(function() end) end,
			CharacterRemovingConnect = function() partialModule.CharacterRemoving:Connect(function() end) end,
			CharacterRemovingOnce = function() partialModule.CharacterRemoving:Once(function() end) end,
		}, "PlayersModuleTerminal")

		local interruptedPlayer = makePlayer(4_403)
		local interruptedClient = nil :: any
		local clientReentrantError = nil :: any
		interruptedPlayer.CharacterAdded.OnConnect = function()
			local ok, result = pcall(function()
				return interruptedClient:GetLocalPlayer()
			end)
			assertEqual(ok, false)
			clientReentrantError = result
			interruptedClient:Stop()
		end
		interruptedClient = ClientPlayersModule.new({ LocalPlayer = interruptedPlayer })
		scope:Defer(function()
			interruptedPlayer:Destroy()
			interruptedClient:Stop()
		end)
		assertThrows(function()
			interruptedClient:Initialize()
		end, "PlayersModuleTerminal")
		assertTrue(string.find(tostring(clientReentrantError), "PlayersModuleInitializing", 1, true) ~= nil, "client reentrant state was not observable")
		assertEqual(interruptedPlayer.CharacterAdded:ActiveCount(), 0)

		local player = makePlayer(44)
		local module = ClientPlayersModule.new({ LocalPlayer = player })
		scope:Defer(function()
			player:Destroy()
			module:Stop()
		end)
		module:Initialize()
		local waiterStarted = false
		local waiterOk = nil :: boolean?
		local waiterValue = nil :: any
		task.spawn(function()
			waiterStarted = true
			waiterOk, waiterValue = pcall(function()
				return module:WaitForCharacter()
			end)
		end)
		waitUntil(function()
			return waiterStarted
		end)
		local character = {} :: any
		player.Character = character
		player.CharacterAdded:Fire(character)
		waitUntil(function()
			return waiterOk ~= nil
		end)
		assertEqual(waiterOk, true)
		assertEqual(waiterValue, character)

		player.Character = nil
		player.CharacterRemoving:Fire(character)
		waiterOk = nil
		waiterValue = nil
		task.spawn(function()
			waiterOk, waiterValue = pcall(function()
				return module:WaitForCharacter()
			end)
		end)
		task.wait()
		module:Stop()
		waitUntil(function()
			return waiterOk ~= nil
		end)
		assertEqual(waiterOk, false)
		assertTrue(string.find(tostring(waiterValue), "PlayersModuleTerminal", 1, true) ~= nil, "waiter missed terminal error")
	end)

	test("server initial observation isolates throw and preserves serial yield", function(scope)
		local service = makePlayersService()
		local first = makePlayer(45)
		local second = makePlayer(46)
		local future = makePlayer(47)
		scope:Defer(function()
			service:Destroy()
			first:Destroy()
			second:Destroy()
			future:Destroy()
		end)
		service:Add(first)
		service:Add(second)
		local module = ServerPlayersModule.new(service)
		scope:Defer(function()
			module:Stop()
		end)
		module:Initialize()

		local moduleEnvironment = getfenv(ServerPlayersModule.ObservePlayers)
		local originalWarn = moduleEnvironment.warn
		local expectedDiagnostic = nil :: string?
		moduleEnvironment.warn = function(message)
			expectedDiagnostic = tostring(message)
		end
		scope:Defer(function()
			moduleEnvironment.warn = originalWarn
		end)
		local delivered = {}
		local disconnect = module:ObservePlayers(function(player)
			table.insert(delivered, player.UserId)
			if player == first then
				error("expected initial observer failure")
			end
		end)
		disconnect()
		assertEqual(delivered[1], first.UserId)
		assertEqual(delivered[2], second.UserId)
		assertTrue(
			expectedDiagnostic ~= nil
				and string.find(expectedDiagnostic, "[PlayersModule] initial observer error:", 1, true) ~= nil
				and string.find(expectedDiagnostic, "expected initial observer failure", 1, true) ~= nil
				and string.find(expectedDiagnostic, "\n", 1, true) ~= nil
				and string.find(expectedDiagnostic, "function ObservePlayers", 1, true) ~= nil,
			"initial observer diagnostic did not preserve its traceback"
		)

		local yieldedThread = nil :: thread?
		local returned = false
		local futureDelivered = false
		local order = {}
		local yieldedDisconnect = nil :: (() -> ())?
		task.spawn(function()
			yieldedDisconnect = module:ObservePlayers(function(player)
				if player == first then
					table.insert(order, "first-start")
					yieldedThread = coroutine.running()
					coroutine.yield()
					table.insert(order, "first-end")
				elseif player == second then
					table.insert(order, "second")
				elseif player == future then
					futureDelivered = true
				end
			end)
			returned = true
		end)
		waitUntil(function()
			return yieldedThread ~= nil
		end)
		service:Add(future)
		waitUntil(function()
			return futureDelivered
		end)
		assertEqual(returned, false)
		assertEqual(order[1], "first-start")
		assertEqual(order[2], nil)
		task.spawn(yieldedThread :: thread)
		waitUntil(function()
			return returned
		end)
		assertEqual(order[2], "first-end")
		assertEqual(order[3], "second")
		assert(yieldedDisconnect ~= nil)
		local disconnectYielded = yieldedDisconnect :: () -> ()
		disconnectYielded()
	end)

	test("PlayersModule character races and delivery cost remain bounded", function(scope)
		local service = makePlayersService()
		local initialCharacter = {} :: any
		local player = makePlayer(48, initialCharacter)
		player.CharacterAdded.OnConnect = function()
			player.CharacterAdded:Fire(initialCharacter)
		end
		scope:Defer(function()
			service:Destroy()
			player:Destroy()
		end)
		local module = ServerPlayersModule.new(service)
		scope:Defer(function()
			module:Stop()
		end)
		module:Initialize()
		local characterAdds = 0
		local characterRemovals = 0
		module.CharacterAdded:Connect(function(observedPlayer, character)
			assertEqual(observedPlayer, player)
			assertEqual(character, initialCharacter)
			characterAdds += 1
		end)
		module.CharacterRemoving:Connect(function(observedPlayer, character)
			assertEqual(observedPlayer, player)
			assertEqual(character, initialCharacter)
			characterRemovals += 1
		end)
		service:Add(player)
		waitUntil(function()
			return characterAdds == 1
		end)
		assertEqual(characterAdds, 1, "character add race emitted a duplicate fact")

		local observers = 3
		local deliveries = 0
		local removals = 0
		local disconnects = {}
		for _ = 1, observers do
			table.insert(disconnects, module:ObservePlayers(function()
				deliveries += 1
			end, function()
				removals += 1
			end))
		end
		assertEqual(deliveries, observers)
		local lookupsAfterExisting = service.GetPlayerByUserIdCalls
		player.CharacterRemoving:Fire(initialCharacter)
		waitUntil(function()
			return characterRemovals == 1
		end)
		service:Remove(player)
		waitUntil(function()
			return removals == observers
		end)
		assertEqual(characterRemovals, 1, "stale player.Character duplicated character removal")
		assertTrue(service.GetPlayerByUserIdCalls - lookupsAfterExisting <= 1, "leave performed superlinear lookups")
		for _, disconnect in disconnects do
			disconnect()
		end
		module:Stop()
		assertEqual(service.PlayerAdded:ActiveCount(), 0)
		assertEqual(service.PlayerRemoving:ActiveCount(), 0)
		assertEqual(player.CharacterAdded:ActiveCount(), 0)
		assertEqual(player.CharacterRemoving:ActiveCount(), 0)
	end)

	test("PlayersModule stale identity and 0 1 N delivery counters remain exact", function(scope)
		local signalEnvironment = getfenv(Signal.Fire)
		local originalTask = signalEnvironment.task
		local scheduledListenerTasks = 0
		local instrumentedTask = table.clone(originalTask)
		instrumentedTask.spawn = function(...)
			scheduledListenerTasks += 1
			return originalTask.spawn(...)
		end
		signalEnvironment.task = instrumentedTask
		scope:Defer(function()
			signalEnvironment.task = originalTask
		end)

		local staleService = makePlayersService()
		local stalePlayer = makePlayer(4_420)
		local replacementPlayer = makePlayer(4_420)
		scope:Defer(function()
			staleService:Destroy()
			stalePlayer:Destroy()
			replacementPlayer:Destroy()
		end)
		staleService:Add(stalePlayer)
		local staleModule = ServerPlayersModule.new(staleService)
		scope:Defer(function()
			staleModule:Stop()
		end)
		staleModule:Initialize()
		local addedPlayers = {}
		local removedPlayers = {}
		local disconnectStale = staleModule:ObservePlayers(function(player)
			table.insert(addedPlayers, player)
		end, function(player)
			table.insert(removedPlayers, player)
		end)
		scope:Defer(disconnectStale)
		assertEqual(#addedPlayers, 1)
		assertEqual(addedPlayers[1], stalePlayer)
		staleService:Replace(stalePlayer, replacementPlayer)
		staleService.PlayerAdded:Fire(stalePlayer)
		staleService.PlayerAdded:Fire(replacementPlayer)
		waitUntil(function()
			return #addedPlayers == 2
		end)
		assertEqual(addedPlayers[2], replacementPlayer, "replacement identity was not delivered")
		staleService:Remove(stalePlayer)
		task.wait()
		assertEqual(#removedPlayers, 1)
		assertEqual(removedPlayers[1], stalePlayer)
		staleService.PlayerAdded:Fire(replacementPlayer)
		task.wait()
		assertEqual(#addedPlayers, 2, "stale removal cleared replacement membership")
		staleService:Remove(replacementPlayer)
		waitUntil(function()
			return #removedPlayers == 2
		end)
		assertEqual(removedPlayers[2], replacementPlayer)

		local function measure(observerCount: number)
			local service = makePlayersService()
			local first = makePlayer(5_000 + observerCount * 10)
			local second = makePlayer(5_001 + observerCount * 10)
			local joined = makePlayer(5_002 + observerCount * 10)
			scope:Defer(function()
				service:Destroy()
				first:Destroy()
				second:Destroy()
				joined:Destroy()
			end)
			service:Add(first)
			service:Add(second)
			local module = ServerPlayersModule.new(service)
			scope:Defer(function()
				module:Stop()
			end)
			module:Initialize()
			local deliveries = 0
			local removals = 0
			local publicPlayerAdds = 0
			local publicPlayerRemovals = 0
			local playerAddedProbe = module.PlayerAdded:Connect(function()
				publicPlayerAdds += 1
			end)
			local playerRemovingProbe = module.PlayerRemoving:Connect(function()
				publicPlayerRemovals += 1
			end)
			scope:Defer(function()
				playerAddedProbe:Disconnect()
				playerRemovingProbe:Disconnect()
			end)
			local disconnects = {}
			local getPlayersBeforeObservers = service.GetPlayersCalls
			local lookupBeforeObservers = service.GetPlayerByUserIdCalls
			local scheduledBeforeExisting = scheduledListenerTasks
			for _ = 1, observerCount do
				table.insert(disconnects, module:ObservePlayers(function()
					deliveries += 1
				end, function()
					removals += 1
				end))
			end
			assertEqual(deliveries, observerCount * 2)
			assertEqual(service.GetPlayersCalls - getPlayersBeforeObservers, observerCount)
			assertEqual(service.GetPlayerByUserIdCalls - lookupBeforeObservers, observerCount * 2)
			assertEqual(publicPlayerAdds, 0, "existing enumeration unexpectedly fired the public PlayerAdded signal")
			assertEqual(
				scheduledListenerTasks - scheduledBeforeExisting,
				0,
				"existing enumeration unexpectedly scheduled Signal listener tasks"
			)

			local lookupBeforeJoin = service.GetPlayerByUserIdCalls
			local platformDispatchesBeforeJoin = service.PlayerAdded.FireCalls
			local scheduledBeforeJoin = scheduledListenerTasks
			service:Add(joined)
			waitUntil(function()
				return publicPlayerAdds == 1 and deliveries == observerCount * 3
			end)
			assertEqual(service.PlayerAdded.FireCalls - platformDispatchesBeforeJoin, 1)
			assertEqual(publicPlayerAdds, 1, "join did not produce exactly one Players-side PlayerAdded dispatch")
			assertEqual(
				scheduledListenerTasks - scheduledBeforeJoin,
				observerCount + 2,
				"join scheduled-task count was not one platform listener plus one public probe and one task per observer"
			)
			assertEqual(
				service.GetPlayerByUserIdCalls - lookupBeforeJoin,
				observerCount + 1,
				"join lookup growth was not one tracking lookup plus one per observer"
			)

			local lookupBeforeLeave = service.GetPlayerByUserIdCalls
			local platformRemovalsBeforeLeave = service.PlayerRemoving.FireCalls
			local scheduledBeforeLeave = scheduledListenerTasks
			service:Remove(joined)
			waitUntil(function()
				return publicPlayerRemovals == 1 and removals == observerCount
			end)
			assertEqual(service.PlayerRemoving.FireCalls - platformRemovalsBeforeLeave, 1)
			assertEqual(publicPlayerRemovals, 1, "leave did not produce exactly one Players-side PlayerRemoving dispatch")
			assertEqual(
				scheduledListenerTasks - scheduledBeforeLeave,
				observerCount + 2,
				"leave scheduled-task count was not one platform listener plus one public probe and one task per observer"
			)
			assertEqual(service.GetPlayerByUserIdCalls - lookupBeforeLeave, 0)
			for _, disconnect in disconnects do
				disconnect()
				disconnect()
			end
			module:Stop()
			assertEqual(service.PlayerAdded:ActiveCount(), 0)
			assertEqual(service.PlayerRemoving:ActiveCount(), 0)
			assertEqual(first.CharacterAdded:ActiveCount(), 0)
			assertEqual(second.CharacterAdded:ActiveCount(), 0)
			assertEqual(joined.CharacterAdded:ActiveCount(), 0)
		end

		for _, observerCount in { 0, 1, 3 } do
			measure(observerCount)
		end
	end)

	test("SaveModule removal retains retryable cleanup ownership on both sides", function(scope)
		local scheduled = {}
		local autoSave = AutoSaveModule.new(makeLogger(), {
			Clock = function() return 0 end,
			Random = function() return 0 end,
			Spawn = function(callback) table.insert(scheduled, callback) end,
			Wait = function(seconds) return seconds end,
		})
		scope:Defer(function() autoSave:Stop() end)
		local sessionLock = SessionLockModule.new(60, makeLogger())
		scope:Defer(function() sessionLock:Stop() end)
		local serverModule = ServerSaveModule.new({
			OnControllerRemoving = function(controller)
				assertTrue(autoSave:UnregisterController(controller), "successful removal lost autosave ownership")
				assertTrue(sessionLock:UnregisterController(controller), "successful removal lost session-lock ownership")
			end,
		})
		serverModule:Initialize()
		local serverBehaviors = {}
		scope:Defer(function()
			for _, behavior in serverBehaviors do behavior.FailStopValue = nil end
			serverModule:RemoveAllSaveControllers(false)
		end)

		local function makeServerFixture(id: string, userId: number): any
			local behavior = { FailStopValue = 2 }
			table.insert(serverBehaviors, behavior)
			local provider = makeProvider(`Provider{id}`, "Server", behavior)
			scope:Defer(function() provider:Destroy() end)
			local releaseCalls = 0
			local storage = {
				Load = function()
					return {
						Ok = true,
						Document = {
							FormatVersion = 1,
							Revision = 4,
							Providers = { [`Provider{id}`] = { Version = 1, Data = { Value = 2 } } },
							Metadata = { CreatedAt = 1, UpdatedAt = 1 },
						},
					}
				end,
				Save = function() return { Ok = true } end,
				Release = function() releaseCalls += 1; return { Ok = true } end,
			}
			local controller = serverModule:BuildSaveController(id)
				:WithSaveProvider(provider)
				:WithStorage(storage)
				:WithKeyResolver(function() return `retryable_{id}` end)
				:Build()
			autoSave:RegisterController(controller, { IntervalSeconds = 60 })
			assertEqual(sessionLock:RegisterController(controller), true)
			local player = { UserId = userId } :: any
			assertTrue(controller:Load(player).Ok, "server cleanup fixture failed to load")
			local closedCount = 0
			local closedConnection = controller.PlayerClosed:Connect(function(closedPlayer)
				assertEqual(closedPlayer, player)
				closedCount += 1
			end)
			return {
				Id = id,
				Behavior = behavior,
				Provider = provider,
				Controller = controller,
				Player = player,
				Runtime = controller._runtimes[player],
				ClosedConnection = closedConnection,
				ClosedCount = function() return closedCount end,
				ReleaseCalls = function() return releaseCalls end,
			}
		end

		local function assertServerRetained(fixture: any)
			assertEqual(serverModule:GetSaveController(fixture.Id), fixture.Controller)
			assertEqual(fixture.Controller._runtimes[fixture.Player], fixture.Runtime)
			assertEqual(fixture.Controller:GetState(fixture.Player), "CloseFailed")
			assertTrue(fixture.Provider.Active[fixture.Player] == true, "failed Stop lost active-provider ownership")
			assertEqual(fixture.ReleaseCalls(), 0, "storage lock released before provider cleanup succeeded")
			assertTrue(fixture.ClosedConnection.Connected, "terminal signal was destroyed on failed cleanup")
			assertEqual(fixture.ClosedCount(), 0)
			local requestOk, requestResult = pcall(function()
				return autoSave:RequestSave(fixture.Controller, fixture.Player, "RetainedCleanup", 1_000)
			end)
			assertTrue(requestOk and requestResult.Code == "Queued", "autosave owner was dropped on failed cleanup")
			assertEqual(
				sessionLock:RegisterController(fixture.Controller),
				false,
				"session-lock scheduler ownership was dropped on failed cleanup"
			)
		end

		local function assertServerReleased(fixture: any)
			assertEqual(serverModule:GetSaveController(fixture.Id), nil)
			assertEqual(fixture.Controller._runtimes[fixture.Player], nil)
			assertTrue(fixture.Provider.Active[fixture.Player] == nil, "successful retry left provider active")
			assertEqual(fixture.ReleaseCalls(), 1, "successful retry must release exactly one storage lock")
			assertTrue(not fixture.ClosedConnection.Connected, "successful cleanup did not destroy terminal signals")
			for _ = 1, 10 do
				if fixture.ClosedCount() == 1 then break end
				task.wait()
			end
			assertEqual(fixture.ClosedCount(), 1, "successful retry must publish exactly one PlayerClosed signal")
			assertThrows(function()
				autoSave:RequestSave(fixture.Controller, fixture.Player, "Removed", 0)
			end, "not registered")
			assertEqual(
				sessionLock:UnregisterController(fixture.Controller),
				false,
				"successful cleanup left a session-lock scheduler entry"
			)
		end

		local serverSingle = makeServerFixture("server_single_retry", 31_001)
		local singleRemoved, singleCleanup = serverModule:RemoveSaveController(serverSingle.Id, false)
		assertEqual(singleRemoved, false)
		assertEqual(singleCleanup.Code, "DestroyFailed")
		assertServerRetained(serverSingle)
		serverSingle.Behavior.FailStopValue = nil
		assertEqual(serverModule:RemoveSaveController(serverSingle.Id, false), true)
		assertServerReleased(serverSingle)
		local serverRebuilt = makeServerFixture(serverSingle.Id, 31_003)
		assertEqual(
			serverModule:RemoveSaveController(serverSingle.Controller, false),
			false,
			"stale server object removed a same-ID replacement"
		)
		assertEqual(serverModule:GetSaveController(serverRebuilt.Id), serverRebuilt.Controller)
		assertTrue(serverRebuilt.Provider.Active[serverRebuilt.Player] == true, "stale server removal stopped replacement provider")
		assertTrue(serverRebuilt.ClosedConnection.Connected, "stale server removal destroyed replacement signal")
		assertEqual(serverRebuilt.ReleaseCalls(), 0, "stale server removal released replacement lock")
		assertEqual(
			autoSave:RequestSave(serverRebuilt.Controller, serverRebuilt.Player, "StaleOwner", 1_000).Code,
			"Queued",
			"stale server removal detached replacement autosave ownership"
		)
		assertEqual(
			sessionLock:RegisterController(serverRebuilt.Controller),
			false,
			"stale server removal detached replacement session-lock ownership"
		)
		serverRebuilt.Behavior.FailStopValue = nil
		assertEqual(serverModule:RemoveSaveController(serverRebuilt.Id, false), true, "string-ID removal contract regressed")
		assertServerReleased(serverRebuilt)

		local serverBulk = makeServerFixture("server_bulk_retry", 31_002)
		local serverBulkSuccess = makeServerFixture("server_bulk_success", 31_004)
		serverBulkSuccess.Behavior.FailStopValue = nil
		local bulkRemoved, bulkFailures = serverModule:RemoveAllSaveControllers(false)
		assertEqual(bulkRemoved, false)
		assertEqual(bulkFailures[serverBulk.Id].Code, "DestroyFailed")
		assertEqual(bulkFailures[serverBulkSuccess.Id], nil, "successful mixed-bulk member was reported failed")
		assertServerRetained(serverBulk)
		assertServerReleased(serverBulkSuccess)
		serverBulk.Behavior.FailStopValue = nil
		assertEqual(serverModule:RemoveAllSaveControllers(false), true)
		assertServerReleased(serverBulk)

		local serverToClient = makeInstrumentedEvent()
		local outboundBatches = {}
		local communication = CommunicationClient.new(makeLogger(), function() return 0 end, nil, {
			ClientToServer = {
				FireServer = function(_self, batch)
					table.insert(outboundBatches, batch)
				end,
			},
			ServerToClient = {
				OnClientEvent = serverToClient,
			},
			Request = {
				InvokeServer = function()
					return { Ok = false, Code = "Unused" }
				end,
			},
		})
		communication:Initialize()
		scope:Defer(function()
			communication:Stop()
			serverToClient:Destroy()
		end)
		local clientModule = ClientSaveModule.new(communication)
		clientModule:Initialize()
		clientModule:Initialize()
		local clientProviders = {}
		local incomingSequence = 0
		scope:Defer(function()
			for _, provider in clientProviders do
				provider.FailStop = false
				provider.MementoChanged:Destroy()
			end
			clientModule:RemoveAllSaveControllers()
		end)

		local function receivePatchResult(controllerId: string, requestId: string, revision: number)
			incomingSequence += 1
			communication:ReceiveBatch({
				Epoch = 0,
				Sequence = incomingSequence,
				Messages = {
					{
						Type = CommunicationProtocol.SystemMessages.SaveClientPatchResult,
						Payload = {
							ControllerId = controllerId,
							AcceptedProviders = { `Provider{controllerId}` },
							Revision = revision,
						},
						RequestId = requestId,
					},
				},
			})
		end

		local function flushPatch(controllerId: string, controller: any, provider: any): string
			provider.Value = { Value = provider.Value.Value + 1 }
			provider.MementoChanged:Fire()
			controller:FlushClientChanges()
			communication:Flush()
			for batchIndex = #outboundBatches, 1, -1 do
				local batch = outboundBatches[batchIndex]
				for messageIndex = #batch.Messages, 1, -1 do
					local message = batch.Messages[messageIndex]
					if message.Payload.ControllerId == controllerId then
						return message.RequestId
					end
				end
			end
			error(`outbound patch for '{controllerId}' was not observed`)
		end

		local function makeClientFixture(id: string): any
			local provider = {
				Id = `Provider{id}`,
				Version = 1,
				Authority = "Client",
				MementoChanged = Signal.new(),
				Value = nil,
				Active = false,
				FailStop = true,
				StopCalls = 0,
			}
			function provider:ValidateMemento(value)
				return typeof(value) == "table" and typeof(value.Value) == "number", value, "InvalidTestValue"
			end
			function provider:SetMemento(value) self.Value = { Value = value.Value } end
			function provider:GetMemento() return self.Value end
			function provider:Run() self.Active = true end
			function provider:Stop()
				self.StopCalls += 1
				if self.FailStop then error("injected permanent client Stop failure") end
				self.Active = false
			end
			table.insert(clientProviders, provider)
			local controller = clientModule:BuildSaveController(id):WithSaveProvider(provider):Build()
			local readyCount = 0
			local readyConnection = controller.Ready:Connect(function() readyCount += 1 end)
			controller:ApplySnapshot({
				ControllerId = id,
				Revision = 3,
				Providers = { [provider.Id] = { Version = 1, Data = { Value = 2 } } },
			})
			assertTrue(controller:IsReady() and provider.Active, "client cleanup fixture did not activate")
			local requestId = flushPatch(id, controller, provider)
			return {
				Id = id,
				Provider = provider,
				Controller = controller,
				ReadyConnection = readyConnection,
				ReadyCount = function() return readyCount end,
				RequestId = requestId,
			}
		end

		local function assertClientRetained(fixture: any)
			assertEqual(clientModule:GetSaveController(fixture.Id), fixture.Controller)
			assertTrue(fixture.Provider.Active and not fixture.Controller:IsReady(),
				"failed client Stop lost active ownership or preserved a false-ready runtime")
			assertTrue(fixture.ReadyConnection.Connected, "failed client cleanup destroyed Ready signal")
			assertEqual(fixture.Provider.StopCalls, 1)
		end

		local function assertClientReleased(fixture: any, expectedStopCalls: number)
			assertEqual(clientModule:GetSaveController(fixture.Id), nil)
			assertTrue(not fixture.Provider.Active and not fixture.Controller:IsReady(),
				"successful client retry left active runtime state")
			assertTrue(not fixture.ReadyConnection.Connected, "successful client retry did not destroy Ready signal")
			assertEqual(fixture.Provider.StopCalls, expectedStopCalls)
		end

		local clientFirst = makeClientFixture("client_route_a")
		local clientSecond = makeClientFixture("client_route_b")
		assertEqual(serverToClient:ActiveCount(), 1, "real CommunicationClient registered duplicate transport handlers")
		receivePatchResult(clientFirst.Id, clientSecond.RequestId, 80)
		receivePatchResult(clientSecond.Id, clientFirst.RequestId, 81)
		assertEqual(clientFirst.Controller:GetRevision(), 3, "crossed result reached first live controller")
		assertEqual(clientSecond.Controller:GetRevision(), 3, "crossed result reached second live controller")
		receivePatchResult(clientFirst.Id, clientFirst.RequestId, 4)
		receivePatchResult(clientSecond.Id, clientSecond.RequestId, 4)
		assertEqual(clientFirst.Controller:GetRevision(), 4, "correct result missed first live controller")
		assertEqual(clientSecond.Controller:GetRevision(), 4, "correct result missed second live controller")

		local removedControllerRequest = flushPatch(clientFirst.Id, clientFirst.Controller, clientFirst.Provider)
		local survivingControllerRequest = flushPatch(clientSecond.Id, clientSecond.Controller, clientSecond.Provider)
		clientFirst.Provider.FailStop = false
		assertEqual(clientModule:RemoveSaveController(clientFirst.Id), true)
		assertClientReleased(clientFirst, 1)
		receivePatchResult(clientFirst.Id, removedControllerRequest, 90)
		assertEqual(clientFirst.Controller:GetRevision(), 4, "removed controller received a late result")
		receivePatchResult(clientSecond.Id, survivingControllerRequest, 5)
		assertEqual(clientSecond.Controller:GetRevision(), 5, "surviving controller route stopped with its sibling")

		local rebuilt = makeClientFixture(clientFirst.Id)
		assertEqual(
			clientModule:RemoveSaveController(clientFirst.Controller),
			false,
			"stale client object removed a same-ID replacement"
		)
		assertEqual(clientModule:GetSaveController(rebuilt.Id), rebuilt.Controller)
		assertTrue(rebuilt.Controller:IsReady() and rebuilt.Provider.Active, "stale client removal stopped replacement provider")
		assertTrue(rebuilt.ReadyConnection.Connected, "stale client removal destroyed replacement signal")
		rebuilt.Provider.FailStop = false
		receivePatchResult(rebuilt.Id, removedControllerRequest, 91)
		assertEqual(rebuilt.Controller:GetRevision(), 3, "late stale result was delivered to same-ID rebuild")
		receivePatchResult(rebuilt.Id, rebuilt.RequestId, 4)
		assertEqual(rebuilt.Controller:GetRevision(), 4, "same-ID rebuild missed its own result")

		local rebuiltBulkRequest = flushPatch(rebuilt.Id, rebuilt.Controller, rebuilt.Provider)
		local retainedBulkRequest = flushPatch(clientSecond.Id, clientSecond.Controller, clientSecond.Provider)
		local clientBulkRemoved, clientBulkFailures = clientModule:RemoveAllSaveControllers()
		assertEqual(clientBulkRemoved, false)
		assertEqual(clientBulkFailures[clientSecond.Id].Code, "ProviderStopFailed")
		assertEqual(clientBulkFailures[rebuilt.Id], nil, "successful mixed-bulk route was reported failed")
		assertClientReleased(rebuilt, 1)
		assertClientRetained(clientSecond)
		receivePatchResult(rebuilt.Id, rebuiltBulkRequest, 92)
		assertEqual(rebuilt.Controller:GetRevision(), 4, "mixed-bulk success retained a stale route")
		receivePatchResult(clientSecond.Id, retainedBulkRequest, 6)
		assertEqual(clientSecond.Controller:GetRevision(), 6, "mixed-bulk failure lost its retry-owned route")
		clientSecond.Provider.FailStop = false
		assertEqual(clientModule:RemoveAllSaveControllers(), true)
		assertClientReleased(clientSecond, 2)
		assertEqual(serverToClient:ActiveCount(), 1, "controller churn changed transport handler lifetime")
	end)

	test("server and client SaveModule registries enforce construction and removal contracts", function(scope)
		local serverModule = ServerSaveModule.new()
		assertThrows(function()
			serverModule:BuildSaveController("before_init")
		end, "must be initialized")
		serverModule:Initialize()
		local serverProvider = makeProvider("ServerProvider", "Server")
		scope:Defer(function()
			serverProvider:Destroy()
			serverModule:RemoveAllSaveControllers(false)
		end)
		local serverController = serverModule:BuildSaveController("slot")
			:WithSaveProvider(serverProvider)
			:WithStorage(SessionLockingStorage.new(MemoryStorage.new(), { StaleLockSeconds = 1_800 }))
			:WithKeyResolver(function(player)
				return `slot_{player.UserId}`
			end)
			:Build()
		assertEqual(serverModule:GetSaveController("slot"), serverController)
		assertThrows(function()
			serverModule:BuildSaveController("slot")
		end, "already exists")
		assertEqual(serverModule:RemoveSaveController("slot", false), true)
		assertEqual(serverModule:RemoveSaveController("slot", false), false)

		local communication = {
			RegisterHandler = function() end,
			Queue = function()
				return true
			end,
		}
		local clientModule = ClientSaveModule.new(communication)
		clientModule:Initialize()
		local clientProvider = makeProvider("ClientProvider", "Server")
		scope:Defer(function()
			clientProvider:Destroy()
			clientModule:RemoveSaveController("slot")
		end)
		local clientController = clientModule:BuildSaveController("slot")
			:WithSaveProvider(clientProvider)
			:Build()
		assertEqual(clientModule:GetSaveController("slot"), clientController)
		assertEqual(clientModule:RemoveSaveController(clientController), true)
		assertEqual(clientModule:RemoveSaveController("slot"), false)
	end)

	return TestHarness.runAll("ProductionReadinessTestRunner", tests, 5)
end

return ProductionReadinessTestRunner
