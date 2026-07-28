--!strict

local Command = {}
Command.__index = Command

function Command.new(playersModule: any)
	return setmetatable({
		Id = "Players",
		DependsOn = {},
		_module = playersModule,
	}, Command)
end

function Command:Initialize(_context: any)
	self._module:Initialize()
end

return Command
