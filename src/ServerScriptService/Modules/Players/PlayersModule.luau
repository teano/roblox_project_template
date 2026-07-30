--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Signal = require(ReplicatedStorage.Shared.Util.Signal)

export type PlayersModule = {
	Initialize: (self: PlayersModule) -> (),
	Stop: (self: PlayersModule) -> (),
	GetPlayers: (self: PlayersModule) -> { Player },
	GetPlayerByUserId: (self: PlayersModule, userId: number) -> Player?,
	GetPlayerFromCharacter: (self: PlayersModule, character: Model) -> Player?,
	ObservePlayers: (
		self: PlayersModule,
		onAdded: (Player) -> (),
		onRemoving: ((Player) -> ())?
	) -> () -> (),
	PlayerAdded: any,
	PlayerRemoving: any,
	CharacterAdded: any,
	CharacterRemoving: any,
}

local PlayersModule = {}
PlayersModule.__index = PlayersModule

function PlayersModule.new(): PlayersModule
	local self = setmetatable({
		_initialized = false,
		_connections = {} :: { RBXScriptConnection },
		_characterConnections = {} :: { [Player]: { RBXScriptConnection } },
		PlayerAdded = Signal.new(),
		PlayerRemoving = Signal.new(),
		CharacterAdded = Signal.new(),
		CharacterRemoving = Signal.new(),
	}, PlayersModule)
	return self :: any
end

function PlayersModule:_disconnectCharacter(player: Player)
	local connections = self._characterConnections[player]
	if connections == nil then
		return
	end
	for _, connection in connections do
		connection:Disconnect()
	end
	self._characterConnections[player] = nil
end

function PlayersModule:_trackPlayer(player: Player)
	if self:GetPlayerByUserId(player.UserId) ~= player then
		return
	end
	if self._characterConnections[player] ~= nil then
		return
	end

	self._characterConnections[player] = {
		player.CharacterAdded:Connect(function(character)
			self.CharacterAdded:Fire(player, character)
		end),
		player.CharacterRemoving:Connect(function(character)
			self.CharacterRemoving:Fire(player, character)
		end),
	}

	self.PlayerAdded:Fire(player)
	if player.Character then
		self.CharacterAdded:Fire(player, player.Character)
	end
end

function PlayersModule:Initialize()
	if self._initialized then
		return
	end
	self._initialized = true

	table.insert(self._connections, Players.PlayerAdded:Connect(function(player)
		self:_trackPlayer(player)
	end))
	table.insert(self._connections, Players.PlayerRemoving:Connect(function(player)
		if player.Character then
			self.CharacterRemoving:Fire(player, player.Character)
		end
		self.PlayerRemoving:Fire(player)
		self:_disconnectCharacter(player)
	end))

	for _, player in Players:GetPlayers() do
		self:_trackPlayer(player)
	end
end

function PlayersModule:GetPlayers(): { Player }
	return Players:GetPlayers()
end

function PlayersModule:GetPlayerByUserId(userId: number): Player?
	return Players:GetPlayerByUserId(userId)
end

function PlayersModule:GetPlayerFromCharacter(character: Model): Player?
	return Players:GetPlayerFromCharacter(character)
end

function PlayersModule:ObservePlayers(onAdded: (Player) -> (), onRemoving: ((Player) -> ())?): () -> ()
	assert(typeof(onAdded) == "function", "onAdded required")

	local active = true
	local observed: { [Player]: boolean } = {}

	local function emitAdded(player: Player)
		if not active
			or observed[player]
			or self:GetPlayerByUserId(player.UserId) ~= player
		then
			return
		end
		observed[player] = true
		onAdded(player)
	end

	local function emitRemoving(player: Player)
		if not active or not observed[player] then
			return
		end
		observed[player] = nil
		if onRemoving then
			onRemoving(player)
		end
	end

	local addedConnection = self.PlayerAdded:Connect(emitAdded)
	local removingConnection = self.PlayerRemoving:Connect(emitRemoving)

	for _, player in self:GetPlayers() do
		emitAdded(player)
	end

	return function()
		if not active then
			return
		end
		active = false
		addedConnection:Disconnect()
		removingConnection:Disconnect()
		table.clear(observed)
	end
end

function PlayersModule:Stop()
	for _, connection in self._connections do
		connection:Disconnect()
	end
	table.clear(self._connections)

	for player in self._characterConnections do
		self:_disconnectCharacter(player)
	end

	self._initialized = false
end

return PlayersModule
