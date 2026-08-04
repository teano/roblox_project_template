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

export type ServerPlayersServiceBoundary = {
	PlayerAdded: ConnectEvent<Player>,
	PlayerRemoving: ConnectEvent<Player>,
	GetPlayers: (self: ServerPlayersServiceBoundary) -> { Player },
	GetPlayerByUserId: (self: ServerPlayersServiceBoundary, userId: number) -> Player?,
	GetPlayerFromCharacter: (self: ServerPlayersServiceBoundary, character: Model) -> Player?,
}

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
	PlayerAdded: PlayersLifecycleSignal<Player>,
	PlayerRemoving: PlayersLifecycleSignal<Player>,
	CharacterAdded: PlayersLifecycleSignal<Player, Model>,
	CharacterRemoving: PlayersLifecycleSignal<Player, Model>,
}

type LifecycleState = "fresh" | "initializing" | "active" | "failed" | "stopped"

type TrackedPlayer = {
	Character: Model?,
	Connections: { DisconnectableConnection },
}

type ObserverRecord = {
	Active: boolean,
	Observed: { [Player]: boolean },
	OnAdded: ((Player) -> ())?,
	OnRemoving: ((Player) -> ())?,
	AddedConnection: DisconnectableConnection?,
	RemovingConnection: DisconnectableConnection?,
}

type PlayersModuleImpl = PlayersModule & {
	_players: ServerPlayersServiceBoundary,
	_state: LifecycleState,
	_connections: { DisconnectableConnection },
	_trackedPlayers: { [Player]: TrackedPlayer },
	_observers: { [ObserverRecord]: boolean },
	_signalsDestroyed: boolean,
	_playerAddedSignal: Signal.Signal<Player>,
	_playerRemovingSignal: Signal.Signal<Player>,
	_characterAddedSignal: Signal.Signal<Player, Model>,
	_characterRemovingSignal: Signal.Signal<Player, Model>,
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

local function requireActive(self: PlayersModuleImpl)
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

function PlayersModule.new(playersService: ServerPlayersServiceBoundary?): PlayersModule
	local PlayersServiceBoundaryCast = (playersService or Players) :: any
	local players: ServerPlayersServiceBoundary = PlayersServiceBoundaryCast
	local self: PlayersModuleImpl
	local playerAdded: PlayersLifecycleSignal<Player>, playerAddedSignal: Signal.Signal<Player> = makeLifecycleSignal(function()
		requireActive(self)
	end, function()
		return self._state == "active"
	end)
	local playerRemoving: PlayersLifecycleSignal<Player>, playerRemovingSignal: Signal.Signal<Player> = makeLifecycleSignal(function()
		requireActive(self)
	end, function()
		return self._state == "active"
	end)
	local characterAdded: PlayersLifecycleSignal<Player, Model>, characterAddedSignal: Signal.Signal<Player, Model> = makeLifecycleSignal(function()
		requireActive(self)
	end, function()
		return self._state == "active"
	end)
	local characterRemoving: PlayersLifecycleSignal<Player, Model>, characterRemovingSignal: Signal.Signal<Player, Model> = makeLifecycleSignal(function()
		requireActive(self)
	end, function()
		return self._state == "active"
	end)

	self = setmetatable({
		_players = players,
		_state = "fresh",
		_connections = {},
		_trackedPlayers = {},
		_observers = {},
		_signalsDestroyed = false,
		PlayerAdded = playerAdded,
		PlayerRemoving = playerRemoving,
		CharacterAdded = characterAdded,
		CharacterRemoving = characterRemoving,
		_playerAddedSignal = playerAddedSignal,
		_playerRemovingSignal = playerRemovingSignal,
		_characterAddedSignal = characterAddedSignal,
		_characterRemovingSignal = characterRemovingSignal,
	}, PlayersModule) :: PlayersModuleImpl
	return self
end

local function disconnectConnections(connections: { DisconnectableConnection })
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)
end

function PlayersModule._disconnectTrackedPlayer(self: PlayersModuleImpl, player: Player)
	local tracked = self._trackedPlayers[player]
	if tracked == nil then
		return
	end
	self._trackedPlayers[player] = nil
	tracked.Character = nil
	disconnectConnections(tracked.Connections)
end

function PlayersModule._disconnectObserver(self: PlayersModuleImpl, observer: ObserverRecord)
	if not observer.Active then
		return
	end
	observer.Active = false
	self._observers[observer] = nil
	if observer.AddedConnection then
		observer.AddedConnection:Disconnect()
		observer.AddedConnection = nil
	end
	if observer.RemovingConnection then
		observer.RemovingConnection:Disconnect()
		observer.RemovingConnection = nil
	end
	table.clear(observer.Observed)
	observer.OnAdded = nil
	observer.OnRemoving = nil
end

function PlayersModule._destroySignals(self: PlayersModuleImpl)
	if self._signalsDestroyed then
		return
	end
	self._signalsDestroyed = true
	self._playerAddedSignal:Destroy()
	self._playerRemovingSignal:Destroy()
	self._characterAddedSignal:Destroy()
	self._characterRemovingSignal:Destroy()
end

function PlayersModule._cleanup(self: PlayersModuleImpl)
	disconnectConnections(self._connections)
	local trackedPlayers = {}
	for player in self._trackedPlayers do
		table.insert(trackedPlayers, player)
	end
	for _, player in trackedPlayers do
		self:_disconnectTrackedPlayer(player)
	end
	local observers = {}
	for observer in self._observers do
		table.insert(observers, observer)
	end
	for _, observer in observers do
		self:_disconnectObserver(observer)
	end
	self:_destroySignals()
end

function PlayersModule._assertAcquiring(self: PlayersModuleImpl, connection: DisconnectableConnection?)
	if self._state == "initializing" or self._state == "active" then
		return
	end
	if connection then
		connection:Disconnect()
	end
	error("PlayersModuleTerminal", 3)
end

function PlayersModule._emitCharacterAdded(self: PlayersModuleImpl, player: Player, character: Model)
	local tracked = self._trackedPlayers[player]
	if tracked == nil or tracked.Character == character then
		return
	end
	tracked.Character = character
	self._characterAddedSignal:Fire(player, character)
end

function PlayersModule._emitCharacterRemoving(self: PlayersModuleImpl, player: Player, character: Model)
	local tracked = self._trackedPlayers[player]
	if tracked == nil or tracked.Character ~= character then
		return
	end
	tracked.Character = nil
	self._characterRemovingSignal:Fire(player, character)
end

function PlayersModule._trackPlayer(self: PlayersModuleImpl, player: Player)
	if self._state ~= "initializing" and self._state ~= "active" then
		return
	end
	if self._players:GetPlayerByUserId(player.UserId) ~= player or self._trackedPlayers[player] ~= nil then
		return
	end

	local tracked: TrackedPlayer = {
		Character = nil,
		Connections = {},
	}
	self._trackedPlayers[player] = tracked
	local ok, trackError = xpcall(function()
		local addedConnection = player.CharacterAdded:Connect(function(character)
			if self._state == "initializing" or self._state == "active" then
				self:_emitCharacterAdded(player, character)
			end
		end)
		self:_assertAcquiring(addedConnection)
		table.insert(tracked.Connections, addedConnection)

		local removingConnection = player.CharacterRemoving:Connect(function(character)
			if self._state == "initializing" or self._state == "active" then
				self:_emitCharacterRemoving(player, character)
			end
		end)
		self:_assertAcquiring(removingConnection)
		table.insert(tracked.Connections, removingConnection)
	end, debug.traceback)
	if not ok then
		self:_disconnectTrackedPlayer(player)
		error(trackError, 0)
	end

	self._playerAddedSignal:Fire(player)
	local currentCharacter = player.Character
	if currentCharacter then
		self:_emitCharacterAdded(player, currentCharacter)
	end
end

function PlayersModule._removePlayer(self: PlayersModuleImpl, player: Player)
	local tracked = self._trackedPlayers[player]
	if tracked == nil then
		return
	end
	if tracked.Character then
		self:_emitCharacterRemoving(player, tracked.Character)
	end
	self._playerRemovingSignal:Fire(player)
	self:_disconnectTrackedPlayer(player)
end

function PlayersModule.Initialize(self: PlayersModuleImpl)
	if self._state == "active" then
		return
	elseif self._state == "initializing" then
		error("PlayersModuleInitializing", 2)
	elseif self._state == "failed" or self._state == "stopped" then
		error("PlayersModuleTerminal", 2)
	end

	self._state = "initializing"
	local ok, initializationError = xpcall(function()
		local addedConnection = self._players.PlayerAdded:Connect(function(player)
			self:_trackPlayer(player)
		end)
		self:_assertAcquiring(addedConnection)
		table.insert(self._connections, addedConnection)

		local removingConnection = self._players.PlayerRemoving:Connect(function(player)
			if self._state == "initializing" or self._state == "active" then
				self:_removePlayer(player)
			end
		end)
		self:_assertAcquiring(removingConnection)
		table.insert(self._connections, removingConnection)

		local currentPlayers = self._players:GetPlayers()
		self:_assertAcquiring(nil)
		for _, player in currentPlayers do
			self:_trackPlayer(player)
			self:_assertAcquiring(nil)
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

function PlayersModule.GetPlayers(self: PlayersModuleImpl): { Player }
	requireActive(self)
	return self._players:GetPlayers()
end

function PlayersModule.GetPlayerByUserId(self: PlayersModuleImpl, userId: number): Player?
	requireActive(self)
	return self._players:GetPlayerByUserId(userId)
end

function PlayersModule.GetPlayerFromCharacter(self: PlayersModuleImpl, character: Model): Player?
	requireActive(self)
	return self._players:GetPlayerFromCharacter(character)
end

local function traceObserverError(observerError: unknown): string
	return debug.traceback(tostring(observerError), 2)
end

function PlayersModule.ObservePlayers(
	self: PlayersModuleImpl,
	onAdded: (Player) -> (),
	onRemoving: ((Player) -> ())?
): () -> ()
	requireActive(self)
	assert(typeof(onAdded) == "function", "onAdded required")
	assert(onRemoving == nil or typeof(onRemoving) == "function", "onRemoving must be a function")

	local observer: ObserverRecord = {
		Active = true,
		Observed = {},
		OnAdded = onAdded,
		OnRemoving = onRemoving,
		AddedConnection = nil,
		RemovingConnection = nil,
	}
	self._observers[observer] = true

	local function emitAdded(player: Player)
		if not observer.Active
			or self._state ~= "active"
			or observer.Observed[player]
			or self._players:GetPlayerByUserId(player.UserId) ~= player
		then
			return
		end
		observer.Observed[player] = true
		local callback = observer.OnAdded
		if callback and observer.Active and self._state == "active" then
			callback(player)
		end
	end

	local function emitRemoving(player: Player)
		if not observer.Active or not observer.Observed[player] then
			return
		end
		observer.Observed[player] = nil
		local callback = observer.OnRemoving
		if callback and observer.Active and self._state == "active" then
			callback(player)
		end
	end

	local connectOk, connectError = xpcall(function()
		observer.AddedConnection = self.PlayerAdded:Connect(emitAdded)
		observer.RemovingConnection = self.PlayerRemoving:Connect(emitRemoving)
	end, debug.traceback)
	if not connectOk then
		self:_disconnectObserver(observer)
		error(connectError, 0)
	end

	local enumerationOk, enumerationError = xpcall(function()
		for _, player in self._players:GetPlayers() do
			if not observer.Active or self._state ~= "active" then
				break
			end
			if not observer.Observed[player] and self._players:GetPlayerByUserId(player.UserId) == player then
				observer.Observed[player] = true
				local callback = observer.OnAdded
				if callback then
					local callbackOk, callbackError = xpcall(callback, traceObserverError, player)
					if not callbackOk then
						warn(`[PlayersModule] initial observer error: {callbackError}`)
					end
				end
			end
		end
	end, debug.traceback)
	if not enumerationOk then
		self:_disconnectObserver(observer)
		error(enumerationError, 0)
	end

	return function()
		self:_disconnectObserver(observer)
	end
end

function PlayersModule.Stop(self: PlayersModuleImpl)
	if self._state == "stopped" or self._state == "failed" then
		self:_cleanup()
		return
	end
	self._state = "stopped"
	self:_cleanup()
end

return PlayersModule
