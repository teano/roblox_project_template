--!strict

local Command = {}
Command.__index = Command

function Command.new(client: any)
	return setmetatable({
		Id = "Characters",
		DependsOn = { "Players" },
		_client = client,
	}, Command)
end

function Command:Initialize(_context: any)
	self._client:Initialize()
end

return Command
