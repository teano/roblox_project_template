--!strict

export type TeleportValidationConfig = {
	Enabled: boolean,
	GameId: number,
	RoutesBySourcePlaceId: { [number]: number },
	AuthorizedUserIds: { [number]: boolean },
}

-- Keep the reusable template inert. Follow docs/TeleportTesting.md to
-- temporarily configure, publish, exercise, and disable the validation pad.
local ENABLED = false
local GAME_ID = 0
local ROUTES_BY_SOURCE_PLACE_ID: { [number]: number } = {}
local AUTHORIZED_USER_IDS: { [number]: boolean } = {}

return table.freeze({
	Enabled = ENABLED,
	GameId = GAME_ID,
	RoutesBySourcePlaceId = table.freeze(table.clone(ROUTES_BY_SOURCE_PLACE_ID)),
	AuthorizedUserIds = table.freeze(table.clone(AUTHORIZED_USER_IDS)),
}) :: TeleportValidationConfig
