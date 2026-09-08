--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Signal = require(ReplicatedStorage.Shared.Util.Signal)

export type CharacterLifecycleSignal<T...> = {
	Connect: (self: CharacterLifecycleSignal<T...>, callback: (T...) -> ()) -> Signal.Connection,
	Once: (self: CharacterLifecycleSignal<T...>, callback: (T...) -> ()) -> Signal.Connection,
}
export type CharacterClient = {
	Initialize: (self: CharacterClient) -> (),
	Stop: (self: CharacterClient) -> (),
	GetCharacter: (self: CharacterClient) -> Model?,
	WaitForCharacter: (self: CharacterClient) -> Model,
	CharacterAdded: CharacterLifecycleSignal<Model>,
	CharacterRemoving: CharacterLifecycleSignal<Model>,
}

type State = "fresh" | "active" | "failed" | "stopped"
type Impl = CharacterClient & {
	_players: any,
	_state: State,
	_character: Model?,
	_waiters: { [thread]: boolean },
	_disconnect: (() -> ())?,
	_added: Signal.Signal<Model>,
	_removing: Signal.Signal<Model>,
}

local Client = {}
Client.__index = Client

local function requireActive(self: Impl)
	if self._state ~= "active" then
		error(if self._state == "fresh" then "CharacterClientNotInitialized" else "CharacterClientTerminal", 3)
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

function Client.new(playersModule: any): CharacterClient
	assert(playersModule ~= nil, "PlayersModule required")
	local self: Impl
	local added, addedSignal = makeSignal(function() return self end)
	local removing, removingSignal = makeSignal(function() return self end)
	self = setmetatable({
		_players = playersModule,
		_state = "fresh",
		_character = nil,
		_waiters = {},
		_disconnect = nil,
		CharacterAdded = added,
		CharacterRemoving = removing,
		_added = addedSignal,
		_removing = removingSignal,
	}, Client) :: any
	return self
end

function Client:_finishWaiters(success: boolean, value: Model | string)
	local waiters = {}
	for thread in self._waiters do table.insert(waiters, thread) end
	table.clear(self._waiters)
	for _, thread in waiters do task.spawn(thread, success, value) end
end

function Client:_onAdded(character: Model)
	if self._state ~= "active" or self._character == character then return end
	self._character = character
	self:_finishWaiters(true, character)
	self._added:Fire(character)
end

function Client:_onRemoving(character: Model)
	if self._state ~= "active" or self._character ~= character then return end
	self._character = nil
	self._removing:Fire(character)
end

function Client:Initialize()
	if self._state == "active" then return end
	if self._state == "failed" or self._state == "stopped" then error("CharacterClientTerminal", 2) end
	self._state = "active"
	local ok, err = xpcall(function()
		self._disconnect = self._players:ObserveCharacter(function(character: Model)
			self:_onAdded(character)
		end, function(character: Model)
			self:_onRemoving(character)
		end)
	end, debug.traceback)
	if not ok then
		self._state = "failed"
		error(err, 0)
	end
end

function Client:GetCharacter(): Model?
	requireActive(self)
	return self._character
end

function Client:WaitForCharacter(): Model
	requireActive(self)
	if self._character ~= nil then return self._character end
	local thread = coroutine.running()
	self._waiters[thread] = true
	local success, value = coroutine.yield()
	if not success then error(value, 2) end
	return value :: Model
end

function Client:Stop()
	if self._state == "stopped" or self._state == "failed" then return end
	self._state = "stopped"
	if self._disconnect ~= nil then self._disconnect(); self._disconnect = nil end
	self:_finishWaiters(false, "CharacterClientTerminal")
	self._character = nil
	self._added:Destroy()
	self._removing:Destroy()
end

return Client
