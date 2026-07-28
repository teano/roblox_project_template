--!strict

local Command = {}
Command.__index = Command

function Command.new(module: any)
	return setmetatable({
		Id = "Communication",
		DependsOn = { "Players" },
		_module = module,
	}, Command)
end

function Command:Initialize(_context: any)
	self._module:Initialize()
end

return Command
