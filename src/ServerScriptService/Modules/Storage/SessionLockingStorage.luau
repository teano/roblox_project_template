--!strict

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TableUtil = require(ReplicatedStorage.Shared.Util.TableUtil)
local SaveProtocol = require(ReplicatedStorage.Shared.Save.SaveProtocol)
local Logger = require(ReplicatedStorage.Shared.Util.Logger)

local SessionLockingStorage = {}
SessionLockingStorage.__index = SessionLockingStorage

local MAX_LOCK_ACQUISITION_ATTEMPTS = 64

local function isFiniteNonNegative(value: any): boolean
	return typeof(value) == "number"
		and value == value
		and value ~= math.huge
		and value ~= -math.huge
		and value >= 0
end

local function isCancelled(options: any?): boolean
	return options ~= nil
		and typeof(options.IsCancelled) == "function"
		and options.IsCancelled()
end

local function readAcquisitionRetry(config: any): (number, number, number)
	local retry = config.LockAcquisitionRetry
	if retry == nil then
		return 1, 0, 0
	end
	assert(typeof(retry) == "table", "LockAcquisitionRetry must be a table")
	assert(
		typeof(retry.MaxAttempts) == "number"
			and retry.MaxAttempts == retry.MaxAttempts
			and retry.MaxAttempts ~= math.huge
			and retry.MaxAttempts ~= -math.huge
			and retry.MaxAttempts >= 1
			and retry.MaxAttempts == math.floor(retry.MaxAttempts)
			and retry.MaxAttempts <= MAX_LOCK_ACQUISITION_ATTEMPTS,
		`LockAcquisitionRetry.MaxAttempts must be an integer from 1 to {MAX_LOCK_ACQUISITION_ATTEMPTS}`
	)
	assert(
		isFiniteNonNegative(retry.BaseDelaySeconds),
		"LockAcquisitionRetry.BaseDelaySeconds must be non-negative"
	)
	assert(
		isFiniteNonNegative(retry.MaxDelaySeconds) and retry.MaxDelaySeconds >= retry.BaseDelaySeconds,
		"LockAcquisitionRetry.MaxDelaySeconds must be at least BaseDelaySeconds"
	)
	return retry.MaxAttempts, retry.BaseDelaySeconds, retry.MaxDelaySeconds
end

local function createEmptyDocument(): any
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

function SessionLockingStorage.new(baseStorage: any, config: any, logger: any?, runtime: any?)
	local maxAttempts, baseDelaySeconds, maxDelaySeconds = readAcquisitionRetry(config)
	return setmetatable({
		_base = baseStorage,
		_config = config,
		_logger = logger or Logger.new("Storage.SessionLock", "info"),
		_locks = {} :: { [string]: string },
		_lockAcquisitionMaxAttempts = maxAttempts,
		_lockAcquisitionBaseDelaySeconds = baseDelaySeconds,
		_lockAcquisitionMaxDelaySeconds = maxDelaySeconds,
		_wait = if runtime and runtime.Wait then runtime.Wait else task.wait,
	}, SessionLockingStorage)
end

function SessionLockingStorage:_makeSession(lockId: string, acquisition: any?)
	local session = {
		LockId = lockId,
		JobId = game.JobId,
		PlaceId = game.PlaceId,
		LastHeartbeatAt = os.time(),
	}
	if acquisition ~= nil and acquisition.Created == true then
		session.AcquiredFromNewProfile = true
	end
	if acquisition ~= nil and acquisition.StaleTakeover == true then
		session.AcquiredByStaleTakeover = true
	end
	return session
end

function SessionLockingStorage:_loadOnce(key: string, options: any?)
	local lockId = HttpService:GenerateGUID(false)

	local result = self._base:Update(key, function(raw)
		if raw ~= nil and typeof(raw) ~= "table" then
			return raw
		end
		local document = if typeof(raw) == "table" then TableUtil.deepCopy(raw) else createEmptyDocument()
		local session = document.Session
		local created = raw == nil
		local staleTakeover = false
		if typeof(session) == "table"
			and session.LockId == nil
			and session.AcquiredFromNewProfile == true
		then
			-- A prior owner released this never-saved profile. There is no live
			-- lock to wait for, but the storage-owned creation classification must
			-- survive until provider defaults are saved successfully.
			created = true
		elseif typeof(session) == "table" and session.LockId ~= lockId then
			local lastHeartbeat = if typeof(session.LastHeartbeatAt) == "number" then session.LastHeartbeatAt else 0
			local stale = os.time() - lastHeartbeat >= self._config.StaleLockSeconds
			if not stale then
				return nil
			end
			-- If the previous owner crashed after creating the document but
			-- before its first provider save, the transient creation marker is
			-- still authoritative. A successful save would have replaced the
			-- Session and removed this marker.
			created = session.AcquiredFromNewProfile == true
			staleTakeover = stale
		elseif typeof(session) == "table" and session.LockId == lockId then
			-- A retry of the complete UpdateAsync operation can observe a write
			-- committed by an earlier attempt whose response was lost. Carry
			-- acquisition classification in the owned final document instead of
			-- relying on callback-local side effects.
			created = session.AcquiredFromNewProfile == true
			staleTakeover = session.AcquiredByStaleTakeover == true
		end

		document.Session = self:_makeSession(lockId, {
			Created = created,
			StaleTakeover = staleTakeover,
		})
		return document
	end, options)

	if not result.Ok then
		return result
	end
	if result.Value ~= nil and typeof(result.Value) ~= "table" then
		return {
			Ok = false,
			Code = "InvalidDocument",
			Error = "Stored save document root must be a table",
		}
	end
	if typeof(result.Value) ~= "table"
		or typeof(result.Value.Session) ~= "table"
		or result.Value.Session.LockId ~= lockId
	then
		return {
			Ok = false,
			Code = "SessionLocked",
			Error = "Save is locked by another live server",
		}
	end

	self._locks[key] = lockId
	local finalSession = result.Value.Session
	return {
		Ok = true,
		Document = TableUtil.deepCopy(result.Value),
		LockId = lockId,
		Created = finalSession.AcquiredFromNewProfile == true,
		StaleTakeover = finalSession.AcquiredByStaleTakeover == true,
	}
end

function SessionLockingStorage:Load(key: string, options: any?)
	local lastResult = nil
	for attempt = 1, self._lockAcquisitionMaxAttempts do
		if isCancelled(options) then
			return {
				Ok = false,
				Code = "LoadCancelled",
				Error = "Session lock acquisition was cancelled",
			}
		end

		local result = self:_loadOnce(key, options)
		lastResult = result
		if not result.Ok and isCancelled(options) then
			return {
				Ok = false,
				Code = "LoadCancelled",
				Error = "Session lock acquisition was cancelled",
			}
		end
		if result.Ok or result.Code ~= "SessionLocked" then
			return result
		end
		if attempt < self._lockAcquisitionMaxAttempts then
			local delaySeconds = math.min(
				self._lockAcquisitionMaxDelaySeconds,
				self._lockAcquisitionBaseDelaySeconds * (2 ^ (attempt - 1))
			)
			self._wait(delaySeconds)
		end
	end

	return lastResult
end

function SessionLockingStorage:Save(key: string, document: any, options: any?)
	local lockId = self._locks[key]
	if lockId == nil then
		return {
			Ok = false,
			Code = "NoSessionLock",
			Error = "No session lock is owned for this key",
		}
	end

	local result = self._base:Update(key, function(current)
		if typeof(current) ~= "table"
			or typeof(current.Session) ~= "table"
			or current.Session.LockId ~= lockId
		then
			return nil
		end

		local nextDocument = TableUtil.deepCopy(document)
		nextDocument.Session = self:_makeSession(lockId)
		nextDocument.Metadata = nextDocument.Metadata or {}
		nextDocument.Metadata.UpdatedAt = os.time()
		return nextDocument
	end, options)

	if not result.Ok then
		return result
	end
	if typeof(result.Value) ~= "table"
		or typeof(result.Value.Session) ~= "table"
		or result.Value.Session.LockId ~= lockId
	then
		self._locks[key] = nil
		return {
			Ok = false,
			Code = "LockLost",
			Error = "Session lock ownership was lost",
		}
	end
	return {
		Ok = true,
	}
end

function SessionLockingStorage:Refresh(key: string, options: any?)
	local lockId = self._locks[key]
	if lockId == nil then
		return {
			Ok = false,
			Code = "NoSessionLock",
			Error = "No session lock is owned for this key",
		}
	end

	local result = self._base:Update(key, function(current)
		if typeof(current) ~= "table"
			or typeof(current.Session) ~= "table"
			or current.Session.LockId ~= lockId
		then
			return nil
		end
		local nextDocument = TableUtil.deepCopy(current)
		-- Acquisition classification remains authoritative until the first
		-- successful profile save. A lock heartbeat must not turn an abandoned
		-- brand-new document into an ambiguous pre-checkpoint profile.
		nextDocument.Session = self:_makeSession(lockId, {
			Created = current.Session.AcquiredFromNewProfile == true,
			StaleTakeover = current.Session.AcquiredByStaleTakeover == true,
		})
		return nextDocument
	end, options)

	if not result.Ok then
		return result
	end
	if typeof(result.Value) ~= "table"
		or typeof(result.Value.Session) ~= "table"
		or result.Value.Session.LockId ~= lockId
	then
		self._locks[key] = nil
		return {
			Ok = false,
			Code = "LockLost",
			Error = "Session lock ownership was lost",
		}
	end
	return { Ok = true }
end

function SessionLockingStorage:Release(key: string, options: any?)
	local lockId = self._locks[key]
	if lockId == nil then
		return { Ok = true }
	end

	local result = self._base:Update(key, function(current)
		if typeof(current) ~= "table"
			or typeof(current.Session) ~= "table"
			or current.Session.LockId ~= lockId
		then
			return nil
		end
		local nextDocument = TableUtil.deepCopy(current)
		if current.Session.AcquiredFromNewProfile == true then
			-- Release ownership without losing the fact that this document has
			-- never completed its first provider save. The next owner may acquire
			-- this marker immediately; Save removes it atomically with provider data.
			nextDocument.Session = {
				AcquiredFromNewProfile = true,
			}
		else
			nextDocument.Session = nil
		end
		return nextDocument
	end, options)

	if not result.Ok then
		return result
	end
	self._locks[key] = nil
	return { Ok = true }
end

function SessionLockingStorage:HasLock(key: string): boolean
	return self._locks[key] ~= nil
end

return SessionLockingStorage
