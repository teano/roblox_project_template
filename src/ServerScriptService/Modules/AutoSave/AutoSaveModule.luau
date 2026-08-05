--!strict

local Logger = require(game:GetService("ReplicatedStorage").Shared.Util.Logger)

local AutoSaveModule = {}
AutoSaveModule.__index = AutoSaveModule

function AutoSaveModule.new(logger: any?, runtime: {
	Clock: (() -> number)?,
	Random: (() -> number)?,
	Spawn: ((() -> ()) -> ())?,
	Wait: ((number?) -> number?)?,
}?)
	return setmetatable({
		_entries = {},
		_entriesByController = {},
		_requests = {},
		_logger = logger or Logger.new("AutoSave", "info"),
		_clock = if runtime and runtime.Clock then runtime.Clock else os.clock,
		_random = if runtime and runtime.Random then runtime.Random else math.random,
		_spawn = if runtime and runtime.Spawn then runtime.Spawn else task.spawn,
		_wait = if runtime and runtime.Wait then runtime.Wait else task.wait,
		_running = false,
	}, AutoSaveModule)
end

function AutoSaveModule:RegisterController(controller: any, config: { IntervalSeconds: number })
	assert(self._entriesByController[controller] == nil, "Autosave controller already registered")
	local entry = {
		Controller = controller,
		IntervalSeconds = config.IntervalSeconds,
		PlayerClosedConnection = nil,
	}
	table.insert(self._entries, entry)
	self._entriesByController[controller] = entry
	local requests = {}
	self._requests[controller] = requests
	if controller.PlayerClosed ~= nil then
		entry.PlayerClosedConnection = controller.PlayerClosed:Connect(function(player)
			local currentRequests = self._requests[controller]
			if currentRequests ~= nil then
				currentRequests[player] = nil
			end
		end)
	end
end

function AutoSaveModule:UnregisterController(controller: any): boolean
	local entry = self._entriesByController[controller]
	if entry == nil then
		return false
	end

	self._entriesByController[controller] = nil
	local requests = self._requests[controller]
	if requests ~= nil then
		for _, state in requests do
			state.Pending = false
			state.Generation += 1
		end
	end
	self._requests[controller] = nil

	if entry.PlayerClosedConnection ~= nil then
		entry.PlayerClosedConnection:Disconnect()
		entry.PlayerClosedConnection = nil
	end
	for index, candidate in self._entries do
		if candidate == entry then
			table.remove(self._entries, index)
			break
		end
	end
	return true
end

function AutoSaveModule:_performRequestedSave(controller: any, player: Player, reason: string, state: any)
	if state.InFlight then
		return { Ok = true, Code = "Joined" }
	end
	state.InFlight = true
	state.Pending = false
	state.LastStartedAt = self._clock()
	local ok, result = xpcall(function()
		return controller:ForceSave(player, reason)
	end, debug.traceback)
	state.InFlight = false
	if not ok then
		return { Ok = false, Code = "SaveFailed", Error = tostring(result) }
	end
	return result
end

function AutoSaveModule:RequestSave(
	controller: any,
	player: Player,
	reason: string,
	minimumIntervalSeconds: number
)
	assert(self._entriesByController[controller] ~= nil, "Autosave controller is not registered")
	assert(typeof(reason) == "string" and reason ~= "", "Save reason required")
	assert(
		typeof(minimumIntervalSeconds) == "number"
			and minimumIntervalSeconds == minimumIntervalSeconds
			and minimumIntervalSeconds >= 0
			and minimumIntervalSeconds < math.huge,
		"Invalid save cooldown"
	)
	local requests = self._requests[controller]
	local state = requests[player]
	if state == nil then
		state = {
			InFlight = false,
			Pending = false,
			Generation = 0,
			LastStartedAt = nil,
		}
		requests[player] = state
	end
	if state.InFlight then
		return { Ok = true, Code = "Joined" }
	end

	local lastSavedAt = controller:GetLastSavedAt(player) or 0
	local lastBoundary = math.max(lastSavedAt, state.LastStartedAt or 0)
	local remaining = minimumIntervalSeconds - (self._clock() - lastBoundary)
	if remaining > 0 then
		if not state.Pending then
			state.Pending = true
			state.Generation += 1
			local generation = state.Generation
			self._spawn(function()
				self._wait(remaining)
				local current = requests[player]
				if self._requests[controller] == requests
					and current == state
					and state.Pending
					and state.Generation == generation
				then
					local result = self:_performRequestedSave(controller, player, reason, state)
					if not result.Ok then
						self._logger:Warn("requested_save_failed", {
							UserId = player.UserId,
							Code = result.Code,
						})
					end
				end
			end)
		end
		return { Ok = true, Code = "Queued" }
	end
	return self:_performRequestedSave(controller, player, reason, state)
end

function AutoSaveModule:Initialize()
	if self._running then
		return
	end
	self._running = true
	self._spawn(function()
		self._wait(self._random() * 5)
		while self._running do
			for _, entry in self._entries do
				local players = entry.Controller:GetDirtyPlayers()
				local slot = if #players > 0 then entry.IntervalSeconds / #players else 1
				for _, player in players do
					if not self._running then
						break
					end
					local lastSavedAt = entry.Controller:GetLastSavedAt(player) or 0
					if self._clock() - lastSavedAt >= entry.IntervalSeconds then
						local result = entry.Controller:ForceSave(player, "Autosave")
						if not result.Ok then
							self._logger:Warn("autosave_failed", {
								UserId = player.UserId,
								Code = result.Code,
								Error = result.Error,
							})
						end
					end
					self._wait(math.max(0.05, slot))
				end
			end
			self._wait(1)
		end
	end)
end

function AutoSaveModule:Stop()
	self._running = false
	local controllers = {}
	for _, entry in self._entries do
		table.insert(controllers, entry.Controller)
	end
	for _, controller in controllers do
		self:UnregisterController(controller)
	end
end

return AutoSaveModule
