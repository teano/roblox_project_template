--!strict

local Command = {}
Command.__index = Command

function Command.new(contentPreloader: any)
	return setmetatable({
		Id = "StartupContentPreload",
		DependsOn = { "Assets" },
		_contentPreloader = contentPreloader,
	}, Command)
end

function Command:Initialize(_context: any)
	self._contentPreloader:PreloadQuery({
		Tags = { "Preload" },
	}, {
		RequestId = "Startup",
		FailurePolicy = "Warn",
	})
end

return Command
