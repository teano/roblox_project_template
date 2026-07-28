--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Signal = require(ReplicatedStorage.Shared.Util.Signal)

local PlayersModule = {}
PlayersModule.__index = PlayersModule

function PlayersModule.new()
	return setmetatable({
		_initialized = false,
		_connections = {},
		LocalPlayer = nil :: Player?,
		CharacterAdded = Signal.new(),
		CharacterRemoving = Signal.new(),
	}, PlayersModule)
end

function PlayersModule:Initialize()
	if self._initialized then
		return
	end
	self._initialized = true

	local player = Players.LocalPlayer
	assert(player ~= nil, "LocalPlayer is not available")
	self.LocalPlayer = player
	table.insert(self._connections, player.CharacterAdded:Connect(function(character)
		self.CharacterAdded:Fire(character)
	end))
	table.insert(self._connections, player.CharacterRemoving:Connect(function(character)
		self.CharacterRemoving:Fire(character)
	end))
	if player.Character then
		self.CharacterAdded:Fire(player.Character)
	end
end

function PlayersModule:GetLocalPlayer(): Player
	return assert(self.LocalPlayer, "PlayersModule is not initialized")
end

function PlayersModule:GetCharacter(): Model?
	local player = self.LocalPlayer
	return if player then player.Character else nil
end

function PlayersModule:WaitForCharacter(): Model
	local character = self:GetCharacter()
	if character then
		return character
	end
	return self.CharacterAdded:Wait()
end

function PlayersModule:Stop()
	for _, connection in self._connections do
		connection:Disconnect()
	end
	table.clear(self._connections)
	self.LocalPlayer = nil
	self._initialized = false
end

return PlayersModule
