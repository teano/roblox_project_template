--!strict

local Command = {}
Command.__index = Command

function Command.new(statistics: any)
	return setmetatable({
		Id = "Statistics",
		DependsOn = { "Communication" },
		_statistics = statistics,
	}, Command)
end

function Command:Initialize(context: any)
	self._statistics:Initialize()
	context.Services.Statistics = self._statistics
end

return Command
