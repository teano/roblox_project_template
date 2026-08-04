--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Signal = require(ReplicatedStorage.Shared.Util.Signal)

export type DisconnectableConnection = Signal.Connection

export type ConnectEvent<T...> = {
	Connect: (self: ConnectEvent<T...>, callback: (T...) -> ()) -> DisconnectableConnection,
}

export type PlayersLifecycleSignal<T...> = {
	Connect: (self: PlayersLifecycleSignal<T...>, callback: (T...) -> ()) -> DisconnectableConnection,
	Once: (self: PlayersLifecycleSignal<T...>, callback: (T...) -> ()) -> DisconnectableConnection,
}

export type ClientPlayersServiceBoundary = {
	LocalPlayer: Player?,
}

export type ClientPlayersModule = {
	Initialize: (self: ClientPlayersModule) -> (),
	Stop: (self: ClientPlayersModule) -> (),
	GetLocalPlayer: (self: ClientPlayersModule) -> Player,
	GetCharacter: (self: ClientPlayersModule) -> Model?,
	WaitForCharacter: (self: ClientPlayersModule) -> Model,
	CharacterAdded: PlayersLifecycleSignal<Model>,
	CharacterRemoving: PlayersLifecycleSignal<Model>,
}

type LifecycleState = "fresh" | "initializing" | "active" | "failed" | "stopped"

type ClientPlayersModuleImpl = ClientPlayersModule & {
	_players: ClientPlayersServiceBoundary,
	_state: LifecycleState,
	_connections: { DisconnectableConnection },
	_localPlayer: Player?,
	_character: Model?,
	_waiters: { [thread]: boolean },
	_signalsDestroyed: boolean,
	_characterAddedSignal: Signal.Signal<Model>,
	_characterRemovingSignal: Signal.Signal<Model>,
}

local PlayersModule = {}
PlayersModule.__index = PlayersModule

local function lifecycleError(state: LifecycleState): string
	if state == "fresh" then
		return "PlayersModuleNotInitialized"
	elseif state == "initializing" then
		return "PlayersModuleInitializing"
	end
	return "PlayersModuleTerminal"
end

local function requireActive(self: ClientPlayersModuleImpl)
	if self._state ~= "active" then
		error(lifecycleError(self._state), 3)
	end
end

local function makeLifecycleSignal<T...>(
	requireConnection: () -> (),
	isActive: () -> boolean
): (PlayersLifecycleSignal<T...>, Signal.Signal<T...>)
	local backing: Signal.Signal<T...> = Signal.new()
	local surface: PlayersLifecycleSignal<T...> = {
		Connect = function(_self, callback)
			requireConnection()
			return backing:Connect(function(...: T...)
				if isActive() then
					callback(...)
				end
			end)
		end,
		Once = function(_self, callback)
			requireConnection()
			return backing:Once(function(...: T...)
				if isActive() then
					callback(...)
				end
			end)
		end,
	}
	return surface, backing
end

function PlayersModule.new(playersService: ClientPlayersServiceBoundary?): ClientPlayersModule
	local PlayersServiceBoundaryCast = (playersService or Players) :: any
	local players: ClientPlayersServiceBoundary = PlayersServiceBoundaryCast
	local self: ClientPlayersModuleImpl
	local characterAdded: PlayersLifecycleSignal<Model>, characterAddedSignal: Signal.Signal<Model> = makeLifecycleSignal(function()
		requireActive(self)
	end, function()
		return self._state == "active"
	end)
	local characterRemoving: PlayersLifecycleSignal<Model>, characterRemovingSignal: Signal.Signal<Model> = makeLifecycleSignal(function()
		requireActive(self)
	end, function()
		return self._state == "active"
	end)

	self = setmetatable({
		_players = players,
		_state = "fresh",
		_connections = {},
		_localPlayer = nil,
		_character = nil,
		_waiters = {},
		_signalsDestroyed = false,
		CharacterAdded = characterAdded,
		CharacterRemoving = characterRemoving,
		_characterAddedSignal = characterAddedSignal,
		_characterRemovingSignal = characterRemovingSignal,
	}, PlayersModule) :: ClientPlayersModuleImpl
	return self
end

local function disconnectConnections(connections: { DisconnectableConnection })
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)
end

function PlayersModule._finishWaiters(self: ClientPlayersModuleImpl, success: boolean, value: Model | string)
	local waiters = {}
	for thread in self._waiters do
		table.insert(waiters, thread)
	end
	table.clear(self._waiters)
	for _, thread in waiters do
		task.spawn(thread, success, value)
	end
end

function PlayersModule._destroySignals(self: ClientPlayersModuleImpl)
	if self._signalsDestroyed then
		return
	end
	self._signalsDestroyed = true
	self._characterAddedSignal:Destroy()
	self._characterRemovingSignal:Destroy()
end

function PlayersModule._cleanup(self: ClientPlayersModuleImpl)
	disconnectConnections(self._connections)
	self:_finishWaiters(false, "PlayersModuleTerminal")
	self._localPlayer = nil
	self._character = nil
	self:_destroySignals()
end

function PlayersModule._assertAcquiring(self: ClientPlayersModuleImpl, connection: DisconnectableConnection?)
	if self._state == "initializing" then
		return
	end
	if connection then
		connection:Disconnect()
	end
	error("PlayersModuleTerminal", 3)
end

function PlayersModule._emitCharacterAdded(self: ClientPlayersModuleImpl, character: Model)
	if self._character == character then
		return
	end
	self._character = character
	self:_finishWaiters(true, character)
	self._characterAddedSignal:Fire(character)
end

function PlayersModule._emitCharacterRemoving(self: ClientPlayersModuleImpl, character: Model)
	if self._character ~= character then
		return
	end
	self._character = nil
	self._characterRemovingSignal:Fire(character)
end

function PlayersModule.Initialize(self: ClientPlayersModuleImpl)
	if self._state == "active" then
		return
	elseif self._state == "initializing" then
		error("PlayersModuleInitializing", 2)
	elseif self._state == "failed" or self._state == "stopped" then
		error("PlayersModuleTerminal", 2)
	end

	self._state = "initializing"
	local ok, initializationError = xpcall(function()
		local player = self._players.LocalPlayer
		assert(player ~= nil, "LocalPlayer is not available")
		self._localPlayer = player

		local addedConnection = player.CharacterAdded:Connect(function(character)
			if self._state == "initializing" or self._state == "active" then
				self:_emitCharacterAdded(character)
			end
		end)
		self:_assertAcquiring(addedConnection)
		table.insert(self._connections, addedConnection)

		local removingConnection = player.CharacterRemoving:Connect(function(character)
			if self._state == "initializing" or self._state == "active" then
				self:_emitCharacterRemoving(character)
			end
		end)
		self:_assertAcquiring(removingConnection)
		table.insert(self._connections, removingConnection)

		local currentCharacter = player.Character
		if currentCharacter then
			self:_emitCharacterAdded(currentCharacter)
		end
	end, debug.traceback)
	if not ok then
		local stopped = self._state == "stopped"
		self:_cleanup()
		self._state = if stopped then "stopped" else "failed"
		error(initializationError, 0)
	end
	if self._state ~= "initializing" then
		self:_cleanup()
		error("PlayersModuleTerminal", 2)
	end
	self._state = "active"
end

function PlayersModule.GetLocalPlayer(self: ClientPlayersModuleImpl): Player
	requireActive(self)
	return assert(self._localPlayer)
end

function PlayersModule.GetCharacter(self: ClientPlayersModuleImpl): Model?
	requireActive(self)
	return self._character
end

function PlayersModule.WaitForCharacter(self: ClientPlayersModuleImpl): Model
	requireActive(self)
	local character = self:GetCharacter()
	if character then
		return character
	end
	local thread = coroutine.running()
	self._waiters[thread] = true
	local success, value = coroutine.yield()
	if not success then
		error(value, 2)
	end
	return value :: Model
end

function PlayersModule.Stop(self: ClientPlayersModuleImpl)
	if self._state == "stopped" or self._state == "failed" then
		self:_cleanup()
		return
	end
	self._state = "stopped"
	self:_cleanup()
end

return PlayersModule
