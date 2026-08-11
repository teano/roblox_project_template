--!strict

local Command = {}
Command.__index = Command

local AUDIO_PRELOAD_REQUEST_ID = "AudioCatalog.Preload.v1"

local function preloadAudioCatalog(contentPreloader: any, contentIds: { string })
	if contentPreloader:GetRequestResult(AUDIO_PRELOAD_REQUEST_ID) ~= nil then
		return
	end

	local carriers: { Sound } = {}
	local ok, preloadError = xpcall(function()
		for _, contentId in contentIds do
			local carrier = Instance.new("Sound")
			table.insert(carriers, carrier)
			carrier.Name = "AudioCatalogPreloadCarrier"
			carrier.SoundId = contentId
			carrier.Playing = false
			carrier.PlayOnRemove = false
		end

		contentPreloader:Preload(carriers, {
			RequestId = AUDIO_PRELOAD_REQUEST_ID,
			FailurePolicy = "Warn",
		})
	end, debug.traceback)

	for _, carrier in carriers do
		carrier:Destroy()
	end

	if not ok then
		error(preloadError, 0)
	end
end

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
		preloadAudioCatalog(self._contentPreloader, audioStartup.Catalog:GetSnapshot().PreloadContentIds)
	end
end

return Command
