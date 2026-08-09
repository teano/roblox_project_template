--!strict

local Logger = require(game:GetService("ReplicatedStorage").Shared.Util.Logger)

local SessionLockModule = {}
SessionLockModule.__index = SessionLockModule

local MAX_CLEANUP_RETRY_ATTEMPTS = 3

local function ownsEntry(self: any, entry: any, controller: any): boolean
	return entry.Active and self._entriesByController[controller] == entry
end

function SessionLockModule.new(refreshIntervalSeconds: number, logger: any?, runtime: {
	Clock: (() -> number)?,
	Spawn: ((() -> ()) -> ())?,
	Wait: ((number?) -> number?)?,
}?)
	return setmetatable({
		_entries = {},
		_entriesByController = {},
		_interval = refreshIntervalSeconds,
		_logger = logger or Logger.new("SessionLock", "info"),
		_clock = if runtime and runtime.Clock then runtime.Clock else os.clock,
		_spawn = if runtime and runtime.Spawn then runtime.Spawn else task.spawn,
		_wait = if runtime and runtime.Wait then runtime.Wait else task.wait,
		_running = false,
	}, SessionLockModule)
end

function SessionLockModule:RegisterController(controller: any)
	if self._entriesByController[controller] ~= nil then
		return false
	end
	local entry = {
		Controller = controller,
		Active = true,
		CleanupAttempts = {},
	}
	table.insert(self._entries, entry)
	self._entriesByController[controller] = entry
	return true
end

function SessionLockModule:UnregisterController(controller: any): boolean
	local entry = self._entriesByController[controller]
	if entry == nil then
		return false
	end
	self._entriesByController[controller] = nil
	entry.Active = false
	local index = table.find(self._entries, entry)
	if index ~= nil then
		table.remove(self._entries, index)
	end
	return true
end

function SessionLockModule:Initialize(_playersModule: any?)
	if self._running then
		return
	end
	self._running = true
	self._spawn(function()
		while self._running do
			for _, entry in table.clone(self._entries) do
				local controller = entry.Controller
				if not ownsEntry(self, entry, controller) then
					continue
				end
				local owners = controller:GetLockOwners()
				if not ownsEntry(self, entry, controller) then
					continue
				end
				local seenOwners = {}
				for _, owner in owners do
					if not ownsEntry(self, entry, controller) then
						break
					end
					local player = owner.Player
					local runtime = owner.Runtime
					seenOwners[runtime] = true
					local shouldRefresh = controller:ShouldRefreshLock(player, runtime)
					if not ownsEntry(self, entry, controller) then
						break
					end
					if shouldRefresh then
						local lastRefresh = controller:GetLastLockRefreshAt(player) or 0
						if not ownsEntry(self, entry, controller) then
							break
						end
						if self._clock() - lastRefresh >= self._interval then
							local result = controller:RefreshLock(player, nil, runtime)
							if not ownsEntry(self, entry, controller) then
								break
							end
							if not result.Ok
								and result.Code ~= "LockRefreshBusy"
								and result.Code ~= "LockRefreshClosed"
							then
								self._logger:Warn("lock_refresh_failed", {
									UserId = player.UserId,
									Code = result.Code,
									Error = result.Error,
								})
								if not ownsEntry(self, entry, controller) then
									break
								end
							end
						end
					end

					local shouldRetry = controller:ShouldRetryClose(player, runtime)
					if not ownsEntry(self, entry, controller) then
						break
					end
					if shouldRetry then
						local attempts = entry.CleanupAttempts[runtime] or 0
						if attempts < MAX_CLEANUP_RETRY_ATTEMPTS then
							if not ownsEntry(self, entry, controller) then
								break
							end
							entry.CleanupAttempts[runtime] = attempts + 1
							local result = controller:RetryClose(player, runtime)
							if not ownsEntry(self, entry, controller) then
								break
							end
							if result.Ok then
								entry.CleanupAttempts[runtime] = nil
							else
								self._logger:Warn("close_cleanup_retry_failed", {
									UserId = player.UserId,
									Attempt = attempts + 1,
									MaxAttempts = MAX_CLEANUP_RETRY_ATTEMPTS,
									Code = result.Code,
									Error = result.Error,
								})
								if not ownsEntry(self, entry, controller) then
									break
								end
								if attempts + 1 == MAX_CLEANUP_RETRY_ATTEMPTS
									and result.Code == "ClosePreparationFailed"
								then
									local shouldFinalize = controller:ShouldRetryClose(player, runtime)
									if not ownsEntry(self, entry, controller) then
										break
									end
									if not shouldFinalize then
										continue
									end
									local finalResult = controller:FinalizeRetainedClose(player, runtime)
									if not ownsEntry(self, entry, controller) then
										break
									end
									if finalResult.Ok then
										entry.CleanupAttempts[runtime] = nil
									else
										self._logger:Warn("close_cleanup_finalization_failed", {
											UserId = player.UserId,
											Code = finalResult.Code,
											Error = finalResult.Error,
										})
										if not ownsEntry(self, entry, controller) then
											break
										end
									end
								end
							end
						end
					end
				end
				if ownsEntry(self, entry, controller) then
					for runtime in entry.CleanupAttempts do
						if not seenOwners[runtime] then
							entry.CleanupAttempts[runtime] = nil
						end
					end
				end
			end
			self._wait(math.min(30, self._interval / 2))
		end
	end)
end

function SessionLockModule:Stop()
	self._running = false
end

return SessionLockModule
