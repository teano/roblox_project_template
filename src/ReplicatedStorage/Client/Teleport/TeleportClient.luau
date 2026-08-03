--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TeleportProtocol = require(ReplicatedStorage.Shared.Teleport.TeleportProtocol)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)

local TERMINAL_HISTORY_LIMIT = 32

local TeleportClient = {}
TeleportClient.__index = TeleportClient

local function copy(value: any): any
	return if value == nil then nil else table.clone(value)
end

local function sameArrival(left: any, right: any): boolean
	return left ~= nil
		and right ~= nil
		and left.SessionId == right.SessionId
		and left.EntryKind == right.EntryKind
		and left.SourcePlaceId == right.SourcePlaceId
end

local function sameAppearance(left: any, right: any): boolean
	return left ~= nil
		and right ~= nil
		and left.UserId == right.UserId
		and left.EntryKind == right.EntryKind
		and left.SourcePlaceId == right.SourcePlaceId
end

function TeleportClient.new(deps: {
	Communication: any,
	PlayersModule: any,
	MaxPlayers: number,
})
	assert(typeof(deps) == "table", "Teleport client dependencies required")
	assert(
		typeof(deps.MaxPlayers) == "number"
			and deps.MaxPlayers == deps.MaxPlayers
			and deps.MaxPlayers ~= math.huge
			and deps.MaxPlayers % 1 == 0
			and deps.MaxPlayers >= 1,
		"MaxPlayers must be a positive integer"
	)
	local self = setmetatable({
		_communication = deps.Communication,
		_players = deps.PlayersModule,
		_maxPresentPlayers = deps.MaxPlayers - 1,
		_arrival = nil :: any,
		_attempt = nil :: any,
		_presentPlayers = {} :: { [number]: any },
		_terminalAttempts = {} :: { [string]: boolean },
		_terminalOrder = {} :: { string },
		_initialized = false,
		_stopped = false,
		LocalArrived = Signal.new(),
		LocalAttemptStarted = Signal.new(),
		LocalAttemptAccepted = Signal.new(),
		LocalAttemptFailed = Signal.new(),
		PlayerAppeared = Signal.new(),
		PlayerDeparted = Signal.new(),
		ProjectionReconciled = Signal.new(),
	}, TeleportClient)

	deps.Communication:RegisterHandler(TeleportProtocol.MessageTypes.LocalArrived, function(payload)
		if self._stopped then
			return
		end
		self:_handleArrival(payload)
	end)
	deps.Communication:RegisterHandler(TeleportProtocol.MessageTypes.LocalAttemptStarted, function(payload)
		if self._stopped then
			return
		end
		self:_handleAttemptStarted(payload)
	end)
	deps.Communication:RegisterHandler(TeleportProtocol.MessageTypes.LocalAttemptAccepted, function(payload)
		if self._stopped then
			return
		end
		self:_handleAttemptAccepted(payload)
	end)
	deps.Communication:RegisterHandler(TeleportProtocol.MessageTypes.LocalAttemptFailed, function(payload)
		if self._stopped then
			return
		end
		self:_handleAttemptFailed(payload)
	end)
	deps.Communication:RegisterHandler(TeleportProtocol.MessageTypes.PlayerAppeared, function(payload)
		if self._stopped then
			return
		end
		self:_handlePlayerAppeared(payload)
	end)
	deps.Communication:RegisterHandler(TeleportProtocol.MessageTypes.PlayerDeparted, function(payload)
		if self._stopped then
			return
		end
		self:_handlePlayerDeparted(payload)
	end)
	return self
end

function TeleportClient:_rememberTerminal(attemptId: string)
	if self._terminalAttempts[attemptId] then
		return
	end
	self._terminalAttempts[attemptId] = true
	table.insert(self._terminalOrder, attemptId)
	if #self._terminalOrder > TERMINAL_HISTORY_LIMIT then
		local retired = table.remove(self._terminalOrder, 1)
		self._terminalAttempts[retired] = nil
	end
end

function TeleportClient:_handleArrival(payload: any)
	local valid, arrival, reason = TeleportProtocol.ValidateSessionSnapshot(payload)
	assert(valid, reason or "Invalid local arrival")
	if sameArrival(self._arrival, arrival) then
		return
	end
	self._arrival = arrival
	self._attempt = nil
	self.LocalArrived:Fire(copy(arrival))
end

function TeleportClient:_handleAttemptStarted(payload: any)
	local valid, attempt, reason = TeleportProtocol.ValidateAttemptSnapshot(payload)
	assert(valid and attempt.State == "Started", reason or "Invalid started attempt")
	assert(self._attempt == nil, "Attempt started while another attempt is active")
	assert(not self._terminalAttempts[attempt.AttemptId], "Terminal attempt cannot restart")
	self._attempt = attempt
	self.LocalAttemptStarted:Fire(copy(attempt))
end

function TeleportClient:_handleAttemptAccepted(payload: any)
	local valid, attempt, reason = TeleportProtocol.ValidateAttemptSnapshot(payload)
	assert(valid and attempt.State == "Accepted", reason or "Invalid accepted attempt")
	local current = self._attempt
	assert(
		current ~= nil and current.State == "Started" and current.AttemptId == attempt.AttemptId,
		"Attempt acceptance does not match Started state"
	)
	self._attempt = attempt
	self.LocalAttemptAccepted:Fire(copy(attempt))
end

function TeleportClient:_handleAttemptFailed(payload: any)
	local valid, failure, reason = TeleportProtocol.ValidateFailure(payload)
	assert(valid, reason or "Invalid attempt failure")
	if self._terminalAttempts[failure.AttemptId] then
		return
	end
	local current = self._attempt
	assert(current ~= nil and current.AttemptId == failure.AttemptId, "Attempt failure does not match active attempt")
	self._attempt = nil
	self:_rememberTerminal(failure.AttemptId)
	self.LocalAttemptFailed:Fire(copy(current), copy(failure))
end

function TeleportClient:_handlePlayerAppeared(payload: any)
	local valid, appearance, reason = TeleportProtocol.ValidateAppearance(payload)
	assert(valid, reason or "Invalid player appearance")
	local localPlayer = self._players:GetLocalPlayer()
	assert(appearance.UserId ~= localPlayer.UserId, "Local player cannot appear in shared presentation")
	local current = self._presentPlayers[appearance.UserId]
	if sameAppearance(current, appearance) then
		return
	end
	assert(current == nil, "Player appearance changed without departure")
	self._presentPlayers[appearance.UserId] = appearance
	self.PlayerAppeared:Fire(copy(appearance))
end

function TeleportClient:_handlePlayerDeparted(payload: any)
	local valid, departure, reason = TeleportProtocol.ValidateDeparture(payload)
	assert(valid, reason or "Invalid player departure")
	if self._presentPlayers[departure.UserId] == nil then
		return
	end
	self._presentPlayers[departure.UserId] = nil
	self.PlayerDeparted:Fire(copy(departure))
end

function TeleportClient:PrepareSnapshot(payload: any): any
	assert(not self._stopped, "TeleportClient is stopped")
	local valid, snapshot, reason = TeleportProtocol.ValidateBootstrapResponse(payload, self._maxPresentPlayers)
	assert(valid, reason or "Invalid Teleport snapshot")
	local localPlayer = self._players:GetLocalPlayer()
	local presentPlayers = {}
	for _, appearance in snapshot.PresentPlayers do
		assert(appearance.UserId ~= localPlayer.UserId, "Teleport snapshot includes local player appearance")
		assert(presentPlayers[appearance.UserId] == nil, "Teleport snapshot contains duplicate player")
		presentPlayers[appearance.UserId] = appearance
	end
	return {
		Arrival = snapshot.Arrival,
		Attempt = snapshot.Attempt,
		PresentPlayers = presentPlayers,
	}
end

function TeleportClient:ApplyPreparedSnapshot(snapshot: any)
	assert(not self._stopped, "TeleportClient is stopped")
	self._arrival = snapshot.Arrival
	self._attempt = snapshot.Attempt
	self._presentPlayers = snapshot.PresentPlayers
	table.clear(self._terminalAttempts)
	table.clear(self._terminalOrder)
	self.ProjectionReconciled:Fire()
end

function TeleportClient:ApplySnapshot(payload: any)
	self:ApplyPreparedSnapshot(self:PrepareSnapshot(payload))
end

function TeleportClient:Initialize()
	if self._initialized then
		return
	end
	assert(not self._stopped, "TeleportClient is stopped")
	local requestOk, response, requestError = self._communication:Request(
		TeleportProtocol.RequestTypes.Bootstrap,
		{}
	)
	assert(requestOk, `Teleport bootstrap failed: {requestError or "Unavailable"}`)
	self:ApplySnapshot(response)
	self._initialized = true
end

function TeleportClient:GetLocalArrival(): any?
	return copy(self._arrival)
end

function TeleportClient:GetLocalAttempt(): any?
	return copy(self._attempt)
end

function TeleportClient:GetPresentPlayers(): { [number]: any }
	local result = {}
	for userId, appearance in self._presentPlayers do
		result[userId] = copy(appearance)
	end
	return result
end

function TeleportClient:Stop()
	if self._stopped then
		return
	end
	self._stopped = true
	self._initialized = false
	self._arrival = nil
	self._attempt = nil
	table.clear(self._presentPlayers)
	table.clear(self._terminalAttempts)
	table.clear(self._terminalOrder)
	self.LocalArrived:Destroy()
	self.LocalAttemptStarted:Destroy()
	self.LocalAttemptAccepted:Destroy()
	self.LocalAttemptFailed:Destroy()
	self.PlayerAppeared:Destroy()
	self.PlayerDeparted:Destroy()
	self.ProjectionReconciled:Destroy()
end

return TeleportClient
