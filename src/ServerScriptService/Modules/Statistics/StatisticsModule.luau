--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SaveSerialize = require(ReplicatedStorage.Shared.Save.SaveSerialize)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local TableUtil = require(ReplicatedStorage.Shared.Util.TableUtil)
local DeepFreeze = require(ReplicatedStorage.Shared.Util.DeepFreeze)
local Logger = require(ReplicatedStorage.Shared.Util.Logger)
local TeleportProtocol = require(ReplicatedStorage.Shared.Teleport.TeleportProtocol)
local StatisticsProtocol = require(ReplicatedStorage.Shared.Statistics.StatisticsProtocol)
local StatisticsValidation = require(script.Parent.StatisticsValidation)

local StatisticsModule = {}
StatisticsModule.__index = StatisticsModule

local CLOSE_CAPACITY_TIMESTAMP = -9_007_199_254_740_991
local CLOSE_CAPACITY_BYTES_PER_SNAPSHOT = 64

local PROVIDER_FIELDS = table.freeze({
	ActiveByType = true,
	PendingSession = true,
	HistoryByType = true,
	NextSnapshotIdByType = true,
	Dedup = true,
})
local SNAPSHOT_FIELDS = table.freeze({
	SnapshotId = true,
	SnapshotType = true,
	State = true,
	StartedAt = true,
	ClosedAt = true,
	PlaceId = true,
	SessionId = true,
	Metadata = true,
	Filter = true,
	Values = true,
})
local FILTER_FIELDS = table.freeze({ Mode = true, StatisticIds = true })
local DEDUP_FIELDS = table.freeze({ OrderedSources = true, EventIdsBySource = true })
local CURSOR_FIELDS = table.freeze({ LastSequence = true, LastEventId = true })
local OPERATION_FIELDS = table.freeze({
	Operation = true,
	StatisticId = true,
	Operand = true,
	FactIdentity = true,
})
local FACT_FIELDS = table.freeze({ Mode = true, SourceId = true, Sequence = true, EventId = true })
local OPERATIONS = table.freeze({ Set = true, Inc = true, Dec = true, Min = true, Max = true })

local function failure(code: string, message: string)
	return { Ok = false, Code = code, Error = message }
end

local function copyFrozen(value: any): any
	return DeepFreeze(TableUtil.deepCopy(value))
end

local function createEmptyMemento()
	return {
		ActiveByType = {},
		HistoryByType = {},
		NextSnapshotIdByType = {},
		Dedup = {
			OrderedSources = {},
			EventIdsBySource = {},
		},
	}
end

local function isDenseArray(value: any): (boolean, number)
	if typeof(value) ~= "table" or getmetatable(value) ~= nil then
		return false, 0
	end
	local count = 0
	local maximum = 0
	for key in value do
		if typeof(key) ~= "number" or key < 1 or key ~= math.floor(key) then
			return false, 0
		end
		count += 1
		maximum = math.max(maximum, key)
	end
	return count == maximum, count
end

local function contains(list: { string }, value: string): boolean
	for _, entry in list do
		if entry == value then
			return true
		end
	end
	return false
end

local function insertSnapshotInCreationOrder(snapshots: { any }, snapshot: any)
	local insertIndex = #snapshots + 1
	for index, existing in snapshots do
		if snapshot.SnapshotId < existing.SnapshotId then
			insertIndex = index
			break
		end
	end
	table.insert(snapshots, insertIndex, snapshot)
end

function StatisticsModule.new(deps: {
	Config: any,
	Teleport: any,
	AutoSave: any,
	PlaceId: number,
	Clock: (() -> number)?,
	MeasureEncodedSize: ((any) -> (boolean, number?, string?))?,
	Logger: any?,
})
	return setmetatable({
		Id = "Statistics",
		Version = 1,
		Authority = "Server",
		ClientSnapshotPolicy = "Omit",
		_configCatalog = deps.Config,
		_teleport = deps.Teleport,
		_autoSave = deps.AutoSave,
		_placeId = deps.PlaceId,
		_clock = deps.Clock or os.time,
		_measureEncodedSize = deps.MeasureEncodedSize or SaveSerialize.measureEncodedSize,
		_logger = deps.Logger or Logger.new("Statistics", "info"),
		_config = nil,
		_data = {} :: { [Player]: any },
		_running = {} :: { [Player]: boolean },
		_resumeOnRun = {} :: { [Player]: boolean },
		_closing = {} :: { [Player]: boolean },
		_closeResults = {} :: { [Player]: any },
		_diagnosticAt = {} :: { [Player]: { [string]: number } },
		_saveController = nil,
		_initialized = false,
		_destroyed = false,
		MementoChanged = Signal.new(),
		Changed = Signal.new(),
		ActiveSnapshotsChanged = Signal.new(),
	}, StatisticsModule)
end

function StatisticsModule:Initialize()
	if self._initialized then
		return
	end
	self._config = self._configCatalog:GetRequired("Statistics")
	self._initialized = true
end

function StatisticsModule:BindSaveController(controller: any)
	assert(self._saveController == nil or self._saveController == controller, "Statistics save controller already bound")
	self._saveController = controller
end

function StatisticsModule:_diagnose(player: Player, code: string, severity: string?)
	local now = self._clock()
	local playerState = self._diagnosticAt[player]
	if playerState == nil then
		playerState = {}
		self._diagnosticAt[player] = playerState
	end
	local previous = playerState[code]
	if previous ~= nil and now - previous < 1 then
		return
	end
	playerState[code] = now
	local fields = { UserId = player.UserId, Code = code }
	if severity == "error" then
		self._logger:Error("statistics_rejected", fields)
	else
		self._logger:Warn("statistics_rejected", fields)
	end
end

function StatisticsModule:_markDirty(player: Player)
	if self._saveController ~= nil then
		self._saveController:MarkDirty(player, self.Id)
	end
	self.MementoChanged:Fire(player)
end

function StatisticsModule:_measure(value: any, maximum: number, label: string): (boolean, string?, number?)
	local safe, issues = SaveSerialize.validate(value)
	if not safe then
		return false, `{label} is not DataStore-safe: {if issues[1] then issues[1].Reason else "unknown"}`, nil
	end
	local measured, bytes, measureError = self._measureEncodedSize(value)
	if not measured or bytes == nil then
		return false, `{label} could not be measured: {measureError or "unknown"}`, nil
	end
	if bytes > maximum then
		return false, `{label} encoded byte limit exceeded`, bytes
	end
	return true, nil, bytes
end

function StatisticsModule:_validateFilter(value: any): (boolean, any?, string?)
	local limits = self._config.Limits
	if not StatisticsValidation.HasOnlyFields(value, FILTER_FIELDS)
		or (value.Mode ~= "AllowOnly" and value.Mode ~= "AllowAllExcept")
	then
		return false, nil, "Invalid snapshot filter"
	end
	local ok, ids, listError = StatisticsValidation.ValidateStringArray(
		value.StatisticIds,
		limits.MaxStatisticIdsPerSnapshot,
		limits.MaxStatisticIdLength
	)
	if not ok then
		return false, nil, `Invalid snapshot filter: {listError}`
	end
	table.sort(ids :: { string })
	return true, { Mode = value.Mode, StatisticIds = ids }, nil
end

function StatisticsModule:_validateSnapshot(
	value: any,
	expectedType: string,
	expectedState: string
): (boolean, any?, string?)
	local limits = self._config.Limits
	if not StatisticsValidation.HasOnlyFields(value, SNAPSHOT_FIELDS)
		or value.SnapshotType ~= expectedType
		or value.State ~= expectedState
		or not StatisticsValidation.IsSafeInteger(value.SnapshotId, false)
		or not StatisticsValidation.IsFinite(value.StartedAt)
	then
		return false, nil, `Invalid {expectedType} snapshot schema`
	end
	if expectedState == "Active" then
		if value.ClosedAt ~= nil then
			return false, nil, "Active snapshot cannot have ClosedAt"
		end
	elseif not StatisticsValidation.IsFinite(value.ClosedAt) then
		return false, nil, "Closed snapshot requires ClosedAt"
	end
	if expectedType == "Place" then
		if not StatisticsValidation.IsSafeInteger(value.PlaceId, true) then
			return false, nil, "Place snapshot requires a valid PlaceId"
		end
	elseif value.PlaceId ~= nil then
		return false, nil, "PlaceId is allowed only on Place snapshots"
	end
	if expectedType == "Session" then
		if not TeleportProtocol.IsCanonicalGuid(value.SessionId) then
			return false, nil, "Session snapshot requires a canonical SessionId"
		end
	elseif value.SessionId ~= nil then
		return false, nil, "SessionId is allowed only on Session snapshots"
	end

	local metadataOk, metadata, metadataError = StatisticsValidation.ValidateMetadata(value.Metadata, limits)
	if not metadataOk then
		return false, nil, metadataError
	end
	local filterOk, filter, filterError = self:_validateFilter(value.Filter)
	if not filterOk then
		return false, nil, filterError
	end
	if typeof(value.Values) ~= "table" or getmetatable(value.Values) ~= nil then
		return false, nil, "Snapshot Values must be a plain dictionary"
	end
	local values: { [string]: number } = {}
	local valueCount = 0
	for statisticId, statisticValue in value.Values do
		if not StatisticsValidation.IsIdentifier(statisticId, limits.MaxStatisticIdLength)
			or not StatisticsValidation.IsFinite(statisticValue)
			or statisticValue < 0
		then
			return false, nil, "Snapshot contains an invalid statistic value"
		end
		valueCount += 1
		if valueCount > limits.MaxStatisticIdsPerSnapshot then
			return false, nil, "Snapshot statistic limit exceeded"
		end
		values[statisticId] = statisticValue
	end

	local result = {
		SnapshotId = value.SnapshotId,
		SnapshotType = expectedType,
		State = expectedState,
		StartedAt = value.StartedAt,
		ClosedAt = value.ClosedAt,
		PlaceId = value.PlaceId,
		SessionId = value.SessionId,
		Metadata = metadata,
		Filter = filter,
		Values = values,
	}
	local sizeOk, sizeError = self:_measure(result, limits.MaxSnapshotEncodedBytes, "Snapshot")
	if not sizeOk then
		return false, nil, sizeError
	end
	if expectedState == "Active" and expectedType ~= "Global" then
		local closedCandidate = TableUtil.deepCopy(result)
		closedCandidate.State = "Closed"
		closedCandidate.ClosedAt = CLOSE_CAPACITY_TIMESTAMP
		local closeSizeOk, closeSizeError = self:_measure(
			closedCandidate,
			limits.MaxSnapshotEncodedBytes,
			"Closed snapshot"
		)
		if not closeSizeOk then
			return false, nil, closeSizeError
		end
	end
	return true, result, nil
end

function StatisticsModule:_validateMemento(value: any): (boolean, any?, string?)
	if not StatisticsValidation.HasOnlyFields(value, PROVIDER_FIELDS)
		or typeof(value.ActiveByType) ~= "table"
		or typeof(value.HistoryByType) ~= "table"
		or typeof(value.NextSnapshotIdByType) ~= "table"
		or not StatisticsValidation.HasOnlyFields(value.Dedup, DEDUP_FIELDS)
		or typeof(value.Dedup.OrderedSources) ~= "table"
		or typeof(value.Dedup.EventIdsBySource) ~= "table"
	then
		return false, nil, "Statistics memento has an invalid root"
	end
	local limits = self._config.Limits
	local result = createEmptyMemento()
	local maximumIdByType: { [string]: number } = {}
	local seenIdsByType: { [string]: { [number]: boolean } } = {}
	local function registerSnapshotId(snapshotType: string, snapshotId: number): boolean
		local seen = seenIdsByType[snapshotType]
		if seen == nil then
			seen = {}
			seenIdsByType[snapshotType] = seen
		end
		if seen[snapshotId] then return false end
		seen[snapshotId] = true
		return true
	end
	if value.PendingSession ~= nil and value.ActiveByType.Session ~= nil then
		return false, nil, "Active Session cannot coexist with PendingSession"
	end

	for snapshotType, snapshot in value.ActiveByType do
		if self._config.SnapshotTypes[snapshotType] == nil then
			return false, nil, `Unknown active snapshot type '{tostring(snapshotType)}'`
		end
		local ok, sanitized, snapshotError = self:_validateSnapshot(snapshot, snapshotType, "Active")
		if not ok then return false, nil, snapshotError end
		if not registerSnapshotId(snapshotType, sanitized.SnapshotId) then
			return false, nil, `Duplicate snapshot ID for '{snapshotType}'`
		end
		result.ActiveByType[snapshotType] = sanitized
		maximumIdByType[snapshotType] = sanitized.SnapshotId
	end

	if value.PendingSession ~= nil then
		local ok, sanitized, snapshotError = self:_validateSnapshot(value.PendingSession, "Session", "Closed")
		if not ok then return false, nil, snapshotError end
		if not registerSnapshotId("Session", sanitized.SnapshotId) then
			return false, nil, "Duplicate snapshot ID for 'Session'"
		end
		result.PendingSession = sanitized
		maximumIdByType.Session = math.max(maximumIdByType.Session or 0, sanitized.SnapshotId)
	end

	for snapshotType, history in value.HistoryByType do
		local definition = self._config.SnapshotTypes[snapshotType]
		if definition == nil then
			return false, nil, `Unknown history snapshot type '{tostring(snapshotType)}'`
		end
		local dense, count = isDenseArray(history)
		if not dense or count > definition.Retention then
			return false, nil, `Invalid or oversized '{snapshotType}' history`
		end
		local sanitizedHistory = {}
		local previousId = 0
		for index = 1, count do
			local ok, sanitized, snapshotError = self:_validateSnapshot(history[index], snapshotType, "Closed")
			if not ok
				or sanitized.SnapshotId <= previousId
				or not registerSnapshotId(snapshotType, sanitized.SnapshotId)
			then
				return false, nil, snapshotError or "Snapshot history is not creation ordered"
			end
			previousId = sanitized.SnapshotId
			maximumIdByType[snapshotType] = math.max(maximumIdByType[snapshotType] or 0, sanitized.SnapshotId)
			table.insert(sanitizedHistory, sanitized)
		end
		result.HistoryByType[snapshotType] = sanitizedHistory
	end

	for snapshotType in value.NextSnapshotIdByType do
		if self._config.SnapshotTypes[snapshotType] == nil then
			return false, nil, `Unknown snapshot counter type '{tostring(snapshotType)}'`
		end
	end
	for snapshotType in self._config.SnapshotTypes do
		local nextId = value.NextSnapshotIdByType[snapshotType]
		if nextId == nil then
			nextId = (maximumIdByType[snapshotType] or 0) + 1
		end
		if not StatisticsValidation.IsSafeInteger(nextId, false)
			or nextId <= (maximumIdByType[snapshotType] or 0)
		then
			return false, nil, `Invalid next snapshot ID for '{snapshotType}'`
		end
		result.NextSnapshotIdByType[snapshotType] = nextId
	end

	local sourceCount = 0
	for sourceId, cursor in value.Dedup.OrderedSources do
		if not StatisticsValidation.IsIdentifier(sourceId, limits.MaxStatisticIdLength)
			or not StatisticsValidation.HasOnlyFields(cursor, CURSOR_FIELDS)
			or not StatisticsValidation.IsSafeInteger(cursor.LastSequence, false)
			or (cursor.LastEventId ~= nil
				and not StatisticsValidation.IsIdentifier(cursor.LastEventId, limits.MaxStatisticIdLength))
		then
			return false, nil, "Invalid ordered dedupe cursor"
		end
		sourceCount += 1
		result.Dedup.OrderedSources[sourceId] = {
			LastSequence = cursor.LastSequence,
			LastEventId = cursor.LastEventId,
		}
	end
	for sourceId, eventIds in value.Dedup.EventIdsBySource do
		if result.Dedup.OrderedSources[sourceId] ~= nil
			or not StatisticsValidation.IsIdentifier(sourceId, limits.MaxStatisticIdLength)
		then
			return false, nil, "Dedupe source changes mode"
		end
		sourceCount += 1
		local listOk, sanitizedIds, listError = StatisticsValidation.ValidateStringArray(
			eventIds,
			limits.MaxEventIdsPerSource,
			limits.MaxStatisticIdLength
		)
		if not listOk then
			return false, nil, `Invalid event dedupe ledger: {listError}`
		end
		result.Dedup.EventIdsBySource[sourceId] = sanitizedIds
	end
	if sourceCount > limits.MaxDedupSources then
		return false, nil, "Dedupe source limit exceeded"
	end

	local sizeOk, sizeError, encodedBytes = self:_measure(
		result,
		limits.MaxProviderEncodedBytes,
		"Statistics provider"
	)
	if not sizeOk then
		return false, nil, sizeError
	end
	local closableSnapshotCount = 0
	for snapshotType in result.ActiveByType do
		if snapshotType ~= "Global" then closableSnapshotCount += 1 end
	end
	if (encodedBytes :: number) + closableSnapshotCount * CLOSE_CAPACITY_BYTES_PER_SNAPSHOT
		> limits.MaxProviderEncodedBytes
	then
		return false, nil, "Statistics provider does not reserve profile-close capacity"
	end
	return true, result, nil
end

function StatisticsModule:CreateDefault(_player: Player)
	assert(self._initialized, "StatisticsModule is not initialized")
	return createEmptyMemento()
end

function StatisticsModule:_canTrimHistory(value: any, snapshotType: string, history: any, count: number): boolean
	if not StatisticsValidation.HasOnlyFields(value, PROVIDER_FIELDS)
		or typeof(value.ActiveByType) ~= "table"
		or getmetatable(value.ActiveByType) ~= nil
		or typeof(value.NextSnapshotIdByType) ~= "table"
		or getmetatable(value.NextSnapshotIdByType) ~= nil
	then
		return false
	end

	local seenIds = {}
	local function reserveSnapshotId(snapshotId: number): boolean
		if seenIds[snapshotId] then
			return false
		end
		seenIds[snapshotId] = true
		return true
	end
	local function validateAndReserve(snapshot: any, state: string): boolean
		if snapshot == nil then
			return true
		end
		local valid, sanitized = self:_validateSnapshot(snapshot, snapshotType, state)
		return valid and reserveSnapshotId(sanitized.SnapshotId)
	end

	local activeSnapshot = value.ActiveByType[snapshotType]
	local pendingSnapshot = if snapshotType == "Session" then value.PendingSession else nil
	if activeSnapshot ~= nil and pendingSnapshot ~= nil then
		return false
	end
	if not validateAndReserve(activeSnapshot, "Active") then
		return false
	end
	if not validateAndReserve(pendingSnapshot, "Closed") then
		return false
	end
	local previousHistoryId = 0
	for index = 1, count do
		local valid, sanitized = self:_validateSnapshot(history[index], snapshotType, "Closed")
		if not valid
			or sanitized.SnapshotId <= previousHistoryId
			or not reserveSnapshotId(sanitized.SnapshotId)
		then
			return false
		end
		previousHistoryId = sanitized.SnapshotId
	end
	local nextId = value.NextSnapshotIdByType[snapshotType]
	if not StatisticsValidation.IsSafeInteger(nextId, false) then
		return false
	end
	for snapshotId in seenIds do
		if snapshotId >= nextId then
			return false
		end
	end
	return true
end

function StatisticsModule:ReconcileMemento(player: Player, value: any, _fromVersion: number)
	-- Retention is the only policy that may intentionally remove persisted
	-- snapshots without a raw migration. Reconcile an older valid generation
	-- on an isolated copy, but leave malformed shapes untouched so validation
	-- still fails closed instead of normalizing corruption.
	if typeof(value) ~= "table" or typeof(value.HistoryByType) ~= "table" then
		return value
	end
	local trimCounts = {}
	for snapshotType, definition in self._config.SnapshotTypes do
		local history = value.HistoryByType[snapshotType]
		if history == nil then
			continue
		end
		local dense, count = isDenseArray(history)
		if not dense or count <= definition.Retention then
			continue
		end
		if not self:_canTrimHistory(value, snapshotType, history, count) then
			return value
		end
		trimCounts[snapshotType] = count
	end
	local reconciled = TableUtil.deepCopy(value)
	for snapshotType, count in trimCounts do
		local definition = self._config.SnapshotTypes[snapshotType]
		local history = reconciled.HistoryByType[snapshotType]
		local retained = {}
		local firstRetained = count - definition.Retention + 1
		for index = firstRetained, count do
			table.insert(retained, history[index])
		end
		reconciled.HistoryByType[snapshotType] = retained
		self:_diagnose(player, "RetentionEvicted")
	end
	return reconciled
end

function StatisticsModule:ValidateMemento(_player: Player, value: any): (boolean, any?, string?)
	assert(self._initialized, "StatisticsModule is not initialized")
	return self:_validateMemento(value)
end

function StatisticsModule:SetMemento(player: Player, value: any)
	self._data[player] = TableUtil.deepCopy(value)
	self._closing[player] = nil
	self._closeResults[player] = nil
end

function StatisticsModule:GetMemento(player: Player)
	return TableUtil.deepCopy(assert(self._data[player], "Statistics memento is not set"))
end

function StatisticsModule:BeforeMementoGet(_player: Player)
end

function StatisticsModule:_appendHistory(memento: any, snapshot: any, player: Player?)
	local snapshotType = snapshot.SnapshotType
	local retention = self._config.SnapshotTypes[snapshotType].Retention
	local history = memento.HistoryByType[snapshotType]
	if history == nil then
		history = {}
		memento.HistoryByType[snapshotType] = history
	end
	if retention > 0 then
		insertSnapshotInCreationOrder(history, snapshot)
		local evicted = false
		while #history > retention do
			table.remove(history, 1)
			evicted = true
		end
		if evicted and player ~= nil then self:_diagnose(player, "RetentionEvicted") end
	else
		table.clear(history)
		if player ~= nil then self:_diagnose(player, "RetentionEvicted") end
	end
end

function StatisticsModule:_closeActive(
	memento: any,
	snapshotType: string,
	pendingSession: boolean?,
	player: Player?
): boolean
	local snapshot = memento.ActiveByType[snapshotType]
	if snapshot == nil then
		return false
	end
	memento.ActiveByType[snapshotType] = nil
	snapshot.State = "Closed"
	snapshot.ClosedAt = self._clock()
	if pendingSession then
		memento.PendingSession = snapshot
	else
		self:_appendHistory(memento, snapshot, player)
	end
	return true
end

function StatisticsModule:_newSnapshot(memento: any, snapshotType: string, metadata: any?, sessionId: string?): any
	local nextId = memento.NextSnapshotIdByType[snapshotType] or 1
	if not StatisticsValidation.IsSafeInteger(nextId, false) then
		return nil, "SnapshotIdExhausted"
	end
	if nextId >= 9_007_199_254_740_991 then
		return nil, "SnapshotIdExhausted"
	end
	local metadataOk, sanitizedMetadata, metadataError = StatisticsValidation.ValidateMetadata(
		metadata,
		self._config.Limits
	)
	if not metadataOk then
		return nil, metadataError
	end
	local snapshot = {
		SnapshotId = nextId,
		SnapshotType = snapshotType,
		State = "Active",
		StartedAt = self._clock(),
		PlaceId = if snapshotType == "Place" then self._placeId else nil,
		SessionId = if snapshotType == "Session" then sessionId else nil,
		Metadata = sanitizedMetadata,
		Filter = TableUtil.deepCopy(self._config.SnapshotTypes[snapshotType].Filter),
		Values = {},
	}
	memento.NextSnapshotIdByType[snapshotType] = nextId + 1
	memento.ActiveByType[snapshotType] = snapshot
	return snapshot, nil
end

function StatisticsModule:_isLifecycleReady(memento: any, session: any): boolean
	local active = memento.ActiveByType
	local global = active.Global
	local sessionSnapshot = active.Session
	local place = active.Place
	return memento.PendingSession == nil
		and global ~= nil
		and sessionSnapshot ~= nil
		and place ~= nil
		and sessionSnapshot.SessionId == session.SessionId
		and place.PlaceId == self._placeId
end

function StatisticsModule:Run(player: Player)
	local current = assert(self._data[player], "Statistics memento is not set")
	local session = self._teleport:GetSession(player)
	assert(session ~= nil, "Teleport session is unavailable for Statistics startup")
	local resumeInstalled = self._resumeOnRun[player] == true
	self._resumeOnRun[player] = nil
	if resumeInstalled and self:_isLifecycleReady(current, session) then
		-- Snapshot application and rollback restart providers after installing an
		-- already active memento. Preserve that exact runtime instead of treating
		-- the restart as a new player visit.
		self._running[player] = true
		return
	end
	local candidate = TableUtil.deepCopy(current)
	local changed = false

	if candidate.ActiveByType.Global == nil then
		local snapshot, createError = self:_newSnapshot(candidate, "Global", nil, nil)
		assert(snapshot ~= nil, createError)
		changed = true
	end

	if candidate.ActiveByType.Session ~= nil then
		self:_closeActive(candidate, "Session", false, player)
		changed = true
	end
	local pending = candidate.PendingSession
	candidate.PendingSession = nil
	if pending ~= nil and session.EntryKind == "Teleported" and pending.SessionId == session.SessionId then
		pending.State = "Active"
		pending.ClosedAt = nil
		candidate.ActiveByType.Session = pending
		changed = true
	else
		if pending ~= nil then
			self:_diagnose(player, "SessionHandoffMismatch")
			self:_appendHistory(candidate, pending, player)
			changed = true
		end
		local snapshot, createError = self:_newSnapshot(candidate, "Session", nil, session.SessionId)
		assert(snapshot ~= nil, createError)
		changed = true
	end

	if candidate.ActiveByType.Place ~= nil then
		self:_closeActive(candidate, "Place", false, player)
	end
	local placeSnapshot, placeError = self:_newSnapshot(candidate, "Place", nil, nil)
	assert(placeSnapshot ~= nil, placeError)
	changed = true

	local valid, sanitized, validationError = self:_validateMemento(candidate)
	assert(valid, validationError)
	self._data[player] = sanitized
	self._running[player] = true
	if changed then
		self:_markDirty(player)
		self.ActiveSnapshotsChanged:Fire(player, copyFrozen({ "Global", "Session", "Place" }))
	end
end

function StatisticsModule:Stop(player: Player, forSnapshotApply: boolean?)
	self._resumeOnRun[player] = if forSnapshotApply then true else nil
	self._running[player] = nil
	self._closing[player] = nil
	self._closeResults[player] = nil
	self._diagnosticAt[player] = nil
	self._data[player] = nil
end

function StatisticsModule:_requireRuntime(player: Player): (any?, any?)
	if not self._running[player] or self._data[player] == nil then
		return nil, failure("NotLoaded", "Statistics is not loaded")
	end
	if self._closing[player] then
		return nil, failure("Closing", "Statistics is closing")
	end
	return self._data[player], nil
end

function StatisticsModule:_isManaged(snapshotType: string): boolean
	return StatisticsProtocol.BuiltInSnapshotTypes[snapshotType] == true
end

function StatisticsModule:StartNewSnapshot(player: Player, snapshotType: string, metadata: any?)
	local current, runtimeError = self:_requireRuntime(player)
	if current == nil then return runtimeError end
	if typeof(snapshotType) ~= "string" or self._config.SnapshotTypes[snapshotType] == nil then
		return failure("UnknownSnapshotType", "Snapshot type is not configured")
	end
	if self:_isManaged(snapshotType) then
		return failure("ManagedSnapshotType", "Built-in snapshot lifecycle is managed")
	end
	if current.ActiveByType[snapshotType] ~= nil then
		return failure("AlreadyActive", "Snapshot type is already active")
	end
	local candidate = TableUtil.deepCopy(current)
	local snapshot, createError = self:_newSnapshot(candidate, snapshotType, metadata, nil)
	if snapshot == nil then
		return failure(createError or "InvalidMetadata", createError or "Snapshot creation failed")
	end
	local valid, sanitized, validationError = self:_validateMemento(candidate)
	if not valid then
		self:_diagnose(player, "SnapshotStartRejected")
		return failure("InvalidSnapshot", validationError or "Snapshot is invalid")
	end
	self._data[player] = sanitized
	self:_markDirty(player)
	self.ActiveSnapshotsChanged:Fire(player, copyFrozen({ snapshotType }))
	return { Ok = true, Code = "Started", Snapshot = copyFrozen(snapshot) }
end

function StatisticsModule:ContinueSnapshot(player: Player, snapshotType: string, snapshotId: number)
	local current, runtimeError = self:_requireRuntime(player)
	if current == nil then return runtimeError end
	if self._config.SnapshotTypes[snapshotType] == nil then
		return failure("UnknownSnapshotType", "Snapshot type is not configured")
	end
	if self:_isManaged(snapshotType) then
		return failure("ManagedSnapshotType", "Built-in snapshot lifecycle is managed")
	end
	if current.ActiveByType[snapshotType] ~= nil then
		return failure("AlreadyActive", "Snapshot type is already active")
	end
	if not StatisticsValidation.IsSafeInteger(snapshotId, false) then
		return failure("InvalidSnapshotId", "Snapshot ID is invalid")
	end
	local candidate = TableUtil.deepCopy(current)
	local history = candidate.HistoryByType[snapshotType] or {}
	local restored = nil
	for index, snapshot in history do
		if snapshot.SnapshotId == snapshotId then
			restored = table.remove(history, index)
			break
		end
	end
	if restored == nil then
		return failure("NotFound", "Snapshot was not retained")
	end
	restored.State = "Active"
	restored.ClosedAt = nil
	candidate.ActiveByType[snapshotType] = restored
	local valid, sanitized, validationError = self:_validateMemento(candidate)
	if not valid then return failure("InvalidSnapshot", validationError or "Snapshot is invalid") end
	self._data[player] = sanitized
	self:_markDirty(player)
	self.ActiveSnapshotsChanged:Fire(player, copyFrozen({ snapshotType }))
	return { Ok = true, Code = "Continued", Snapshot = copyFrozen(restored) }
end

function StatisticsModule:CloseSnapshot(player: Player, snapshotType: string)
	local current, runtimeError = self:_requireRuntime(player)
	if current == nil then return runtimeError end
	if self._config.SnapshotTypes[snapshotType] == nil then
		return failure("UnknownSnapshotType", "Snapshot type is not configured")
	end
	if self:_isManaged(snapshotType) then
		return failure("ManagedSnapshotType", "Built-in snapshot lifecycle is managed")
	end
	if current.ActiveByType[snapshotType] == nil then
		return failure("NotActive", "Snapshot type is not active")
	end
	local candidate = TableUtil.deepCopy(current)
	self:_closeActive(candidate, snapshotType, false, player)
	local valid, sanitized, validationError = self:_validateMemento(candidate)
	if not valid then return failure("InvalidSnapshot", validationError or "Snapshot is invalid") end
	self._data[player] = sanitized
	self:_markDirty(player)
	self.ActiveSnapshotsChanged:Fire(player, copyFrozen({ snapshotType }))
	return { Ok = true, Code = "Closed" }
end

function StatisticsModule:PrepareForProfileClose(player: Player)
	local prior = self._closeResults[player]
	if prior ~= nil then
		return TableUtil.deepCopy(prior)
	end
	if not self._running[player] or self._data[player] == nil then
		return failure("NotLoaded", "Statistics is not loaded")
	end
	self._closing[player] = true
	local candidate = TableUtil.deepCopy(self._data[player])
	self:_closeActive(candidate, "Place", false, player)
	self:_closeActive(candidate, "Session", true, player)
	local valid, sanitized, validationError = self:_validateMemento(candidate)
	if not valid then
		local result = failure("ClosePreparationFailed", validationError or "Close preparation failed")
		-- A failed candidate never mutates provider data and remains retryable by
		-- the controller-owned terminal cleanup path. Keep gameplay fail-closed
		-- through _closing, but do not memoize a transient failure forever.
		self._closeResults[player] = nil
		self:_diagnose(player, "ClosePreparationFailed", "error")
		return TableUtil.deepCopy(result)
	end
	self._data[player] = sanitized
	self:_markDirty(player)
	self.ActiveSnapshotsChanged:Fire(player, copyFrozen({ "Session", "Place" }))
	local result = { Ok = true, Code = "Prepared" }
	self._closeResults[player] = result
	return TableUtil.deepCopy(result)
end

function StatisticsModule:_snapshotPermits(snapshot: any, statisticId: string): boolean
	local listed = contains(snapshot.Filter.StatisticIds, statisticId)
	return if snapshot.Filter.Mode == "AllowOnly" then listed else not listed
end

function StatisticsModule:_validateFactIdentity(memento: any, identity: any): (string, any?, any?)
	if identity == nil then return "Accept", nil, nil end
	local limits = self._config.Limits
	if not StatisticsValidation.HasOnlyFields(identity, FACT_FIELDS)
		or not StatisticsValidation.IsIdentifier(identity.SourceId, limits.MaxStatisticIdLength)
	then
		return "Reject", nil, failure("InvalidFactIdentity", "Fact identity is invalid")
	end
	local ordered = memento.Dedup.OrderedSources[identity.SourceId]
	local events = memento.Dedup.EventIdsBySource[identity.SourceId]
	if identity.Mode == "Ordered" then
		if events ~= nil
			or not StatisticsValidation.IsSafeInteger(identity.Sequence, false)
			or (identity.EventId ~= nil
				and not StatisticsValidation.IsIdentifier(identity.EventId, limits.MaxStatisticIdLength))
		then
			return "Reject", nil, failure("InvalidFactIdentity", "Ordered identity is invalid")
		end
		if ordered ~= nil and identity.Sequence <= ordered.LastSequence then
			return "Duplicate", nil, nil
		end
		return "Accept", {
			Mode = "Ordered",
			SourceId = identity.SourceId,
			LastSequence = identity.Sequence,
			LastEventId = identity.EventId,
		}, nil
	elseif identity.Mode == "EventId" then
		if ordered ~= nil
			or identity.Sequence ~= nil
			or not StatisticsValidation.IsIdentifier(identity.EventId, limits.MaxStatisticIdLength)
		then
			return "Reject", nil, failure("InvalidFactIdentity", "Event identity is invalid")
		end
		if events ~= nil and contains(events, identity.EventId) then
			return "Duplicate", nil, nil
		end
		if events ~= nil and #events >= limits.MaxEventIdsPerSource then
			return "Reject", nil, failure("DedupeLimitExceeded", "Event dedupe ledger is full")
		end
		return "Accept", {
			Mode = "EventId",
			SourceId = identity.SourceId,
			EventId = identity.EventId,
		}, nil
	end
	return "Reject", nil, failure("InvalidFactIdentity", "Fact identity mode is invalid")
end

function StatisticsModule:ApplyOperation(player: Player, operation: any)
	local current, runtimeError = self:_requireRuntime(player)
	if current == nil then return runtimeError end
	local limits = self._config.Limits
	if not StatisticsValidation.HasOnlyFields(operation, OPERATION_FIELDS)
		or OPERATIONS[operation.Operation] ~= true
		or not StatisticsValidation.IsIdentifier(operation.StatisticId, limits.MaxStatisticIdLength)
		or not StatisticsValidation.IsFinite(operation.Operand)
	then
		self:_diagnose(player, "InvalidOperation")
		return failure("InvalidOperation", "Statistic operation is invalid")
	end
	local dedupState, dedupCommit, dedupError = self:_validateFactIdentity(current, operation.FactIdentity)
	if dedupState == "Duplicate" then
		self:_diagnose(player, "Duplicate")
		return { Ok = true, Code = "Duplicate", ChangedSnapshotIds = {} }
	elseif dedupState == "Reject" then
		self:_diagnose(player, dedupError.Code)
		return dedupError
	end

	local operand = math.max(0, operation.Operand)
	local candidate = TableUtil.deepCopy(current)
	local changedIds = {}
	for _, snapshot in candidate.ActiveByType do
		if not self:_snapshotPermits(snapshot, operation.StatisticId) then
			continue
		end
		local oldValue = snapshot.Values[operation.StatisticId] or 0
		local newValue
		if operation.Operation == "Set" then newValue = operand
		elseif operation.Operation == "Inc" then newValue = oldValue + operand
		elseif operation.Operation == "Dec" then newValue = math.max(0, oldValue - operand)
		elseif operation.Operation == "Min" then newValue = math.min(oldValue, operand)
		else newValue = math.max(oldValue, operand) end
		if not StatisticsValidation.IsFinite(newValue) then
			self:_diagnose(player, "ResultOverflow")
			return failure("ResultOverflow", "Statistic result is not finite")
		end
		if newValue ~= oldValue then
			if snapshot.Values[operation.StatisticId] == nil then
				local count = 0
				for _ in snapshot.Values do count += 1 end
				if count >= limits.MaxStatisticIdsPerSnapshot then
					self:_diagnose(player, "StatisticLimitExceeded")
					return failure("StatisticLimitExceeded", "Snapshot statistic limit exceeded")
				end
			end
			snapshot.Values[operation.StatisticId] = newValue
			table.insert(changedIds, snapshot.SnapshotId)
		end
	end
	if #changedIds == 0 then
		return { Ok = true, Code = "NoChange", ChangedSnapshotIds = {} }
	end
	if dedupCommit ~= nil then
		local sourceExists = candidate.Dedup.OrderedSources[dedupCommit.SourceId] ~= nil
			or candidate.Dedup.EventIdsBySource[dedupCommit.SourceId] ~= nil
		if not sourceExists then
			local sourceCount = 0
			for _ in candidate.Dedup.OrderedSources do sourceCount += 1 end
			for _ in candidate.Dedup.EventIdsBySource do sourceCount += 1 end
			if sourceCount >= limits.MaxDedupSources then
				self:_diagnose(player, "DedupeLimitExceeded")
				return failure("DedupeLimitExceeded", "Dedupe source limit exceeded")
			end
		end
		if dedupCommit.Mode == "Ordered" then
			candidate.Dedup.OrderedSources[dedupCommit.SourceId] = {
				LastSequence = dedupCommit.LastSequence,
				LastEventId = dedupCommit.LastEventId,
			}
		else
			local ledger = candidate.Dedup.EventIdsBySource[dedupCommit.SourceId] or {}
			table.insert(ledger, dedupCommit.EventId)
			candidate.Dedup.EventIdsBySource[dedupCommit.SourceId] = ledger
		end
	end
	local valid, sanitized, validationError = self:_validateMemento(candidate)
	if not valid then
		self:_diagnose(player, "CandidateRejected")
		return failure("CandidateRejected", validationError or "Statistics candidate is invalid")
	end
	self._data[player] = sanitized
	self:_markDirty(player)
	local change = copyFrozen({
		Operation = operation.Operation,
		StatisticId = operation.StatisticId,
		Operand = operand,
		ChangedSnapshotIds = changedIds,
	})
	self.Changed:Fire(player, change)
	return { Ok = true, Code = "Applied", ChangedSnapshotIds = TableUtil.deepCopy(changedIds) }
end

function StatisticsModule:GetActiveSnapshot(player: Player, snapshotType: string)
	local data = self._data[player]
	local snapshot = if data then data.ActiveByType[snapshotType] else nil
	return if snapshot then TableUtil.deepCopy(snapshot) else nil
end

function StatisticsModule:GetSnapshot(player: Player, snapshotType: string, snapshotId: number)
	local data = self._data[player]
	if data == nil then return nil end
	local active = data.ActiveByType[snapshotType]
	if active ~= nil and active.SnapshotId == snapshotId then return TableUtil.deepCopy(active) end
	for _, snapshot in data.HistoryByType[snapshotType] or {} do
		if snapshot.SnapshotId == snapshotId then return TableUtil.deepCopy(snapshot) end
	end
	return nil
end

function StatisticsModule:GetSnapshots(player: Player, snapshotType: string)
	local data = self._data[player]
	if data == nil or self._config.SnapshotTypes[snapshotType] == nil then return {} end
	local result = TableUtil.deepCopy(data.HistoryByType[snapshotType] or {})
	if data.ActiveByType[snapshotType] ~= nil then
		insertSnapshotInCreationOrder(result, TableUtil.deepCopy(data.ActiveByType[snapshotType]))
	end
	return result
end

function StatisticsModule:GetLastSnapshots(player: Player, snapshotType: string, count: number)
	if not StatisticsValidation.IsSafeInteger(count, true) or count > self._config.Limits.MaxHistoryReadCount then
		return {}
	end
	local all = self:GetSnapshots(player, snapshotType)
	local result = {}
	for index = math.max(1, #all - count + 1), #all do table.insert(result, all[index]) end
	return result
end

function StatisticsModule:GetLastSnapshot(player: Player, snapshotType: string)
	local result = self:GetLastSnapshots(player, snapshotType, 1)
	return result[1]
end

function StatisticsModule:GetValue(player: Player, snapshotType: string, statisticId: string, snapshotId: number?)
	local snapshot = if snapshotId == nil
		then self:GetActiveSnapshot(player, snapshotType)
		else self:GetSnapshot(player, snapshotType, snapshotId)
	if snapshot == nil then return nil end
	return snapshot.Values[statisticId] or 0
end

function StatisticsModule:SaveSnapshot(player: Player, snapshotType: string, snapshotId: number?)
	local current, runtimeError = self:_requireRuntime(player)
	if current == nil then return runtimeError end
	if self._config.SnapshotTypes[snapshotType] == nil then
		return failure("UnknownSnapshotType", "Snapshot type is not configured")
	end
	local snapshot = if snapshotId == nil
		then current.ActiveByType[snapshotType]
		else self:GetSnapshot(player, snapshotType, snapshotId)
	if snapshot == nil then return failure("NotFound", "Snapshot does not exist") end
	if self._saveController == nil then return failure("NotReady", "Save controller is not bound") end
	local result = self._autoSave:RequestSave(
		self._saveController,
		player,
		`Statistics:{snapshotType}`,
		self._config.SaveRequestCooldownSeconds
	)
	if not result.Ok then self:_diagnose(player, "PersistenceFailed", "error") end
	return result
end

function StatisticsModule:BuildClientSnapshot(player: Player, snapshotType: string)
	if not self:_isManaged(snapshotType) then return nil, "Unavailable" end
	local snapshot = self:GetActiveSnapshot(player, snapshotType)
	if snapshot == nil then return nil, "Unavailable" end
	local projection = self._config.PublicProjection[snapshotType]
	local values = {}
	for _, statisticId in projection.StatisticIds do
		if snapshot.Values[statisticId] ~= nil then values[statisticId] = snapshot.Values[statisticId] end
	end
	local metadata = {}
	for _, key in projection.MetadataKeys do
		if snapshot.Metadata[key] ~= nil then metadata[key] = TableUtil.deepCopy(snapshot.Metadata[key]) end
	end
	return {
		SnapshotId = snapshot.SnapshotId,
		SnapshotType = snapshot.SnapshotType,
		State = "Active",
		StartedAt = snapshot.StartedAt,
		PlaceId = snapshot.PlaceId,
		Metadata = metadata,
		Values = values,
	}, nil
end

function StatisticsModule:BuildClientValue(player: Player, snapshotType: string, statisticId: string)
	if not self:_isManaged(snapshotType) then return nil, "Unavailable" end
	local projection = self._config.PublicProjection[snapshotType]
	if not contains(projection.StatisticIds, statisticId) then return nil, "Unavailable" end
	local snapshot = self:GetActiveSnapshot(player, snapshotType)
	if snapshot == nil then return nil, "Unavailable" end
	return {
		SnapshotId = snapshot.SnapshotId,
		SnapshotType = snapshotType,
		StatisticId = statisticId,
		Value = snapshot.Values[statisticId] or 0,
	}, nil
end

function StatisticsModule:GetClientResponseLimit(): number
	return self._config.Limits.MaxClientResponseEstimatedBytes
end

function StatisticsModule:Destroy()
	if self._destroyed then return end
	self._destroyed = true
	for player in self._data do self:Stop(player) end
	table.clear(self._resumeOnRun)
	self.MementoChanged:Destroy()
	self.Changed:Destroy()
	self.ActiveSnapshotsChanged:Destroy()
end

return StatisticsModule
