--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local CommunicationProtocol = require(ReplicatedStorage.Shared.Communication.CommunicationProtocol)
local CommunicationConfig = require(ReplicatedStorage.Shared.Communication.CommunicationConfig)
local CommunicationSerialize = require(ReplicatedStorage.Shared.Communication.CommunicationSerialize)
local TokenBucket = require(ReplicatedStorage.Shared.Communication.TokenBucket)
local Logger = require(ReplicatedStorage.Shared.Util.Logger)

local CommunicationClient = {}
CommunicationClient.__index = CommunicationClient

local function newOutboundRate(clock: () -> number)
	return {
		Batches = TokenBucket.new(
			CommunicationConfig.MaxBatchInvocationsPerSecond,
			CommunicationConfig.BatchInvocationBurst,
			clock
		),
		Messages = TokenBucket.new(
			CommunicationConfig.MaxMessagesPerSecond,
			CommunicationConfig.MessageBurst,
			clock
		),
		Bytes = TokenBucket.new(
			CommunicationConfig.MaxBytesPerSecond,
			CommunicationConfig.ByteBurst,
			clock
		),
	}
end

local function waitForRemotes(): (RemoteEvent, RemoteEvent, RemoteFunction)
	local root = ReplicatedStorage:WaitForChild("Remotes")
	assert(root:IsA("Folder"), "ReplicatedStorage.Remotes must be a Folder")
	local folder = root:WaitForChild(CommunicationProtocol.RemoteFolderName)
	assert(folder:IsA("Folder"), "Communication remote container must be a Folder")
	local clientToServer = folder:WaitForChild(CommunicationProtocol.ClientToServerEventName)
	local serverToClient = folder:WaitForChild(CommunicationProtocol.ServerToClientEventName)
	local request = folder:WaitForChild(CommunicationProtocol.RequestFunctionName)
	assert(clientToServer:IsA("RemoteEvent"), "ClientToServer must be a RemoteEvent")
	assert(serverToClient:IsA("RemoteEvent"), "ServerToClient must be a RemoteEvent")
	assert(request:IsA("RemoteFunction"), "Request must be a RemoteFunction")
	return clientToServer, serverToClient, request
end

function CommunicationClient.new(
	logger: any?,
	clock: (() -> number)?,
	delayScheduler: ((number, () -> ()) -> ())?
)
	local resolvedClock = clock or os.clock
	local resolvedDelayScheduler = delayScheduler or function(delaySeconds: number, callback: () -> ())
		task.delay(delaySeconds, callback)
	end
	return setmetatable({
		_logger = logger or Logger.new("Communication.Client", "info"),
		_clock = resolvedClock,
		_delayScheduler = resolvedDelayScheduler,
		_handlers = {} :: { [string]: (any, string?) -> () },
		_outgoing = {},
		_outgoingBytes = 0,
		_outgoingSequence = 0,
		_outboundRate = newOutboundRate(resolvedClock),
		_expectedIncomingSequence = 1,
		_incomingEpoch = 0,
		_pausedForResync = false,
		_resyncHandler = nil,
		_resyncInFlight = false,
		_resyncRetryAttempt = 0,
		_resyncRetryScheduled = false,
		_resyncGeneration = 0,
		_resyncThread = nil :: thread?,
		_connections = {},
		_initialized = false,
		_clientToServer = nil :: RemoteEvent?,
		_serverToClient = nil :: RemoteEvent?,
		_request = nil :: RemoteFunction?,
	}, CommunicationClient)
end

function CommunicationClient:RegisterHandler(messageType: string, handler: (any, string?) -> ())
	assert(
		typeof(messageType) == "string"
			and messageType ~= ""
			and #messageType <= CommunicationConfig.MaxMessageTypeLength,
		"messageType invalid"
	)
	assert(self._handlers[messageType] == nil, `Duplicate communication handler '{messageType}'`)
	self._handlers[messageType] = handler
end

function CommunicationClient:SetResyncHandler(handler: () -> ())
	self._resyncHandler = handler
	if self._pausedForResync then
		self:_startResync()
	end
end

function CommunicationClient:Request(requestType: string, payload: any): (boolean, any?, string?)
	if self._request == nil then
		return false, nil, "NotInitialized"
	end
	if typeof(requestType) ~= "string"
		or requestType == ""
		or #requestType > CommunicationConfig.MaxRequestTypeLength
	then
		return false, nil, "InvalidRequest"
	end

	local request = {
		Type = requestType,
		Payload = payload,
	}
	local valid, _, estimatedBytes = CommunicationSerialize.inspect(request, {
		MaxBytes = CommunicationConfig.MaxSingleMessageEstimatedBytes,
	})
	if not valid then
		return false, nil, "InvalidRequest"
	end

	local invoked, response = pcall(function()
		return (self._request :: RemoteFunction):InvokeServer(request)
	end)
	if not invoked then
		self._logger:Warn("request_transport_failed", {
			RequestType = requestType,
			Error = tostring(response),
		})
		return false, nil, "TransportError"
	end
	local responseValid, _, responseBytes = CommunicationSerialize.inspect(response, {
		MaxBytes = CommunicationConfig.MaxSingleMessageEstimatedBytes,
	})
	if not responseValid
		or typeof(response) ~= "table"
		or typeof(response.Ok) ~= "boolean"
	then
		return false, nil, "InvalidResponse"
	end
	if not response.Ok then
		return false, nil, if typeof(response.Code) == "string" then response.Code else "Unavailable"
	end
	return true, response.Payload, nil
end

function CommunicationClient:Queue(
	messageType: string,
	payload: any,
	requestId: string?,
	options: { Priority: string? }?
): boolean
	if self._pausedForResync then
		return false
	end
	if typeof(messageType) ~= "string"
		or messageType == ""
		or #messageType > CommunicationConfig.MaxMessageTypeLength
	then
		self._logger:Warn("outgoing_message_type_invalid")
		return false
	end
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
	local valid, issues, estimatedBytes = CommunicationSerialize.inspect(message, {
		MaxBytes = CommunicationConfig.MaxSingleMessageEstimatedBytes,
	})
	if not valid then
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

function CommunicationClient:_startResync()
	local handler = self._resyncHandler
	if not self._pausedForResync
		or self._resyncInFlight
		or self._resyncRetryScheduled
		or handler == nil
	then
		return
	end
	self._resyncInFlight = true
	local generation = self._resyncGeneration
	local resyncThread = task.spawn(function()
		local currentThread = coroutine.running()
		local function clearResyncThread()
			if self._resyncThread == currentThread then
				self._resyncThread = nil
			end
		end

		local ok, err = xpcall(handler, debug.traceback)
		if self._resyncGeneration ~= generation then
			clearResyncThread()
			return
		end
		self._resyncInFlight = false
		if not ok or self._pausedForResync then
			self._resyncRetryAttempt += 1
			local retryDelay = math.min(
				CommunicationConfig.ResyncRetryMaxDelaySeconds,
				CommunicationConfig.ResyncRetryBaseDelaySeconds * (2 ^ (self._resyncRetryAttempt - 1))
			)
			self._logger:Error("resync_handler_failed", {
				Error = if ok then "Resync handler returned without resuming after a snapshot" else tostring(err),
				RetryAttempt = self._resyncRetryAttempt,
				RetryDelaySeconds = retryDelay,
			})
			if self._pausedForResync and not self._resyncRetryScheduled then
				self._resyncRetryScheduled = true
				self._delayScheduler(retryDelay, function()
					if self._resyncGeneration ~= generation then
						return
					end
					self._resyncRetryScheduled = false
					if self._pausedForResync then
						self:_startResync()
					end
				end)
			end
		end
		clearResyncThread()
	end)
	self._resyncThread = resyncThread
	if coroutine.status(resyncThread) == "dead" then
		self._resyncThread = nil
	end
end

function CommunicationClient:_requestResync(reason: string)
	if self._pausedForResync then
		return
	end
	self._pausedForResync = true
	self._resyncRetryAttempt = 0
	self._resyncGeneration += 1
	self._resyncRetryScheduled = false
	table.clear(self._outgoing)
	self._outgoingBytes = 0
	self._logger:Warn("resync_required", { Reason = reason })
	self:_startResync()
end

function CommunicationClient:ResumeAfterSnapshot(epoch: number)
	assert(typeof(epoch) == "number" and epoch >= 1 and epoch == math.floor(epoch), "Snapshot epoch invalid")
	local currentThread = coroutine.running()
	local resyncThread = self._resyncThread
	if resyncThread ~= nil and resyncThread ~= currentThread then
		self._resyncThread = nil
		if coroutine.status(resyncThread) ~= "dead" then
			task.cancel(resyncThread)
		end
	end
	self._incomingEpoch = epoch
	self._expectedIncomingSequence = 1
	self._pausedForResync = false
	self._resyncInFlight = false
	self._resyncRetryAttempt = 0
	self._resyncRetryScheduled = false
	self._resyncGeneration += 1
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
	local denseMessages, messageCount =
		CommunicationSerialize.inspectDenseArray(batch.Messages, CommunicationConfig.MaxMessagesPerBatch)
	if not denseMessages then
		self:_requestResync("InvalidBatchMessages")
		return
	end
	local valid, _, estimatedBytes = CommunicationSerialize.inspect(batch, {
		MaxBytes = CommunicationConfig.MaxEstimatedPayloadBytes,
	})
	if not valid
		or messageCount > CommunicationConfig.MaxMessagesPerBatch
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
		if typeof(message) ~= "table"
			or typeof(message.Type) ~= "string"
			or message.Type == ""
			or #message.Type > CommunicationConfig.MaxMessageTypeLength
		then
			self:_requestResync("InvalidMessage")
			return
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
	if self._pausedForResync or #self._outgoing == 0 or self._clientToServer == nil then
		return
	end

	while #self._outgoing > 0 do
		local messages = {}
		local batchBytes = 0
		for _, entry in self._outgoing do
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

		local sequence = self._outgoingSequence + 1
		local batch = {
			Sequence = sequence,
			Messages = messages,
		}
		local valid, issues, estimatedBytes = CommunicationSerialize.inspect(batch, {
			MaxBytes = CommunicationConfig.MaxEstimatedPayloadBytes,
		})
		if not valid then
			self._logger:Error("outgoing_batch_invalid", {
				Error = if issues[1] then issues[1].Reason else "payload_too_large",
			})
			self:_requestResync("InvalidOutgoingBatch")
			return
		end

		local budgetAvailable = TokenBucket.tryConsumeAll({
			{
				Bucket = self._outboundRate.Batches,
				Amount = 1,
			},
			{
				Bucket = self._outboundRate.Messages,
				Amount = #messages,
			},
			{
				Bucket = self._outboundRate.Bytes,
				Amount = estimatedBytes,
			},
		})
		if not budgetAvailable then
			return
		end

		local sent, sendError = pcall(function()
			(self._clientToServer :: RemoteEvent):FireServer(batch)
		end)
		if not sent then
			self._logger:Error("outgoing_batch_transport_failed", {
				Error = tostring(sendError),
			})
			return
		end

		self._outgoingSequence = sequence
		for _ = 1, #messages do
			local entry = table.remove(self._outgoing, 1)
			self._outgoingBytes = math.max(0, self._outgoingBytes - entry.EstimatedBytes)
		end
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
	local clientToServer, serverToClient, request = waitForRemotes()
	self._clientToServer = clientToServer
	self._serverToClient = serverToClient
	self._request = request
	table.insert(self._connections, serverToClient.OnClientEvent:Connect(function(batch)
		self:_handleBatch(batch)
	end))
	table.insert(self._connections, RunService.Heartbeat:Connect(function()
		self:_flush()
	end))
end

function CommunicationClient:Stop()
	local resyncThread = self._resyncThread
	self._resyncThread = nil
	if resyncThread ~= nil
		and resyncThread ~= coroutine.running()
		and coroutine.status(resyncThread) ~= "dead"
	then
		task.cancel(resyncThread)
	end
	for _, connection in self._connections do
		connection:Disconnect()
	end
	table.clear(self._connections)
	self._clientToServer = nil
	self._serverToClient = nil
	self._request = nil
	table.clear(self._outgoing)
	self._outgoingBytes = 0
	self._outgoingSequence = 0
	self._outboundRate = newOutboundRate(self._clock)
	self._expectedIncomingSequence = 1
	self._incomingEpoch = 0
	self._pausedForResync = false
	self._resyncInFlight = false
	self._resyncRetryAttempt = 0
	self._resyncRetryScheduled = false
	self._resyncGeneration += 1
	self._initialized = false
end

return CommunicationClient
