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
