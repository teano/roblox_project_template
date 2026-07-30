--!strict

--[[
	Opt-in test. Writes only a GUID key to PlayerData_IntegrationTests_v1,
	verifies release/reload, then removes the key.

	require(game.ServerScriptService.Tests.RealDataStoreSmokeTest).run()
]]

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local ServerScriptService = game:GetService("ServerScriptService")

local DataStoreStorage = require(ServerScriptService.Modules.Storage.DataStoreStorage)
local SessionLockingStorage = require(ServerScriptService.Modules.Storage.SessionLockingStorage)

local STORE_NAME = "PlayerData_IntegrationTests_v1"

local RealDataStoreSmokeTest = {}

function RealDataStoreSmokeTest.run()
	local key = `Smoke_{HttpService:GenerateGUID(false)}`
	local config = {
		DataStoreName = STORE_NAME,
		Retry = {
			MaxAttempts = 3,
			BaseDelaySeconds = 0.25,
			MaxDelaySeconds = 1,
			JitterSeconds = 0.1,
		},
		StaleLockSeconds = 60,
	}
	local rawStore: any = nil
	local ok, resultOrError = xpcall(function()
		rawStore = DataStoreService:GetDataStore(STORE_NAME)
		local storage = SessionLockingStorage.new(DataStoreStorage.new(config, nil, rawStore), config)
		local loaded = storage:Load(key)
		assert(loaded.Ok, loaded.Error or loaded.Code)
		local document = loaded.Document
		document.Revision = 73
		document.Providers.IntegrationMarker = {
			Version = 1,
			Data = {
				Token = key,
			},
		}
		assert(storage:Save(key, document).Ok, "real DataStore save failed")
		assert(storage:Release(key).Ok, "real DataStore release failed")

		local second = SessionLockingStorage.new(DataStoreStorage.new(config, nil, rawStore), config)
		local reloaded = second:Load(key)
		assert(reloaded.Ok, reloaded.Error or reloaded.Code)
		assert(reloaded.Document.Revision == 73, "real DataStore revision mismatch")
		assert(reloaded.Document.Providers.IntegrationMarker.Data.Token == key, "real DataStore payload mismatch")
		assert(second:Release(key).Ok, "real DataStore second release failed")
		return {
			Ok = true,
			Key = key,
		}
	end, debug.traceback)

	local removed = false
	local removeError = nil
	if rawStore ~= nil then
		removed, removeError = pcall(function()
			rawStore:RemoveAsync(key)
		end)
	end
	if rawStore ~= nil and not removed then
		warn(`[RealDataStoreSmokeTest] cleanup failed for {key}: {tostring(removeError)}`)
	end
	if not ok then
		return {
			Ok = false,
			Key = key,
			Error = tostring(resultOrError),
			CleanupOk = removed,
		}
	end
	resultOrError.CleanupOk = removed
	print(`[RealDataStoreSmokeTest] passed key={key} cleanup={removed}`)
	return resultOrError
end

return RealDataStoreSmokeTest
