--!strict

local GlobalSaveConfigCodec = {}

local function isFiniteNumber(value: any): boolean
	return typeof(value) == "number"
		and value == value
		and value ~= math.huge
		and value ~= -math.huge
end

function GlobalSaveConfigCodec.decode(value: any): (boolean, any?, string?)
	if typeof(value) ~= "table"
		or not isFiniteNumber(value.SnapshotRequestAttempts)
		or value.SnapshotRequestAttempts < 1
		or value.SnapshotRequestAttempts > 100
		or value.SnapshotRequestAttempts ~= math.floor(value.SnapshotRequestAttempts)
		or not isFiniteNumber(value.SnapshotRetryDelaySeconds)
		or value.SnapshotRetryDelaySeconds < 0.05
		or value.SnapshotRetryDelaySeconds > 10
	then
		return false, nil, "invalid GlobalSave client config"
	end
	for key in value do
		if key ~= "SnapshotRequestAttempts" and key ~= "SnapshotRetryDelaySeconds" then
			return false, nil, `GlobalSave client config has unknown field '{tostring(key)}'`
		end
	end
	return true, {
		SnapshotRequestAttempts = value.SnapshotRequestAttempts,
		SnapshotRetryDelaySeconds = value.SnapshotRetryDelaySeconds,
	}, nil
end

return GlobalSaveConfigCodec
