--!strict

local SaveSerialize = require(script.Parent.Parent.Save.SaveSerialize)

local StatisticsProtocol = {}

local SAFE_INTEGER = 9_007_199_254_740_991

StatisticsProtocol.BuiltInSnapshotTypes = table.freeze({
	Global = true,
	Session = true,
	Place = true,
})

StatisticsProtocol.RequestTypes = table.freeze({
	GetCurrentSnapshot = "Statistics.GetCurrentSnapshot",
	GetCurrentValue = "Statistics.GetCurrentValue",
})

local function isExactDictionary(value: any, fields: { [string]: boolean }): boolean
	if typeof(value) ~= "table" or getmetatable(value) ~= nil then
		return false
	end
	for key in value do
		if typeof(key) ~= "string" or fields[key] == nil then
			return false
		end
	end
	for key, required in fields do
		if required and value[key] == nil then
			return false
		end
	end
	return true
end

local function isBuiltInSnapshotType(value: any): boolean
	return typeof(value) == "string" and StatisticsProtocol.BuiltInSnapshotTypes[value] == true
end

local function isFinite(value: any): boolean
	return typeof(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function isSafeInteger(value: any, allowZero: boolean?): boolean
	return isFinite(value)
		and value == math.floor(value)
		and value >= (if allowZero then 0 else 1)
		and value <= SAFE_INTEGER
end

local function isIdentifier(value: any): boolean
	if typeof(value) ~= "string" or value == "" or #value > 64 then return false end
	local utf8Ok, length = pcall(utf8.len, value)
	return utf8Ok and length ~= nil and string.match(value, "^[%w%._%-]+$") ~= nil
end

function StatisticsProtocol.ValidateSnapshotRequest(payload: any): (boolean, any?, string?)
	if not isExactDictionary(payload, { SnapshotType = true })
		or not isBuiltInSnapshotType(payload.SnapshotType)
	then
		return false, nil, "InvalidSnapshotRequest"
	end
	return true, { SnapshotType = payload.SnapshotType }, nil
end

function StatisticsProtocol.ValidateValueRequest(payload: any): (boolean, any?, string?)
	if not isExactDictionary(payload, { SnapshotType = true, StatisticId = true })
		or not isBuiltInSnapshotType(payload.SnapshotType)
		or not isIdentifier(payload.StatisticId)
	then
		return false, nil, "InvalidValueRequest"
	end
	return true, {
		SnapshotType = payload.SnapshotType,
		StatisticId = payload.StatisticId,
	}, nil
end

function StatisticsProtocol.ValidateClientSnapshot(value: any): (boolean, any?, string?)
	if not isExactDictionary(value, {
		SnapshotId = true,
		SnapshotType = true,
		State = true,
		StartedAt = true,
		Metadata = true,
		Values = true,
		PlaceId = false,
	})
		or not isBuiltInSnapshotType(value.SnapshotType)
		or not isSafeInteger(value.SnapshotId, false)
		or value.State ~= "Active"
		or not isFinite(value.StartedAt)
		or typeof(value.Metadata) ~= "table"
		or getmetatable(value.Metadata) ~= nil
		or typeof(value.Values) ~= "table"
		or getmetatable(value.Values) ~= nil
		or value.SessionId ~= nil
		or value.Filter ~= nil
		or value.ClosedAt ~= nil
	then
		return false, nil, "InvalidClientSnapshot"
	end
	if value.SnapshotType == "Place" then
		if not isSafeInteger(value.PlaceId, true) then
			return false, nil, "InvalidClientSnapshot"
		end
	elseif value.PlaceId ~= nil then
		return false, nil, "InvalidClientSnapshot"
	end
	local metadataSafe = SaveSerialize.validate(value.Metadata)
	if not metadataSafe then return false, nil, "InvalidClientSnapshot" end
	for statisticId, statisticValue in value.Values do
		if not isIdentifier(statisticId) or not isFinite(statisticValue) or statisticValue < 0 then
			return false, nil, "InvalidClientSnapshot"
		end
	end
	return true, value, nil
end

function StatisticsProtocol.ValidateClientValue(value: any): (boolean, any?, string?)
	if not isExactDictionary(value, {
		SnapshotId = true,
		SnapshotType = true,
		StatisticId = true,
		Value = true,
	})
		or not isBuiltInSnapshotType(value.SnapshotType)
		or not isSafeInteger(value.SnapshotId, false)
		or not isIdentifier(value.StatisticId)
		or not isFinite(value.Value)
		or value.Value < 0
	then
		return false, nil, "InvalidClientValue"
	end
	return true, value, nil
end

return table.freeze(StatisticsProtocol)
