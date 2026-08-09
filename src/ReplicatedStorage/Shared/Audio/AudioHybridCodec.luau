--!strict

local Codec = {}
local CommunicationSerialize = require(script.Parent.Parent.Communication.CommunicationSerialize)
local AudioSafetyLimits = require(script.Parent.AudioSafetyLimits)

local ALLOWED = {
	Version = true, CueId = true, VariantId = true, VolumeMultiplier = true,
	PlaybackSpeedMultiplier = true, TimePosition = true, Spatial = true,
}

local function finite(value: any): boolean
	return typeof(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function identifier(value: any): boolean
	return typeof(value) == "string" and #value > 0 and #value <= 128 and value:match("^[A-Za-z0-9][A-Za-z0-9._%-]*$") ~= nil
end

local function validateWithSerializer(payload: any, serializerValidate: (any, any) -> boolean): (boolean, any?, string?)
	if typeof(payload) ~= "table" or getmetatable(payload) ~= nil then return false, nil, "InvalidSchema" end
	local serializable = serializerValidate(payload, {
		MaxBytes = AudioSafetyLimits.HybridIntentMaxEstimatedBytes,
		MaxNodes = 32,
		MaxIssues = 1,
	})
	if not serializable then return false, nil, "InvalidSchema" end
	for key in payload do if not ALLOWED[key] then return false, nil, "InvalidSchema" end end
	if payload.Version ~= 1 or not identifier(payload.CueId) or not identifier(payload.VariantId) then
		return false, nil, "InvalidSchema"
	end
	if payload.VolumeMultiplier ~= nil and (not finite(payload.VolumeMultiplier) or payload.VolumeMultiplier < 0 or payload.VolumeMultiplier > 2) then return false, nil, "InvalidSchema" end
	if payload.PlaybackSpeedMultiplier ~= nil and (not finite(payload.PlaybackSpeedMultiplier) or payload.PlaybackSpeedMultiplier < 0.5 or payload.PlaybackSpeedMultiplier > 2) then return false, nil, "InvalidSchema" end
	if payload.TimePosition ~= nil and (not finite(payload.TimePosition) or payload.TimePosition < 0) then return false, nil, "InvalidSchema" end
	local spatial = payload.Spatial
	if typeof(spatial) ~= "table" or getmetatable(spatial) ~= nil then return false, nil, "InvalidSchema" end
	if spatial.Kind == "None" then
		for key in spatial do if key ~= "Kind" then return false, nil, "InvalidSchema" end end
	elseif spatial.Kind == "Point" then
		for key in spatial do if key ~= "Kind" and key ~= "Position" then return false, nil, "InvalidSchema" end end
		if typeof(spatial.Position) ~= "Vector3"
			or not finite(spatial.Position.X)
			or not finite(spatial.Position.Y)
			or not finite(spatial.Position.Z)
			or math.abs(spatial.Position.X) > 1_000_000
			or math.abs(spatial.Position.Y) > 1_000_000
			or math.abs(spatial.Position.Z) > 1_000_000 then return false, nil, "InvalidSchema" end
	else return false, nil, "InvalidSchema" end
	return true, payload, nil
end

function Codec.validate(payload: any): (boolean, any?, string?)
	return validateWithSerializer(payload, CommunicationSerialize.validate)
end

-- Test seam for observing the exact production serializer options while the
-- complete HybridIntentV1 schema validation remains active.
function Codec.validateWithSerializer(payload: any, serializerValidate: (any, any) -> boolean): (boolean, any?, string?)
	assert(typeof(serializerValidate) == "function", "serializerValidate must be a function")
	return validateWithSerializer(payload, serializerValidate)
end

return table.freeze(Codec)
