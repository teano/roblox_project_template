--!strict

local Command = {}
Command.__index = Command

function Command.new(versionModule: any, walletModule: any)
	return setmetatable({
		Id = "DomainData",
		DependsOn = { "Migration" },
		_modules = {
			versionModule,
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
