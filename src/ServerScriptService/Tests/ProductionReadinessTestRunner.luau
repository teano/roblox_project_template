--!strict

--[[
	Deterministic contract coverage for production lifecycle boundaries that do
	not belong to one of the older focused runners.

	require(game.ServerScriptService.Tests.ProductionReadinessTestRunner).runAll()
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local ClientGameData = require(ReplicatedStorage.Client.GameData.GameDataClient)
local ClientPlayersModule = require(ReplicatedStorage.Client.Players.PlayersModule)
local ClientSaveModule = require(ReplicatedStorage.Client.Save.SaveModule)
local VersionClient = require(ReplicatedStorage.Client.Version.VersionClient)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local VersionConfig = require(ReplicatedStorage.Shared.Version.VersionConfig)
local AutoSaveModule = require(ServerScriptService.Modules.AutoSave.AutoSaveModule)
local MigrationModule = require(ServerScriptService.Modules.Migration.MigrationModule)
local ServerPlayersModule = require(ServerScriptService.Modules.Players.PlayersModule)
local ServerSaveController = require(ServerScriptService.Modules.Save.ServerSaveController)
local ServerSaveModule = require(ServerScriptService.Modules.Save.SaveModule)
local MemoryStorage = require(ServerScriptService.Modules.Storage.MemoryStorage)
local SessionLockingStorage = require(ServerScriptService.Modules.Storage.SessionLockingStorage)
local SessionLockModule = require(ServerScriptService.Modules.Storage.SessionLockModule)
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
			if behavior and behavior.FailRunValue == values[player].Value then
				error("injected Run failure")
			end
		end,
		Stop = function(_self, player)
			if behavior and behavior.FailStopValue == (values[player] and values[player].Value) then
				error("injected Stop failure")
			end
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

local function makeController(id: string, providers: { any })
	return ServerSaveController.new({
		Id = id,
		Providers = providers,
		Storage = SessionLockingStorage.new(MemoryStorage.new(), {
			StaleLockSeconds = 1_800,
		}),
		KeyResolver = function(player)
			return `{id}_{player.UserId}`
		end,
		Logger = makeLogger(),
	})
end

local function makePlayersService()
	local players = {}
	local service = {
		PlayerAdded = Signal.new(),
		PlayerRemoving = Signal.new(),
	}
	function service:GetPlayers()
		return table.clone(players)
	end
	function service:GetPlayerByUserId(userId)
		for _, player in players do
			if player.UserId == userId then
				return player
			end
		end
		return nil
	end
	function service:GetPlayerFromCharacter(character)
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
	function service:Destroy()
		self.PlayerAdded:Destroy()
		self.PlayerRemoving:Destroy()
	end
	return service
end

local function makePlayer(userId: number, character: any?)
	return {
		UserId = userId,
		Character = character,
		CharacterAdded = Signal.new(),
		CharacterRemoving = Signal.new(),
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
		local refreshed = {}
		module:RegisterController({
			IsLoaded = function(_self, player)
				return player ~= notLoaded
			end,
			GetLastLockRefreshAt = function(_self, player)
				return if player == due then 80 else 81
			end,
			RefreshLock = function(_self, player)
				table.insert(refreshed, player)
				return { Ok = false, Code = "Injected", Error = "expected" }
			end,
		})
		module:Initialize({
			GetPlayers = function()
				return { due, notDue, notLoaded }
			end,
		})
		module:Initialize({})
		local worker = assert(spawned)
		worker()

		assertEqual(#refreshed, 1)
		assertEqual(refreshed[1], due)
		assertEqual(entries[1].Event, "lock_refresh_failed")
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

	test("migration chains select versions and run same-version controllers by order", function()
		local migration = MigrationModule.new()
		local order = {}
		local function controller(targetVersion, controllerOrder, name)
			return {
				TargetVersion = targetVersion,
				Order = controllerOrder,
				Migrate = function(_self, document)
					table.insert(order, name)
					document[name] = true
					return document
				end,
			}
		end
		migration:Register(controller("1.0.0", 20, "Last"))
		migration:Register(controller("0.5.0", 0, "First"))
		migration:Register(controller("1.0.0", 10, "Middle"))
		migration:Register(controller("2.0.0", 0, "Future"))

		local source = {
			Providers = {
				Version = {
					Data = {
						PreviousVersion = "0.0.0",
					},
				},
			},
		}
		local result = migration:Migrate(source)
		assertEqual(table.concat(order, ","), "First,Middle,Last")
		assertEqual(result.Future, nil)
		assertEqual(source.First, nil, "migration mutated its source document")
		assertThrows(function()
			migration:Register({})
		end, "Migration TargetVersion required")
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
		local added = {}
		local removed = {}
		module.CharacterAdded:Connect(function(character)
			table.insert(added, character)
		end)
		module.CharacterRemoving:Connect(function(character)
			table.insert(removed, character)
		end)
		module:Initialize()
		module:Initialize()
		waitUntil(function()
			return #added == 1
		end)
		player.CharacterRemoving:Fire(existingCharacter)
		player.Character = nextCharacter
		player.CharacterAdded:Fire(nextCharacter)
		waitUntil(function()
			return #added == 2 and #removed == 1
		end)
		assertEqual(module:GetLocalPlayer(), player)
		assertEqual(module:GetCharacter(), nextCharacter)
		assertEqual(module:WaitForCharacter(), nextCharacter)
		module:Stop()
		module:Stop()
		player.CharacterAdded:Fire({} :: any)
		task.wait()
		assertEqual(#added, 2, "stopped client player wrapper leaked a connection")
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
		module:Initialize()
		module:Initialize()
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
		service:Add(player)
		task.wait()
		assertEqual(added, 1, "stopped server player wrapper leaked a connection")
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
