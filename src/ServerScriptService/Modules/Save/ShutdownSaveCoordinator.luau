--!strict

local Logger = require(game:GetService("ReplicatedStorage").Shared.Util.Logger)

local ShutdownSaveCoordinator = {}
ShutdownSaveCoordinator.__index = ShutdownSaveCoordinator

function ShutdownSaveCoordinator.new(config: {
	BudgetSeconds: number,
	MaxConcurrency: number,
}, logger: any?)
	assert(config.BudgetSeconds > 0, "Shutdown budget must be positive")
	assert(config.MaxConcurrency >= 1, "Shutdown concurrency must be at least one")
	return setmetatable({
		_budgetSeconds = config.BudgetSeconds,
		_maxConcurrency = math.floor(config.MaxConcurrency),
		_logger = logger or Logger.new("Save.Shutdown", "info"),
	}, ShutdownSaveCoordinator)
end

function ShutdownSaveCoordinator:ClosePlayers(controller: any, players: { Player })
	local deadline = os.clock() + self._budgetSeconds
	local nextIndex = 1
	local completed = 0
	local results = {}
	local workerCount = math.min(#players, self._maxConcurrency)

	local function worker()
		while true do
			local index = nextIndex
			nextIndex += 1
			local player = players[index]
			if player == nil then
				return
			end
			if os.clock() >= deadline then
				results[player] = {
					Ok = false,
					Code = "DeadlineExceeded",
					Error = "Shutdown budget exhausted before save started",
				}
				completed += 1
				continue
			end

			local ok, resultOrError = xpcall(function()
				return controller:Close(player, true, {
					Deadline = deadline,
				})
			end, debug.traceback)
			local result = if ok
				then resultOrError
				else {
					Ok = false,
					Code = "CloseFailed",
					Error = tostring(resultOrError),
				}
			results[player] = result
			if not result.Ok then
				self._logger:Warn("shutdown_player_save_failed", {
					UserId = player.UserId,
					Code = result.Code,
					Error = result.Error,
				})
			end
			completed += 1
		end
	end

	for _ = 1, workerCount do
		task.spawn(worker)
	end

	while completed < #players and os.clock() < deadline do
		task.wait()
	end

	local succeeded = 0
	for _, result in results do
		if result.Ok then
			succeeded += 1
		end
	end
	return {
		Deadline = deadline,
		Completed = completed,
		Succeeded = succeeded,
		Failed = completed - succeeded,
		Unfinished = #players - completed,
		TimedOut = completed < #players,
		Results = results,
	}
end

return ShutdownSaveCoordinator
