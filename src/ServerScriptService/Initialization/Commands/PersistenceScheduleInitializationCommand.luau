--!strict

local Command = {}
Command.__index = Command

function Command.new(autoSaveModule: any, sessionLockModule: any, playersModule: any)
	return setmetatable({
		Id = "PersistenceSchedule",
		DependsOn = { "GlobalSave" },
		_autoSave = autoSaveModule,
		_sessionLock = sessionLockModule,
		_players = playersModule,
	}, Command)
end

function Command:Initialize(_context: any)
	self._autoSave:Initialize()
	self._sessionLock:Initialize(self._players)
end

return Command
