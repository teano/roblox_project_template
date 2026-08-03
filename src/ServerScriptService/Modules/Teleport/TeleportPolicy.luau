--!strict

export type TeleportPolicy = {
	AllowedPlaceIds: { [number]: boolean },
	MaxGroupSize: number,
	MaxSessionIdLength: number,
	MaxAttemptIdLength: number,
}

local TeleportPolicy = {}

local TEMPLATE_GAME_ID = 10596427617
local TEMPLATE_PLACE_IDS = table.freeze({
	[91045933836846] = true,
	[101736951773632] = true,
})

local function freezePolicy(
	allowedPlaceIds: { [number]: boolean },
	maxGroupSize: number,
	maxSessionIdLength: number,
	maxAttemptIdLength: number
): TeleportPolicy
	return table.freeze({
		AllowedPlaceIds = table.freeze(allowedPlaceIds),
		MaxGroupSize = maxGroupSize,
		MaxSessionIdLength = maxSessionIdLength,
		MaxAttemptIdLength = maxAttemptIdLength,
	})
end

local function isPositiveInteger(value: any): boolean
	return typeof(value) == "number"
		and value == value
		and value ~= math.huge
		and value % 1 == 0
		and value > 0
end

function TeleportPolicy.new(policy: TeleportPolicy): TeleportPolicy
	assert(typeof(policy) == "table", "Teleport policy required")
	assert(isPositiveInteger(policy.MaxGroupSize) and policy.MaxGroupSize <= 50, "MaxGroupSize must be 1..50")
	assert(policy.MaxSessionIdLength == 36, "MaxSessionIdLength must preserve canonical GUIDs")
	assert(policy.MaxAttemptIdLength == 36, "MaxAttemptIdLength must preserve canonical GUIDs")
	assert(typeof(policy.AllowedPlaceIds) == "table", "AllowedPlaceIds required")
	local allowed = {}
	for placeId, enabled in policy.AllowedPlaceIds do
		assert(isPositiveInteger(placeId) and enabled == true, "AllowedPlaceIds entries must be positive IDs set to true")
		allowed[placeId] = true
	end
	assert(next(allowed) ~= nil, "At least one allowed place is required")
	return freezePolicy(
		allowed,
		policy.MaxGroupSize,
		policy.MaxSessionIdLength,
		policy.MaxAttemptIdLength
	)
end

function TeleportPolicy.Template(placeId: number, gameId: number?): TeleportPolicy
	if placeId == 0 then
		assert(gameId == nil or gameId == 0, "An unpublished place cannot belong to a published Experience")
		return freezePolicy({}, 50, 36, 36)
	end
	assert(
		gameId == nil or isPositiveInteger(gameId),
		"A published place must have a positive Experience ID"
	)
	local allowedPlaceIds = { [placeId] = true }
	if gameId == TEMPLATE_GAME_ID then
		assert(TEMPLATE_PLACE_IDS[placeId] == true, "Template Experience place is not recorded")
		for templatePlaceId in TEMPLATE_PLACE_IDS do
			allowedPlaceIds[templatePlaceId] = true
		end
	end
	return TeleportPolicy.new({
		AllowedPlaceIds = allowedPlaceIds,
		MaxGroupSize = 50,
		MaxSessionIdLength = 36,
		MaxAttemptIdLength = 36,
	})
end

return table.freeze(TeleportPolicy)
