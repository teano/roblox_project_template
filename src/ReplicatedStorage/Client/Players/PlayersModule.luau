--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Signal = require(ReplicatedStorage.Shared.Util.Signal)

export type DisconnectableConnection = Signal.Connection
export type ClientPlayersServiceBoundary = {
	LocalPlayer: Player?,
}
export type ClientPlayersModule = {
	Initialize: (self: ClientPlayersModule) -> (),
	Stop: (self: ClientPlayersModule) -> (),
	GetLocalPlayer: (self: ClientPlayersModule) -> Player,
}

type State = "fresh" | "initializing" | "active" | "failed" | "stopped"
type Impl = ClientPlayersModule & {
	_players: ClientPlayersServiceBoundary,
	_state: State,
	_localPlayer: Player?,
	_connections: { DisconnectableConnection },
	_characterAdded: Signal.Signal<Model>,
	_characterRemoving: Signal.Signal<Model>,
}

local Module = {}
Module.__index = Module

local function requireActive(self: Impl)
	if self._state ~= "active" then
		local token = if self._state == "fresh" then "PlayersModuleNotInitialized"
			elseif self._state == "initializing" then "PlayersModuleInitializing"
			else "PlayersModuleTerminal"
		error(token, 3)
	end
end

function Module.new(playersService: ClientPlayersServiceBoundary?): ClientPlayersModule
	return setmetatable({
		_players = (playersService or Players) :: any,
		_state = "fresh",
		_localPlayer = nil,
		_connections = {},
		_characterAdded = Signal.new(),
		_characterRemoving = Signal.new(),
	}, Module) :: any
end

local function disconnectAll(connections: { DisconnectableConnection })
	for _, connection in connections do connection:Disconnect() end
	table.clear(connections)
end

function Module:Initialize()
	if self._state == "active" then return end
	if self._state == "initializing" then error("PlayersModuleInitializing", 2) end
	if self._state == "failed" or self._state == "stopped" then error("PlayersModuleTerminal", 2) end
	self._state = "initializing"
	local player = self._players.LocalPlayer
	if player == nil then
		self._state = "failed"
		error("LocalPlayer is not available", 2)
	end
	self._localPlayer = player
	local ok, err = xpcall(function()
		local added = player.CharacterAdded:Connect(function(character)
			if self._state == "active" then self._characterAdded:Fire(character) end
		end)
		if self._state ~= "initializing" then
			added:Disconnect()
			return
		end
		table.insert(self._connections, added)
		local removing = player.CharacterRemoving:Connect(function(character)
			if self._state == "active" then self._characterRemoving:Fire(character) end
		end)
		if self._state ~= "initializing" then
			removing:Disconnect()
			return
		end
		table.insert(self._connections, removing)
	end, debug.traceback)
	if not ok then
		disconnectAll(self._connections)
		if self._state == "initializing" then self._state = "failed" end
		error(err, 0)
	end
	if self._state ~= "initializing" then
		disconnectAll(self._connections)
		error("PlayersModuleTerminal", 2)
	end
	self._state = "active"
end

function Module:GetLocalPlayer(): Player
	requireActive(self)
	return assert(self._localPlayer)
end

-- CharacterClient is the sole caller. This intentionally remains outside the
-- public ClientPlayersModule contract while PlayersModule stays the one
-- platform subscription owner.
function Module:ObserveCharacter(onAdded: (Model) -> (), onRemoving: (Model) -> ()): () -> ()
	requireActive(self)
	assert(typeof(onAdded) == "function" and typeof(onRemoving) == "function", "Character observers required")
	local active = true
	local added = self._characterAdded:Connect(function(character)
		if active then onAdded(character) end
	end)
	local removing = self._characterRemoving:Connect(function(character)
		if active then onRemoving(character) end
	end)
	local current = assert(self._localPlayer).Character
	if current ~= nil then onAdded(current) end
	return function()
		if not active then return end
		active = false
		added:Disconnect()
		removing:Disconnect()
	end
end

function Module:Stop()
	if self._state == "stopped" or self._state == "failed" then return end
	self._state = "stopped"
	disconnectAll(self._connections)
	self._localPlayer = nil
	self._characterAdded:Destroy()
	self._characterRemoving:Destroy()
end

return Module
