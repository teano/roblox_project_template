--!strict

local Command = {}
Command.__index = Command

function Command.new(migrationModule: any)
	return setmetatable({
		Id = "Migration",
		DependsOn = { "Save" },
		_module = migrationModule,
	}, Command)
end

function Command:Initialize(_context: any)
	self._module:Initialize()
end

return Command
