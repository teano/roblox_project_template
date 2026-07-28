--!strict

local Command = {}
Command.__index = Command

function Command.new(poolModule: any)
	return setmetatable({
		Id = "Pooling",
		DependsOn = {},
		_module = poolModule,
	}, Command)
end

function Command:Initialize(_context: any)
	self._module:Initialize()
end

return Command
