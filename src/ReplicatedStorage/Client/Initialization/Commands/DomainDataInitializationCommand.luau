--!strict

local Command = {}
Command.__index = Command

function Command.new(modules: { any })
	return setmetatable({
		Id = "DomainData",
		DependsOn = { "Save", "AudioGraph" },
		_modules = modules,
	}, Command)
end

function Command:Initialize(_context: any)
	for _, module in self._modules do
		module:Initialize()
	end
end

return Command
