--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local CommunicationProtocol = require(ReplicatedStorage.Shared.Communication.CommunicationProtocol)
local CommunicationConfig = require(ReplicatedStorage.Shared.Communication.CommunicationConfig)
local CommunicationSerialize = require(ReplicatedStorage.Shared.Communication.CommunicationSerialize)
local Logger = require(ReplicatedStorage.Shared.Util.Logger)

type MessageHandler = {
	Validate: ((payload: any) -> (boolean, any?, string?))?,
	Handle: (player: Player, payload: any, requestId: string?) -> (),
}

type RequestHandler = {
	Validate: ((payload: any) -> (boolean, any?, string?))?,
	Handle: (player: Player, payload: any) -> (boolean, any?, string?),
}

type QueueEntry = {
	Message: any,
	Priority: string,
	EstimatedBytes: number,
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
})
	local clientToServer, serverToClient, request = ensureRemotes()
	local self = setmetatable({
		_players = deps.PlayersModule,
		_logger = deps.Logger or Logger.new("Communication.Server", "info"),
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
		_rate = {} :: { [Player]: { WindowStartedAt: number, Count: number, Bytes: number } },
		_requestRate = {} :: { [Player]: { WindowStartedAt: number, Count: number, Bytes: number } },
		_resyncQueued = {} :: { [Player]: boolean },
		_droppedPresentation = {} :: { [Player]: number },
		_connections = {} :: { any },
		_initialized = false,
	}, CommunicationServer)
	return self
end

function CommunicationServer:RegisterHandler(
	messageType: string,
	validator: ((payload: any) -> (boolean, any?, string?))?,
	handler: (player: Player, payload: any, requestId: string?) -> ()
)
	assert(self._handlers[messageType] == nil, `Duplicate communication handler '{messageType}'`)
	self._handlers[messageType] = {
		Validate = validator,
		Handle = handler,
	}
end

function CommunicationServer:RegisterRequestHandler(
	requestType: string,
	validator: ((payload: any) -> (boolean, any?, string?))?,
	handler: (player: Player, payload: any) -> (boolean, any?, string?)
)
	assert(typeof(requestType) == "string" and requestType ~= "", "requestType required")
	assert(#requestType <= CommunicationConfig.MaxRequestTypeLength, "requestType too long")
	assert(self._requestHandlers[requestType] == nil, `Duplicate request handler '{requestType}'`)
	self._requestHandlers[requestType] = {
		Validate = validator,
		Handle = handler,
	}
end

function CommunicationServer:_reserveRequestBudget(player: Player, estimatedBytes: number): boolean
	local now = os.clock()
	local state = self._requestRate[player]
	if state == nil or now - state.WindowStartedAt >= 1 then
		state = {
			WindowStartedAt = now,
			Count = 0,
			Bytes = 0,
		}
		self._requestRate[player] = state
	end
	state.Count += 1
	state.Bytes += estimatedBytes
	return state.Count <= CommunicationConfig.MaxRequestsPerSecond
		and state.Bytes <= CommunicationConfig.MaxRequestResponseBytesPerSecond
end

function CommunicationServer:_reserveRequestResponseBytes(player: Player, estimatedBytes: number): boolean
	local state = self._requestRate[player]
	if state == nil then
		return false
	end
	state.Bytes += estimatedBytes
	return state.Bytes <= CommunicationConfig.MaxRequestResponseBytesPerSecond
end

function CommunicationServer:_handleRequest(player: Player, request: any)
	local valid, _, estimatedBytes = CommunicationSerialize.inspect(request)
	if not valid
		or estimatedBytes > CommunicationConfig.MaxSingleMessageEstimatedBytes
		or typeof(request) ~= "table"
		or typeof(request.Type) ~= "string"
		or request.Type == ""
		or #request.Type > CommunicationConfig.MaxRequestTypeLength
	then
		self._logger:Warn("invalid_request", { UserId = player.UserId })
		return {
			Ok = false,
			Code = "Unavailable",
		}
	end
	if not self:_reserveRequestBudget(player, estimatedBytes) then
		self._logger:Warn("request_rate_limited", {
			UserId = player.UserId,
			RequestType = request.Type,
		})
		return {
			Ok = false,
			Code = "RateLimited",
		}
	end

	local handler = self._requestHandlers[request.Type]
	if handler == nil then
		return {
			Ok = false,
			Code = "Unavailable",
		}
	end

	local payload = request.Payload
	if handler.Validate then
		local validatorOk, payloadValid, sanitized, _validationError = pcall(handler.Validate, payload)
		if not validatorOk then
			self._logger:Error("request_validator_failed", {
				UserId = player.UserId,
				RequestType = request.Type,
				Error = tostring(payloadValid),
			})
			return {
				Ok = false,
				Code = "InternalError",
			}
		end
		if not payloadValid then
			return {
				Ok = false,
				Code = "Unavailable",
			}
		end
		payload = sanitized
	end

	local callOk, handled, result, failureCode = pcall(handler.Handle, player, payload)
	if not callOk then
		self._logger:Error("request_handler_failed", {
			UserId = player.UserId,
			RequestType = request.Type,
			Error = tostring(handled),
		})
		return {
			Ok = false,
			Code = "InternalError",
		}
	end
	if not handled then
		return {
			Ok = false,
			Code = if typeof(failureCode) == "string" then failureCode else "Unavailable",
		}
	end

	local response = {
		Ok = true,
		Payload = result,
	}
	local responseValid, _, responseBytes = CommunicationSerialize.inspect(response)
	if not responseValid or responseBytes > CommunicationConfig.MaxSingleMessageEstimatedBytes then
		self._logger:Warn("request_response_rejected", {
			UserId = player.UserId,
			RequestType = request.Type,
			EstimatedBytes = responseBytes,
		})
		return {
			Ok = false,
			Code = "InternalError",
		}
	end
	if not self:_reserveRequestResponseBytes(player, responseBytes) then
		self._logger:Warn("request_response_rate_limited", {
			UserId = player.UserId,
			RequestType = request.Type,
			EstimatedBytes = responseBytes,
		})
		return {
			Ok = false,
			Code = "RateLimited",
		}
	end
	return response
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
	local _, _, estimatedBytes = CommunicationSerialize.inspect(message)
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
	assert(typeof(messageType) == "string" and messageType ~= "", "messageType required")
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
	local valid, issues, estimatedBytes = CommunicationSerialize.inspect(message)
	if not valid or estimatedBytes > CommunicationConfig.MaxSingleMessageEstimatedBytes then
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

function CommunicationServer:SetClientReady(player: Player)
	self._ready[player] = true
end

function CommunicationServer:IsClientReady(player: Player): boolean
	return self._ready[player] == true
end

function CommunicationServer:_isRateLimited(player: Player, messageCount: number, estimatedBytes: number): boolean
	local now = os.clock()
	local state = self._rate[player]
	if state == nil or now - state.WindowStartedAt >= 1 then
		state = {
			WindowStartedAt = now,
			Count = 0,
			Bytes = 0,
		}
		self._rate[player] = state
	end
	state.Count += messageCount
	state.Bytes += estimatedBytes
	return state.Count > CommunicationConfig.MaxMessagesPerSecond
		or state.Bytes > CommunicationConfig.MaxBytesPerSecond
end

function CommunicationServer:_handleBatch(player: Player, batch: any)
	if typeof(batch) ~= "table"
		or typeof(batch.Sequence) ~= "number"
		or batch.Sequence < 1
		or batch.Sequence ~= math.floor(batch.Sequence)
		or typeof(batch.Messages) ~= "table"
	then
		self._logger:Warn("invalid_batch_envelope", { UserId = player.UserId })
		return
	end
	if #batch.Messages > CommunicationConfig.MaxMessagesPerBatch then
		self._logger:Warn("batch_message_limit", { UserId = player.UserId, Count = #batch.Messages })
		return
	end
	local serializable, serializeIssues, estimatedBytes = CommunicationSerialize.inspect(batch)
	if not serializable or estimatedBytes > CommunicationConfig.MaxEstimatedPayloadBytes then
		self._logger:Warn("invalid_batch_payload", {
			UserId = player.UserId,
			Error = if serializeIssues[1] then serializeIssues[1].Reason else "payload_too_large",
			EstimatedBytes = estimatedBytes,
		})
		return
	end
	if self:_isRateLimited(player, #batch.Messages, estimatedBytes) then
		self._logger:Warn("message_rate_limited", { UserId = player.UserId })
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
		if typeof(message) ~= "table" or typeof(message.Type) ~= "string" then
			self._logger:Warn("invalid_message", { UserId = player.UserId })
			continue
		end
		if message.RequestId ~= nil
			and (typeof(message.RequestId) ~= "string"
				or #message.RequestId > CommunicationConfig.MaxRequestIdLength)
		then
			self._logger:Warn("invalid_request_id", {
				UserId = player.UserId,
				MessageType = message.Type,
			})
			continue
		end

		local handler = self._handlers[message.Type]
		if handler == nil then
			self._logger:Warn("unknown_message", {
				UserId = player.UserId,
				MessageType = message.Type,
			})
			continue
		end

		local validPayload = message.Payload
		if handler.Validate then
			local valid, sanitized, validationError = handler.Validate(message.Payload)
			if not valid then
				self._logger:Warn("invalid_message_payload", {
					UserId = player.UserId,
					MessageType = message.Type,
					Error = validationError,
				})
				continue
			end
			validPayload = sanitized
		end

		local ok, err = pcall(handler.Handle, player, validPayload, message.RequestId)
		if not ok then
			self._logger:Error("message_handler_failed", {
				UserId = player.UserId,
				MessageType = message.Type,
				Error = tostring(err),
			})
		end
	end
end

function CommunicationServer:_flush()
	for player, queue in self._outgoing do
		if self._ready[player] ~= true or #queue == 0 then
			continue
		end

		self._outgoing[player] = {}
		self._outgoingBytes[player] = 0
		while #queue > 0 do
			local messages = {}
			local batchBytes = 0
			while #queue > 0 and #messages < CommunicationConfig.MaxMessagesPerBatch do
				local entry = queue[1]
				if #messages > 0
					and batchBytes + entry.EstimatedBytes > CommunicationConfig.MaxEstimatedPayloadBytes
				then
					break
				end
				table.remove(queue, 1)
				table.insert(messages, entry.Message)
				batchBytes += entry.EstimatedBytes
			end

			local valid, issues, estimatedBytes = CommunicationSerialize.inspect(messages)
			if not valid or estimatedBytes > CommunicationConfig.MaxEstimatedPayloadBytes then
				self._logger:Error("outgoing_batch_invalid", {
					UserId = player.UserId,
					Error = if issues[1] then issues[1].Reason else "payload_too_large",
				})
				continue
			end

			local sequence = (self._outgoingSequence[player] or 0) + 1
			self._outgoingSequence[player] = sequence
			self._serverToClient:FireClient(player, {
				Epoch = self._outgoingEpoch[player] or 0,
				Sequence = sequence,
				Messages = messages,
			})
		end
	end
end

function CommunicationServer:GetQueueStats(player: Player)
	local queue = self._outgoing[player] or {}
	return {
		Messages = #queue,
		EstimatedBytes = self._outgoingBytes[player] or 0,
		ResyncRequired = self._resyncQueued[player] == true,
		DroppedPresentation = self._droppedPresentation[player] or 0,
		Epoch = self._outgoingEpoch[player] or 0,
	}
end

function CommunicationServer:Initialize()
	if self._initialized then
		return
	end
	self._initialized = true

	table.insert(self._connections, self._clientToServer.OnServerEvent:Connect(function(player, batch)
		self:_handleBatch(player, batch)
	end))
	self._request.OnServerInvoke = function(player, request)
		return self:_handleRequest(player, request)
	end
	table.insert(self._connections, RunService.Heartbeat:Connect(function()
		self:_flush()
	end))
	table.insert(self._connections, self._players.PlayerRemoving:Connect(function(player)
		self._outgoing[player] = nil
		self._outgoingBytes[player] = nil
		self._outgoingSequence[player] = nil
		self._outgoingEpoch[player] = nil
		self._expectedIncomingSequence[player] = nil
		self._ready[player] = nil
		self._rate[player] = nil
		self._requestRate[player] = nil
		self._resyncQueued[player] = nil
		self._droppedPresentation[player] = nil
	end))
end

function CommunicationServer:Stop()
	self._request.OnServerInvoke = nil
	for _, connection in self._connections do
		connection:Disconnect()
	end
	table.clear(self._connections)
	self._initialized = false
end

return CommunicationServer
