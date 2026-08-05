--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local TableUtil = require(ReplicatedStorage.Shared.Util.TableUtil)
local SaveProtocol = require(ReplicatedStorage.Shared.Save.SaveProtocol)
local SaveSerialize = require(ReplicatedStorage.Shared.Save.SaveSerialize)
local MementoTransaction = require(ReplicatedStorage.Shared.Save.MementoTransaction)
local Logger = require(ReplicatedStorage.Shared.Util.Logger)

type SaveOperation = {
	Pending: boolean,
	Completed: boolean,
	Result: any?,
}

type CloseOperation = {
	Completed: boolean,
	Result: any?,
}

type Runtime = {
	Owner: Player,
	Key: string,
	Document: any,
	DirtyProviders: { [string]: boolean },
	Dirty: boolean,
	Running: boolean,
	State: string,
	ActiveSave: SaveOperation?,
	ActiveClose: CloseOperation?,
	CloseRequested: boolean,
	LastSavedAt: number,
	LastLockRefreshAt: number,
}

local ServerSaveController = {}
ServerSaveController.__index = ServerSaveController

local function createDocument(): any
	local timestamp = os.time()
	return {
		FormatVersion = SaveProtocol.FormatVersion,
		Revision = 0,
		Providers = {},
		Metadata = {
			CreatedAt = timestamp,
			UpdatedAt = timestamp,
		},
		Session = nil,
	}
end

local function releaseAfterFailedLoad(storage: any, key: string): any
	local releaseOk, releaseOrError = xpcall(function()
		return storage:Release(key)
	end, debug.traceback)
	if not releaseOk then
		return {
			Ok = false,
			Code = "ReleaseFailed",
			Error = tostring(releaseOrError),
		}
	end
	if typeof(releaseOrError) ~= "table" or typeof(releaseOrError.Ok) ~= "boolean" then
		return {
			Ok = false,
			Code = "ReleaseFailed",
			Error = "Storage Release returned an invalid result",
		}
	end
	return releaseOrError
end

function ServerSaveController.new(config: {
	Id: string,
	Providers: { any },
	Storage: any,
	KeyResolver: (Player) -> string,
	SoftSerializedBytesLimit: number?,
	Logger: any?,
})
	local providersById: { [string]: any } = {}
	for _, provider in config.Providers do
		assert(typeof(provider.Id) == "string" and provider.Id ~= "", "Save provider Id required")
		assert(providersById[provider.Id] == nil, `Duplicate save provider '{provider.Id}'`)
		assert(
			provider.ClientSnapshotPolicy == nil
				or provider.ClientSnapshotPolicy == "Include"
				or provider.ClientSnapshotPolicy == "Omit",
			`Save provider '{provider.Id}' has an invalid ClientSnapshotPolicy`
		)
		providersById[provider.Id] = provider
	end

	local self = setmetatable({
		Id = config.Id,
		_providers = table.clone(config.Providers),
		_providersById = providersById,
		_storage = config.Storage,
		_keyResolver = config.KeyResolver,
		_softLimit = config.SoftSerializedBytesLimit or 3_500_000,
		_logger = config.Logger or Logger.new(`Save.Controller.{config.Id}`, "info"),
		_runtimes = {} :: { [Player]: Runtime },
		_connections = {} :: { any },
		_destroyed = false,
		PlayerLoaded = Signal.new(),
		PlayerLoadFailed = Signal.new(),
		PlayerClosed = Signal.new(),
	}, ServerSaveController)

	for _, provider in self._providers do
		if provider.MementoChanged then
			table.insert(self._connections, provider.MementoChanged:Connect(function(player: Player)
				self:MarkDirty(player, provider.Id)
			end))
		end
	end

	table.insert(self._connections, RunService.Heartbeat:Connect(function()
		for player, runtime in self._runtimes do
			if next(runtime.DirtyProviders) ~= nil and runtime.State == "Loaded" then
				local ok, err = self:_captureDirty(player, runtime)
				if not ok then
					self._logger:Error("capture_dirty_failed", {
						UserId = player.UserId,
						Error = err,
					})
				end
			end
		end
	end))

	return self
end

function ServerSaveController:GetProviders(): { any }
	return table.clone(self._providers)
end

function ServerSaveController:IsLoaded(player: Player): boolean
	local runtime = self._runtimes[player]
	return runtime ~= nil and runtime.State == "Loaded"
end

function ServerSaveController:GetState(player: Player): string
	local runtime = self._runtimes[player]
	return if runtime then runtime.State else "NotLoaded"
end

function ServerSaveController:GetDirtyPlayers(): { Player }
	local result = {}
	for player, runtime in self._runtimes do
		if runtime.State == "Loaded" and runtime.Dirty then
			table.insert(result, player)
		end
	end
	return result
end

function ServerSaveController:_makeProviderEnvelope(provider: any, data: any)
	return {
		Version = provider.Version or 1,
		Data = TableUtil.deepCopy(data),
	}
end

function ServerSaveController:_prepareProviderData(provider: any, envelope: any, player: Player): any
	local data = if typeof(envelope) == "table" then envelope.Data else nil
	local version = if typeof(envelope) == "table" and typeof(envelope.Version) == "number"
		then envelope.Version
		else 0

	if data == nil then
		data = provider:CreateDefault(player)
	elseif provider.ReconcileMemento then
		data = provider:ReconcileMemento(player, data, version)
	end

	local valid, sanitized, validationError = provider:ValidateMemento(player, data)
	if not valid then
		error(`Provider '{provider.Id}' memento is invalid: {validationError or "unknown"}`)
	end

	return if sanitized ~= nil then sanitized else data
end

function ServerSaveController:_stopProviders(player: Player)
	local runtime = self._runtimes[player]
	if runtime == nil or not runtime.Running then
		return
	end
	for index = #self._providers, 1, -1 do
		self._providers[index]:Stop(player)
	end
	runtime.Running = false
end

function ServerSaveController:ApplyMemento(player: Player, document: any)
	local runtime = self._runtimes[player]
	assert(runtime ~= nil, "Load must create runtime before ApplyMemento")

	if runtime.Running then
		local captured, captureError = self:_captureDirty(player, runtime)
		if not captured then
			error(`Could not capture dirty providers before snapshot apply: {captureError or "unknown"}`)
		end
	end

	local source = if typeof(document) == "table" then TableUtil.deepCopy(document) else createDocument()
	source.FormatVersion = SaveProtocol.FormatVersion
	source.Revision = if typeof(source.Revision) == "number" then source.Revision else 0
	source.Providers = if typeof(source.Providers) == "table" then source.Providers else {}
	source.Metadata = if typeof(source.Metadata) == "table" then source.Metadata else createDocument().Metadata

	local preparedDocumentChanged = false
	local targetValues = {}
	for _, provider in self._providers do
		local storedEnvelope = source.Providers[provider.Id]
		local data = self:_prepareProviderData(provider, storedEnvelope, player)
		local preparedEnvelope = self:_makeProviderEnvelope(provider, data)
		if not TableUtil.deepEqual(storedEnvelope, preparedEnvelope) then
			preparedDocumentChanged = true
		end
		source.Providers[provider.Id] = preparedEnvelope
		targetValues[provider] = data
	end

	-- Reconciliation and provider defaults are allowed to expand the raw
	-- document. Validate the complete persistence candidate before stopping or
	-- mutating runtime providers so a successful load can never publish state
	-- that is already impossible to save.
	local serializable, serializationIssues = SaveSerialize.validate(source)
	if not serializable then
		local first = serializationIssues[1]
		error(
			`Prepared save document is not DataStore-safe at '{if first then first.Path else ""}': `
				.. (if first then first.Reason else "unknown")
		)
	end
	local measured, encodedSize, measurementError = SaveSerialize.measureEncodedSize(source)
	if not measured then
		error(`Prepared save document could not be JSON encoded: {measurementError or "unknown"}`)
	end
	if (encodedSize :: number) > self._softLimit then
		error(
			`Prepared save document is {encodedSize} encoded bytes and exceeds the `
				.. `{self._softLimit}-byte soft size limit`
		)
	end

	local previousDocument = TableUtil.deepCopy(runtime.Document)
	local previousDirtyProviders = table.clone(runtime.DirtyProviders)
	local previousDirty = runtime.Dirty
	local previousState = runtime.State
	local wasRunning = runtime.Running
	local previousValues = {}
	if wasRunning then
		local captured, captureError = xpcall(function()
			for _, provider in self._providers do
				if provider.BeforeMementoGet then
					provider:BeforeMementoGet(player)
				end
				local current = provider:GetMemento(player)
				local valid, sanitized, validationError = provider:ValidateMemento(player, current)
				if not valid then
					error(`Provider '{provider.Id}' current runtime is invalid: {validationError or "unknown"}`)
				end
				local value = TableUtil.deepCopy(if sanitized ~= nil then sanitized else current)
				previousValues[provider] = value
				previousDocument.Providers[provider.Id] = self:_makeProviderEnvelope(provider, value)
			end
		end, debug.traceback)
		if not captured then
			error(`Could not capture current runtime before snapshot apply:\n{tostring(captureError)}`)
		end
	end

	runtime.State = "Applying"
	runtime.Document = source
	runtime.DirtyProviders = {}
	runtime.Dirty = false

	local transaction = MementoTransaction.apply({
		Providers = self._providers,
		TargetValues = targetValues,
		PreviousValues = previousValues,
		WasRunning = wasRunning,
		Capture = function(_provider)
			error("Previous values were already captured")
		end,
		Stop = function(provider)
			provider:Stop(player, wasRunning)
		end,
		SetMemento = function(provider, value)
			provider:SetMemento(player, TableUtil.deepCopy(value))
		end,
		Run = function(provider)
			provider:Run(player)
		end,
	})

	if not transaction.Ok then
		if transaction.RolledBack or (wasRunning and not transaction.MutationStarted) then
			runtime.Document = previousDocument
			runtime.DirtyProviders = previousDirtyProviders
			runtime.Dirty = previousDirty
			runtime.Running = true
			runtime.State = previousState
		else
			runtime.Running = false
			runtime.State = "ApplyFailed"
		end
		error(
			`Snapshot transaction failed{if transaction.RolledBack then " and was rolled back" else ""}:\n`
				.. tostring(transaction.Error)
				.. (if transaction.RollbackError then `\nRollback cleanup failed:\n{transaction.RollbackError}` else "")
		)
	end

	runtime.Running = true
	runtime.State = "Loaded"
	if preparedDocumentChanged then
		runtime.Document.Revision += 1
		runtime.Dirty = true
	end
end

function ServerSaveController:Load(
	player: Player,
	beforeApply: ((any, { Created: boolean }) -> (any, { string }?))?
)
	if self._runtimes[player] ~= nil then
		return {
			Ok = self:IsLoaded(player),
			Code = if self:IsLoaded(player) then nil else "AlreadyLoading",
		}
	end

	local key = self._keyResolver(player)
	local runtime: Runtime = {
		Owner = player,
		Key = key,
		Document = createDocument(),
		DirtyProviders = {},
		Dirty = false,
		Running = false,
		State = "Loading",
		ActiveSave = nil,
		ActiveClose = nil,
		CloseRequested = false,
		LastSavedAt = os.clock(),
		LastLockRefreshAt = os.clock(),
	}
	self._runtimes[player] = runtime

	local loaded = self._storage:Load(key, {
		IsCancelled = function()
			return runtime.CloseRequested
		end,
	})
	if not loaded.Ok then
		runtime.State = "LoadFailed"
		self.PlayerLoadFailed:Fire(player, loaded)
		return loaded
	end
	if runtime.CloseRequested then
		local releaseResult = releaseAfterFailedLoad(self._storage, key)
		runtime.State = "LoadCancelled"
		if not releaseResult.Ok then
			self._logger:Error("load_cancel_lock_release_failed", {
				UserId = player.UserId,
				Key = key,
				Code = releaseResult.Code,
				Error = releaseResult.Error,
			})
		end
		return {
			Ok = false,
			Code = "LoadCancelled",
			Error = if releaseResult.Ok
				then "Load was cancelled because the player is closing"
				else `Load was cancelled and lock release failed: {releaseResult.Error or releaseResult.Code or "unknown"}`,
			LockReleaseOk = releaseResult.Ok == true,
			LockReleaseCode = releaseResult.Code,
		}
	end

	local ok, applyError = xpcall(function()
		local document = loaded.Document
		local dirtyProviderIds: { string }? = nil
		if beforeApply then
			document, dirtyProviderIds = beforeApply(document, {
				Created = loaded.Created == true,
			})
			assert(typeof(document) == "table", "The pre-apply transform must return a document table")
			if dirtyProviderIds ~= nil then
				assert(typeof(dirtyProviderIds) == "table", "Pre-apply dirty provider IDs must be an array")
				local count = 0
				local seen = {}
				for index, providerId in dirtyProviderIds do
					count += 1
					assert(
						typeof(index) == "number"
							and index >= 1
							and index == math.floor(index)
							and index <= #dirtyProviderIds,
						"Pre-apply dirty provider IDs must be a dense array"
					)
					assert(
						typeof(providerId) == "string" and self._providersById[providerId] ~= nil,
						`Unknown pre-apply dirty provider '{tostring(providerId)}'`
					)
					assert(not seen[providerId], `Duplicate pre-apply dirty provider '{providerId}'`)
					seen[providerId] = true
				end
				assert(count == #dirtyProviderIds, "Pre-apply dirty provider IDs must be a dense array")

				if #dirtyProviderIds > 0 then
					assert(
						typeof(self._storage.Refresh) == "function",
						"Storage must support lock refresh for a persistent pre-apply transform"
					)
					local refreshResult = self._storage:Refresh(key)
					local refreshError = if typeof(refreshResult) == "table"
						then refreshResult.Error or refreshResult.Code or "unknown"
						else "invalid refresh result"
					assert(
						typeof(refreshResult) == "table" and refreshResult.Ok == true,
						`Session lock could not be confirmed after pre-apply transform: {refreshError}`
					)
					runtime.LastLockRefreshAt = os.clock()
				end
			end
		end
		self:ApplyMemento(player, document)
		for _, providerId in dirtyProviderIds or {} do
			self:MarkDirty(player, providerId)
		end
	end, debug.traceback)
	if not ok then
		runtime.State = "LoadFailed"
		local releaseResult = releaseAfterFailedLoad(self._storage, key)
		local errorMessage = tostring(applyError)
		if not releaseResult.Ok then
			self._logger:Error("load_failure_lock_release_failed", {
				UserId = player.UserId,
				Key = key,
				Code = releaseResult.Code,
				Error = releaseResult.Error,
			})
			errorMessage ..= `\nSession lock release also failed: {releaseResult.Error or releaseResult.Code or "unknown"}`
		end
		local failure = {
			Ok = false,
			Code = "ApplyFailed",
			Error = errorMessage,
			LockReleaseOk = releaseResult.Ok == true,
			LockReleaseCode = releaseResult.Code,
		}
		self.PlayerLoadFailed:Fire(player, failure)
		return failure
	end
	if runtime.CloseRequested then
		return {
			Ok = false,
			Code = "LoadCancelled",
			Error = "Load completed after player close was requested",
		}
	end

	self.PlayerLoaded:Fire(player)
	return {
		Ok = true,
		Created = loaded.Created == true,
		StaleTakeover = loaded.StaleTakeover == true,
	}
end

function ServerSaveController:MarkDirty(player: Player, providerId: string)
	local runtime = self._runtimes[player]
	if runtime == nil or (runtime.State ~= "Loaded" and runtime.State ~= "Applying") then
		return
	end
	if self._providersById[providerId] == nil then
		self._logger:Warn("unknown_dirty_provider", {
			UserId = player.UserId,
			ProviderId = providerId,
		})
		return
	end
	runtime.DirtyProviders[providerId] = true
	runtime.Dirty = true
end

function ServerSaveController:_captureDirty(player: Player, runtime: Runtime): (boolean, string?)
	if next(runtime.DirtyProviders) == nil then
		return true, nil
	end

	local dirtyProviders = runtime.DirtyProviders
	runtime.DirtyProviders = {}

	local function restoreDirtyProviders()
		for providerId in dirtyProviders do
			runtime.DirtyProviders[providerId] = true
		end
	end

	local providerIds = {}
	for providerId in dirtyProviders do
		table.insert(providerIds, providerId)
	end
	table.sort(providerIds)

	local capturedEnvelopes = {}
	local captured, captureError = xpcall(function()
		for _, providerId in providerIds do
			local provider = self._providersById[providerId]
			if provider == nil then
				continue
			end

			if provider.BeforeMementoGet then
				provider:BeforeMementoGet(player)
			end
			local value = provider:GetMemento(player)
			local valid, sanitized, validationError = provider:ValidateMemento(player, value)
			if not valid then
				error(`Provider '{providerId}' capture invalid: {validationError or "unknown"}`)
			end

			local data = if sanitized ~= nil then sanitized else value
			capturedEnvelopes[providerId] = self:_makeProviderEnvelope(provider, data)
		end
	end, debug.traceback)
	if not captured then
		restoreDirtyProviders()
		return false, tostring(captureError)
	end

	local changed = false
	for providerId, envelope in capturedEnvelopes do
		if not TableUtil.deepEqual(runtime.Document.Providers[providerId], envelope) then
			runtime.Document.Providers[providerId] = envelope
			changed = true
		end
	end

	if changed then
		runtime.Document.Revision += 1
		runtime.Document.Metadata.UpdatedAt = os.time()
		runtime.Dirty = true
	end
	return true, nil
end

function ServerSaveController:_captureAll(player: Player, runtime: Runtime): (boolean, string?)
	for _, provider in self._providers do
		runtime.DirtyProviders[provider.Id] = true
	end
	return self:_captureDirty(player, runtime)
end

function ServerSaveController:FlushDirty(player: Player): (boolean, string?)
	local runtime = self._runtimes[player]
	if runtime == nil then
		return false, "NotLoaded"
	end
	return self:_captureDirty(player, runtime)
end

function ServerSaveController:BuildSnapshot(player: Player)
	local runtime = self._runtimes[player]
	if runtime == nil or runtime.State ~= "Loaded" then
		return nil
	end

	local ok, err = self:_captureDirty(player, runtime)
	if not ok then
		self._logger:Error("snapshot_capture_failed", {
			UserId = player.UserId,
			Error = err,
		})
		return nil
	end

	local providers = {}
	for _, provider in self._providers do
		if provider.ClientSnapshotPolicy == "Omit" then
			continue
		end
		local envelope = runtime.Document.Providers[provider.Id]
		if envelope == nil then
			continue
		end
		local data = envelope.Data
		if provider.ToClientMemento then
			data = provider:ToClientMemento(player, data)
		end
		providers[provider.Id] = self:_makeProviderEnvelope(provider, data)
	end

	return {
		ControllerId = self.Id,
		Revision = runtime.Document.Revision,
		Providers = providers,
	}
end

function ServerSaveController:ApplyClientPatch(player: Player, patch: any)
	local runtime = self._runtimes[player]
	if runtime == nil or runtime.State ~= "Loaded" or typeof(patch) ~= "table" then
		return {
			AcceptedProviders = {},
			RejectedProviders = {},
			Revision = if runtime then runtime.Document.Revision else 0,
		}
	end

	local accepted = {}
	local rejected = {}
	local changed = false
	local providers = if typeof(patch.Providers) == "table" then patch.Providers else {}

	for providerId, envelope in providers do
		local provider = self._providersById[providerId]
		if provider == nil or provider.Authority ~= "Client" or typeof(envelope) ~= "table" then
			table.insert(rejected, providerId)
			self._logger:Warn("client_patch_provider_rejected", {
				UserId = player.UserId,
				ProviderId = tostring(providerId),
			})
			continue
		end

		local valid, sanitized, validationError = provider:ValidateMemento(player, envelope.Data)
		if not valid then
			table.insert(rejected, providerId)
			self._logger:Warn("client_patch_invalid", {
				UserId = player.UserId,
				ProviderId = providerId,
				Error = validationError,
			})
			continue
		end

		local data = if sanitized ~= nil then sanitized else envelope.Data
		if provider.ApplyClientMemento then
			provider:ApplyClientMemento(player, TableUtil.deepCopy(data))
		else
			provider:SetMemento(player, TableUtil.deepCopy(data))
		end
		runtime.Document.Providers[providerId] = self:_makeProviderEnvelope(provider, data)
		table.insert(accepted, providerId)
		changed = true
	end

	if changed then
		runtime.Document.Revision += 1
		runtime.Document.Metadata.UpdatedAt = os.time()
		runtime.Dirty = true
	end

	return {
		AcceptedProviders = accepted,
		RejectedProviders = rejected,
		Revision = runtime.Document.Revision,
	}
end

function ServerSaveController:ForceSave(player: Player, _reason: string?, options: any?)
	local runtime = self._runtimes[player]
	if runtime == nil or runtime.State ~= "Loaded" then
		return {
			Ok = false,
			Code = "NotLoaded",
			Error = "Save controller is not loaded",
		}
	end

	if options and options.Deadline and os.clock() >= options.Deadline then
		return {
			Ok = false,
			Code = "DeadlineExceeded",
			Error = "Save deadline exceeded",
		}
	end

	local activeSave = runtime.ActiveSave
	if activeSave ~= nil then
		activeSave.Pending = true
		while not activeSave.Completed do
			if options and options.Deadline and os.clock() >= options.Deadline then
				return {
					Ok = false,
					Code = "DeadlineExceeded",
					Error = "Timed out waiting for the active save",
				}
			end
			task.wait()
		end
		return TableUtil.deepCopy(activeSave.Result)
	end

	local operation: SaveOperation = {
		Pending = false,
		Completed = false,
		Result = nil,
	}
	runtime.ActiveSave = operation

	local completed, resultOrError = xpcall(function()
		local finalResult: any = nil
		repeat
			if options and options.Deadline and os.clock() >= options.Deadline then
				finalResult = {
					Ok = false,
					Code = "DeadlineExceeded",
					Error = "Save deadline exceeded",
				}
				break
			end
			operation.Pending = false
			local captured, captureError = self:_captureDirty(player, runtime)
			if not captured then
				finalResult = {
					Ok = false,
					Code = "CaptureFailed",
					Error = captureError or "Capture failed",
				}
				break
			end

			if not runtime.Dirty then
				finalResult = {
					Ok = true,
					Revision = runtime.Document.Revision,
				}
				break
			end

			local document = TableUtil.deepCopy(runtime.Document)
			local valid, issues = SaveSerialize.validate(document)
			if not valid then
				finalResult = {
					Ok = false,
					Code = "SerializeInvalid",
					Error = `{issues[1].Path}: {issues[1].Reason}`,
				}
				break
			end

			local measured, encodedSize, measurementError = SaveSerialize.measureEncodedSize(document)
			if not measured then
				finalResult = {
					Ok = false,
					Code = "SerializeInvalid",
					Error = measurementError or "Save document could not be JSON encoded",
				}
				break
			end
			if (encodedSize :: number) > self._softLimit then
				finalResult = {
					Ok = false,
					Code = "SizeLimit",
					Error = "Save document exceeds soft size limit",
				}
				break
			end

			local revisionBeingSaved = document.Revision
			local saveResult = self._storage:Save(runtime.Key, document, options)
			if not saveResult.Ok then
				finalResult = saveResult
				break
			end

			runtime.LastSavedAt = os.clock()
			runtime.LastLockRefreshAt = os.clock()
			runtime.Dirty = runtime.Document.Revision > revisionBeingSaved
				or next(runtime.DirtyProviders) ~= nil
			finalResult = {
				Ok = true,
				Revision = revisionBeingSaved,
			}
		until not operation.Pending and not runtime.Dirty
		return finalResult
	end, debug.traceback)

	local finalResult = if completed
		then resultOrError
		else {
			Ok = false,
			Code = "SaveFailed",
			Error = tostring(resultOrError),
		}
	operation.Result = finalResult
	operation.Completed = true
	runtime.ActiveSave = nil
	return finalResult
end

function ServerSaveController:RefreshLock(player: Player, options: any?)
	local runtime = self._runtimes[player]
	if runtime == nil or runtime.State ~= "Loaded" then
		return { Ok = false, Code = "NotLoaded", Error = "Not loaded" }
	end
	local result = self._storage:Refresh(runtime.Key, options)
	if result.Ok then
		runtime.LastLockRefreshAt = os.clock()
	end
	return result
end

function ServerSaveController:GetLastSavedAt(player: Player): number?
	local runtime = self._runtimes[player]
	return if runtime then runtime.LastSavedAt else nil
end

function ServerSaveController:GetLastLockRefreshAt(player: Player): number?
	local runtime = self._runtimes[player]
	return if runtime then runtime.LastLockRefreshAt else nil
end

function ServerSaveController:Close(player: Player, saveBeforeClose: boolean?, options: any?)
	local runtime = self._runtimes[player]
	if runtime == nil then
		return { Ok = true }
	end

	local activeClose = runtime.ActiveClose
	if activeClose ~= nil then
		while not activeClose.Completed do
			if options and options.Deadline and os.clock() >= options.Deadline then
				return {
					Ok = false,
					Code = "DeadlineExceeded",
					Error = "Timed out waiting for the active close",
				}
			end
			task.wait()
		end
		return TableUtil.deepCopy(activeClose.Result)
	end

	local operation: CloseOperation = {
		Completed = false,
		Result = nil,
	}
	runtime.ActiveClose = operation
	runtime.CloseRequested = true

	local completed, resultOrError = xpcall(function()
		while runtime.State == "Loading" or runtime.State == "Applying" do
			if options and options.Deadline and os.clock() >= options.Deadline then
				return {
					Ok = false,
					Code = "DeadlineExceeded",
					Error = "Timed out waiting for load or snapshot application to finish",
				}
			end
			task.wait()
		end

		if self._runtimes[player] ~= runtime then
			return { Ok = true }
		end

		local shouldSave = saveBeforeClose ~= false and (runtime.State == "Loaded" or runtime.Running)
		if shouldSave then
			local captured, captureError = self:_captureAll(player, runtime)
			if not captured then
				runtime.State = "Loaded"
				return {
					Ok = false,
					Code = "CaptureFailed",
					Error = captureError or "Close capture failed",
				}
			end
		end
		runtime.State = "Closing"

		local saveResult = { Ok = true, Revision = runtime.Document.Revision }
		if shouldSave then
			runtime.State = "Loaded"
			saveResult = self:ForceSave(player, "Close", options)
			runtime.State = "Closing"
			if not saveResult.Ok and saveResult.Code == "DeadlineExceeded" then
				runtime.State = "Loaded"
				return saveResult
			end
		end

		local stopOk, stopError = xpcall(function()
			self:_stopProviders(player)
		end, debug.traceback)
		if not stopOk then
			self._logger:Error("provider_stop_failed", {
				UserId = player.UserId,
				Error = tostring(stopError),
			})
		end

		local releaseResult = self._storage:Release(runtime.Key, options)
		if self._runtimes[player] == runtime then
			self._runtimes[player] = nil
			self.PlayerClosed:Fire(player)
		end

		if not saveResult.Ok then
			return saveResult
		end
		return releaseResult
	end, debug.traceback)

	local finalResult = if completed
		then resultOrError
		else {
			Ok = false,
			Code = "CloseFailed",
			Error = tostring(resultOrError),
		}
	operation.Result = finalResult
	operation.Completed = true
	if self._runtimes[player] == runtime then
		runtime.ActiveClose = nil
	end
	return finalResult
end

function ServerSaveController:Destroy(saveBeforeClose: boolean?)
	if self._destroyed then
		return
	end
	self._destroyed = true
	for player in self._runtimes do
		self:Close(player, saveBeforeClose)
	end
	for _, connection in self._connections do
		connection:Disconnect()
	end
	table.clear(self._connections)
	self.PlayerLoaded:Destroy()
	self.PlayerLoadFailed:Destroy()
	self.PlayerClosed:Destroy()
end

return ServerSaveController
