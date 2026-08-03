--!strict

local Command = {}
Command.__index = Command

function Command.new(module: any)
	return setmetatable({
		Id = "Teleport",
		DependsOn = { "Players", "Communication" },
		_module = module,
	}, Command)
end

function Command:Initialize(_context: any)
	self._module:Initialize()
end

return Command
