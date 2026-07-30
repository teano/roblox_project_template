--!strict

local Logger = require(game:GetService("ReplicatedStorage").Shared.Util.Logger)

local SessionLockModule = {}
SessionLockModule.__index = SessionLockModule

function SessionLockModule.new(refreshIntervalSeconds: number, logger: any?, runtime: {
	Clock: (() -> number)?,
	Spawn: ((() -> ()) -> ())?,
	Wait: ((number?) -> number?)?,
}?)
	return setmetatable({
		_entries = {},
		_interval = refreshIntervalSeconds,
		_logger = logger or Logger.new("SessionLock", "info"),
		_clock = if runtime and runtime.Clock then runtime.Clock else os.clock,
		_spawn = if runtime and runtime.Spawn then runtime.Spawn else task.spawn,
		_wait = if runtime and runtime.Wait then runtime.Wait else task.wait,
		_running = false,
	}, SessionLockModule)
end

function SessionLockModule:RegisterController(controller: any)
	table.insert(self._entries, controller)
end

function SessionLockModule:Initialize(playersModule: any)
	if self._running then
		return
	end
	self._running = true
	self._spawn(function()
		while self._running do
			for _, controller in self._entries do
				for _, player in playersModule:GetPlayers() do
					if controller:IsLoaded(player) then
						local lastRefresh = controller:GetLastLockRefreshAt(player) or 0
						if self._clock() - lastRefresh >= self._interval then
							local result = controller:RefreshLock(player)
							if not result.Ok then
								self._logger:Warn("lock_refresh_failed", {
									UserId = player.UserId,
									Code = result.Code,
									Error = result.Error,
								})
							end
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
