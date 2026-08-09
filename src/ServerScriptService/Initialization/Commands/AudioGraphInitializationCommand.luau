--!strict

local Command = {}
Command.__index = Command

function Command.new(graph: any)
	return setmetatable({ Id = "AudioGraph", DependsOn = { "AudioStartup", "Players" }, _graph = graph }, Command)
end

function Command:Initialize(context: any)
	context.Services.AudioGraph = self._graph:Initialize(context.Services.AudioStartup)
end

return Command
