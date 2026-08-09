--!strict

local Logger = require(game:GetService("ReplicatedStorage").Shared.Util.Logger)

local ShutdownSaveCoordinator = {}
ShutdownSaveCoordinator.__index = ShutdownSaveCoordinator

local MAX_CLEANUP_RETRY_ATTEMPTS = 3

local function invalidResult(errorMessage: string): any
	return {
		Ok = false,
		Code = "CloseFailed",
		Error = errorMessage,
	}
end

local function normalizeTarget(target: any): (Player, any?)
	if typeof(target) == "table" and target.Player ~= nil then
		return target.Player, target.Runtime
	end
	return target, nil
end

function ShutdownSaveCoordinator.new(config: {
	BudgetSeconds: number,
	MaxConcurrency: number,
}, logger: any?, runtime: {
	Clock: (() -> number)?,
	Spawn: ((() -> ()) -> ())?,
	Wait: ((number?) -> number?)?,
}?)
	assert(config.BudgetSeconds > 0, "Shutdown budget must be positive")
	assert(config.MaxConcurrency >= 1, "Shutdown concurrency must be at least one")
	return setmetatable({
		_budgetSeconds = config.BudgetSeconds,
		_maxConcurrency = math.floor(config.MaxConcurrency),
		_logger = logger or Logger.new("Save.Shutdown", "info"),
		_clock = if runtime and runtime.Clock then runtime.Clock else os.clock,
		_spawn = if runtime and runtime.Spawn then runtime.Spawn else task.spawn,
		_wait = if runtime and runtime.Wait then runtime.Wait else task.wait,
	}, ShutdownSaveCoordinator)
end

function ShutdownSaveCoordinator:ClosePlayers(controller: any, targets: { any })
	local deadline = self._clock() + self._budgetSeconds
	local nextIndex = 1
	local completed = 0
	local results = {}
	local workerCount = math.min(#targets, self._maxConcurrency)

	local function callClose(player: Player, expectedRuntime: any?, options: any): any
		local callOk, resultOrError = xpcall(function()
			if expectedRuntime ~= nil and controller:IsRetainedCloseOwner(player, expectedRuntime) then
				return controller:RetryClose(player, expectedRuntime, options)
			end
			return controller:Close(player, true, options, expectedRuntime)
		end, debug.traceback)
		if not callOk then
			return invalidResult(tostring(resultOrError))
		end
		if typeof(resultOrError) ~= "table" or typeof(resultOrError.Ok) ~= "boolean" then
			return invalidResult("Save controller Close returned an invalid result")
		end
		return resultOrError
	end

	local function closeTarget(target: any): (Player, any)
		local player, expectedRuntime = normalizeTarget(target)
		if self._clock() >= deadline then
			return player, {
				Ok = false,
				Code = "DeadlineExceeded",
				Error = "Shutdown budget exhausted before close started",
			}
		end

		local options = { Deadline = deadline }
		local result = callClose(player, expectedRuntime, options)
		local attempts = 0
		while not result.Ok
			and self._clock() < deadline
			and expectedRuntime ~= nil
			and controller:IsRetainedCloseOwner(player, expectedRuntime)
			and attempts < MAX_CLEANUP_RETRY_ATTEMPTS
		do
			attempts += 1
			local retryOk, retryOrError = xpcall(function()
				return controller:RetryClose(player, expectedRuntime, options)
			end, debug.traceback)
			if not retryOk then
				result = invalidResult(tostring(retryOrError))
			elseif typeof(retryOrError) ~= "table" or typeof(retryOrError.Ok) ~= "boolean" then
				result = invalidResult("Save controller RetryClose returned an invalid result")
			else
				result = retryOrError
			end
		end

		if not result.Ok
			and result.Code == "ClosePreparationFailed"
			and self._clock() < deadline
			and expectedRuntime ~= nil
			and controller:IsRetainedCloseOwner(player, expectedRuntime)
		then
			local finalOk, finalOrError = xpcall(function()
				return controller:FinalizeRetainedClose(player, expectedRuntime, options)
			end, debug.traceback)
			if not finalOk then
				result = invalidResult(tostring(finalOrError))
			elseif typeof(finalOrError) ~= "table" or typeof(finalOrError.Ok) ~= "boolean" then
				result = invalidResult("Save controller finalization returned an invalid result")
			else
				result = finalOrError
			end
		end
		return player, result
	end

	local function worker()
		while true do
			local index = nextIndex
			nextIndex += 1
			local target = targets[index]
			if target == nil then
				return
			end
			local player, result = closeTarget(target)
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
		self._spawn(worker)
	end

	while completed < #targets and self._clock() < deadline do
		self._wait()
	end

	local resultSnapshot = table.clone(results)
	local completedSnapshot = completed
	local succeeded = 0
	for _, result in resultSnapshot do
		if result.Ok then
			succeeded += 1
		end
	end
	return {
		Deadline = deadline,
		Completed = completedSnapshot,
		Succeeded = succeeded,
		Failed = completedSnapshot - succeeded,
		Unfinished = #targets - completedSnapshot,
		TimedOut = completedSnapshot < #targets,
		Results = resultSnapshot,
	}
end

return ShutdownSaveCoordinator
