--!strict

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local FriendsProtocol = require(ReplicatedStorage.Shared.Friends.FriendsProtocol)
local FriendsSnapshot = require(ReplicatedStorage.Shared.Friends.FriendsSnapshot)
local CommunicationProtocol = require(ReplicatedStorage.Shared.Communication.CommunicationProtocol)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)

local Client = {}
Client.__index = Client
local INVITE_ATTEMPT_SECONDS = 10

local function finitePositiveInteger(value: any): boolean
	return typeof(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
		and value == math.floor(value) and value > 0
end

local function inviteState(phase: string?, targetUserId: number?): any
	if phase == nil or targetUserId == nil then
		return table.freeze({ IsBusy = false, Phase = "Idle" })
	end
	return table.freeze({
		IsBusy = true,
		Phase = phase,
		TargetUserId = targetUserId,
	})
end

local function snapshotHasReserve(snapshot: any?, targetUserId: number): boolean
	if typeof(snapshot) ~= "table" or typeof(snapshot.Reserves) ~= "table" then return false end
	for _, reserve in snapshot.Reserves do
		if typeof(reserve) == "table" and reserve.TargetUserId == targetUserId then return true end
	end
	return false
end

function Client.new(provider: any, deps: any?)
	assert(provider ~= nil, "Friends snapshot provider required")
	deps = deps or {}
	return setmetatable({
		_provider = provider,
		_communication = deps.Communication,
		_social = deps.SocialService,
		_localPlayer = deps.LocalPlayer,
		_generateRequestId = deps.GenerateRequestId or function() return HttpService:GenerateGUID(false) end,
		_clock = deps.Clock or os.clock,
		_delay = deps.Delay or task.delay,
		_spawn = deps.Spawn or task.spawn,
		_recoveryGeneration = 0,
		_state = "fresh",
		_snapshot = nil,
		_readyConnection = nil,
		_prepareCancel = nil,
		_pending = {},
		_pendingOfferResponses = {},
		_inviteAttempt = nil,
		_inviteState = inviteState(nil, nil),
		_handlersRegistered = false,
		SnapshotChanged = Signal.new(),
		PromptStateChanged = Signal.new(),
		RefreshSucceeded = Signal.new(),
	}, Client)
end

function Client:_setInviteState(phase: string?, targetUserId: number?)
	local previous = self._inviteState
	local current = inviteState(phase, targetUserId)
	if previous.IsBusy == current.IsBusy
		and previous.Phase == current.Phase and previous.TargetUserId == current.TargetUserId then
		return
	end
	self._inviteState = current
	self.PromptStateChanged:Fire(table.freeze({ Previous = previous, Current = current }))
end

function Client:_completeInvite(pending: any, category: string)
	if pending == nil or pending.Stage ~= "Active" then return end
	local ownsState = self._pending[pending.RequestId] == pending
	pending.Completed = true
	pending.Stage = "Terminal"
	if ownsState then self._pending[pending.RequestId] = nil end
	local attempt = self._inviteAttempt
	if ownsState and attempt ~= nil and attempt.RequestId == pending.RequestId then
		if category ~= "PromptRequested" then
			self:_retireInviteAttempt(attempt, category)
		end
	end
	if pending.Callback ~= nil then pending.Callback(category) end
end

function Client:_completeOfferResponse(pending: any, category: string)
	if pending == nil or pending.Stage ~= "Active" then return end
	pending.Stage = "Terminal"
	self._pendingOfferResponses[pending.RequestId] = nil
	if pending.Callback ~= nil then pending.Callback(category) end
end

function Client:_requestResync(reason: string)
	if self._communication ~= nil and typeof(self._communication.RequestResync) == "function" then
		self._communication:RequestResync(reason)
	end
end

function Client:_registerHandlers()
	if self._handlersRegistered or self._communication == nil then return end
	self._communication:RegisterHandler(FriendsProtocol.MessageTypes.OpenPrompt, function(payload: any, requestId: string?)
		local valid, checked, reason = FriendsProtocol.validateOpenPrompt(payload)
		assert(valid, reason)
		self:_handleOpenPrompt(checked, requestId)
	end)
	self._communication:RegisterHandler(FriendsProtocol.MessageTypes.InviteResult, function(payload: any, requestId: string?)
		local valid, checked, reason = FriendsProtocol.validateInviteResult(payload)
		assert(valid, reason)
		if requestId ~= nil then self:_completeInvite(self._pending[requestId], checked.Category) end
	end)
	self._communication:RegisterHandler(FriendsProtocol.MessageTypes.LocalOfferResult, function(payload: any, requestId: string?)
		local valid, checked, reason = FriendsProtocol.validateLocalOfferResult(payload)
		assert(valid, reason)
		if requestId ~= nil then
			local pending = self._pendingOfferResponses[requestId]
			if pending ~= nil and pending.OfferId == checked.OfferId then
				self:_completeOfferResponse(pending, checked.Category)
			end
		end
	end)
	self._communication:RegisterHandler(FriendsProtocol.MessageTypes.SnapshotChanged, function(payload: any, _requestId: string?)
		local valid, checked, reason = FriendsProtocol.validateSnapshotChanged(payload)
		assert(valid, reason)
		self:_handleSnapshotChanged(checked)
	end)
	self._handlersRegistered = true
end

function Client:_retireInviteAttempt(attempt: any, category: string)
	if self._inviteAttempt ~= attempt then return end
	self._inviteAttempt = nil
	local pending = self._pending[attempt.RequestId]
	self._pending[attempt.RequestId] = nil
	if attempt.Options ~= nil then attempt.Options:Destroy(); attempt.Options = nil end
	self:_setInviteState(nil, nil)
	self:_completeInvite(pending, category)
end

function Client:_expireInviteAttempt()
	local attempt = self._inviteAttempt
	if attempt ~= nil and self._clock() >= attempt.Deadline then
		self:_retireInviteAttempt(attempt, "TemporaryError")
	end
	return self._inviteAttempt
end

function Client:_isCurrentAttempt(attempt: any): boolean
	return self._state == "active" and self:_expireInviteAttempt() == attempt
		and attempt.RecoveryGeneration == self._recoveryGeneration
end

function Client:_scheduleInviteDeadline(attempt: any)
	self._delay(math.max(0, attempt.Deadline - self._clock()), function()
		if self._state ~= "active" or self._inviteAttempt ~= attempt then return end
		self:_expireInviteAttempt()
		if self._inviteAttempt == attempt then self:_scheduleInviteDeadline(attempt) end
	end)
end

function Client:_reconcilePrompt(snapshot: any)
	local attempt = self._inviteAttempt
	if attempt == nil then return end
	local hasReserve = snapshotHasReserve(snapshot, attempt.TargetUserId)
	if snapshot.IsSlotOwner ~= true or (attempt.SawReserve and not hasReserve) then
		self:_retireInviteAttempt(attempt, "Cancelled")
	elseif hasReserve then
		attempt.SawReserve = true
	end
end

function Client:_handleOpenPrompt(payload: any, requestId: string?)
	local pending = if requestId ~= nil then self._pending[requestId] else nil
	local attempt = self._inviteAttempt
	if pending == nil or pending.Stage ~= "Active" or attempt == nil
		or attempt.RequestId ~= requestId or attempt.TargetUserId ~= payload.TargetUserId
		or attempt.PromptGeneration ~= nil or not self:_isCurrentAttempt(attempt) then return end
	attempt.PromptGeneration = payload.Generation
	self:_setInviteState("OpeningRoblox", payload.TargetUserId)
	self._spawn(function() self:_requestNativePrompt(attempt, payload) end)
end

function Client:_requestNativePrompt(attempt: any, payload: any)
	if not self:_isCurrentAttempt(attempt) then return end
	local result = "PromptRequested"
	if self._social == nil or self._localPlayer == nil then
		result = "TemporaryError"
	else
		local canCall, canSend = pcall(function()
			return self._social:CanSendGameInviteAsync(self._localPlayer, payload.TargetUserId)
		end)
		if not self:_isCurrentAttempt(attempt) then return end
		if not canCall then
			result = "TemporaryError"
		elseif canSend ~= true then
			result = "InviteUnavailable"
		else
			local options = Instance.new("ExperienceInviteOptions")
			attempt.Options = options
			local prompted = pcall(function()
				options.LaunchData = payload.LaunchData
				options.InviteUser = payload.TargetUserId
				self._social:PromptGameInvite(self._localPlayer, options)
			end)
			options:Destroy()
			if attempt.Options == options then attempt.Options = nil end
			if not prompted then result = "TemporaryError" end
		end
	end
	if not self:_isCurrentAttempt(attempt) then return end
	if result == "PromptRequested" then self:_setInviteState("PromptRequested", attempt.TargetUserId) end
	if not self:_isCurrentAttempt(attempt) then return end
	local queued = self._communication:Queue(FriendsProtocol.MessageTypes.PlatformResult, {
		Generation = payload.Generation, Result = result,
	}, attempt.RequestId, { Priority = CommunicationProtocol.Priorities.State })
	if not queued then self:_requestResync("FriendsPlatformResultQueueRejected") end
	if result ~= "PromptRequested" then self:_retireInviteAttempt(attempt, result) end
end

function Client:_handleSnapshotChanged(payload: any)
	if self._state ~= "active" then return end
	if not self._provider:TryApply(payload.Previous, payload.Current) then
		self:_requestResync("FriendsSnapshotMismatch")
		return
	end
	local previous = self._snapshot
	self._snapshot = payload.Current
	if previous ~= nil and typeof(previous.Reserves) == "table" then
		local retiredTargets = {} :: { [number]: boolean }
		for _, reserve in previous.Reserves do
			if not snapshotHasReserve(payload.Current, reserve.TargetUserId) then
				retiredTargets[reserve.TargetUserId] = true
			end
		end
		local retired = {}
		for _, pending in self._pending do
			if pending.Stage == "Active" and retiredTargets[pending.TargetUserId] == true then
				table.insert(retired, pending)
			end
		end
		for _, pending in retired do
			self:_completeInvite(pending, "Cancelled")
		end
	end
	self:_reconcilePrompt(payload.Current)
	if previous ~= nil and not FriendsSnapshot.equal(previous, payload.Current) then
		self.SnapshotChanged:Fire(table.freeze({ Previous = previous, Current = payload.Current }))
	end
end

function Client:Initialize(globalSaveController: any)
	if self._state == "active" then return end
	if self._state == "stopped" then error("FriendsClientStopped", 2) end
	assert(globalSaveController ~= nil and globalSaveController.Ready ~= nil, "GlobalSaveController required")
	self._state = "active"
	self:_registerHandlers()
	if self._communication ~= nil then
		self._prepareCancel = self._communication:RegisterResyncPreparation(function(_reason: string)
			self._recoveryGeneration += 1
			local pendingInvites = self._pending
			local pendingResponses = self._pendingOfferResponses
			self._pending = {}
			self._pendingOfferResponses = {}
			local attempt = self._inviteAttempt
			if attempt ~= nil then self:_retireInviteAttempt(attempt, "Cancelled") end
			local completions = {}
			for _, entry in pendingInvites do
				if entry.Stage == "Active" then table.insert(completions, function() self:_completeInvite(entry, "Cancelled") end) end
			end
			for _, entry in pendingResponses do
				if entry.Stage == "Active" then table.insert(completions, function() self:_completeOfferResponse(entry, "Cancelled") end) end
			end
			return completions
		end)
	end
	self._readyConnection = globalSaveController.Ready:Connect(function()
		if self._state ~= "active" then return end
		local snapshot = self._provider:GetSnapshot()
		assert(snapshot ~= nil, "Friends snapshot provider is not ready")
		if self._snapshot == nil then
			self._snapshot = snapshot
		elseif not FriendsSnapshot.equal(self._snapshot, snapshot) then
			local previous = self._snapshot
			self._snapshot = snapshot
			self.SnapshotChanged:Fire(table.freeze({ Previous = previous, Current = snapshot }))
		end
		self:_reconcilePrompt(snapshot)
	end)
end

function Client:RequestInvite(targetUserId: any, callback: ((string) -> ())?): any
	if self._state == "stopped" then return table.freeze({ Ok = false, Error = "Stopped" }) end
	if self._state ~= "active" then return table.freeze({ Ok = false, Error = "NotReady" }) end
	if not finitePositiveInteger(targetUserId) then return table.freeze({ Ok = false, Error = "InvalidTargetUserId" }) end
	if self._communication == nil then return table.freeze({ Ok = false, Error = "CommunicationUnavailable" }) end
	self:_expireInviteAttempt()
	if self._inviteState.IsBusy then return table.freeze({ Ok = false, Error = "AnotherPromptActive" }) end
	for _, request in self._pending do
		if request.Stage == "Active" or request.Stage == "PendingQueue" then
			return table.freeze({ Ok = false, Error = "AnotherPromptActive" })
		end
	end
	local requestId = self._generateRequestId()
	if typeof(requestId) ~= "string" or requestId == "" then return table.freeze({ Ok = false, Error = "CommunicationUnavailable" }) end
	local pending = { RequestId = requestId, TargetUserId = targetUserId, Callback = callback, Stage = "PendingQueue" }
	local attempt = {
		RequestId = requestId, TargetUserId = targetUserId, Deadline = self._clock() + INVITE_ATTEMPT_SECONDS,
		RecoveryGeneration = self._recoveryGeneration, SawReserve = snapshotHasReserve(self._snapshot, targetUserId),
	}
	self._inviteAttempt = attempt
	self._pending[requestId] = pending
	self:_setInviteState("Requesting", targetUserId)
	local queued = self._communication:Queue(FriendsProtocol.MessageTypes.RequestInvite, { TargetUserId = targetUserId }, requestId, {
		Priority = CommunicationProtocol.Priorities.State,
	})
	if not queued then
		pending.Stage = "Discarded"
		self._pending[requestId] = nil
		self:_retireInviteAttempt(attempt, "Cancelled")
		self:_requestResync("FriendsRequestInviteQueueRejected")
		return table.freeze({ Ok = false, Error = "CommunicationUnavailable" })
	end
	pending.Stage = "Active"
	self:_scheduleInviteDeadline(attempt)
	return table.freeze({ Ok = true })
end

function Client:RespondToLocalOffer(offerId: any, decision: any, callback: ((string) -> ())?): any
	if self._state == "stopped" then return table.freeze({ Ok = false, Error = "Stopped" }) end
	if self._state ~= "active" then return table.freeze({ Ok = false, Error = "NotReady" }) end
	if self._communication == nil then return table.freeze({ Ok = false, Error = "CommunicationUnavailable" }) end
	local valid, payload = FriendsProtocol.validateRespondLocalOffer({ OfferId = offerId, Decision = decision })
	if not valid then return table.freeze({ Ok = false, Error = "InvalidLocalOfferResponse" }) end
	for _, pending in self._pendingOfferResponses do
		if pending.Stage == "Active" or pending.Stage == "PendingQueue" then
			return table.freeze({ Ok = false, Error = "LocalOfferResponsePending" })
		end
	end
	local requestId = self._generateRequestId()
	if typeof(requestId) ~= "string" or requestId == "" then return table.freeze({ Ok = false, Error = "CommunicationUnavailable" }) end
	local pending = { RequestId = requestId, OfferId = offerId, Callback = callback, Stage = "PendingQueue" }
	self._pendingOfferResponses[requestId] = pending
	local queued = self._communication:Queue(FriendsProtocol.MessageTypes.RespondLocalOffer, payload, requestId, {
		Priority = CommunicationProtocol.Priorities.Critical,
	})
	if not queued then
		pending.Stage = "Discarded"
		self._pendingOfferResponses[requestId] = nil
		self:_requestResync("FriendsRespondLocalOfferQueueRejected")
		return table.freeze({ Ok = false, Error = "CommunicationUnavailable" })
	end
	pending.Stage = "Active"
	return table.freeze({ Ok = true })
end

function Client:GetSnapshot(): any
	if self._state == "stopped" then return table.freeze({ Ok = false, Error = "Stopped" }) end
	if self._state ~= "active" or self._snapshot == nil then return table.freeze({ Ok = false, Error = "NotReady" }) end
	return table.freeze({ Ok = true, Snapshot = self._snapshot })
end

function Client:GetPromptState(): any
	self:_expireInviteAttempt()
	return self._inviteState
end

function Client:NotifyRefreshSucceeded()
	if self._state == "active" then self.RefreshSucceeded:Fire() end
end

function Client:Stop()
	if self._state == "stopped" then return end
	self._state = "stopped"
	if self._readyConnection ~= nil then self._readyConnection:Disconnect(); self._readyConnection = nil end
	if self._prepareCancel ~= nil then self._prepareCancel(); self._prepareCancel = nil end
	local pendingInvites = self._pending
	local pendingResponses = self._pendingOfferResponses
	self._pending = {}
	self._pendingOfferResponses = {}
	local attempt = self._inviteAttempt
	if attempt ~= nil then self:_retireInviteAttempt(attempt, "Cancelled") end
	self:_setInviteState(nil, nil)
	for _, entry in pendingInvites do self:_completeInvite(entry, "Cancelled") end
	for _, entry in pendingResponses do self:_completeOfferResponse(entry, "Cancelled") end
	self._snapshot = nil
	self.SnapshotChanged:Destroy()
	self.PromptStateChanged:Destroy()
	self.RefreshSucceeded:Destroy()
end

return Client
