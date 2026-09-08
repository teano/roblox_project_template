--!strict

local Command = {}
Command.__index = Command

function Command.new(controller: any)
	return setmetatable({
		Id = "FriendInvitationsUI",
		DependsOn = { "UI", "GlobalSave" },
		_controller = controller,
	}, Command)
end

function Command:Initialize(context: any)
	self._controller:Initialize()
	context.Services.FriendInvitationsUI = self._controller
end

return Command
