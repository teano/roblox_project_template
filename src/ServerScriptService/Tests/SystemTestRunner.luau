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
local WalletModule = require(ServerScriptService.Modules.Wallet.WalletModule)
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
