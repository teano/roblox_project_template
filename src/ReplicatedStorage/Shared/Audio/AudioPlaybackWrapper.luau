--!strict

local AudioPlaybackWrapper = {}
AudioPlaybackWrapper.__index = AudioPlaybackWrapper

function AudioPlaybackWrapper.new(playerType: string, dependencies: any?)
	local create = if dependencies and dependencies.InstanceFactory then dependencies.InstanceFactory else Instance.new
	local root = create("Folder")
	root.Name = playerType .. "Playback"
	local player = create("AudioPlayer")
	player.Name = "Player"
	player.Parent = root
	local wire = create("Wire")
	wire.Name = "SourceWire"
	wire.Parent = root
	return setmetatable({
		Root = root,
		Player = player,
		Wire = wire,
		Emitter = nil,
		Anchor = nil,
		Connection = nil,
		TargetConnection = nil,
		PlayerType = playerType,
		Generation = 0,
		_Create = create,
		_BaseVolume = 1,
		_TransitionGain = 1,
		_CallbackContext = nil,
	}, AudioPlaybackWrapper)
end

function AudioPlaybackWrapper:SetTransitionGain(gain: number)
	self._TransitionGain = math.clamp(gain, 0, 1)
	self.Player.Volume = self._BaseVolume * self._TransitionGain
end

function AudioPlaybackWrapper:OnAcquire(context: any)
	self.Generation += 1
	local generation = self.Generation
	local player = self.Player
	local rawPlayer = player :: any
	local variant = context.Variant
	local function notifyEnded(reason: string?)
		if reason ~= nil and context.Logger ~= nil then
			pcall(function()
				context.Logger:Warn("PlaybackEnded", { ReasonCode = reason, PlayerType = self.PlayerType })
			end)
		end
		if context.OnEnded ~= nil then
			pcall(context.OnEnded, generation, reason)
		end
	end
	rawPlayer.Asset = variant.ContentId
	self._BaseVolume = variant.SourceVolume * (context.VolumeMultiplier or 1)
	self._TransitionGain = if context.TransitionGain == nil then 1 else context.TransitionGain
	player.Volume = self._BaseVolume * self._TransitionGain
	player.PlaybackSpeed = variant.PlaybackSpeed * (context.PlaybackSpeedMultiplier or 1)
	player.Looping = variant.Looping
	if variant.PlaybackRegion ~= nil then
		player.PlaybackRegion = NumberRange.new(variant.PlaybackRegion.Start, variant.PlaybackRegion.End)
	end
	if variant.LoopRegion ~= nil and variant.Looping then
		player.LoopRegion = NumberRange.new(variant.LoopRegion.Start, variant.LoopRegion.End)
	end
	if context.TimePosition ~= nil then
		player.TimePosition = math.max(0, context.TimePosition)
	end
	self.Wire.SourceInstance = player
	if variant.PlayerType == "World" then
		local emitter = self.Emitter
		if emitter == nil then
			emitter = self._Create("AudioEmitter")
			emitter.Name = "Emitter"
			emitter.Parent = self.Root
			self.Emitter = emitter
		end
		emitter.AudioInteractionGroup = context.InteractionGroupId
		emitter.AcousticSimulationEnabled = context.SpatialProfile.AcousticSimulationEnabled
		if context.SpatialProfile.DistanceCurve ~= nil then
			local curve = {}
			for _, point in context.SpatialProfile.DistanceCurve do curve[point.Distance] = point.Gain01 end
			emitter:SetDistanceAttenuation(curve)
		end
		if context.SpatialProfile.AngleCurve ~= nil then
			local curve = {}
			for _, point in context.SpatialProfile.AngleCurve do curve[point.Angle] = point.Gain01 end
			emitter:SetAngleAttenuation(curve)
		end
		emitter.PositionType = Enum.EmitterPositionType.Instance
		if context.Source.Kind == "Point" then
			local anchor = self._Create("Part")
			anchor.Name = "PointAnchor"
			anchor.Anchored = true
			anchor.CanCollide = false
			anchor.CanQuery = false
			anchor.CanTouch = false
			anchor.Transparency = 1
			anchor.Position = context.Source.Position
			anchor.Parent = self.Root
			self.Anchor = anchor
			emitter.PositionInstance = anchor
		else
			emitter.PositionInstance = context.Source.Instance
			self.TargetConnection = context.Source.Instance.AncestryChanged:Connect(function()
				if self.Generation == generation and context.Source.Instance.Parent == nil then
					notifyEnded("TargetRemoved")
				end
			end)
		end
		self.Wire.TargetInstance = emitter
	else
		self.Wire.TargetInstance = context.Fader
	end
	local endedCallback = context.OnEnded
	self.Connection = player.Ended:Connect(function()
		if self.Generation == generation and endedCallback ~= nil then
			pcall(endedCallback, generation, nil)
		end
	end)
	self._CallbackContext = context
	self.Root.Parent = context.Parent
	local spawnCallback = context.Spawn or task.spawn
	spawnCallback(function()
		local clock = context.Clock or os.clock
		local waitStep = context.ReadinessWait or task.wait
		local deadline = clock() + (context.LoadTimeoutSeconds or 3)
		while self.Generation == generation and not player.IsReady and clock() < deadline do waitStep() end
		if self.Generation ~= generation then return end
		if not player.IsReady then
			notifyEnded("LoadTimeout")
			return
		end
		local duration = player.TimeLength
		if not (typeof(duration) == "number" and duration == duration and duration > 0 and duration ~= math.huge) then
			notifyEnded("InvalidRegion")
			return
		end
		local effectivePlayback = NumberRange.new(0, duration)
		if variant.PlaybackRegion ~= nil then
			local ending = math.min(variant.PlaybackRegion.End, duration)
			if ending <= variant.PlaybackRegion.Start then
				notifyEnded("InvalidRegion")
				return
			end
			effectivePlayback = NumberRange.new(variant.PlaybackRegion.Start, ending)
		end
		player.PlaybackRegion = effectivePlayback
		if variant.Looping then
			if variant.LoopRegion ~= nil
				and variant.LoopRegion.Start >= effectivePlayback.Min
				and variant.LoopRegion.End <= effectivePlayback.Max
			then
				player.LoopRegion = NumberRange.new(variant.LoopRegion.Start, variant.LoopRegion.End)
			else
				player.LoopRegion = effectivePlayback
				if variant.LoopRegion ~= nil and context.Logger ~= nil then
					pcall(function()
						context.Logger:Warn("InvalidLoopRegion", {
							ReasonCode = "OutsideEffectivePlaybackRegion",
							PlayerType = self.PlayerType,
						})
					end)
				end
			end
		end
		if context.TimePosition ~= nil then
			player.TimePosition = math.clamp(context.TimePosition, effectivePlayback.Min, effectivePlayback.Max)
		end
		if context.OnReady ~= nil then
			local callbackOk = pcall(context.OnReady, generation)
			if not callbackOk then notifyEnded("CallbackFailed"); return end
		end
		if self.Generation ~= generation then return end
		if context.AutoPlay ~= false then player:Play() end
		while self.Generation == generation do
			waitStep()
			if self.Generation ~= generation then return end
			if not player.IsReady then
				notifyEnded("ReadinessLost")
				return
			end
		end
	end)
end

-- Music stack mutations rebase callback authorization without replacing the
-- retained playback lease. Disconnecting the prior Ended connection ensures a
-- callback already captured by that connection keeps its old authorization.
function AudioPlaybackWrapper:UpdateCallbacks(onReady: any, onEnded: any)
	local context = self._CallbackContext
	if context == nil then return end
	context.OnReady = onReady
	context.OnEnded = onEnded
	if self.Connection ~= nil then self.Connection:Disconnect() end
	local generation = self.Generation
	local endedCallback = onEnded
	self.Connection = self.Player.Ended:Connect(function()
		if self.Generation == generation and endedCallback ~= nil then
			pcall(endedCallback, generation, nil)
		end
	end)
end

function AudioPlaybackWrapper:OnRelease()
	self.Generation += 1
	local rawPlayer = self.Player :: any
	if self.Connection ~= nil then
		self.Connection:Disconnect()
		self.Connection = nil
	end
	if self.TargetConnection ~= nil then self.TargetConnection:Disconnect(); self.TargetConnection = nil end
	if self.Emitter ~= nil then
		self.Emitter.PositionInstance = nil
		self.Emitter.PositionType = Enum.EmitterPositionType.Parent
	end
	self.Player:Stop()
	self.Wire.SourceInstance = nil
	self.Wire.TargetInstance = nil
	rawPlayer.Asset = ""
	self.Player.Volume = 1
	self.Player.PlaybackSpeed = 1
	self.Player.Looping = false
	self.Player.PlaybackRegion = NumberRange.new(0, 60000)
	self.Player.LoopRegion = NumberRange.new(0, 60000)
	self.Player.TimePosition = 0
	self._BaseVolume = 1
	self._TransitionGain = 1
	self._CallbackContext = nil
	if self.Emitter ~= nil then
		self.Emitter:Destroy()
		self.Emitter = nil
	end
	if self.Anchor ~= nil then
		self.Anchor:Destroy()
		self.Anchor = nil
	end
	self.Root.Parent = nil
end

function AudioPlaybackWrapper:IsPoolableValid(): boolean
	return self.Root ~= nil and self.Player ~= nil
end

function AudioPlaybackWrapper:Destroy()
	self:OnRelease()
	self.Root:Destroy()
end

return AudioPlaybackWrapper
