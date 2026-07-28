--!strict

local Command = {}
Command.__index = Command

function Command.new(communication: any)
	return setmetatable({
		Id = "Communication",
		DependsOn = { "Players" },
		_module = communication,
	}, Command)
end

function Command:Initialize(_context: any)
	self._module:Initialize()
end

return Command
