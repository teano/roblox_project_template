--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local FriendsProtocol = require(ReplicatedStorage.Shared.Friends.FriendsProtocol)
local FriendsSnapshot = require(ReplicatedStorage.Shared.Friends.FriendsSnapshot)
local CommunicationProtocol = require(ReplicatedStorage.Shared.Communication.CommunicationProtocol)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local TableUtil = require(ReplicatedStorage.Shared.Util.TableUtil)

local FriendsModule = {}
FriendsModule.__index = FriendsModule

local RECENT_ID_LIMIT = 64
local RECENT_ID_TTL_SECONDS = 300
local CAPABILITY_LIMIT = 32
local LOCAL_TRANSFER_TIMEOUT_SECONDS = 30
local INVITE_ATTEMPT_TIMEOUT_SECONDS = 10

local LOCAL_FAILURES = table.freeze({
	InviterUnavailable = true, NoCapacity = true, TargetIneligible = true, TargetBusy = true,
	NotFriends = true, TransferFailed = true, RespawnFailed = true, Cancelled = true, TechnicalError = true,
})

local function finiteInteger(value: any): boolean
	return typeof(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
		and value == math.floor(value)
end

local function exactOrdinaryInput(value: any): boolean
	if typeof(value) ~= "table" or getmetatable(value) ~= nil or value.Kind ~= "Ordinary" then return false end
	for key in value do if key ~= "Kind" then return false end end
	return true
end

local function exactInvitationInput(value: any): boolean
	if typeof(value) ~= "table" or getmetatable(value) ~= nil or value.Kind ~= "Invitation"
		or typeof(value.Token) ~= "string" or value.Token == ""
		or typeof(value.TargetJobId) ~= "string" or value.TargetJobId == "" then return false end
	for key in value do if key ~= "Kind" and key ~= "Token" and key ~= "TargetJobId" then return false end end
	return true
end

function FriendsModule.new(deps: any)
	assert(typeof(deps) == "table" and deps.Config ~= nil and deps.PlayerSlots ~= nil, "FriendsModule dependencies required")
	local generated = 0
	local generateId = deps.GenerateId or function() generated += 1; return `friends-{generated}` end
	return setmetatable({
		Id = "Friends", Version = 1, Authority = "Server",
		_configCatalog = deps.Config,
		_playerSlots = deps.PlayerSlots,
		_players = deps.PlayersModule,
		_communication = deps.Communication,
		_generateId = generateId,
		_encodeJson = deps.EncodeJson,
		_jobId = deps.JobId or game.JobId,
		_clock = deps.Clock or os.clock,
		_delay = deps.Delay or function(seconds: number, callback: () -> ()) task.delay(seconds, callback) end,
		_spawn = deps.Spawn or function(callback: () -> ()) task.spawn(callback) end,
		_checkFriendship = deps.CheckFriendship or function(inviter: Player, targetUserId: number)
			return inviter:IsFriendsWithAsync(targetUserId)
		end,
		_canCreateLocalOffer = deps.CanCreateLocalOffer,
		_localTransferHandler = nil,
		_config = nil,
		_data = {},
		_running = {},
		_operations = {},
		_localTransfers = {},
		_holdsByInviter = {},
		_capabilitiesByInviter = {},
		_capabilitiesByToken = {},
		_relations = {},
		_requests = {},
		_responseRequests = {},
		_recentRequestIds = {},
		_recentResponseIds = {},
		_activePrompts = {},
		_activeChecks = {},
		_incomingOffers = {},
		_offersById = {},
		_capabilitySequence = 0,
		_departures = {},
		_state = "fresh",
		_handlersRegistered = false,
		MementoChanged = Signal.new(),
		SnapshotChanged = Signal.new(),
	}, FriendsModule)
end

function FriendsModule:BindLocalTransferHandler(handler: any)
	assert(self._localTransferHandler == nil, "Friends local transfer handler already bound")
	assert(typeof(handler) == "function", "Friends local transfer handler must be a function")
	self._localTransferHandler = handler
end

function FriendsModule:_makeLaunchData(token: string): (string?, string?)
	if typeof(self._jobId) ~= "string" or self._jobId == "" or self._encodeJson == nil then return nil, "LaunchDataUnavailable" end
	local ok, launchData = pcall(self._encodeJson, { Version = 1, Token = token, TargetJobId = self._jobId })
	if not ok or typeof(launchData) ~= "string" or #launchData > 200 then return nil, "LaunchDataInvalid" end
	return launchData, nil
end

function FriendsModule:_holdCount(player: Player): number
	local holds = self._holdsByInviter[player]
	if holds == nil then return 0 end
	local count = 0
	for _, hold in holds do if hold.State == "Open" or hold.State == "Claimed" then count += 1 end end
	return count
end

function FriendsModule:_connectedCount(player: Player): number
	local relations = self._relations[player]
	if relations == nil then return 0 end
	local count = 0
	for _ in relations do count += 1 end
	return count
end

function FriendsModule:_hasOpenLocalOffer(player: Player): boolean
	local holds = self._holdsByInviter[player]
	if holds == nil then return false end
	for _, hold in holds do
		if hold.Kind == "SameServer" and (hold.State == "Open" or hold.State == "Claimed") then return true end
	end
	return false
end

function FriendsModule:_connectedUserIds(player: Player): { number }
	local result = {}
	local relations = self._relations[player]
	if relations ~= nil then
		for friend in relations do
			assert(finiteInteger(friend.UserId) and friend.UserId ~= 0, "Friends relation user ID is invalid")
			table.insert(result, friend.UserId)
		end
	end
	table.sort(result)
	return result
end

function FriendsModule:_holdSnapshotEntries(player: Player): { any }
	local result = {}
	local holds = self._holdsByInviter[player]
	if holds ~= nil then
		for _, hold in holds do
			if hold.State == "Open" or hold.State == "Claimed" then
				table.insert(result, {
					TargetUserId = hold.TargetUserId,
					ExpiresAtServerTime = hold.Deadline,
					Kind = hold.Kind,
				})
			end
		end
	end
	table.sort(result, function(left, right) return left.TargetUserId < right.TargetUserId end)
	return result
end

function FriendsModule:_isSlotOwner(player: Player): boolean
	if self._state ~= "active" or self._running[player] ~= true then return false end
	local transfer = self._localTransfers[player]
	if transfer ~= nil and (transfer.Stage == "Prepared" or transfer.Stage == "Committed") then
		return transfer.PreviousTargetIsSlotOwner
	end
	local called, relation = pcall(function() return self._playerSlots:GetPlayerSlot(player) end)
	return called and typeof(relation) == "table" and relation.Role == "Owner"
end

function FriendsModule:_snapshot(player: Player, current: number?): any
	local config = assert(self._config, "FriendsModule is not initialized")
	local data = self._data[player]
	local capacity = if current ~= nil then current else if data ~= nil then data.Current else config.MinInviteCapacity
	local slotState = "NotReady"
	if self._state == "active" and self._running[player] == true then
		local called, value = pcall(function() return self._playerSlots:CanCreateInvitation(player) end)
		if called then slotState = value end
	end
	local connectedUserIds = self:_connectedUserIds(player)
	local holds = self:_holdSnapshotEntries(player)
	local isSlotOwner = self:_isSlotOwner(player)
	local incoming = self._incomingOffers[player]
	local incomingSnapshot = nil
	if incoming ~= nil and incoming.State ~= "Terminal" then
		incomingSnapshot = {
			OfferId = incoming.OfferId,
			InviterUserId = incoming.Inviter.UserId,
			InviterUsername = if typeof(incoming.Inviter.Name) == "string" then incoming.Inviter.Name else tostring(incoming.Inviter.UserId),
			InviterDisplayName = if typeof(incoming.Inviter.DisplayName) == "string" then incoming.Inviter.DisplayName else tostring(incoming.Inviter.UserId),
			ExpiresAtServerTime = incoming.Hold.Deadline,
			Status = incoming.State,
		}
	end
	local canCreate = self._state == "active" and self._running[player] == true and isSlotOwner
		and slotState == "Allowed" and #connectedUserIds + #holds < capacity and incomingSnapshot == nil
		and self._activeChecks[player] == nil and self._activePrompts[player] == nil
		and not self:_hasOpenLocalOffer(player)
	local valid, snapshot, reason = FriendsSnapshot.validate({
		Min = config.MinInviteCapacity, Max = config.MaxInviteCapacity, Current = capacity,
		ConnectedCount = #connectedUserIds, CanCreateReserve = canCreate, IsSlotOwner = isSlotOwner,
		ConnectedUserIds = connectedUserIds, Reserves = holds, IncomingOffer = incomingSnapshot,
	})
	assert(valid, reason)
	return snapshot
end

function FriendsModule:_queue(player: Player, messageType: string, payload: any, requestId: string?, priority: string): boolean
	if self._communication == nil then return false end
	local ok, accepted = pcall(function()
		return self._communication:Queue(player, messageType, payload, requestId, { Priority = priority })
	end)
	return ok and accepted == true
end

function FriendsModule:_publishSnapshot(player: Player, previous: any, current: any)
	if FriendsSnapshot.equal(previous, current) then return end
	local payload = table.freeze({ Previous = previous, Current = current })
	self.SnapshotChanged:Fire(player, payload)
	self:_queue(player, FriendsProtocol.MessageTypes.SnapshotChanged, payload, nil, CommunicationProtocol.Priorities.State)
end

function FriendsModule:_isRecent(recentByPlayer: any, player: Player, requestId: string): boolean
	local recent = recentByPlayer[player]
	if recent == nil then return false end
	local now = self._clock()
	while #recent.Order > 0 do
		local first = recent.Order[1]
		if first.Deadline > now and #recent.Order <= RECENT_ID_LIMIT then break end
		table.remove(recent.Order, 1)
		if recent.ById[first.Id] == first then recent.ById[first.Id] = nil end
	end
	return recent.ById[requestId] ~= nil
end

function FriendsModule:_remember(recentByPlayer: any, player: Player, requestId: string)
	local recent = recentByPlayer[player]
	if recent == nil then recent = { ById = {}, Order = {} }; recentByPlayer[player] = recent end
	local record = { Id = requestId, Deadline = self._clock() + RECENT_ID_TTL_SECONDS }
	recent.ById[requestId] = record
	table.insert(recent.Order, record)
	self:_isRecent(recentByPlayer, player, requestId)
end

function FriendsModule:_recordRequest(player: Player, requestId: string): any?
	if requestId == "" or self:_isRecent(self._recentRequestIds, player, requestId) then return nil end
	local requests = self._requests[player]
	if requests == nil then requests = {}; self._requests[player] = requests end
	if requests[requestId] ~= nil then return nil end
	local request = { Stage = "Pending", Player = player, RequestId = requestId, Deadline = self._clock() + INVITE_ATTEMPT_TIMEOUT_SECONDS }
	requests[requestId] = request
	return request
end

function FriendsModule:_finishRequest(player: Player, request: any?, category: string, generation: string?)
	if request == nil or request.Stage ~= "Pending" then return end
	request.Stage = "Terminal"
	local requests = self._requests[player]
	if requests ~= nil and requests[request.RequestId] == request then requests[request.RequestId] = nil end
	self:_remember(self._recentRequestIds, player, request.RequestId)
	local payload = { Category = category }
	if generation ~= nil then payload.Generation = generation end
	local valid, checked = FriendsProtocol.validateInviteResult(payload)
	if valid then self:_queue(player, FriendsProtocol.MessageTypes.InviteResult, checked, request.RequestId, CommunicationProtocol.Priorities.State) end
	local provisional = request.ProvisionalHold
	if provisional ~= nil and not provisional.Confirmed then self:_removeHold(provisional, nil, true) end
end

function FriendsModule:_recordResponseRequest(player: Player, requestId: string, offerId: string): any?
	if requestId == "" or self:_isRecent(self._recentResponseIds, player, requestId) then return nil end
	local requests = self._responseRequests[player]
	if requests == nil then requests = {}; self._responseRequests[player] = requests end
	if requests[requestId] ~= nil then return nil end
	local request = { Stage = "Pending", Player = player, RequestId = requestId, OfferId = offerId }
	requests[requestId] = request
	return request
end

function FriendsModule:_finishResponseRequest(request: any?, category: string)
	if request == nil or request.Stage ~= "Pending" then return end
	request.Stage = "Terminal"
	local requests = self._responseRequests[request.Player]
	if requests ~= nil and requests[request.RequestId] == request then requests[request.RequestId] = nil end
	self:_remember(self._recentResponseIds, request.Player, request.RequestId)
	self:_sendLocalResult(request.Player, request.OfferId, category, request.RequestId)
end

function FriendsModule:_sendLocalResult(target: Player, offerId: string, category: string, requestId: string?)
	local valid, checked = FriendsProtocol.validateLocalOfferResult({ OfferId = offerId, Category = category })
	if valid then self:_queue(target, FriendsProtocol.MessageTypes.LocalOfferResult, checked, requestId, CommunicationProtocol.Priorities.State) end
end

function FriendsModule:_removeHold(hold: any, category: string?, publish: boolean)
	if hold == nil or (hold.State ~= "Open" and hold.State ~= "Claimed") then return end
	if hold.Offer ~= nil and hold.Offer.State ~= "Terminal" then
		self:_terminalizeLocalOffer(hold.Offer, category or "Cancelled", nil)
		return
	end
	local inviter = hold.Inviter
	local previous = if publish and self._running[inviter] == true then self:_snapshot(inviter) else nil
	hold.State = "Terminal"
	local holds = self._holdsByInviter[inviter]
	if holds ~= nil and holds[hold.TargetUserId] == hold then holds[hold.TargetUserId] = nil end
	local prompt = self._activePrompts[inviter]
	if prompt ~= nil and prompt.Hold == hold and prompt.Provisional then
		self._activePrompts[inviter] = nil
		prompt.Retired = true
		self:_finishRequest(inviter, prompt.Request, category or "Cancelled", nil)
	end
	if category ~= nil then self:_finishRequest(inviter, hold.Request, category, nil) end
	if previous ~= nil then self:_publishSnapshot(inviter, previous, self:_snapshot(inviter)) end
end

function FriendsModule:_terminalizeLocalOffer(offer: any, category: string, previousByPlayer: any?)
	if offer == nil or offer.State == "Terminal" then return end
	local inviter, target, hold = offer.Inviter, offer.Target, offer.Hold
	local previous = previousByPlayer or {}
	if previous[inviter] == nil and self._running[inviter] == true then previous[inviter] = self:_snapshot(inviter) end
	if previous[target] == nil and self._running[target] == true then previous[target] = self:_snapshot(target) end
	offer.State = "Terminal"
	hold.State = "Terminal"
	if self._incomingOffers[target] == offer then self._incomingOffers[target] = nil end
	if self._offersById[offer.OfferId] == offer then self._offersById[offer.OfferId] = nil end
	local holds = self._holdsByInviter[inviter]
	if holds ~= nil and holds[hold.TargetUserId] == hold then holds[hold.TargetUserId] = nil end
	self:_finishResponseRequest(offer.ResponseRequest, category)
	for player, snapshot in previous do
		if self._running[player] == true and self._data[player] ~= nil then
			self:_publishSnapshot(player, snapshot, self:_snapshot(player))
		end
	end
end

function FriendsModule:_expireHold(hold: any)
	if self._state ~= "active" or hold.State ~= "Open" or self._clock() < hold.Deadline then return end
	if hold.Kind == "Native" and hold.Confirmed then
		local prompt = self._activePrompts[hold.Inviter]
		local check = self._activeChecks[hold.Inviter]
		local request = if prompt ~= nil and prompt.Hold == hold then prompt.Request
			else if check ~= nil and check.TargetUserId == hold.TargetUserId then check.Request else nil
		local holds = self._holdsByInviter[hold.Inviter]
		if request ~= nil and request.Stage == "Pending" and self._clock() < request.Deadline
			and holds ~= nil and holds[hold.TargetUserId] == hold then
			local previous = self:_snapshot(hold.Inviter)
			local provisional = {
				Kind = "Native", Inviter = hold.Inviter, TargetUserId = hold.TargetUserId, Capability = hold.Capability,
				Generation = if prompt ~= nil then prompt.Generation else check.Generation,
				Deadline = request.Deadline, Confirmed = false, State = "Open", Request = request,
			}
			hold.State = "Terminal"
			holds[hold.TargetUserId] = provisional
			request.ProvisionalHold = provisional
			if prompt ~= nil then prompt.Hold, prompt.Provisional = provisional, true end
			self:_publishSnapshot(hold.Inviter, previous, self:_snapshot(hold.Inviter))
			return
		end
	end
	if hold.Offer ~= nil then
		if hold.Offer.State == "Open" then self:_terminalizeLocalOffer(hold.Offer, "Expired", nil) end
	else
		self:_removeHold(hold, "Cancelled", true)
	end
end

function FriendsModule:_expireHolds(player: Player?)
	if player ~= nil then
		local check = self._activeChecks[player]
		if check ~= nil and self._clock() >= check.Deadline then
			self:_finishFriendshipCheck(player, check)
			self:_finishRequest(player, check.Request, "TemporaryError", nil)
		end
		local prompt = self._activePrompts[player]
		if prompt ~= nil and self._clock() >= prompt.Deadline then
			self:_retireNativePrompt(player, prompt, "TemporaryError")
		end
		local holds = self._holdsByInviter[player]
		if holds ~= nil then
			local pending = {}; for _, hold in holds do table.insert(pending, hold) end
			for _, hold in pending do self:_expireHold(hold) end
		end
		local incoming = self._incomingOffers[player]
		if incoming ~= nil then self:_expireHold(incoming.Hold) end
		return
	end
	for inviter in self._holdsByInviter do self:_expireHolds(inviter) end
end

function FriendsModule:_scheduleHoldExpiry(hold: any)
	local generation = hold.Generation
	hold.ExpiryScheduleId = (hold.ExpiryScheduleId or 0) + 1
	local scheduleId = hold.ExpiryScheduleId
	local function waitUntilDeadline()
		self._delay(math.max(0, hold.Deadline - self._clock()), function()
			if self._state ~= "active" or hold.State ~= "Open" or hold.Generation ~= generation
				or hold.ExpiryScheduleId ~= scheduleId then return end
			if self._clock() < hold.Deadline then waitUntilDeadline(); return end
			self:_expireHold(hold)
		end)
	end
	waitUntilDeadline()
end

function FriendsModule:_registerProtocolHandlers()
	if self._handlersRegistered or self._communication == nil then return end
	self._communication:RegisterHandler(FriendsProtocol.MessageTypes.RequestInvite, FriendsProtocol.validateRequestInvite,
		function(player: Player, payload: any, requestId: string?) self:RequestInvite(player, payload, requestId) end)
	self._communication:RegisterHandler(FriendsProtocol.MessageTypes.PlatformResult, FriendsProtocol.validatePlatformResult,
		function(player: Player, payload: any, requestId: string?) self:HandlePlatformResult(player, payload, requestId) end)
	self._communication:RegisterHandler(FriendsProtocol.MessageTypes.PromptClosed, FriendsProtocol.validatePromptClosed,
		function(player: Player, payload: any, requestId: string?) self:HandlePromptClosed(player, payload, requestId) end)
	self._communication:RegisterHandler(FriendsProtocol.MessageTypes.RespondLocalOffer, FriendsProtocol.validateRespondLocalOffer,
		function(player: Player, payload: any, requestId: string?) self:RespondLocalOffer(player, payload, requestId) end)
	self._handlersRegistered = true
end

function FriendsModule:Initialize()
	if self._state == "active" then return end
	if self._state == "stopped" then error("FriendsModuleStopped", 2) end
	self._config = self._configCatalog:GetRequired("Friends")
	self._state = "active"
	self:_registerProtocolHandlers()
end

function FriendsModule:CreateDefault(_player: Player): any
	return { Current = assert(self._config, "FriendsModule is not initialized").MinInviteCapacity }
end

function FriendsModule:ReconcileMemento(_player: Player, value: any, _fromVersion: number): any
	local config = assert(self._config, "FriendsModule is not initialized")
	if typeof(value) ~= "table" or getmetatable(value) ~= nil then return value end
	local result = TableUtil.deepCopy(value)
	if result.Current == nil then result.Current = config.MinInviteCapacity
	elseif finiteInteger(result.Current) then result.Current = math.clamp(result.Current, config.MinInviteCapacity, config.MaxInviteCapacity) end
	return result
end

function FriendsModule:ValidateMemento(_player: Player, value: any): (boolean, any?, string?)
	if typeof(value) ~= "table" or getmetatable(value) ~= nil then return false, nil, "Friends memento must be a plain table" end
	for key in value do if key ~= "Current" then return false, nil, `Unknown Friends memento field '{tostring(key)}'` end end
	local config = assert(self._config, "FriendsModule is not initialized")
	if not finiteInteger(value.Current) then return false, nil, "Friends Current must be a finite integer" end
	if value.Current < config.MinInviteCapacity or value.Current > config.MaxInviteCapacity then return false, nil, "Friends Current is outside configured capacity" end
	return true, { Current = value.Current }, nil
end

function FriendsModule:SetMemento(player: Player, value: any) self._data[player] = TableUtil.deepCopy(value) end
function FriendsModule:GetMemento(player: Player): any return TableUtil.deepCopy(assert(self._data[player], "Friends memento is not set")) end
function FriendsModule:BeforeMementoGet(_player: Player) end

function FriendsModule:Run(player: Player)
	assert(self._state == "active", "FriendsModule is not initialized")
	assert(self._data[player] ~= nil, "Friends memento is not set")
	self._running[player] = true
end

function FriendsModule:ToClientMemento(player: Player, value: any): any return self:_snapshot(player, value.Current) end

function FriendsModule:GetSnapshot(player: Player): any
	if self._state == "stopped" then return table.freeze({ Ok = false, Error = "Stopped" }) end
	if self._state ~= "active" or self._running[player] ~= true or self._data[player] == nil then return table.freeze({ Ok = false, Error = "NotReady" }) end
	self:_expireHolds(player)
	return table.freeze({ Ok = true, Snapshot = self:_snapshot(player) })
end

function FriendsModule:SetCurrent(player: Player, value: any): any
	if self._state == "stopped" then return table.freeze({ Ok = false, Error = "Stopped" }) end
	if self._state ~= "active" or self._running[player] ~= true or self._data[player] == nil then return table.freeze({ Ok = false, Error = "NotReady" }) end
	if not finiteInteger(value) then return table.freeze({ Ok = false, Error = "InvalidValue" }) end
	self:_expireHolds(player)
	local connectedCount, holdCount = self:_connectedCount(player), self:_holdCount(player)
	local incomingMembership = not self:_isSlotOwner(player) and connectedCount == 1 and holdCount == 0
	local occupiedCapacity = if incomingMembership then 0 else connectedCount + holdCount
	if value < occupiedCapacity then return table.freeze({ Ok = false, Error = "InsufficientCapacity" }) end
	local config = assert(self._config)
	if value < config.MinInviteCapacity or value > config.MaxInviteCapacity then return table.freeze({ Ok = false, Error = "OutOfRange" }) end
	local data = self._data[player]
	if data.Current == value then return table.freeze({ Ok = true, Changed = false }) end
	local previous = self:_snapshot(player)
	data.Current = value
	self.MementoChanged:Fire(player)
	self:_publishSnapshot(player, previous, self:_snapshot(player))
	return table.freeze({ Ok = true, Changed = true })
end

function FriendsModule:_requestPrecheck(player: Player, targetUserId: number, request: any): string?
	if targetUserId == player.UserId then return "TechnicalError" end
	local invitationState = self._playerSlots:CanCreateInvitation(player)
	if invitationState == "NotOwner" then return "NotOwner" end
	if invitationState ~= "Allowed" then return "NotReady" end
	if self._activeChecks[player] ~= nil or self._activePrompts[player] ~= nil then return "AnotherPromptActive" end
	if self:_hasOpenLocalOffer(player) then return "AnotherPromptActive" end
	if self._incomingOffers[player] ~= nil then return "AnotherPromptActive" end
	local relations = self._relations[player]
	if relations ~= nil then
		for connected in relations do if connected.UserId == targetUserId then return "AlreadyConnected" end end
	end
	local holds = self._holdsByInviter[player]
	local existing = if holds ~= nil then holds[targetUserId] else nil
	if existing ~= nil and (existing.Kind ~= "Native" or existing.State ~= "Open") then return "AnotherPromptActive" end
	local additionalHold = if existing == nil then 1 else 0
	if self:_connectedCount(player) + self:_holdCount(player) + additionalHold > self._data[player].Current then return "NoCapacity" end
	request.TargetUserId = targetUserId
	return nil
end

function FriendsModule:_normalizeLocalEligibility(inviter: Player, target: Player): (boolean, string?)
	if self._canCreateLocalOffer == nil then return false, "TargetIneligible" end
	local ok, result, reason = pcall(self._canCreateLocalOffer, inviter, target)
	if not ok then return false, "TechnicalError" end
	if result == true or result == "Allowed" or (typeof(result) == "table" and result.Ok == true) then return true, nil end
	local category = if typeof(result) == "table" then result.Error else if typeof(reason) == "string" then reason else result
	if category == "NoCapacity" or category == "TargetBusy" or category == "NotFriends" then return false, category end
	return false, "TargetIneligible"
end

function FriendsModule:_createLocalOffer(inviter: Player, target: Player, request: any)
	local precheck = self:_requestPrecheck(inviter, target.UserId, request)
	if precheck ~= nil then self:_finishRequest(inviter, request, precheck, nil); return end
	if self._incomingOffers[target] ~= nil or self._activeChecks[target] ~= nil or self._activePrompts[target] ~= nil
		or self:_holdCount(target) > 0 then
		self:_finishRequest(inviter, request, "TargetBusy", nil)
		return
	end
	local eligible, eligibilityError = self:_normalizeLocalEligibility(inviter, target)
	if not eligible then self:_finishRequest(inviter, request, eligibilityError or "TargetIneligible", nil); return end
	local offerId, generation, claimId = self._generateId(), self._generateId(), self._generateId()
	if typeof(offerId) ~= "string" or offerId == "" or typeof(generation) ~= "string" or generation == ""
		or typeof(claimId) ~= "string" or claimId == "" then
		self:_finishRequest(inviter, request, "TechnicalError", nil)
		return
	end
	local previousInviter, previousTarget = self:_snapshot(inviter), self:_snapshot(target)
	local hold = {
		Kind = "SameServer", Inviter = inviter, TargetUserId = target.UserId, Generation = generation,
		ClaimId = claimId, Deadline = self._clock() + self._config.ReserveLifetimeSeconds,
		State = "Open", Request = request,
	}
	local offer = { OfferId = offerId, Inviter = inviter, Target = target, Hold = hold, State = "Open" }
	hold.Offer = offer
	local holds = self._holdsByInviter[inviter]
	if holds == nil then holds = {}; self._holdsByInviter[inviter] = holds end
	local existing = holds[target.UserId]
	if existing ~= nil then existing.State = "Terminal" end
	holds[target.UserId] = hold
	self._incomingOffers[target] = offer
	self._offersById[offerId] = offer
	self:_publishSnapshot(inviter, previousInviter, self:_snapshot(inviter))
	self:_publishSnapshot(target, previousTarget, self:_snapshot(target))
	self:_scheduleHoldExpiry(hold)
	self:_finishRequest(inviter, request, "LocalOfferPresented", generation)
end

function FriendsModule:_finishFriendshipCheck(player: Player, check: any)
	if self._activeChecks[player] ~= check then return end
	local previous = if self._state == "active" and self._running[player] == true and self._data[player] ~= nil
		then self:_snapshot(player) else nil
	self._activeChecks[player] = nil
	if previous ~= nil then self:_publishSnapshot(player, previous, self:_snapshot(player)) end
end

function FriendsModule:_beginFriendshipCheck(player: Player, targetUserId: number, request: any)
	local generation = self._generateId()
	if typeof(generation) ~= "string" or generation == "" then self:_finishRequest(player, request, "TechnicalError", nil); return end
	local check = {
		Inviter = player, TargetUserId = targetUserId, Request = request, Generation = generation,
		Deadline = request.Deadline,
	}
	request.CheckGeneration = generation
	local previous = self:_snapshot(player)
	self._activeChecks[player] = check
	self:_publishSnapshot(player, previous, self:_snapshot(player))
	local function waitForCheckDeadline()
		self._delay(math.max(0, check.Deadline - self._clock()), function()
			if self._state ~= "active" or self._activeChecks[player] ~= check then return end
			if self._clock() < check.Deadline then waitForCheckDeadline(); return end
			self:_finishFriendshipCheck(player, check)
			self:_finishRequest(player, request, "TemporaryError", nil)
		end)
	end
	waitForCheckDeadline()
	self._spawn(function()
		if self._state ~= "active" or self._activeChecks[player] ~= check or request.Stage ~= "Pending" then return end
		if self._clock() >= check.Deadline then
			self:_finishFriendshipCheck(player, check)
			self:_finishRequest(player, request, "TemporaryError", nil)
			return
		end
		local friendshipOk, isFriend = pcall(self._checkFriendship, player, targetUserId)
		if self._activeChecks[player] ~= check or request.Stage ~= "Pending"
			or request.CheckGeneration ~= generation then return end
		self:_finishFriendshipCheck(player, check)
		if self._state ~= "active" or self._running[player] ~= true or self._data[player] == nil
			or (self._players ~= nil and self._players:GetPlayerByUserId(player.UserId) ~= player) then
			self:_finishRequest(player, request, "Cancelled", nil)
			return
		end
		if self._clock() >= check.Deadline then
			self:_finishRequest(player, request, "TemporaryError", nil)
			return
		end
		if not friendshipOk then self:_finishRequest(player, request, "TemporaryError", nil); return end
		if isFriend ~= true then self:_finishRequest(player, request, "NotFriends", nil); return end
		self:_expireHolds(player)
		local precheck = self:_requestPrecheck(player, targetUserId, request)
		if precheck ~= nil then self:_finishRequest(player, request, precheck, nil); return end
		local target = if self._players ~= nil then self._players:GetPlayerByUserId(targetUserId) else nil
		if target == nil then
			self:_beginNativeInvite(player, targetUserId, request)
			return
		end
		if self._running[target] ~= true or self._data[target] == nil then
			self:_finishRequest(player, request, "TargetUnavailable", nil)
			return
		end
		self:_createLocalOffer(player, target, request)
	end)
end

function FriendsModule:_revokeCapability(capability: any)
	if capability == nil or capability.State == "Revoked" or capability.State == "Consumed" then return end
	capability.State = "Revoked"
	if self._capabilitiesByToken[capability.Token] == capability then self._capabilitiesByToken[capability.Token] = nil end
	local capabilities = self._capabilitiesByInviter[capability.Inviter]
	if capabilities ~= nil and capabilities[capability.TargetUserId] == capability then
		capabilities[capability.TargetUserId] = nil
	end
end

function FriendsModule:_getOrCreateCapability(inviter: Player, targetUserId: number): any?
	local capabilities = self._capabilitiesByInviter[inviter]
	if capabilities == nil then capabilities = {}; self._capabilitiesByInviter[inviter] = capabilities end
	local capability = capabilities[targetUserId]
	if capability ~= nil and capability.State == "Active" then
		self._capabilitySequence += 1
		capability.LastUsedSequence = self._capabilitySequence
		return capability
	end
	local count = 0
	local oldest: any = nil
	for _, existing in capabilities do
		count += 1
		local hold = self._holdsByInviter[inviter] and self._holdsByInviter[inviter][existing.TargetUserId]
		if existing.State == "Active" and (hold == nil or hold.Capability ~= existing or hold.State == "Terminal")
			and (oldest == nil or existing.LastUsedSequence < oldest.LastUsedSequence) then oldest = existing end
	end
	if count >= CAPABILITY_LIMIT then
		if oldest == nil then return nil end
		self:_revokeCapability(oldest)
	end
	local token, claimId = self._generateId(), self._generateId()
	if typeof(token) ~= "string" or token == "" or typeof(claimId) ~= "string" or claimId == "" then return nil end
	self._capabilitySequence += 1
	capability = {
		Inviter = inviter, TargetUserId = targetUserId, Token = token, ClaimId = claimId,
		TargetJobId = self._jobId, State = "Active", LastUsedSequence = self._capabilitySequence,
	}
	capabilities[targetUserId] = capability
	self._capabilitiesByToken[token] = capability
	return capability
end

function FriendsModule:_retireNativePrompt(player: Player, prompt: any, category: string)
	if prompt.Retired then return end
	local previous = if self._running[player] == true and self._data[player] ~= nil then self:_snapshot(player) else nil
	prompt.Retired = true
	if self._activePrompts[player] == prompt then self._activePrompts[player] = nil end
	if prompt.Provisional and prompt.Hold ~= nil and not prompt.Hold.Confirmed then
		self:_removeHold(prompt.Hold, nil, false)
	end
	self:_finishRequest(player, prompt.Request, category, nil)
	if previous ~= nil then self:_publishSnapshot(player, previous, self:_snapshot(player)) end
end

function FriendsModule:_beginNativeInvite(player: Player, targetUserId: number, request: any)
	local capability = self:_getOrCreateCapability(player, targetUserId)
	local generation = self._generateId()
	if capability == nil or typeof(generation) ~= "string" or generation == "" then
		self:_finishRequest(player, request, "TechnicalError", nil)
		return
	end
	local launchData = self:_makeLaunchData(capability.Token)
	if launchData == nil then self:_finishRequest(player, request, "TechnicalError", nil); return end
	local previous = self:_snapshot(player)
	local holds = self._holdsByInviter[player]
	if holds == nil then holds = {}; self._holdsByInviter[player] = holds end
	local existing = holds[targetUserId]
	local hold = existing or {
		Kind = "Native", Inviter = player, TargetUserId = targetUserId, Capability = capability,
		Generation = generation, Deadline = request.Deadline, Confirmed = false,
		State = "Open", Request = request,
	}
	if existing == nil then holds[targetUserId] = hold end
	local prompt = {
		Generation = generation, RequestId = request.RequestId, Request = request,
		Deadline = request.Deadline, TargetUserId = targetUserId, Capability = capability,
		Hold = hold, Provisional = not hold.Confirmed, Retired = false,
	}
	self._activePrompts[player] = prompt
	request.Hold = hold
	request.Prompt = prompt
	if prompt.Provisional then request.ProvisionalHold = hold end
	self:_publishSnapshot(player, previous, self:_snapshot(player))
	local function waitForAttemptDeadline()
		self._delay(math.max(0, prompt.Deadline - self._clock()), function()
			if self._state ~= "active" or self._activePrompts[player] ~= prompt or prompt.Retired then return end
			if self._clock() < prompt.Deadline then waitForAttemptDeadline(); return end
			self:_retireNativePrompt(player, prompt, "TemporaryError")
		end)
	end
	waitForAttemptDeadline()
	local sent = self:_queue(player, FriendsProtocol.MessageTypes.OpenPrompt, table.freeze({
		Generation = generation, TargetUserId = targetUserId, LaunchData = launchData,
	}), request.RequestId, CommunicationProtocol.Priorities.State)
	if not sent then self:_retireNativePrompt(player, prompt, "TechnicalError") end
end

function FriendsModule:RequestInvite(player: Player, payload: any, requestId: string?)
	if self._state ~= "active" or self._running[player] ~= true or self._data[player] == nil then return end
	if typeof(requestId) ~= "string" or requestId == "" then return end
	local request = self:_recordRequest(player, requestId)
	if request == nil then return end
	self:_expireHolds(player)
	local precheck = self:_requestPrecheck(player, payload.TargetUserId, request)
	if precheck ~= nil then self:_finishRequest(player, request, precheck, nil); return end
	self:_beginFriendshipCheck(player, payload.TargetUserId, request)
end

function FriendsModule:HandlePlatformResult(player: Player, payload: any, requestId: string?)
	if self._state ~= "active" or typeof(requestId) ~= "string" then return end
	local request = self._requests[player] and self._requests[player][requestId]
	local prompt = if request ~= nil then request.Prompt else nil
	if request == nil or request.Stage ~= "Pending" or prompt == nil or prompt.Retired
		or self._activePrompts[player] ~= prompt or prompt.RequestId ~= requestId or prompt.Generation ~= payload.Generation then return end
	if self._clock() >= prompt.Deadline then self:_retireNativePrompt(player, prompt, "TemporaryError"); return end
	if payload.Result == "PromptRequested" then
		self:_expireHolds(player)
		if prompt.Retired then return end
		if self._running[player] ~= true or self._data[player] == nil or prompt.Capability.State ~= "Active"
			or self._playerSlots:CanCreateInvitation(player) ~= "Allowed" then
			self:_retireNativePrompt(player, prompt, "Cancelled"); return
		end
		local holds = self._holdsByInviter[player] or {}
		local hold = holds[prompt.TargetUserId]
		if hold ~= nil and (hold ~= prompt.Hold or hold.State ~= "Open") then self:_retireNativePrompt(player, prompt, "Cancelled"); return end
		if self:_connectedCount(player) + self:_holdCount(player) + (if hold == nil then 1 else 0) > self._data[player].Current then
			self:_retireNativePrompt(player, prompt, "NoCapacity"); return
		end
		local previous = self:_snapshot(player)
		hold = hold or {
			Kind = "Native", Inviter = player, TargetUserId = prompt.TargetUserId,
			Capability = prompt.Capability, State = "Open",
		}
		hold.Generation, hold.Deadline = prompt.Generation, self._clock() + self._config.ReserveLifetimeSeconds
		hold.Confirmed, hold.Request = true, request
		holds[prompt.TargetUserId] = hold
		self._holdsByInviter[player] = holds
		prompt.Hold, prompt.Provisional = hold, false
		self:_publishSnapshot(player, previous, self:_snapshot(player))
		self:_scheduleHoldExpiry(hold)
		self:_finishRequest(player, request, "PromptRequested", prompt.Generation)
	elseif payload.Result == "InviteUnavailable" then
		self:_retireNativePrompt(player, prompt, "InviteUnavailable")
	else
		self:_retireNativePrompt(player, prompt, "TemporaryError")
	end
end

function FriendsModule:HandlePromptClosed(_player: Player, _payload: any, _requestId: string?)
	-- Закрытие платформенного окна не имеет надёжного идентификатора попытки.
	-- Владение снимается только результатом ошибки или отдельным сроком попытки.
end

function FriendsModule:_scheduleProcessingWatchdog(offer: any)
	local processingGeneration = offer.ProcessingGeneration
	local function waitUntilDeadline()
		self._delay(math.max(0, offer.Hold.Deadline - self._clock()), function()
			if self._state ~= "active" or offer.State ~= "Processing"
				or offer.ProcessingGeneration ~= processingGeneration then return end
			if self._clock() < offer.Hold.Deadline then waitUntilDeadline(); return end
			local cancelOk = true
			if typeof(offer.CancelTransfer) == "function" then
				cancelOk = pcall(offer.CancelTransfer, "TransferFailed")
			end
			if offer.State == "Processing" then
				self:_terminalizeLocalOffer(offer, if cancelOk then "TransferFailed" else "TechnicalError", nil)
			end
		end)
	end
	waitUntilDeadline()
end

function FriendsModule:RespondLocalOffer(target: Player, payload: any, requestId: string?)
	if self._state ~= "active" or self._running[target] ~= true or typeof(requestId) ~= "string" or requestId == "" then return end
	local responseRequest = self:_recordResponseRequest(target, requestId, payload.OfferId)
	if responseRequest == nil then return end
	self:_expireHolds(target)
	local offer = self._incomingOffers[target]
	if offer == nil or offer.OfferId ~= payload.OfferId or offer.Target ~= target or offer.State ~= "Open" then
		self:_finishResponseRequest(responseRequest, "Cancelled")
		return
	end
	if payload.Decision == "Decline" then
		offer.ResponseRequest = responseRequest
		self:_terminalizeLocalOffer(offer, "Declined", nil)
		return
	end
	local previousTarget = self:_snapshot(target)
	local previousInviter = self:_snapshot(offer.Inviter)
	offer.State = "Processing"
	offer.ResponseRequest = responseRequest
	offer.ProcessingGeneration = self._generateId()
	if typeof(offer.ProcessingGeneration) ~= "string" or offer.ProcessingGeneration == "" then
		self:_terminalizeLocalOffer(offer, "TechnicalError", nil)
		return
	end
	offer.Hold.Deadline = self._clock() + math.min(self._config.ReserveLifetimeSeconds, LOCAL_TRANSFER_TIMEOUT_SECONDS)
	self:_publishSnapshot(offer.Inviter, previousInviter, self:_snapshot(offer.Inviter))
	self:_publishSnapshot(target, previousTarget, self:_snapshot(target))
	self:_scheduleProcessingWatchdog(offer)
	local handler = self._localTransferHandler
	if handler == nil then self:_terminalizeLocalOffer(offer, "TransferFailed", nil); return end
	self._spawn(function()
		local processingGeneration = offer.ProcessingGeneration
		if self._state ~= "active" or offer.State ~= "Processing"
			or self._incomingOffers[target] ~= offer then return end
		local friendshipOk, isFriend = pcall(self._checkFriendship, offer.Inviter, target.UserId)
		if self._state ~= "active" or offer.State ~= "Processing"
			or offer.ProcessingGeneration ~= processingGeneration or self._incomingOffers[target] ~= offer then return end
		if self._clock() >= offer.Hold.Deadline then
			self:_terminalizeLocalOffer(offer, "TransferFailed", nil)
			return
		end
		if self._running[offer.Inviter] ~= true or self._running[target] ~= true
			or self._data[offer.Inviter] == nil or self._data[target] == nil
			or self._players == nil or self._players:GetPlayerByUserId(offer.Inviter.UserId) ~= offer.Inviter
			or self._players:GetPlayerByUserId(target.UserId) ~= target then
			self:_terminalizeLocalOffer(offer, "InviterUnavailable", nil)
			return
		end
		if not friendshipOk then self:_terminalizeLocalOffer(offer, "TransferFailed", nil); return end
		if isFriend ~= true then self:_terminalizeLocalOffer(offer, "NotFriends", nil); return end
		if self._playerSlots:CanCreateInvitation(offer.Inviter) ~= "Allowed"
			or self:_connectedCount(offer.Inviter) + self:_holdCount(offer.Inviter) > self._data[offer.Inviter].Current then
			self:_terminalizeLocalOffer(offer, "NoCapacity", nil)
			return
		end
		local eligible, eligibilityError = self:_normalizeLocalEligibility(offer.Inviter, target)
		if not eligible then
			local category = if eligibilityError ~= nil and LOCAL_FAILURES[eligibilityError] then eligibilityError else "TargetIneligible"
			self:_terminalizeLocalOffer(offer, category, nil)
			return
		end
		if self._state ~= "active" or offer.State ~= "Processing"
			or offer.ProcessingGeneration ~= processingGeneration or self._incomingOffers[target] ~= offer
			or self._clock() >= offer.Hold.Deadline then return end
		local ok, result = pcall(handler, offer.Inviter, target, offer.OfferId)
		if offer.State ~= "Processing" or offer.ProcessingGeneration ~= processingGeneration then return end
		if not ok or typeof(result) ~= "table" or result.Ok ~= true then
			local category = if ok and typeof(result) == "table" and LOCAL_FAILURES[result.Error] then result.Error else "TransferFailed"
			self:_terminalizeLocalOffer(offer, category, nil)
			return
		end
		if typeof(result.Cancel) ~= "function" then
			self:_terminalizeLocalOffer(offer, "TransferFailed", nil)
			return
		end
		offer.CancelTransfer = result.Cancel
	end)
end

function FriendsModule:PrepareLocalTransfer(inviter: Player, target: Player, offerId: string): any
	if self._state ~= "active" or self._localTransfers[target] ~= nil then return table.freeze({ Ok = false, Error = "TargetBusy" }) end
	local offer = self._offersById[offerId]
	if offer == nil or offer.State ~= "Processing" or offer.Inviter ~= inviter or offer.Target ~= target
		or self._incomingOffers[target] ~= offer or self._running[inviter] ~= true or self._running[target] ~= true then
		return table.freeze({ Ok = false, Error = "TargetIneligible" })
	end
	local hold = offer.Hold
	if hold.State ~= "Open" or self._playerSlots:CanCreateInvitation(inviter) ~= "Allowed"
		or self:_connectedCount(inviter) + self:_holdCount(inviter) > self._data[inviter].Current then
		return table.freeze({ Ok = false, Error = "NoCapacity" })
	end
	local operation = {
		Stage = "Prepared", Offer = offer, Inviter = inviter, Target = target,
		PreviousTargetIsSlotOwner = self:_isSlotOwner(target),
	}
	self._localTransfers[target] = operation
	return table.freeze({
		Ok = true,
		Operation = operation,
		SlotContext = table.freeze({ Kind = "Friend", InviterUserId = inviter.UserId, ClaimId = hold.ClaimId }),
	})
end

function FriendsModule:CommitLocalTransfer(operation: any): boolean
	if typeof(operation) ~= "table" or self._localTransfers[operation.Target] ~= operation or operation.Stage ~= "Prepared"
		or operation.Offer.State ~= "Processing" then return false end
	-- The relation remains unpublished and unmodified while slots and respawn are tentative.
	-- Complete applies a delta to the then-current graph, so a concurrent departure cannot
	-- be resurrected by restoring an old relation snapshot.
	operation.Stage = "Committed"
	return true
end

function FriendsModule:RollbackLocalTransfer(operation: any, category: string?)
	if typeof(operation) ~= "table" or self._localTransfers[operation.Target] ~= operation
		or (operation.Stage ~= "Prepared" and operation.Stage ~= "Committed") then return end
	operation.Stage = "RolledBack"
	self._localTransfers[operation.Target] = nil
	local resultCategory = if category ~= nil and LOCAL_FAILURES[category] then category else "TransferFailed"
	self:_terminalizeLocalOffer(operation.Offer, resultCategory, nil)
end

function FriendsModule:CompleteLocalTransfer(operation: any): boolean
	if typeof(operation) ~= "table" or self._localTransfers[operation.Target] ~= operation or operation.Stage ~= "Committed" then return false end
	local previous = {}
	for _, player in { operation.Inviter, operation.Target } do
		if self._running[player] == true and self._data[player] ~= nil then previous[player] = self:_snapshot(player) end
	end
	local targetRelations = self._relations[operation.Target]
	if targetRelations ~= nil then
		local currentFriends = {}; for friend in targetRelations do table.insert(currentFriends, friend) end
		for _, friend in currentFriends do
			if self._running[friend] == true and self._data[friend] ~= nil and previous[friend] == nil then
				previous[friend] = self:_snapshot(friend)
			end
			self:_removeRelation(operation.Target, friend)
		end
	end
	local inviterRelations = self._relations[operation.Inviter] or {}; self._relations[operation.Inviter] = inviterRelations
	local updatedTargetRelations = self._relations[operation.Target] or {}; self._relations[operation.Target] = updatedTargetRelations
	inviterRelations[operation.Target] = true
	updatedTargetRelations[operation.Inviter] = true
	operation.Stage = "Completed"
	self._localTransfers[operation.Target] = nil
	self:_terminalizeLocalOffer(operation.Offer, "Accepted", previous)
	return true
end

function FriendsModule:PrepareAdmission(player: Player, input: any): any
	if self._state ~= "active" or self._running[player] ~= true or self._data[player] == nil then return table.freeze({ Ok = false, Error = "NotReady" }) end
	if self._operations[player] ~= nil then return table.freeze({ Ok = false, Error = "Rejected" }) end
	self:_expireHolds()
	if exactOrdinaryInput(input) then
		local operation = { Player = player, Stage = "Prepared", Kind = "Ordinary", Previous = self:_snapshot(player), Pending = {} }
		self._operations[player] = operation
		return table.freeze({ Ok = true, Operation = operation, SlotContext = table.freeze({ Kind = "Ordinary" }) })
	end
	if not exactInvitationInput(input) or input.TargetJobId ~= self._jobId then return table.freeze({ Ok = false, Error = "Rejected" }) end
	local capability = self._capabilitiesByToken[input.Token]
	if capability == nil or capability.State ~= "Active" or capability.TargetUserId ~= player.UserId
		or self._running[capability.Inviter] ~= true or self._data[capability.Inviter] == nil
		or self._playerSlots:CanCreateInvitation(capability.Inviter) ~= "Allowed" then return table.freeze({ Ok = false, Error = "Rejected" }) end
	local hold = self._holdsByInviter[capability.Inviter] and self._holdsByInviter[capability.Inviter][player.UserId]
	local otherHoldCount = self:_holdCount(capability.Inviter) - (if hold ~= nil and hold.Capability == capability then 1 else 0)
	if self:_connectedCount(capability.Inviter) + otherHoldCount >= self._data[capability.Inviter].Current then
		return table.freeze({ Ok = false, Error = "Rejected" })
	end
	local operation = { Player = player, Stage = "Prepared", Kind = "Friend", Capability = capability, Hold = hold, Previous = self:_snapshot(player), Pending = {} }
	capability.State, capability.ClaimOperation = "Claimed", operation
	if hold ~= nil then hold.State = "Claimed" end
	self._operations[player] = operation
	return table.freeze({ Ok = true, Operation = operation, SlotContext = table.freeze({
		Kind = "Friend", InviterUserId = capability.Inviter.UserId, ClaimId = capability.ClaimId,
	}) })
end

function FriendsModule:_appendSnapshotChange(operation: any, player: Player, previous: any)
	if self._running[player] ~= true or self._data[player] == nil then return end
	local current = self:_snapshot(player)
	if not FriendsSnapshot.equal(previous, current) then table.insert(operation.Pending, { Player = player, Previous = previous, Current = current }) end
end

function FriendsModule:CommitAdmission(operation: any): boolean
	if typeof(operation) ~= "table" or self._operations[operation.Player] ~= operation or operation.Stage ~= "Prepared" then return false end
	if operation.Kind == "Ordinary" then operation.Stage = "Committed"; self:_appendSnapshotChange(operation, operation.Player, operation.Previous); return true end
	local capability = operation.Capability
	if capability == nil or capability.State ~= "Claimed" or capability.ClaimOperation ~= operation then return false end
	local inviter = capability.Inviter
	local affected = { inviter, operation.Player }
	local targetedHolds = {}
	for otherInviter, holds in self._holdsByInviter do
		local other = holds[operation.Player.UserId]
		if other ~= nil and other.State == "Open" then table.insert(targetedHolds, other); table.insert(affected, otherInviter) end
	end
	if operation.Hold ~= nil then table.insert(targetedHolds, operation.Hold) end
	local previous = {}
	for _, candidate in affected do if self._running[candidate] == true and previous[candidate] == nil then previous[candidate] = self:_snapshot(candidate) end end
	capability.State = "Consumed"
	self._capabilitiesByToken[capability.Token] = nil
	local capabilities = self._capabilitiesByInviter[inviter]
	if capabilities ~= nil and capabilities[capability.TargetUserId] == capability then capabilities[capability.TargetUserId] = nil end
	for _, other in targetedHolds do self:_removeHold(other, "Cancelled", false) end
	local inviterRelations = self._relations[inviter] or {}; self._relations[inviter] = inviterRelations
	local playerRelations = self._relations[operation.Player] or {}; self._relations[operation.Player] = playerRelations
	inviterRelations[operation.Player], playerRelations[inviter] = true, true
	operation.Stage = "Committed"
	for candidate, snapshot in previous do self:_appendSnapshotChange(operation, candidate, snapshot) end
	return true
end

function FriendsModule:CancelAdmission(operation: any)
	if typeof(operation) ~= "table" or self._operations[operation.Player] ~= operation or operation.Stage ~= "Prepared" then return end
	operation.Stage = "Cancelled"
	self._operations[operation.Player] = nil
	if operation.Kind == "Friend" and operation.Capability ~= nil and operation.Capability.ClaimOperation == operation then
		operation.Capability.ClaimOperation = nil
		operation.Capability.State = "Active"
		if operation.Hold ~= nil and operation.Hold.State == "Claimed" then operation.Hold.State = "Open" end
	end
end

function FriendsModule:EmitAdmissionEvents(operation: any)
	if typeof(operation) ~= "table" or operation.Stage ~= "Committed" or operation.Emitted then return end
	operation.Emitted = true
	self._operations[operation.Player] = nil
	for _, change in operation.Pending do self:_publishSnapshot(change.Player, change.Previous, change.Current) end
end

function FriendsModule:_removeRelation(left: Player, right: Player)
	local leftRelations = self._relations[left]; if leftRelations ~= nil then leftRelations[right] = nil end
	local rightRelations = self._relations[right]; if rightRelations ~= nil then rightRelations[left] = nil end
end

function FriendsModule:_revokeCapabilities(inviter: Player)
	local capabilities = self._capabilitiesByInviter[inviter]
	if capabilities == nil then return end
	local pending = {}; for _, capability in capabilities do table.insert(pending, capability) end
	for _, capability in pending do self:_revokeCapability(capability) end
	self._capabilitiesByInviter[inviter] = nil
end

function FriendsModule:BeginDeparture(player: Player, mode: any): any
	if self._departures[player] ~= nil then return self._departures[player].Result end
	local operation = { Player = player, Stage = "Prepared" }
	local friendsToDisconnect = {}
	local relations = self._relations[player]
	if mode == "DisconnectPublishedFriends" and relations ~= nil then
		for friend in relations do table.insert(friendsToDisconnect, friend) end
		table.sort(friendsToDisconnect, function(left, right) return left.UserId < right.UserId end)
	elseif relations ~= nil then
		local previousSnapshots = {}
		for friend in relations do if self._running[friend] == true and self._data[friend] ~= nil then previousSnapshots[friend] = self:_snapshot(friend) end end
		local friends = {}; for friend in relations do table.insert(friends, friend) end
		for _, friend in friends do self:_removeRelation(player, friend) end
		for friend, previous in previousSnapshots do self:_publishSnapshot(friend, previous, self:_snapshot(friend)) end
	end
	local check = self._activeChecks[player]
	if check ~= nil then self:_finishFriendshipCheck(player, check); self:_finishRequest(player, check.Request, "Cancelled", nil) end
	local targetedChecks = {}
	for inviter, otherCheck in self._activeChecks do
		if otherCheck.TargetUserId == player.UserId then table.insert(targetedChecks, { Inviter = inviter, Check = otherCheck }) end
	end
	for _, item in targetedChecks do
		self:_finishFriendshipCheck(item.Inviter, item.Check)
		self:_finishRequest(item.Inviter, item.Check.Request, "TargetUnavailable", nil)
	end
	local retiringPrompts = {}
	for inviter, prompt in self._activePrompts do
		if inviter == player or prompt.TargetUserId == player.UserId then table.insert(retiringPrompts, { Player = inviter, Prompt = prompt }) end
	end
	for _, entry in retiringPrompts do self:_retireNativePrompt(entry.Player, entry.Prompt, "Cancelled") end
	local outgoing = self._holdsByInviter[player]
	if outgoing ~= nil then
		local holds = {}; for _, hold in outgoing do table.insert(holds, hold) end
		for _, hold in holds do
			if hold.Offer ~= nil then self:_terminalizeLocalOffer(hold.Offer, "InviterUnavailable", nil)
			else self:_removeHold(hold, "Cancelled", false) end
		end
	end
	self:_revokeCapabilities(player)
	local targeted = {}
	for _, holds in self._holdsByInviter do
		local hold = holds[player.UserId]
		if hold ~= nil then table.insert(targeted, hold) end
	end
	for _, hold in targeted do
		if hold.Offer ~= nil then self:_terminalizeLocalOffer(hold.Offer, "Cancelled", nil)
		else self:_removeHold(hold, "Cancelled", true) end
	end
	local incoming = self._incomingOffers[player]
	if incoming ~= nil then self:_terminalizeLocalOffer(incoming, "Cancelled", nil) end
	local result = table.freeze({ Operation = operation, FriendsToDisconnect = table.freeze(friendsToDisconnect) })
	self._departures[player] = { Operation = operation, Result = result }
	return result
end

function FriendsModule:CompleteDeparture(operation: any)
	if typeof(operation) ~= "table" or operation.Stage ~= "Prepared" then return end
	operation.Stage = "Completed"
	self._departures[operation.Player] = nil
	self._relations[operation.Player] = nil
end

function FriendsModule:Stop(player: Player?)
	if player ~= nil then
		local prompt = self._activePrompts[player]
		if prompt ~= nil then self:_retireNativePrompt(player, prompt, "Cancelled") end
		local active = self._operations[player]; if active ~= nil then self:CancelAdmission(active) end
		local outgoing = self._holdsByInviter[player]
		if outgoing ~= nil then
			local holds = {}; for _, hold in outgoing do table.insert(holds, hold) end
			for _, hold in holds do
				if hold.Offer ~= nil then self:_terminalizeLocalOffer(hold.Offer, "InviterUnavailable", nil)
				else self:_removeHold(hold, "Cancelled", false) end
			end
		end
		local incoming = self._incomingOffers[player]
		if incoming ~= nil then self:_terminalizeLocalOffer(incoming, "Cancelled", nil) end
		self:_revokeCapabilities(player)
		self._running[player], self._data[player], self._requests[player], self._responseRequests[player] = nil, nil, nil, nil
		self._recentRequestIds[player], self._recentResponseIds[player] = nil, nil
		self._activePrompts[player], self._activeChecks[player] = nil, nil
		return
	end
	if self._state == "stopped" then return end
	self._state = "stopped"
	for _, requests in self._requests do for _, request in requests do self:_finishRequest(request.Player, request, "Cancelled", nil) end end
	for _, operation in self._operations do self:CancelAdmission(operation) end
	for inviter in self._capabilitiesByInviter do self:_revokeCapabilities(inviter) end
	table.clear(self._running); table.clear(self._data); table.clear(self._operations); table.clear(self._localTransfers)
	table.clear(self._holdsByInviter); table.clear(self._capabilitiesByInviter); table.clear(self._capabilitiesByToken)
	table.clear(self._relations); table.clear(self._requests); table.clear(self._responseRequests)
	table.clear(self._recentRequestIds); table.clear(self._recentResponseIds)
	table.clear(self._activePrompts); table.clear(self._activeChecks); table.clear(self._incomingOffers)
	table.clear(self._offersById); table.clear(self._departures)
	self.MementoChanged:Destroy(); self.SnapshotChanged:Destroy()
end

return FriendsModule
