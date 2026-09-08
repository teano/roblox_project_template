--!strict

local Command = {}
Command.__index = Command

function Command.new(module: any, slots: any, bindToClose: any)
	return setmetatable({ Id = "AdmissionRouting", DependsOn = { "PlayerSlots", "Teleport" },
		_module = module, _slots = slots, _bindToClose = bindToClose }, Command)
end

function Command:Initialize(_context: any)
	local ids = {}
	local enabled = self._slots:GetStrategy() == "Enabled"
	if enabled then
		for _, slot in self._slots:GetSlots() do table.insert(ids, slot.SlotId) end
	end
	self._module:Initialize(enabled, ids)
	self._bindToClose(function() self._module:Stop() end)
end

return Command
