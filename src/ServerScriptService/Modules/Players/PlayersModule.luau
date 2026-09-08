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
	CharacterAutoLoads: boolean,
	PlayerAdded: ConnectEvent<Player>,
	PlayerRemoving: ConnectEvent<Player>,
	GetPlayers: (self: any) -> { Player },
	GetPlayerByUserId: (self: any, userId: number) -> Player?,
	GetPlayerFromCharacter: (self: any, character: Model) -> Player?,
}
export type PlayersAdmissionOperation = {
	Player: Player,
	Generation: number,
}
export type PlayersPrepareResult = {
	Ok: boolean,
	Operation: PlayersAdmissionOperation?,
	Error: string?,
}
export type PlayersModule = {
	Initialize: (self: PlayersModule) -> (),
	StartPlatformObservation: (self: PlayersModule) -> boolean,
	Stop: (self: PlayersModule) -> (),
	SetCharacterAutoLoads: (self: PlayersModule, enabled: boolean) -> (),
	GetPlayers: (self: PlayersModule) -> { Player },
	GetPlayerByUserId: (self: PlayersModule, userId: number) -> Player?,
	GetPlayerFromCharacter: (self: PlayersModule, character: Model) -> Player?,
	ObservePlayers: (self: PlayersModule, (Player) -> (), ((Player) -> ())?) -> () -> (),
	PrepareApproval: (self: PlayersModule, player: Player) -> PlayersPrepareResult,
	CommitApproval: (self: PlayersModule, operation: PlayersAdmissionOperation) -> boolean,
	CancelApproval: (self: PlayersModule, operation: PlayersAdmissionOperation) -> (),
	EmitConnectionApproved: (self: PlayersModule, operation: PlayersAdmissionOperation) -> boolean,
	AdmitPlayer: (self: PlayersModule, player: Player) -> boolean,
	DisconnectPlayer: (self: PlayersModule, player: Player, reason: string) -> boolean,
	PlayerAdded: PlayersLifecycleSignal<Player>,
	PlayerRemoving: PlayersLifecycleSignal<Player>,
	CharacterAdded: PlayersLifecycleSignal<Player, Model>,
	CharacterRemoving: PlayersLifecycleSignal<Player, Model>,
	ConnectionApproved: PlayersLifecycleSignal<Player>,
}

type State = "fresh" | "active" | "failed" | "stopped"
type TrackedPlayer = {
	Generation: number,
	Character: Model?,
	Connections: { any },
}
type Approval = PlayersAdmissionOperation & {
	Stage: "prepared" | "committed" | "cancelled" | "emitted",
}
type Observer = {
	Active: boolean,
	Observed: { [Player]: boolean },
	OnAdded: ((Player) -> ())?,
	OnRemoving: ((Player) -> ())?,
	Added: any?,
	Removing: any?,
}
type Impl = PlayersModule & {
	_players: ServerPlayersServiceBoundary,
	_state: State,
	_observationStarted: boolean,
	_connections: { any },
	_tracked: { [Player]: TrackedPlayer },
	_observers: { [Observer]: boolean },
	_nextGeneration: number,
	_added: Signal.Signal<Player>,
	_removing: Signal.Signal<Player>,
	_characterAdded: Signal.Signal<Player, Model>,
	_characterRemoving: Signal.Signal<Player, Model>,
	_connectionApproved: Signal.Signal<Player>,
	_approvals: { [Approval]: boolean },
}

local Module = {}
Module.__index = Module

local function lifecycleError(state: State): string
	if state == "fresh" then
		return "PlayersModuleNotInitialized"
	end
	return "PlayersModuleTerminal"
end

local function requireActive(self: Impl)
	if self._state ~= "active" then
		error(lifecycleError(self._state), 3)
	end
end

local function makeSurface<T...>(
	check: () -> (),
	isActive: () -> boolean
): (PlayersLifecycleSignal<T...>, Signal.Signal<T...>)
	local signal = Signal.new()
	return {
		Connect = function(_self, callback)
			check()
			return signal:Connect(function(...: T...)
				if isActive() then callback(...) end
			end)
		end,
		Once = function(_self, callback)
			check()
			return signal:Once(function(...: T...)
				if isActive() then callback(...) end
			end)
		end,
	}, signal
end

function Module.new(playersService: ServerPlayersServiceBoundary?, _unusedScheduler: any?): PlayersModule
	local self: Impl
	local added, addedSignal = makeSurface(function() requireActive(self) end, function() return self._state == "active" end)
	local removing, removingSignal = makeSurface(function() requireActive(self) end, function() return self._state == "active" end)
	local characterAdded, characterAddedSignal = makeSurface(function() requireActive(self) end, function() return self._state == "active" end)
	local characterRemoving, characterRemovingSignal = makeSurface(function() requireActive(self) end, function() return self._state == "active" end)
	local approved, approvedSignal = makeSurface(function() requireActive(self) end, function() return self._state == "active" end)
	self = setmetatable({
		_players = playersService or Players,
		_state = "fresh",
		_observationStarted = false,
		_connections = {},
		_tracked = {},
		_observers = {},
		_nextGeneration = 0,
		_approvals = {},
		PlayerAdded = added,
		PlayerRemoving = removing,
		CharacterAdded = characterAdded,
		CharacterRemoving = characterRemoving,
		ConnectionApproved = approved,
		_added = addedSignal,
		_removing = removingSignal,
		_characterAdded = characterAddedSignal,
		_characterRemoving = characterRemovingSignal,
		_connectionApproved = approvedSignal,
	}, Module) :: any
	return self
end

local function disconnectAll(connections: { any })
	for _, connection in connections do connection:Disconnect() end
	table.clear(connections)
end

function Module:_disconnectObserver(observer: Observer)
	if not observer.Active then return end
	observer.Active = false
	self._observers[observer] = nil
	if observer.Added then observer.Added:Disconnect(); observer.Added = nil end
	if observer.Removing then observer.Removing:Disconnect(); observer.Removing = nil end
	table.clear(observer.Observed)
	observer.OnAdded = nil
	observer.OnRemoving = nil
end

function Module:_removePlayer(player: Player)
	local tracked = self._tracked[player]
	if tracked == nil then return end
	self._tracked[player] = nil
	disconnectAll(tracked.Connections)
	if tracked.Character ~= nil then
		self._characterRemoving:Fire(player, tracked.Character)
		tracked.Character = nil
	end
	self._removing:Fire(player)
end

function Module:_trackPlayer(player: Player)
	if self._state ~= "active" or self._tracked[player] ~= nil
		or self._players:GetPlayerByUserId(player.UserId) ~= player
	then return end
	self._nextGeneration += 1
	local tracked: TrackedPlayer = { Generation = self._nextGeneration, Character = nil, Connections = {} }
	self._tracked[player] = tracked
	local ok, err = xpcall(function()
		table.insert(tracked.Connections, player.CharacterAdded:Connect(function(character)
			if self._state ~= "active" or self._tracked[player] ~= tracked or tracked.Character == character then return end
			tracked.Character = character
			self._characterAdded:Fire(player, character)
		end))
		table.insert(tracked.Connections, player.CharacterRemoving:Connect(function(character)
			if self._state ~= "active" or self._tracked[player] ~= tracked or tracked.Character ~= character then return end
			tracked.Character = nil
			self._characterRemoving:Fire(player, character)
		end))
	end, debug.traceback)
	if not ok then
		self._tracked[player] = nil
		disconnectAll(tracked.Connections)
		error(err, 0)
	end
	local character = player.Character
	if character ~= nil and tracked.Character ~= character then
		tracked.Character = character
		self._characterAdded:Fire(player, character)
	end
	self._added:Fire(player)
end

function Module:_cleanup()
	disconnectAll(self._connections)
	local players = {}
	for player in self._tracked do table.insert(players, player) end
	for _, player in players do self:_removePlayer(player) end
	local observers = {}
	for observer in self._observers do table.insert(observers, observer) end
	for _, observer in observers do self:_disconnectObserver(observer) end
	for operation in self._approvals do operation.Stage = "cancelled" end
	table.clear(self._approvals)
end

function Module:_destroySignals()
	self._added:Destroy()
	self._removing:Destroy()
	self._characterAdded:Destroy()
	self._characterRemoving:Destroy()
	self._connectionApproved:Destroy()
end

function Module:Initialize()
	if self._state == "active" then return end
	if self._state == "failed" or self._state == "stopped" then error("PlayersModuleTerminal", 2) end
	self._state = "active"
end

function Module:StartPlatformObservation(): boolean
	requireActive(self)
	if self._observationStarted then return false end
	local ok, err = xpcall(function()
		table.insert(self._connections, self._players.PlayerAdded:Connect(function(player)
			self:_trackPlayer(player)
		end))
		table.insert(self._connections, self._players.PlayerRemoving:Connect(function(player)
			self:_removePlayer(player)
		end))
		for _, player in self._players:GetPlayers() do self:_trackPlayer(player) end
	end, debug.traceback)
	if not ok then
		self:_cleanup()
		self._state = "failed"
		error(err, 0)
	end
	self._observationStarted = true
	return true
end

function Module:SetCharacterAutoLoads(enabled: boolean)
	requireActive(self)
	assert(typeof(enabled) == "boolean", "CharacterAutoLoads must be boolean")
	self._players.CharacterAutoLoads = enabled
end

function Module:GetPlayers(): { Player }
	requireActive(self)
	return self._players:GetPlayers()
end

function Module:GetPlayerByUserId(userId: number): Player?
	requireActive(self)
	return self._players:GetPlayerByUserId(userId)
end

function Module:GetPlayerFromCharacter(character: Model): Player?
	requireActive(self)
	return self._players:GetPlayerFromCharacter(character)
end

function Module:ObservePlayers(onAdded: (Player) -> (), onRemoving: ((Player) -> ())?): () -> ()
	requireActive(self)
	if not self._observationStarted then error("PlayersModuleObservationNotStarted", 2) end
	assert(typeof(onAdded) == "function", "onAdded required")
	assert(onRemoving == nil or typeof(onRemoving) == "function", "onRemoving must be a function")
	local observer: Observer = { Active = true, Observed = {}, OnAdded = onAdded, OnRemoving = onRemoving, Added = nil, Removing = nil }
	self._observers[observer] = true
	local function added(player: Player)
		if not observer.Active or observer.Observed[player] or self._players:GetPlayerByUserId(player.UserId) ~= player then return end
		observer.Observed[player] = true
		if observer.OnAdded then observer.OnAdded(player) end
	end
	local function removing(player: Player)
		if not observer.Active or not observer.Observed[player] then return end
		observer.Observed[player] = nil
		if observer.OnRemoving then observer.OnRemoving(player) end
	end
	local ok, err = xpcall(function()
		observer.Added = self.PlayerAdded:Connect(added)
		observer.Removing = self.PlayerRemoving:Connect(removing)
		for _, player in self._players:GetPlayers() do
			local delivered, deliveryError = xpcall(function()
				added(player)
			end, debug.traceback)
			if not delivered then warn(`[PlayersModule] initial observer error: {deliveryError}`) end
		end
	end, debug.traceback)
	if not ok then self:_disconnectObserver(observer); error(err, 0) end
	return function() self:_disconnectObserver(observer) end
end

function Module:PrepareApproval(player: Player): PlayersPrepareResult
	requireActive(self)
	local tracked = self._tracked[player]
	if tracked == nil or self._players:GetPlayerByUserId(player.UserId) ~= player then
		return table.freeze({ Ok = false, Error = "PlayerNotPresent" })
	end
	local operation: Approval = { Player = player, Generation = tracked.Generation, Stage = "prepared" }
	self._approvals[operation] = true
	return table.freeze({ Ok = true, Operation = operation })
end

function Module:CommitApproval(operation: PlayersAdmissionOperation): boolean
	requireActive(self)
	local internal = operation :: Approval
	if self._approvals[internal] ~= true or internal.Stage ~= "prepared" then return false end
	local tracked = self._tracked[internal.Player]
	if tracked == nil or tracked.Generation ~= internal.Generation
		or self._players:GetPlayerByUserId(internal.Player.UserId) ~= internal.Player
	then
		internal.Stage = "cancelled"
		self._approvals[internal] = nil
		return false
	end
	internal.Stage = "committed"
	return true
end

function Module:CancelApproval(operation: PlayersAdmissionOperation)
	local internal = operation :: Approval
	if self._approvals[internal] == nil or internal.Stage == "emitted" then return end
	internal.Stage = "cancelled"
	self._approvals[internal] = nil
end

function Module:EmitConnectionApproved(operation: PlayersAdmissionOperation): boolean
	requireActive(self)
	local internal = operation :: Approval
	if self._approvals[internal] ~= true or internal.Stage ~= "committed" then return false end
	local tracked = self._tracked[internal.Player]
	if tracked == nil or tracked.Generation ~= internal.Generation
		or self._players:GetPlayerByUserId(internal.Player.UserId) ~= internal.Player
	then
		self:CancelApproval(operation)
		return false
	end
	internal.Stage = "emitted"
	self._approvals[internal] = nil
	self._connectionApproved:Fire(internal.Player)
	return true
end

-- This bridge preserves the established player-slot call site until its
-- approved admission coordinator replaces it in the following slice. It owns
-- no character policy: the character module receives ConnectionApproved.
function Module:AdmitPlayer(player: Player): boolean
	local prepared = self:PrepareApproval(player)
	if not prepared.Ok or prepared.Operation == nil then return false end
	if not self:CommitApproval(prepared.Operation) then
		self:CancelApproval(prepared.Operation)
		return false
	end
	return self:EmitConnectionApproved(prepared.Operation)
end

function Module:DisconnectPlayer(player: Player, reason: string): boolean
	requireActive(self)
	assert(typeof(reason) == "string" and reason ~= "", "Disconnect reason required")
	if self._players:GetPlayerByUserId(player.UserId) ~= player then return false end
	return pcall(function() player:Kick(reason) end)
end

function Module:Stop()
	if self._state ~= "stopped" and self._state ~= "failed" then self._state = "stopped" end
	self:_cleanup()
	self:_destroySignals()
end

return Module
