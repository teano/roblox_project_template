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
	Token: number,
	OperationGeneration: number,
}

type LifecycleOperation = {
	Kind: string,
	Token: number,
}

type Runtime = {
	Owner: Player,
	Key: string,
	Document: any,
	DirtyProviders: { [string]: boolean },
	Dirty: boolean,
	Running: boolean,
	ActiveProviders: { [any]: boolean },
	State: string,
	OperationGeneration: number,
	ActiveOperation: LifecycleOperation?,
	ActiveSave: SaveOperation?,
	ActiveClose: CloseOperation?,
	CloseGeneration: number,
	CloseRequested: boolean,
	CloseSaveRequired: boolean,
	ClosePreparationRequired: boolean,
	LockRefreshRetained: boolean,
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

local function deadlineExpired(clock: () -> number, options: any?): boolean
	return options ~= nil and options.Deadline ~= nil and clock() >= options.Deadline
end

function ServerSaveController:_beginOperation(runtime: Runtime, kind: string): LifecycleOperation?
	if runtime.ActiveOperation ~= nil then
		return nil
	end
	runtime.OperationGeneration += 1
	local operation = {
		Kind = kind,
		Token = runtime.OperationGeneration,
	}
	runtime.ActiveOperation = operation
	return operation
end

function ServerSaveController:_ownsOperation(player: Player, runtime: Runtime, operation: LifecycleOperation): boolean
	return self._runtimes[player] == runtime
		and runtime.ActiveOperation == operation
		and runtime.OperationGeneration == operation.Token
end

function ServerSaveController:_assertOperation(
	player: Player,
	runtime: Runtime,
	operation: LifecycleOperation
)
	assert(self:_ownsOperation(player, runtime, operation), `Stale {operation.Kind} operation`)
end

function ServerSaveController:_endOperation(player: Player, runtime: Runtime, operation: LifecycleOperation)
	if self:_ownsOperation(player, runtime, operation) then
		runtime.ActiveOperation = nil
	end
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
	Heartbeat: any?,
	Clock: (() -> number)?,
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
		_clock = config.Clock or os.clock,
		_closePreparation = nil :: ((Player) -> any)?,
		_runtimes = {} :: { [Player]: Runtime },
		_connections = {} :: { any },
		_destroyed = false,
		PlayerLoaded = Signal.new(),
		PlayerLoadFailed = Signal.new(),
		PlayerClosed = Signal.new(),
	}, ServerSaveController)
	local heartbeat = config.Heartbeat or RunService.Heartbeat

	for _, provider in self._providers do
		if provider.SetMutationAdmission ~= nil then
			provider:SetMutationAdmission(function(player: Player): boolean
				return self:IsProviderMutationAllowed(player)
			end)
		end
		if provider.MementoChanged then
			table.insert(self._connections, provider.MementoChanged:Connect(function(player: Player)
				self:MarkDirty(player, provider.Id)
			end))
		end
	end

	table.insert(self._connections, heartbeat:Connect(function()
		for player, runtime in self._runtimes do
			if next(runtime.DirtyProviders) ~= nil
				and runtime.State == "Loaded"
				and not runtime.CloseRequested
			then
				local operation = self:_beginOperation(runtime, "HeartbeatCapture")
				if operation == nil then
					continue
				end
				runtime.State = "Capturing"
				local ok, err = self:_captureDirty(player, runtime, operation)
				if self:_ownsOperation(player, runtime, operation) then
					runtime.State = "Loaded"
				end
				self:_endOperation(player, runtime, operation)
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

function ServerSaveController:SetClosePreparation(callback: (Player) -> any)
	assert(typeof(callback) == "function", "Close preparation callback required")
	assert(
		self._closePreparation == nil or self._closePreparation == callback,
		"Save controller close preparation is already configured"
	)
	self._closePreparation = callback
end

function ServerSaveController:IsLoaded(player: Player): boolean
	local runtime = self._runtimes[player]
	return runtime ~= nil and runtime.State == "Loaded" and not runtime.CloseRequested
end

function ServerSaveController:IsProviderMutationAllowed(player: Player): boolean
	local runtime = self._runtimes[player]
	if runtime == nil or not runtime.Running or runtime.CloseRequested then
		return false
	end
	return runtime.State == "Loaded"
		or runtime.State == "Saving"
		or runtime.State == "Capturing"
		or runtime.State == "Snapshotting"
end

local function ownsRefreshableLock(runtime: Runtime): boolean
	if runtime.State == "Loaded" then
		return not runtime.CloseRequested
	end
	return runtime.State == "CloseFailed"
		and runtime.CloseRequested
		and runtime.LockRefreshRetained
end

local function ownsRetryableClose(runtime: Runtime): boolean
	return runtime.State == "CloseFailed" and runtime.CloseRequested
end

function ServerSaveController:GetLockOwners(): { any }
	local result = {}
	for player, runtime in self._runtimes do
		if ownsRefreshableLock(runtime) or ownsRetryableClose(runtime) then
			table.insert(result, {
				Player = player,
				Runtime = runtime,
			})
		end
	end
	table.sort(result, function(a, b)
		if a.Player.UserId ~= b.Player.UserId then
			return a.Player.UserId < b.Player.UserId
		end
		return tostring(a.Player) < tostring(b.Player)
	end)
	return result
end

function ServerSaveController:ShouldRefreshLock(player: Player, expectedRuntime: Runtime?): boolean
	local runtime = self._runtimes[player]
	return runtime ~= nil
		and (expectedRuntime == nil or runtime == expectedRuntime)
		and runtime.ActiveOperation == nil
		and ownsRefreshableLock(runtime)
end

function ServerSaveController:ShouldRetryClose(player: Player, expectedRuntime: Runtime?): boolean
	local runtime = self._runtimes[player]
	return runtime ~= nil
		and (expectedRuntime == nil or runtime == expectedRuntime)
		and runtime.ActiveOperation == nil
		and runtime.ActiveClose == nil
		and ownsRetryableClose(runtime)
end

function ServerSaveController:IsRetainedCloseOwner(player: Player, expectedRuntime: Runtime?): boolean
	local runtime = self._runtimes[player]
	return runtime ~= nil
		and (expectedRuntime == nil or runtime == expectedRuntime)
		and ownsRetryableClose(runtime)
end

function ServerSaveController:RetryClose(player: Player, expectedRuntime: Runtime?, options: any?)
	if not self:IsRetainedCloseOwner(player, expectedRuntime) then
		return {
			Ok = false,
			Code = "CloseRetryStale",
			Error = "Retained close owner changed before cleanup retry",
		}
	end
	return self:Close(player, false, options, expectedRuntime)
end

function ServerSaveController:FinalizeRetainedClose(player: Player, expectedRuntime: Runtime?, options: any?)
	if not self:IsRetainedCloseOwner(player, expectedRuntime) then
		return {
			Ok = false,
			Code = "CloseRetryStale",
			Error = "Retained close owner changed before fail-closed finalization",
		}
	end
	if deadlineExpired(self._clock, options) then
		return {
			Ok = false,
			Code = "DeadlineExceeded",
			Error = "Close deadline exceeded before fail-closed finalization",
		}
	end
	return self:Close(player, false, options, expectedRuntime, true)
end

function ServerSaveController:GetState(player: Player): string
	local runtime = self._runtimes[player]
	return if runtime then runtime.State else "NotLoaded"
end

function ServerSaveController:GetDirtyPlayers(): { Player }
	local result = {}
	for player, runtime in self._runtimes do
		if runtime.State == "Loaded" and not runtime.CloseRequested and runtime.Dirty then
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
	if provider.ValidateEnvelope ~= nil and envelope ~= nil then
		local callOk, accepted = xpcall(function()
			return provider:ValidateEnvelope(player, envelope)
		end, debug.traceback)
		if not callOk or not accepted then
			error(`Provider '{provider.Id}' envelope is invalid: InvalidSettings`)
		end
	end
	local data = if typeof(envelope) == "table" then envelope.Data else nil
	local version = if typeof(envelope) == "table" and typeof(envelope.Version) == "number"
		then envelope.Version
		else 0

	if data == nil then
		data = provider:CreateDefault(player)
	elseif provider.ReconcileMemento then
		data = provider:ReconcileMemento(player, data, version)
	end
	if provider.ValidateEnvelope ~= nil and envelope == nil then
		local candidate = self:_makeProviderEnvelope(provider, data)
		local callOk, accepted = xpcall(function()
			return provider:ValidateEnvelope(player, candidate)
		end, debug.traceback)
		if not callOk or not accepted then
			error(`Provider '{provider.Id}' envelope is invalid: InvalidSettings`)
		end
	end

	local valid, sanitized, validationError = provider:ValidateMemento(player, data)
	if not valid then
		error(`Provider '{provider.Id}' memento is invalid: {validationError or "unknown"}`)
	end

	return if sanitized ~= nil then sanitized else data
end

function ServerSaveController:_stopProviders(
	player: Player,
	operation: LifecycleOperation?
): (boolean, string?)
	local runtime = self._runtimes[player]
	if runtime == nil then
		return true, nil
	end
	local errors = {}
	for index = #self._providers, 1, -1 do
		local provider = self._providers[index]
		if runtime.ActiveProviders[provider] then
			if operation ~= nil then self:_assertOperation(player, runtime, operation) end
			local ok, stopError = xpcall(function()
				provider:Stop(player)
			end, debug.traceback)
			if operation ~= nil then self:_assertOperation(player, runtime, operation) end
			if ok then
				runtime.ActiveProviders[provider] = nil
			else
				table.insert(errors, `Provider '{provider.Id}' Stop failed:\n{tostring(stopError)}`)
			end
		end
	end
	if next(runtime.ActiveProviders) == nil then
		runtime.Running = false
	end
	if #errors > 0 then
		return false, table.concat(errors, "\n---\n")
	end
	return true, nil
end

function ServerSaveController:ApplyMemento(player: Player, document: any)
	local runtime = self._runtimes[player]
	assert(runtime ~= nil, "Load must create runtime before ApplyMemento")
	assert(runtime.ActiveClose == nil and not runtime.CloseRequested, "Snapshot application is blocked by close")
	local operation = self:_beginOperation(runtime, "Apply")
	assert(operation ~= nil, "Snapshot application is blocked by another lifecycle operation")
	local ok, result = xpcall(function()
		self:_applyMemento(player, document, operation :: LifecycleOperation)
	end, debug.traceback)
	self:_endOperation(player, runtime, operation :: LifecycleOperation)
	if not ok then
		error(result, 0)
	end
end

function ServerSaveController:_applyMemento(player: Player, document: any, operation: LifecycleOperation)
	local runtime = self._runtimes[player]
	assert(runtime ~= nil, "Load must create runtime before ApplyMemento")
	self:_assertOperation(player, runtime, operation)
	local previousState = runtime.State
	assert(previousState == "Loading" or previousState == "Loaded", "Snapshot application is already in progress")
	local wasRunning = runtime.Running
	runtime.State = "Applying"

	-- Provider envelope hooks may yield. Reserve the runtime before entering any
	-- hook, and complete target validation/measurement before capturing current
	-- state or mutating a live provider.
	local prepared, preparedOrError = xpcall(function()
		local source = if typeof(document) == "table" then TableUtil.deepCopy(document) else createDocument()
		source.FormatVersion = SaveProtocol.FormatVersion
		source.Revision = if typeof(source.Revision) == "number" then source.Revision else 0
		source.Providers = if typeof(source.Providers) == "table" then source.Providers else {}
		source.Metadata = if typeof(source.Metadata) == "table" then source.Metadata else createDocument().Metadata

		local preparedDocumentChanged = false
		local targetValues = {}
		for _, provider in self._providers do
			self:_assertOperation(player, runtime, operation)
			local storedEnvelope = source.Providers[provider.Id]
			local data = self:_prepareProviderData(provider, storedEnvelope, player)
			self:_assertOperation(player, runtime, operation)
			local preparedEnvelope = self:_makeProviderEnvelope(provider, data)
			if not TableUtil.deepEqual(storedEnvelope, preparedEnvelope) then
				preparedDocumentChanged = true
			end
			source.Providers[provider.Id] = preparedEnvelope
			targetValues[provider] = data
		end

		-- Revision and metadata are part of the exact persistence candidate, so
		-- finalize them before serialization and the authoritative byte measure.
		if preparedDocumentChanged then
			source.Revision += 1
			source.Metadata.UpdatedAt = os.time()
		end
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

		-- Rollback state is captured through the normal generation-aware path.
		-- This preserves data/revision/metadata coherence when a later Run fails.
		if wasRunning then
			local captured, captureError = self:_captureAll(player, runtime, operation)
			self:_assertOperation(player, runtime, operation)
			if not captured then
				error(`Could not capture current runtime before snapshot apply:\n{captureError or "unknown"}`)
			end
		end

		local previousDocument = TableUtil.deepCopy(runtime.Document)
		local previousValues = {}
		if wasRunning then
			for _, provider in self._providers do
				local envelope = previousDocument.Providers[provider.Id]
				assert(typeof(envelope) == "table", `Provider '{provider.Id}' rollback envelope is missing`)
				previousValues[provider] = TableUtil.deepCopy(envelope.Data)
			end
		end
		return {
			Source = source,
			TargetValues = targetValues,
			PreparedDocumentChanged = preparedDocumentChanged,
			PreviousDocument = previousDocument,
			PreviousDirtyProviders = table.clone(runtime.DirtyProviders),
			PreviousDirty = runtime.Dirty,
			PreviousValues = previousValues,
		}
	end, debug.traceback)
	if not prepared then
		if self:_ownsOperation(player, runtime, operation) then
			runtime.State = previousState
		end
		error(preparedOrError, 0)
	end

	self:_assertOperation(player, runtime, operation)
	local preparation = preparedOrError
	runtime.Document = preparation.Source
	runtime.DirtyProviders = {}
	runtime.Dirty = preparation.PreparedDocumentChanged

	local transaction = MementoTransaction.apply({
		Providers = self._providers,
		TargetValues = preparation.TargetValues,
		PreviousValues = preparation.PreviousValues,
		WasRunning = wasRunning,
		Capture = function(_provider)
			error("Previous values were already captured")
		end,
		Stop = function(provider)
			self:_assertOperation(player, runtime, operation)
			provider:Stop(player, wasRunning)
			self:_assertOperation(player, runtime, operation)
			runtime.ActiveProviders[provider] = nil
		end,
		SetMemento = function(provider, value)
			self:_assertOperation(player, runtime, operation)
			provider:SetMemento(player, TableUtil.deepCopy(value))
			self:_assertOperation(player, runtime, operation)
		end,
		Run = function(provider)
			self:_assertOperation(player, runtime, operation)
			runtime.ActiveProviders[provider] = true
			provider:Run(player)
			self:_assertOperation(player, runtime, operation)
		end,
	})

	self:_assertOperation(player, runtime, operation)
	if not transaction.Ok then
		if transaction.RolledBack or (wasRunning and not transaction.MutationStarted) then
			local transactionDirtyProviders = runtime.DirtyProviders
			runtime.Document = preparation.PreviousDocument
			runtime.DirtyProviders = preparation.PreviousDirtyProviders
			for providerId in transactionDirtyProviders do
				runtime.DirtyProviders[providerId] = true
			end
			runtime.Dirty = preparation.PreviousDirty or next(runtime.DirtyProviders) ~= nil
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
		ActiveProviders = {},
		State = "Loading",
		OperationGeneration = 1,
		ActiveOperation = nil,
		ActiveSave = nil,
		ActiveClose = nil,
		CloseGeneration = 0,
		CloseRequested = false,
		CloseSaveRequired = false,
		ClosePreparationRequired = false,
		LockRefreshRetained = false,
		LastSavedAt = self._clock(),
		LastLockRefreshAt = self._clock(),
	}
	local loadOperation: LifecycleOperation = { Kind = "Load", Token = 1 }
	runtime.ActiveOperation = loadOperation
	self._runtimes[player] = runtime

	local loaded = self._storage:Load(key, {
		IsCancelled = function()
			return runtime.CloseRequested
		end,
	})
	self:_assertOperation(player, runtime, loadOperation)
	if not loaded.Ok then
		runtime.State = "LoadFailed"
		self:_endOperation(player, runtime, loadOperation)
		self.PlayerLoadFailed:Fire(player, loaded)
		return loaded
	end
	if runtime.CloseRequested then
		local releaseResult = releaseAfterFailedLoad(self._storage, key)
		self:_assertOperation(player, runtime, loadOperation)
		runtime.State = "LoadCancelled"
		if not releaseResult.Ok then
			self._logger:Error("load_cancel_lock_release_failed", {
				UserId = player.UserId,
				Key = key,
				Code = releaseResult.Code,
				Error = releaseResult.Error,
			})
		end
		local cancelled = {
			Ok = false,
			Code = "LoadCancelled",
			Error = if releaseResult.Ok
				then "Load was cancelled because the player is closing"
				else `Load was cancelled and lock release failed: {releaseResult.Error or releaseResult.Code or "unknown"}`,
			LockReleaseOk = releaseResult.Ok == true,
			LockReleaseCode = releaseResult.Code,
		}
		self:_endOperation(player, runtime, loadOperation)
		return cancelled
	end

	local ok, applyError = xpcall(function()
		local document = loaded.Document
		local dirtyProviderIds: { string }? = nil
		if beforeApply then
			document, dirtyProviderIds = beforeApply(document, {
				Created = loaded.Created == true,
			})
			self:_assertOperation(player, runtime, loadOperation)
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
					self:_assertOperation(player, runtime, loadOperation)
					local refreshError = if typeof(refreshResult) == "table"
						then refreshResult.Error or refreshResult.Code or "unknown"
						else "invalid refresh result"
					assert(
						typeof(refreshResult) == "table" and refreshResult.Ok == true,
						`Session lock could not be confirmed after pre-apply transform: {refreshError}`
					)
					runtime.LastLockRefreshAt = self._clock()
				end
			end
		end
		self:_applyMemento(player, document, loadOperation)
		self:_assertOperation(player, runtime, loadOperation)
		for _, providerId in dirtyProviderIds or {} do
			self:MarkDirty(player, providerId)
		end
	end, debug.traceback)
	if not ok then
		self:_assertOperation(player, runtime, loadOperation)
		runtime.State = "LoadFailed"
		local stopped, stopError = self:_stopProviders(player, loadOperation)
		self:_assertOperation(player, runtime, loadOperation)
		if not stopped then
			local failure = {
				Ok = false,
				Code = "ApplyFailed",
				Error = `{tostring(applyError)}\nTerminal provider cleanup failed:\n{stopError or "unknown"}`,
				LockReleaseOk = false,
				LockReleaseCode = "ProviderStopFailed",
			}
			self:_endOperation(player, runtime, loadOperation)
			self.PlayerLoadFailed:Fire(player, failure)
			return failure
		end
		local releaseResult = releaseAfterFailedLoad(self._storage, key)
		self:_assertOperation(player, runtime, loadOperation)
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
		self:_endOperation(player, runtime, loadOperation)
		self.PlayerLoadFailed:Fire(player, failure)
		return failure
	end
	self:_assertOperation(player, runtime, loadOperation)
	self:_endOperation(player, runtime, loadOperation)
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
	if runtime == nil
		or (
			runtime.State ~= "Loaded"
			and runtime.State ~= "Applying"
			and runtime.State ~= "Saving"
			and runtime.State ~= "Capturing"
			and runtime.State ~= "Snapshotting"
			and runtime.State ~= "Closing"
		)
	then
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

function ServerSaveController:_captureDirty(
	player: Player,
	runtime: Runtime,
	operation: LifecycleOperation
): (boolean, string?)
	self:_assertOperation(player, runtime, operation)
	if next(runtime.DirtyProviders) == nil then
		return true, nil
	end

	local dirtyProviders = runtime.DirtyProviders
	self:_assertOperation(player, runtime, operation)
	runtime.DirtyProviders = {}

	local function restoreDirtyProviders()
		self:_assertOperation(player, runtime, operation)
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
			self:_assertOperation(player, runtime, operation)
			local provider = self._providersById[providerId]
			if provider == nil then
				continue
			end

			if provider.BeforeMementoGet then
				provider:BeforeMementoGet(player)
				self:_assertOperation(player, runtime, operation)
			end
			local value = provider:GetMemento(player)
			self:_assertOperation(player, runtime, operation)
			local valid, sanitized, validationError = provider:ValidateMemento(player, value)
			self:_assertOperation(player, runtime, operation)
			if not valid then
				error(`Provider '{providerId}' capture invalid: {validationError or "unknown"}`)
			end

			local data = if sanitized ~= nil then sanitized else value
			capturedEnvelopes[providerId] = self:_makeProviderEnvelope(provider, data)
		end
	end, debug.traceback)
	if not captured then
		if self:_ownsOperation(player, runtime, operation) then
			restoreDirtyProviders()
		end
		return false, tostring(captureError)
	end

	local changed = false
	self:_assertOperation(player, runtime, operation)
	for providerId, envelope in capturedEnvelopes do
		self:_assertOperation(player, runtime, operation)
		if not TableUtil.deepEqual(runtime.Document.Providers[providerId], envelope) then
			runtime.Document.Providers[providerId] = envelope
			changed = true
		end
	end

	if changed then
		self:_assertOperation(player, runtime, operation)
		runtime.Document.Revision += 1
		runtime.Document.Metadata.UpdatedAt = os.time()
		runtime.Dirty = true
	end
	return true, nil
end

function ServerSaveController:_captureAll(
	player: Player,
	runtime: Runtime,
	operation: LifecycleOperation
): (boolean, string?)
	for _, provider in self._providers do
		self:_assertOperation(player, runtime, operation)
		runtime.DirtyProviders[provider.Id] = true
	end
	return self:_captureDirty(player, runtime, operation)
end

function ServerSaveController:FlushDirty(player: Player): (boolean, string?)
	local runtime = self._runtimes[player]
	if runtime == nil then
		return false, "NotLoaded"
	end
	if runtime.State ~= "Loaded" or runtime.CloseRequested then
		return false, "Busy"
	end
	local operation = self:_beginOperation(runtime, "FlushDirty")
	if operation == nil then
		return false, "Busy"
	end
	runtime.State = "Capturing"
	local ok, err = self:_captureDirty(player, runtime, operation)
	if self:_ownsOperation(player, runtime, operation) then
		runtime.State = "Loaded"
	end
	self:_endOperation(player, runtime, operation)
	return ok, err
end

function ServerSaveController:BuildSnapshot(player: Player)
	local runtime = self._runtimes[player]
	if runtime == nil or runtime.State ~= "Loaded" or runtime.CloseRequested then
		return nil
	end
	local operation = self:_beginOperation(runtime, "BuildSnapshot")
	if operation == nil then
		return nil
	end
	runtime.State = "Snapshotting"

	local completed, snapshotOrError = xpcall(function()
		local ok, err = self:_captureDirty(player, runtime, operation)
		self:_assertOperation(player, runtime, operation)
		if not ok then
			error(err or "Snapshot capture failed")
		end

		local providers = {}
		for _, provider in self._providers do
			self:_assertOperation(player, runtime, operation)
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
				self:_assertOperation(player, runtime, operation)
			end
			providers[provider.Id] = self:_makeProviderEnvelope(provider, data)
		end

		self:_assertOperation(player, runtime, operation)
		return {
			ControllerId = self.Id,
			Revision = runtime.Document.Revision,
			Providers = providers,
		}
	end, debug.traceback)
	if self:_ownsOperation(player, runtime, operation) then
		runtime.State = "Loaded"
	end
	self:_endOperation(player, runtime, operation)
	if not completed then
		self._logger:Error("snapshot_capture_failed", {
			UserId = player.UserId,
			Error = tostring(snapshotOrError),
		})
		return nil
	end
	return snapshotOrError
end

function ServerSaveController:ApplyClientPatch(player: Player, patch: any)
	local runtime = self._runtimes[player]
	if runtime == nil
		or runtime.State ~= "Loaded"
		or runtime.CloseRequested
		or typeof(patch) ~= "table"
	then
		return {
			AcceptedProviders = {},
			RejectedProviders = {},
			Revision = if runtime then runtime.Document.Revision else 0,
		}
	end
	local operation = self:_beginOperation(runtime, "ApplyClientPatch")
	if operation == nil then
		return {
			AcceptedProviders = {},
			RejectedProviders = {},
			Revision = runtime.Document.Revision,
		}
	end

	local providers = if typeof(patch.Providers) == "table" then patch.Providers else {}
	local completed, resultOrError = xpcall(function()
		local accepted = {}
		local rejected = {}
		local changed = false

		local function stillOwnsOpenPatch(): boolean
			return self:_ownsOperation(player, runtime :: Runtime, operation :: LifecycleOperation)
				and runtime.State == "Loaded"
				and not runtime.CloseRequested
		end

		local function closedResult()
			local allRejected = {}
			for providerId in providers do
				table.insert(allRejected, providerId)
			end
			return {
				AcceptedProviders = {},
				RejectedProviders = allRejected,
				Revision = runtime.Document.Revision,
			}
		end

		for providerId, envelope in providers do
			if not stillOwnsOpenPatch() then
				return closedResult()
			end
			local provider = self._providersById[providerId]
			if provider == nil or provider.Authority ~= "Client" or typeof(envelope) ~= "table" then
				table.insert(rejected, providerId)
				self._logger:Warn("client_patch_provider_rejected", {
					UserId = player.UserId,
					ProviderId = tostring(providerId),
				})
				continue
			end

			if provider.ValidateEnvelope ~= nil then
				local callOk, envelopeAccepted = xpcall(function()
					return provider:ValidateEnvelope(player, envelope)
				end, debug.traceback)
				if not stillOwnsOpenPatch() then
					return closedResult()
				end
				if not callOk or not envelopeAccepted then
					table.insert(rejected, providerId)
					self._logger:Warn("client_patch_invalid", {
						UserId = player.UserId,
						ProviderId = providerId,
						Error = "InvalidSettings",
					})
					continue
				end
			end

			local valid, sanitized, validationError = provider:ValidateMemento(player, envelope.Data)
			if not stillOwnsOpenPatch() then
				return closedResult()
			end
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
			if not stillOwnsOpenPatch() then
				return closedResult()
			end
			runtime.Document.Providers[providerId] = self:_makeProviderEnvelope(provider, data)
			table.insert(accepted, providerId)
			changed = true
		end

		if not stillOwnsOpenPatch() then
			return closedResult()
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
	end, debug.traceback)
	self:_endOperation(player, runtime, operation :: LifecycleOperation)
	if not completed then
		error(resultOrError, 0)
	end
	return resultOrError
end

function ServerSaveController:_waitForSave(operation: SaveOperation, options: any?): any
	operation.Pending = true
	while not operation.Completed do
		if deadlineExpired(self._clock, options) then
			return {
				Ok = false,
				Code = "DeadlineExceeded",
				Error = "Timed out waiting for the active save",
			}
		end
		task.wait()
	end
	return TableUtil.deepCopy(operation.Result)
end

function ServerSaveController:_forceSaveUnderOperation(
	player: Player,
	runtime: Runtime,
	lifecycle: LifecycleOperation,
	options: any?
): any
	local activeSave = runtime.ActiveSave
	if activeSave ~= nil then
		return self:_waitForSave(activeSave, options)
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
			self:_assertOperation(player, runtime, lifecycle)
			if deadlineExpired(self._clock, options) then
				finalResult = {
					Ok = false,
					Code = "DeadlineExceeded",
					Error = "Save deadline exceeded",
				}
				break
			end
			operation.Pending = false
			local captured, captureError = self:_captureDirty(player, runtime, lifecycle)
			self:_assertOperation(player, runtime, lifecycle)
			if not captured then
				finalResult = {
					Ok = false,
					Code = "CaptureFailed",
					Error = captureError or "Capture failed",
				}
				break
			end
			if deadlineExpired(self._clock, options) then
				finalResult = {
					Ok = false,
					Code = "DeadlineExceeded",
					Error = "Save deadline exceeded after capture",
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
			if deadlineExpired(self._clock, options) then
				finalResult = {
					Ok = false,
					Code = "DeadlineExceeded",
					Error = "Save deadline exceeded before storage write",
				}
				break
			end

			local revisionBeingSaved = document.Revision
			local saveResult = self._storage:Save(runtime.Key, document, options)
			self:_assertOperation(player, runtime, lifecycle)
			if typeof(saveResult) ~= "table" or typeof(saveResult.Ok) ~= "boolean" then
				finalResult = {
					Ok = false,
					Code = "SaveFailed",
					Error = "Storage Save returned an invalid result",
				}
				break
			end
			if not saveResult.Ok then
				finalResult = saveResult
				break
			end

			runtime.LastSavedAt = self._clock()
			runtime.LastLockRefreshAt = self._clock()
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
	if runtime.ActiveSave == operation then
		runtime.ActiveSave = nil
	end
	return finalResult
end

function ServerSaveController:ForceSave(player: Player, _reason: string?, options: any?)
	local runtime = self._runtimes[player]
	if runtime == nil then
		return {
			Ok = false,
			Code = "NotLoaded",
			Error = "Save controller is not loaded",
		}
	end

	local activeSave = runtime.ActiveSave
	if activeSave ~= nil then
		return self:_waitForSave(activeSave, options)
	end
	if runtime.State ~= "Loaded" or runtime.CloseRequested or runtime.ActiveOperation ~= nil then
		return {
			Ok = false,
			Code = "NotLoaded",
			Error = "Save controller is not loaded",
		}
	end

	if deadlineExpired(self._clock, options) then
		return {
			Ok = false,
			Code = "DeadlineExceeded",
			Error = "Save deadline exceeded",
		}
	end

	local lifecycle = self:_beginOperation(runtime, "Save")
	assert(lifecycle ~= nil, "Save lifecycle operation could not be reserved")
	runtime.State = "Saving"
	local finalResult = self:_forceSaveUnderOperation(player, runtime, lifecycle :: LifecycleOperation, options)
	if self:_ownsOperation(player, runtime, lifecycle :: LifecycleOperation) then
		runtime.State = "Loaded"
	end
	self:_endOperation(player, runtime, lifecycle :: LifecycleOperation)
	return finalResult
end

function ServerSaveController:RefreshLock(player: Player, options: any?, expectedRuntime: Runtime?)
	local runtime = self._runtimes[player]
	if runtime == nil
		or (expectedRuntime ~= nil and runtime ~= expectedRuntime)
		or not ownsRefreshableLock(runtime)
	then
		return { Ok = false, Code = "NotLoaded", Error = "Not loaded" }
	end
	local lifecycle = self:_beginOperation(runtime, "RefreshLock")
	if lifecycle == nil then
		return { Ok = false, Code = "LockRefreshBusy", Error = "Another lifecycle operation is active" }
	end

	local callOk, result = xpcall(function()
		return self._storage:Refresh(runtime.Key, options)
	end, debug.traceback)
	if not self:_ownsOperation(player, runtime, lifecycle) or not ownsRefreshableLock(runtime) then
		self:_endOperation(player, runtime, lifecycle)
		return {
			Ok = false,
			Code = "LockRefreshClosed",
			Error = "Lock refresh completed after terminal cleanup began",
		}
	end
	if not callOk or typeof(result) ~= "table" or typeof(result.Ok) ~= "boolean" then
		self:_endOperation(player, runtime, lifecycle)
		return {
			Ok = false,
			Code = "LockRefreshFailed",
			Error = if callOk then "Storage Refresh returned an invalid result" else tostring(result),
		}
	end
	if result.Ok then
		runtime.LastLockRefreshAt = self._clock()
	elseif result.Code == "LockLost" or result.Code == "NoSessionLock" then
		-- Storage has authoritatively reported that this process no longer owns
		-- the lock. Keep the runtime fail-closed for terminal cleanup retry, but
		-- stop claiming or scheduling heartbeat ownership.
		runtime.LockRefreshRetained = false
	end
	self:_endOperation(player, runtime, lifecycle)
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

function ServerSaveController:Close(
	player: Player,
	saveBeforeClose: boolean?,
	options: any?,
	expectedRuntime: Runtime?,
	skipClosePreparation: boolean?
)
	local runtime = self._runtimes[player]
	if runtime == nil then
		return if expectedRuntime == nil
			then { Ok = true }
			else { Ok = false, Code = "CloseRetryStale", Error = "Retained close owner no longer exists" }
	end
	if expectedRuntime ~= nil and runtime ~= expectedRuntime then
		return {
			Ok = false,
			Code = "CloseRetryStale",
			Error = "Retained close owner changed before cleanup",
		}
	end

	local activeClose = runtime.ActiveClose
	if activeClose ~= nil then
		while not activeClose.Completed do
			if deadlineExpired(self._clock, options) then
				return {
					Ok = false,
					Code = "DeadlineExceeded",
					Error = "Timed out waiting for the active close",
				}
			end
			task.wait()
		end
		if expectedRuntime ~= nil and self._runtimes[player] ~= expectedRuntime then
			return {
				Ok = false,
				Code = "CloseRetryStale",
				Error = "Retained close owner changed while waiting for cleanup",
			}
		end
		return TableUtil.deepCopy(activeClose.Result)
	end

	local priorCloseRequested = runtime.CloseRequested
	local priorCloseSaveRequired = runtime.CloseSaveRequired
	local priorClosePreparationRequired = runtime.ClosePreparationRequired
	local priorLockRefreshRetained = runtime.LockRefreshRetained
	local operation: CloseOperation = {
		Completed = false,
		Result = nil,
		Token = runtime.CloseGeneration + 1,
		OperationGeneration = runtime.OperationGeneration,
	}
	runtime.CloseGeneration = operation.Token
	runtime.ActiveClose = operation
	runtime.CloseRequested = true
	local lifecycle: LifecycleOperation? = nil

	local completed, resultOrError = xpcall(function()
		while runtime.ActiveOperation ~= nil do
			if deadlineExpired(self._clock, options) then
				if self._runtimes[player] == runtime
					and runtime.ActiveClose == operation
					and runtime.CloseGeneration == operation.Token
					and runtime.OperationGeneration == operation.OperationGeneration
				then
					runtime.CloseRequested = priorCloseRequested
					runtime.CloseSaveRequired = priorCloseSaveRequired
					runtime.ClosePreparationRequired = priorClosePreparationRequired
					runtime.LockRefreshRetained = priorLockRefreshRetained
				end
				return {
					Ok = false,
					Code = "DeadlineExceeded",
					Error = "Timed out waiting for the active lifecycle operation to finish",
				}
			end
			task.wait()
		end

		if self._runtimes[player] ~= runtime then
			return if expectedRuntime == nil
				then { Ok = true }
				else { Ok = false, Code = "CloseRetryStale", Error = "Retained close owner changed" }
		end

		lifecycle = self:_beginOperation(runtime, "Close")
		assert(lifecycle ~= nil, "Close lifecycle operation could not be reserved")
		local reserved = lifecycle :: LifecycleOperation
		local stateBeforeClose = runtime.State
		if stateBeforeClose ~= "CloseFailed" then
			runtime.CloseSaveRequired = saveBeforeClose ~= false
				and (stateBeforeClose == "Loaded" or runtime.Running)
			runtime.ClosePreparationRequired = self._closePreparation ~= nil
		elseif saveBeforeClose == true and runtime.Running then
			runtime.CloseSaveRequired = true
		end
		if skipClosePreparation == true then
			runtime.ClosePreparationRequired = false
		end
		local shouldSave = runtime.CloseSaveRequired and runtime.Running
		runtime.State = "Closing"
		if deadlineExpired(self._clock, options) then
			runtime.State = "CloseFailed"
			runtime.LockRefreshRetained = true
			return {
				Ok = false,
				Code = "DeadlineExceeded",
				Error = "Close deadline exceeded before preparation",
			}
		end
		if runtime.ClosePreparationRequired and self._closePreparation ~= nil then
			local preparationCallOk, preparationResult = xpcall(function()
				return (self._closePreparation :: (Player) -> any)(player)
			end, debug.traceback)
			self:_assertOperation(player, runtime, reserved)
			local preparationAccepted = preparationCallOk
				and typeof(preparationResult) == "table"
				and (preparationResult.Ok == true or preparationResult.Code == "NotLoaded")
			if not preparationAccepted then
				runtime.State = "CloseFailed"
				runtime.LockRefreshRetained = true
				if preparationCallOk and typeof(preparationResult) == "table" then
					return preparationResult
				end
				return {
					Ok = false,
					Code = "ClosePreparationFailed",
					Error = if preparationCallOk
						then "Close preparation returned an invalid result"
						else tostring(preparationResult),
				}
			end
			runtime.ClosePreparationRequired = false
			if deadlineExpired(self._clock, options) then
				runtime.State = "CloseFailed"
				runtime.LockRefreshRetained = true
				return {
					Ok = false,
					Code = "DeadlineExceeded",
					Error = "Close deadline exceeded after preparation",
				}
			end
		end
		if shouldSave then
			local captured, captureError = self:_captureAll(player, runtime, reserved)
			self:_assertOperation(player, runtime, reserved)
			if not captured then
				runtime.State = "CloseFailed"
				runtime.LockRefreshRetained = true
				return {
					Ok = false,
					Code = "CaptureFailed",
					Error = captureError or "Close capture failed",
				}
			end
			if deadlineExpired(self._clock, options) then
				runtime.State = "CloseFailed"
				runtime.LockRefreshRetained = true
				return {
					Ok = false,
					Code = "DeadlineExceeded",
					Error = "Close deadline exceeded after capture",
				}
			end
		end

		local saveResult = { Ok = true, Revision = runtime.Document.Revision }
		if shouldSave then
			saveResult = self:_forceSaveUnderOperation(player, runtime, reserved, options)
			self:_assertOperation(player, runtime, reserved)
			if typeof(saveResult) ~= "table" or typeof(saveResult.Ok) ~= "boolean" then
				runtime.State = "CloseFailed"
				runtime.LockRefreshRetained = true
				return {
					Ok = false,
					Code = "SaveFailed",
					Error = "Save operation returned an invalid result",
				}
			end
			if not saveResult.Ok then
				runtime.State = "CloseFailed"
				runtime.LockRefreshRetained = saveResult.Code ~= "LockLost"
					and saveResult.Code ~= "NoSessionLock"
				return saveResult
			end
			if saveResult.Ok then
				runtime.CloseSaveRequired = false
			end
		end

		if deadlineExpired(self._clock, options) then
			runtime.State = "CloseFailed"
			runtime.LockRefreshRetained = true
			return {
				Ok = false,
				Code = "DeadlineExceeded",
				Error = "Close deadline exceeded before provider stop",
			}
		end
		local stopOk, stopError = self:_stopProviders(player, reserved)
		self:_assertOperation(player, runtime, reserved)
		if not stopOk then
			self._logger:Error("provider_stop_failed", {
				UserId = player.UserId,
				Error = tostring(stopError),
			})
			runtime.State = "CloseFailed"
			runtime.LockRefreshRetained = true
			return {
				Ok = false,
				Code = "ProviderStopFailed",
				Error = stopError or "Provider cleanup failed",
			}
		end
		if deadlineExpired(self._clock, options) then
			runtime.State = "CloseFailed"
			runtime.LockRefreshRetained = true
			return {
				Ok = false,
				Code = "DeadlineExceeded",
				Error = "Close deadline exceeded before lock release",
			}
		end

		local releaseCallOk, releaseResult = xpcall(function()
			return self._storage:Release(runtime.Key, options)
		end, debug.traceback)
		self:_assertOperation(player, runtime, reserved)
		if not releaseCallOk
			or typeof(releaseResult) ~= "table"
			or typeof(releaseResult.Ok) ~= "boolean"
		then
			runtime.State = "CloseFailed"
			runtime.LockRefreshRetained = true
			return {
				Ok = false,
				Code = "ReleaseFailed",
				Error = if releaseCallOk then "Storage Release returned an invalid result" else tostring(releaseResult),
			}
		end
		if not releaseResult.Ok then
			runtime.State = "CloseFailed"
			runtime.LockRefreshRetained = releaseResult.Code ~= "LockLost"
				and releaseResult.Code ~= "NoSessionLock"
			return releaseResult
		end
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
		if not completed and runtime.State ~= "CloseFailed" then
			runtime.State = "CloseFailed"
			runtime.LockRefreshRetained = true
		end
		if lifecycle ~= nil then
			self:_endOperation(player, runtime, lifecycle :: LifecycleOperation)
		end
		runtime.ActiveClose = nil
	end
	return finalResult
end

function ServerSaveController:Destroy(saveBeforeClose: boolean?)
	if self._destroyed then
		return { Ok = true }
	end
	local players = {}
	for player in self._runtimes do
		table.insert(players, player)
	end
	table.sort(players, function(a, b)
		if a.UserId ~= b.UserId then
			return a.UserId < b.UserId
		end
		return tostring(a) < tostring(b)
	end)
	local failures = {}
	for _, player in players do
		local result = self:Close(player, saveBeforeClose)
		if self._runtimes[player] ~= nil then
			table.insert(failures, `UserId {player.UserId}: {tostring(result.Code or "CloseFailed")} - {tostring(result.Error or "cleanup incomplete")}`)
		end
	end
	if #failures > 0 or next(self._runtimes) ~= nil then
		return {
			Ok = false,
			Code = "DestroyFailed",
			Error = table.concat(failures, "\n"),
		}
	end
	self._destroyed = true
	for _, connection in self._connections do
		connection:Disconnect()
	end
	table.clear(self._connections)
	self.PlayerLoaded:Destroy()
	self.PlayerLoadFailed:Destroy()
	self.PlayerClosed:Destroy()
	return { Ok = true }
end

return ServerSaveController
