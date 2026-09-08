--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local FriendsSnapshot = require(ReplicatedStorage.Shared.Friends.FriendsSnapshot)

local Protocol = {}

Protocol.MessageTypes = table.freeze({
	RequestInvite = "Friends.RequestInvite",
	OpenPrompt = "Friends.OpenPrompt",
	PlatformResult = "Friends.PlatformResult",
	PromptClosed = "Friends.PromptClosed",
	InviteResult = "Friends.InviteResult",
	SnapshotChanged = "Friends.SnapshotChanged",
	RespondLocalOffer = "Friends.RespondLocalOffer",
	LocalOfferResult = "Friends.LocalOfferResult",
})

Protocol.InviteResultCategories = table.freeze({
	PromptRequested = true,
	LocalOfferPresented = true,
	AnotherPromptActive = true,
	AlreadyConnected = true,
	NotOwner = true,
	NotReady = true,
	NoCapacity = true,
	InviteUnavailable = true,
	TargetUnavailable = true,
	TargetIneligible = true,
	TargetBusy = true,
	NotFriends = true,
	TemporaryError = true,
	TechnicalError = true,
	Cancelled = true,
})

Protocol.LocalOfferResultCategories = table.freeze({
	Accepted = true,
	Declined = true,
	Expired = true,
	InviterUnavailable = true,
	NoCapacity = true,
	TargetIneligible = true,
	TargetBusy = true,
	NotFriends = true,
	TransferFailed = true,
	RespawnFailed = true,
	Cancelled = true,
	TechnicalError = true,
})

Protocol.LocalOfferDecisions = table.freeze({ Accept = true, Decline = true })

Protocol.PlatformResults = table.freeze({
	PromptRequested = true,
	InviteUnavailable = true,
	TemporaryError = true,
})

local function finitePositiveInteger(value: any): boolean
	return typeof(value) == "number"
		and value == value
		and value ~= math.huge
		and value ~= -math.huge
		and value == math.floor(value)
		and value > 0
end

local function exactKeys(value: any, allowed: { [string]: boolean }): boolean
	if typeof(value) ~= "table" or getmetatable(value) ~= nil then return false end
	for key in value do
		if typeof(key) ~= "string" or allowed[key] ~= true then return false end
	end
	return true
end

local function nonemptyString(value: any, maxLength: number?): boolean
	return typeof(value) == "string" and value ~= "" and (maxLength == nil or #value <= maxLength)
end

function Protocol.validateRequestInvite(value: any): (boolean, any?, string?)
	if not exactKeys(value, { TargetUserId = true }) or not finitePositiveInteger(value.TargetUserId) then
		return false, nil, "Invalid Friends.RequestInvite payload"
	end
	return true, table.freeze({ TargetUserId = value.TargetUserId }), nil
end

function Protocol.validateOpenPrompt(value: any): (boolean, any?, string?)
	if not exactKeys(value, { Generation = true, TargetUserId = true, LaunchData = true })
		or not nonemptyString(value.Generation, 100) or not finitePositiveInteger(value.TargetUserId)
		or not nonemptyString(value.LaunchData, 200) then
		return false, nil, "Invalid Friends.OpenPrompt payload"
	end
	return true, table.freeze({ Generation = value.Generation, TargetUserId = value.TargetUserId, LaunchData = value.LaunchData }), nil
end

function Protocol.validatePlatformResult(value: any): (boolean, any?, string?)
	if not exactKeys(value, { Generation = true, Result = true })
		or not nonemptyString(value.Generation, 100) or Protocol.PlatformResults[value.Result] ~= true then
		return false, nil, "Invalid Friends.PlatformResult payload"
	end
	return true, table.freeze({ Generation = value.Generation, Result = value.Result }), nil
end

function Protocol.validatePromptClosed(value: any): (boolean, any?, string?)
	if not exactKeys(value, { Generation = true }) or not nonemptyString(value.Generation, 100) then
		return false, nil, "Invalid Friends.PromptClosed payload"
	end
	return true, table.freeze({ Generation = value.Generation }), nil
end

function Protocol.validateInviteResult(value: any): (boolean, any?, string?)
	if not exactKeys(value, { Category = true, Generation = true }) and not exactKeys(value, { Category = true }) then
		return false, nil, "Invalid Friends.InviteResult payload"
	end
	if Protocol.InviteResultCategories[value.Category] ~= true
		or (value.Generation ~= nil and not nonemptyString(value.Generation, 100)) then
		return false, nil, "Invalid Friends.InviteResult category"
	end
	local result = { Category = value.Category }
	if value.Generation ~= nil then result.Generation = value.Generation end
	return true, table.freeze(result), nil
end

function Protocol.validateRespondLocalOffer(value: any): (boolean, any?, string?)
	if not exactKeys(value, { OfferId = true, Decision = true })
		or not nonemptyString(value.OfferId, 100)
		or Protocol.LocalOfferDecisions[value.Decision] ~= true then
		return false, nil, "Invalid Friends.RespondLocalOffer payload"
	end
	return true, table.freeze({ OfferId = value.OfferId, Decision = value.Decision }), nil
end

function Protocol.validateLocalOfferResult(value: any): (boolean, any?, string?)
	if not exactKeys(value, { OfferId = true, Category = true })
		or not nonemptyString(value.OfferId, 100)
		or Protocol.LocalOfferResultCategories[value.Category] ~= true then
		return false, nil, "Invalid Friends.LocalOfferResult payload"
	end
	return true, table.freeze({ OfferId = value.OfferId, Category = value.Category }), nil
end

function Protocol.validateSnapshotChanged(value: any): (boolean, any?, string?)
	if not exactKeys(value, { Previous = true, Current = true }) then
		return false, nil, "Invalid Friends.SnapshotChanged payload"
	end
	local previousValid, previous, previousReason = FriendsSnapshot.validate(value.Previous)
	if not previousValid then return false, nil, previousReason end
	local currentValid, current, currentReason = FriendsSnapshot.validate(value.Current)
	if not currentValid then return false, nil, currentReason end
	return true, table.freeze({ Previous = previous, Current = current }), nil
end

return table.freeze(Protocol)
