--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DeepFreeze = require(ReplicatedStorage.Shared.Util.DeepFreeze)
local AudioSafetyLimits = require(script.Parent.AudioSafetyLimits)

local AudioConfigValidator = {}

local REQUIRED_TYPES = { "UI", "SFX", "World", "Music" }
local REQUIRED_FADERS = { "Master", "UI", "SFX", "World", "Music" }

local function isFinite(value: any): boolean
	return typeof(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function isInteger(value: any): boolean
	return isFinite(value) and value == math.floor(value)
end

local function hasExactKeys(value: any, allowed: { [string]: boolean }): boolean
	if typeof(value) ~= "table" or getmetatable(value) ~= nil then
		return false
	end
	for key in value do
		if typeof(key) ~= "string" or not allowed[key] then
			return false
		end
	end
	for key in allowed do
		if value[key] == nil then
			return false
		end
	end
	return true
end

local function hasOnlyKeys(value: any, allowed: { [string]: boolean }): boolean
	if typeof(value) ~= "table" or getmetatable(value) ~= nil then
		return false
	end
	for key in value do
		if typeof(key) ~= "string" or not allowed[key] then
			return false
		end
	end
	return true
end

local function exactKeys(keys: { string }): { [string]: boolean }
	local result = {}
	for _, key in keys do
		result[key] = true
	end
	return result
end

local function validIdentifier(value: any, maxBytes: number): boolean
	return typeof(value) == "string"
		and #value >= 1
		and #value <= maxBytes
		and value:match("^[A-Za-z0-9][A-Za-z0-9._%-]*$") ~= nil
end

local function validateBudget(value: any, maximum: number): boolean
	return isInteger(value) and value >= 0 and value <= maximum
end

local function validatePlayerType(id: string, record: any): (boolean, any?)
	local ordinary = id ~= "Music"
	local keys = if ordinary
		then exactKeys({
			"PlayerType", "ServerMaxActive", "ServerMaxRetained", "ClientMaxActive", "ClientMaxRetained",
			"HybridRatePerSecond", "HybridBurst", "SourceVolumeMin", "SourceVolumeMax",
			"PlaybackSpeedMin", "PlaybackSpeedMax", "LoadTimeoutSeconds",
		})
		else exactKeys({
			"PlayerType", "ClientMaxActive", "ClientMaxRetained", "MusicStackMaxDepth", "SourceVolumeMin",
			"SourceVolumeMax", "PlaybackSpeedMin", "PlaybackSpeedMax", "LoadTimeoutSeconds",
		})
	if not hasExactKeys(record, keys) or record.PlayerType ~= id then
		return false, nil
	end
	if ordinary then
		if not validateBudget(record.ServerMaxActive, AudioSafetyLimits.MaxOrdinaryActivePerType)
			or not validateBudget(record.ServerMaxRetained, AudioSafetyLimits.MaxOrdinaryRetainedPerType)
			or not validateBudget(record.ClientMaxActive, AudioSafetyLimits.MaxOrdinaryActivePerType)
			or not validateBudget(record.ClientMaxRetained, AudioSafetyLimits.MaxOrdinaryRetainedPerType)
			or record.ServerMaxRetained > record.ServerMaxActive
			or record.ClientMaxRetained > record.ClientMaxActive
			or not isFinite(record.HybridRatePerSecond)
			or not isFinite(record.HybridBurst)
			or record.HybridRatePerSecond < 0
			or record.HybridRatePerSecond > AudioSafetyLimits.MaxHybridRatePerSecond
			or record.HybridBurst < 0
			or record.HybridBurst > AudioSafetyLimits.MaxHybridBurst
		then
			return false, nil
		end
	else
		if not validateBudget(record.ClientMaxActive, AudioSafetyLimits.MaxMusicStackDepth)
			or not validateBudget(record.ClientMaxRetained, AudioSafetyLimits.MaxOrdinaryRetainedPerType)
			or not validateBudget(record.MusicStackMaxDepth, AudioSafetyLimits.MaxMusicStackDepth)
			or record.ClientMaxActive ~= record.MusicStackMaxDepth
			or record.ClientMaxRetained > record.ClientMaxActive
		then
			return false, nil
		end
	end
	if not isFinite(record.SourceVolumeMin)
		or not isFinite(record.SourceVolumeMax)
		or record.SourceVolumeMin < 0
		or record.SourceVolumeMin > record.SourceVolumeMax
		or record.SourceVolumeMax > 10
		or not isFinite(record.PlaybackSpeedMin)
		or not isFinite(record.PlaybackSpeedMax)
		or record.PlaybackSpeedMin < 0.05
		or record.PlaybackSpeedMin > record.PlaybackSpeedMax
		or record.PlaybackSpeedMax > 20
		or not isFinite(record.LoadTimeoutSeconds)
		or record.LoadTimeoutSeconds < 0.5
		or record.LoadTimeoutSeconds > 30
	then
		return false, nil
	end
	return true, table.clone(record)
end

local function validateCurve(points: any, distance: boolean): (boolean, any?)
	if points == nil then
		return true, nil
	end
	if typeof(points) ~= "table" or getmetatable(points) ~= nil then
		return false, nil
	end
	local count = 0
	for key in points do
		if not isInteger(key) or key < 1 then return false, nil end
		count += 1
	end
	if count ~= #points or (not distance and count < 1) or count > AudioSafetyLimits.MaxCurvePoints then
		return false, nil
	end
	local result = {}
	local previous = -math.huge
	local coordinateKey = if distance then "Distance" else "Angle"
	for index = 1, count do
		local point = points[index]
		if point == nil
			or not hasExactKeys(point, exactKeys({ coordinateKey, "Gain01" }))
		then
			return false, nil
		end
		local coordinate = point[coordinateKey]
		if not isFinite(coordinate)
			or coordinate <= previous
			or coordinate < 0
			or (not distance and coordinate > 180)
			or not isFinite(point.Gain01)
			or point.Gain01 < 0
			or point.Gain01 > 1
		then
			return false, nil
		end
		previous = coordinate
		table.insert(result, { [coordinateKey] = coordinate, Gain01 = point.Gain01 })
	end
	return true, result
end

local function disabled(reason: string, logger: any): any
	logger:Warn("InvalidConfig", { ReasonCode = reason })
	return DeepFreeze({ Enabled = false, ReasonCode = reason })
end

function AudioConfigValidator.validate(runtimeConfig: any, routingConfig: any, spatialConfig: any, side: string, logger: any): any
	if side ~= "Server" and side ~= "Client" then
		return disabled("InvalidSide", logger)
	end
	if not hasExactKeys(runtimeConfig, exactKeys({ "Version", "PlayerTypes", "Faders" }))
		or runtimeConfig.Version ~= 1
		or not hasExactKeys(runtimeConfig.PlayerTypes, exactKeys(REQUIRED_TYPES))
		or not hasExactKeys(runtimeConfig.Faders, exactKeys(REQUIRED_FADERS))
	then
		return disabled("InvalidRuntimeConfig", logger)
	end

	local playerTypes = {}
	local totalActive = 0
	local totalRetained = 0
	for _, id in REQUIRED_TYPES do
		local ok, normalized = validatePlayerType(id, runtimeConfig.PlayerTypes[id])
		if not ok then
			return disabled(`InvalidPlayerType:{id}`, logger)
		end
		playerTypes[id] = normalized
		if side == "Server" then
			if id ~= "Music" then
				totalActive += normalized.ServerMaxActive
				totalRetained += normalized.ServerMaxRetained
			end
		else
			totalActive += normalized.ClientMaxActive
			totalRetained += normalized.ClientMaxRetained
		end
	end
	if totalActive > AudioSafetyLimits.MaxTotalActivePerSide
		or totalRetained > AudioSafetyLimits.MaxTotalRetainedPerSide
		or 4 * (totalActive + totalRetained) > AudioSafetyLimits.MaxWorstCasePlaybackObjectsPerSide
	then
		return disabled("AggregateBudgetExceeded", logger)
	end

	local faderProfiles = {}
	for _, id in REQUIRED_FADERS do
		local record = runtimeConfig.Faders[id]
		if not hasExactKeys(record, exactKeys({ "DefaultLevel01", "MinDb", "MaxDb", "Curve" }))
			or record.Curve ~= "LinearDb"
			or not isFinite(record.DefaultLevel01)
			or record.DefaultLevel01 < 0
			or record.DefaultLevel01 > 1
			or not isFinite(record.MinDb)
			or not isFinite(record.MaxDb)
			or record.MinDb < -60
			or record.MinDb > record.MaxDb
			or record.MaxDb > 0
		then
			return disabled(`InvalidFader:{id}`, logger)
		end
		faderProfiles[id] = table.clone(record)
	end

	if not hasExactKeys(routingConfig, exactKeys({ "Version", "InteractionGroupId", "Faders", "Routes" }))
		or routingConfig.Version ~= 1
		or routingConfig.InteractionGroupId ~= "AudioPlayback.Private.v1"
		or not hasExactKeys(routingConfig.Faders, exactKeys(REQUIRED_FADERS))
		or not hasExactKeys(routingConfig.Routes, exactKeys(REQUIRED_TYPES))
	then
		return disabled("InvalidRoutingConfig", logger)
	end
	local faderParents = {}
	local routes = {}
	for _, id in REQUIRED_FADERS do
		local record = routingConfig.Faders[id]
		if typeof(record) ~= "table" or getmetatable(record) ~= nil then
			return disabled(`InvalidRouteFader:{id}`, logger)
		end
		for key in record do
			if key ~= "ParentFaderId" then
				return disabled(`InvalidRouteFader:{id}`, logger)
			end
		end
		local parent = record.ParentFaderId
		if (id == "Master" and parent ~= nil)
			or (id ~= "Master" and (parent ~= "Master" or routingConfig.Faders[parent] == nil))
		then
			return disabled(`InvalidRouteParent:{id}`, logger)
		end
		faderParents[id] = parent
	end
	for _, id in REQUIRED_TYPES do
		local route = routingConfig.Routes[id]
		local expectedKind = if id == "World" then "Spatial" else "Direct"
		if not hasExactKeys(route, exactKeys({ "PlayerType", "SourceKind", "FaderId" }))
			or route.PlayerType ~= id
			or route.SourceKind ~= expectedKind
			or route.FaderId ~= id
		then
			return disabled(`InvalidRoute:{id}`, logger)
		end
		routes[id] = table.clone(route)
	end

	if not hasOnlyKeys(spatialConfig, exactKeys({ "Version", "DefaultWorldProfileId", "Profiles" }))
		or spatialConfig.Version ~= 1
		or typeof(spatialConfig.Profiles) ~= "table"
		or getmetatable(spatialConfig.Profiles) ~= nil
	then
		return disabled("InvalidSpatialRegistry", logger)
	end
	local defaultWorldProfileId = nil
	if validIdentifier(spatialConfig.DefaultWorldProfileId, AudioSafetyLimits.MaxPlayerTypeBytes) then
		defaultWorldProfileId = spatialConfig.DefaultWorldProfileId
	else
		logger:Warn("InvalidSpatialProfile", {
			ProfileId = tostring(spatialConfig.DefaultWorldProfileId),
			ReasonCode = "InvalidDefaultWorldProfile",
		})
	end
	local profileCount = 0
	for _ in spatialConfig.Profiles do profileCount += 1 end
	if profileCount > AudioSafetyLimits.MaxSpatialProfiles then
		return disabled("SpatialProfileBudgetExceeded", logger)
	end
	profileCount = 0
	local profiles = {}
	for id, record in spatialConfig.Profiles do
		profileCount += 1
		if not validIdentifier(id, AudioSafetyLimits.MaxPlayerTypeBytes)
			or not hasOnlyKeys(record, exactKeys({ "DistanceCurve", "AngleCurve", "AcousticSimulationEnabled" }))
			or typeof(record.AcousticSimulationEnabled) ~= "boolean"
		then
			logger:Warn("InvalidSpatialProfile", { ProfileId = tostring(id), ReasonCode = "InvalidRecord" })
			continue
		end
		local distanceOk, distance = validateCurve(record.DistanceCurve, true)
		local angleOk, angle = validateCurve(record.AngleCurve, false)
		if not distanceOk or not angleOk then
			logger:Warn("InvalidSpatialProfile", { ProfileId = id, ReasonCode = "InvalidCurve" })
			continue
		end
		profiles[id] = {
			DistanceCurve = distance,
			AngleCurve = angle,
			AcousticSimulationEnabled = record.AcousticSimulationEnabled,
		}
	end
	if defaultWorldProfileId ~= nil and profiles[defaultWorldProfileId] == nil then
		logger:Warn("InvalidSpatialProfile", {
			ProfileId = defaultWorldProfileId,
			ReasonCode = "InvalidDefaultWorldProfile",
		})
		defaultWorldProfileId = nil
	end

	return DeepFreeze({
		Enabled = true,
		Config = {
			Version = 1,
			PlayerTypes = playerTypes,
			FaderProfiles = faderProfiles,
			InteractionGroupId = routingConfig.InteractionGroupId,
			FaderParentById = faderParents,
			RouteByPlayerType = routes,
			SpatialProfilesById = profiles,
			DefaultWorldProfileId = defaultWorldProfileId,
		},
	})
end

function AudioConfigValidator.levelToGain(profile: any, level01: number): number
	if level01 == 0 then
		return 0
	end
	local db = profile.MinDb + (profile.MaxDb - profile.MinDb) * level01
	return 10 ^ (db / 20)
end

return table.freeze(AudioConfigValidator)
