--!strict

local AudioPlaybackWrapper = require(script.Parent.Parent.Parent.Shared.Audio.AudioPlaybackWrapper)

local MusicClient = {}
MusicClient.__index = MusicClient

local function inert(): any
	return table.freeze({ IsActive = function() return false end, Stop = function() end })
end

local function finite(value: any): boolean
	return typeof(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function normalizeTransition(value: any): any?
	if value == nil then return { Strategy = "Instant", FadeOutSeconds = 0, FadeInSeconds = 0 } end
	if typeof(value) ~= "table" or getmetatable(value) ~= nil then return nil end
	if value.Strategy == "Instant" then
		for key in value do if key ~= "Strategy" then return nil end end
		return { Strategy = "Instant", FadeOutSeconds = 0, FadeInSeconds = 0 }
	end
	if value.Strategy ~= "SequentialFade" and value.Strategy ~= "Crossfade" then return nil end
	for key, number in value do
		if key ~= "Strategy" and key ~= "FadeOutSeconds" and key ~= "FadeInSeconds" then return nil end
		if key ~= "Strategy" and (not finite(number) or number < 0 or number > 10) then return nil end
	end
	return {
		Strategy = value.Strategy,
		FadeOutSeconds = if value.FadeOutSeconds == nil then 0.5 else value.FadeOutSeconds,
		FadeInSeconds = if value.FadeInSeconds == nil then 0.5 else value.FadeInSeconds,
	}
end

local function normalizeOptions(options: any): any?
	if options == nil then return table.freeze({}) end
	if typeof(options) ~= "table" or getmetatable(options) ~= nil then return nil end
	for key, value in options do
		if key ~= "VolumeMultiplier" and key ~= "PlaybackSpeedMultiplier" and key ~= "TimePosition" then return nil end
		if not finite(value) then return nil end
	end
	if not ((options.VolumeMultiplier == nil or (options.VolumeMultiplier >= 0 and options.VolumeMultiplier <= 2))
		and (options.PlaybackSpeedMultiplier == nil or (options.PlaybackSpeedMultiplier >= 0.5 and options.PlaybackSpeedMultiplier <= 2))
		and (options.TimePosition == nil or options.TimePosition >= 0)) then
		return nil
	end
	return table.freeze({
		VolumeMultiplier = options.VolumeMultiplier,
		PlaybackSpeedMultiplier = options.PlaybackSpeedMultiplier,
		TimePosition = options.TimePosition,
	})
end

local function defaultTransitionDriver(duration: number, step: (number) -> (), complete: () -> ()): () -> ()
	local cancelled = false
	if duration <= 0 then step(1); complete(); return function() cancelled = true end end
	task.spawn(function()
		local started = os.clock()
		while not cancelled do
			local alpha = math.clamp((os.clock() - started) / duration, 0, 1)
			step(alpha)
			if alpha >= 1 then complete(); return end
			task.wait()
		end
	end)
	return function() cancelled = true end
end

function MusicClient.new(poolModule: any, logger: any, dependencies: any?)
	return setmetatable({
		_poolModule = poolModule,
		_logger = logger,
		_runtime = dependencies or {},
		_initialized = false,
		_pool = nil,
		_catalog = nil,
		_graph = nil,
		_stack = {},
		_stackGeneration = 0,
		_entryGeneration = 0,
		_schedulerGeneration = 0,
		_cancelScheduled = nil,
		_incumbent = nil,
		_exiting = {},
		_maxDepth = 0,
	}, MusicClient)
end

function MusicClient:Initialize(startup: any, graph: any)
	if self._initialized then return end
	self._initialized = true
	if not startup.Enabled or not graph.Enabled then return end
	local record = startup.Config.PlayerTypes.Music
	local poolId = "Audio.Client.Music"
	local ok, poolOrError = xpcall(function()
		return self._poolModule:CreatePoolablePool(poolId, function()
			if self._runtime.WrapperFactory then return self._runtime.WrapperFactory("Music") end
			return AudioPlaybackWrapper.new("Music", self._runtime)
		end, { MaxActive = record.ClientMaxActive, MaxRetained = record.ClientMaxRetained })
	end, debug.traceback)
	if not ok then
		pcall(function() self._poolModule:RemovePool(poolId) end)
		self._logger:Warn("AudioDisabled", { ReasonCode = "PoolConstructionFailed", PlayerType = "Music" })
		return
	end
	self._catalog = startup.Catalog
	self._graph = graph
	self._pool = poolOrError
	self._maxDepth = record.MusicStackMaxDepth
end

function MusicClient:_cancelTransition()
	self._schedulerGeneration += 1
	if self._cancelScheduled ~= nil then self._cancelScheduled(); self._cancelScheduled = nil end
end

function MusicClient:_schedule(duration: number, step: (number) -> (), complete: () -> ())
	local generation = self._schedulerGeneration
	local driver = self._runtime.TransitionDriver or defaultTransitionDriver
	local completed = false
	local cancellation = driver(duration, function(alpha)
		if self._schedulerGeneration == generation then step(math.clamp(alpha, 0, 1)) end
	end, function()
		if self._schedulerGeneration ~= generation then return end
		completed = true
		self._cancelScheduled = nil
		complete()
	end)
	if not completed and self._schedulerGeneration == generation then self._cancelScheduled = cancellation end
end

function MusicClient:_leaseActive(entry: any): boolean
	return entry.Lease ~= nil and self._pool ~= nil and self._pool:IsLeaseActive(entry.Lease)
end

function MusicClient:_stopRetained(entry: any)
	if not self:_leaseActive(entry) then return end
	local wrapper = entry.Lease.Object
	entry.SavedPosition = wrapper.Player.TimePosition
	wrapper.Player:Stop()
	wrapper:SetTransitionGain(0)
end

function MusicClient:_releaseLease(entry: any)
	entry.AcquisitionGeneration += 1
	if self:_leaseActive(entry) then self._pool:TryReleaseToPool(entry.Lease) end
	entry.Lease = nil
	entry.Ready = false
end

function MusicClient:_removeFromStack(entry: any)
	for index, current in self._stack do
		if current == entry then table.remove(self._stack, index); return end
	end
end

function MusicClient:_releaseEntry(entry: any)
	if self._incumbent == entry then self._incumbent = nil end
	self._exiting[entry] = nil
	entry.Active = false
	self:_removeFromStack(entry)
	self:_releaseLease(entry)
end

function MusicClient:_callbacksFor(entry: any, stackGeneration: number, readyQueued: any?, endedQueued: any?): (any, any)
	local entryGeneration = entry.EntryGeneration
	local acquisitionGeneration = entry.AcquisitionGeneration
	local function authorized(): boolean
		return self._stackGeneration == stackGeneration
			and entry.EntryGeneration == entryGeneration
			and entry.AcquisitionGeneration == acquisitionGeneration
	end
	return function()
		if not authorized() then return end
		if entry.Lease == nil and readyQueued ~= nil then
			readyQueued.Value = true
		else
			self:_onReady(entry)
		end
	end, function(_generation, reason)
		if not authorized() then return end
		if entry.Lease == nil and endedQueued ~= nil then
			endedQueued.Value = reason or "Ended"
		else
			self:_onEnded(entry, reason or "Ended")
		end
	end
end

function MusicClient:_reauthorizeEntry(entry: any)
	if not self:_leaseActive(entry) then return end
	local wrapper = entry.Lease.Object
	if typeof(wrapper.UpdateCallbacks) ~= "function" then return end
	local onReady, onEnded = self:_callbacksFor(entry, self._stackGeneration, nil, nil)
	wrapper:UpdateCallbacks(onReady, onEnded)
end

function MusicClient:_advanceStackGeneration()
	self._stackGeneration += 1
	for _, entry in self._stack do self:_reauthorizeEntry(entry) end
	for entry in self._exiting do self:_reauthorizeEntry(entry) end
end

function MusicClient:_canonicalize(excludedEntry: any?)
	self:_cancelTransition()
	local exiting = table.clone(self._exiting)
	for entry in exiting do
		if entry ~= excludedEntry then self:_releaseEntry(entry) end
	end
	local incumbent = self._incumbent
	if incumbent == excludedEntry
		or incumbent == nil
		or not incumbent.Active
		or not incumbent.Ready
		or not self:_leaseActive(incumbent)
	then
		incumbent = nil
		self._incumbent = nil
	end
	for _, entry in self._stack do
		if entry.Ready and self:_leaseActive(entry) then
			local wrapper = entry.Lease.Object
			if entry == excludedEntry then
				self:_stopRetained(entry)
			elseif entry == incumbent then
				wrapper:SetTransitionGain(1)
				if not wrapper.Player.IsPlaying then wrapper.Player:Play() end
			else
				self:_stopRetained(entry)
			end
		end
	end
	self:_advanceStackGeneration()
	return incumbent
end

function MusicClient:_acquire(entry: any): boolean
	entry.AcquisitionGeneration += 1
	local acquisitionGeneration = entry.AcquisitionGeneration
	entry.Ready = false
	local readyQueued = { Value = false }
	local endedQueued = { Value = nil :: string? }
	local lease = nil
	local typeConfig = self._graph.Config.PlayerTypes.Music
	local onReady, onEnded = self:_callbacksFor(entry, self._stackGeneration, readyQueued, endedQueued)
	local ok = pcall(function()
		lease = self._pool:Acquire({
			Variant = entry.Variant,
			Parent = self._graph.LocalRoot,
			Fader = self._graph.Faders.Music,
			InteractionGroupId = self._graph.Config.InteractionGroupId,
			SpatialProfile = nil,
			Source = nil,
			VolumeMultiplier = if entry.Options then entry.Options.VolumeMultiplier else nil,
			PlaybackSpeedMultiplier = if entry.Options then entry.Options.PlaybackSpeedMultiplier else nil,
			TimePosition = entry.SavedPosition or (if entry.Options then entry.Options.TimePosition else nil),
			LoadTimeoutSeconds = typeConfig.LoadTimeoutSeconds,
			TransitionGain = 0,
			AutoPlay = false,
			Clock = self._runtime.Clock,
			ReadinessWait = self._runtime.ReadinessWait,
			Spawn = self._runtime.Spawn,
			Logger = self._logger,
			OnReady = onReady,
			OnEnded = onEnded,
		})
	end)
	if not ok then return false end
	entry.Lease = lease
	if endedQueued.Value ~= nil then self:_onEnded(entry, endedQueued.Value)
	elseif readyQueued.Value then self:_onReady(entry) end
	return true
end

function MusicClient:_finishOutgoing(outgoing: any?, releaseOutgoing: boolean)
	if outgoing == nil then return end
	self:_stopRetained(outgoing)
	if releaseOutgoing then self:_releaseEntry(outgoing) end
end

function MusicClient:_fadeOutOnly(outgoing: any?, transition: any)
	if outgoing == nil then
		self._incumbent = nil
		return
	end
	local wrapper = if self:_leaseActive(outgoing) then outgoing.Lease.Object else nil
	if wrapper == nil or transition.Strategy == "Instant" or transition.FadeOutSeconds <= 0 then
		self:_finishOutgoing(outgoing, true)
		self._incumbent = nil
		return
	end
	local startGain = wrapper._TransitionGain
	self._incumbent = outgoing
	self:_schedule(transition.FadeOutSeconds, function(alpha)
		if self:_leaseActive(outgoing) then wrapper:SetTransitionGain(startGain * (1 - alpha)) end
	end, function()
		self:_finishOutgoing(outgoing, true)
		self._incumbent = nil
	end)
end

function MusicClient:_fadeIn(incoming: any, seconds: number)
	if not incoming.Active or not incoming.Ready or not self:_leaseActive(incoming) then return end
	local wrapper = incoming.Lease.Object
	wrapper:SetTransitionGain(0)
	wrapper.Player:Play()
	self._incumbent = incoming
	self:_schedule(seconds, function(alpha)
		if incoming.Active and self:_leaseActive(incoming) then wrapper:SetTransitionGain(alpha) end
	end, function()
		if incoming.Active and self:_leaseActive(incoming) then wrapper:SetTransitionGain(1) end
	end)
end

function MusicClient:_transitionTo(incoming: any, transition: any, outgoing: any?, releaseOutgoing: boolean)
	if not incoming.Active or not incoming.Ready or not self:_leaseActive(incoming) then
		self:_finishOutgoing(outgoing, releaseOutgoing)
		return
	end
	if outgoing == incoming then
		local wrapper = incoming.Lease.Object
		wrapper:SetTransitionGain(1)
		wrapper.Player:Play()
		self._incumbent = incoming
		return
	end
	local incomingWrapper = incoming.Lease.Object
	local outgoingWrapper = if outgoing ~= nil and self:_leaseActive(outgoing) then outgoing.Lease.Object else nil
	if transition.Strategy == "Instant" then
		self:_finishOutgoing(outgoing, releaseOutgoing)
		incomingWrapper:SetTransitionGain(1)
		incomingWrapper.Player:Play()
		self._incumbent = incoming
		return
	end
	if transition.Strategy == "SequentialFade" and outgoingWrapper ~= nil then
		local outgoingStart = outgoingWrapper._TransitionGain
		self._incumbent = outgoing
		self:_schedule(transition.FadeOutSeconds, function(alpha)
			if self:_leaseActive(outgoing) then outgoingWrapper:SetTransitionGain(outgoingStart * (1 - alpha)) end
		end, function()
			self:_finishOutgoing(outgoing, releaseOutgoing)
			self:_fadeIn(incoming, transition.FadeInSeconds)
		end)
		return
	end
	if transition.Strategy == "Crossfade" and outgoingWrapper ~= nil then
		local outgoingStart = outgoingWrapper._TransitionGain
		incomingWrapper:SetTransitionGain(0)
		incomingWrapper.Player:Play()
		self._incumbent = incoming
		local duration = math.max(transition.FadeOutSeconds, transition.FadeInSeconds)
		self:_schedule(duration, function(alpha)
			local elapsed = duration * alpha
			local outAlpha = if transition.FadeOutSeconds == 0 then 1 else math.min(1, elapsed / transition.FadeOutSeconds)
			local inAlpha = if transition.FadeInSeconds == 0 then 1 else math.min(1, elapsed / transition.FadeInSeconds)
			if self:_leaseActive(outgoing) then outgoingWrapper:SetTransitionGain(outgoingStart * (1 - outAlpha)) end
			if incoming.Active and self:_leaseActive(incoming) then incomingWrapper:SetTransitionGain(inAlpha) end
		end, function()
			self:_finishOutgoing(outgoing, releaseOutgoing)
			if incoming.Active and self:_leaseActive(incoming) then incomingWrapper:SetTransitionGain(1) end
		end)
		return
	end
	self:_finishOutgoing(outgoing, releaseOutgoing)
	self:_fadeIn(incoming, transition.FadeInSeconds)
end

function MusicClient:_resumeStructuralTop(transition: any, outgoing: any?)
	local top = self._stack[#self._stack]
	if top == nil then
		if outgoing ~= nil and not outgoing.Active then
			self:_fadeOutOnly(outgoing, transition)
		else
			self:_finishOutgoing(outgoing, false)
			self._incumbent = nil
		end
		return
	end
	top.Transition = transition
	if top.Ready and self:_leaseActive(top) and not top.Lease.Object.Player.IsReady then
		self:_finishOutgoing(outgoing, outgoing ~= nil and not outgoing.Active)
		self:_onReadinessLost(top)
		return
	end
	if top.Ready and self:_leaseActive(top) then
		self:_transitionTo(top, transition, outgoing, outgoing ~= nil and not outgoing.Active)
	elseif outgoing ~= nil and not outgoing.Active then
		self:_releaseEntry(outgoing)
		self._incumbent = nil
	end
end

function MusicClient:_onReady(entry: any)
	if not entry.Active or not self:_leaseActive(entry) then return end
	entry.Ready = true
	self:_stopRetained(entry)
	if self._stack[#self._stack] ~= entry then return end
	local outgoing = self:_canonicalize()
	self:_transitionTo(entry, entry.Transition, outgoing, false)
end

function MusicClient:_onReadinessLost(entry: any)
	if not entry.Active or not self:_leaseActive(entry) then return end
	self:_cancelTransition()
	self:_stopRetained(entry)
	entry.Ready = false
	if self._incumbent == entry then self._incumbent = nil end
	local fallback = nil
	for index = #self._stack, 1, -1 do
		local candidate = self._stack[index]
		if candidate ~= entry and candidate.Active and candidate.Ready and self:_leaseActive(candidate) then
			fallback = candidate
			break
		end
	end
	for _, candidate in self._stack do
		if candidate ~= entry and candidate.Ready and self:_leaseActive(candidate) then
			if candidate == fallback then
				candidate.Lease.Object:SetTransitionGain(1)
				candidate.Lease.Object.Player:Play()
			else
				self:_stopRetained(candidate)
			end
		end
	end
	self._incumbent = fallback
	self:_advanceStackGeneration()
	self:_releaseLease(entry)
	if not self:_acquire(entry) then
		self:_canonicalize()
		self:_releaseEntry(entry)
		self:_resumeStructuralTop({ Strategy = "Instant", FadeOutSeconds = 0, FadeInSeconds = 0 }, self._incumbent)
	end
end

function MusicClient:_onEnded(entry: any, reason: string)
	if self._exiting[entry] then
		local wasIncumbent = self._incumbent == entry
		self:_canonicalize(entry)
		self:_releaseEntry(entry)
		if wasIncumbent or self._incumbent == nil then
			self:_resumeStructuralTop({ Strategy = "Instant", FadeOutSeconds = 0, FadeInSeconds = 0 }, nil)
		end
		return
	end
	if not entry.Active then return end
	if reason == "ReadinessLost" then self:_onReadinessLost(entry); return end
	local wasTop = self._stack[#self._stack] == entry
	local wasIncumbent = self._incumbent == entry
	self:_canonicalize(entry)
	self:_releaseEntry(entry)
	if wasTop then
		self:_resumeStructuralTop({ Strategy = "Instant", FadeOutSeconds = 0, FadeInSeconds = 0 }, nil)
	elseif wasIncumbent then
		self:_resumeStructuralTop({ Strategy = "Instant", FadeOutSeconds = 0, FadeInSeconds = 0 }, nil)
	end
end

function MusicClient:_stopEntry(entry: any, transition: any)
	if not entry.Active then return end
	local wasTop = self._stack[#self._stack] == entry
	local wasIncumbent = self._incumbent == entry
	self:_canonicalize()
	entry.Active = false
	self:_removeFromStack(entry)
	if not wasTop then
		self:_releaseLease(entry)
		if wasIncumbent then
			self._incumbent = nil
			self:_resumeStructuralTop(transition, nil)
		end
		return
	end
	if not wasIncumbent then
		self:_releaseLease(entry)
		local incumbent = self._incumbent
		if incumbent ~= nil and incumbent.Active and incumbent.Ready and self:_leaseActive(incumbent) then
			-- Removing a still-pending structural top must not restart or fade the
			-- already-audible lower incumbent.
			return
		end
		self:_resumeStructuralTop(transition, nil)
		return
	end
	self._exiting[entry] = true
	self:_resumeStructuralTop(transition, entry)
end

function MusicClient:PlayMusic(ref: any, options: any?, transitionValue: any?): any
	local transition = normalizeTransition(transitionValue)
	local normalizedOptions = normalizeOptions(options)
	if self._pool == nil or transition == nil or normalizedOptions == nil then return inert() end
	if #self._stack >= self._maxDepth then
		self._logger:Warn("MusicCapacity", {})
		return inert()
	end
	local variant = self._catalog:Resolve(ref)
	if variant == nil or variant.PlayerType ~= "Music" then return inert() end
	local typeConfig = self._graph.Config.PlayerTypes.Music
	local effectiveVolume = variant.SourceVolume * (normalizedOptions.VolumeMultiplier or 1)
	local effectiveSpeed = variant.PlaybackSpeed * (normalizedOptions.PlaybackSpeedMultiplier or 1)
	if effectiveVolume < typeConfig.SourceVolumeMin or effectiveVolume > typeConfig.SourceVolumeMax
		or effectiveSpeed < typeConfig.PlaybackSpeedMin or effectiveSpeed > typeConfig.PlaybackSpeedMax then return inert() end

	self._entryGeneration += 1
	local entry = {
		Active = true,
		Ready = false,
		EntryGeneration = self._entryGeneration,
		AcquisitionGeneration = 0,
		Variant = variant,
		Options = normalizedOptions,
		Transition = transition,
		SavedPosition = nil,
		Lease = nil,
	}
	table.insert(self._stack, entry)
	if not self:_acquire(entry) then
		self:_releaseEntry(entry)
		self._logger:Warn("MusicCapacity", {})
		return inert()
	end
	if entry.Active and not entry.Ready then self:_canonicalize() end
	return table.freeze({
		IsActive = function() return entry.Active end,
		Stop = function(_self, exitTransition)
			local normalized = normalizeTransition(exitTransition)
			if normalized ~= nil then self:_stopEntry(entry, normalized) end
		end,
	})
end

function MusicClient:StopAllMusic()
	self:_cancelTransition()
	self:_advanceStackGeneration()
	self._incumbent = nil
	local entries = table.clone(self._stack)
	for _, entry in entries do self:_releaseEntry(entry) end
	local exiting = table.clone(self._exiting)
	for entry in exiting do self:_releaseEntry(entry) end
end

return MusicClient
