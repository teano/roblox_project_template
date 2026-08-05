--!strict

--[[
	Deterministic Statistics domain, persistence, adapter, and projection tests.

	require(game.ServerScriptService.Tests.StatisticsTestRunner).runAll()
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local TableUtil = require(ReplicatedStorage.Shared.Util.TableUtil)
local SaveSerialize = require(ReplicatedStorage.Shared.Save.SaveSerialize)
local CommunicationConfig = require(ReplicatedStorage.Shared.Communication.CommunicationConfig)
local StatisticsProtocol = require(ReplicatedStorage.Shared.Statistics.StatisticsProtocol)
local StatisticsClient = require(ReplicatedStorage.Client.Statistics.StatisticsClient)
local StatisticsConfigCodec = require(ServerScriptService.Modules.Config.Codecs.StatisticsConfigCodec)
local CommunicationServer = require(ServerScriptService.Modules.Communication.CommunicationServer)
local StatisticsModule = require(ServerScriptService.Modules.Statistics.StatisticsModule)
local StatisticsRequestController = require(ServerScriptService.Modules.Statistics.StatisticsRequestController)
local StatisticsClientFactController = require(ServerScriptService.Modules.Statistics.StatisticsClientFactController)
local WalletStatisticsController = require(ServerScriptService.Modules.Statistics.WalletStatisticsController)
local WalletModule = require(ServerScriptService.Modules.Wallet.WalletModule)
local AutoSaveModule = require(ServerScriptService.Modules.AutoSave.AutoSaveModule)
local ServerSaveController = require(ServerScriptService.Modules.Save.ServerSaveController)
local MemoryStorage = require(ServerScriptService.Modules.Storage.MemoryStorage)
local SessionLockingStorage = require(ServerScriptService.Modules.Storage.SessionLockingStorage)
local TestHarness = require(script.Parent.TestHarness)

local StatisticsTestRunner = {}

local SESSION_A = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
local SESSION_B = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

local function assertEqual(actual: any, expected: any, message: string?)
	if actual ~= expected then
		error(`{message or "assertEqual"}: expected={tostring(expected)} actual={tostring(actual)}`, 2)
	end
end

local function assertTrue(value: any, message: string)
	if not value then error(message, 2) end
end

local function makeLogger()
	local entries = {}
	local function record(level, event, fields)
		table.insert(entries, { Level = level, Event = event, Fields = fields })
	end
	return {
		Info = function(_self, event, fields) record("info", event, fields) end,
		Warn = function(_self, event, fields) record("warn", event, fields) end,
		Error = function(_self, event, fields) record("error", event, fields) end,
	}, entries
end

local function makeConfig()
	return {
		SnapshotTypes = {
			Global = { Retention = 0, Filter = { Mode = "AllowAllExcept", StatisticIds = {} } },
			Session = { Retention = 4, Filter = { Mode = "AllowAllExcept", StatisticIds = {} } },
			Place = { Retention = 8, Filter = { Mode = "AllowAllExcept", StatisticIds = {} } },
			Round = { Retention = 2, Filter = { Mode = "AllowOnly", StatisticIds = { "Round.Score" } } },
		},
		PublicProjection = {
			Global = { StatisticIds = { "Public", "Wallet.Coins.Earned" }, MetadataKeys = {} },
			Session = { StatisticIds = { "Public", "Wallet.Coins.Earned" }, MetadataKeys = {} },
			Place = { StatisticIds = { "Public", "Wallet.Coins.Earned" }, MetadataKeys = {} },
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
end

local function rawConfig()
	return {
		snapshotTypes = {
			Global = { retention = 0, filter = { mode = "AllowAllExcept", statisticIds = {} } },
			Session = { retention = 4, filter = { mode = "AllowAllExcept", statisticIds = {} } },
			Place = { retention = 8, filter = { mode = "AllowAllExcept", statisticIds = {} } },
		},
		publicProjection = {
			Global = { statisticIds = {}, metadataKeys = {} },
			Session = { statisticIds = {}, metadataKeys = {} },
			Place = { statisticIds = {}, metadataKeys = {} },
		},
		limits = {
			maxSnapshotTypes = 16,
			maxRetentionPerType = 32,
			maxStatisticIdsPerSnapshot = 256,
			maxStatisticIdLength = 64,
			maxSnapshotTypeLength = 48,
			maxSnapshotEncodedBytes = 24_576,
			maxMetadataDepth = 6,
			maxMetadataNodes = 128,
			maxMetadataEncodedBytes = 4_096,
			maxMetadataKeyLength = 64,
			maxMetadataStringLength = 256,
			maxDedupSources = 16,
			maxEventIdsPerSource = 64,
			maxProviderEncodedBytes = 524_288,
			maxClientResponseEstimatedBytes = 49_152,
			maxHistoryReadCount = 32,
		},
		saveRequestCooldownSeconds = 30,
	}
end

local function makeStatistics(options: any?)
	local now = if options and options.Now then options.Now else 100
	local session = if options and options.Session then options.Session else {
		SessionId = SESSION_A,
		EntryKind = "External",
		SourcePlaceId = nil,
	}
	local config = if options and options.Config then options.Config else makeConfig()
	local logger, entries = makeLogger()
	local module = StatisticsModule.new({
		Config = { GetRequired = function(_self, id) assertEqual(id, "Statistics"); return config end },
		Teleport = { GetSession = function() return TableUtil.deepCopy(session) end },
		AutoSave = if options and options.AutoSave then options.AutoSave else {},
		PlaceId = if options and options.PlaceId then options.PlaceId else 101,
		Clock = function() return now end,
		MeasureEncodedSize = if options then options.MeasureEncodedSize else nil,
		Logger = logger,
	})
	module:Initialize()
	return module, session, function(value) now = value end, entries
end

local function loadStatistics(module: any, player: any)
	module:SetMemento(player, module:CreateDefault(player))
	module:Run(player)
end

function StatisticsTestRunner.runAll()
	local tests = {}
	local function test(name: string, callback: (any) -> ())
		table.insert(tests, { Name = name, Callback = callback })
	end

	test("first load owns exactly one Global Session and Place snapshot", function(scope)
		local statistics = makeStatistics()
		scope:Defer(function() statistics:Destroy() end)
		local player = { UserId = 1 } :: any
		loadStatistics(statistics, player)
		local global = statistics:GetActiveSnapshot(player, "Global")
		local session = statistics:GetActiveSnapshot(player, "Session")
		local place = statistics:GetActiveSnapshot(player, "Place")
		assertEqual(global.SnapshotId, 1)
		assertEqual(session.SessionId, SESSION_A)
		assertEqual(place.PlaceId, 101)
		for _, snapshot in { global, session, place } do
			assertTrue(typeof(snapshot.StartedAt) == "number", "snapshot omitted StartedAt")
			assertEqual(snapshot.State, "Active")
			assertTrue(typeof(snapshot.Metadata) == "table", "snapshot omitted Metadata")
			assertTrue(typeof(snapshot.Filter) == "table", "snapshot omitted Filter")
		end
		assertEqual(global.PlaceId, nil)
		assertEqual(session.PlaceId, nil)
		assertEqual(statistics:StartNewSnapshot(player, "Global").Code, "ManagedSnapshotType")
		assertEqual(statistics.GrantReward, nil)
		statistics:Stop(player)
	end)

	test("all operation formulas are deterministic and reads do not insert missing values", function(scope)
		local statistics = makeStatistics()
		scope:Defer(function() statistics:Destroy() end)
		local player = { UserId = 2 } :: any
		loadStatistics(statistics, player)
		local committedReads = 0
		local expectedAtCallback = nil :: number?
		local connection = statistics.Changed:Connect(function(changedPlayer, change)
			assertEqual(changedPlayer, player)
			assertEqual(statistics:GetValue(player, "Global", change.StatisticId), expectedAtCallback)
			committedReads += 1
		end)
		scope:Defer(function() connection:Disconnect() end)
		local cases = {
			{ "Set", -10, 0 },
			{ "Inc", 10, 10 },
			{ "Dec", 3, 7 },
			{ "Dec", 99, 0 },
			{ "Max", 4, 4 },
			{ "Min", 2, 2 },
		}
		for _, case in cases do
			expectedAtCallback = case[3]
			local result = statistics:ApplyOperation(player, {
				Operation = case[1], StatisticId = "Formula", Operand = case[2],
			})
			assertTrue(result.Ok, `operation {case[1]} failed`)
			assertEqual(statistics:GetValue(player, "Global", "Formula"), case[3])
		end
		assertEqual(statistics:GetValue(player, "Global", "Missing"), 0)
		assertEqual(statistics:GetMemento(player).ActiveByType.Global.Values.Missing, nil)
		assertTrue(committedReads > 0, "post-commit change event did not run")
	end)

	test("frozen filters update only eligible active snapshots", function(scope)
		local config = makeConfig()
		config.SnapshotTypes.Session.Filter = { Mode = "AllowOnly", StatisticIds = { "Allowed" } }
		config.SnapshotTypes.Place.Filter = { Mode = "AllowAllExcept", StatisticIds = { "Allowed" } }
		local statistics = makeStatistics({ Config = config })
		scope:Defer(function() statistics:Destroy() end)
		local player = { UserId = 3 } :: any
		loadStatistics(statistics, player)
		statistics:ApplyOperation(player, { Operation = "Inc", StatisticId = "Allowed", Operand = 1 })
		assertEqual(statistics:GetValue(player, "Global", "Allowed"), 1)
		assertEqual(statistics:GetValue(player, "Session", "Allowed"), 1)
		assertEqual(statistics:GetValue(player, "Place", "Allowed"), 0)
	end)

	test("custom lifecycle preserves metadata values filter ID and retention", function(scope)
		local statistics = makeStatistics()
		scope:Defer(function() statistics:Destroy() end)
		local player = { UserId = 4 } :: any
		loadStatistics(statistics, player)
		local metadata = { RunId = "run-1", EventId = "event-1", Difficulty = 3, Nested = { MapId = "map" } }
		local started = statistics:StartNewSnapshot(player, "Round", metadata)
		assertTrue(started.Ok, "custom snapshot did not start")
		metadata.Nested.MapId = "mutated"
		statistics:ApplyOperation(player, { Operation = "Inc", StatisticId = "Round.Score", Operand = 9 })
		local id = statistics:GetActiveSnapshot(player, "Round").SnapshotId
		local activeBeforeClose = statistics:GetActiveSnapshot(player, "Round")
		assertTrue(statistics:CloseSnapshot(player, "Round").Ok, "custom snapshot did not close")
		assertEqual(statistics:CloseSnapshot(player, "Round").Code, "NotActive")
		local retained = statistics:GetSnapshot(player, "Round", id)
		assertEqual(retained.Metadata.Nested.MapId, "map")
		retained.Metadata.Nested.MapId = "returned-mutation"
		retained.Values["Round.Score"] = 999
		assertEqual(statistics:GetSnapshot(player, "Round", id).Metadata.Nested.MapId, "map")
		assertEqual(statistics:GetValue(player, "Round", "Round.Score", id), 9)
		assertTrue(statistics:ContinueSnapshot(player, "Round", id).Ok, "custom snapshot did not continue")
		local continued = statistics:GetActiveSnapshot(player, "Round")
		assertEqual(continued.SnapshotId, id)
		assertEqual(continued.StartedAt, activeBeforeClose.StartedAt)
		assertTrue(TableUtil.deepEqual(continued.Filter, activeBeforeClose.Filter), "continued filter changed")
		assertTrue(TableUtil.deepEqual(continued.Metadata, activeBeforeClose.Metadata), "continued metadata changed")
		assertEqual(statistics:GetValue(player, "Round", "Round.Score"), 9)
	end)

	test("continued historical snapshots preserve creation order before and after re-close", function(scope)
		local statistics = makeStatistics()
		scope:Defer(function() statistics:Destroy() end)
		local player = { UserId = 41 } :: any
		loadStatistics(statistics, player)
		for index = 1, 2 do
			assertTrue(statistics:StartNewSnapshot(player, "Round", { RunId = `run-{index}` }).Ok)
			assertTrue(statistics:CloseSnapshot(player, "Round").Ok)
		end

		assertTrue(statistics:ContinueSnapshot(player, "Round", 1).Ok, "older snapshot did not continue")
		local whileActive = statistics:GetSnapshots(player, "Round")
		assertEqual(whileActive[1].SnapshotId, 1)
		assertEqual(whileActive[1].State, "Active")
		assertEqual(whileActive[2].SnapshotId, 2)
		assertEqual(statistics:GetLastSnapshots(player, "Round", 1)[1].SnapshotId, 2)

		assertTrue(statistics:CloseSnapshot(player, "Round").Ok, "continued older snapshot could not re-close")
		local reclosed = statistics:GetSnapshots(player, "Round")
		assertEqual(reclosed[1].SnapshotId, 1)
		assertEqual(reclosed[2].SnapshotId, 2)

		assertTrue(statistics:StartNewSnapshot(player, "Round", { RunId = "run-3" }).Ok)
		assertTrue(statistics:CloseSnapshot(player, "Round").Ok)
		local retained = statistics:GetSnapshots(player, "Round")
		assertEqual(#retained, 2)
		assertEqual(retained[1].SnapshotId, 2)
		assertEqual(retained[2].SnapshotId, 3)
	end)

	test("metadata bounds and invalid operations leave the complete memento unchanged", function(scope)
		local statistics = makeStatistics()
		scope:Defer(function() statistics:Destroy() end)
		local player = { UserId = 5 } :: any
		loadStatistics(statistics, player)
		assertTrue(statistics:ApplyOperation(player, {
			Operation = "Set", StatisticId = "Overflow", Operand = 1e308,
		}).Ok)
		local before = statistics:GetMemento(player)
		assertEqual(statistics:StartNewSnapshot(player, "Round", { SnapshotId = 7 }).Ok, false)
		local cyclic = {}
		cyclic.Self = cyclic
		assertEqual(statistics:StartNewSnapshot(player, "Round", cyclic).Ok, false)
		assertEqual(statistics:StartNewSnapshot(player, "Round", { Value = string.rep("x", 300) }).Ok, false)
		local tooDeep = { Value = true }
		for _ = 1, 7 do tooDeep = { Child = tooDeep } end
		assertEqual(statistics:StartNewSnapshot(player, "Round", tooDeep).Ok, false)
		assertEqual(statistics:ApplyOperation(player, { Operation = "Nope", StatisticId = "X", Operand = 1 }).Ok, false)
		assertEqual(statistics:ApplyOperation(player, { Operation = "Set", StatisticId = "X", Operand = 0 / 0 }).Ok, false)
		assertEqual(statistics:ApplyOperation(player, { Operation = "Set", StatisticId = "X", Operand = math.huge }).Ok, false)
		assertEqual(statistics:ApplyOperation(player, { Operation = "Set", StatisticId = "X", Operand = -math.huge }).Ok, false)
		assertEqual(statistics:ApplyOperation(player, {
			Operation = "Inc", StatisticId = "Overflow", Operand = 1e308,
		}).Code, "ResultOverflow")
		assertEqual(statistics:ContinueSnapshot(player, "Global", 1).Code, "ManagedSnapshotType")
		assertTrue(TableUtil.deepEqual(before, statistics:GetMemento(player)), "rejected input mutated Statistics")
	end)

	test("metadata node byte and unsafe table limits reject atomically", function(scope)
		local config = makeConfig()
		local statistics = makeStatistics({ Config = config })
		scope:Defer(function() statistics:Destroy() end)
		local player = { UserId = 53 } :: any
		loadStatistics(statistics, player)
		local dirtyEvents = 0
		local lifecycleEvents = 0
		local dirtyConnection = statistics.MementoChanged:Connect(function() dirtyEvents += 1 end)
		local lifecycleConnection = statistics.ActiveSnapshotsChanged:Connect(function() lifecycleEvents += 1 end)
		scope:Defer(function() dirtyConnection:Disconnect() end)
		scope:Defer(function() lifecycleConnection:Disconnect() end)

		local function assertRejected(label: string, metadata: any)
			local before = statistics:GetMemento(player)
			local result = statistics:StartNewSnapshot(player, "Round", metadata)
			assertEqual(result.Ok, false, `{label} metadata was accepted`)
			assertTrue(
				TableUtil.deepEqual(before, statistics:GetMemento(player)),
				`{label} metadata rejection changed the complete memento`
			)
		end

		local nodeOverflow = {}
		for index = 1, config.Limits.MaxMetadataNodes do
			nodeOverflow[index] = true
		end
		assertRejected("node-overflow", nodeOverflow)

		local byteOverflow = {}
		for index = 1, 20 do
			byteOverflow[`Key{index}`] = string.rep("x", 250)
		end
		local measured, encodedBytes = SaveSerialize.measureEncodedSize(byteOverflow)
		assertTrue(measured, "byte-overflow fixture was not serializable")
		assertTrue(
			encodedBytes > config.Limits.MaxMetadataEncodedBytes,
			"byte-overflow fixture did not cross the aggregate metadata limit"
		)
		assertRejected("aggregate-byte-overflow", byteOverflow)

		assertRejected("metatable", setmetatable({ Public = true }, {}))
		assertRejected("mixed-table", { Public = true, [1] = true })
		assertRejected("sparse-table", { [1] = true, [3] = true })
		task.wait()
		assertEqual(dirtyEvents, 0, "rejected metadata emitted a dirty event")
		assertEqual(lifecycleEvents, 0, "rejected metadata emitted a lifecycle event")
	end)

	test("retention never reuses IDs and legacy missing Metadata reconciles safely", function(scope)
		local statistics, _, _, entries = makeStatistics()
		scope:Defer(function() statistics:Destroy() end)
		local player = { UserId = 51 } :: any
		loadStatistics(statistics, player)
		for index = 1, 3 do
			assertTrue(statistics:StartNewSnapshot(player, "Round", { RunId = `run-{index}` }).Ok)
			assertTrue(statistics:CloseSnapshot(player, "Round").Ok)
		end
		local history = statistics:GetSnapshots(player, "Round")
		assertEqual(#history, 2)
		assertEqual(history[1].SnapshotId, 2)
		assertEqual(history[2].SnapshotId, 3)
		assertEqual(entries[1].Fields.Code, "RetentionEvicted")
		assertEqual(entries[1].Fields.SessionId, nil)
		assertEqual(entries[1].Fields.Metadata, nil)
		assertTrue(statistics:StartNewSnapshot(player, "Round").Ok)
		assertEqual(statistics:GetActiveSnapshot(player, "Round").SnapshotId, 4)

		local legacy = statistics:GetMemento(player)
		legacy.ActiveByType.Global.Metadata = nil
		local valid, reconciled = statistics:ValidateMemento(player, legacy)
		assertTrue(valid, "legacy snapshot without Metadata was rejected")
		assertTrue(TableUtil.deepEqual(reconciled.ActiveByType.Global.Metadata, {}))

		local duplicate = statistics:GetMemento(player)
		local activeRound = TableUtil.deepCopy(duplicate.ActiveByType.Round)
		activeRound.State = "Closed"
		activeRound.ClosedAt = 999
		duplicate.HistoryByType.Round = { activeRound }
		assertEqual(statistics:ValidateMemento(player, duplicate), false)

		local zeroConfig = makeConfig()
		zeroConfig.SnapshotTypes.Round.Retention = 0
		local zeroRetention, _, _, zeroEntries = makeStatistics({ Config = zeroConfig })
		scope:Defer(function() zeroRetention:Destroy() end)
		local zeroPlayer = { UserId = 510 } :: any
		loadStatistics(zeroRetention, zeroPlayer)
		assertTrue(zeroRetention:StartNewSnapshot(zeroPlayer, "Round").Ok)
		assertTrue(zeroRetention:CloseSnapshot(zeroPlayer, "Round").Ok)
		assertEqual(#zeroRetention:GetSnapshots(zeroPlayer, "Round"), 0)
		assertEqual(#zeroEntries, 1, "retention zero did not emit one bounded eviction diagnostic")
		assertEqual(zeroEntries[1].Fields.Code, "RetentionEvicted")
		assertEqual(zeroEntries[1].Fields.SessionId, nil)
		assertEqual(zeroEntries[1].Fields.Metadata, nil)
		assertTrue(zeroRetention:StartNewSnapshot(zeroPlayer, "Round").Ok)
		assertEqual(zeroRetention:GetActiveSnapshot(zeroPlayer, "Round").SnapshotId, 2)
	end)

	test("reduced retention loads persists newest history and preserves unrelated state", function(scope)
		local oldConfig = makeConfig()
		oldConfig.SnapshotTypes.Round.Retention = 2
		local source = makeStatistics({ Config = oldConfig })
		scope:Defer(function() source:Destroy() end)
		local player = { UserId = 511 } :: any
		loadStatistics(source, player)
		for index = 1, 2 do
			assertTrue(source:StartNewSnapshot(player, "Round", {
				RunId = `run-{index}`,
				Nested = { Marker = `marker-{index}` },
			}).Ok)
			assertTrue(source:ApplyOperation(player, {
				Operation = "Inc",
				StatisticId = "Round.Score",
				Operand = index,
			}).Ok)
			assertTrue(source:CloseSnapshot(player, "Round").Ok)
		end
		assertTrue(source:ApplyOperation(player, {
			Operation = "Inc",
			StatisticId = "Persistent.Fact",
			Operand = 7,
			FactIdentity = {
				Mode = "EventId",
				SourceId = "RetentionSource",
				EventId = "retained-event",
			},
		}).Ok)
		local sessionSnapshotId = source:GetActiveSnapshot(player, "Session").SnapshotId
		assertTrue(source:PrepareForProfileClose(player).Ok)
		local oldMemento = source:GetMemento(player)

		local key = "StatisticsRetention_511"
		local memory = MemoryStorage.new({
			[key] = {
				FormatVersion = 1,
				Revision = 9,
				Providers = {
					Statistics = { Version = 1, Data = oldMemento },
				},
				Metadata = { CreatedAt = 1, UpdatedAt = 1 },
			},
		})
		local newConfig = makeConfig()
		newConfig.SnapshotTypes.Round.Retention = 1
		local target, _, _, targetEntries = makeStatistics({
			Config = newConfig,
			Session = { SessionId = SESSION_A, EntryKind = "Teleported", SourcePlaceId = 101 },
			PlaceId = 202,
		})
		scope:Defer(function() target:Destroy() end)
		local corruptOldMemento = TableUtil.deepCopy(oldMemento)
		corruptOldMemento.HistoryByType.Round[1].Unexpected = true
		local corruptReconciled = target:ReconcileMemento(player, corruptOldMemento, 1)
		assertEqual(
			target:ValidateMemento(player, corruptReconciled),
			false,
			"retention reconciliation trimmed away a malformed old snapshot"
		)
		local controller = ServerSaveController.new({
			Id = "statistics_retention_generation",
			Providers = { target },
			Storage = SessionLockingStorage.new(memory, { StaleLockSeconds = 1_800 }),
			KeyResolver = function() return key end,
		})
		scope:Defer(function() controller:Destroy(false) end)
		target:BindSaveController(controller)
		assertTrue(controller:Load(player).Ok, "reduced-retention profile did not load")
		local retained = target:GetSnapshots(player, "Round")
		assertEqual(#retained, 1)
		assertEqual(retained[1].SnapshotId, 2)
		assertEqual(retained[1].Metadata.RunId, "run-2")
		assertEqual(retained[1].Metadata.Nested.Marker, "marker-2")
		assertEqual(retained[1].Values["Round.Score"], 2)
		assertEqual(target:GetMemento(player).NextSnapshotIdByType.Round, 3)
		assertEqual(target:GetActiveSnapshot(player, "Session").SnapshotId, sessionSnapshotId)
		assertEqual(target:GetValue(player, "Global", "Persistent.Fact"), 7)
		assertEqual(target:GetValue(player, "Session", "Persistent.Fact"), 7)
		assertEqual(target:GetMemento(player).Dedup.EventIdsBySource.RetentionSource[1], "retained-event")
		assertEqual(targetEntries[1].Fields.Code, "RetentionEvicted")
		assertEqual(targetEntries[1].Fields.SessionId, nil)
		assertTrue(controller:ForceSave(player, "RetentionReconciled").Ok, "trimmed profile did not persist")
		local persisted = memory:Read(key).Providers.Statistics.Data
		assertEqual(#persisted.HistoryByType.Round, 1)
		assertEqual(persisted.HistoryByType.Round[1].SnapshotId, 2)
		assertEqual(persisted.Dedup.EventIdsBySource.RetentionSource[1], "retained-event")
	end)

	test("reduced retention rejects out-of-order history before pruning or persistence", function(scope)
		local oldConfig = makeConfig()
		oldConfig.SnapshotTypes.Round.Retention = 2
		local source = makeStatistics({ Config = oldConfig })
		scope:Defer(function() source:Destroy() end)
		local player = { UserId = 512 } :: any
		loadStatistics(source, player)
		for index = 1, 2 do
			assertTrue(source:StartNewSnapshot(player, "Round", { RunId = `run-{index}` }).Ok)
			assertTrue(source:CloseSnapshot(player, "Round").Ok)
		end

		local corrupt = source:GetMemento(player)
		local orderedHistory = corrupt.HistoryByType.Round
		corrupt.HistoryByType.Round = {
			TableUtil.deepCopy(orderedHistory[2]),
			TableUtil.deepCopy(orderedHistory[1]),
		}
		assertEqual(corrupt.HistoryByType.Round[1].SnapshotId, 2)
		assertEqual(corrupt.HistoryByType.Round[2].SnapshotId, 1)

		local newConfig = makeConfig()
		newConfig.SnapshotTypes.Round.Retention = 1
		local target, _, _, targetEntries = makeStatistics({ Config = newConfig })
		scope:Defer(function() target:Destroy() end)
		local reconciled = target:ReconcileMemento(player, corrupt, 1)
		assertTrue(
			TableUtil.deepEqual(reconciled, corrupt),
			"retention reconciliation pruned corrupt creation order"
		)
		assertEqual(target:ValidateMemento(player, reconciled), false)
		assertEqual(#targetEntries, 0, "rejected reconciliation emitted a retention diagnostic")

		local key = "StatisticsRetentionOrder_512"
		local memory = MemoryStorage.new({
			[key] = {
				FormatVersion = 1,
				Revision = 3,
				Providers = {
					Statistics = { Version = 1, Data = corrupt },
				},
				Metadata = { CreatedAt = 1, UpdatedAt = 1 },
			},
		})
		local controller = ServerSaveController.new({
			Id = "statistics_retention_order",
			Providers = { target },
			Storage = SessionLockingStorage.new(memory, { StaleLockSeconds = 1_800 }),
			KeyResolver = function() return key end,
		})
		scope:Defer(function() controller:Destroy(false) end)
		target:BindSaveController(controller)
		local loadResult = controller:Load(player)
		assertEqual(loadResult.Ok, false, "out-of-order retained history loaded successfully")
		assertEqual(loadResult.Code, "ApplyFailed")
		assertEqual(controller:GetState(player), "LoadFailed")
		assertEqual(target:GetActiveSnapshot(player, "Global"), nil)
		assertEqual(#targetEntries, 0, "failed load emitted a retention diagnostic")

		local persisted = memory:Read(key).Providers.Statistics.Data
		assertTrue(TableUtil.deepEqual(persisted, corrupt), "failed load persisted a trimmed provider")
		assertEqual(persisted.HistoryByType.Round[1].SnapshotId, 2)
		assertEqual(persisted.HistoryByType.Round[2].SnapshotId, 1)
	end)

	test("new statistic ID limits reject insertion but permit existing updates", function(scope)
		local config = makeConfig()
		config.Limits.MaxStatisticIdsPerSnapshot = 1
		local statistics = makeStatistics({ Config = config })
		scope:Defer(function() statistics:Destroy() end)
		local player = { UserId = 52 } :: any
		loadStatistics(statistics, player)
		assertTrue(statistics:ApplyOperation(player, { Operation = "Set", StatisticId = "Only", Operand = 1 }).Ok)
		local before = statistics:GetMemento(player)
		assertEqual(statistics:ApplyOperation(player, { Operation = "Set", StatisticId = "Second", Operand = 1 }).Code, "StatisticLimitExceeded")
		assertTrue(TableUtil.deepEqual(before, statistics:GetMemento(player)))
		assertTrue(statistics:ApplyOperation(player, { Operation = "Inc", StatisticId = "Only", Operand = 2 }).Ok)
		assertEqual(statistics:GetValue(player, "Global", "Only"), 3)
	end)

	test("ordered dedupe and one-candidate size failure are atomic", function(scope)
		local function measure(value)
			if typeof(value) == "table"
				and value.SnapshotType == "Round"
				and typeof(value.Values) == "table"
				and value.Values["Round.Score"] ~= nil
			then
				return true, 99_999, nil
			end
			return SaveSerialize.measureEncodedSize(value)
		end
		local statistics = makeStatistics({ MeasureEncodedSize = measure })
		scope:Defer(function() statistics:Destroy() end)
		local player = { UserId = 6 } :: any
		loadStatistics(statistics, player)
		statistics:StartNewSnapshot(player, "Round")
		local operation = {
			Operation = "Inc", StatisticId = "Public", Operand = 2,
			FactIdentity = { Mode = "Ordered", SourceId = "Source", Sequence = 1, EventId = "event-1" },
		}
		assertEqual(statistics:ApplyOperation(player, operation).Code, "Applied")
		assertEqual(statistics:ApplyOperation(player, operation).Code, "Duplicate")
		for _, snapshotType in { "Global", "Session", "Place" } do
			assertEqual(statistics:GetValue(player, snapshotType, "Public"), 2)
		end
		local before = statistics:GetMemento(player)
		local blocked = statistics:ApplyOperation(player, {
			Operation = "Inc", StatisticId = "Round.Score", Operand = 1,
		})
		assertEqual(blocked.Ok, false)
		assertTrue(TableUtil.deepEqual(before, statistics:GetMemento(player)), "candidate failure partially committed")
	end)

	test("multi-snapshot candidate failure rolls back values dedupe dirty and success events", function(scope)
		local function measure(value)
			if typeof(value) == "table"
				and value.SnapshotType == "Round"
				and typeof(value.Values) == "table"
				and value.Values["Round.Score"] ~= nil
			then
				return true, 99_999, nil
			end
			return SaveSerialize.measureEncodedSize(value)
		end
		local statistics = makeStatistics({ MeasureEncodedSize = measure })
		scope:Defer(function() statistics:Destroy() end)
		local player = { UserId = 63 } :: any
		loadStatistics(statistics, player)
		assertTrue(statistics:StartNewSnapshot(player, "Round").Ok, "Round fixture did not start")
		assertTrue(statistics:ApplyOperation(player, {
			Operation = "Inc",
			StatisticId = "Public",
			Operand = 1,
			FactIdentity = {
				Mode = "Ordered",
				SourceId = "OrderedSource",
				Sequence = 1,
				EventId = "ordered-event-1",
			},
		}).Ok, "ordered baseline fact failed")
		assertTrue(statistics:ApplyOperation(player, {
			Operation = "Inc",
			StatisticId = "Public",
			Operand = 1,
			FactIdentity = {
				Mode = "EventId",
				SourceId = "LedgerSource",
				EventId = "ledger-event-1",
			},
		}).Ok, "EventId baseline fact failed")

		local before = statistics:GetMemento(player)
		local changedEvents = 0
		local dirtyEvents = 0
		local dirtyMarks = 0
		statistics:BindSaveController({
			MarkDirty = function(_self, dirtyPlayer, providerId)
				assertEqual(dirtyPlayer, player)
				assertEqual(providerId, statistics.Id)
				dirtyMarks += 1
			end,
		})
		local changedConnection = statistics.Changed:Connect(function() changedEvents += 1 end)
		local dirtyConnection = statistics.MementoChanged:Connect(function() dirtyEvents += 1 end)
		scope:Defer(function() changedConnection:Disconnect() end)
		scope:Defer(function() dirtyConnection:Disconnect() end)

		local blocked = statistics:ApplyOperation(player, {
			Operation = "Inc",
			StatisticId = "Round.Score",
			Operand = 5,
			FactIdentity = {
				Mode = "Ordered",
				SourceId = "OrderedSource",
				Sequence = 2,
				EventId = "ordered-event-2",
			},
		})
		assertEqual(blocked.Code, "CandidateRejected")
		for _, snapshotType in { "Global", "Session", "Place", "Round" } do
			assertEqual(
				statistics:GetValue(player, snapshotType, "Round.Score"),
				0,
				`{snapshotType} value changed after candidate rejection`
			)
		end
		local after = statistics:GetMemento(player)
		assertEqual(after.Dedup.OrderedSources.OrderedSource.LastSequence, 1)
		assertEqual(after.Dedup.OrderedSources.OrderedSource.LastEventId, "ordered-event-1")
		assertEqual(#after.Dedup.EventIdsBySource.LedgerSource, 1)
		assertEqual(after.Dedup.EventIdsBySource.LedgerSource[1], "ledger-event-1")
		assertTrue(TableUtil.deepEqual(before, after), "candidate rejection changed the complete memento")
		task.wait()
		assertEqual(dirtyMarks, 0, "candidate rejection marked the save provider dirty")
		assertEqual(dirtyEvents, 0, "candidate rejection emitted MementoChanged")
		assertEqual(changedEvents, 0, "candidate rejection emitted a success event")
	end)

	test("new EventId survives late provider rejection and retries exactly once", function(scope)
		local config = makeConfig()
		local rejectCandidate = false
		local providerRejections = 0
		local function measure(value)
			local active = if typeof(value) == "table" then value.ActiveByType else nil
			local dedup = if typeof(value) == "table" then value.Dedup else nil
			local eventIds = if typeof(dedup) == "table" then dedup.EventIdsBySource else nil
			local ledger = if typeof(eventIds) == "table" then eventIds.RetrySource else nil
			local completeCandidate = typeof(active) == "table"
				and typeof(ledger) == "table"
				and #ledger == 1
				and ledger[1] == "retry-event-1"
			for _, snapshotType in { "Global", "Session", "Place", "Round" } do
				local snapshot = if completeCandidate then active[snapshotType] else nil
				if typeof(snapshot) ~= "table"
					or typeof(snapshot.Values) ~= "table"
					or snapshot.Values["Round.Score"] ~= 1
				then
					completeCandidate = false
					break
				end
			end
			if rejectCandidate and completeCandidate then
				providerRejections += 1
				return true, config.Limits.MaxProviderEncodedBytes + 1, nil
			end
			return SaveSerialize.measureEncodedSize(value)
		end

		local statistics = makeStatistics({ Config = config, MeasureEncodedSize = measure })
		scope:Defer(function() statistics:Destroy() end)
		local player = { UserId = 64 } :: any
		loadStatistics(statistics, player)
		assertTrue(statistics:StartNewSnapshot(player, "Round").Ok, "Round fixture did not start")

		local dirtyMarks = 0
		local dirtyEvents = 0
		local changedEvents = 0
		statistics:BindSaveController({
			MarkDirty = function(_self, dirtyPlayer, providerId)
				assertEqual(dirtyPlayer, player)
				assertEqual(providerId, statistics.Id)
				dirtyMarks += 1
			end,
		})
		local dirtyConnection = statistics.MementoChanged:Connect(function() dirtyEvents += 1 end)
		local changedConnection = statistics.Changed:Connect(function() changedEvents += 1 end)
		scope:Defer(function() dirtyConnection:Disconnect() end)
		scope:Defer(function() changedConnection:Disconnect() end)

		local operation = {
			Operation = "Inc",
			StatisticId = "Round.Score",
			Operand = 1,
			FactIdentity = {
				Mode = "EventId",
				SourceId = "RetrySource",
				EventId = "retry-event-1",
			},
		}
		local before = statistics:GetMemento(player)
		assertEqual(before.Dedup.EventIdsBySource.RetrySource, nil, "EventId fixture started consumed")
		assertTrue(
			config.Limits.MaxEventIdsPerSource > 1,
			"EventId fixture did not leave ledger capacity"
		)

		rejectCandidate = true
		local blocked = statistics:ApplyOperation(player, operation)
		assertEqual(blocked.Code, "CandidateRejected")
		assertEqual(providerRejections, 1, "operation did not reach late provider-size validation")
		assertTrue(
			TableUtil.deepEqual(before, statistics:GetMemento(player)),
			"late provider rejection changed the complete memento"
		)
		for _, snapshotType in { "Global", "Session", "Place", "Round" } do
			assertEqual(
				statistics:GetValue(player, snapshotType, "Round.Score"),
				0,
				`{snapshotType} value changed after late provider rejection`
			)
		end
		task.wait()
		assertEqual(dirtyMarks, 0, "late provider rejection marked the save provider dirty")
		assertEqual(dirtyEvents, 0, "late provider rejection emitted MementoChanged")
		assertEqual(changedEvents, 0, "late provider rejection emitted a success event")

		rejectCandidate = false
		local applied = statistics:ApplyOperation(player, operation)
		assertEqual(applied.Code, "Applied")
		assertEqual(#applied.ChangedSnapshotIds, 4, "retry did not change every eligible snapshot")
		for _, snapshotType in { "Global", "Session", "Place", "Round" } do
			assertEqual(
				statistics:GetValue(player, snapshotType, "Round.Score"),
				1,
				`{snapshotType} did not apply the retried EventId exactly once`
			)
		end
		local appliedMemento = statistics:GetMemento(player)
		local appliedLedger = appliedMemento.Dedup.EventIdsBySource.RetrySource
		assertEqual(#appliedLedger, 1, "retried EventId did not create exactly one ledger entry")
		assertEqual(appliedLedger[1], "retry-event-1")
		task.wait()
		assertEqual(dirtyMarks, 1, "successful retry did not mark the provider exactly once")
		assertEqual(dirtyEvents, 1, "successful retry did not emit MementoChanged exactly once")
		assertEqual(changedEvents, 1, "successful retry did not emit one success event")

		assertEqual(statistics:ApplyOperation(player, operation).Code, "Duplicate")
		task.wait()
		assertEqual(dirtyMarks, 1, "duplicate retry marked the provider dirty")
		assertEqual(dirtyEvents, 1, "duplicate retry emitted MementoChanged")
		assertEqual(changedEvents, 1, "duplicate retry emitted a success event")
		local duplicateMemento = statistics:GetMemento(player)
		local duplicateLedger = duplicateMemento.Dedup.EventIdsBySource.RetrySource
		assertEqual(#duplicateLedger, 1, "duplicate retry changed the EventId ledger")
		assertEqual(duplicateLedger[1], "retry-event-1")
		for _, snapshotType in { "Global", "Session", "Place", "Round" } do
			assertEqual(statistics:GetValue(player, snapshotType, "Round.Score"), 1)
		end
	end)

	test("accepted candidates reserve enough capacity for profile close", function(scope)
		local config = makeConfig()
		local rejectClosedBoundary = false
		local function measure(value)
			if rejectClosedBoundary
				and typeof(value) == "table"
				and value.SnapshotType ~= nil
				and value.State == "Closed"
				and typeof(value.Values) == "table"
				and value.Values.CloseBoundary ~= nil
			then
				return true, config.Limits.MaxSnapshotEncodedBytes + 1, nil
			end
			return SaveSerialize.measureEncodedSize(value)
		end
		local statistics = makeStatistics({ Config = config, MeasureEncodedSize = measure })
		scope:Defer(function() statistics:Destroy() end)
		local player = { UserId = 61 } :: any
		loadStatistics(statistics, player)
		local before = statistics:GetMemento(player)
		rejectClosedBoundary = true
		local result = statistics:ApplyOperation(player, {
			Operation = "Set",
			StatisticId = "CloseBoundary",
			Operand = 1,
		})
		assertEqual(result.Code, "CandidateRejected")
		assertTrue(TableUtil.deepEqual(before, statistics:GetMemento(player)), "unclosable state was committed")
		assertTrue(statistics:PrepareForProfileClose(player).Ok, "prior valid state did not remain closable")
	end)

	test("teleport continuation keeps Session and replaces Place while mismatch starts a new Session", function(scope)
		local source = makeStatistics({ Session = { SessionId = SESSION_A, EntryKind = "External" }, PlaceId = 101 })
		scope:Defer(function() source:Destroy() end)
		local player = { UserId = 7 } :: any
		loadStatistics(source, player)
		source:ApplyOperation(player, { Operation = "Inc", StatisticId = "Public", Operand = 5 })
		local sessionId = source:GetActiveSnapshot(player, "Session").SnapshotId
		local placeId = source:GetActiveSnapshot(player, "Place").SnapshotId
		local cold = makeStatistics({
			Session = { SessionId = SESSION_A, EntryKind = "Teleported", SourcePlaceId = 101 },
			PlaceId = 101,
		})
		scope:Defer(function() cold:Destroy() end)
		cold:SetMemento(player, source:GetMemento(player))
		cold:Run(player)
		assertTrue(
			cold:GetActiveSnapshot(player, "Session").SnapshotId > sessionId,
			"cold load incorrectly reused an active Session as a rollback resume"
		)
		assertTrue(
			cold:GetActiveSnapshot(player, "Place").SnapshotId > placeId,
			"cold same-Place load incorrectly reused an active Place visit"
		)
		assertTrue(source:PrepareForProfileClose(player).Ok, "source close preparation failed")
		local saved = source:GetMemento(player)

		local target = makeStatistics({
			Session = { SessionId = SESSION_A, EntryKind = "Teleported", SourcePlaceId = 101 },
			PlaceId = 202,
		})
		scope:Defer(function() target:Destroy() end)
		target:SetMemento(player, saved)
		target:Run(player)
		assertEqual(target:GetActiveSnapshot(player, "Session").SnapshotId, sessionId)
		assertEqual(target:GetValue(player, "Session", "Public"), 5)
		assertTrue(target:GetActiveSnapshot(player, "Place").SnapshotId > placeId, "target Place ID was reused")
		assertEqual(target:GetActiveSnapshot(player, "Place").PlaceId, 202)

		target:PrepareForProfileClose(player)
		local mismatchSaved = target:GetMemento(player)
		local third = makeStatistics({
			Session = { SessionId = SESSION_A, EntryKind = "Teleported", SourcePlaceId = 202 },
			PlaceId = 303,
		})
		scope:Defer(function() third:Destroy() end)
		third:SetMemento(player, mismatchSaved)
		third:Run(player)
		assertEqual(third:GetActiveSnapshot(player, "Session").SnapshotId, sessionId)
		assertEqual(third:GetActiveSnapshot(player, "Place").SnapshotId, placeId + 2)
		third:PrepareForProfileClose(player)

		local mismatch, _, _, mismatchEntries = makeStatistics({
			Session = { SessionId = SESSION_B, EntryKind = "External", SourcePlaceId = nil },
			PlaceId = 404,
		})
		scope:Defer(function() mismatch:Destroy() end)
		mismatch:SetMemento(player, third:GetMemento(player))
		mismatch:Run(player)
		assertEqual(mismatch:GetActiveSnapshot(player, "Global").SnapshotId, 1)
		assertTrue(mismatch:GetActiveSnapshot(player, "Session").SnapshotId > sessionId, "external entry continued old Session")
		assertEqual(mismatchEntries[1].Fields.Code, "SessionHandoffMismatch")
		assertEqual(mismatchEntries[1].Fields.SessionId, nil)
		assertEqual(mismatchEntries[1].Fields.Metadata, nil)
	end)

	test("Wallet committed changes are synchronous ordered and startup balances are ignored", function(scope)
		local boundaryConfig = makeConfig()
		boundaryConfig.Limits.MaxStatisticIdLength = 36
		local statistics = makeStatistics({ Config = boundaryConfig })
		scope:Defer(function() statistics:Destroy() end)
		local wallet = WalletModule.new({ Queue = function() return true end }, {
			GetRequired = function() return { StartingBalances = { Coins = 10, Gems = 2 } } end,
		})
		wallet:Initialize()
		local adapter = WalletStatisticsController.new({ Wallet = wallet, Statistics = statistics, Logger = makeLogger() })
		adapter:Initialize()
		scope:Defer(function() adapter:Destroy() end)
		local player = { UserId = 8 } :: any
		loadStatistics(statistics, player)
		wallet:SetMemento(player, wallet:CreateDefault(player))
		wallet:Run(player)
		assertEqual(statistics:GetValue(player, "Global", "Wallet.Coins.Earned"), 0)
		assertEqual(statistics:GetValue(player, "Global", "Wallet.Gems.Earned"), 0)
		local added = wallet:Add(player, "Coins", 7, "Test")
		assertTrue(added.Ok, "Wallet add failed")
		assertEqual(#added.TransactionId, 36)
		assertEqual(added.TransactionSequence, 1)
		local gemsAdded = wallet:Add(player, "Gems", 4, "Test")
		assertTrue(gemsAdded.Ok, "Wallet Gems add failed")
		local cyclicMetadata = {}
		cyclicMetadata.Self = cyclicMetadata
		local cyclicAdded = wallet:Add(player, "Coins", 1, "CyclicMetadata", cyclicMetadata)
		assertTrue(cyclicAdded.Ok, "cyclic Wallet metadata interrupted the committed fact")
		assertEqual(#cyclicAdded.IntegrationFailures, 0)
		for _, snapshotType in { "Global", "Session", "Place" } do
			assertEqual(statistics:GetValue(player, snapshotType, "Wallet.Coins.Earned"), 8)
			assertEqual(statistics:GetValue(player, snapshotType, "Wallet.Gems.Earned"), 4)
		end
		wallet:TrySpend(player, "Coins", 3, "Spend")
		wallet:Add(player, "Gems", 0, "NoOp")
		local rejected = wallet:Add(player, "Coins", 9_007_199_254_740_991, "Rejected")
		assertEqual(rejected.Ok, false)
		for _, snapshotType in { "Global", "Session", "Place" } do
			assertEqual(statistics:GetValue(player, snapshotType, "Wallet.Coins.Earned"), 8)
			assertEqual(statistics:GetValue(player, snapshotType, "Wallet.Gems.Earned"), 4)
		end
		wallet:Stop(player)
	end)

	test("EventId dedupe is exact bounded atomic and observable", function(scope)
		local config = makeConfig()
		config.Limits.MaxDedupSources = 1
		config.Limits.MaxEventIdsPerSource = 1
		local statistics, _, _, entries = makeStatistics({ Config = config })
		scope:Defer(function() statistics:Destroy() end)
		local player = { UserId = 82 } :: any
		loadStatistics(statistics, player)
		local first = {
			Operation = "Inc",
			StatisticId = "Event.Count",
			Operand = 1,
			FactIdentity = { Mode = "EventId", SourceId = "SourceA", EventId = "event-1" },
		}
		assertEqual(statistics:ApplyOperation(player, first).Code, "Applied")
		assertEqual(statistics:ApplyOperation(player, first).Code, "Duplicate")
		local before = statistics:GetMemento(player)
		local sourceLimit = statistics:ApplyOperation(player, {
			Operation = "Inc",
			StatisticId = "Event.Count",
			Operand = 1,
			FactIdentity = { Mode = "EventId", SourceId = "SourceB", EventId = "event-1" },
		})
		assertEqual(sourceLimit.Code, "DedupeLimitExceeded")
		assertTrue(TableUtil.deepEqual(before, statistics:GetMemento(player)), "source limit partially committed")
		local ledgerLimit = statistics:ApplyOperation(player, {
			Operation = "Inc",
			StatisticId = "Event.Count",
			Operand = 1,
			FactIdentity = { Mode = "EventId", SourceId = "SourceA", EventId = "event-2" },
		})
		assertEqual(ledgerLimit.Code, "DedupeLimitExceeded")
		assertTrue(TableUtil.deepEqual(before, statistics:GetMemento(player)), "ledger limit partially committed")
		local dedupeDiagnostics = 0
		for _, entry in entries do
			if entry.Fields.Code == "DedupeLimitExceeded" then
				dedupeDiagnostics += 1
				assertEqual(entry.Fields.UserId, 82)
				assertEqual(entry.Fields.EventId, nil)
			end
		end
		assertEqual(dedupeDiagnostics, 1, "dedupe limit diagnostics were missing or not cooldown-bounded")
	end)

	test("Wallet adapter rejection diagnostics are cooldown-bounded and payload-safe", function(scope)
		local committedHandler: any = nil
		local wallet = {
			RegisterCommittedChangeHandler = function(_self, handler)
				committedHandler = handler
				return { Disconnect = function() end }
			end,
		}
		local now = 100
		local logger, entries = makeLogger()
		local adapter = WalletStatisticsController.new({
			Wallet = wallet,
			Statistics = { ApplyOperation = function() return { Ok = false, Code = "Closing" } end },
			Logger = logger,
			Clock = function() return now end,
		})
		adapter:Initialize()
		scope:Defer(function() adapter:Destroy() end)
		local player = { UserId = 81 } :: any
		local change = {
			Delta = 5,
			Path = { "Coins" },
			TransactionSequence = 1,
			TransactionId = "secret-transaction-id",
		}
		committedHandler(player, change)
		committedHandler(player, change)
		assertEqual(#entries, 1)
		assertEqual(entries[1].Fields.UserId, 81)
		assertEqual(entries[1].Fields.Code, "Closing")
		assertEqual(entries[1].Fields.Delta, nil)
		assertEqual(entries[1].Fields.Path, nil)
		assertEqual(entries[1].Fields.TransactionId, nil)
		now = 102
		committedHandler(player, change)
		assertEqual(#entries, 2)
	end)

	test("global save omits Statistics and close captures the final synchronous Wallet fact", function(scope)
		local memory = MemoryStorage.new()
		local statistics = makeStatistics()
		scope:Defer(function() statistics:Destroy() end)
		local wallet = WalletModule.new({ Queue = function() return true end }, {
			GetRequired = function() return { StartingBalances = { Coins = 0, Gems = 0 } } end,
		})
		wallet:Initialize()
		local adapter = WalletStatisticsController.new({ Wallet = wallet, Statistics = statistics, Logger = makeLogger() })
		adapter:Initialize()
		scope:Defer(function() adapter:Destroy() end)
		local controller = ServerSaveController.new({
			Id = "statistics_close",
			Providers = { wallet, statistics },
			Storage = SessionLockingStorage.new(memory, { StaleLockSeconds = 1_800 }),
			KeyResolver = function(player) return `Statistics_{player.UserId}` end,
		})
		scope:Defer(function() controller:Destroy(false) end)
		statistics:BindSaveController(controller)
		local player = { UserId = 9 } :: any
		assertTrue(controller:Load(player).Ok, "integrated profile load failed")
		assertEqual(controller:BuildSnapshot(player).Providers.Statistics, nil, "Statistics leaked into client snapshot")
		local persistedBeforeOperations = memory:Read("Statistics_9")
		for _ = 1, 3 do
			assertTrue(statistics:ApplyOperation(player, {
				Operation = "Inc", StatisticId = "Public", Operand = 1,
			}).Ok)
		end
		assertTrue(wallet:Add(player, "Coins", 11, "BeforeClose").Ok, "final Wallet fact failed")
		assertTrue(
			TableUtil.deepEqual(memory:Read("Statistics_9"), persistedBeforeOperations),
			"runtime Statistics operations persisted before the save contour"
		)
		assertTrue(statistics:PrepareForProfileClose(player).Ok, "Statistics close preparation failed")
		assertTrue(controller:Close(player, true).Ok, "profile close failed")
		local stored = memory:Read("Statistics_9").Providers.Statistics.Data
		assertEqual(stored.ActiveByType.Global.Values["Wallet.Coins.Earned"], 11)
		assertEqual(stored.PendingSession.Values["Wallet.Coins.Earned"], 11)
		assertEqual(stored.HistoryByType.Place[1].Values["Wallet.Coins.Earned"], 11)
	end)

	test("generic save ignores identical dirty captures and full-captures unsignaled close state", function(scope)
		local changed = Signal.new()
		scope:Defer(function() changed:Destroy() end)
		local values = {} :: { [any]: number }
		local provider = {
			Id = "CaptureProbe",
			Version = 1,
			Authority = "Server",
			MementoChanged = changed,
			CreateDefault = function() return { Value = 1 } end,
			ReconcileMemento = function(_self, _player, value) return value end,
			ValidateMemento = function(_self, _player, value)
				return typeof(value) == "table" and typeof(value.Value) == "number", value, nil
			end,
			SetMemento = function(_self, player, value) values[player] = value.Value end,
			GetMemento = function(_self, player) return { Value = values[player] } end,
			BeforeMementoGet = function() end,
			Run = function() end,
			Stop = function() end,
			ToClientMemento = function(_self, _player, value) return value end,
		}
		local memory = MemoryStorage.new()
		local controller = ServerSaveController.new({
			Id = "capture_probe",
			Providers = { provider },
			Storage = SessionLockingStorage.new(memory, { StaleLockSeconds = 1_800 }),
			KeyResolver = function(player) return `CaptureProbe_{player.UserId}` end,
		})
		scope:Defer(function() controller:Destroy(false) end)
		local player = { UserId = 91 } :: any
		assertTrue(controller:Load(player).Ok, "capture probe load failed")
		local revision = controller:BuildSnapshot(player).Revision
		changed:Fire(player)
		assertTrue(controller:FlushDirty(player), "identical dirty capture failed")
		assertEqual(controller:BuildSnapshot(player).Revision, revision, "identical capture advanced revision")
		values[player] = 7
		assertTrue(controller:Close(player, true).Ok, "capture probe close failed")
		assertEqual(memory:Read("CaptureProbe_91").Providers.CaptureProbe.Data.Value, 7)
	end)

	test("Statistics rollback restart preserves exact runtime document and emits no lifecycle work", function(scope)
		local statistics = makeStatistics()
		scope:Defer(function() statistics:Destroy() end)
		local values = {} :: { [any]: number }
		local failTarget = false
		local laterProvider = {
			Id = "LaterRunProbe",
			Version = 1,
			Authority = "Server",
			CreateDefault = function() return { Value = 1 } end,
			ReconcileMemento = function(_self, _player, value) return value end,
			ValidateMemento = function(_self, _player, value)
				return typeof(value) == "table" and typeof(value.Value) == "number", value, nil
			end,
			SetMemento = function(_self, owner, value) values[owner] = value.Value end,
			GetMemento = function(_self, owner) return { Value = values[owner] } end,
			BeforeMementoGet = function() end,
			Run = function(_self, owner)
				if failTarget and values[owner] == 2 then error("injected later provider Run failure") end
			end,
			Stop = function(_self, owner) values[owner] = nil end,
			ToClientMemento = function(_self, _player, value) return value end,
		}
		local memory = MemoryStorage.new()
		local controller = ServerSaveController.new({
			Id = "statistics_exact_rollback",
			Providers = { statistics, laterProvider },
			Storage = SessionLockingStorage.new(memory, { StaleLockSeconds = 1_800 }),
			KeyResolver = function(owner) return `StatisticsRollback_{owner.UserId}` end,
		})
		scope:Defer(function() controller:Destroy(false) end)
		statistics:BindSaveController(controller)
		local player = { UserId = 92 } :: any
		assertTrue(controller:Load(player).Ok, "rollback fixture failed to load")
		assertTrue(controller:ForceSave(player, "RollbackBaseline").Ok, "rollback baseline failed to persist")
		local beforeRuntime = statistics:GetMemento(player)
		local beforeDocument = memory:Read("StatisticsRollback_92")
		local target = TableUtil.deepCopy(beforeDocument)
		target.Revision += 1
		target.Providers.Statistics.Data.ActiveByType.Global.Values.RollbackProbe = 99
		target.Providers.LaterRunProbe.Data.Value = 2

		local dirtyEvents = 0
		local lifecycleEvents = 0
		local dirtyConnection = statistics.MementoChanged:Connect(function() dirtyEvents += 1 end)
		local lifecycleConnection = statistics.ActiveSnapshotsChanged:Connect(function() lifecycleEvents += 1 end)
		scope:Defer(function() dirtyConnection:Disconnect() end)
		scope:Defer(function() lifecycleConnection:Disconnect() end)
		failTarget = true
		local applied = pcall(function() controller:ApplyMemento(player, target) end)
		assertEqual(applied, false, "later provider failure did not abort snapshot application")
		assertTrue(controller:IsLoaded(player), "successful rollback did not restore Loaded state")
		assertTrue(TableUtil.deepEqual(statistics:GetMemento(player), beforeRuntime), "Statistics runtime changed after rollback")
		assertEqual(values[player], 1)
		task.wait()
		assertEqual(dirtyEvents, 0, "rollback restart emitted Statistics dirty notification")
		assertEqual(lifecycleEvents, 0, "rollback restart emitted Statistics lifecycle notification")
		controller:MarkDirty(player, statistics.Id)
		assertTrue(controller:FlushDirty(player), "restored Statistics runtime could not be recaptured")
		assertTrue(controller:ForceSave(player, "RollbackVerification").Ok)
		assertTrue(TableUtil.deepEqual(memory:Read("StatisticsRollback_92"), beforeDocument), "rollback changed persisted document")
	end)

	test("client projection strips internals and request protocol has no mutation surface", function(scope)
		local config = makeConfig()
		local statistics = makeStatistics({ Config = config })
		scope:Defer(function() statistics:Destroy() end)
		local player = { UserId = 10 } :: any
		loadStatistics(statistics, player)
		statistics:ApplyOperation(player, { Operation = "Set", StatisticId = "Public", Operand = 4 })
		statistics:ApplyOperation(player, { Operation = "Set", StatisticId = "Private", Operand = 9 })
		local handlers = {}
		local controller = StatisticsRequestController.new({
			Statistics = statistics,
			Communication = { RegisterRequestHandler = function(_self, id, validate, handle)
				handlers[id] = { Validate = validate, Handle = handle }
			end },
		})
		controller:Initialize()
		assertEqual(StatisticsProtocol.RequestTypes.Mutate, nil)
		for _, snapshotType in { "Global", "Session", "Place" } do
			local valid, request = handlers[StatisticsProtocol.RequestTypes.GetCurrentSnapshot].Validate({ SnapshotType = snapshotType })
			assertTrue(valid, "valid Statistics read request rejected")
			local handled, snapshot = handlers[StatisticsProtocol.RequestTypes.GetCurrentSnapshot].Handle(player, request)
			assertTrue(handled, "Statistics read request failed")
			assertEqual(snapshot.Values.Public, 4)
			assertEqual(snapshot.Values.Private, nil)
			assertEqual(snapshot.SessionId, nil)
			assertEqual(snapshot.Filter, nil)
		end
		assertEqual(handlers[StatisticsProtocol.RequestTypes.GetCurrentSnapshot].Validate({ SnapshotType = "Round" }), false)
		assertEqual(handlers[StatisticsProtocol.RequestTypes.GetCurrentSnapshot].Validate({ SnapshotType = "Global", TargetUserId = 99 }), false)
		config.Limits.MaxClientResponseEstimatedBytes = 1
		local _, boundedRequest = handlers[StatisticsProtocol.RequestTypes.GetCurrentSnapshot].Validate({ SnapshotType = "Global" })
		local handled, _, responseError = handlers[StatisticsProtocol.RequestTypes.GetCurrentSnapshot].Handle(player, boundedRequest)
		assertEqual(handled, false)
		assertEqual(responseError, "ResponseTooLarge")
		assertEqual(StatisticsProtocol.RequestTypes.GetHistory, nil)
	end)

	test("registered client requests preserve public metadata and strip private state", function(scope)
		local config = makeConfig()
		for _, snapshotType in { "Global", "Session", "Place" } do
			config.PublicProjection[snapshotType].MetadataKeys = { "PublicMeta" }
		end
		local statistics = makeStatistics({ Config = config })
		scope:Defer(function() statistics:Destroy() end)
		local player = { UserId = 103 } :: any
		loadStatistics(statistics, player)
		assertTrue(statistics:ApplyOperation(player, {
			Operation = "Set", StatisticId = "Public", Operand = 4,
		}).Ok)
		assertTrue(statistics:ApplyOperation(player, {
			Operation = "Set", StatisticId = "Private", Operand = 9,
		}).Ok)
		local withMetadata = statistics:GetMemento(player)
		for _, snapshotType in { "Global", "Session", "Place" } do
			withMetadata.ActiveByType[snapshotType].Metadata = {
				PublicMeta = `public-{snapshotType}`,
				PrivateMeta = `private-{snapshotType}`,
			}
		end
		local valid, sanitized, validationError = statistics:ValidateMemento(player, withMetadata)
		assertTrue(valid, validationError or "metadata projection fixture was invalid")
		statistics:SetMemento(player, sanitized)

		local removing = Signal.new()
		scope:Defer(function() removing:Destroy() end)
		local communication = CommunicationServer.new({
			PlayersModule = { PlayerRemoving = removing },
			Transport = {
				ClientToServer = {},
				ServerToClient = { FireClient = function() end },
				Request = {},
			},
		})
		scope:Defer(function() communication:Stop() end)
		local controller = StatisticsRequestController.new({
			Statistics = statistics,
			Communication = communication,
		})
		controller:Initialize()

		for _, snapshotType in { "Global", "Session", "Place" } do
			local response = communication:HandleRequest(player, {
				Type = StatisticsProtocol.RequestTypes.GetCurrentSnapshot,
				Payload = { SnapshotType = snapshotType },
			})
			assertTrue(response.Ok, `{snapshotType} registered request failed`)
			local snapshot = response.Payload
			assertEqual(snapshot.Values.Public, 4)
			assertEqual(snapshot.Values.Private, nil)
			assertEqual(snapshot.Metadata.PublicMeta, `public-{snapshotType}`)
			assertEqual(snapshot.Metadata.PrivateMeta, nil)
			assertEqual(snapshot.SessionId, nil)
			assertEqual(snapshot.Filter, nil)
			assertEqual(snapshot.Dedup, nil)
		end
	end)

	test("read-only client facade validates complete responses and exposes no mutation method", function()
		local client = StatisticsClient.new({
			Request = function(_self, requestType)
				if requestType == StatisticsProtocol.RequestTypes.GetCurrentSnapshot then
					return true, {
						SnapshotId = 1, SnapshotType = "Global", State = "Active", StartedAt = 1,
						Metadata = {}, Values = { Public = 2 },
					}, nil
				end
				return true, { SnapshotId = 1, SnapshotType = "Global", StatisticId = "Public", Value = 2 }, nil
			end,
		})
		client:Initialize()
		assertTrue(client:GetCurrentSnapshot("Global").Ok, "client snapshot read failed")
		assertEqual(client:GetCurrentValue("Global", "Public").Value.Value, 2)
		assertEqual(client.ApplyOperation, nil)
		assertEqual(StatisticsProtocol.ValidateClientSnapshot({
			SnapshotId = 1, SnapshotType = "Global", State = "Active", StartedAt = 1,
			Metadata = {}, Values = { Public = -1 },
		}), false)
		assertEqual(StatisticsProtocol.ValidateClientValue({
			SnapshotId = 1, SnapshotType = "Global", StatisticId = "bad id", Value = 1,
		}), false)
	end)

	test("project client facts use a fixed code-owned mapping", function(scope)
		local statistics = makeStatistics()
		scope:Defer(function() statistics:Destroy() end)
		local player = { UserId = 11 } :: any
		loadStatistics(statistics, player)
		local handlers = {}
		local eligible = true
		local now = 100
		local logger, entries = makeLogger()
		local controller = StatisticsClientFactController.new({
			Statistics = statistics,
			Communication = { RegisterHandler = function(_self, id, validate, handle)
				handlers[id] = { Validate = validate, Handle = handle }
			end },
			Definitions = {
				{
					MessageType = "Project.Jump",
					Validate = function(payload)
						local valid = typeof(payload) == "table"
							and payload.Jumped == true
							and payload.StatisticId == nil
						return valid, if valid then { Jumped = true } else nil, if valid then nil else "InvalidJump"
					end,
					IsEligible = function() return eligible end,
					Map = function()
						return { Operation = "Inc", StatisticId = "Public", Operand = 1 }
					end,
				},
			},
			Logger = logger,
			Clock = function() return now end,
		})
		controller:Initialize()
		assertEqual(handlers["Project.Jump"].Validate({ Jumped = true, StatisticId = "Private" }), false)
		local valid, sanitized = handlers["Project.Jump"].Validate({ Jumped = true })
		assertTrue(valid, "project fact validator rejected its domain payload")
		handlers["Project.Jump"].Handle(player, sanitized)
		assertEqual(statistics:GetValue(player, "Global", "Public"), 1)
		eligible = false
		handlers["Project.Jump"].Handle(player, sanitized)
		handlers["Project.Jump"].Handle(player, sanitized)
		assertEqual(statistics:GetValue(player, "Global", "Public"), 1)
		assertEqual(statistics:GetValue(player, "Global", "Private"), 0)
		assertEqual(#entries, 1)
		assertEqual(entries[1].Fields.UserId, 11)
		assertEqual(entries[1].Fields.MessageType, "Project.Jump")
		assertEqual(entries[1].Fields.Code, "Ineligible")
		assertEqual(entries[1].Fields.Payload, nil)
		now = 102
		handlers["Project.Jump"].Handle(player, sanitized)
		assertEqual(#entries, 2)
		eligible = true
		statistics:Stop(player)
		handlers["Project.Jump"].Handle(player, sanitized)
		handlers["Project.Jump"].Handle(player, sanitized)
		assertEqual(#entries, 3)
		assertEqual(entries[3].Fields.Code, "NotLoaded")
		assertEqual(handlers["Unknown"], nil)
	end)

	test("Statistics client facts and reads enforce common Communication rate policy", function(scope)
		local now = 0
		local removing = Signal.new()
		scope:Defer(function() removing:Destroy() end)
		local communication = CommunicationServer.new({
			PlayersModule = { PlayerRemoving = removing },
			Clock = function() return now end,
			Transport = {
				ClientToServer = {},
				ServerToClient = { FireClient = function() end },
				Request = {},
			},
		})
		scope:Defer(function() communication:Stop() end)
		local statistics = makeStatistics()
		scope:Defer(function() statistics:Destroy() end)
		local player = { UserId = 111 } :: any
		loadStatistics(statistics, player)
		local factController = StatisticsClientFactController.new({
			Statistics = statistics,
			Communication = communication,
			Definitions = {
				{
					MessageType = "Project.Jump",
					Validate = function(payload)
						local valid = typeof(payload) == "table"
							and payload.Jumped == true
							and payload.StatisticId == nil
						return valid, if valid then { Jumped = true } else nil, "InvalidJump"
					end,
					Map = function()
						return { Operation = "Inc", StatisticId = "Public", Operand = 1 }
					end,
				},
			},
		})
		factController:Initialize()
		for sequence = 1, CommunicationConfig.BatchInvocationBurst do
			communication:ReceiveBatch(player, {
				Sequence = sequence,
				Messages = { { Type = "Project.Jump", Payload = { Jumped = true } } },
			})
		end
		communication:ReceiveBatch(player, {
			Sequence = CommunicationConfig.BatchInvocationBurst + 1,
			Messages = { { Type = "Project.Jump", Payload = { Jumped = true } } },
		})
		assertEqual(
			statistics:GetValue(player, "Global", "Public"),
			CommunicationConfig.BatchInvocationBurst,
			"rate-limited fact reached Statistics"
		)
		now = 1
		communication:ReceiveBatch(player, {
			Sequence = CommunicationConfig.BatchInvocationBurst + 1,
			Messages = {
				{ Type = "Project.Jump", Payload = { Jumped = true, StatisticId = "Private" } },
			},
		})
		assertEqual(statistics:GetValue(player, "Global", "Private"), 0)

		local requestController = StatisticsRequestController.new({
			Statistics = statistics,
			Communication = communication,
		})
		requestController:Initialize()
		local requests = {
			{ Type = StatisticsProtocol.RequestTypes.GetCurrentSnapshot, Payload = { SnapshotType = "Round" } },
			{
				Type = StatisticsProtocol.RequestTypes.GetCurrentSnapshot,
				Payload = { SnapshotType = "Global", TargetUserId = 999 },
			},
			{ Type = StatisticsProtocol.RequestTypes.GetCurrentSnapshot, Payload = { SnapshotType = "Global" } },
			{
				Type = StatisticsProtocol.RequestTypes.GetCurrentValue,
				Payload = { SnapshotType = "Global", StatisticId = "Public" },
			},
		}
		assertEqual(communication:HandleRequest(player, requests[1]).Code, "Unavailable")
		assertEqual(communication:HandleRequest(player, requests[2]).Code, "Unavailable")
		assertTrue(communication:HandleRequest(player, requests[3]).Ok)
		assertTrue(communication:HandleRequest(player, requests[4]).Ok)
		local limited = communication:HandleRequest(player, requests[3])
		assertEqual(limited.Code, "RateLimited", "frequent Statistics read bypassed common request policy")
	end)

	test("coalesced SaveSnapshot requests retain at most one pending write", function(scope)
		local now = 100
		local scheduled = {}
		local forceSaves = 0
		local closed = Signal.new()
		scope:Defer(function() closed:Destroy() end)
		local autosave = AutoSaveModule.new(makeLogger(), {
			Clock = function() return now end,
			Random = function() return 0 end,
			Spawn = function(callback) table.insert(scheduled, callback) end,
			Wait = function(seconds) now += seconds or 0; return seconds end,
		})
		scope:Defer(function() autosave:Stop() end)
		local controller = {
			PlayerClosed = closed,
			MarkDirty = function() end,
			GetLastSavedAt = function() return 100 end,
			ForceSave = function() forceSaves += 1; return { Ok = true, Revision = forceSaves } end,
			GetDirtyPlayers = function() return {} end,
		}
		autosave:RegisterController(controller, { IntervalSeconds = 60 })
		local player = { UserId = 12 } :: any
		local config = makeConfig()
		config.SaveRequestCooldownSeconds = 1
		local statistics = makeStatistics({ AutoSave = autosave, Config = config })
		scope:Defer(function() statistics:Destroy() end)
		loadStatistics(statistics, player)
		statistics:BindSaveController(controller)
		local closedIds = {}
		for index = 1, 2 do
			assertTrue(statistics:StartNewSnapshot(player, "Round", { RunId = `rapid-{index}` }).Ok)
			table.insert(closedIds, statistics:GetActiveSnapshot(player, "Round").SnapshotId)
			assertTrue(statistics:CloseSnapshot(player, "Round").Ok)
			assertEqual(statistics:SaveSnapshot(player, "Round", closedIds[index]).Code, "Queued")
		end
		assertEqual(#statistics:GetSnapshots(player, "Round"), 2)
		assertTrue(statistics:GetActiveSnapshot(player, "Global") ~= nil, "SaveSnapshot closed the snapshot")
		assertEqual(#scheduled, 1, "coalesced request created more than one worker")
		scheduled[1]()
		assertEqual(forceSaves, 1)

		local attempts = 0
		local throwing = {
			GetLastSavedAt = function() return 0 end,
			ForceSave = function()
				attempts += 1
				if attempts == 1 then error("injected") end
				return { Ok = true }
			end,
			GetDirtyPlayers = function() return {} end,
		}
		autosave:RegisterController(throwing, { IntervalSeconds = 60 })
		assertEqual(autosave:RequestSave(throwing, player, "Statistics", 0).Ok, false)
		assertTrue(autosave:RequestSave(throwing, player, "Statistics", 0).Ok, "thrown save stranded in-flight state")
	end)

	test("statistics_config exact schema accepts defaults and rejects unsafe budgets", function()
		local defaults = rawConfig()
		defaults.snapshotTypes.Global.filter = nil
		local valid, decoded = StatisticsConfigCodec.decode(defaults)
		assertTrue(valid, "production Statistics config rejected")
		assertEqual(decoded.SnapshotTypes.Session.Retention, 4)
		assertEqual(decoded.SnapshotTypes.Global.Filter.Mode, "AllowAllExcept")
		assertEqual(#decoded.SnapshotTypes.Global.Filter.StatisticIds, 0)

		local explicit = rawConfig()
		explicit.snapshotTypes.Global.filter = { mode = "AllowOnly", statisticIds = { "Allowed" } }
		explicit.snapshotTypes.Session.filter = { mode = "AllowAllExcept", statisticIds = { "Blocked" } }
		local explicitOk, explicitDecoded = StatisticsConfigCodec.decode(explicit)
		assertTrue(explicitOk, "explicit Statistics filters were rejected")
		assertEqual(explicitDecoded.SnapshotTypes.Global.Filter.Mode, "AllowOnly")
		assertEqual(explicitDecoded.SnapshotTypes.Global.Filter.StatisticIds[1], "Allowed")
		assertEqual(explicitDecoded.SnapshotTypes.Session.Filter.Mode, "AllowAllExcept")
		assertEqual(explicitDecoded.SnapshotTypes.Session.Filter.StatisticIds[1], "Blocked")
		local invalid = rawConfig()
		invalid.unknown = true
		assertEqual(StatisticsConfigCodec.decode(invalid), false)
		local oversized = rawConfig()
		oversized.limits.maxProviderEncodedBytes = 16_384
		assertEqual(StatisticsConfigCodec.decode(oversized), false)

		local shortMandatoryIdentifier = rawConfig()
		shortMandatoryIdentifier.limits.maxStatisticIdLength = 35
		assertEqual(StatisticsConfigCodec.decode(shortMandatoryIdentifier), false)
		local mandatoryBoundary = rawConfig()
		mandatoryBoundary.limits.maxStatisticIdLength = 36
		assertTrue(StatisticsConfigCodec.decode(mandatoryBoundary), "mandatory Wallet identifier boundary rejected")

		local impossibleDedupeCapacity = rawConfig()
		impossibleDedupeCapacity.limits.maxDedupSources = 32
		impossibleDedupeCapacity.limits.maxEventIdsPerSource = 512
		assertEqual(StatisticsConfigCodec.decode(impossibleDedupeCapacity), false)

		local disabledCoalescing = rawConfig()
		disabledCoalescing.saveRequestCooldownSeconds = 0
		assertEqual(StatisticsConfigCodec.decode(disabledCoalescing), false)
		local minimumCoalescing = rawConfig()
		minimumCoalescing.saveRequestCooldownSeconds = 1
		assertTrue(StatisticsConfigCodec.decode(minimumCoalescing), "safe minimum save cooldown was rejected")
	end)

	test("diagnostics are cooldown-bounded and contain no protected payload", function(scope)
		local statistics, _, setNow, entries = makeStatistics()
		scope:Defer(function() statistics:Destroy() end)
		local player = { UserId = 13 } :: any
		loadStatistics(statistics, player)
		local bad = { Operation = "Invalid", StatisticId = "X", Operand = 1 }
		statistics:ApplyOperation(player, bad)
		statistics:ApplyOperation(player, bad)
		assertEqual(#entries, 1)
		assertEqual(entries[1].Fields.UserId, 13)
		assertEqual(entries[1].Fields.SessionId, nil)
		assertEqual(entries[1].Fields.Metadata, nil)
		setNow(102)
		statistics:ApplyOperation(player, bad)
		assertEqual(#entries, 2)

		local persistence, _, _, persistenceEntries = makeStatistics({
			AutoSave = {
				RequestSave = function()
					return { Ok = false, Code = "InjectedPersistenceFailure" }
				end,
			},
		})
		scope:Defer(function() persistence:Destroy() end)
		local persistencePlayer = { UserId = 131 } :: any
		loadStatistics(persistence, persistencePlayer)
		persistence:BindSaveController({})
		persistence:SaveSnapshot(persistencePlayer, "Global")
		persistence:SaveSnapshot(persistencePlayer, "Global")
		assertEqual(#persistenceEntries, 1)
		assertEqual(persistenceEntries[1].Fields.Code, "PersistenceFailed")
		assertEqual(persistenceEntries[1].Fields.Snapshot, nil)
		assertEqual(persistenceEntries[1].Fields.SessionId, nil)
		assertEqual(persistenceEntries[1].Fields.Metadata, nil)
	end)

	return TestHarness.runAll("StatisticsTestRunner", tests, 8)
end

return StatisticsTestRunner
