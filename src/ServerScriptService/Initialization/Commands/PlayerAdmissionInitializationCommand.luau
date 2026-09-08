--!strict

local Command = {}
Command.__index = Command

function Command.new(module: any)
	return setmetatable({
		Id = "PlayerAdmission",
		DependsOn = { "GlobalSave", "Characters", "PlayerSlots" },
		_module = module,
	}, Command)
end

function Command:Initialize(context: any)
	self._module:Initialize(assert(context.Services.GlobalSaveController, "GlobalSaveController required"))
end

return Command
