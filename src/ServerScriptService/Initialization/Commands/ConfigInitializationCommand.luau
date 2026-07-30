--!strict

local Command = {}
Command.__index = Command

function Command.new(configCatalog: any)
	return setmetatable({
		Id = "Config",
		DependsOn = { "Communication" },
		_catalog = configCatalog,
	}, Command)
end

function Command:Initialize(_context: any)
	self._catalog:Initialize()
end

return Command
