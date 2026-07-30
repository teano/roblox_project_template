--!strict

--[[
	Manual Studio harness for initialization, assets, layered saves, locks and domain data.

	require(game.ServerScriptService.Tests.SystemTestRunner).runAll()
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local InitializationRunner = require(ReplicatedStorage.Shared.Initialization.InitializationRunner)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local MemoryStorage = require(ServerScriptService.Modules.Storage.MemoryStorage)
local SessionLockingStorage = require(ServerScriptService.Modules.Storage.SessionLockingStorage)
local ServerSaveController = require(ServerScriptService.Modules.Save.ServerSaveController)
local MigrationModule = require(ServerScriptService.Modules.Migration.MigrationModule)
local PlayersModule = require(ServerScriptService.Modules.Players.PlayersModule)
local WalletModule = require(ServerScriptService.Modules.Wallet.WalletModule)
local WalletConfig = require(ReplicatedStorage.Shared.Wallet.WalletConfig)
local ServerManifest = require(ServerScriptService.Initialization.ServerManifest)

local SystemTestRunner = {}

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

local function getManifestCommand(commandId: string)
	for _, command in ServerManifest.Commands do
		if command.Id == commandId then
			return command
		end
	end
	error(`server manifest command not found: {commandId}`, 2)
end

local function initializeManifestCommand(commandId: string)
	getManifestCommand(commandId):Initialize({})
end

local function makeCommand(id: string, dependencies: { string }, callback: (any) -> ())
	return {
		Id = id,
		DependsOn = dependencies,
		Initialize = function(_self, context)
			callback(context)
		end,
	}
end

local function makeProvider(lifecycle: { string })
	local values = {}
	return {
		Id = "Test",
		Version = 1,
		Authority = "Server",
		MementoChanged = Signal.new(),
		CreateDefault = function(_self, _player)
			table.insert(lifecycle, "CreateDefault")
			return { Value = 1 }
		end,
		ValidateMemento = function(_self, _player, value)
			return typeof(value) == "table" and typeof(value.Value) == "number", value, nil
		end,
		SetMemento = function(_self, player, value)
			table.insert(lifecycle, `Set:{value.Value}`)
			values[player] = { Value = value.Value }
		end,
		GetMemento = function(_self, player)
			table.insert(lifecycle, "Get")
			return { Value = values[player].Value }
		end,
		Run = function(_self, _player)
			table.insert(lifecycle, "Run")
		end,
		Stop = function(_self, player)
			table.insert(lifecycle, "Stop")
			values[player] = nil
		end,
		SetValue = function(self, player, value)
			values[player].Value = value
			self.MementoChanged:Fire(player)
		end,
	}
end

function SystemTestRunner.runAll()
	local tests = {}

	local function test(name: string, callback: () -> ())
		table.insert(tests, { Name = name, Callback = callback })
	end

	test("signal disconnect and destroy keep connection state accurate", function()
		local signal = Signal.new()
		local calls = 0
		local disconnected = signal:Connect(function()
			calls += 1
		end)

		assertTrue(disconnected.Connected, "new signal connection must be connected")
		local writeOk = pcall(function()
			(disconnected :: any).Connected = false
		end)
		assertTrue(not writeOk, "connection state must be read-only")
		disconnected:Disconnect()
		disconnected:Disconnect()
		assertTrue(not disconnected.Connected, "disconnected signal connection must report false")

		local destroyed = signal:Connect(function()
			calls += 1
		end)
		signal:Destroy()
		signal:Destroy()
		assertTrue(not destroyed.Connected, "destroyed signal connection must report false")

		signal:Fire()
		task.wait()
		assertEqual(calls, 0, "disconnected or destroyed listeners must not run")
	end)

	test("signal once disconnects before listener execution", function()
		local signal = Signal.new()
		local calls = 0
		local connection = signal:Once(function()
			calls += 1
			signal:Fire()
		end)

		signal:Fire()
		signal:Fire()
		task.wait()

		assertEqual(calls, 1, "once listener must run exactly once")
		assertTrue(not connection.Connected, "once connection must report false after dispatch")
		signal:Destroy()
	end)

	test("signal yielding listener does not block dispatch", function()
		local signal = Signal.new()
		local releaseFirst = false
		local firstStarted = false
		local firstCompleted = false
		local secondCompleted = false
		local fireReturned = false

		signal:Connect(function()
			firstStarted = true
			while not releaseFirst do
				task.wait()
			end
			firstCompleted = true
		end)
		signal:Connect(function()
			secondCompleted = true
		end)

		task.spawn(function()
			signal:Fire()
			fireReturned = true
		end)
		task.wait()

		assertTrue(firstStarted, "first listener must start")
		assertTrue(secondCompleted, "yielding listener must not block later listeners")
		assertTrue(fireReturned, "yielding listener must not block Fire")
		assertTrue(not firstCompleted, "first listener must remain suspended until released")

		releaseFirst = true
		task.wait()
		assertTrue(firstCompleted, "released listener must complete")
		signal:Destroy()
	end)

	test("signal destroy during dispatch prevents remaining listeners", function()
		local signal = Signal.new()
		local laterCalls = 0

		signal:Connect(function()
			signal:Destroy()
		end)
		local laterConnection = signal:Connect(function()
			laterCalls += 1
		end)

		signal:Fire()
		task.wait()

		assertEqual(laterCalls, 0, "destroy must stop listeners not yet dispatched")
		assertTrue(not laterConnection.Connected, "destroy must disconnect remaining listeners")
	end)

	test("player observation emits each player once across subscribe-enumerate races", function()
		local playersModule = PlayersModule.new()
		local player = { UserId = 4_201 } :: any
		local added = 0
		local removed = 0
		local currentPlayer = player

		playersModule.GetPlayers = function(self)
			self.PlayerAdded:Fire(player)
			return { player }
		end
		playersModule.GetPlayerByUserId = function(_self, userId)
			return if currentPlayer ~= nil and currentPlayer.UserId == userId then currentPlayer else nil
		end

		local disconnect = playersModule:ObservePlayers(function(observedPlayer)
			assertEqual(observedPlayer, player)
			added += 1
		end, function(observedPlayer)
			assertEqual(observedPlayer, player)
			removed += 1
		end)
		task.wait()
		assertEqual(added, 1, "subscribe-enumerate race emitted a duplicate player")

		currentPlayer = nil
		playersModule.PlayerRemoving:Fire(player)
		playersModule.PlayerRemoving:Fire(player)
		task.wait()
		assertEqual(removed, 1, "player removal must be emitted once per observation")

		disconnect()
		disconnect()
		playersModule.PlayerAdded:Fire(player)
		task.wait()
		assertEqual(added, 1, "disconnected observer received another player")

		currentPlayer = player
		local addedWithoutRemovalCallback = 0
		local disconnectWithoutRemovalCallback = playersModule:ObservePlayers(function()
			addedWithoutRemovalCallback += 1
		end)
		task.wait()
		assertEqual(addedWithoutRemovalCallback, 1)
		currentPlayer = nil
		playersModule.PlayerRemoving:Fire(player)
		task.wait()
		currentPlayer = player
		playersModule.PlayerAdded:Fire(player)
		task.wait()
		assertEqual(
			addedWithoutRemovalCallback,
			2,
			"observation state must be cleared on removal even without an onRemoving callback"
		)
		disconnectWithoutRemovalCallback()

		local departedPlayersModule = PlayersModule.new()
		local departedPlayer = { UserId = 4_202 } :: any
		local departedCurrent = departedPlayer
		departedPlayersModule.GetPlayerByUserId = function(_self, userId)
			return if departedCurrent ~= nil and departedCurrent.UserId == userId then departedCurrent else nil
		end
		departedPlayersModule.GetPlayers = function(self)
			departedCurrent = nil
			self.PlayerRemoving:Fire(departedPlayer)
			return { departedPlayer }
		end
		local departedAdds = 0
		local disconnectDeparted = departedPlayersModule:ObservePlayers(function()
			departedAdds += 1
		end)
		task.wait()
		assertEqual(departedAdds, 0, "enumeration must not deliver a player who already left")
		disconnectDeparted()
	end)

	test("initialization follows manifest and is idempotent", function()
		local order = {}
		local commands = {
			makeCommand("A", {}, function()
				table.insert(order, "A")
			end),
			makeCommand("B", { "A" }, function()
				table.insert(order, "B")
			end),
		}
		local runner = InitializationRunner.new(commands)
		assertTrue(runner:Initialize({}).Ok, "first initialization failed")
		assertTrue(runner:Initialize({}).Ok, "repeat initialization failed")
		assertEqual(table.concat(order, ","), "A,B")
		assertTrue(runner:IsInitialized(), "runner must remain initialized")
	end)

	test("initialization validates explicit dependencies", function()
		local ok = pcall(function()
			InitializationRunner.new({
				makeCommand("B", { "Missing" }, function() end),
			})
		end)
		assertEqual(ok, false, "missing dependency must fail construction")
	end)

	test("initialization failure is sticky", function()
		local attempts = 0
		local runner = InitializationRunner.new({
			makeCommand("Broken", {}, function()
				attempts += 1
				error("expected")
			end),
		})
		local first = runner:Initialize({})
		local second = runner:Initialize({})
		assertEqual(first.Ok, false)
		assertEqual(second.Ok, false)
		assertEqual(attempts, 1)
	end)

	test("server manifest asset command initializes the side-owned catalog", function()
		local assets = ServerManifest.Services.Assets
		assertTrue(assets ~= nil, "server manifest must expose Services.Assets")
		initializeManifestCommand("Assets")
		assertTrue(assets:IsInitialized(), "server asset command must initialize its catalog")
		assertEqual(assets:Get("Shared"), ReplicatedStorage.Assets.Shared)
		assertEqual(assets:Get("Server"), ServerStorage.Assets)
		assertEqual(assets:Get("Client"), nil, "server catalog must not expose the client namespace")
	end)

	test("server manifest exposes the Experience Config catalog after Communication", function()
		local config = ServerManifest.Services.Config
		assertTrue(config ~= nil, "server manifest must expose Services.Config")
		local command = getManifestCommand("Config")
		assertEqual(command.DependsOn[1], "Communication")
	end)

	test("session lock blocks a second live owner", function()
		local memory = MemoryStorage.new()
		local config = { StaleLockSeconds = 1_800 }
		local first = SessionLockingStorage.new(memory, config)
		local second = SessionLockingStorage.new(memory, config)
		assertTrue(first:Load("User_1").Ok, "first owner did not acquire lock")
		assertEqual(second:Load("User_1").Code, "SessionLocked")
		assertTrue(first:Release("User_1").Ok, "release failed")
		assertTrue(second:Load("User_1").Ok, "second owner did not acquire released lock")
		assertTrue(second:Release("User_1").Ok, "second release failed")
	end)

	test("save lifecycle is stop, set all, then run all", function()
		local lifecycle = {}
		local provider = makeProvider(lifecycle)
		local memory = MemoryStorage.new()
		local storage = SessionLockingStorage.new(memory, { StaleLockSeconds = 1_800 })
		local controller = ServerSaveController.new({
			Id = "test",
			Providers = { provider },
			Storage = storage,
			KeyResolver = function(player)
				return `User_{player.UserId}`
			end,
		})
		local player = { UserId = 5 } :: any

		assertTrue(controller:Load(player).Ok, "load failed")
		provider:SetValue(player, 7)
		assertTrue(controller:ForceSave(player, "Test").Ok, "force save failed")
		assertEqual(memory:Read("User_5").Providers.Test.Data.Value, 7)

		table.clear(lifecycle)
		controller:ApplyMemento(player, {
			Revision = 12,
			Providers = {
				Test = { Version = 1, Data = { Value = 20 } },
			},
			Metadata = {},
		})
		assertEqual(table.concat(lifecycle, ","), "Get,Stop,Set:20,Run")
		assertTrue(controller:Close(player, true).Ok, "close failed")
		controller:Destroy(false)
	end)

	test("wallet initializes new players once and preserves legacy balances", function()
		local messages = {}
		local wallet = WalletModule.new({
			Queue = function(_self, _player, messageType, payload)
				table.insert(messages, { Type = messageType, Payload = payload })
			end,
		}, {
			GetRequired = function(_self, configId)
				assertEqual(configId, "Wallet")
				return {
					StartingBalances = {
						Coins = 25,
						Gems = 3,
					},
				}
			end,
		})
		wallet:Initialize()
		local player = { UserId = 7 } :: any
		local dirty = 0
		wallet.MementoChanged:Connect(function()
			dirty += 1
		end)
		wallet:SetMemento(player, wallet:CreateDefault(player))
		wallet:Run(player)
		assertEqual(wallet:GetBalance(player, "Coins"), 25)
		assertEqual(wallet:GetBalance(player, "Gems"), 3)
		assertEqual(wallet:GetMemento(player).IsInitialized, true)
		assertEqual(wallet:ToClientMemento(player, wallet:GetMemento(player)).IsInitialized, nil)
		wallet:Run(player)
		assertEqual(wallet:GetBalance(player, "Coins"), 25, "startup balance must only apply once")
		assertTrue(wallet:Add(player, "Coins", 100, "Test").Ok, "add failed")
		assertEqual(wallet:GetBalance(player, "Coins"), 125)
		assertEqual(dirty, 2)
		assertEqual(#messages, 1)
		assertEqual(wallet:TrySpend(player, "Coins", 126, "Test").Code, "InsufficientFunds")
		assertTrue(
			wallet:Add(player, "Coins", WalletConfig.MaxBalance - 125, "Boundary").Ok,
			"safe maximum balance must be accepted"
		)
		assertEqual(wallet:GetBalance(player, "Coins"), WalletConfig.MaxBalance)
		assertEqual(wallet:Add(player, "Coins", 1, "Overflow").Code, "BalanceLimitExceeded")
		assertEqual(wallet:GetBalance(player, "Coins"), WalletConfig.MaxBalance)

		local validOversized = wallet:ValidateMemento(player, {
			IsInitialized = true,
			Coins = WalletConfig.MaxBalance + 1,
			Gems = 0,
		})
		assertEqual(validOversized, false, "unsafe persisted balances must be rejected")

		local legacy = wallet:ReconcileMemento(player, {
			Coins = 9,
			Gems = 4,
		}, 1)
		assertEqual(legacy.IsInitialized, true, "legacy wallet must not receive startup balance")
		assertEqual(legacy.Coins, 9)
		wallet:Stop(player)
	end)

	test("empty migration registry preserves current document", function()
		local migrations = MigrationModule.new()
		local document = {
			Providers = {},
			Revision = 9,
		}
		local migrated = migrations:Migrate(document)
		assertEqual(migrated.Revision, 9)
		assertTrue(migrated ~= document, "migration result must be an isolated copy")
	end)

	local passed = 0
	local failures = {}
	for _, entry in tests do
		local ok, testError = xpcall(entry.Callback, debug.traceback)
		if ok then
			passed += 1
		else
			table.insert(failures, `{entry.Name}: {tostring(testError)}`)
			warn(`[SystemTestRunner] FAIL {entry.Name}: {tostring(testError)}`)
		end
	end

	print(`[SystemTestRunner] passed={passed} failed={#failures} total={#tests}`)
	return {
		passed = passed,
		failed = #failures,
		failures = failures,
	}
end

return SystemTestRunner
