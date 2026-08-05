--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SaveSerialize = require(ReplicatedStorage.Shared.Save.SaveSerialize)
local TableUtil = require(ReplicatedStorage.Shared.Util.TableUtil)

local StatisticsValidation = {}

local SAFE_INTEGER = 9_007_199_254_740_991
local SYSTEM_FIELDS = table.freeze({
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

function StatisticsValidation.IsFinite(value: any): boolean
	return typeof(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

function StatisticsValidation.IsSafeInteger(value: any, allowZero: boolean?): boolean
	return StatisticsValidation.IsFinite(value)
		and value == math.floor(value)
		and value >= (if allowZero then 0 else 1)
		and value <= SAFE_INTEGER
end

function StatisticsValidation.IsValidUtf8(value: string): boolean
	local ok, length = pcall(utf8.len, value)
	return ok and length ~= nil
end

function StatisticsValidation.IsIdentifier(value: any, maximumLength: number): boolean
	return typeof(value) == "string"
		and value ~= ""
		and #value <= maximumLength
		and StatisticsValidation.IsValidUtf8(value)
		and string.match(value, "^[%w%._%-]+$") ~= nil
end

function StatisticsValidation.HasOnlyFields(value: any, fields: { [string]: boolean }): boolean
	if typeof(value) ~= "table" or getmetatable(value) ~= nil then
		return false
	end
	for key in value do
		if typeof(key) ~= "string" or fields[key] ~= true then
			return false
		end
	end
	return true
end

function StatisticsValidation.ValidateStringArray(
	value: any,
	maximumCount: number,
	maximumLength: number
): (boolean, { string }?, string?)
	if typeof(value) ~= "table" or getmetatable(value) ~= nil then
		return false, nil, "expected plain array"
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
		return false, nil, "array limit exceeded or sparse"
	end
	local result = {}
	local seen: { [string]: boolean } = {}
	for index = 1, count do
		local entry = value[index]
		if not StatisticsValidation.IsIdentifier(entry, maximumLength) or seen[entry] then
			return false, nil, `invalid or duplicate identifier at {index}`
		end
		seen[entry] = true
		table.insert(result, entry)
	end
	return true, result, nil
end

local function validateMetadataValue(
	value: any,
	limits: any,
	state: any,
	depth: number,
	path: string
): string?
	state.Nodes += 1
	if state.Nodes > limits.MaxMetadataNodes then
		return `{path}: metadata node limit exceeded`
	end
	if depth > limits.MaxMetadataDepth then
		return `{path}: metadata depth limit exceeded`
	end

	local valueType = typeof(value)
	if valueType == "boolean" then
		return nil
	elseif valueType == "number" then
		return if StatisticsValidation.IsFinite(value) then nil else `{path}: non-finite number`
	elseif valueType == "string" then
		if not StatisticsValidation.IsValidUtf8(value) then
			return `{path}: invalid UTF-8`
		end
		return if #value <= limits.MaxMetadataStringLength then nil else `{path}: string too long`
	elseif valueType ~= "table" then
		return `{path}: unsupported metadata type '{valueType}'`
	end
	if getmetatable(value) ~= nil then
		return `{path}: metatable is not allowed`
	end
	if state.Seen[value] then
		return `{path}: cyclic metadata`
	end
	state.Seen[value] = true

	local stringKeys = 0
	local numericKeys = 0
	local maximumIndex = 0
	for key in value do
		if typeof(key) == "string" then
			stringKeys += 1
			if #key > limits.MaxMetadataKeyLength or not StatisticsValidation.IsValidUtf8(key) then
				state.Seen[value] = nil
				return `{path}: invalid metadata key`
			end
		elseif typeof(key) == "number" and StatisticsValidation.IsSafeInteger(key, false) then
			numericKeys += 1
			maximumIndex = math.max(maximumIndex, key)
		else
			state.Seen[value] = nil
			return `{path}: invalid metadata key type`
		end
	end
	if stringKeys > 0 and numericKeys > 0 then
		state.Seen[value] = nil
		return `{path}: mixed metadata table`
	end
	if numericKeys > 0 and maximumIndex ~= numericKeys then
		state.Seen[value] = nil
		return `{path}: sparse metadata array`
	end

	for key, child in value do
		local issue = validateMetadataValue(child, limits, state, depth + 1, `{path}.{tostring(key)}`)
		if issue ~= nil then
			state.Seen[value] = nil
			return issue
		end
	end
	state.Seen[value] = nil
	return nil
end

function StatisticsValidation.ValidateMetadata(value: any, limits: any): (boolean, any?, string?)
	local source = if value == nil then {} else value
	if typeof(source) ~= "table" or getmetatable(source) ~= nil then
		return false, nil, "Metadata must be a plain table"
	end
	for key in source do
		if typeof(key) == "string" and SYSTEM_FIELDS[key] then
			return false, nil, `Metadata cannot replace system field '{key}'`
		end
	end
	local issue = validateMetadataValue(source, limits, { Nodes = 0, Seen = {} }, 0, "Metadata")
	if issue ~= nil then
		return false, nil, issue
	end
	local safe, issues = SaveSerialize.validate(source)
	if not safe then
		return false, nil, `Metadata is not DataStore-safe: {
			if issues[1] then issues[1].Reason else "unknown"
		}`
	end
	local measured, encodedBytes, measurementError = SaveSerialize.measureEncodedSize(source)
	if not measured or encodedBytes == nil then
		return false, nil, `Metadata encoding failed: {measurementError or "unknown"}`
	end
	if encodedBytes > limits.MaxMetadataEncodedBytes then
		return false, nil, "Metadata encoded byte limit exceeded"
	end
	return true, TableUtil.deepCopy(source), nil
end

return StatisticsValidation
