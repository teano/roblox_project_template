--!strict

local Command = {}
Command.__index = Command

function Command.new(uiSystem: any)
	return setmetatable({
		Id = "UI",
		DependsOn = { "StartupContentPreload", "Pooling", "Players" },
		_uiSystem = uiSystem,
	}, Command)
end

function Command:Initialize(_context: any)
	local result = self._uiSystem:Initialize()
	if result.Kind == "Error" then
		error(`UiInitializationFailed:{result.Error.Code}`, 0)
	end
end

return Command
