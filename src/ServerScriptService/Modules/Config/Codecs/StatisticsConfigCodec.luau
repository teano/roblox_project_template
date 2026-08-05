--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CommunicationConfig = require(ReplicatedStorage.Shared.Communication.CommunicationConfig)
local WalletStatisticsContract = require(script.Parent.Parent.Parent.Statistics.WalletStatisticsContract)

local StatisticsConfigCodec = {}

local SAFE_INTEGER = 9_007_199_254_740_991
local JSON_STRING_ENTRY_OVERHEAD_BYTES = 3 -- quotes plus a comma
local JSON_DICTIONARY_KEY_OVERHEAD_BYTES = 3 -- quotes plus a colon
local JSON_ARRAY_DELIMITER_BYTES = 2
local ORDERED_CURSOR_FIXED_BYTES = 64
local DEDUP_ROOT_RESERVE_BYTES = 128
local PROVIDER_INDEX_RESERVE_BYTES = 4_096
local BUILT_INS = table.freeze({ Global = true, Session = true, Place = true })
local ROOT_FIELDS = table.freeze({
	snapshotTypes = true,
	publicProjection = true,
	limits = true,
	saveRequestCooldownSeconds = true,
})
local LIMIT_FIELDS = table.freeze({
	maxSnapshotTypes = true,
	maxRetentionPerType = true,
	maxStatisticIdsPerSnapshot = true,
	maxStatisticIdLength = true,
	maxSnapshotTypeLength = true,
	maxSnapshotEncodedBytes = true,
	maxMetadataDepth = true,
	maxMetadataNodes = true,
	maxMetadataEncodedBytes = true,
	maxMetadataKeyLength = true,
	maxMetadataStringLength = true,
	maxDedupSources = true,
	maxEventIdsPerSource = true,
	maxProviderEncodedBytes = true,
	maxClientResponseEstimatedBytes = true,
	maxHistoryReadCount = true,
})

local LIMIT_SPECS = table.freeze({
	maxSnapshotTypes = { 3, 16 },
	maxRetentionPerType = { 0, 32 },
	maxStatisticIdsPerSnapshot = { 1, 256 },
	maxStatisticIdLength = { 1, 64 },
	maxSnapshotTypeLength = { 6, 48 },
	maxSnapshotEncodedBytes = { 1_024, 1_048_576 },
	maxMetadataDepth = { 0, 8 },
	maxMetadataNodes = { 1, 256 },
	maxMetadataEncodedBytes = { 2, 65_536 },
	maxMetadataKeyLength = { 1, 64 },
	maxMetadataStringLength = { 0, 4_096 },
	maxDedupSources = { 1, 32 },
	maxEventIdsPerSource = { 1, 512 },
	maxProviderEncodedBytes = { 16_384, 1_048_576 },
	maxClientResponseEstimatedBytes = { 256, CommunicationConfig.MaxSingleMessageEstimatedBytes - 1 },
	maxHistoryReadCount = { 1, 32 },
})

local function isFinite(value: any): boolean
	return typeof(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function isIntegerInRange(value: any, minimum: number, maximum: number): boolean
	return isFinite(value) and value == math.floor(value) and value >= minimum and value <= maximum
end

local function isValidUtf8(value: string): boolean
	local ok, length = pcall(utf8.len, value)
	return ok and length ~= nil
end

local function isIdentifier(value: any, maximumLength: number): boolean
	return typeof(value) == "string"
		and value ~= ""
		and #value <= maximumLength
		and isValidUtf8(value)
		and string.match(value, "^[%w%._%-]+$") ~= nil
end

local function hasOnlyFields(value: any, fields: { [string]: boolean }): (boolean, string?)
	if typeof(value) ~= "table" or getmetatable(value) ~= nil then
		return false, "expected plain object"
	end
	for key in value do
		if typeof(key) ~= "string" or fields[key] ~= true then
			return false, `unknown field '{tostring(key)}'`
		end
	end
	return true, nil
end

local function readStringArray(value: any, maximumLength: number, maximumCount: number): (boolean, { string }?, string?)
	if typeof(value) ~= "table" or getmetatable(value) ~= nil then
		return false, nil, "expected array"
	end
	local count = 0
	local maximumIndex = 0
	for key in value do
		if typeof(key) ~= "number" or key < 1 or key ~= math.floor(key) then
			return false, nil, "expected dense array"
		end
		count += 1
		maximumIndex = math.max(maximumIndex, key)
	end
	if count ~= maximumIndex or count > maximumCount then
		return false, nil, "array exceeds configured limit or is sparse"
	end
	local seen: { [string]: boolean } = {}
	local result = {}
	for index = 1, count do
		local entry = value[index]
		if not isIdentifier(entry, maximumLength) or seen[entry] then
			return false, nil, `invalid or duplicate identifier at index {index}`
		end
		seen[entry] = true
		table.insert(result, entry)
	end
	table.sort(result)
	return true, result, nil
end

local function decodeFilter(value: any, limits: any, path: string): (boolean, any?, string?)
	if value == nil then
		return true, { Mode = "AllowAllExcept", StatisticIds = {} }, nil
	end
	local shapeOk, shapeError = hasOnlyFields(value, { mode = true, statisticIds = true })
	if not shapeOk or (value.mode ~= "AllowOnly" and value.mode ~= "AllowAllExcept") then
		return false, nil, `{path}: {shapeError or "invalid mode"}`
	end
	local listOk, ids, listError = readStringArray(
		value.statisticIds,
		limits.MaxStatisticIdLength,
		limits.MaxStatisticIdsPerSnapshot
	)
	if not listOk then
		return false, nil, `{path}.statisticIds: {listError}`
	end
	return true, { Mode = value.mode, StatisticIds = ids }, nil
end

function StatisticsConfigCodec.decode(value: any): (boolean, any?, string?)
	local rootOk, rootError = hasOnlyFields(value, ROOT_FIELDS)
	if not rootOk then
		return false, nil, `statistics_config: {rootError}`
	end

	local limitsShapeOk, limitsShapeError = hasOnlyFields(value.limits, LIMIT_FIELDS)
	if not limitsShapeOk then
		return false, nil, `statistics_config.limits: {limitsShapeError}`
	end
	local limits: { [string]: number } = {}
	for rawName, range in LIMIT_SPECS do
		local rawValue = value.limits[rawName]
		if not isIntegerInRange(rawValue, range[1], range[2]) then
			return false, nil, `statistics_config.limits.{rawName}: expected integer in [{range[1]}, {range[2]}]`
		end
		local modelName = string.upper(string.sub(rawName, 1, 1)) .. string.sub(rawName, 2)
		limits[modelName] = rawValue
	end
	if limits.MaxMetadataEncodedBytes > limits.MaxSnapshotEncodedBytes then
		return false, nil, "statistics_config.limits: metadata budget exceeds snapshot budget"
	end
	if limits.MaxStatisticIdLength < WalletStatisticsContract.RequiredIdentifierLength then
		return false, nil, `statistics_config.limits.maxStatisticIdLength: expected at least {
			WalletStatisticsContract.RequiredIdentifierLength
		} for mandatory Wallet Statistics identifiers`
	end
	if limits.MaxHistoryReadCount > limits.MaxRetentionPerType then
		return false, nil, "statistics_config.limits: history read count exceeds retention limit"
	end

	if typeof(value.snapshotTypes) ~= "table" or getmetatable(value.snapshotTypes) ~= nil then
		return false, nil, "statistics_config.snapshotTypes: expected plain object"
	end
	local snapshotTypeCount = 0
	for snapshotType in value.snapshotTypes do
		if not isIdentifier(snapshotType, limits.MaxSnapshotTypeLength) then
			return false, nil, `statistics_config.snapshotTypes.{tostring(snapshotType)}: invalid type identifier`
		end
		snapshotTypeCount += 1
	end
	if snapshotTypeCount > limits.MaxSnapshotTypes then
		return false, nil, "statistics_config.snapshotTypes: too many types"
	end
	for builtIn in BUILT_INS do
		if value.snapshotTypes[builtIn] == nil then
			return false, nil, `statistics_config.snapshotTypes.{builtIn}: required`
		end
	end

	local snapshotTypes: { [string]: any } = {}
	local retainedSnapshotCapacity = 1 -- pending Session
	for snapshotType, rawDefinition in value.snapshotTypes do
		local definitionOk, definitionError = hasOnlyFields(rawDefinition, { retention = true, filter = true })
		if not definitionOk
			or not isIntegerInRange(rawDefinition.retention, 0, limits.MaxRetentionPerType)
		then
			return false, nil, `statistics_config.snapshotTypes.{snapshotType}: {
				definitionError or "invalid retention"
			}`
		end
		local filterOk, filter, filterError = decodeFilter(
			rawDefinition.filter,
			limits,
			`statistics_config.snapshotTypes.{snapshotType}.filter`
		)
		if not filterOk then
			return false, nil, filterError
		end
		snapshotTypes[snapshotType] = {
			Retention = rawDefinition.retention,
			Filter = filter,
		}
		retainedSnapshotCapacity += 1 + rawDefinition.retention
	end

	local projectionShapeOk, projectionShapeError = hasOnlyFields(
		value.publicProjection,
		BUILT_INS
	)
	if not projectionShapeOk then
		return false, nil, `statistics_config.publicProjection: {projectionShapeError}`
	end
	local publicProjection: { [string]: any } = {}
	for snapshotType in BUILT_INS do
		local rawProjection = value.publicProjection[snapshotType]
		local definitionOk, definitionError = hasOnlyFields(rawProjection, {
			statisticIds = true,
			metadataKeys = true,
		})
		if not definitionOk then
			return false, nil, `statistics_config.publicProjection.{snapshotType}: {definitionError}`
		end
		local statsOk, statisticIds, statsError = readStringArray(
			rawProjection.statisticIds,
			limits.MaxStatisticIdLength,
			limits.MaxStatisticIdsPerSnapshot
		)
		if not statsOk then
			return false, nil, `statistics_config.publicProjection.{snapshotType}.statisticIds: {statsError}`
		end
		local metadataOk, metadataKeys, metadataError = readStringArray(
			rawProjection.metadataKeys,
			limits.MaxMetadataKeyLength,
			limits.MaxMetadataNodes
		)
		if not metadataOk then
			return false, nil, `statistics_config.publicProjection.{snapshotType}.metadataKeys: {metadataError}`
		end
		publicProjection[snapshotType] = {
			StatisticIds = statisticIds,
			MetadataKeys = metadataKeys,
		}
	end

	if not isFinite(value.saveRequestCooldownSeconds)
		or value.saveRequestCooldownSeconds < 1
		or value.saveRequestCooldownSeconds > 3_600
	then
		return false, nil, "statistics_config.saveRequestCooldownSeconds: expected number in [1, 3600]"
	end

	-- Every retained record is independently constrained by the snapshot byte
	-- cap. A source uses exactly one dedupe mode, so reserve the larger of a
	-- maximum ordered cursor and a maximum exact EventId ledger for every
	-- configured source. Identifier characters are restricted to JSON-safe
	-- ASCII, making their encoded bytes bounded by MaxStatisticIdLength plus
	-- quotes/separators.
	local maximumIdentifierBytes = limits.MaxStatisticIdLength
	local orderedSourceBytes = maximumIdentifierBytes
		+ JSON_DICTIONARY_KEY_OVERHEAD_BYTES
		+ maximumIdentifierBytes
		+ ORDERED_CURSOR_FIXED_BYTES
	local eventLedgerSourceBytes = maximumIdentifierBytes
		+ JSON_DICTIONARY_KEY_OVERHEAD_BYTES
		+ JSON_ARRAY_DELIMITER_BYTES
		+ limits.MaxEventIdsPerSource
			* (maximumIdentifierBytes + JSON_STRING_ENTRY_OVERHEAD_BYTES)
	local dedupReserve = DEDUP_ROOT_RESERVE_BYTES
		+ limits.MaxDedupSources * math.max(orderedSourceBytes, eventLedgerSourceBytes)
	local structuralReserve = limits.MaxMetadataEncodedBytes
		+ dedupReserve
		+ PROVIDER_INDEX_RESERVE_BYTES
	if retainedSnapshotCapacity * limits.MaxSnapshotEncodedBytes + structuralReserve
		> limits.MaxProviderEncodedBytes
	then
		return false, nil, "statistics_config: theoretical retained snapshot budget exceeds provider budget"
	end
	if limits.MaxProviderEncodedBytes > SAFE_INTEGER then
		return false, nil, "statistics_config: provider budget is not a safe integer"
	end

	return true, {
		SnapshotTypes = snapshotTypes,
		PublicProjection = publicProjection,
		Limits = limits,
		SaveRequestCooldownSeconds = value.saveRequestCooldownSeconds,
	}, nil
end

return StatisticsConfigCodec
