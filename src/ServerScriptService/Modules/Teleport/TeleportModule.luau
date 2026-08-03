--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CommunicationProtocol = require(ReplicatedStorage.Shared.Communication.CommunicationProtocol)
local TeleportProtocol = require(ReplicatedStorage.Shared.Teleport.TeleportProtocol)
local Logger = require(ReplicatedStorage.Shared.Util.Logger)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)

type SessionRecord = {
	SessionId: string,
	EntryKind: string,
	SourcePlaceId: number?,
}

type TeleportDestinationSnapshot =
	{ Kind: "Public", PlaceId: number }
	| { Kind: "ServerInstance", PlaceId: number, ServerInstanceId: string }
	| { Kind: "ReservedServer", PlaceId: number, ReservedServerAccessCode: string }
	| { Kind: "NewReservedServer", PlaceId: number }

type PendingFailure = {
	Code: string,
	Error: string,
}

type AttemptRecord = {
	AttemptId: string,
	State: string,
	Destination: TeleportDestinationSnapshot,
	Options: any?,
	PendingFailure: PendingFailure?,
}

local MAX_SELECTOR_LENGTH = 128
local MAX_FAILURE_LENGTH = 160

local TeleportModule = {}
TeleportModule.__index = TeleportModule

local function isFinitePositiveInteger(value: any): boolean
	return typeof(value) == "number"
		and value == value
		and value ~= math.huge
		and value ~= -math.huge
		and value % 1 == 0
		and value > 0
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

local function isValidSelector(value: any): boolean
	return typeof(value) == "string"
		and #value > 0
		and #value <= MAX_SELECTOR_LENGTH
		and string.find(value, "[%c]") == nil
end

local function copySession(record: SessionRecord): any
	return {
		SessionId = record.SessionId,
		EntryKind = record.EntryKind,
		SourcePlaceId = record.SourcePlaceId,
	}
end

local function copyAttempt(record: AttemptRecord): any
	return {
		AttemptId = record.AttemptId,
		State = record.State,
		DestinationKind = record.Destination.Kind,
		PlaceId = record.Destination.PlaceId,
	}
end

local function copyAppearance(player: any, record: SessionRecord): any
	return {
		UserId = player.UserId,
		EntryKind = record.EntryKind,
		SourcePlaceId = record.SourcePlaceId,
	}
end

local function sanitizeError(value: any): string
	local text = string.gsub(tostring(value), "[%c]", " ")
	if #text > MAX_FAILURE_LENGTH then
		return string.sub(text, 1, MAX_FAILURE_LENGTH)
	end
	return text
end

local function defaultIsPlayer(value: any): boolean
	return typeof(value) == "Instance" and value:IsA("Player")
end

function TeleportModule.new(deps: {
	TeleportService: any,
	HttpService: any,
	PlayersModule: any,
	Communication: any,
	Policy: any,
	PlaceId: number?,
	TeleportOptionsFactory: (() -> any)?,
	IsPlayer: ((any) -> boolean)?,
	Logger: any?,
})
	assert(typeof(deps) == "table", "Teleport dependencies required")
	local currentPlaceId = deps.PlaceId or game.PlaceId
	assert(
		currentPlaceId == 0 or isFinitePositiveInteger(currentPlaceId),
		"Current PlaceId must be zero or a positive integer"
	)
	local allowedPlaceIds = {}
	for placeId, enabled in deps.Policy.AllowedPlaceIds do
		allowedPlaceIds[placeId] = enabled
	end
	if currentPlaceId == 0 then
		assert(next(allowedPlaceIds) == nil, "An unpublished place must use an inert Teleport policy")
	end
	local policy = table.freeze({
		AllowedPlaceIds = table.freeze(allowedPlaceIds),
		MaxGroupSize = deps.Policy.MaxGroupSize,
		MaxSessionIdLength = deps.Policy.MaxSessionIdLength,
		MaxAttemptIdLength = deps.Policy.MaxAttemptIdLength,
	})
	return setmetatable({
		_teleportService = deps.TeleportService,
		_httpService = deps.HttpService,
		_players = deps.PlayersModule,
		_communication = deps.Communication,
		_policy = policy,
		_placeId = currentPlaceId,
		_newTeleportOptions = deps.TeleportOptionsFactory or function()
			return Instance.new("TeleportOptions")
		end,
		_isPlayer = deps.IsPlayer or defaultIsPlayer,
		_logger = deps.Logger or Logger.new("Teleport.Server", "info"),
		_sessions = {} :: { [any]: SessionRecord },
		_attempts = {} :: { [any]: AttemptRecord },
		_observerDisconnect = nil :: (() -> ())?,
		_initFailedConnection = nil :: any,
		_initialized = false,
		PlayerArrived = Signal.new(),
		AttemptStarted = Signal.new(),
		AttemptAccepted = Signal.new(),
		AttemptFailed = Signal.new(),
		PlayerDeparted = Signal.new(),
	}, TeleportModule)
end

function TeleportModule:_newGuid(): string
	for _ = 1, 16 do
		local guid = self._httpService:GenerateGUID(false)
		if TeleportProtocol.IsCanonicalGuid(guid) then
			local collision = false
			for _, session in self._sessions do
				if session.SessionId == guid then
					collision = true
					break
				end
			end
			if not collision then
				for _, attempt in self._attempts do
					if attempt.AttemptId == guid then
						collision = true
						break
					end
				end
			end
			if not collision then
				return guid
			end
		end
	end
	error("Unable to allocate a unique canonical teleport GUID")
end

function TeleportModule:_queue(player: any, messageType: string, payload: any, priority: string)
	local ok, queued = pcall(function()
		return self._communication:Queue(player, messageType, payload, nil, {
			Priority = priority,
		})
	end)
	if not ok or not queued then
		self._logger:Warn("teleport_projection_queue_failed", {
			UserId = player.UserId,
			MessageType = messageType,
		})
		if priority ~= CommunicationProtocol.Priorities.Presentation then
			local recoveryOk, recoveryError = pcall(function()
				self._communication:RequireResync(player, "TeleportProjectionQueueFailed")
			end)
			if not recoveryOk then
				self._logger:Error("teleport_projection_recovery_failed", {
					UserId = player.UserId,
					MessageType = messageType,
					Error = sanitizeError(recoveryError),
				})
			end
		end
	end
end

function TeleportModule:_validateContinuation(player: any, joinData: any): SessionRecord?
	if typeof(joinData) ~= "table" then
		return nil
	end
	local sourcePlaceId = joinData.SourcePlaceId
	if not isFinitePositiveInteger(sourcePlaceId) or self._policy.AllowedPlaceIds[sourcePlaceId] ~= true then
		return nil
	end
	local teleportData = joinData.TeleportData
	if not hasOnlyKeys(teleportData, { [TeleportProtocol.EnvelopeKey] = true }) then
		return nil
	end
	local envelope = teleportData[TeleportProtocol.EnvelopeKey]
	if not hasOnlyKeys(envelope, {
		Version = true,
		SourcePlaceId = true,
		AttemptId = true,
		SessionsByUserId = true,
	}) then
		return nil
	end
	if envelope.Version ~= TeleportProtocol.EnvelopeVersion
		or envelope.SourcePlaceId ~= sourcePlaceId
		or not TeleportProtocol.IsCanonicalGuid(envelope.AttemptId)
	then
		return nil
	end
	local sessions = envelope.SessionsByUserId
	if typeof(sessions) ~= "table" or getmetatable(sessions) ~= nil then
		return nil
	end
	local sessionCount = 0
	for userId, sessionId in sessions do
		if typeof(userId) ~= "string"
			or #userId == 0
			or #userId > 20
			or string.match(userId, "^%d+$") == nil
			or tostring(tonumber(userId)) ~= userId
			or not TeleportProtocol.IsCanonicalGuid(sessionId)
		then
			return nil
		end
		sessionCount += 1
		if sessionCount > self._policy.MaxGroupSize then
			return nil
		end
	end
	local sessionId = sessions[tostring(player.UserId)]
	if not TeleportProtocol.IsCanonicalGuid(sessionId) then
		return nil
	end
	return {
		SessionId = sessionId,
		EntryKind = "Teleported",
		SourcePlaceId = sourcePlaceId,
	}
end

function TeleportModule:_onPlayerAdded(player: any)
	if self._sessions[player] ~= nil or not self._isPlayer(player) then
		return
	end
	local joinOk, joinData = pcall(function()
		return player:GetJoinData()
	end)
	local record = if joinOk then self:_validateContinuation(player, joinData) else nil
	if record == nil then
		record = {
			SessionId = self:_newGuid(),
			EntryKind = "External",
			SourcePlaceId = nil,
		}
	end
	self._sessions[player] = record
	local snapshot = copySession(record)
	self.PlayerArrived:Fire(player, snapshot)
	self:_queue(
		player,
		TeleportProtocol.MessageTypes.LocalArrived,
		snapshot,
		CommunicationProtocol.Priorities.State
	)
	local appearance = copyAppearance(player, record)
	for otherPlayer in self._sessions do
		if otherPlayer ~= player then
			self:_queue(
				otherPlayer,
				TeleportProtocol.MessageTypes.PlayerAppeared,
				appearance,
				CommunicationProtocol.Priorities.Presentation
			)
		end
	end
end

function TeleportModule:_onPlayerRemoving(player: any)
	local session = self._sessions[player]
	if session == nil then
		return
	end
	local departure = {
		HadActiveAttempt = self._attempts[player] ~= nil,
	}
	self._attempts[player] = nil
	self._sessions[player] = nil
	self.PlayerDeparted:Fire(player, departure)
	local safeDeparture = { UserId = player.UserId }
	for otherPlayer in self._sessions do
		self:_queue(
			otherPlayer,
			TeleportProtocol.MessageTypes.PlayerDeparted,
			safeDeparture,
			CommunicationProtocol.Priorities.Presentation
		)
	end
end

function TeleportModule:_bootstrap(player: any): (boolean, any?, string?)
	local snapshot = self:BuildClientSnapshot(player)
	if snapshot == nil then
		return false, nil, "Unavailable"
	end
	return true, snapshot, nil
end

function TeleportModule:BuildClientSnapshot(player: any): any?
	local session = self._sessions[player]
	if session == nil then
		return nil
	end
	local presentPlayers = {}
	for presentPlayer, presentSession in self._sessions do
		if presentPlayer ~= player then
			table.insert(presentPlayers, copyAppearance(presentPlayer, presentSession))
		end
	end
	return {
		Arrival = copySession(session),
		Attempt = if self._attempts[player] then copyAttempt(self._attempts[player]) else nil,
		PresentPlayers = presentPlayers,
	}
end

function TeleportModule:Initialize()
	if self._initialized then
		return
	end
	self._initialized = true
	self._communication:RegisterRequestHandler(
		TeleportProtocol.RequestTypes.Bootstrap,
		TeleportProtocol.ValidateEmptyRequest,
		function(player, _payload)
			return self:_bootstrap(player)
		end
	)
	self._observerDisconnect = self._players:ObservePlayers(function(player)
		self:_onPlayerAdded(player)
	end, function(player)
		self:_onPlayerRemoving(player)
	end)
	self._initFailedConnection = self._teleportService.TeleportInitFailed:Connect(function(
		player,
		teleportResult,
		errorMessage,
		_placeId,
		teleportOptions
	)
		self:_onTeleportInitFailed(player, teleportResult, errorMessage, teleportOptions)
	end)
end

function TeleportModule:GetSession(player: any): any?
	local record = self._sessions[player]
	return if record then copySession(record) else nil
end

function TeleportModule:GetAttempt(player: any): any?
	local record = self._attempts[player]
	return if record then copyAttempt(record) else nil
end

function TeleportModule:_validateDestination(destination: any): (TeleportDestinationSnapshot?, string?)
	if typeof(destination) ~= "table" or getmetatable(destination) ~= nil then
		return nil, "Destination must be a plain table"
	end
	local kind = destination.Kind
	if not isFinitePositiveInteger(destination.PlaceId)
		or self._policy.AllowedPlaceIds[destination.PlaceId] ~= true
	then
		return nil, "Destination place is not allowed"
	end

	if kind == "Public" then
		if not hasOnlyKeys(destination, { Kind = true, PlaceId = true }) then
			return nil, "Destination shape is invalid"
		end
		return table.freeze({
			Kind = "Public",
			PlaceId = destination.PlaceId,
		}), nil
	elseif kind == "ServerInstance" then
		if not hasOnlyKeys(destination, { Kind = true, PlaceId = true, ServerInstanceId = true }) then
			return nil, "Destination shape is invalid"
		end
		if not isValidSelector(destination.ServerInstanceId) then
			return nil, "Destination selector is invalid"
		end
		return table.freeze({
			Kind = "ServerInstance",
			PlaceId = destination.PlaceId,
			ServerInstanceId = destination.ServerInstanceId,
		}), nil
	elseif kind == "ReservedServer" then
		if not hasOnlyKeys(destination, { Kind = true, PlaceId = true, ReservedServerAccessCode = true }) then
			return nil, "Destination shape is invalid"
		end
		if not isValidSelector(destination.ReservedServerAccessCode) then
			return nil, "Destination selector is invalid"
		end
		return table.freeze({
			Kind = "ReservedServer",
			PlaceId = destination.PlaceId,
			ReservedServerAccessCode = destination.ReservedServerAccessCode,
		}), nil
	elseif kind == "NewReservedServer" then
		if not hasOnlyKeys(destination, { Kind = true, PlaceId = true }) then
			return nil, "Destination shape is invalid"
		end
		return table.freeze({
			Kind = "NewReservedServer",
			PlaceId = destination.PlaceId,
		}), nil
	end
	return nil, "Unknown destination kind"
end

function TeleportModule:_validatePlayers(players: any): (boolean, { any }?, string?)
	if typeof(players) ~= "table" or getmetatable(players) ~= nil then
		return false, nil, "Players must be a dense array"
	end
	local count = 0
	for key in players do
		if not isFinitePositiveInteger(key) then
			return false, nil, "Players must be a dense array"
		end
		count += 1
	end
	if count < 1 or count > math.min(self._policy.MaxGroupSize, 50) then
		return false, nil, "Player group size is invalid"
	end
	local seen = {}
	local participants = table.create(count)
	for index = 1, count do
		local player = players[index]
		if player == nil or not self._isPlayer(player) then
			return false, nil, "Player entry is invalid"
		end
		if seen[player] then
			return false, nil, "Duplicate player"
		end
		seen[player] = true
		if self._sessions[player] == nil then
			return false, nil, "Player is not present"
		end
		if self._attempts[player] ~= nil then
			return false, nil, "Player already has an active attempt"
		end
		participants[index] = player
	end
	return true, table.freeze(participants), nil
end

function TeleportModule:_publishAttempt(player: any, record: AttemptRecord, messageType: string, signal: any)
	local snapshot = copyAttempt(record)
	signal:Fire(player, snapshot)
	self:_queue(player, messageType, snapshot, CommunicationProtocol.Priorities.State)
end

function TeleportModule:_failAttempt(player: any, record: AttemptRecord, code: string, message: any)
	if self._attempts[player] ~= record then
		return
	end
	self._attempts[player] = nil
	local attemptSnapshot = copyAttempt(record)
	local failure = {
		Code = code,
		Error = sanitizeError(message),
	}
	self.AttemptFailed:Fire(player, attemptSnapshot, failure)
	self:_queue(player, TeleportProtocol.MessageTypes.LocalAttemptFailed, {
		AttemptId = record.AttemptId,
		Code = failure.Code,
		Error = failure.Error,
	}, CommunicationProtocol.Priorities.State)
end

function TeleportModule:_onTeleportInitFailed(player: any, teleportResult: any, errorMessage: any, options: any?)
	local record = self._attempts[player]
	if record == nil then
		return
	end
	local dataOk, teleportData = pcall(function()
		return options:GetTeleportData()
	end)
	local envelope = if dataOk and typeof(teleportData) == "table"
		then teleportData[TeleportProtocol.EnvelopeKey]
		else nil
	if typeof(envelope) ~= "table" or envelope.AttemptId ~= record.AttemptId then
		return
	end
	local failure = {
		Code = sanitizeError(teleportResult),
		Error = sanitizeError(errorMessage),
	}
	if record.State == "Started" then
		if record.PendingFailure == nil then
			record.PendingFailure = failure
		end
		return
	end
	if record.State == "Accepted" then
		self:_failAttempt(player, record, failure.Code, failure.Error)
	end
end

function TeleportModule:Teleport(players: any, destination: any): any
	local destinationSnapshot, destinationError = self:_validateDestination(destination)
	if destinationSnapshot == nil then
		return { Ok = false, Code = "InvalidDestination", Error = destinationError :: string }
	end
	local playersOk, participants, playersError = self:_validatePlayers(players)
	if not playersOk then
		return { Ok = false, Code = "InvalidPlayers", Error = playersError :: string }
	end
	local participantSnapshot = participants :: { any }

	local attemptId = self:_newGuid()
	for _, player in participantSnapshot do
		self._attempts[player] = {
			AttemptId = attemptId,
			State = "Started",
			Destination = destinationSnapshot,
			Options = nil,
			PendingFailure = nil,
		}
	end
	for _, player in participantSnapshot do
		self:_publishAttempt(
			player,
			self._attempts[player],
			TeleportProtocol.MessageTypes.LocalAttemptStarted,
			self.AttemptStarted
		)
	end

	local callOk, callResult = pcall(function()
		local options = self._newTeleportOptions()
		local sessionsByUserId = {}
		for _, player in participantSnapshot do
			sessionsByUserId[tostring(player.UserId)] = self._sessions[player].SessionId
			self._attempts[player].Options = options
		end
		options:SetTeleportData({
			[TeleportProtocol.EnvelopeKey] = {
				Version = TeleportProtocol.EnvelopeVersion,
				SourcePlaceId = self._placeId,
				AttemptId = attemptId,
				SessionsByUserId = sessionsByUserId,
			},
		})
		if destinationSnapshot.Kind == "ServerInstance" then
			options.ServerInstanceId = destinationSnapshot.ServerInstanceId
		elseif destinationSnapshot.Kind == "ReservedServer" then
			options.ReservedServerAccessCode = destinationSnapshot.ReservedServerAccessCode
		elseif destinationSnapshot.Kind == "NewReservedServer" then
			options.ShouldReserveServer = true
		end
		return self._teleportService:TeleportAsync(destinationSnapshot.PlaceId, participantSnapshot, options)
	end)
	if not callOk then
		for _, player in participantSnapshot do
			local record = self._attempts[player]
			if record ~= nil and record.AttemptId == attemptId then
				self:_failAttempt(player, record, "TeleportRequestFailed", callResult)
			end
		end
		return {
			Ok = false,
			Code = "TeleportRequestFailed",
			Error = sanitizeError(callResult),
			AttemptId = attemptId,
		}
	end
	for _, player in participantSnapshot do
		local record = self._attempts[player]
		if record ~= nil and record.AttemptId == attemptId and record.State == "Started" then
			record.State = "Accepted"
			self:_publishAttempt(
				player,
				record,
				TeleportProtocol.MessageTypes.LocalAttemptAccepted,
				self.AttemptAccepted
			)
			local pendingFailure = record.PendingFailure
			if pendingFailure ~= nil and self._attempts[player] == record then
				self:_failAttempt(player, record, pendingFailure.Code, pendingFailure.Error)
			end
		end
	end
	return { Ok = true, AttemptId = attemptId }
end

function TeleportModule:Stop()
	if not self._initialized then
		return
	end
	self._initialized = false
	if self._observerDisconnect ~= nil then
		self._observerDisconnect()
		self._observerDisconnect = nil
	end
	if self._initFailedConnection ~= nil then
		self._initFailedConnection:Disconnect()
		self._initFailedConnection = nil
	end
	local players = {}
	for player in self._sessions do
		table.insert(players, player)
	end
	for _, player in players do
		self:_onPlayerRemoving(player)
	end
	self.PlayerArrived:Destroy()
	self.AttemptStarted:Destroy()
	self.AttemptAccepted:Destroy()
	self.AttemptFailed:Destroy()
	self.PlayerDeparted:Destroy()
end

return TeleportModule
