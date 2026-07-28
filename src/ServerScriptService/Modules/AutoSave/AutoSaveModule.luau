--!strict

local Logger = require(game:GetService("ReplicatedStorage").Shared.Util.Logger)

local AutoSaveModule = {}
AutoSaveModule.__index = AutoSaveModule

function AutoSaveModule.new(logger: any?)
	return setmetatable({
		_entries = {},
		_logger = logger or Logger.new("AutoSave", "info"),
		_running = false,
	}, AutoSaveModule)
end

function AutoSaveModule:RegisterController(controller: any, config: { IntervalSeconds: number })
	table.insert(self._entries, {
		Controller = controller,
		IntervalSeconds = config.IntervalSeconds,
	})
end

function AutoSaveModule:Initialize()
	if self._running then
		return
	end
	self._running = true
	task.spawn(function()
		task.wait(math.random() * 5)
		while self._running do
			for _, entry in self._entries do
				local players = entry.Controller:GetDirtyPlayers()
				local slot = if #players > 0 then entry.IntervalSeconds / #players else 1
				for _, player in players do
					if not self._running then
						break
					end
					local lastSavedAt = entry.Controller:GetLastSavedAt(player) or 0
					if os.clock() - lastSavedAt >= entry.IntervalSeconds then
						local result = entry.Controller:ForceSave(player, "Autosave")
						if not result.Ok then
							self._logger:Warn("autosave_failed", {
								UserId = player.UserId,
								Code = result.Code,
								Error = result.Error,
							})
						end
					end
					task.wait(math.max(0.05, slot))
				end
			end
			task.wait(1)
		end
	end)
end

function AutoSaveModule:Stop()
	self._running = false
end

return AutoSaveModule
