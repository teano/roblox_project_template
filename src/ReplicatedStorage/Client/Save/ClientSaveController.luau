--!strict

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local TableUtil = require(ReplicatedStorage.Shared.Util.TableUtil)
local CommunicationProtocol = require(ReplicatedStorage.Shared.Communication.CommunicationProtocol)
local MementoTransaction = require(ReplicatedStorage.Shared.Save.MementoTransaction)
local Logger = require(ReplicatedStorage.Shared.Util.Logger)

local ClientSaveController = {}
ClientSaveController.__index = ClientSaveController

function ClientSaveController.new(config: {
	Id: string,
	Providers: { any },
	Communication: any,
	Logger: any?,
})
	local byId = {}
	local self = setmetatable({
		Id = config.Id,
		_providers = table.clone(config.Providers),
		_providersById = byId,
		_communication = config.Communication,
		_logger = config.Logger or Logger.new(`Save.ClientController.{config.Id}`, "info"),
		_revision = 0,
		_running = false,
		_dirtyGeneration = {} :: { [string]: number },
		_sentGeneration = {} :: { [string]: number },
		_pendingRequestId = nil :: string?,
		_connections = {},
		Ready = Signal.new(),
	}, ClientSaveController)

	for _, provider in self._providers do
		assert(byId[provider.Id] == nil, `Duplicate client save provider '{provider.Id}'`)
		byId[provider.Id] = provider
		if provider.MementoChanged then
			table.insert(self._connections, provider.MementoChanged:Connect(function()
				if provider.Authority ~= "Client" then
					self._logger:Error("readonly_provider_changed", { ProviderId = provider.Id })
					return
				end
				self._dirtyGeneration[provider.Id] = (self._dirtyGeneration[provider.Id] or 0) + 1
			end))
		end
	end

	self._communication:RegisterHandler(
		CommunicationProtocol.SystemMessages.SaveClientPatchResult,
		function(payload, requestId)
			self:_handlePatchResult(payload, requestId)
		end
	)
	table.insert(self._connections, RunService.Heartbeat:Connect(function()
		self:_flushClientDirty()
	end))
	return self
end

function ClientSaveController:IsReady(): boolean
	return self._running
end

function ClientSaveController:GetRevision(): number
	return self._revision
end

function ClientSaveController:GetProvider(providerId: string)
	return self._providersById[providerId]
end

function ClientSaveController:ApplySnapshot(snapshot: any)
	assert(typeof(snapshot) == "table", "Snapshot must be a table")
	assert(snapshot.ControllerId == self.Id, "Snapshot controller mismatch")
	assert(typeof(snapshot.Providers) == "table", "Snapshot providers missing")
	assert(typeof(snapshot.Revision) == "number", "Snapshot revision missing")

	local targetValues = {}
	for _, provider in self._providers do
		local envelope = snapshot.Providers[provider.Id]
		assert(typeof(envelope) == "table", `Snapshot provider '{provider.Id}' missing`)
		local valid, sanitized, validationError = provider:ValidateMemento(envelope.Data)
		assert(valid, `Provider '{provider.Id}' snapshot invalid: {validationError or "unknown"}`)
		targetValues[provider] = TableUtil.deepCopy(if sanitized ~= nil then sanitized else envelope.Data)
	end

	local wasRunning = self._running
	local previousRevision = self._revision
	local previousValues = {}
	if wasRunning then
		for _, provider in self._providers do
			if provider.BeforeMementoGet then
				provider:BeforeMementoGet()
			end
			local current = provider:GetMemento()
			local valid, sanitized, validationError = provider:ValidateMemento(current)
			assert(valid, `Provider '{provider.Id}' current runtime is invalid: {validationError or "unknown"}`)
			previousValues[provider] = TableUtil.deepCopy(if sanitized ~= nil then sanitized else current)
		end
	end
	local transaction = MementoTransaction.apply({
		Providers = self._providers,
		TargetValues = targetValues,
		PreviousValues = previousValues,
		WasRunning = wasRunning,
		Capture = function(_provider)
			error("Previous values were already captured")
		end,
		Stop = function(provider)
			provider:Stop()
		end,
		SetMemento = function(provider, value)
			provider:SetMemento(TableUtil.deepCopy(value))
		end,
		Run = function(provider)
			provider:Run()
		end,
	})

	if not transaction.Ok then
		if transaction.RolledBack or (wasRunning and not transaction.MutationStarted) then
			self._running = true
			self._revision = previousRevision
		else
			self._running = false
		end
		error(
			`Snapshot transaction failed{if transaction.RolledBack then " and was rolled back" else ""}:\n`
				.. tostring(transaction.Error)
				.. (if transaction.RollbackError then `\nRollback cleanup failed:\n{transaction.RollbackError}` else "")
		)
	end

	self._revision = snapshot.Revision
	self._pendingRequestId = nil
	self._pendingSent = nil
	for providerId, generation in self._dirtyGeneration do
		self._sentGeneration[providerId] = generation
	end
	self._running = true
	self.Ready:Fire(self._revision)
end

function ClientSaveController:_flushClientDirty()
	if not self._running or self._pendingRequestId ~= nil then
		return
	end

	local providers = {}
	local sent = {}
	for providerId, generation in self._dirtyGeneration do
		if generation <= (self._sentGeneration[providerId] or 0) then
			continue
		end
		local provider = self._providersById[providerId]
		if provider == nil or provider.Authority ~= "Client" then
			continue
		end
		if provider.BeforeMementoGet then
			provider:BeforeMementoGet()
		end
		providers[providerId] = {
			Version = provider.Version,
			Data = provider:GetMemento(),
		}
		sent[providerId] = generation
	end

	if next(providers) == nil then
		return
	end

	local requestId = HttpService:GenerateGUID(false)
	self._pendingRequestId = requestId
	self._pendingSent = sent
	local queued = self._communication:Queue(CommunicationProtocol.SystemMessages.SaveClientPatch, {
		ControllerId = self.Id,
		BaseRevision = self._revision,
		Providers = providers,
	}, requestId, {
		Priority = CommunicationProtocol.Priorities.State,
	})
	if not queued then
		self._pendingRequestId = nil
		self._pendingSent = nil
	end
end

function ClientSaveController:_handlePatchResult(payload: any, requestId: string?)
	if requestId == nil or requestId ~= self._pendingRequestId or typeof(payload) ~= "table" then
		return
	end
	local accepted = if typeof(payload.AcceptedProviders) == "table" then payload.AcceptedProviders else {}
	local acceptedSet = {}
	for _, providerId in accepted do
		acceptedSet[providerId] = true
	end
	for providerId, generation in self._pendingSent or {} do
		if acceptedSet[providerId] and self._dirtyGeneration[providerId] == generation then
			self._sentGeneration[providerId] = generation
		end
	end
	if typeof(payload.Revision) == "number" then
		self._revision = math.max(self._revision, payload.Revision)
	end
	self._pendingRequestId = nil
	self._pendingSent = nil
end

function ClientSaveController:Destroy()
	if self._running then
		for index = #self._providers, 1, -1 do
			self._providers[index]:Stop()
		end
	end
	for _, connection in self._connections do
		connection:Disconnect()
	end
	table.clear(self._connections)
	self.Ready:Destroy()
end

return ClientSaveController
