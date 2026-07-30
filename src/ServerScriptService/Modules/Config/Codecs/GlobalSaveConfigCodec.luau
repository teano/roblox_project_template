--!strict

local GlobalSaveConfigCodec = {}

local FIELDS = table.freeze({
	autoSaveIntervalSeconds = true,
	snapshotLoadTimeoutSeconds = true,
	snapshotRequestAttempts = true,
	snapshotRetryDelaySeconds = true,
})

local function isFiniteNumber(value: any): boolean
	return typeof(value) == "number"
		and value == value
		and value ~= math.huge
		and value ~= -math.huge
end

local function readBoundedNumber(
	source: any,
	field: string,
	minimum: number,
	maximum: number,
	integer: boolean
): (boolean, number?, string?)
	local value = source[field]
	if not isFiniteNumber(value)
		or value < minimum
		or value > maximum
		or (integer and value ~= math.floor(value))
	then
		return false, nil, `global_save_config.{field}: expected {
			if integer then "integer" else "number"
		} in [{minimum}, {maximum}]`
	end
	return true, value, nil
end

function GlobalSaveConfigCodec.decode(value: any): (boolean, any?, string?)
	if typeof(value) ~= "table" then
		return false, nil, "global_save_config: expected object"
	end
	for key in value do
		if FIELDS[key] ~= true then
			return false, nil, `global_save_config.{tostring(key)}: unknown field`
		end
	end

	local autoSaveOk, autoSaveIntervalSeconds, autoSaveError =
		readBoundedNumber(value, "autoSaveIntervalSeconds", 5, 3_600, false)
	if not autoSaveOk then
		return false, nil, autoSaveError
	end
	local loadOk, snapshotLoadTimeoutSeconds, loadError =
		readBoundedNumber(value, "snapshotLoadTimeoutSeconds", 1, 120, false)
	if not loadOk then
		return false, nil, loadError
	end
	local attemptsOk, snapshotRequestAttempts, attemptsError =
		readBoundedNumber(value, "snapshotRequestAttempts", 1, 100, true)
	if not attemptsOk then
		return false, nil, attemptsError
	end
	local delayOk, snapshotRetryDelaySeconds, delayError =
		readBoundedNumber(value, "snapshotRetryDelaySeconds", 0.05, 10, false)
	if not delayOk then
		return false, nil, delayError
	end

	return true, {
		AutoSaveIntervalSeconds = autoSaveIntervalSeconds,
		SnapshotLoadTimeoutSeconds = snapshotLoadTimeoutSeconds,
		SnapshotRequestAttempts = snapshotRequestAttempts,
		SnapshotRetryDelaySeconds = snapshotRetryDelaySeconds,
	}, nil
end

function GlobalSaveConfigCodec.toClient(value: any): (boolean, any?, string?)
	return true, {
		SnapshotRequestAttempts = value.SnapshotRequestAttempts,
		SnapshotRetryDelaySeconds = value.SnapshotRetryDelaySeconds,
	}, nil
end

return GlobalSaveConfigCodec
