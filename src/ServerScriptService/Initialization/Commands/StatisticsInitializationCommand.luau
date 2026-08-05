--!strict

local Command = {}
Command.__index = Command

function Command.new(deps: {
	Statistics: any,
	WalletController: any,
	RequestController: any,
	ClientFactController: any,
})
	return setmetatable({
		Id = "Statistics",
		DependsOn = { "Config", "Teleport", "Communication" },
		_deps = deps,
	}, Command)
end

function Command:Initialize(context: any)
	self._deps.Statistics:Initialize()
	self._deps.WalletController:Initialize()
	self._deps.RequestController:Initialize()
	self._deps.ClientFactController:Initialize()
	context.Services.Statistics = self._deps.Statistics
end

return Command
