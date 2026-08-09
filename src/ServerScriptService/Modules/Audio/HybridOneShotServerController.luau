--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local AudioProtocol = require(ReplicatedStorage.Shared.Audio.AudioProtocol)
local AudioHybridCodec = require(ReplicatedStorage.Shared.Audio.AudioHybridCodec)
local AudioSafetyLimits = require(ReplicatedStorage.Shared.Audio.AudioSafetyLimits)

local Controller = {}
Controller.__index = Controller

function Controller.new(dependencies: any)
	return setmetatable({ _d = dependencies, _startup = nil, _registered = false, _rate = {} }, Controller)
end

function Controller:_bucket(key: string, rate: number, burst: number): any
	local now = self._d.Clock()
	local state = self._rate[key]
	if state == nil then state = { At = now, Tokens = burst }; self._rate[key] = state end
	state.Tokens = math.min(burst, state.Tokens + math.max(0, now - state.At) * rate)
	state.At = now
	return state
end

function Controller:_reserve(player: Player, playerType: string, recipients: number): (boolean, string?)
	local config = self._startup.Config.PlayerTypes[playerType]
	local reservations = {
		{ State = self:_bucket(`Type:{player.UserId}:{playerType}`, config.HybridRatePerSecond, config.HybridBurst), Cost = 1, Reason = "RateLimited" },
		{ State = self:_bucket(`Owner:{player.UserId}`, AudioSafetyLimits.HybridAggregateRatePerOwner, AudioSafetyLimits.HybridAggregateBurstPerOwner), Cost = 1, Reason = "RateLimited" },
		{ State = self:_bucket("ServerAccepted", AudioSafetyLimits.HybridAcceptedRateServer, AudioSafetyLimits.HybridAcceptedBurstServer), Cost = 1, Reason = "RateLimited" },
	}
	if recipients > 0 then
		table.insert(reservations, {
			State = self:_bucket("FanoutRecipients", AudioSafetyLimits.HybridFanoutRecipientsRateServer, AudioSafetyLimits.HybridFanoutRecipientsBurstServer),
			Cost = recipients,
			Reason = "FanoutBudgetExceeded",
		})
	end
	for _, reservation in reservations do
		if reservation.State.Tokens < reservation.Cost then return false, reservation.Reason end
	end
	for _, reservation in reservations do reservation.State.Tokens -= reservation.Cost end
	return true, nil
end

function Controller:_clearPlayer(player: Player)
	local ownerKey = `Owner:{player.UserId}`
	local typePrefix = `Type:{player.UserId}:`
	for key in self._rate do
		if key == ownerKey or key:sub(1, #typePrefix) == typePrefix then self._rate[key] = nil end
	end
end

function Controller:Register(startup: any)
	if self._registered then return end
	self._startup = startup
	local removalConnection = self._d.PlayersModule.PlayerRemoving:Connect(function(player) self:_clearPlayer(player) end)
	local ok, registerError = xpcall(function()
		self._d.Communication:RegisterHandler(AudioProtocol.MessageTypes.HybridIntent, AudioHybridCodec.validate, function(player, payload)
		if not startup.Enabled then self._d.Logger:Warn("AudioDisabled", {}); return end
		local variant = startup.Catalog:GetNamedVariant(payload.CueId, payload.VariantId)
		if variant == nil or not variant.AllowClientHybrid or variant.Looping or variant.PlayerType == "Music" then
			self._d.Logger:Warn("HybridNotAllowed", { UserId = player.UserId }); return
		end
		if (variant.PlayerType == "World") ~= (payload.Spatial.Kind == "Point") then
			self._d.Logger:Warn("HybridNotAllowed", { UserId = player.UserId }); return
		end
		local typeConfig = startup.Config.PlayerTypes[variant.PlayerType]
		local effectiveVolume = variant.SourceVolume * (payload.VolumeMultiplier or 1)
		local effectiveSpeed = variant.PlaybackSpeed * (payload.PlaybackSpeedMultiplier or 1)
		if effectiveVolume < typeConfig.SourceVolumeMin or effectiveVolume > typeConfig.SourceVolumeMax
			or effectiveSpeed < typeConfig.PlaybackSpeedMin or effectiveSpeed > typeConfig.PlaybackSpeedMax
			or (payload.TimePosition ~= nil and variant.PlaybackRegion ~= nil
				and (payload.TimePosition < variant.PlaybackRegion.Start or payload.TimePosition >= variant.PlaybackRegion.End))
		then
			self._d.Logger:Warn("HybridNotAllowed", { UserId = player.UserId }); return
		end
		local recipients = {}
		for _, recipient in self._d.PlayersModule:GetPlayers() do
			if recipient ~= player and self._d.Communication:IsClientReady(recipient) then table.insert(recipients, recipient) end
		end
		local reserved, reason = self:_reserve(player, variant.PlayerType, #recipients)
		if not reserved then self._d.Logger:Warn(reason or "RateLimited", { UserId = player.UserId }); return end
		local queued = self._d.Communication:QueuePresentationAtomic(
			recipients,
			AudioProtocol.MessageTypes.HybridPresentation,
			payload,
			nil
		)
		if not queued then
			self._d.Logger:Warn("HybridQueueRejected", { UserId = player.UserId })
		end
		end)
	end, debug.traceback)
	if not ok then
		removalConnection:Disconnect()
		self._startup = nil
		error(registerError, 0)
	end
	self._removalConnection = removalConnection
	self._registered = true
end

return Controller
