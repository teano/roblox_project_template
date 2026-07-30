--!strict

export type Connection = {
	read Connected: boolean,
	Disconnect: (self: Connection) -> (),
}

export type Signal<T...> = {
	Connect: (self: Signal<T...>, callback: (T...) -> ()) -> Connection,
	Once: (self: Signal<T...>, callback: (T...) -> ()) -> Connection,
	Fire: (self: Signal<T...>, T...) -> (),
	Wait: (self: Signal<T...>) -> T...,
	Destroy: (self: Signal<T...>) -> (),
}

type ConnectionState = {
	_connected: boolean,
	_signal: any?,
	_callback: ((...any) -> ())?,
	_once: boolean,
}

local ConnectionMethods = {}

local ConnectionMetatable = {
	__index = function(connection: ConnectionState, key: string)
		if key == "Connected" then
			return connection._connected
		end
		return (ConnectionMethods :: any)[key]
	end,
	__newindex = function(connection: ConnectionState, key: string, value: any)
		if key == "Connected" then
			error("Connection.Connected is read-only", 2)
		end
		rawset(connection, key, value)
	end,
}

local function disconnectConnection(connection: ConnectionState)
	local signal = connection._signal
	connection._connected = false
	connection._signal = nil
	connection._callback = nil

	if signal == nil then
		return
	end

	local index = table.find(signal._connections, connection)
	if index ~= nil then
		table.remove(signal._connections, index)
	end
end

function ConnectionMethods.Disconnect(self: ConnectionState)
	disconnectConnection(self)
end

local function traceListenerError(listenerError: any): string
	return debug.traceback(tostring(listenerError), 2)
end

local function runListener(callback: (...any) -> (), ...: any)
	local ok, err = xpcall(callback, traceListenerError, ...)
	if not ok then
		warn(`[Signal] listener error: {err}`)
	end
end

local Signal = {}
Signal.__index = Signal

function Signal.new<T...>(): Signal<T...>
	local self = setmetatable({
		_connections = {} :: { ConnectionState },
		_destroyed = false,
	}, Signal)
	return (self :: any) :: Signal<T...>
end

local function connect(self: any, callback: (...any) -> (), once: boolean): Connection
	assert(not self._destroyed, "Signal is destroyed")
	assert(typeof(callback) == "function", "callback must be a function")

	local connection = setmetatable({
		_connected = true,
		_signal = self,
		_callback = callback,
		_once = once,
	}, ConnectionMetatable) :: any
	table.insert(self._connections, connection)

	return (connection :: any) :: Connection
end

function Signal:Connect(callback: (...any) -> ()): Connection
	return connect(self, callback, false)
end

function Signal:Once(callback: (...any) -> ()): Connection
	return connect(self, callback, true)
end

function Signal:Fire(...: any)
	if self._destroyed then
		return
	end

	local snapshot = table.clone(self._connections)
	for _, connection in snapshot do
		if not connection._connected then
			continue
		end

		local callback = connection._callback
		if callback == nil then
			continue
		end

		if connection._once then
			disconnectConnection(connection)
		end

		-- A yielding listener must not block Fire or any later listener.
		task.spawn(runListener, callback, ...)
	end
end

function Signal:Wait(): ...any
	local thread = coroutine.running()
	self:Once(function(...: any)
		task.spawn(thread, ...)
	end)
	return coroutine.yield()
end

function Signal:Destroy()
	if self._destroyed then
		return
	end
	self._destroyed = true
	for _, connection in self._connections do
		connection._connected = false
		connection._signal = nil
		connection._callback = nil
	end
	table.clear(self._connections)
end

return Signal
