--!strict

local Command = {}
Command.__index = Command

function Command.new(versionModule: any, migrationModule: any, walletModule: any)
	return setmetatable({
		Id = "DomainData",
		DependsOn = { "Save" },
		_modules = {
			versionModule,
			migrationModule,
			walletModule,
		},
	}, Command)
end

function Command:Initialize(_context: any)
	for _, module in self._modules do
		module:Initialize()
	end
end

return Command
