--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local CommunicationConfig = require(ReplicatedStorage.Shared.Communication.CommunicationConfig)
local CommunicationSerialize = require(ReplicatedStorage.Shared.Communication.CommunicationSerialize)

export type UiError = { Code: string }
export type UiVoidResult = { Kind: "Success" } | { Kind: "Error", Error: UiError }
export type UiRootEvent = {
	ActionId: string,
	UIElementId: string,
	WindowId: string?,
	Payload: any?,
}

local EventStream = {}
EventStream.__index = EventStream

local function failure(code: string): UiVoidResult
	return { Kind = "Error", Error = { Code = code } }
end

local ENVELOPE_FIELDS: { [string]: boolean } = table.freeze({
	ActionId = true,
	UIElementId = true,
	WindowId = true,
	Payload = true,
})

function EventStream.new(actionCatalog: any)
	local backing = Signal.new()
	local surface = table.freeze({
		Connect = function(_self: any, listener: (UiRootEvent) -> ())
			return backing:Connect(listener)
		end,
		Once = function(_self: any, listener: (UiRootEvent) -> ())
			return backing:Once(listener)
		end,
	})
	return setmetatable({
		_catalog = actionCatalog,
		_signal = backing,
		_surface = surface,
		_destroyed = false,
	}, EventStream)
end

function EventStream:GetSource()
	return self._surface
end

function EventStream:Publish(event: UiRootEvent): UiVoidResult
	if self._destroyed
		or typeof(event) ~= "table"
		or self._catalog.ById[event.ActionId] == nil
		or typeof(event.UIElementId) ~= "string"
		or event.UIElementId == ""
		or #event.UIElementId > 544
		or (event.WindowId ~= nil and (typeof(event.WindowId) ~= "string" or event.WindowId == ""))
	then
		return failure("PayloadNotSerializable")
	end
	for key in event do
		if typeof(key) ~= "string" or ENVELOPE_FIELDS[key] ~= true then
			return failure("PayloadNotSerializable")
		end
	end
	local valid = CommunicationSerialize.inspect(event, {
		MaxBytes = CommunicationConfig.MaxSingleMessageEstimatedBytes,
	})
	if not valid then
		return failure("PayloadNotSerializable")
	end
	local envelope = {
		ActionId = event.ActionId,
		UIElementId = event.UIElementId,
		WindowId = event.WindowId,
		Payload = event.Payload,
	}
	table.freeze(envelope)
	self._signal:Fire(envelope)
	return { Kind = "Success" }
end

function EventStream:Destroy()
	if self._destroyed then
		return
	end
	self._destroyed = true
	self._signal:Destroy()
end

return EventStream
