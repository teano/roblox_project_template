--!strict

local Codec = {}

function Codec.decode(value: any): (boolean, any?, string?)
	if typeof(value) ~= "table" or getmetatable(value) ~= nil then return false, nil, "player_slots_config: expected plain object" end
	for key in value do
		if key ~= "strategy" then return false, nil, `player_slots_config.{tostring(key)}: unknown field` end
	end
	if value.strategy ~= "Enabled" and value.strategy ~= "Disabled" then return false, nil, "player_slots_config.strategy: expected Enabled or Disabled" end
	return true, table.freeze({ Strategy = value.strategy }), nil
end

return Codec
