--!strict

local MAX_IDENTIFIER_LENGTH = 64
local MAX_FAILURE_LENGTH = 160

local function isFiniteInteger(value: any, minimum: number): boolean
	return typeof(value) == "number"
		and value == value
		and value ~= math.huge
		and value ~= -math.huge
		and value % 1 == 0
		and value >= minimum
end

local function isPlayerUserId(value: any): boolean
	-- Studio Server & Clients assigns negative IDs to simulated players.
	return typeof(value) == "number"
		and value == value
		and value ~= math.huge
		and value ~= -math.huge
		and value % 1 == 0
		and value ~= 0
end

local function isCanonicalGuid(value: any): boolean
	if typeof(value) ~= "string" or #value ~= 36 then
		return false
	end
	if string.sub(value, 9, 9) ~= "-"
		or string.sub(value, 14, 14) ~= "-"
		or string.sub(value, 19, 19) ~= "-"
		or string.sub(value, 24, 24) ~= "-"
	then
		return false
	end
	local compact = string.gsub(value, "%-", "")
	return #compact == 32 and string.match(compact, "^[%da-fA-F]+$") ~= nil
end

local function isPlainDictionary(value: any, allowedKeys: { [string]: boolean }): boolean
	if typeof(value) ~= "table" or getmetatable(value) ~= nil then
		return false
	end
	for key in value do
		if typeof(key) ~= "string" or not allowedKeys[key] then
			return false
		end
	end
	return true
end

local function validateSession(value: any): (boolean, any?, string?)
	if not isPlainDictionary(value, {
		SessionId = true,
		EntryKind = true,
		SourcePlaceId = true,
	}) then
		return false, nil, "InvalidSessionShape"
	end
	if not isCanonicalGuid(value.SessionId) then
		return false, nil, "InvalidSessionId"
	end
	if value.EntryKind ~= "External" and value.EntryKind ~= "Teleported" then
		return false, nil, "InvalidEntryKind"
	end
	if value.SourcePlaceId ~= nil and not isFiniteInteger(value.SourcePlaceId, 1) then
		return false, nil, "InvalidSourcePlaceId"
	end
	if value.EntryKind == "External" and value.SourcePlaceId ~= nil then
		return false, nil, "ExternalSourcePlaceId"
	end
	if value.EntryKind == "Teleported" and value.SourcePlaceId == nil then
		return false, nil, "MissingSourcePlaceId"
	end
	return true, {
		SessionId = value.SessionId,
		EntryKind = value.EntryKind,
		SourcePlaceId = value.SourcePlaceId,
	}, nil
end

local function validateAttempt(value: any): (boolean, any?, string?)
	if not isPlainDictionary(value, {
		AttemptId = true,
		State = true,
		DestinationKind = true,
		PlaceId = true,
	}) then
		return false, nil, "InvalidAttemptShape"
	end
	if not isCanonicalGuid(value.AttemptId) then
		return false, nil, "InvalidAttemptId"
	end
	if value.State ~= "Started" and value.State ~= "Accepted" then
		return false, nil, "InvalidAttemptState"
	end
	if typeof(value.DestinationKind) ~= "string"
		or #value.DestinationKind == 0
		or #value.DestinationKind > MAX_IDENTIFIER_LENGTH
	then
		return false, nil, "InvalidDestinationKind"
	end
	if not isFiniteInteger(value.PlaceId, 1) then
		return false, nil, "InvalidPlaceId"
	end
	return true, {
		AttemptId = value.AttemptId,
		State = value.State,
		DestinationKind = value.DestinationKind,
		PlaceId = value.PlaceId,
	}, nil
end

local function validateAppearance(value: any): (boolean, any?, string?)
	if not isPlainDictionary(value, {
		UserId = true,
		EntryKind = true,
		SourcePlaceId = true,
	}) then
		return false, nil, "InvalidAppearanceShape"
	end
	if not isPlayerUserId(value.UserId) then
		return false, nil, "InvalidUserId"
	end
	if value.EntryKind ~= "External" and value.EntryKind ~= "Teleported" then
		return false, nil, "InvalidEntryKind"
	end
	if value.SourcePlaceId ~= nil and not isFiniteInteger(value.SourcePlaceId, 1) then
		return false, nil, "InvalidSourcePlaceId"
	end
	if value.EntryKind == "External" and value.SourcePlaceId ~= nil then
		return false, nil, "ExternalSourcePlaceId"
	end
	if value.EntryKind == "Teleported" and value.SourcePlaceId == nil then
		return false, nil, "MissingSourcePlaceId"
	end
	return true, {
		UserId = value.UserId,
		EntryKind = value.EntryKind,
		SourcePlaceId = value.SourcePlaceId,
	}, nil
end

local function validateDeparture(value: any): (boolean, any?, string?)
	if not isPlainDictionary(value, { UserId = true }) or not isPlayerUserId(value.UserId) then
		return false, nil, "InvalidDeparture"
	end
	return true, { UserId = value.UserId }, nil
end

local function validateFailure(value: any): (boolean, any?, string?)
	if not isPlainDictionary(value, {
		AttemptId = true,
		Code = true,
		Error = true,
	}) then
		return false, nil, "InvalidFailureShape"
	end
	if not isCanonicalGuid(value.AttemptId) then
		return false, nil, "InvalidAttemptId"
	end
	if typeof(value.Code) ~= "string" or #value.Code == 0 or #value.Code > MAX_IDENTIFIER_LENGTH then
		return false, nil, "InvalidFailureCode"
	end
	if typeof(value.Error) ~= "string" or #value.Error > MAX_FAILURE_LENGTH then
		return false, nil, "InvalidFailureError"
	end
	return true, {
		AttemptId = value.AttemptId,
		Code = value.Code,
		Error = value.Error,
	}, nil
end

local function validateEmptyRequest(value: any): (boolean, any?, string?)
	if value == nil then
		return true, {}, nil
	end
	if typeof(value) ~= "table" or getmetatable(value) ~= nil or next(value) ~= nil then
		return false, nil, "ExpectedEmptyRequest"
	end
	return true, {}, nil
end

local function validateBootstrap(value: any, maxPresentPlayers: number): (boolean, any?, string?)
	if not isFiniteInteger(maxPresentPlayers, 0) then
		return false, nil, "InvalidMaxPresentPlayers"
	end
	if not isPlainDictionary(value, {
		Arrival = true,
		Attempt = true,
		PresentPlayers = true,
	}) then
		return false, nil, "InvalidBootstrapShape"
	end
	local arrivalOk, arrival = validateSession(value.Arrival)
	if not arrivalOk then
		return false, nil, "InvalidBootstrapArrival"
	end
	local attempt = nil
	if value.Attempt ~= nil then
		local attemptOk, sanitizedAttempt = validateAttempt(value.Attempt)
		if not attemptOk then
			return false, nil, "InvalidBootstrapAttempt"
		end
		attempt = sanitizedAttempt
	end
	if typeof(value.PresentPlayers) ~= "table" or getmetatable(value.PresentPlayers) ~= nil then
		return false, nil, "InvalidPresentPlayers"
	end
	local presentPlayers = {}
	local count = 0
	for key, appearance in value.PresentPlayers do
		if not isFiniteInteger(key, 1) then
			return false, nil, "InvalidPresentPlayers"
		end
		count += 1
		if count > maxPresentPlayers then
			return false, nil, "TooManyPresentPlayers"
		end
		local appearanceOk, sanitizedAppearance = validateAppearance(appearance)
		if not appearanceOk then
			return false, nil, "InvalidPresentPlayer"
		end
		presentPlayers[key] = sanitizedAppearance
	end
	for index = 1, count do
		if presentPlayers[index] == nil then
			return false, nil, "SparsePresentPlayers"
		end
	end
	return true, {
		Arrival = arrival,
		Attempt = attempt,
		PresentPlayers = presentPlayers,
	}, nil
end

return table.freeze({
	EnvelopeKey = "TeleportModule",
	EnvelopeVersion = 1,
	RequestTypes = table.freeze({
		Bootstrap = "Teleport.Bootstrap",
	}),
	MessageTypes = table.freeze({
		LocalAttemptStarted = "Teleport.LocalAttemptStarted",
		LocalAttemptAccepted = "Teleport.LocalAttemptAccepted",
		LocalAttemptFailed = "Teleport.LocalAttemptFailed",
		LocalArrived = "Teleport.LocalArrived",
		PlayerAppeared = "Teleport.PlayerAppeared",
		PlayerDeparted = "Teleport.PlayerDeparted",
	}),
	ValidateSessionSnapshot = validateSession,
	ValidateAttemptSnapshot = validateAttempt,
	ValidateAppearance = validateAppearance,
	ValidateDeparture = validateDeparture,
	ValidateFailure = validateFailure,
	ValidateEmptyRequest = validateEmptyRequest,
	ValidateBootstrapResponse = validateBootstrap,
	IsCanonicalGuid = isCanonicalGuid,
})
