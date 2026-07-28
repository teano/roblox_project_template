--!strict

export type Connection = {
	Connected: boolean,
	Disconnect: (self: Connection) -> (),
}

export type Signal<T...> = {
	Connect: (self: Signal<T...>, callback: (T...) -> ()) -> Connection,
	Once: (self: Signal<T...>, callback: (T...) -> ()) -> Connection,
	Fire: (self: Signal<T...>, T...) -> (),
	Wait: (self: Signal<T...>) -> T...,
	Destroy: (self: Signal<T...>) -> (),
}

type Binding = {
	Connected: boolean,
	_callback: (...any) -> (),
	_once: boolean,
}

local Signal = {}
Signal.__index = Signal

function Signal.new<T...>(): Signal<T...>
	local self = setmetatable({
		_bindings = {} :: { Binding },
		_destroyed = false,
	}, Signal)
	return (self :: any) :: Signal<T...>
end

function Signal:Connect(callback: (...any) -> ()): Connection
	assert(not self._destroyed, "Signal is destroyed")
	assert(typeof(callback) == "function", "callback must be a function")

	local binding: Binding = {
		Connected = true,
		_callback = callback,
		_once = false,
	}

	table.insert(self._bindings, binding)

	local connection: Connection = {
		Connected = true,
		Disconnect = function(conn)
			if not conn.Connected then
				return
			end
			conn.Connected = false
			binding.Connected = false
		end,
	}

	return connection
end

function Signal:Once(callback: (...any) -> ()): Connection
	assert(not self._destroyed, "Signal is destroyed")
	assert(typeof(callback) == "function", "callback must be a function")

	local binding: Binding = {
		Connected = true,
		_callback = callback,
		_once = true,
	}

	table.insert(self._bindings, binding)

	local connection: Connection = {
		Connected = true,
		Disconnect = function(conn)
			if not conn.Connected then
				return
			end
			conn.Connected = false
			binding.Connected = false
		end,
	}

	return connection
end

function Signal:Fire(...: any)
	if self._destroyed then
		return
	end

	local snapshot = table.clone(self._bindings)
	for _, binding in snapshot do
		if not binding.Connected then
			continue
		end

		if binding._once then
			binding.Connected = false
		end

		local ok, err = pcall(binding._callback, ...)
		if not ok then
			warn(`[Signal] listener error: {err}`)
		end
	end

	local compacted: { Binding } = {}
	for _, binding in self._bindings do
		if binding.Connected then
			table.insert(compacted, binding)
		end
	end
	self._bindings = compacted
end

function Signal:Wait(): ...any
	local thread = coroutine.running()
	local connection: Connection
	connection = self:Connect(function(...: any)
		connection:Disconnect()
		task.spawn(thread, ...)
	end)
	return coroutine.yield()
end

function Signal:Destroy()
	self._destroyed = true
	table.clear(self._bindings)
end

return Signal
