--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local CommunicationProtocol = require(ReplicatedStorage.Shared.Communication.CommunicationProtocol)
local CommunicationConfig = require(ReplicatedStorage.Shared.Communication.CommunicationConfig)
local CommunicationSerialize = require(ReplicatedStorage.Shared.Communication.CommunicationSerialize)
local TokenBucket = require(ReplicatedStorage.Shared.Communication.TokenBucket)
local Logger = require(ReplicatedStorage.Shared.Util.Logger)

type MessageHandler = {
	Validate: (payload: any) -> (boolean, any?, string?),
	Handle: (player: Player, payload: any, requestId: string?) -> (),
}

type RequestHandler = {
	Validate: (payload: any) -> (boolean, any?, string?),
	Handle: (player: Player, payload: any) -> (boolean, any?, string?),
}

type QueueEntry = {
	Message: any,
	Priority: string,
	EstimatedBytes: number,
}

type RateState = {
	Invocations: any,
	Count: any,
	Bytes: any,
	RejectionLoggedAt: number?,
	InvalidLoggedAt: number?,
}

type OutboundRateState = {
	Batches: any,
	Bytes: any,
}

type SnapshotRequestState = {
	LastStartedAt: number?,
	InFlight: boolean,
}

local CommunicationServer = {}
CommunicationServer.__index = CommunicationServer

local function ensureFolder(parent: Instance, name: string): Folder
	local existing = parent:FindFirstChild(name)
	if existing ~= nil then
		assert(existing:IsA("Folder"), `{parent:GetFullName()}.{name} must be a Folder`)
		return existing
	end

	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = parent
	return folder
end

local function ensureRemoteEvent(parent: Instance, name: string): RemoteEvent
	local existing = parent:FindFirstChild(name)
	if existing ~= nil then
		assert(existing:IsA("RemoteEvent"), `{parent:GetFullName()}.{name} must be a RemoteEvent`)
		return existing
	end

	local remote = Instance.new("RemoteEvent")
	remote.Name = name
	remote.Parent = parent
	return remote
end

local function ensureRemoteFunction(parent: Instance, name: string): RemoteFunction
	local existing = parent:FindFirstChild(name)
	if existing ~= nil then
		assert(existing:IsA("RemoteFunction"), `{parent:GetFullName()}.{name} must be a RemoteFunction`)
		return existing
	end

	local remote = Instance.new("RemoteFunction")
	remote.Name = name
	remote.Parent = parent
	return remote
end

local function ensureRemotes(): (RemoteEvent, RemoteEvent, RemoteFunction)
	local root = ensureFolder(ReplicatedStorage, "Remotes")
	local folder = ensureFolder(root, CommunicationProtocol.RemoteFolderName)
	local clientToServer = ensureRemoteEvent(folder, CommunicationProtocol.ClientToServerEventName)
	local serverToClient = ensureRemoteEvent(folder, CommunicationProtocol.ServerToClientEventName)
	local request = ensureRemoteFunction(folder, CommunicationProtocol.RequestFunctionName)

	return clientToServer, serverToClient, request
end

function CommunicationServer.new(deps: {
	PlayersModule: any,
	Logger: any?,
	Clock: (() -> number)?,
	Transport: {
		ClientToServer: any,
		ServerToClient: any,
		Request: any,
	}?,
})
	local clientToServer
	local serverToClient
	local request
	if deps.Transport ~= nil then
		clientToServer = deps.Transport.ClientToServer
		serverToClient = deps.Transport.ServerToClient
		request = deps.Transport.Request
	else
		clientToServer, serverToClient, request = ensureRemotes()
	end
	local self = setmetatable({
		_players = deps.PlayersModule,
		_logger = deps.Logger or Logger.new("Communication.Server", "info"),
		_clock = deps.Clock or os.clock,
		_clientToServer = clientToServer,
		_serverToClient = serverToClient,
		_request = request,
		_handlers = {} :: { [string]: MessageHandler },
		_requestHandlers = {} :: { [string]: RequestHandler },
		_outgoing = {} :: { [Player]: { QueueEntry } },
		_outgoingBytes = {} :: { [Player]: number },
		_outgoingSequence = {} :: { [Player]: number },
		_outgoingEpoch = {} :: { [Player]: number },
		_expectedIncomingSequence = {} :: { [Player]: number },
		_ready = {} :: { [Player]: boolean },
		_rate = {} :: { [Player]: RateState },
		_requestRate = {} :: { [Player]: RateState },
		_outboundRate = {} :: { [Player]: OutboundRateState },
		_snapshotRequests = {} :: { [Player]: SnapshotRequestState },
		_resyncQueued = {} :: { [Player]: boolean },
		_droppedPresentation = {} :: { [Player]: number },
		_connections = {} :: { any },
		_initialized = false,
	}, CommunicationServer)
	return self
end

function CommunicationServer:RegisterHandler(
	messageType: string,
	validator: (payload: any) -> (boolean, any?, string?),
	handler: (player: Player, payload: any, requestId: string?) -> ()
)
	assert(
		typeof(messageType) == "string"
			and messageType ~= ""
			and #messageType <= CommunicationConfig.MaxMessageTypeLength,
		"messageType invalid"
	)
	assert(typeof(validator) == "function", "Client message validator required")
	assert(self._handlers[messageType] == nil, `Duplicate communication handler '{messageType}'`)
	self._handlers[messageType] = {
		Validate = validator,
		Handle = handler,
	}
end

function CommunicationServer:RegisterRequestHandler(
	requestType: string,
	validator: (payload: any) -> (boolean, any?, string?),
	handler: (player: Player, payload: any) -> (boolean, any?, string?)
)
	assert(typeof(requestType) == "string" and requestType ~= "", "requestType required")
	assert(#requestType <= CommunicationConfig.MaxRequestTypeLength, "requestType too long")
	assert(typeof(validator) == "function", "Request validator required")
	assert(self._requestHandlers[requestType] == nil, `Duplicate request handler '{requestType}'`)
	self._requestHandlers[requestType] = {
		Validate = validator,
		Handle = handler,
	}
end

function CommunicationServer:_getRequestRateState(player: Player): RateState
	local state = self._requestRate[player]
	if state == nil then
		state = {
			Invocations = TokenBucket.new(
				CommunicationConfig.MaxRequestsPerSecond,
				CommunicationConfig.RequestInvocationBurst,
				self._clock
			),
			Count = TokenBucket.new(1, 1, self._clock),
			Bytes = TokenBucket.new(
				CommunicationConfig.MaxRequestResponseBytesPerSecond,
				CommunicationConfig.RequestResponseByteBurst,
				self._clock
			),
			RejectionLoggedAt = nil,
			InvalidLoggedAt = nil,
		}
		self._requestRate[player] = state
	end
	return state
end

local function reserveRateLimit(state: RateState, allowed: boolean, now: number): (boolean, boolean)
	if allowed then
		return true, false
	end
	local shouldLog = state.RejectionLoggedAt == nil
		or now - state.RejectionLoggedAt >= CommunicationConfig.DiagnosticLogCooldownSeconds
	if shouldLog then
		state.RejectionLoggedAt = now
	end
	return false, shouldLog
end

local function shouldLogInvalid(state: RateState, now: number): boolean
	if state.InvalidLoggedAt ~= nil
		and now - state.InvalidLoggedAt < CommunicationConfig.DiagnosticLogCooldownSeconds
	then
		return false
	end
	state.InvalidLoggedAt = now
	return true
end

function CommunicationServer:_reserveRequestInvocation(player: Player): (boolean, boolean)
	local state = self:_getRequestRateState(player)
	local allowed = state.Invocations:TryConsume(1)
	return reserveRateLimit(state, allowed, self._clock())
end

function CommunicationServer:_reserveRequestBytes(player: Player, estimatedBytes: number): (boolean, boolean)
	local state = self:_getRequestRateState(player)
	local allowed = state.Bytes:TryConsume(estimatedBytes)
	return reserveRateLimit(state, allowed, self._clock())
end

function CommunicationServer:TryBeginSnapshotRequest(player: Player): (boolean, string?)
	local now = self._clock()
	local state = self._snapshotRequests[player]
	if state == nil then
		state = {
			LastStartedAt = nil,
			InFlight = false,
		}
		self._snapshotRequests[player] = state
	end
	if state.InFlight then
		return false, "Busy"
	end
	if state.LastStartedAt ~= nil
		and now - state.LastStartedAt < CommunicationConfig.SnapshotRequestCooldownSeconds
	then
		return false, "RateLimited"
	end
	state.LastStartedAt = now
	state.InFlight = true
	return true, nil
end

function CommunicationServer:EndSnapshotRequest(player: Player)
	local state = self._snapshotRequests[player]
	if state ~= nil then
		state.InFlight = false
	end
end

function CommunicationServer:_finalizeRequestResponse(player: Player, requestType: string, response: any)
	local responseValid, _, responseBytes = CommunicationSerialize.inspect(response, {
		MaxBytes = CommunicationConfig.MaxSingleMessageEstimatedBytes,
	})
	if not responseValid then
		self._logger:Warn("request_response_rejected", {
			UserId = player.UserId,
			RequestType = requestType,
			EstimatedBytes = responseBytes,
		})
		return {
			Ok = false,
			Code = "InternalError",
		}
	end
	local bytesAllowed, shouldLog = self:_reserveRequestBytes(player, responseBytes)
	if not bytesAllowed then
		if shouldLog then
			self._logger:Warn("request_response_rate_limited", {
				UserId = player.UserId,
				RequestType = requestType,
				EstimatedBytes = responseBytes,
			})
		end
		return {
			Ok = false,
			Code = "RateLimited",
		}
	end
	return response
end

function CommunicationServer:_handleRequest(player: Player, request: any)
	local invocationAllowed, shouldLogInvocation = self:_reserveRequestInvocation(player)
	if not invocationAllowed then
		if shouldLogInvocation then
			self._logger:Warn("request_rate_limited", { UserId = player.UserId })
		end
		return {
			Ok = false,
			Code = "RateLimited",
		}
	end

	local valid, _, estimatedBytes = CommunicationSerialize.inspect(request, {
		MaxBytes = CommunicationConfig.MaxSingleMessageEstimatedBytes,
	})
	local bytesAllowed, shouldLogBytes = self:_reserveRequestBytes(player, estimatedBytes)
	if not bytesAllowed then
		if shouldLogBytes then
			self._logger:Warn("request_rate_limited", { UserId = player.UserId })
		end
		return {
			Ok = false,
			Code = "RateLimited",
		}
	end
	if not valid
		or typeof(request) ~= "table"
		or typeof(request.Type) ~= "string"
		or request.Type == ""
		or #request.Type > CommunicationConfig.MaxRequestTypeLength
	then
		if shouldLogInvalid(self:_getRequestRateState(player), self._clock()) then
			self._logger:Warn("invalid_request", { UserId = player.UserId })
		end
		return {
			Ok = false,
			Code = "Unavailable",
		}
	end

	local handler = self._requestHandlers[request.Type]
	if handler == nil then
		return self:_finalizeRequestResponse(player, request.Type, {
			Ok = false,
			Code = "Unavailable",
		})
	end

	local payload = request.Payload
	local validatorOk, payloadValid, sanitized, _validationError = pcall(handler.Validate, payload)
	if not validatorOk then
		self._logger:Error("request_validator_failed", {
			UserId = player.UserId,
			RequestType = request.Type,
			Error = tostring(payloadValid),
		})
		return self:_finalizeRequestResponse(player, request.Type, {
			Ok = false,
			Code = "InternalError",
		})
	end
	if not payloadValid then
		return self:_finalizeRequestResponse(player, request.Type, {
			Ok = false,
			Code = "Unavailable",
		})
	end
	payload = sanitized

	local callOk, handled, result, failureCode = pcall(handler.Handle, player, payload)
	if not callOk then
		self._logger:Error("request_handler_failed", {
			UserId = player.UserId,
			RequestType = request.Type,
			Error = tostring(handled),
		})
		return self:_finalizeRequestResponse(player, request.Type, {
			Ok = false,
			Code = "InternalError",
		})
	end
	if not handled then
		return self:_finalizeRequestResponse(player, request.Type, {
			Ok = false,
			Code = if typeof(failureCode) == "string" then failureCode else "Unavailable",
		})
	end

	return self:_finalizeRequestResponse(player, request.Type, {
		Ok = true,
		Payload = result,
	})
end

function CommunicationServer:HandleRequest(player: Player, request: any)
	return self:_handleRequest(player, request)
end

function CommunicationServer:_setResyncRequired(player: Player, reason: string)
	if self._resyncQueued[player] then
		return
	end
	local message = {
		Type = CommunicationProtocol.SystemMessages.ResyncRequired,
		Payload = {
			Reason = reason,
		},
	}
	local _, _, estimatedBytes = CommunicationSerialize.inspect(message, {
		MaxBytes = CommunicationConfig.MaxSingleMessageEstimatedBytes,
	})
	self._outgoing[player] = {
		{
			Message = message,
			Priority = CommunicationProtocol.Priorities.Critical,
			EstimatedBytes = estimatedBytes,
		},
	}
	self._outgoingBytes[player] = estimatedBytes
	self._resyncQueued[player] = true
	self._logger:Warn("outgoing_queue_forced_resync", {
		UserId = player.UserId,
		Reason = reason,
	})
end

function CommunicationServer:_dropOldestPresentation(player: Player): boolean
	local queue = self._outgoing[player]
	if queue == nil then
		return false
	end
	for index, entry in queue do
		if entry.Priority == CommunicationProtocol.Priorities.Presentation then
			table.remove(queue, index)
			self._outgoingBytes[player] = math.max(
				0,
				(self._outgoingBytes[player] or 0) - entry.EstimatedBytes
			)
			self._droppedPresentation[player] = (self._droppedPresentation[player] or 0) + 1
			return true
		end
	end
	return false
end

function CommunicationServer:Queue(
	player: Player,
	messageType: string,
	payload: any,
	requestId: string?,
	options: { Priority: string? }?
): boolean
	assert(
		typeof(messageType) == "string"
			and messageType ~= ""
			and #messageType <= CommunicationConfig.MaxMessageTypeLength,
		"messageType invalid"
	)
	if requestId ~= nil
		and (typeof(requestId) ~= "string" or #requestId > CommunicationConfig.MaxRequestIdLength)
	then
		self._logger:Warn("outgoing_request_id_invalid", {
			UserId = player.UserId,
			MessageType = messageType,
		})
		return false
	end
	if self._resyncQueued[player] and messageType ~= CommunicationProtocol.SystemMessages.ResyncRequired then
		return false
	end

	local priority = if options and options.Priority
		then options.Priority
		else CommunicationProtocol.Priorities.State
	assert(
		priority == CommunicationProtocol.Priorities.Critical
			or priority == CommunicationProtocol.Priorities.State
			or priority == CommunicationProtocol.Priorities.Presentation,
		"Unknown communication priority"
	)

	local message = {
		Type = messageType,
		Payload = payload,
		RequestId = requestId,
	}
	local valid, issues, estimatedBytes = CommunicationSerialize.inspect(message, {
		MaxBytes = CommunicationConfig.MaxSingleMessageEstimatedBytes,
	})
	if not valid then
		self._logger:Error("outgoing_message_invalid", {
			UserId = player.UserId,
			MessageType = messageType,
			Error = if issues[1] then issues[1].Reason else "message_too_large",
			EstimatedBytes = estimatedBytes,
		})
		if priority ~= CommunicationProtocol.Priorities.Presentation then
			self:_setResyncRequired(player, "InvalidOrOversizedStateMessage")
		end
		return false
	end

	local queue = self._outgoing[player]
	if queue == nil then
		queue = {}
		self._outgoing[player] = queue
	end
	local queueBytes = self._outgoingBytes[player] or 0
	local function exceedsLimit(): boolean
		return #queue + 1 > CommunicationConfig.MaxQueuedMessagesPerPeer
			or queueBytes + estimatedBytes > CommunicationConfig.MaxQueuedPayloadBytesPerPeer
	end
	while exceedsLimit() do
		if not self:_dropOldestPresentation(player) then
			break
		end
		queueBytes = self._outgoingBytes[player] or 0
	end

	if exceedsLimit() then
		if priority == CommunicationProtocol.Priorities.Presentation then
			self._droppedPresentation[player] = (self._droppedPresentation[player] or 0) + 1
			return false
		end
		self:_setResyncRequired(player, "OutgoingQueueOverflow")
		return false
	end

	table.insert(queue, {
		Message = message,
		Priority = priority,
		EstimatedBytes = estimatedBytes,
	})
	self._outgoingBytes[player] = queueBytes + estimatedBytes
	return true
end

function CommunicationServer:BeginSnapshot(player: Player)
	self._ready[player] = false
	self._outgoing[player] = {}
	self._outgoingBytes[player] = 0
	self._outgoingSequence[player] = 0
	self._outgoingEpoch[player] = (self._outgoingEpoch[player] or 0) + 1
	self._resyncQueued[player] = false
	return self._outgoingEpoch[player]
end

function CommunicationServer:RequireResync(player: Player, reason: string)
	assert(typeof(reason) == "string" and reason ~= "", "Resync reason required")
	self:_setResyncRequired(player, reason)
end

function CommunicationServer:GetNextSnapshotEpoch(player: Player): number
	return (self._outgoingEpoch[player] or 0) + 1
end

function CommunicationServer:SetClientReady(player: Player, epoch: number): boolean
	if self._outgoingEpoch[player] ~= epoch then
		self._logger:Warn("client_ready_epoch_mismatch", {
			UserId = player.UserId,
			Expected = self._outgoingEpoch[player],
			Got = epoch,
		})
		return false
	end
	self._ready[player] = true
	return true
end

function CommunicationServer:IsClientReady(player: Player): boolean
	return self._ready[player] == true
end

function CommunicationServer:_getMessageRateState(player: Player): RateState
	local state = self._rate[player]
	if state == nil then
		state = {
			Invocations = TokenBucket.new(
				CommunicationConfig.MaxBatchInvocationsPerSecond,
				CommunicationConfig.BatchInvocationBurst,
				self._clock
			),
			Count = TokenBucket.new(
				CommunicationConfig.MaxMessagesPerSecond,
				CommunicationConfig.MessageBurst,
				self._clock
			),
			Bytes = TokenBucket.new(
				CommunicationConfig.MaxBytesPerSecond,
				CommunicationConfig.ByteBurst,
				self._clock
			),
			RejectionLoggedAt = nil,
			InvalidLoggedAt = nil,
		}
		self._rate[player] = state
	end
	return state
end

function CommunicationServer:_reserveBatchInvocation(player: Player): (boolean, boolean)
	local state = self:_getMessageRateState(player)
	local allowed = state.Invocations:TryConsume(1)
	return reserveRateLimit(state, allowed, self._clock())
end

function CommunicationServer:_reserveBatchPayload(
	player: Player,
	messageCount: number,
	estimatedBytes: number
): (boolean, boolean)
	local state = self:_getMessageRateState(player)
	local allowed = TokenBucket.tryConsumeAll({
		{
			Bucket = state.Count,
			Amount = messageCount,
		},
		{
			Bucket = state.Bytes,
			Amount = estimatedBytes,
		},
	})
	return reserveRateLimit(state, allowed, self._clock())
end

function CommunicationServer:_handleBatch(player: Player, batch: any)
	local invocationAllowed, shouldLogInvocation = self:_reserveBatchInvocation(player)
	if not invocationAllowed then
		if shouldLogInvocation then
			self._logger:Warn("message_rate_limited", { UserId = player.UserId })
		end
		return
	end

	if typeof(batch) ~= "table"
		or typeof(batch.Sequence) ~= "number"
		or batch.Sequence < 1
		or batch.Sequence ~= math.floor(batch.Sequence)
		or typeof(batch.Messages) ~= "table"
	then
		if shouldLogInvalid(self:_getMessageRateState(player), self._clock()) then
			self._logger:Warn("invalid_batch_envelope", { UserId = player.UserId })
		end
		return
	end
	local denseMessages, messageCount =
		CommunicationSerialize.inspectDenseArray(batch.Messages, CommunicationConfig.MaxMessagesPerBatch)
	if not denseMessages then
		if shouldLogInvalid(self:_getMessageRateState(player), self._clock()) then
			self._logger:Warn("batch_message_limit", { UserId = player.UserId, Count = messageCount })
		end
		return
	end
	local serializable, serializeIssues, estimatedBytes = CommunicationSerialize.inspect(batch, {
		MaxBytes = CommunicationConfig.MaxEstimatedPayloadBytes,
	})
	local payloadAllowed, shouldLogPayload = self:_reserveBatchPayload(player, messageCount, estimatedBytes)
	if not payloadAllowed then
		if shouldLogPayload then
			self._logger:Warn("message_rate_limited", { UserId = player.UserId })
		end
		return
	end
	if not serializable then
		if shouldLogInvalid(self:_getMessageRateState(player), self._clock()) then
			self._logger:Warn("invalid_batch_payload", {
				UserId = player.UserId,
				Error = if serializeIssues[1] then serializeIssues[1].Reason else "payload_too_large",
				EstimatedBytes = estimatedBytes,
			})
		end
		return
	end

	local expected = self._expectedIncomingSequence[player] or 1
	if batch.Sequence ~= expected then
		self._logger:Warn("incoming_sequence_gap", {
			UserId = player.UserId,
			Expected = expected,
			Got = batch.Sequence,
		})
		self:_setResyncRequired(player, "ClientSequenceGap")
		return
	end
	self._expectedIncomingSequence[player] = expected + 1

	for _, message in batch.Messages do
		if typeof(message) ~= "table"
			or typeof(message.Type) ~= "string"
			or message.Type == ""
			or #message.Type > CommunicationConfig.MaxMessageTypeLength
		then
			if shouldLogInvalid(self:_getMessageRateState(player), self._clock()) then
				self._logger:Warn("invalid_message", { UserId = player.UserId })
			end
			continue
		end
		if message.RequestId ~= nil
			and (typeof(message.RequestId) ~= "string"
				or #message.RequestId > CommunicationConfig.MaxRequestIdLength)
		then
			if shouldLogInvalid(self:_getMessageRateState(player), self._clock()) then
				self._logger:Warn("invalid_request_id", {
					UserId = player.UserId,
					MessageType = message.Type,
				})
			end
			continue
		end

		local handler = self._handlers[message.Type]
		if handler == nil then
			if shouldLogInvalid(self:_getMessageRateState(player), self._clock()) then
				self._logger:Warn("unknown_message", {
					UserId = player.UserId,
					MessageType = message.Type,
				})
			end
			continue
		end

		local validatorOk, valid, sanitized, validationError = pcall(handler.Validate, message.Payload)
		if not validatorOk then
			self._logger:Error("message_validator_failed", {
				UserId = player.UserId,
				MessageType = message.Type,
				Error = tostring(valid),
			})
			self:_setResyncRequired(player, "MessageValidatorFailed")
			return
		end
		if not valid then
			if shouldLogInvalid(self:_getMessageRateState(player), self._clock()) then
				self._logger:Warn("invalid_message_payload", {
					UserId = player.UserId,
					MessageType = message.Type,
					Error = validationError,
				})
			end
			continue
		end

		local ok, err = pcall(handler.Handle, player, sanitized, message.RequestId)
		if not ok then
			self._logger:Error("message_handler_failed", {
				UserId = player.UserId,
				MessageType = message.Type,
				Error = tostring(err),
			})
			self:_setResyncRequired(player, "MessageHandlerFailed")
			return
		end
	end
end

function CommunicationServer:ReceiveBatch(player: Player, batch: any)
	self:_handleBatch(player, batch)
end

function CommunicationServer:_getOutboundRateState(player: Player): OutboundRateState
	local state = self._outboundRate[player]
	if state == nil then
		state = {
			Batches = TokenBucket.new(
				CommunicationConfig.MaxServerToClientBatchInvocationsPerSecond,
				CommunicationConfig.ServerToClientBatchBurst,
				self._clock
			),
			Bytes = TokenBucket.new(
				CommunicationConfig.MaxServerToClientBytesPerSecond,
				CommunicationConfig.ServerToClientByteBurst,
				self._clock
			),
		}
		self._outboundRate[player] = state
	end
	return state
end

function CommunicationServer:_flush()
	for player, queue in self._outgoing do
		if self._ready[player] ~= true or #queue == 0 then
			continue
		end

		while #queue > 0 do
			local messages = {}
			local batchBytes = 0
			for index, entry in queue do
				if #messages >= CommunicationConfig.MaxMessagesPerBatch then
					break
				end
				if #messages > 0
					and batchBytes + entry.EstimatedBytes > CommunicationConfig.MaxEstimatedPayloadBytes
				then
					break
				end
				table.insert(messages, entry.Message)
				batchBytes += entry.EstimatedBytes
			end

			local sequence = (self._outgoingSequence[player] or 0) + 1
			local batch = {
				Epoch = self._outgoingEpoch[player] or 0,
				Sequence = sequence,
				Messages = messages,
			}
			local valid, issues, estimatedBytes = CommunicationSerialize.inspect(batch, {
				MaxBytes = CommunicationConfig.MaxEstimatedPayloadBytes,
			})
			if not valid then
				self._logger:Error("outgoing_batch_invalid", {
					UserId = player.UserId,
					Error = if issues[1] then issues[1].Reason else "payload_too_large",
				})
				self:_setResyncRequired(player, "InvalidOutgoingBatch")
				break
			end

			local outboundRate = self:_getOutboundRateState(player)
			local budgetAvailable = TokenBucket.tryConsumeAll({
				{
					Bucket = outboundRate.Batches,
					Amount = 1,
				},
				{
					Bucket = outboundRate.Bytes,
					Amount = estimatedBytes,
				},
			})
			if not budgetAvailable then
				break
			end

			local sent, sendError = pcall(function()
				self._serverToClient:FireClient(player, batch)
			end)
			if not sent then
				self._logger:Error("outgoing_batch_transport_failed", {
					UserId = player.UserId,
					Error = tostring(sendError),
				})
				break
			end

			self._outgoingSequence[player] = sequence
			for _ = 1, #messages do
				local entry = table.remove(queue, 1)
				self._outgoingBytes[player] = math.max(
					0,
					(self._outgoingBytes[player] or 0) - entry.EstimatedBytes
				)
			end
		end
	end
end

function CommunicationServer:Flush()
	self:_flush()
end

function CommunicationServer:GetQueueStats(player: Player)
	local queue = self._outgoing[player] or {}
	return {
		Messages = #queue,
		EstimatedBytes = self._outgoingBytes[player] or 0,
		ResyncRequired = self._resyncQueued[player] == true,
		DroppedPresentation = self._droppedPresentation[player] or 0,
		Epoch = self._outgoingEpoch[player] or 0,
		OutgoingSequence = self._outgoingSequence[player] or 0,
	}
end

function CommunicationServer:_clearPlayerState(player: Player)
	self._outgoing[player] = nil
	self._outgoingBytes[player] = nil
	self._outgoingSequence[player] = nil
	self._outgoingEpoch[player] = nil
	self._expectedIncomingSequence[player] = nil
	self._ready[player] = nil
	self._rate[player] = nil
	self._requestRate[player] = nil
	self._outboundRate[player] = nil
	self._snapshotRequests[player] = nil
	self._resyncQueued[player] = nil
	self._droppedPresentation[player] = nil
end

function CommunicationServer:ForgetPlayer(player: Player)
	self:_clearPlayerState(player)
end

function CommunicationServer:Initialize()
	if self._initialized then
		return
	end
	self._initialized = true

	table.insert(self._connections, self._clientToServer.OnServerEvent:Connect(function(player, batch)
		self:ReceiveBatch(player, batch)
	end))
	self._request.OnServerInvoke = function(player, request)
		return self:HandleRequest(player, request)
	end
	table.insert(self._connections, RunService.Heartbeat:Connect(function()
		self:Flush()
	end))
	table.insert(self._connections, self._players.PlayerRemoving:Connect(function(player)
		self:ForgetPlayer(player)
	end))
end

function CommunicationServer:Stop()
	self._request.OnServerInvoke = nil
	for _, connection in self._connections do
		connection:Disconnect()
	end
	table.clear(self._connections)
	table.clear(self._outgoing)
	table.clear(self._outgoingBytes)
	table.clear(self._outgoingSequence)
	table.clear(self._outgoingEpoch)
	table.clear(self._expectedIncomingSequence)
	table.clear(self._ready)
	table.clear(self._rate)
	table.clear(self._requestRate)
	table.clear(self._outboundRate)
	table.clear(self._snapshotRequests)
	table.clear(self._resyncQueued)
	table.clear(self._droppedPresentation)
	self._initialized = false
end

return CommunicationServer
