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
