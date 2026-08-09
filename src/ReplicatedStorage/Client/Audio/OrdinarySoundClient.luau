--!strict

local Core = require(script.Parent.Parent.Parent.Shared.Audio.OrdinaryPlaybackCore)

local OrdinarySoundClient = {}
OrdinarySoundClient.__index = OrdinarySoundClient

function OrdinarySoundClient.new(poolModule: any, logger: any, dependencies: any?)
	return setmetatable({ _core = Core.new("Client", poolModule, logger, dependencies), _intentSender = nil, _bound = false }, OrdinarySoundClient)
end

function OrdinarySoundClient:Initialize(startup: any, graph: any) self._core:Initialize(startup, graph) end

function OrdinarySoundClient:BindHybridIntentSender(sender: any)
	assert(not self._bound, "Hybrid intent sender may be bound only once")
	self._bound = true
	self._intentSender = sender
end

function OrdinarySoundClient:_local(ref: any, source: any, options: any): any
	local handle, reason = self._core:ResolveAndPlay(ref, source, options)
	if handle == nil then
		self._core._logger:Warn("PlaybackRejected", { ReasonCode = reason })
		return Core.InertHandle()
	end
	return handle
end

function OrdinarySoundClient:PlayLocal(ref: any, options: any?): any return self:_local(ref, nil, options) end
function OrdinarySoundClient:PlayLocalAt(ref: any, position: Vector3, options: any?): any return self:_local(ref, { Kind = "Point", Position = position }, options) end
function OrdinarySoundClient:PlayLocalAttached(ref: any, target: Instance, options: any?): any return self:_local(ref, { Kind = "Attached", Instance = target }, options) end

function OrdinarySoundClient:_rejectHybrid(reason: string): any
	self._core._logger:Warn("HybridNotAllowed", { ReasonCode = reason })
	return Core.InertHandle()
end

function OrdinarySoundClient:_hybrid(ref: any, source: any, options: any): any
	local variant = if self._core._catalog then self._core._catalog:Resolve(ref) else nil
	if variant == nil then return self:_rejectHybrid("UnknownRef") end
	if self._intentSender == nil then return self:_rejectHybrid("HybridSenderUnavailable") end
	local named = self._core._catalog:GetNamedVariant(variant.CueId, variant.VariantId)
	if named ~= variant then return self:_rejectHybrid("HybridNamedVariantRequired") end
	if variant.PlayerType == "Music" then return self:_rejectHybrid("TypeMismatch") end
	if not variant.AllowClientHybrid then return self:_rejectHybrid("HybridNotAllowed") end
	if variant.Looping then return self:_rejectHybrid("HybridLoopUnsupported") end
	local typeConfig = self._core._graph.Config.PlayerTypes[variant.PlayerType]
	if typeConfig == nil or typeConfig.HybridRatePerSecond <= 0 or typeConfig.HybridBurst <= 0 then
		return self:_rejectHybrid("HybridTypeDisabled")
	end
	local valid, validationReason = self._core:ValidateVariant(variant, source, options)
	if not valid then return self:_rejectHybrid(validationReason or "InvalidRequest") end
	local payload, payloadReason = self._intentSender:PrepareIntent(variant, source, options)
	if payload == nil then return self:_rejectHybrid(payloadReason or "InvalidSchema") end
	local handle, playReason = self._core:PlayVariant(variant, source, options)
	if handle == nil then return self:_rejectHybrid(playReason or "InvalidRequest") end
	self._intentSender:SendPreparedIntent(payload)
	return handle
end

function OrdinarySoundClient:PlayHybrid(ref: any, options: any?): any return self:_hybrid(ref, nil, options) end
function OrdinarySoundClient:PlayHybridAt(ref: any, position: Vector3, options: any?): any return self:_hybrid(ref, { Kind = "Point", Position = position }, options) end

function OrdinarySoundClient:PlayReceivedPresentation(payload: any)
	local variant = if self._core._catalog then self._core._catalog:GetNamedVariant(payload.CueId, payload.VariantId) else nil
	local source = if payload.Spatial.Kind == "Point" then payload.Spatial else nil
	local options = {
		VolumeMultiplier = payload.VolumeMultiplier,
		PlaybackSpeedMultiplier = payload.PlaybackSpeedMultiplier,
		TimePosition = payload.TimePosition,
	}
	if variant ~= nil then self._core:PlayVariant(variant, source, options) end
end

return OrdinarySoundClient
