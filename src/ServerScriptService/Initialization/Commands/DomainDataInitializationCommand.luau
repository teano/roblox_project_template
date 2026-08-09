--!strict

local Command = {}
Command.__index = Command

function Command.new(versionModule: any, walletModule: any, audioSettingsModule: any?)
	return setmetatable({
		Id = "DomainData",
		DependsOn = { "Migration", "AudioStartup" },
		_modules = {
			audioSettingsModule,
			versionModule,
			walletModule,
		},
	}, Command)
end

function Command:Initialize(context: any)
	for index, module in self._modules do
		if module ~= nil then
			if index == 1 then module:Initialize(context.Services.AudioStartup) else module:Initialize() end
		end
	end
end

return Command
