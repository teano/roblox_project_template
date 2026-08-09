--!strict

local Command = {}
Command.__index = Command

function Command.new(service: any, hybrid: any)
	return setmetatable({ Id = "OrdinarySound", DependsOn = { "AudioStartup", "Pooling", "Communication", "AudioGraph" }, _service = service, _hybrid = hybrid }, Command)
end

function Command:Initialize(context: any)
	self._service:Initialize(context.Services.AudioStartup, context.Services.AudioGraph)
	self._hybrid:Register(context.Services.AudioStartup)
end

return Command
