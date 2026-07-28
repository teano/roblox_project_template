--!strict

local Command = {}
Command.__index = Command

function Command.new(saveModule: any)
	return setmetatable({
		Id = "Save",
		DependsOn = { "Communication" },
		_module = saveModule,
	}, Command)
end

function Command:Initialize(_context: any)
	self._module:Initialize()
end

return Command
