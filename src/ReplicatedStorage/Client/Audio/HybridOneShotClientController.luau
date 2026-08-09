--!strict

local AudioProtocol = require(script.Parent.Parent.Parent.Shared.Audio.AudioProtocol)
local AudioHybridCodec = require(script.Parent.Parent.Parent.Shared.Audio.AudioHybridCodec)

local Controller = {}
Controller.__index = Controller

function Controller.new(dependencies: any)
	return setmetatable({ _d = dependencies, _startup = nil, _registered = false }, Controller)
end

function Controller:Register(startup: any)
	if self._registered then return end
	self._d.Communication:RegisterHandler(AudioProtocol.MessageTypes.HybridPresentation, function(payload)
		local valid, normalized = AudioHybridCodec.validate(payload)
		if not valid then self._d.Logger:Warn("HybridNotAllowed", { ReasonCode = "InvalidSchema" }); return end
		if not startup.Enabled then self._d.Logger:Warn("AudioDisabled", {}); return end
		local variant = startup.Catalog:GetNamedVariant(normalized.CueId, normalized.VariantId)
		if variant == nil or not variant.AllowClientHybrid or variant.Looping then return end
		self._d.PlayReceivedPresentation(normalized)
	end)
	self._startup = startup
	self._registered = true
end

function Controller:PrepareIntent(variant: any, source: any, options: any): (any?, string?)
	local payload = {
		Version = 1,
		CueId = variant.CueId,
		VariantId = variant.VariantId,
		VolumeMultiplier = if options then options.VolumeMultiplier else nil,
		PlaybackSpeedMultiplier = if options then options.PlaybackSpeedMultiplier else nil,
		TimePosition = if options then options.TimePosition else nil,
		Spatial = if source == nil then { Kind = "None" } else { Kind = "Point", Position = source.Position },
	}
	local valid, normalized, reason = AudioHybridCodec.validate(payload)
	if not valid then return nil, reason or "InvalidSchema" end
	return normalized, nil
end

function Controller:SendPreparedIntent(payload: any): boolean
	local queued = self._d.Communication:Queue(AudioProtocol.MessageTypes.HybridIntent, payload, nil, { Priority = "Presentation" })
	if not queued then self._d.Logger:Warn("HybridQueueRejected", {}) end
	return queued
end

function Controller:SendIntent(variant: any, source: any, options: any): boolean
	local payload = self:PrepareIntent(variant, source, options)
	if payload == nil then return false end
	return self:SendPreparedIntent(payload)
end

return Controller
