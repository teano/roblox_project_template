--!strict

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TableUtil = require(ReplicatedStorage.Shared.Util.TableUtil)
local SaveProtocol = require(ReplicatedStorage.Shared.Save.SaveProtocol)
local Logger = require(ReplicatedStorage.Shared.Util.Logger)

local SessionLockingStorage = {}
SessionLockingStorage.__index = SessionLockingStorage

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

function SessionLockingStorage.new(baseStorage: any, config: any, logger: any?)
	return setmetatable({
		_base = baseStorage,
		_config = config,
		_logger = logger or Logger.new("Storage.SessionLock", "info"),
		_locks = {} :: { [string]: string },
	}, SessionLockingStorage)
end

function SessionLockingStorage:_makeSession(lockId: string)
	return {
		LockId = lockId,
		JobId = game.JobId,
		PlaceId = game.PlaceId,
		LastHeartbeatAt = os.time(),
	}
end

function SessionLockingStorage:Load(key: string, options: any?)
	local lockId = HttpService:GenerateGUID(false)
	local acquired = false
	local staleTakeover = false

	local result = self._base:Update(key, function(raw)
		local document = if typeof(raw) == "table" then TableUtil.deepCopy(raw) else createEmptyDocument()
		local session = document.Session
		if typeof(session) == "table" and session.LockId ~= lockId then
			local lastHeartbeat = if typeof(session.LastHeartbeatAt) == "number" then session.LastHeartbeatAt else 0
			local stale = os.time() - lastHeartbeat >= self._config.StaleLockSeconds
			if not stale then
				return document
			end
			staleTakeover = stale
		end

		document.Session = self:_makeSession(lockId)
		acquired = true
		return document
	end, options)

	if not result.Ok then
		return result
	end
	if not acquired then
		return {
			Ok = false,
			Code = "SessionLocked",
			Error = "Save is locked by another live server",
		}
	end

	self._locks[key] = lockId
	return {
		Ok = true,
		Document = TableUtil.deepCopy(result.Value),
		LockId = lockId,
		StaleTakeover = staleTakeover,
	}
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

	local owned = false
	local result = self._base:Update(key, function(current)
		if typeof(current) ~= "table"
			or typeof(current.Session) ~= "table"
			or current.Session.LockId ~= lockId
		then
			return current
		end

		owned = true
		local nextDocument = TableUtil.deepCopy(document)
		nextDocument.Session = self:_makeSession(lockId)
		nextDocument.Metadata = nextDocument.Metadata or {}
		nextDocument.Metadata.UpdatedAt = os.time()
		return nextDocument
	end, options)

	if not result.Ok then
		return result
	end
	if not owned then
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

	local owned = false
	local result = self._base:Update(key, function(current)
		if typeof(current) ~= "table"
			or typeof(current.Session) ~= "table"
			or current.Session.LockId ~= lockId
		then
			return current
		end
		owned = true
		local nextDocument = TableUtil.deepCopy(current)
		nextDocument.Session = self:_makeSession(lockId)
		return nextDocument
	end, options)

	if not result.Ok then
		return result
	end
	if not owned then
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
			return current
		end
		local nextDocument = TableUtil.deepCopy(current)
		nextDocument.Session = nil
		return nextDocument
	end, options)

	self._locks[key] = nil
	if not result.Ok then
		return result
	end
	return { Ok = true }
end

function SessionLockingStorage:HasLock(key: string): boolean
	return self._locks[key] ~= nil
end

return SessionLockingStorage
