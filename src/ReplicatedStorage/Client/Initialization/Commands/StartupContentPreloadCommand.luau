--!strict

local Command = {}
Command.__index = Command

function Command.new(contentPreloader: any)
	return setmetatable({
		Id = "StartupContentPreload",
		DependsOn = { "AudioStartup" },
		_contentPreloader = contentPreloader,
	}, Command)
end

function Command:Initialize(context: any)
	self._contentPreloader:PreloadQuery({
		Tags = { "Preload" },
	}, {
		RequestId = "Startup",
		FailurePolicy = "Warn",
	})
	local audioStartup = context.Services.AudioStartup
	if audioStartup.Enabled then
		self._contentPreloader:Preload(audioStartup.Catalog:GetSnapshot().PreloadContentIds, {
			RequestId = "AudioCatalog.Preload.v1",
			FailurePolicy = "Warn",
		})
	end
end

return Command
