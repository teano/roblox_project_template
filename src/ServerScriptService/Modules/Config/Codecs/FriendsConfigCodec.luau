--!strict

local Codec = {}
local fields = table.freeze({ minInviteCapacity = true, maxInviteCapacity = true, reserveLifetimeSeconds = true })

local function finite(value: any): boolean
	return typeof(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function nonNegativeInteger(value: any): boolean
	return finite(value) and value >= 0 and value == math.floor(value)
end

function Codec.decode(value: any): (boolean, any?, string?)
	if typeof(value) ~= "table" or getmetatable(value) ~= nil then return false, nil, "friends_config: expected plain object" end
	for key in value do
		if typeof(key) ~= "string" or fields[key] ~= true then return false, nil, `friends_config.{tostring(key)}: unknown field` end
	end
	local minimum = value.minInviteCapacity
	local maximum = value.maxInviteCapacity
	local reserveLifetime = value.reserveLifetimeSeconds
	if not nonNegativeInteger(minimum) or not nonNegativeInteger(maximum) or minimum > maximum then
		return false, nil, "friends_config: invite capacities must be ordered non-negative integers"
	end
	if not finite(reserveLifetime) or reserveLifetime <= 0 then return false, nil, "friends_config.reserveLifetimeSeconds: expected positive finite number" end
	return true, table.freeze({ MinInviteCapacity = minimum, MaxInviteCapacity = maximum, ReserveLifetimeSeconds = reserveLifetime }), nil
end

return Codec
