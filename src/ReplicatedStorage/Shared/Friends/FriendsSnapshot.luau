--!strict

local Snapshot = {}

local fields = table.freeze({
	Min = true,
	Max = true,
	Current = true,
	ConnectedCount = true,
	CanCreateReserve = true,
	IsSlotOwner = true,
	ConnectedUserIds = true,
	Reserves = true,
	IncomingOffer = true,
})

local function finiteInteger(value: any): boolean
	return typeof(value) == "number"
		and value == value
		and value ~= math.huge
		and value ~= -math.huge
		and value == math.floor(value)
end

local function finiteNonzeroInteger(value: any): boolean
	return finiteInteger(value) and value ~= 0
end

local function finiteNumber(value: any): boolean
	return typeof(value) == "number"
		and value == value
		and value ~= math.huge
		and value ~= -math.huge
end

local function denseSequence(value: any): (boolean, number)
	if typeof(value) ~= "table" or getmetatable(value) ~= nil then
		return false, 0
	end
	local count = 0
	for index in value do
		if not finiteInteger(index) or index < 1 then
			return false, 0
		end
		count += 1
	end
	for index = 1, count do
		if value[index] == nil then
			return false, 0
		end
	end
	return true, count
end

function Snapshot.validate(value: any): (boolean, any?, string?)
	if typeof(value) ~= "table" or getmetatable(value) ~= nil then
		return false, nil, "Friends snapshot must be a plain table"
	end
	for key in value do
		if typeof(key) ~= "string" or fields[key] ~= true then
			return false, nil, `Unknown Friends snapshot field '{tostring(key)}'`
		end
	end
	if not finiteInteger(value.Min) or not finiteInteger(value.Max) or value.Min < 0 or value.Max < value.Min then
		return false, nil, "Friends snapshot capacity bounds are invalid"
	end
	if not finiteInteger(value.Current) or value.Current < value.Min or value.Current > value.Max then
		return false, nil, "Friends snapshot Current is invalid"
	end
	if not finiteInteger(value.ConnectedCount) or value.ConnectedCount < 0 then
		return false, nil, "Friends snapshot ConnectedCount is invalid"
	end
	if typeof(value.CanCreateReserve) ~= "boolean" then
		return false, nil, "Friends snapshot CanCreateReserve is invalid"
	end
	if typeof(value.IsSlotOwner) ~= "boolean" then
		return false, nil, "Friends snapshot IsSlotOwner is invalid"
	end

	local connectedDense, connectedCount = denseSequence(value.ConnectedUserIds)
	if not connectedDense or connectedCount ~= value.ConnectedCount then
		return false, nil, "Friends snapshot ConnectedUserIds is invalid"
	end
	local connectedUserIds = {}
	local connectedIds = {}
	local previousUserId: number? = nil
	for index = 1, connectedCount do
		local userId = value.ConnectedUserIds[index]
		if not finiteNonzeroInteger(userId)
			or (previousUserId ~= nil and userId <= previousUserId)
		then
			return false, nil, "Friends snapshot ConnectedUserIds is invalid"
		end
		connectedIds[userId] = true
		connectedUserIds[index] = userId
		previousUserId = userId
	end

	local reservesDense, reserveCount = denseSequence(value.Reserves)
	if not reservesDense then
		return false, nil, "Friends snapshot Reserves is invalid"
	end
	local reserves = {}
	local previousReserveUserId: number? = nil
	for index = 1, reserveCount do
		local reserve = value.Reserves[index]
		if typeof(reserve) ~= "table" or getmetatable(reserve) ~= nil then
			return false, nil, "Friends snapshot reserve is invalid"
		end
		for key in reserve do
			if key ~= "TargetUserId" and key ~= "ExpiresAtServerTime" and key ~= "Kind" then
				return false, nil, "Friends snapshot reserve is invalid"
			end
		end
		local targetUserId = reserve.TargetUserId
		if not finiteInteger(targetUserId) or targetUserId <= 0
			or not finiteNumber(reserve.ExpiresAtServerTime)
			or (reserve.Kind ~= "Native" and reserve.Kind ~= "SameServer")
			or (previousReserveUserId ~= nil and targetUserId <= previousReserveUserId)
			or connectedIds[targetUserId] == true
		then
			return false, nil, "Friends snapshot reserve is invalid"
		end
		reserves[index] = table.freeze({
			TargetUserId = targetUserId,
			ExpiresAtServerTime = reserve.ExpiresAtServerTime,
			Kind = reserve.Kind,
		})
		previousReserveUserId = targetUserId
	end

	local incomingMembership = not value.IsSlotOwner and connectedCount == 1 and reserveCount == 0
	if not incomingMembership and value.ConnectedCount + reserveCount > value.Current then
		return false, nil, "Friends snapshot occupancy is invalid"
	end
	if value.CanCreateReserve
		and (not value.IsSlotOwner or value.ConnectedCount + reserveCount >= value.Current)
	then
		return false, nil, "Friends snapshot CanCreateReserve is inconsistent"
	end

	local incomingOffer = nil
	if value.IncomingOffer ~= nil then
		local offer = value.IncomingOffer
		if typeof(offer) ~= "table" or getmetatable(offer) ~= nil then
			return false, nil, "Friends snapshot IncomingOffer is invalid"
		end
		for key in offer do
			if key ~= "OfferId" and key ~= "InviterUserId" and key ~= "InviterUsername"
				and key ~= "InviterDisplayName" and key ~= "ExpiresAtServerTime" and key ~= "Status" then
				return false, nil, "Friends snapshot IncomingOffer is invalid"
			end
		end
		if typeof(offer.OfferId) ~= "string" or offer.OfferId == "" or #offer.OfferId > 100
			or not finiteNonzeroInteger(offer.InviterUserId)
			or typeof(offer.InviterUsername) ~= "string" or #offer.InviterUsername > 100
			or typeof(offer.InviterDisplayName) ~= "string" or #offer.InviterDisplayName > 100
			or not finiteNumber(offer.ExpiresAtServerTime)
			or (offer.Status ~= "Open" and offer.Status ~= "Processing") then
			return false, nil, "Friends snapshot IncomingOffer is invalid"
		end
		incomingOffer = table.freeze({
			OfferId = offer.OfferId,
			InviterUserId = offer.InviterUserId,
			InviterUsername = offer.InviterUsername,
			InviterDisplayName = offer.InviterDisplayName,
			ExpiresAtServerTime = offer.ExpiresAtServerTime,
			Status = offer.Status,
		})
	end
	if value.CanCreateReserve and incomingOffer ~= nil then
		return false, nil, "Friends snapshot CanCreateReserve is inconsistent"
	end
	return true, table.freeze({
		Min = value.Min,
		Max = value.Max,
		Current = value.Current,
		ConnectedCount = value.ConnectedCount,
		CanCreateReserve = value.CanCreateReserve,
		IsSlotOwner = value.IsSlotOwner,
		ConnectedUserIds = table.freeze(connectedUserIds),
		Reserves = table.freeze(reserves),
		IncomingOffer = incomingOffer,
	}), nil
end

function Snapshot.equal(left: any, right: any): boolean
	if typeof(left) ~= "table" or typeof(right) ~= "table" then
		return false
	end
	if left.Min ~= right.Min then
		return false
	end
	if left.Max ~= right.Max
		or left.Current ~= right.Current
		or left.ConnectedCount ~= right.ConnectedCount
		or left.CanCreateReserve ~= right.CanCreateReserve
		or left.IsSlotOwner ~= right.IsSlotOwner
		or typeof(left.ConnectedUserIds) ~= "table"
		or typeof(right.ConnectedUserIds) ~= "table"
		or typeof(left.Reserves) ~= "table"
		or typeof(right.Reserves) ~= "table"
		or ((left.IncomingOffer == nil) ~= (right.IncomingOffer == nil))
		or #left.ConnectedUserIds ~= #right.ConnectedUserIds
		or #left.Reserves ~= #right.Reserves
	then
		return false
	end
	for index, userId in left.ConnectedUserIds do
		if right.ConnectedUserIds[index] ~= userId then
			return false
		end
	end
	for index, reserve in left.Reserves do
		local other = right.Reserves[index]
		if typeof(other) ~= "table"
			or reserve.TargetUserId ~= other.TargetUserId
			or reserve.ExpiresAtServerTime ~= other.ExpiresAtServerTime
			or reserve.Kind ~= other.Kind
		then
			return false
		end
	end
	if left.IncomingOffer ~= nil then
		local leftOffer = left.IncomingOffer
		local rightOffer = right.IncomingOffer
		if leftOffer.OfferId ~= rightOffer.OfferId
			or leftOffer.InviterUserId ~= rightOffer.InviterUserId
			or leftOffer.InviterUsername ~= rightOffer.InviterUsername
			or leftOffer.InviterDisplayName ~= rightOffer.InviterDisplayName
			or leftOffer.ExpiresAtServerTime ~= rightOffer.ExpiresAtServerTime
			or leftOffer.Status ~= rightOffer.Status then
			return false
		end
	end
	return true
end

return Snapshot
