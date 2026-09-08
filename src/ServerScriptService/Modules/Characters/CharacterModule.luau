--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Signal = require(ReplicatedStorage.Shared.Util.Signal)

export type CharacterLifecycleSignal<T...> = {
	Connect: (self: CharacterLifecycleSignal<T...>, callback: (T...) -> ()) -> Signal.Connection,
	Once: (self: CharacterLifecycleSignal<T...>, callback: (T...) -> ()) -> Signal.Connection,
}
export type CharacterModule = {
	Initialize: (self: CharacterModule) -> (),
	RequestRespawn: (self: CharacterModule, player: Player, callback: (boolean, string?) -> ()) -> boolean,
	CancelRespawn: (self: CharacterModule, player: Player) -> boolean,
	Stop: (self: CharacterModule) -> (),
	CharacterAdded: CharacterLifecycleSignal<Player, Model>,
	CharacterRemoving: CharacterLifecycleSignal<Player, Model>,
}

type State = "fresh" | "active" | "failed" | "stopped"
type TrackedCharacter = {
	Generation: number,
	Approved: boolean,
	SpawnActive: boolean,
	SpawnReturned: boolean,
	SpawnCharacter: Model?,
	SpawnPreviousCharacter: Model?,
	SpawnCompletion: ((boolean, string?) -> ())?,
	SpawnCancelled: boolean,
	Current: Model?,
	Seen: { [Model]: boolean },
	Connections: { any },
}
type Impl = CharacterModule & {
	_players: any,
	_config: any,
	_scheduler: any,
	_state: State,
	_respawnDelaySeconds: number?,
	_connections: { any },
	_tracked: { [Player]: TrackedCharacter },
	_nextGeneration: number,
	_added: Signal.Signal<Player, Model>,
	_removing: Signal.Signal<Player, Model>,
}

local Module = {}
Module.__index = Module

local function requireActive(self: Impl)
	if self._state ~= "active" then
		error(if self._state == "fresh" then "CharacterModuleNotInitialized" else "CharacterModuleTerminal", 3)
	end
end

local function makeSignal<T...>(self: () -> Impl): (CharacterLifecycleSignal<T...>, Signal.Signal<T...>)
	local backing = Signal.new()
	return {
		Connect = function(_self, callback)
			requireActive(self())
			return backing:Connect(function(...: T...)
				if self()._state == "active" then callback(...) end
			end)
		end,
		Once = function(_self, callback)
			requireActive(self())
			return backing:Once(function(...: T...)
				if self()._state == "active" then callback(...) end
			end)
		end,
	}, backing
end

function Module.new(dependencies: {
	PlayersModule: any,
	Config: any,
	Scheduler: any?,
}): CharacterModule
	assert(dependencies ~= nil and dependencies.PlayersModule ~= nil and dependencies.Config ~= nil, "CharacterModule dependencies required")
	local self: Impl
	local added, addedSignal = makeSignal(function() return self end)
	local removing, removingSignal = makeSignal(function() return self end)
	self = setmetatable({
		_players = dependencies.PlayersModule,
		_config = dependencies.Config,
		_scheduler = dependencies.Scheduler or {
			Defer = function(callback) task.defer(callback) end,
			Wait = function(seconds) task.wait(seconds) end,
		},
		_state = "fresh",
		_respawnDelaySeconds = nil,
		_connections = {},
		_tracked = {},
		_nextGeneration = 0,
		CharacterAdded = added,
		CharacterRemoving = removing,
		_added = addedSignal,
		_removing = removingSignal,
	}, Module) :: any
	return self
end

local function disconnectAll(connections: { any })
	for _, connection in connections do connection:Disconnect() end
	table.clear(connections)
end

local function destroyCharacter(character: Model?)
	if character ~= nil then pcall(function() character:Destroy() end) end
end

function Module:_isCurrent(player: Player, generation: number): boolean
	local tracked = self._tracked[player]
	return self._state == "active" and tracked ~= nil and tracked.Generation == generation
		and tracked.Approved and self._players:GetPlayerByUserId(player.UserId) == player
end

function Module:_getTracked(player: Player): TrackedCharacter
	local tracked = self._tracked[player]
	if tracked ~= nil then return tracked end
	self._nextGeneration += 1
	tracked = {
		Generation = self._nextGeneration,
		Approved = false,
		SpawnActive = false,
		SpawnReturned = false,
		SpawnCharacter = nil,
		SpawnPreviousCharacter = nil,
		SpawnCompletion = nil,
		SpawnCancelled = false,
		Current = nil,
		Seen = {},
		Connections = {},
	}
	self._tracked[player] = tracked
	return tracked
end

function Module:_settleCancelledSpawn(player: Player, generation: number)
	local tracked = self._tracked[player]
	if tracked == nil or tracked.Generation ~= generation or not tracked.SpawnActive or not tracked.SpawnCancelled then return end
	local previousCharacter = tracked.SpawnPreviousCharacter
	local currentCharacter = tracked.Current
	if currentCharacter ~= nil and currentCharacter ~= previousCharacter then
		tracked.Current = nil
		disconnectAll(tracked.Connections)
		if tracked.Approved then self._removing:Fire(player, currentCharacter) end
		destroyCharacter(currentCharacter)
	end
	local platformCharacter = player.Character
	if platformCharacter ~= nil and platformCharacter ~= previousCharacter then destroyCharacter(platformCharacter) end
	tracked.SpawnActive = false
	tracked.SpawnReturned = false
	tracked.SpawnCharacter = nil
	tracked.SpawnPreviousCharacter = nil
	tracked.SpawnCancelled = false
	if tracked.Current == nil and self:_isCurrent(player, generation) then
		self:_scheduleSpawn(player, assert(self._respawnDelaySeconds), function() end, true)
	end
end

local function finishSpawnCompletion(tracked: TrackedCharacter, ok: boolean, errorCode: string?)
	local callback = tracked.SpawnCompletion
	tracked.SpawnCompletion = nil
	if callback ~= nil then
		pcall(callback, ok, errorCode)
	end
end

function Module:_settleSpawn(player: Player, generation: number, character: Model)
	self._scheduler.Defer(function()
		local tracked = self._tracked[player]
		if self._state ~= "active" or tracked == nil or tracked.Generation ~= generation
			or not tracked.Approved or not tracked.SpawnActive or tracked.SpawnCharacter ~= character
		then return end
		if tracked.SpawnCancelled then
			self:_settleCancelledSpawn(player, generation)
			return
		end
		tracked.SpawnActive = false
		tracked.SpawnReturned = false
		tracked.SpawnCharacter = nil
		tracked.SpawnPreviousCharacter = nil
		tracked.SpawnCancelled = false
		finishSpawnCompletion(tracked, true, nil)
		if tracked.Current == nil then self:_requestRespawn(player) end
	end)
end

function Module:_scheduleSpawn(player: Player, delaySeconds: number, completion: ((boolean, string?) -> ())?, isRecovery: boolean?): boolean
	local tracked = self._tracked[player]
	if tracked == nil or not tracked.Approved or tracked.SpawnActive then return false end
	tracked.SpawnActive = true
	tracked.SpawnReturned = false
	tracked.SpawnCharacter = nil
	tracked.SpawnPreviousCharacter = tracked.Current or player.Character
	tracked.SpawnCompletion = completion
	tracked.SpawnCancelled = false
	local generation = tracked.Generation
	self._scheduler.Defer(function()
		if delaySeconds > 0 then self._scheduler.Wait(delaySeconds) end
		if not self:_isCurrent(player, generation) then return end
		local beforeLoad = self._tracked[player]
		if beforeLoad ~= nil and beforeLoad.SpawnCancelled then
			self:_settleCancelledSpawn(player, generation)
			return
		end
		for _ = 1, 3 do
			local ok = pcall(function()
				(player :: any):LoadCharacterAsync()
			end)
			if not self:_isCurrent(player, generation) then
				destroyCharacter(player.Character)
				return
			end
			local afterLoad = self._tracked[player]
			if afterLoad ~= nil and afterLoad.SpawnCancelled then
				self:_settleCancelledSpawn(player, generation)
				return
			end
			if ok then
				local current = self._tracked[player]
				if current ~= nil and current.Generation == generation then
					current.SpawnReturned = true
					local candidate = player.Character
					if candidate ~= current.SpawnPreviousCharacter then current.SpawnCharacter = candidate end
					local character = current.SpawnCharacter
					if character ~= nil and current.Seen[character] then
						self:_settleSpawn(player, generation, character)
					end
				end
				return
			end
		end
		if self:_isCurrent(player, generation) then
			local current = self._tracked[player]
			if current ~= nil and current.Generation == generation then
				current.SpawnActive = false
				current.SpawnReturned = false
				current.SpawnCharacter = nil
				current.SpawnPreviousCharacter = nil
				current.SpawnCancelled = false
			end
			if current ~= nil and current.SpawnCompletion ~= nil then
				finishSpawnCompletion(current, false, "RespawnFailed")
				if not isRecovery and current.Current == nil and self:_isCurrent(player, generation) then
					self:_scheduleSpawn(player, assert(self._respawnDelaySeconds), function() end, true)
				end
			else
				self._players:DisconnectPlayer(player, "Не удалось создать персонажа после трёх попыток.")
			end
		end
	end)
	return true
end

function Module:_requestRespawn(player: Player)
	local tracked = self._tracked[player]
	if tracked == nil or not tracked.Approved then return end
	self:_scheduleSpawn(player, assert(self._respawnDelaySeconds))
end

function Module:RequestRespawn(player: Player, callback: (boolean, string?) -> ()): boolean
	if self._state ~= "active" or typeof(callback) ~= "function" then return false end
	if self._players:GetPlayerByUserId(player.UserId) ~= player then return false end
	return self:_scheduleSpawn(player, 0, callback)
end

function Module:CancelRespawn(player: Player): boolean
	if self._state ~= "active" then return false end
	local tracked = self._tracked[player]
	if tracked == nil or not tracked.SpawnActive or tracked.SpawnCompletion == nil then return false end
	tracked.SpawnCancelled = true
	finishSpawnCompletion(tracked, false, "Cancelled")
	return true
end

function Module:_handleCharacterAdded(player: Player, character: Model)
	if self._state ~= "active" then return end
	local tracked = self:_getTracked(player)
	if tracked.Seen[character] then return end
	tracked.Seen[character] = true
	if tracked.SpawnActive and tracked.SpawnCancelled and character ~= tracked.SpawnPreviousCharacter then
		destroyCharacter(character)
		return
	end
	if tracked.Current ~= nil and tracked.Current ~= character then
		local replaced = tracked.Current
		tracked.Current = nil
		disconnectAll(tracked.Connections)
		if tracked.Approved then self._removing:Fire(player, replaced) end
	end
	if not tracked.Approved then
		destroyCharacter(character)
		return
	end
	tracked.Current = character
	if tracked.SpawnActive and character ~= tracked.SpawnPreviousCharacter then
		tracked.SpawnCharacter = character
	end
	if tracked.SpawnActive and tracked.SpawnReturned
		and tracked.SpawnCharacter == character
	then
		tracked.SpawnCharacter = character
		self:_settleSpawn(player, tracked.Generation, character)
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid ~= nil then
		table.insert(tracked.Connections, humanoid.Died:Connect(function()
			self:_requestRespawn(player)
		end))
	end
	self._added:Fire(player, character)
end

function Module:_handleCharacterRemoving(player: Player, character: Model)
	local tracked = self._tracked[player]
	if self._state ~= "active" or tracked == nil or tracked.Current ~= character then return end
	tracked.Current = nil
	disconnectAll(tracked.Connections)
	if tracked.Approved then
		self._removing:Fire(player, character)
		self:_requestRespawn(player)
	end
end

function Module:_handleConnectionApproved(player: Player)
	if self._state ~= "active" then return end
	local tracked = self:_getTracked(player)
	if tracked.Approved then return end
	tracked.Approved = true
	self:_scheduleSpawn(player, 0)
end

function Module:_handlePlayerRemoving(player: Player)
	local tracked = self._tracked[player]
	if tracked == nil then return end
	self._tracked[player] = nil
	tracked.Generation += 1
	tracked.Approved = false
	tracked.SpawnActive = false
	tracked.SpawnReturned = false
	tracked.SpawnCharacter = nil
	tracked.SpawnPreviousCharacter = nil
	tracked.SpawnCancelled = false
	finishSpawnCompletion(tracked, false, "PlayerGone")
	disconnectAll(tracked.Connections)
	destroyCharacter(tracked.Current)
	destroyCharacter(player.Character)
	tracked.Current = nil
	table.clear(tracked.Seen)
end

function Module:Initialize()
	if self._state == "active" then return end
	if self._state == "failed" or self._state == "stopped" then error("CharacterModuleTerminal", 2) end
	local config = self._config:GetRequired("Characters")
	assert(typeof(config) == "table" and typeof(config.RespawnDelaySeconds) == "number", "Characters config is invalid")
	self._respawnDelaySeconds = config.RespawnDelaySeconds
	self._state = "active"
	local ok, err = xpcall(function()
		self._players:SetCharacterAutoLoads(false)
		table.insert(self._connections, self._players.CharacterAdded:Connect(function(player, character)
			self:_handleCharacterAdded(player, character)
		end))
		table.insert(self._connections, self._players.CharacterRemoving:Connect(function(player, character)
			self:_handleCharacterRemoving(player, character)
		end))
		table.insert(self._connections, self._players.ConnectionApproved:Connect(function(player)
			self:_handleConnectionApproved(player)
		end))
		table.insert(self._connections, self._players.PlayerRemoving:Connect(function(player)
			self:_handlePlayerRemoving(player)
		end))
		self._players:StartPlatformObservation()
		for _, player in self._players:GetPlayers() do
			local character = player.Character
			if character ~= nil then self:_handleCharacterAdded(player, character) end
		end
	end, debug.traceback)
	if not ok then
		disconnectAll(self._connections)
		self._state = "failed"
		error(err, 0)
	end
end

function Module:Stop()
	if self._state == "stopped" or self._state == "failed" then return end
	self._state = "stopped"
	disconnectAll(self._connections)
	for player, tracked in self._tracked do
		tracked.Generation += 1
		tracked.Approved = false
		tracked.SpawnActive = false
		tracked.SpawnReturned = false
		tracked.SpawnCharacter = nil
		tracked.SpawnPreviousCharacter = nil
		tracked.SpawnCancelled = false
		finishSpawnCompletion(tracked, false, "Stopped")
		disconnectAll(tracked.Connections)
		destroyCharacter(tracked.Current)
		destroyCharacter(player.Character)
	end
	table.clear(self._tracked)
	self._added:Destroy()
	self._removing:Destroy()
end

return Module
