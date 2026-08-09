--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Core = require(ReplicatedStorage.Shared.Audio.OrdinaryPlaybackCore)

local OrdinarySoundServer = {}
OrdinarySoundServer.__index = OrdinarySoundServer

function OrdinarySoundServer.new(poolModule: any, logger: any, dependencies: any?)
	return setmetatable({ _core = Core.new("Server", poolModule, logger, dependencies) }, OrdinarySoundServer)
end

function OrdinarySoundServer:Initialize(startup: any, graph: any)
	self._core:Initialize(startup, graph)
end

function OrdinarySoundServer:_play(ref: any, source: any, options: any): any
	if self._core._catalog == nil then
		return table.freeze({ Accepted = false, ReasonCode = "AudioDisabled" })
	end
	local variant, resolveReason = self._core._catalog:Resolve(ref)
	if variant == nil then
		return table.freeze({ Accepted = false, ReasonCode = resolveReason })
	end
	local handle, reason = self._core:PlayVariant(variant, source, options)
	if handle == nil then
		return table.freeze({ Accepted = false, ReasonCode = reason })
	end
	if variant.Looping then
		return table.freeze({ Accepted = true, Handle = handle })
	end
	return table.freeze({ Accepted = true })
end

function OrdinarySoundServer:Play(ref: any, options: any?): any return self:_play(ref, nil, options) end
function OrdinarySoundServer:PlayAt(ref: any, position: Vector3, options: any?): any return self:_play(ref, { Kind = "Point", Position = position }, options) end
function OrdinarySoundServer:PlayAttached(ref: any, target: Instance, options: any?): any return self:_play(ref, { Kind = "Attached", Instance = target }, options) end

return OrdinarySoundServer
