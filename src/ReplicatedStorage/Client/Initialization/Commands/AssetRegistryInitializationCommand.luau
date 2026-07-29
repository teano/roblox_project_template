--!strict

local Command = {}
Command.__index = Command

function Command.new(assetRegistry: any)
	return setmetatable({
		Id = "Assets",
		DependsOn = {},
		_registry = assetRegistry,
	}, Command)
end

function Command:Initialize(_context: any)
	self._registry:Initialize()
end

return Command
