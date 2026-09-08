--!strict

local CharactersConfigCodec = {}

local FIELDS = table.freeze({
	respawnDelaySeconds = true,
})

local function isFinite(value: any): boolean
	return typeof(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

function CharactersConfigCodec.decode(value: any): (boolean, any?, string?)
	if typeof(value) ~= "table" or getmetatable(value) ~= nil then
		return false, nil, "characters_config: expected plain object"
	end
	for key in value do
		if typeof(key) ~= "string" or FIELDS[key] ~= true then
			return false, nil, `characters_config.{tostring(key)}: unknown field`
		end
	end
	local delay = value.respawnDelaySeconds
	if not isFinite(delay) or delay < 0 then
		return false, nil, "characters_config.respawnDelaySeconds: expected finite number not less than zero"
	end
	return true, table.freeze({ RespawnDelaySeconds = delay }), nil
end

return CharactersConfigCodec
