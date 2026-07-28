--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local CommunicationProtocol = require(ReplicatedStorage.Shared.Communication.CommunicationProtocol)
local CommunicationConfig = require(ReplicatedStorage.Shared.Communication.CommunicationConfig)
local CommunicationSerialize = require(ReplicatedStorage.Shared.Communication.CommunicationSerialize)
local Logger = require(ReplicatedStorage.Shared.Util.Logger)

local CommunicationClient = {}
CommunicationClient.__index = CommunicationClient

local function waitForRemotes(): (RemoteEvent, RemoteEvent)
	local root = ReplicatedStorage:WaitForChild("Remotes")
	assert(root:IsA("Folder"), "ReplicatedStorage.Remotes must be a Folder")
	local folder = root:WaitForChild(CommunicationProtocol.RemoteFolderName)
	assert(folder:IsA("Folder"), "Communication remote container must be a Folder")
	local clientToServer = folder:WaitForChild(CommunicationProtocol.ClientToServerEventName)
	local serverToClient = folder:WaitForChild(CommunicationProtocol.ServerToClientEventName)
	assert(clientToServer:IsA("RemoteEvent"), "ClientToServer must be a RemoteEvent")
	assert(serverToClient:IsA("RemoteEvent"), "ServerToClient must be a RemoteEvent")
	return clientToServer, serverToClient
end

function CommunicationClient.new(logger: any?)
	return setmetatable({
		_logger = logger or Logger.new("Communication.Client", "info"),
		_handlers = {} :: { [string]: (any, string?) -> () },
		_outgoing = {},
		_outgoingBytes = 0,
		_outgoingSequence = 0,
		_expectedIncomingSequence = 1,
		_incomingEpoch = 0,
		_pausedForResync = false,
		_resyncHandler = nil,
		_connections = {},
		_initialized = false,
		_clientToServer = nil :: RemoteEvent?,
		_serverToClient = nil :: RemoteEvent?,
	}, CommunicationClient)
end

function CommunicationClient:RegisterHandler(messageType: string, handler: (any, string?) -> ())
	assert(self._handlers[messageType] == nil, `Duplicate communication handler '{messageType}'`)
	self._handlers[messageType] = handler
end

function CommunicationClient:SetResyncHandler(handler: () -> ())
	self._resyncHandler = handler
end

function CommunicationClient:Queue(
	messageType: string,
	payload: any,
	requestId: string?,
	options: { Priority: string? }?
): boolean
	if requestId ~= nil
		and (typeof(requestId) ~= "string" or #requestId > CommunicationConfig.MaxRequestIdLength)
	then
		self._logger:Warn("outgoing_request_id_invalid", { MessageType = messageType })
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
			MessageType = messageType,
			Error = if issues[1] then issues[1].Reason else "message_too_large",
		})
		return false
	end
	if #self._outgoing + 1 > CommunicationConfig.MaxQueuedMessagesPerPeer
		or self._outgoingBytes + estimatedBytes > CommunicationConfig.MaxQueuedPayloadBytesPerPeer
	then
		if priority ~= CommunicationProtocol.Priorities.Presentation then
			self:_requestResync("OutgoingQueueOverflow")
		end
		return false
	end
	table.insert(self._outgoing, {
		Message = message,
		Priority = priority,
		EstimatedBytes = estimatedBytes,
	})
	self._outgoingBytes += estimatedBytes
	return true
end

function CommunicationClient:_requestResync(reason: string)
	if self._pausedForResync then
		return
	end
	self._pausedForResync = true
	table.clear(self._outgoing)
	self._outgoingBytes = 0
	self._logger:Warn("resync_required", { Reason = reason })
	if self._resyncHandler then
		task.spawn(self._resyncHandler)
	end
end

function CommunicationClient:ResumeAfterSnapshot(epoch: number)
	assert(typeof(epoch) == "number" and epoch >= 1 and epoch == math.floor(epoch), "Snapshot epoch invalid")
	self._incomingEpoch = epoch
	self._expectedIncomingSequence = 1
	self._pausedForResync = false
end

function CommunicationClient:_handleBatch(batch: any)
	if self._pausedForResync then
		return
	end
	if typeof(batch) ~= "table"
		or typeof(batch.Epoch) ~= "number"
		or typeof(batch.Sequence) ~= "number"
		or batch.Sequence < 1
		or batch.Sequence ~= math.floor(batch.Sequence)
		or typeof(batch.Messages) ~= "table"
	then
		self:_requestResync("InvalidBatch")
		return
	end
	if batch.Epoch < self._incomingEpoch then
		return
	end
	if batch.Epoch > self._incomingEpoch then
		self:_requestResync("EpochMismatch")
		return
	end
	local valid, _, estimatedBytes = CommunicationSerialize.inspect(batch)
	if not valid
		or #batch.Messages > CommunicationConfig.MaxMessagesPerBatch
		or estimatedBytes > CommunicationConfig.MaxEstimatedPayloadBytes
	then
		self:_requestResync("InvalidBatchPayload")
		return
	end
	if batch.Sequence ~= self._expectedIncomingSequence then
		self:_requestResync("SequenceGap")
		return
	end
	self._expectedIncomingSequence += 1

	for _, message in batch.Messages do
		if typeof(message) ~= "table" or typeof(message.Type) ~= "string" then
			self._logger:Warn("invalid_message")
			continue
		end
		if message.RequestId ~= nil
			and (typeof(message.RequestId) ~= "string"
				or #message.RequestId > CommunicationConfig.MaxRequestIdLength)
		then
			self:_requestResync("InvalidRequestId")
			return
		end
		if message.Type == CommunicationProtocol.SystemMessages.ResyncRequired then
			self:_requestResync("ServerRequested")
			return
		end
		local handler = self._handlers[message.Type]
		if handler == nil then
			self._logger:Warn("unknown_message", { MessageType = message.Type })
			continue
		end
		local ok, err = pcall(handler, message.Payload, message.RequestId)
		if not ok then
			self._logger:Error("message_handler_failed", {
				MessageType = message.Type,
				Error = tostring(err),
			})
			self:_requestResync(`HandlerFailed:{message.Type}`)
			return
		end
	end
end

function CommunicationClient:_flush()
	if #self._outgoing == 0 or self._clientToServer == nil then
		return
	end

	while #self._outgoing > 0 do
		local messages = {}
		local batchBytes = 0
		while #self._outgoing > 0 and #messages < CommunicationConfig.MaxMessagesPerBatch do
			local entry = self._outgoing[1]
			if #messages > 0
				and batchBytes + entry.EstimatedBytes > CommunicationConfig.MaxEstimatedPayloadBytes
			then
				break
			end
			table.remove(self._outgoing, 1)
			self._outgoingBytes = math.max(0, self._outgoingBytes - entry.EstimatedBytes)
			table.insert(messages, entry.Message)
			batchBytes += entry.EstimatedBytes
		end

		local valid, issues, estimatedBytes = CommunicationSerialize.inspect(messages)
		if not valid or estimatedBytes > CommunicationConfig.MaxEstimatedPayloadBytes then
			self._logger:Error("outgoing_batch_invalid", {
				Error = if issues[1] then issues[1].Reason else "payload_too_large",
			})
			continue
		end

		self._outgoingSequence += 1
		self._clientToServer:FireServer({
			Sequence = self._outgoingSequence,
			Messages = messages,
		})
	end
end

function CommunicationClient:GetQueueStats()
	return {
		Messages = #self._outgoing,
		EstimatedBytes = self._outgoingBytes,
		PausedForResync = self._pausedForResync,
		Epoch = self._incomingEpoch,
	}
end

function CommunicationClient:Initialize()
	if self._initialized then
		return
	end
	self._initialized = true
	local clientToServer, serverToClient = waitForRemotes()
	self._clientToServer = clientToServer
	self._serverToClient = serverToClient
	table.insert(self._connections, serverToClient.OnClientEvent:Connect(function(batch)
		self:_handleBatch(batch)
	end))
	table.insert(self._connections, RunService.Heartbeat:Connect(function()
		self:_flush()
	end))
end

function CommunicationClient:Stop()
	for _, connection in self._connections do
		connection:Disconnect()
	end
	table.clear(self._connections)
	self._initialized = false
end

return CommunicationClient
