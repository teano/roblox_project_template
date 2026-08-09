--!strict

local Command = {}
Command.__index = Command

function Command.new(service: any)
	return setmetatable({ Id = "Music", DependsOn = { "AudioStartup", "Pooling", "AudioGraph" }, _service = service }, Command)
end

function Command:Initialize(context: any)
	self._service:Initialize(context.Services.AudioStartup, context.Services.AudioGraph)
end

return Command
