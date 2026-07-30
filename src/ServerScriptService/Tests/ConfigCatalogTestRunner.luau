--!strict

--[[
	Deterministic Experience Config catalog and client projection tests.

	require(game.ServerScriptService.Tests.ConfigCatalogTestRunner).runAll()
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local ClientConfigCatalog = require(ReplicatedStorage.Client.Config.ClientConfigCatalog)
local ClientConfigManifest = require(ReplicatedStorage.Client.Config.ClientConfigManifest)
local ClientGlobalSaveConfigCodec = require(ReplicatedStorage.Client.Config.Codecs.GlobalSaveConfigCodec)
local ExperienceConfigCatalog = require(ServerScriptService.Modules.Config.ExperienceConfigCatalog)
local ServerConfigManifest = require(ServerScriptService.Modules.Config.ServerConfigManifest)
local ServerGlobalSaveConfigCodec = require(ServerScriptService.Modules.Config.Codecs.GlobalSaveConfigCodec)
local WalletConfigCodec = require(ServerScriptService.Modules.Config.Codecs.WalletConfigCodec)
local TestHarness = require(script.Parent.TestHarness)

local ConfigCatalogTestRunner = {}

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
	return {
		Info = function() end,
		Warn = function() end,
		Error = function() end,
	}
end

local function makeSnapshot(initialValues: { [string]: any })
	local snapshot = {
		Values = initialValues,
		UpdateAvailable = Signal.new(),
	}
	function snapshot:GetValue(key: string)
		return self.Values[key]
	end
	function snapshot:Refresh()
	end
	return snapshot
end

local function makeCommunication()
	local handlers = {}
	return {
		Handlers = handlers,
		RegisterRequestHandler = function(_self, requestType, validator, handler)
			handlers[requestType] = {
				Validate = validator,
				Handle = handler,
			}
		end,
	}
end

local function equipmentDefinition()
	return {
		Id = "Equipment",
		Key = "equip_config",
		Decode = function(value)
			if typeof(value) ~= "table"
				or typeof(value.schemaVersion) ~= "number"
				or typeof(value.items) ~= "table"
			then
				return false, nil, "invalid_equipment_config"
			end
			return true, {
				SchemaVersion = value.schemaVersion,
				Items = value.items,
				ServerSecret = value.serverSecret,
			}, nil
		end,
		ToClient = function(value)
			return true, {
				SchemaVersion = value.SchemaVersion,
				Items = value.Items,
			}, nil
		end,
	}
end

function ConfigCatalogTestRunner.runAll()
	local tests = {}

	local function test(name: string, callback: () -> ())
		table.insert(tests, { Name = name, Callback = callback })
	end

	test("server catalog decodes atomically and projects only explicit client fields", function()
		local snapshot = makeSnapshot({
			equip_config = {
				schemaVersion = 1,
				items = {
					Sword = {
						DisplayName = "Sword",
					},
				},
				serverSecret = "not-for-client",
			},
		})
		local communication = makeCommunication()
		local catalog = ExperienceConfigCatalog.new({
			ConfigService = {
				GetConfigAsync = function()
					return snapshot
				end,
			},
			Communication = communication,
			Definitions = { equipmentDefinition() },
			ClientBundles = {
				Bootstrap = { "Equipment" },
			},
			Logger = makeLogger(),
		})
		catalog:Initialize()

		local equipment = catalog:GetRequired("Equipment")
		assertEqual(equipment.ServerSecret, "not-for-client")
		assertTrue(table.isfrozen(equipment), "decoded server model must be frozen")
		assertTrue(table.isfrozen(equipment.Items), "nested server model must be frozen")

		local bundle = catalog:GetClientBundle("Bootstrap")
		assertEqual(bundle.Generation, 1)
		assertEqual(bundle.Configs.Equipment.ServerSecret, nil, "client projection leaked server field")
		assertEqual(bundle.Configs.Equipment.Items.Sword.DisplayName, "Sword")
		assertTrue(table.isfrozen(bundle), "client bundle must be frozen")

		local handler = communication.Handlers["Config.GetClientBundle"]
		local valid, sanitized = handler.Validate({ BundleId = "Bootstrap" })
		assertTrue(valid, "valid bundle request rejected")
		local handled, response = handler.Handle(nil, sanitized)
		assertTrue(handled, "allowed bundle request failed")
		assertEqual(response.Generation, 1)
		local unavailable, _, code = handler.Handle(nil, { BundleId = "ServerSecrets" })
		assertEqual(unavailable, false)
		assertEqual(code, "Unavailable")
		catalog:Destroy()
		snapshot.UpdateAvailable:Destroy()
	end)

	test("invalid refresh preserves the last complete server generation", function()
		local snapshot = makeSnapshot({
			equip_config = {
				schemaVersion = 1,
				items = { Sword = { DisplayName = "Sword" } },
				serverSecret = "first",
			},
		})
		local catalog = ExperienceConfigCatalog.new({
			ConfigService = {
				GetConfigAsync = function()
					return snapshot
				end,
			},
			Communication = makeCommunication(),
			Definitions = { equipmentDefinition() },
			ClientBundles = { Bootstrap = { "Equipment" } },
			Logger = makeLogger(),
		})
		catalog:Initialize()
		snapshot.Values.equip_config = {
			schemaVersion = "wrong",
			items = {},
		}
		local refresh = catalog:Refresh()
		assertEqual(refresh.Ok, false)
		assertEqual(refresh.Code, "InvalidConfig")
		assertEqual(catalog:GetGeneration(), 1)
		assertEqual(catalog:GetRequired("Equipment").ServerSecret, "first")
		catalog:Destroy()
		snapshot.UpdateAvailable:Destroy()
	end)

	test("missing required config stops startup without publishing a partial catalog", function()
		local snapshot = makeSnapshot({})
		local catalog = ExperienceConfigCatalog.new({
			ConfigService = {
				GetConfigAsync = function()
					return snapshot
				end,
			},
			Communication = makeCommunication(),
			Definitions = { equipmentDefinition() },
			ClientBundles = { Bootstrap = { "Equipment" } },
			Logger = makeLogger(),
		})
		local initialized = pcall(function()
			catalog:Initialize()
		end)
		assertEqual(initialized, false)
		assertEqual(catalog:IsInitialized(), false)
		assertEqual(catalog:GetGeneration(), 0)
		catalog:Destroy()
		snapshot.UpdateAvailable:Destroy()
	end)

	test("production manifests decode Wallet and expose only GlobalSave client settings", function()
		local snapshot = makeSnapshot({
			wallet_config = {
				startingBalances = {
					Coins = 100,
					Gems = 5,
				},
			},
			global_save_config = {
				autoSaveIntervalSeconds = 60,
				snapshotLoadTimeoutSeconds = 15,
				snapshotRequestAttempts = 20,
				snapshotRetryDelaySeconds = 0.5,
			},
		})
		local catalog = ExperienceConfigCatalog.new({
			ConfigService = {
				GetConfigAsync = function()
					return snapshot
				end,
			},
			Communication = makeCommunication(),
			Definitions = ServerConfigManifest.Definitions,
			ClientBundles = ServerConfigManifest.ClientBundles,
			Logger = makeLogger(),
		})
		catalog:Initialize()
		assertEqual(catalog:GetRequired("Wallet").StartingBalances.Coins, 100)
		assertEqual(catalog:GetRequired("GlobalSave").AutoSaveIntervalSeconds, 60)

		local bundle = catalog:GetRequired("GlobalSave")
		assertEqual(bundle.SnapshotRequestAttempts, 20)
		local clientBundle = catalog:GetClientBundle("Bootstrap")
		assertEqual(clientBundle.Configs.Wallet, nil, "Wallet startup config must remain server-only")
		assertEqual(clientBundle.Configs.GlobalSave.AutoSaveIntervalSeconds, nil)

		local client = ClientConfigCatalog.new({
			Communication = {
				Request = function()
					return true, clientBundle, nil
				end,
			},
			BundleId = ClientConfigManifest.BundleId,
			Definitions = ClientConfigManifest.Definitions,
			Logger = makeLogger(),
		})
		client:Initialize()
		assertEqual(client:GetRequired("GlobalSave").SnapshotRequestAttempts, 20)
		assertEqual(client:GetRequired("GlobalSave").SnapshotRetryDelaySeconds, 0.5)
		client:Destroy()
		catalog:Destroy()
		snapshot.UpdateAvailable:Destroy()
	end)

	test("production Wallet config rejects unknown currencies", function()
		local snapshot = makeSnapshot({
			wallet_config = {
				startingBalances = {
					Coins = 100,
					Gems = 5,
					Gold = 1,
				},
			},
			global_save_config = {
				autoSaveIntervalSeconds = 60,
				snapshotLoadTimeoutSeconds = 15,
				snapshotRequestAttempts = 20,
				snapshotRetryDelaySeconds = 0.5,
			},
		})
		local catalog = ExperienceConfigCatalog.new({
			ConfigService = {
				GetConfigAsync = function()
					return snapshot
				end,
			},
			Communication = makeCommunication(),
			Definitions = ServerConfigManifest.Definitions,
			ClientBundles = ServerConfigManifest.ClientBundles,
			Logger = makeLogger(),
		})
		assertEqual(pcall(function()
			catalog:Initialize()
		end), false)
		assertEqual(catalog:IsInitialized(), false)
		catalog:Destroy()
		snapshot.UpdateAvailable:Destroy()
	end)

	test("production Wallet config rejects unsafe integer balances", function()
		local valid, _, decodeError = WalletConfigCodec.decode({
			startingBalances = {
				Coins = 9_007_199_254_740_992,
				Gems = 0,
			},
		})
		assertEqual(valid, false)
		assertTrue(
			string.find(decodeError or "", "safe non-negative integer", 1, true) ~= nil,
			"unsafe Wallet balance returned an unrelated validation error"
		)
	end)

	test("GlobalSave codecs enforce every numeric boundary and reject unknown fields", function()
		local validMinimum = {
			autoSaveIntervalSeconds = 5,
			snapshotLoadTimeoutSeconds = 1,
			snapshotRequestAttempts = 1,
			snapshotRetryDelaySeconds = 0.05,
		}
		local validMaximum = {
			autoSaveIntervalSeconds = 3_600,
			snapshotLoadTimeoutSeconds = 120,
			snapshotRequestAttempts = 100,
			snapshotRetryDelaySeconds = 10,
		}
		assertTrue(ServerGlobalSaveConfigCodec.decode(validMinimum), "minimum server boundaries were rejected")
		assertTrue(ServerGlobalSaveConfigCodec.decode(validMaximum), "maximum server boundaries were rejected")

		local invalidValues = {
			"not-a-table",
			{},
			{
				autoSaveIntervalSeconds = 4.99,
				snapshotLoadTimeoutSeconds = 1,
				snapshotRequestAttempts = 1,
				snapshotRetryDelaySeconds = 0.05,
			},
			{
				autoSaveIntervalSeconds = 5,
				snapshotLoadTimeoutSeconds = math.huge,
				snapshotRequestAttempts = 1,
				snapshotRetryDelaySeconds = 0.05,
			},
			{
				autoSaveIntervalSeconds = 5,
				snapshotLoadTimeoutSeconds = 1,
				snapshotRequestAttempts = 1.5,
				snapshotRetryDelaySeconds = 0.05,
			},
			{
				autoSaveIntervalSeconds = 5,
				snapshotLoadTimeoutSeconds = 1,
				snapshotRequestAttempts = 1,
				snapshotRetryDelaySeconds = 0 / 0,
			},
			{
				autoSaveIntervalSeconds = 5,
				snapshotLoadTimeoutSeconds = 1,
				snapshotRequestAttempts = 1,
				snapshotRetryDelaySeconds = 0.05,
				unknown = true,
			},
		}
		for _, value in invalidValues do
			assertEqual(ServerGlobalSaveConfigCodec.decode(value), false)
		end

		assertTrue(ClientGlobalSaveConfigCodec.decode({
			SnapshotRequestAttempts = 1,
			SnapshotRetryDelaySeconds = 0.05,
		}), "minimum client boundaries were rejected")
		assertTrue(ClientGlobalSaveConfigCodec.decode({
			SnapshotRequestAttempts = 100,
			SnapshotRetryDelaySeconds = 10,
		}), "maximum client boundaries were rejected")
		assertEqual(ClientGlobalSaveConfigCodec.decode({
			SnapshotRequestAttempts = 0,
			SnapshotRetryDelaySeconds = 0.05,
		}), false)
		assertEqual(ClientGlobalSaveConfigCodec.decode({
			SnapshotRequestAttempts = 1,
			SnapshotRetryDelaySeconds = 0.05,
			ServerOnly = true,
		}), false)
	end)

	test("oversized client projection fails before publishing a config generation", function()
		local snapshot = makeSnapshot({
			equip_config = {
				schemaVersion = 1,
				items = {
					Huge = {
						DisplayName = string.rep("x", 60 * 1_024),
					},
				},
				serverSecret = "safe",
			},
		})
		local catalog = ExperienceConfigCatalog.new({
			ConfigService = {
				GetConfigAsync = function()
					return snapshot
				end,
			},
			Communication = makeCommunication(),
			Definitions = { equipmentDefinition() },
			ClientBundles = { Bootstrap = { "Equipment" } },
			Logger = makeLogger(),
		})
		assertEqual(pcall(function()
			catalog:Initialize()
		end), false)
		assertEqual(catalog:IsInitialized(), false)
		assertEqual(catalog:GetGeneration(), 0)
		catalog:Destroy()
		snapshot.UpdateAvailable:Destroy()
	end)

	test("client catalog decodes an allowed bundle and retains old data after invalid refresh", function()
		local response = {
			BundleId = "Bootstrap",
			Generation = 3,
			Configs = {
				Equipment = {
					SchemaVersion = 1,
					Items = { Sword = { DisplayName = "Sword" } },
				},
			},
		}
		local client = ClientConfigCatalog.new({
			Communication = {
				Request = function()
					return true, response, nil
				end,
			},
			BundleId = "Bootstrap",
			Definitions = {
				{
					Id = "Equipment",
					Decode = function(value)
						if typeof(value) ~= "table" or typeof(value.Items) ~= "table" then
							return false, nil, "invalid"
						end
						return true, {
							Items = value.Items,
						}, nil
					end,
				},
			},
			Logger = makeLogger(),
		})
		client:Initialize()
		assertEqual(client:GetGeneration(), 3)
		assertEqual(client:GetRequired("Equipment").Items.Sword.DisplayName, "Sword")
		assertTrue(table.isfrozen(client:GetRequired("Equipment").Items), "client data must be frozen")

		response = {
			BundleId = "Bootstrap",
			Generation = 4,
			Configs = {
				Equipment = "broken",
			},
		}
		local refresh = client:Refresh()
		assertEqual(refresh.Ok, false)
		assertEqual(client:GetGeneration(), 3)
		assertEqual(client:GetRequired("Equipment").Items.Sword.DisplayName, "Sword")
		client:Destroy()
	end)

	test("client bundle manifest cannot expose a config without an explicit projection", function()
		local definition = equipmentDefinition()
		definition.ToClient = nil
		local constructed = pcall(function()
			ExperienceConfigCatalog.new({
				ConfigService = {},
				Communication = makeCommunication(),
				Definitions = { definition },
				ClientBundles = { Bootstrap = { "Equipment" } },
				Logger = makeLogger(),
			})
		end)
		assertEqual(constructed, false)
	end)

	return TestHarness.runAll("ConfigCatalogTestRunner", tests)
end

return ConfigCatalogTestRunner
