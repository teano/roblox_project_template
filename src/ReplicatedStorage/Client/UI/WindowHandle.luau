--!strict

local UiSyncHookGuard = require(script.Parent.Internal.UiSyncHookGuard)

local Handle = {}
Handle.__index = Handle

export type WindowHandle<T> = {
	WindowId: string,
	IsValid: (self: WindowHandle<T>) -> boolean,
	IsActiveWindow: (self: WindowHandle<T>) -> boolean,
	GetView: (self: WindowHandle<T>) -> ({ Kind: "Success", Value: T } | { Kind: "Error", Error: any }),
}

function Handle.new<T>(
	navigator: any,
	registration: any,
	windowId: string,
	generation: number,
	cast: (any) -> T?
): WindowHandle<T>
	return table.freeze(setmetatable({
		WindowId = windowId,
		_navigator = navigator,
		_registration = registration,
		_generation = generation,
		_cast = cast,
	}, Handle)) :: any
end

function Handle:IsValid(): boolean
	return self._navigator:_IsHandleValid(self._registration, self._generation)
end

function Handle:IsActiveWindow(): boolean
	return self._navigator:_IsHandleActive(self._registration, self._generation)
end

function Handle:GetView()
	local view = self._navigator:_GetHandleView(self._registration, self._generation)
	if view == nil then
		return { Kind = "Error", Error = { Code = "StaleHandle", WindowId = self.WindowId } }
	end
	local cast = UiSyncHookGuard.call("TryCastView", function()
		return self._cast(view)
	end)
	if cast.Kind ~= "Success" or cast.Value == nil then
		return { Kind = "Error", Error = { Code = "TypedDefinitionMismatch", WindowId = self.WindowId } }
	end
	return { Kind = "Success", Value = cast.Value }
end

return Handle
