--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TestHarness = require(script.Parent.TestHarness)
local PoolModule = require(ReplicatedStorage.Shared.Pooling.PoolModule)
local Wrapper = require(ReplicatedStorage.Shared.Audio.AudioPlaybackWrapper)
local OrdinaryPlaybackCore = require(ReplicatedStorage.Shared.Audio.OrdinaryPlaybackCore)
local OrdinarySoundClient = require(ReplicatedStorage.Client.Audio.OrdinarySoundClient)
local AudioGraphClient = require(ReplicatedStorage.Client.Audio.AudioGraphClient)
local MusicClient = require(ReplicatedStorage.Client.Audio.MusicClient)
local AudioConfigValidator = require(ReplicatedStorage.Shared.Audio.AudioConfigValidator)
local AudioCatalog = require(ReplicatedStorage.Shared.Audio.AudioCatalog)
local RuntimeConfig = require(ReplicatedStorage.Shared.Configs.Audio.AudioRuntimeConfig)
local RoutingConfig = require(ReplicatedStorage.Shared.Configs.Audio.RoutingConfig)
local SpatialProfiles = require(ReplicatedStorage.Shared.Configs.Audio.SpatialProfiles)
local SoundCatalog = require(ReplicatedStorage.Shared.Configs.Audio.SoundCatalog)
local OrdinarySoundServer = require(game.ServerScriptService.Modules.Audio.OrdinarySoundServer)

local Runner = {}

local function makeLogger(events: { any })
	return { Warn = function(_self, event, data) table.insert(events, { Event = event, Data = data }) end }
end

local function makeFakeWrapper(control: any, created: { any }): any
	local player = { TimePosition = 0, IsReady = false, IsPlaying = false, PlayCount = 0, StopCount = 0 }
	function player:Play() self.IsPlaying = true; self.PlayCount += 1 end
	function player:Stop() self.IsPlaying = false; self.StopCount += 1 end
	local wrapper = {
		Player = player,
		_TransitionGain = 1,
		Generation = 0,
		Context = nil,
		ReleaseCount = 0,
	}
	function wrapper:SetTransitionGain(gain) self._TransitionGain = gain end
	function wrapper:OnAcquire(context)
		if control.OnAcquire ~= nil then control.OnAcquire(self) end
		if control.FailAcquire then error("injected wrapper acquire failure") end
		self.Generation += 1
		self.Context = context
		self.Player.IsReady = control.AutoReady
		self.Player.IsPlaying = false
		self._TransitionGain = context.TransitionGain or 1
		if self.Player.IsReady and context.OnReady then context.OnReady(self.Generation) end
	end
	function wrapper:UpdateCallbacks(onReady, onEnded)
		if self.Context == nil then return end
		self.Context.OnReady = onReady
		self.Context.OnEnded = onEnded
	end
	function wrapper:OnRelease()
		self.Generation += 1
		self.ReleaseCount += 1
		self.Player:Stop()
		self.Player.IsReady = false
		self.Context = nil
		self._TransitionGain = 1
	end
	function wrapper:IsPoolableValid() return true end
	function wrapper:Destroy() self:OnRelease() end
	function wrapper:Ready()
		self.Player.IsReady = true
		local context = self.Context
		if context and context.OnReady then context.OnReady(self.Generation) end
	end
	function wrapper:End(reason)
		if reason == nil or reason == "Ended" then self.Player.IsPlaying = false end
		local context = self.Context
		if context and context.OnEnded then context.OnEnded(self.Generation, reason) end
	end
	table.insert(created, wrapper)
	return wrapper
end

local function makeTransitionDriver(jobs: { any })
	return function(duration, step, complete)
		if duration <= 0 then step(1); complete(); return function() end end
		local job = { Cancelled = false, Completed = false, Step = step, Complete = complete }
		table.insert(jobs, job)
		return function() job.Cancelled = true end
	end
end

local function makeSignal(): any
	local callbacks = {}
	return {
		Connect = function(_self, callback)
			table.insert(callbacks, callback)
			local connected = true
			return {
				Disconnect = function()
					if not connected then return end
					connected = false
					for index, current in callbacks do
						if current == callback then table.remove(callbacks, index); break end
					end
				end,
			}
		end,
		Fire = function(_self, ...)
			for _, callback in table.clone(callbacks) do callback(...) end
		end,
		GetConnectionCount = function()
			return #callbacks
		end,
	}
end

local function makeWrapperFactory(): (string) -> any
	return function(className)
		local object = { ClassName = className, Name = className, Parent = nil, Destroyed = false }
		function object:Destroy() self.Destroyed = true; self.Parent = nil end
		if className == "AudioPlayer" then
			object.Ended = makeSignal()
			object.IsReady = true
			object.TimeLength = 10
			object.IsPlaying = false
			function object:Play() self.IsPlaying = true end
			function object:Stop() self.IsPlaying = false end
		elseif className == "AudioEmitter" then
			object.DistanceAttenuation = nil
			object.AngleAttenuation = nil
			function object:SetDistanceAttenuation(curve) self.DistanceAttenuation = table.clone(curve) end
			function object:SetAngleAttenuation(curve) self.AngleAttenuation = table.clone(curve) end
		end
		return object
	end
end

local function finishNext(jobs: { any })
	for _, job in jobs do
		if not job.Cancelled and not job.Completed then
			job.Step(1)
			job.Completed = true
			job.Complete()
			return job
		end
	end
	error("No scheduled transition remained", 2)
end

local function invokeLate(job: any)
	job.Step(0.37)
	job.Complete()
end

local function makeMusicFixture(scope: any, maxDepth: number?): any
	local events = {}
	local jobs = {}
	local created = {}
	local control = { AutoReady = true }
	local pools = PoolModule.new()
	pools:Initialize()
	scope:Defer(function() pools:Destroy() end)
	local depth = maxDepth or 8
	local variant = {
		CueId = "Music.A",
		VariantId = "Default",
		ContentId = "rbxassetid://1",
		PlayerType = "Music",
		SourceVolume = 0.5,
		PlaybackSpeed = 1,
		Looping = true,
	}
	local catalog = {
		Resolve = function(_self, ref)
			if ref.CueId == "Missing" then return nil, "UnknownRef" end
			local result = table.clone(variant)
			result.CueId = ref.CueId
			return result
		end,
	}
	local graph = {
		Enabled = true,
		LocalRoot = {},
		Faders = { Music = {} },
		Config = {
			InteractionGroupId = "AudioPlayback.Private.v1",
			PlayerTypes = { Music = {
				ClientMaxActive = depth,
				ClientMaxRetained = math.min(2, depth),
				MusicStackMaxDepth = depth,
				SourceVolumeMin = 0,
				SourceVolumeMax = 1,
				PlaybackSpeedMin = 0.5,
				PlaybackSpeedMax = 2,
				LoadTimeoutSeconds = 15,
			} },
		},
	}
	local music = MusicClient.new(pools, makeLogger(events), {
		WrapperFactory = function() return makeFakeWrapper(control, created) end,
		TransitionDriver = makeTransitionDriver(jobs),
	})
	music:Initialize({ Enabled = true, Catalog = catalog, Config = graph.Config }, graph)
	scope:Defer(function() music:StopAllMusic() end)
	return { Music = music, Pool = pools:GetPool("Audio.Client.Music"), Events = events, Jobs = jobs, Created = created, Control = control }
end

local function makeTransitionPhase(scope: any, phase: string): any
	local fixture = makeMusicFixture(scope)
	local music = fixture.Music
	local a = music:PlayMusic({ CueId = "A" })
	local wa = music._stack[1].Lease.Object
	local strategy = if phase == "Crossfade" then "Crossfade" else "SequentialFade"
	local b = music:PlayMusic({ CueId = "B" }, nil, {
		Strategy = strategy,
		FadeOutSeconds = 1,
		FadeInSeconds = 1,
	})
	local wb = music._stack[2].Lease.Object
	if phase == "SequentialFadeIn" then
		finishNext(fixture.Jobs)
	elseif phase == "Crossfade" then
		fixture.Jobs[#fixture.Jobs].Step(0.5)
	end
	local currentJob = fixture.Jobs[#fixture.Jobs]
	assert(currentJob ~= nil and not currentJob.Completed and not currentJob.Cancelled)
	return {
		Fixture = fixture,
		Music = music,
		A = a,
		B = b,
		WA = wa,
		WB = wb,
		Job = currentJob,
	}
end

local function assertOnlyPlaying(fixture: any, expected: any?)
	for _, wrapper in fixture.Created do
		if wrapper.Context ~= nil then
			assert(wrapper.Player.IsPlaying == (wrapper == expected))
			assert(wrapper._TransitionGain == (if wrapper == expected then 1 else 0))
		end
	end
end

local function makeOrdinaryEvidenceFixture(scope: any, side: string, playerType: string, maximum: number): any
	local events = {}
	local created = {}
	local control = { AutoReady = true }
	local pools = PoolModule.new()
	pools:Initialize()
	scope:Defer(function() pools:Destroy() end)
	local record = {
		ServerMaxActive = if side == "Server" then maximum else 0,
		ServerMaxRetained = if side == "Server" then math.min(maximum, 1) else 0,
		ClientMaxActive = if side == "Client" then maximum else 0,
		ClientMaxRetained = if side == "Client" then math.min(maximum, 1) else 0,
		SourceVolumeMin = 0,
		SourceVolumeMax = 1,
		PlaybackSpeedMin = 0.5,
		PlaybackSpeedMax = 2,
		LoadTimeoutSeconds = 3,
	}
	local profile = { DistanceAttenuation = NumberSequence.new(1), AngleAttenuation = nil }
	local disabledRecord = {
		ServerMaxActive = 0, ServerMaxRetained = 0, ClientMaxActive = 0, ClientMaxRetained = 0,
		SourceVolumeMin = 0, SourceVolumeMax = 1, PlaybackSpeedMin = 0.5, PlaybackSpeedMax = 2,
		LoadTimeoutSeconds = 3,
	}
	local records = {
		UI = table.clone(disabledRecord),
		SFX = table.clone(disabledRecord),
		World = table.clone(disabledRecord),
	}
	records[playerType] = record
	local config = {
		InteractionGroupId = "AudioPlayback.Private.v1",
		PlayerTypes = records,
		SpatialProfilesById = { Default = profile },
	}
	local graph = {
		Enabled = true,
		LocalRoot = {},
		ServerPlayback = {},
		Faders = { [playerType] = {} },
		Config = config,
	}
	local spatialFrameDriver = makeSignal()
	local core = OrdinaryPlaybackCore.new(side, pools, makeLogger(events), {
		WrapperFactory = function() return makeFakeWrapper(control, created) end,
		Workspace = {},
		SpatialFrameDriver = spatialFrameDriver,
	})
	core:Initialize({ Enabled = true, Catalog = {}, Config = config }, graph)
	local variant = {
		CueId = "Evidence",
		VariantId = "Default",
		ContentId = "rbxassetid://1",
		SourceVolume = 0.5,
		PlaybackSpeed = 1,
		Looping = false,
		PlayerType = playerType,
		SpatialProfileId = if playerType == "World" then "Default" else nil,
	}
	return {
		Core = core,
		Pools = pools,
		Events = events,
		Created = created,
		Control = control,
		Graph = graph,
		Profile = profile,
		Variant = variant,
		Pool = pools:GetPool(`Audio.{side}.{playerType}`),
		SpatialFrameDriver = spatialFrameDriver,
	}
end

local function makeProductionWrapperFixture(scope: any, side: string, playerType: string, maximum: number): any
	local events = {}
	local workers = {}
	local created = {}
	local createdKinds = {}
	local pools = PoolModule.new()
	pools:Initialize()
	scope:Defer(function() pools:Destroy() end)
	local disabled = {
		ServerMaxActive = 0, ServerMaxRetained = 0, ClientMaxActive = 0, ClientMaxRetained = 0,
		SourceVolumeMin = 0, SourceVolumeMax = 1, PlaybackSpeedMin = 0.5, PlaybackSpeedMax = 2,
		LoadTimeoutSeconds = 3,
	}
	local records = { UI = table.clone(disabled), SFX = table.clone(disabled), World = table.clone(disabled) }
	records[playerType] = {
		ServerMaxActive = if side == "Server" then maximum else 0,
		ServerMaxRetained = if side == "Server" then math.min(maximum, 1) else 0,
		ClientMaxActive = if side == "Client" then maximum else 0,
		ClientMaxRetained = if side == "Client" then math.min(maximum, 1) else 0,
		SourceVolumeMin = 0, SourceVolumeMax = 1, PlaybackSpeedMin = 0.5, PlaybackSpeedMax = 2,
		LoadTimeoutSeconds = 3,
	}
	local profile = {
		AcousticSimulationEnabled = true,
		DistanceCurve = { { Distance = 0, Gain01 = 1 }, { Distance = 400, Gain01 = 0 } },
		AngleCurve = nil,
	}
	local config = {
		InteractionGroupId = "AudioPlayback.Private.v1",
		PlayerTypes = records,
		SpatialProfilesById = { Default = profile },
	}
	local graph = {
		Enabled = true,
		LocalRoot = {},
		ServerPlayback = {},
		Faders = { [playerType] = {} },
		Config = config,
	}
	local factory = makeWrapperFactory()
	local spatialFrameDriver = makeSignal()
	local injectedWorkspace = {}
	local core = OrdinaryPlaybackCore.new(side, pools, makeLogger(events), {
		WrapperFactory = function(kind)
			table.insert(createdKinds, kind)
			local wrapper = Wrapper.new(kind, { InstanceFactory = factory })
			table.insert(created, wrapper)
			return wrapper
		end,
		Spawn = function(callback) table.insert(workers, callback) end,
		Workspace = injectedWorkspace,
		SpatialFrameDriver = spatialFrameDriver,
	})
	local variant = {
		CueId = "Evidence", VariantId = "Default", ContentId = "rbxassetid://1",
		SourceVolume = 0.5, PlaybackSpeed = 1, Looping = false, PlayerType = playerType,
		SpatialProfileId = if playerType == "World" then "Default" else nil,
	}
	local catalog = {
		Resolve = function() return variant end,
		GetNamedVariant = function() return variant end,
	}
	core:Initialize({ Enabled = true, Catalog = catalog, Config = config }, graph)
	return {
		Core = core, Pools = pools, Pool = pools:GetPool(`Audio.{side}.{playerType}`),
		Created = created, CreatedKinds = createdKinds, Workers = workers, Events = events, Graph = graph, Profile = profile,
		Variant = variant, Catalog = catalog, Config = config,
		SpatialFrameDriver = spatialFrameDriver, Workspace = injectedWorkspace,
	}
end

local function poolStatsUnchanged(before: any, after: any): boolean
	return after.Active == before.Active
		and after.Available == before.Available
		and after.Created == before.Created
		and after.Acquired == before.Acquired
		and after.Released == before.Released
		and after.Destroyed == before.Destroyed
end

local function makePublicOrdinaryService(scope: any, side: string, looping: boolean): any
	local events = {}
	local created = {}
	local workers = {}
	local pools = PoolModule.new()
	pools:Initialize()
	scope:Defer(function() pools:Destroy() end)
	local record = {
		ServerMaxActive = if side == "Server" then 2 else 0,
		ServerMaxRetained = if side == "Server" then 1 else 0,
		ClientMaxActive = if side == "Client" then 2 else 0,
		ClientMaxRetained = if side == "Client" then 1 else 0,
		HybridRatePerSecond = 2, HybridBurst = 2,
		SourceVolumeMin = 0, SourceVolumeMax = 1,
		PlaybackSpeedMin = 0.5, PlaybackSpeedMax = 2, LoadTimeoutSeconds = 3,
	}
	local disabled = table.clone(record)
	disabled.ServerMaxActive = 0; disabled.ServerMaxRetained = 0
	disabled.ClientMaxActive = 0; disabled.ClientMaxRetained = 0
	local config = {
		InteractionGroupId = "AudioPlayback.Private.v1",
		PlayerTypes = { UI = table.clone(disabled), SFX = record, World = table.clone(disabled) },
		SpatialProfilesById = {},
	}
	local variant = {
		CueId = "Loop", VariantId = "Default", ContentId = "rbxassetid://1", PlayerType = "SFX",
		SourceVolume = 0.5, PlaybackSpeed = 1, Looping = looping, AllowClientHybrid = true,
	}
	local catalog = {
		Resolve = function() return variant end,
		GetNamedVariant = function() return variant end,
	}
	local graph = {
		Enabled = true, LocalRoot = {}, ServerPlayback = {}, Faders = { SFX = {} }, Config = config,
	}
	local factory = makeWrapperFactory()
	local dependencies = {
		WrapperFactory = function(kind)
			local wrapper = Wrapper.new(kind, { InstanceFactory = factory })
			table.insert(created, wrapper)
			return wrapper
		end,
		Spawn = function(callback) table.insert(workers, callback) end,
	}
	local fanoutCalls = 0
	dependencies.Communication = {
		QueuePresentationAtomic = function()
			fanoutCalls += 1
			return true
		end,
	}
	local service = if side == "Server"
		then OrdinarySoundServer.new(pools, makeLogger(events), dependencies)
		else OrdinarySoundClient.new(pools, makeLogger(events), dependencies)
	service:Initialize({ Enabled = true, Catalog = catalog, Config = config }, graph)
	return {
		Service = service, Pools = pools, Pool = pools:GetPool(`Audio.{side}.SFX`), Events = events,
		Created = created, Workers = workers, Variant = variant, GetFanoutCalls = function() return fanoutCalls end,
	}
end

function Runner.runAll()
	local tests = {}
	local function test(name, callback) table.insert(tests, { Name = name, Callback = callback }) end

	test("AudioPlayback/WrapperResetAndStaleReadinessCancellation", function(scope)
		local parent = scope:Track(Instance.new("Folder"))
		local fader = scope:Track(Instance.new("AudioFader"))
		local workers = {}
		local ended = 0
		local wrapper = Wrapper.new("SFX", { Spawn = function(callback) table.insert(workers, callback) end })
		scope:Defer(function() wrapper:Destroy() end)
		wrapper:OnAcquire({
			Variant = { ContentId = "rbxassetid://9112854440", SourceVolume = 0.5, PlaybackSpeed = 1, Looping = false, PlayerType = "SFX" },
			Parent = parent,
			Fader = fader,
			InteractionGroupId = "AudioPlayback.Private.v1",
			OnEnded = function() ended += 1 end,
			Spawn = function(callback) table.insert(workers, callback) end,
		})
		assert(wrapper.Player.Volume == 0.5 and wrapper.Root.Parent == parent and wrapper.Wire.TargetInstance == fader)
		wrapper:OnRelease()
		assert(wrapper.Root.Parent == nil and wrapper.Wire.SourceInstance == nil and not wrapper.Player.IsPlaying)
		assert(wrapper.Player.Volume == 1 and wrapper.Player.PlaybackSpeed == 1 and wrapper.Player.TimePosition == 0)
		for _, worker in workers do worker() end
		assert(ended == 0, "released readiness workers must be generation-cancelled")
	end)

	test("AudioPlayback/WrapperEffectiveRegionsAndReadinessLoss", function(scope)
		local workers = {}
		local endedReasons = {}
		local wrapper = Wrapper.new("SFX", {
			InstanceFactory = makeWrapperFactory(),
			Spawn = function(callback) table.insert(workers, callback) end,
		})
		scope:Defer(function() wrapper:Destroy() end)
		wrapper:OnAcquire({
			Variant = {
				ContentId = "rbxassetid://1",
				SourceVolume = 0.5,
				PlaybackSpeed = 1,
				Looping = true,
				PlayerType = "SFX",
				PlaybackRegion = { Start = 2, End = 12 },
				LoopRegion = { Start = 1, End = 11 },
			},
			Parent = {},
			Fader = {},
			InteractionGroupId = "AudioPlayback.Private.v1",
			TimePosition = 11,
			ReadinessWait = function() coroutine.yield() end,
			OnEnded = function(_generation, reason) table.insert(endedReasons, reason) end,
			Spawn = function(callback) table.insert(workers, callback) end,
		})
		assert(#workers == 1)
		local readinessThread = coroutine.create(workers[1])
		assert(coroutine.resume(readinessThread))
		assert(wrapper.Player.IsPlaying)
		assert(wrapper.Player.PlaybackRegion == NumberRange.new(2, 10))
		assert(wrapper.Player.LoopRegion == NumberRange.new(2, 10), "invalid loop region must fall back to effective playback")
		assert(wrapper.Player.TimePosition == 10, "start time must clamp after duration becomes available")
		wrapper.Player.IsReady = false
		assert(coroutine.resume(readinessThread))
		assert(endedReasons[1] == "ReadinessLost")
	end)

	test("AudioPlayback/PendingReadyBeforeTimeoutStarts", function(scope)
		local workers = {}
		local now = 0
		local playCount = 0
		local wrapper = Wrapper.new("SFX", {
			InstanceFactory = makeWrapperFactory(),
			Spawn = function(callback) table.insert(workers, callback) end,
		})
		scope:Defer(function() wrapper:Destroy() end)
		wrapper.Player.IsReady = false
		wrapper.Player.Play = function(player) playCount += 1; player.IsPlaying = true end
		wrapper:OnAcquire({
			Variant = { ContentId = "rbxassetid://1", SourceVolume = 0.5, PlaybackSpeed = 1, Looping = false, PlayerType = "SFX" },
			Parent = {}, Fader = {}, InteractionGroupId = "AudioPlayback.Private.v1",
			LoadTimeoutSeconds = 3, Clock = function() return now end,
			ReadinessWait = function() coroutine.yield() end,
			Spawn = function(callback) table.insert(workers, callback) end,
		})
		local thread = coroutine.create(workers[1])
		assert(coroutine.resume(thread) and playCount == 0)
		now = 1; wrapper.Player.IsReady = true
		assert(coroutine.resume(thread) and playCount == 1 and wrapper.Player.IsPlaying)
		wrapper:OnRelease()
		assert(coroutine.resume(thread) and playCount == 1 and not wrapper.Player.IsPlaying)
	end)

	test("AudioPlayback/PendingStopBeforeReadyCleanup", function(scope)
		local workers = {}
		local ended = 0
		local playCount = 0
		local wrapper = Wrapper.new("SFX", {
			InstanceFactory = makeWrapperFactory(),
			Spawn = function(callback) table.insert(workers, callback) end,
		})
		scope:Defer(function() wrapper:Destroy() end)
		wrapper.Player.IsReady = false
		wrapper.Player.Play = function(player) playCount += 1; player.IsPlaying = true end
		wrapper:OnAcquire({
			Variant = { ContentId = "rbxassetid://1", SourceVolume = 0.5, PlaybackSpeed = 1, Looping = false, PlayerType = "SFX" },
			Parent = {}, Fader = {}, InteractionGroupId = "AudioPlayback.Private.v1",
			LoadTimeoutSeconds = 3, OnEnded = function() ended += 1 end,
			Spawn = function(callback) table.insert(workers, callback) end,
		})
		wrapper:OnRelease()
		workers[1]()
		assert(playCount == 0 and ended == 0 and wrapper.Root.Parent == nil
			and wrapper.Wire.SourceInstance == nil and wrapper.Wire.TargetInstance == nil)
	end)

	test("AudioPlayback/PendingLoadTimeoutCleanup", function(scope)
		local workers = {}
		local now = 0
		local reasons = {}
		local wrapper = Wrapper.new("SFX", {
			InstanceFactory = makeWrapperFactory(),
			Spawn = function(callback) table.insert(workers, callback) end,
		})
		scope:Defer(function() wrapper:Destroy() end)
		wrapper.Player.IsReady = false
		wrapper:OnAcquire({
			Variant = { ContentId = "rbxassetid://1", SourceVolume = 0.5, PlaybackSpeed = 1, Looping = false, PlayerType = "SFX" },
			Parent = {}, Fader = {}, InteractionGroupId = "AudioPlayback.Private.v1",
			LoadTimeoutSeconds = 3, Clock = function() return now end,
			ReadinessWait = function() now = 4 end,
			OnEnded = function(_generation, reason)
				table.insert(reasons, reason)
				wrapper:OnRelease()
			end,
			Spawn = function(callback) table.insert(workers, callback) end,
		})
		workers[1]()
		assert(#reasons == 1 and reasons[1] == "LoadTimeout" and not wrapper.Player.IsPlaying
			and wrapper.Root.Parent == nil and wrapper.Wire.SourceInstance == nil)
	end)

	test("AudioPlayback/ActiveReadinessLossReleasesWithoutEnded", function(scope)
		local workers = {}
		local reasons = {}
		local wrapper = Wrapper.new("SFX", {
			InstanceFactory = makeWrapperFactory(),
			Spawn = function(callback) table.insert(workers, callback) end,
		})
		scope:Defer(function() wrapper:Destroy() end)
		wrapper:OnAcquire({
			Variant = { ContentId = "rbxassetid://1", SourceVolume = 0.5, PlaybackSpeed = 1, Looping = true, PlayerType = "SFX" },
			Parent = {}, Fader = {}, InteractionGroupId = "AudioPlayback.Private.v1",
			ReadinessWait = function() coroutine.yield() end,
			OnEnded = function(_generation, reason)
				table.insert(reasons, reason)
				wrapper:OnRelease()
			end,
			Spawn = function(callback) table.insert(workers, callback) end,
		})
		local thread = coroutine.create(workers[1])
		assert(coroutine.resume(thread) and wrapper.Player.IsPlaying)
		wrapper.Player.IsReady = false
		assert(coroutine.resume(thread))
		assert(#reasons == 1 and reasons[1] == "ReadinessLost" and wrapper.Root.Parent == nil
			and wrapper.Wire.SourceInstance == nil and not wrapper.Player.IsPlaying)
		wrapper.Player.Ended:Fire()
		assert(#reasons == 1, "a later Ended callback must remain inert after readiness-loss release")
	end)

	test("AudioPlayback/ResolvedVariantAssetAndPlayerType", function(scope)
		local fixture = makeProductionWrapperFixture(scope, "Client", "SFX", 1)
		local handle = assert(fixture.Core:ResolveAndPlay({ CueId = "Evidence", VariantId = "Default" }, nil, nil))
		assert(handle:IsActive() and fixture.Created[1].Player.Asset == fixture.Variant.ContentId
			and fixture.CreatedKinds[1] == "SFX"
			and fixture.Pool:GetStats().Active == 1)
		handle:Stop()
	end)

	test("AudioPlayback/UnknownIdentifierNoAcquire", function(scope)
		local fixture = makeProductionWrapperFixture(scope, "Client", "SFX", 1)
		fixture.Catalog.Resolve = function() return nil, "UnknownRef" end
		local handle, reason = fixture.Core:ResolveAndPlay({ CueId = "Missing" }, nil, nil)
		assert(handle == nil and reason == "UnknownRef" and #fixture.Created == 0
			and fixture.Pool:GetStats().Active == 0 and fixture.Pool:GetStats().Created == 0)
	end)

	test("AudioPlayback/PerPlayOverridesIsolated", function(scope)
		local fixture = makeProductionWrapperFixture(scope, "Client", "SFX", 2)
		local first = assert(fixture.Core:PlayVariant(fixture.Variant, nil, {
			VolumeMultiplier = 0.5, PlaybackSpeedMultiplier = 0.5, TimePosition = 2,
		}))
		local second = assert(fixture.Core:PlayVariant(fixture.Variant, nil, {
			VolumeMultiplier = 2, PlaybackSpeedMultiplier = 2, TimePosition = 4,
		}))
		assert(fixture.Created[1].Player.Volume == 0.25 and fixture.Created[1].Player.PlaybackSpeed == 0.5
			and fixture.Created[1].Player.TimePosition == 2)
		assert(fixture.Created[2].Player.Volume == 1 and fixture.Created[2].Player.PlaybackSpeed == 2
			and fixture.Created[2].Player.TimePosition == 4)
		assert(fixture.Variant.SourceVolume == 0.5 and fixture.Variant.PlaybackSpeed == 1)
		first:Stop(); second:Stop()
	end)

	test("AudioPlayback/PerPlayEffectiveRangeRejectedBeforeAcquire", function(scope)
		local client = makePublicOrdinaryService(scope, "Client", false)
		client.Variant.SourceVolume = 0.8
		local clientBefore = client.Pool:GetStats()
		local handle = client.Service:PlayLocal({ CueId = "Loop" }, { VolumeMultiplier = 2 })
		local clientAfter = client.Pool:GetStats()
		assert(not handle:IsActive() and #client.Created == 0 and poolStatsUnchanged(clientBefore, clientAfter))
		assert(#client.Events == 1 and client.Events[1].Event == "PlaybackRejected"
			and client.Events[1].Data.ReasonCode == "TypeMismatch",
			"effective-range rejection must emit exactly one TypeMismatch diagnostic")

		local server = makePublicOrdinaryService(scope, "Server", false)
		server.Variant.SourceVolume = 0.8
		local serverBefore = server.Pool:GetStats()
		local result = server.Service:Play({ CueId = "Loop" }, { VolumeMultiplier = 2 })
		local serverAfter = server.Pool:GetStats()
		assert(not result.Accepted and result.ReasonCode == "TypeMismatch"
			and #server.Created == 0 and poolStatsUnchanged(serverBefore, serverAfter))
	end)

	test("AudioPlayback/ForbiddenCatalogOverrideFieldsRejected", function(scope)
		local client = makePublicOrdinaryService(scope, "Client", false)
		local server = makePublicOrdinaryService(scope, "Server", false)
		local clientBefore = client.Pool:GetStats()
		local serverBefore = server.Pool:GetStats()
		for index, options in {
			{ SourceVolume = 0.1 }, { PlayerType = "UI" }, { Bus = "UI" },
			{ MaxActive = 99 }, { Preload = false }, { Source = {} },
		} do
			local handle = client.Service:PlayLocal({ CueId = "Loop" }, options)
			assert(not handle:IsActive() and #client.Events == index
				and client.Events[index].Event == "PlaybackRejected"
				and client.Events[index].Data.ReasonCode == "TypeMismatch",
				"each forbidden client override must emit exactly one TypeMismatch diagnostic")
			local result = server.Service:Play({ CueId = "Loop" }, options)
			assert(not result.Accepted and result.ReasonCode == "TypeMismatch")
		end
		local catalogOverrideDiagnosticCount = #client.Events
		for index, options in {
			{ Typo = 1 },
			{ [1] = 0.5 },
			{ VolumeMultiplier = 1, Typo = 1 },
		} do
			local handle = client.Service:PlayLocal({ CueId = "Loop" }, options)
			local diagnosticIndex = catalogOverrideDiagnosticCount + index
			assert(not handle:IsActive() and #client.Events == diagnosticIndex
				and client.Events[diagnosticIndex].Event == "PlaybackRejected"
				and client.Events[diagnosticIndex].Data.ReasonCode == "InvalidRequest",
				"each unrelated malformed option key must emit exactly one InvalidRequest diagnostic")
			local result = server.Service:Play({ CueId = "Loop" }, options)
			assert(not result.Accepted and result.ReasonCode == "InvalidRequest")
		end
		assert(#client.Created == 0 and poolStatsUnchanged(clientBefore, client.Pool:GetStats()))
		assert(#server.Created == 0 and poolStatsUnchanged(serverBefore, server.Pool:GetStats()))
	end)

	test("AudioPlayback/MusicStopAudibleIncumbentUnderPendingTop", function(scope)
		local fixture = makeMusicFixture(scope)
		local incumbent = fixture.Music:PlayMusic({ CueId = "A" })
		local incumbentWrapper = fixture.Created[1]
		fixture.Control.AutoReady = false
		local pending = fixture.Music:PlayMusic({ CueId = "B" })
		local pendingWrapper = fixture.Created[2]
		assert(incumbent:IsActive() and pending:IsActive() and incumbentWrapper.Player.IsPlaying
			and not pendingWrapper.Player.IsPlaying)
		incumbent:Stop()
		assert(not incumbent:IsActive() and pending:IsActive() and not pendingWrapper.Player.IsPlaying
			and fixture.Pool:GetStats().Active == 1)
		pendingWrapper:Ready()
		assert(pending:IsActive() and pendingWrapper.Player.IsPlaying and fixture.Pool:GetStats().Active == 1)
	end)

	test("AudioPlayback/OrdinaryFifoValidationBeforeMutation", function(scope)
		local events = {}
		local created = {}
		local control = { AutoReady = true }
		local pools = PoolModule.new(); pools:Initialize(); scope:Defer(function() pools:Destroy() end)
		local core = OrdinaryPlaybackCore.new("Client", pools, makeLogger(events), {
			WrapperFactory = function() return makeFakeWrapper(control, created) end,
		})
		local records = {
			UI = { ClientMaxActive = 0, ClientMaxRetained = 0 },
			SFX = { ClientMaxActive = 2, ClientMaxRetained = 1, SourceVolumeMin = 0, SourceVolumeMax = 1, PlaybackSpeedMin = 0.5, PlaybackSpeedMax = 2, LoadTimeoutSeconds = 3 },
			World = { ClientMaxActive = 0, ClientMaxRetained = 0 },
		}
		local graph = { Enabled = true, LocalRoot = {}, Faders = { SFX = {} }, Config = { InteractionGroupId = "AudioPlayback.Private.v1", PlayerTypes = records, SpatialProfilesById = {} } }
		core:Initialize({ Enabled = true, Catalog = {}, Config = graph.Config }, graph)
		local variant = { ContentId = "rbxassetid://1", SourceVolume = 0.5, PlaybackSpeed = 1, Looping = false, PlayerType = "SFX", PlaybackRegion = { Start = 2, End = 5 } }
		local first = assert(core:PlayVariant(variant, nil, nil))
		local second = assert(core:PlayVariant(variant, nil, nil))
		local rejected, reason = core:PlayVariant(variant, nil, { TimePosition = 5 })
		assert(rejected == nil and reason == "InvalidRegion" and first:IsActive() and second:IsActive())
		assert(pools:GetPool("Audio.Client.SFX"):GetStats().Active == 2)
		local highestObserved = 0
		control.OnAcquire = function()
			highestObserved = math.max(highestObserved, pools:GetPool("Audio.Client.SFX"):GetStats().Active)
			assert(not first:IsActive(), "FIFO oldest must be fully released before adapter acquisition")
		end
		control.FailAcquire = true
		local failed, failureReason = core:PlayVariant(variant, nil, { TimePosition = 3 })
		assert(failed == nil and failureReason == "AcquireFailed" and not first:IsActive() and second:IsActive())
		assert(pools:GetPool("Audio.Client.SFX"):GetStats().Active == 1 and highestObserved <= 2)
		control.FailAcquire = false
		local third = assert(core:PlayVariant(variant, nil, { TimePosition = 3 }))
		assert(not first:IsActive() and second:IsActive() and third:IsActive() and highestObserved <= 2)
		second:Stop(); third:Stop()
	end)

	test("AudioPlayback/OrdinaryInitializationFailureAtomic", function()
		local created = 0
		local removed = {}
		local registryInitialized = 0
		local registryDestroyed = 0
		local fakePools = {
			CreatePoolablePool = function(_self, id)
				created += 1
				if created == 2 then error("injected second pool failure") end
				return { Id = id }
			end,
			RemovePool = function(_self, id) table.insert(removed, id); return true end,
		}
		local core = OrdinaryPlaybackCore.new("Client", fakePools, makeLogger({}), {
			Workspace = {},
			SpatialFrameDriver = makeSignal(),
			SpatialRegistryFactory = {
				new = function()
					return {
						Initialize = function() registryInitialized += 1 end,
						Destroy = function() registryDestroyed += 1 end,
					}
				end,
			},
		})
		local records = {}
		for _, id in { "UI", "SFX", "World" } do records[id] = { ClientMaxActive = 1, ClientMaxRetained = 0 } end
		local graph = { Enabled = true, Config = { PlayerTypes = records } }
		core:Initialize({ Enabled = true, Catalog = {}, Config = graph.Config }, graph)
		assert(created == 2 and #removed == 1 and removed[1] == "Audio.Client.UI")
		assert(not core._enabled and next(core._pools) == nil
			and registryInitialized == 1 and registryDestroyed == 1)
		core:Initialize({ Enabled = true, Catalog = {}, Config = graph.Config }, graph)
		assert(created == 2, "memoized fail-soft result must not duplicate pools")
	end)

	test("AudioPlayback/MusicTransitionMutationMatrix", function(scope)
		for _, phase in { "SequentialFadeOut", "SequentialFadeIn", "Crossfade" } do
			local pushed = makeTransitionPhase(scope, phase)
			local c = pushed.Music:PlayMusic({ CueId = "C" })
			local wc = pushed.Music._stack[#pushed.Music._stack].Lease.Object
			assert(c:IsActive() and pushed.Job.Cancelled)
			assertOnlyPlaying(pushed.Fixture, wc)
			invokeLate(pushed.Job)
			assertOnlyPlaying(pushed.Fixture, wc)

			for _, role in { "Outgoing", "Incoming" } do
				local stopped = makeTransitionPhase(scope, phase)
				local stoppedHandle = if role == "Outgoing" then stopped.A else stopped.B
				local survivor = if role == "Outgoing" then stopped.WB else stopped.WA
				stoppedHandle:Stop()
				assert(not stoppedHandle:IsActive() and stopped.Job.Cancelled)
				assertOnlyPlaying(stopped.Fixture, survivor)
				invokeLate(stopped.Job)
				assertOnlyPlaying(stopped.Fixture, survivor)
			end

			local endedRoles = if phase == "Crossfade" then { "Outgoing", "Incoming" }
				elseif phase == "SequentialFadeOut" then { "Outgoing" }
				else { "Incoming" }
			for _, role in endedRoles do
				local ended = makeTransitionPhase(scope, phase)
				local endedHandle = if role == "Outgoing" then ended.A else ended.B
				local endedWrapper = if role == "Outgoing" then ended.WA else ended.WB
				local survivor = if role == "Outgoing" then ended.WB else ended.WA
				local playCount = endedWrapper.Player.PlayCount
				endedWrapper:End("Ended")
				assert(not endedHandle:IsActive() and ended.Job.Cancelled)
				assert(endedWrapper.Player.PlayCount == playCount, "natural end must not replay the ended incumbent during rebase")
				assertOnlyPlaying(ended.Fixture, survivor)
				invokeLate(ended.Job)
				assertOnlyPlaying(ended.Fixture, survivor)
			end
		end
	end)

	test("AudioPlayback/MusicReadinessLossPreRebase", function(scope)
		for _, phase in { "SequentialFadeOut", "SequentialFadeIn", "Crossfade" } do
			for _, role in { "Outgoing", "Incoming" } do
				local state = makeTransitionPhase(scope, phase)
				state.Fixture.Control.AutoReady = false
				local affected = if role == "Outgoing" then state.WA else state.WB
				local fallback = if role == "Outgoing" then state.WB else state.WA
				affected.Player.IsReady = false
				affected:End("ReadinessLost")
				assert(state.Job.Cancelled and state.Fixture.Pool:GetStats().Active == 2)
				assertOnlyPlaying(state.Fixture, fallback)
				invokeLate(state.Job)
				assertOnlyPlaying(state.Fixture, fallback)
			end
		end
	end)

	test("AudioPlayback/MusicResumeReloadPosition", function(scope)
		local fixture = makeMusicFixture(scope)
		local options = {
			VolumeMultiplier = 0.8,
			PlaybackSpeedMultiplier = 1.25,
			TimePosition = 4,
		}
		local handle = fixture.Music:PlayMusic({ CueId = "A" }, options)
		assert(handle:IsActive())
		local wrapper = fixture.Created[1]
		assert(wrapper.Context.VolumeMultiplier == 0.8)
		assert(wrapper.Context.PlaybackSpeedMultiplier == 1.25)
		assert(wrapper.Context.TimePosition == 4)

		options.VolumeMultiplier = 100
		options.PlaybackSpeedMultiplier = 100
		options.TimePosition = 1e9
		assert(fixture.Music._stack[1].Options.VolumeMultiplier == 0.8)
		assert(fixture.Music._stack[1].Options.PlaybackSpeedMultiplier == 1.25)
		assert(fixture.Music._stack[1].Options.TimePosition == 4)
		assert(table.isfrozen(fixture.Music._stack[1].Options),
			"accepted PlayOptions must be retained as an immutable private snapshot")

		fixture.Control.AutoReady = false
		wrapper.Player.TimePosition = 4.5
		wrapper.Player.IsReady = false
		wrapper:End("ReadinessLost")
		local reloaded = fixture.Music._stack[1].Lease.Object
		assert(reloaded.Context.VolumeMultiplier == 0.8)
		assert(reloaded.Context.PlaybackSpeedMultiplier == 1.25)
		assert(reloaded.Context.TimePosition == 4.5,
			"readiness reload must restore the bounded saved position without consulting caller-owned options")
	end)

	test("AudioPlayback/MusicStopAllDuringEveryPhase", function(scope)
		for _, phase in { "SequentialFadeOut", "SequentialFadeIn", "Crossfade" } do
			local state = makeTransitionPhase(scope, phase)
			state.Music:StopAllMusic()
			assert(state.Job.Cancelled and not state.A:IsActive() and not state.B:IsActive())
			assert(state.Fixture.Pool:GetStats().Active == 0)
			for _, wrapper in state.Fixture.Created do assert(not wrapper.Player.IsPlaying) end
			invokeLate(state.Job)
			assert(state.Fixture.Pool:GetStats().Active == 0)
			for _, wrapper in state.Fixture.Created do assert(not wrapper.Player.IsPlaying) end
		end
	end)

	test("AudioPlayback/MusicPendingIncumbentEndAndReadinessRecovery", function(scope)
		local fixture = makeMusicFixture(scope)
		local music = fixture.Music
		local a = music:PlayMusic({ CueId = "A" })
		local wa = fixture.Created[1]
		fixture.Control.AutoReady = false
		local b = music:PlayMusic({ CueId = "B" })
		local wb = fixture.Created[2]
		assert(wa.Player.IsPlaying and not wb.Player.IsPlaying and b:IsActive())
		wa:End("Ended")
		assert(not a:IsActive() and b:IsActive() and not wb.Player.IsPlaying)
		wb:Ready()
		assert(wb.Player.IsPlaying)
		fixture.Control.AutoReady = true
		local c = music:PlayMusic({ CueId = "C" }, nil, { Strategy = "Crossfade", FadeOutSeconds = 1, FadeInSeconds = 1 })
		local wc = music._stack[#music._stack].Lease.Object
		assert(wb.Player.IsPlaying and wc.Player.IsPlaying)
		fixture.Control.AutoReady = false
		wc:End("ReadinessLost")
		assert(wb.Player.IsPlaying and not wc.Player.IsPlaying and c:IsActive())
		wc:Ready()
		assert(wb.Player.IsPlaying and wc.Player.IsPlaying)
		music:StopAllMusic()
		assert(not b:IsActive() and not c:IsActive() and fixture.Pool:GetStats().Active == 0)
		for _, wrapper in fixture.Created do assert(not wrapper.Player.IsPlaying) end
	end)

	test("AudioPlayback/MusicCapacityRejectsWithoutMutation", function(scope)
		local fixture = makeMusicFixture(scope, 2)
		local music = fixture.Music
		local a = music:PlayMusic({ CueId = "A" })
		local b = music:PlayMusic({ CueId = "B" })
		local beforeGeneration = music._stackGeneration
		local beforeScheduler = music._schedulerGeneration
		local c = music:PlayMusic({ CueId = "C" })
		assert(not c:IsActive() and a:IsActive() and b:IsActive())
		assert(music._stackGeneration == beforeGeneration and music._schedulerGeneration == beforeScheduler)
		assert(fixture.Pool:GetStats().Active == 2 and fixture.Events[#fixture.Events].Event == "MusicCapacity")
	end)

	test("AudioPlayback/MusicStackGenerationAndExitSemantics", function(scope)
		local fixture = makeMusicFixture(scope)
		local music = fixture.Music
		local a = music:PlayMusic({ CueId = "A" })
		local wa = fixture.Created[1]
		local staleReady = wa.Context.OnReady
		local staleEnded = wa.Context.OnEnded
		fixture.Control.AutoReady = false
		local b = music:PlayMusic({ CueId = "B" })
		local wb = fixture.Created[2]
		local incumbentPlayCount = wa.Player.PlayCount
		local incumbentStopCount = wa.Player.StopCount
		staleReady(wa.Generation)
		staleEnded(wa.Generation, "Ended")
		assert(a:IsActive() and b:IsActive(), "old stack-generation callback must be inert")
		assert(wa.Player.StopCount == incumbentStopCount, "old readiness callback must not mutate retained playback")
		b:Stop({ Strategy = "SequentialFade", FadeOutSeconds = 1, FadeInSeconds = 1 })
		assert(not b:IsActive() and a:IsActive() and wa.Player.IsPlaying and wa._TransitionGain == 1)
		assert(wa.Player.PlayCount == incumbentPlayCount, "pending-top exit must not replay the incumbent")
		assert(not wb.Player.IsPlaying)
		a:Stop({ Strategy = "SequentialFade", FadeOutSeconds = 1, FadeInSeconds = 1 })
		assert(not a:IsActive() and fixture.Pool:GetStats().Active == 1 and wa.Player.IsPlaying)
		finishNext(fixture.Jobs)
		assert(fixture.Pool:GetStats().Active == 0 and not wa.Player.IsPlaying)
	end)

	local ordinaryEvidenceIdentities = {
		"AudioPlayback/PointRejectsDirectionalProfile",
		"AudioPlayback/OrdinaryFifoBudget",
		"AudioPlayback/ServerOneLeaseNoFanout",
		"AudioPlayback/OrdinaryFifoNPlusOne",
		"AudioPlayback/CatalogDefaultsApplied",
		"AudioPlayback/AttachedTargetRemoval",
		"AudioPlayback/WrapperResetAcrossAssets",
		"AudioPlayback/SourceVolume01",
		"AudioPlayback/RegionAbsentAndValid",
		"AudioPlayback/RegionClampAfterReady",
		"AudioPlayback/InvalidLoopUsesEffectivePlaybackRegion",
		"AudioPlayback/LoopRegionIgnoredWhenNotLooping",
		"AudioPlayback/PublicPlayNeverYields",
		"AudioPlayback/PendingOccupiesActiveSlot",
		"AudioPlayback/ClientFailSoftHandle",
		"AudioPlayback/MusicOrdinaryTypeSeparation",
		"AudioPlayback/ConcurrentWorldPositions",
		"AudioPlayback/ServerLoopLeaseLifetime",
		"AudioPlayback/ServerWorldWrapperIsolation",
		"AudioPlayback/ServerWrapperFullReset",
		"AudioPlayback/StaleServerEndedGeneration",
		"AudioPlayback/SpatialCurveBoundaryMatrix",
		"AudioPlayback/InvalidProfileVariantIsolation",
		"AudioPlayback/ListenerEnabledOnceEmitterProfileIsolation",
		"AudioPlayback/DirectionalPointAttachedSplit",
		"AudioPlayback/LoopedDeliveryMatrix",
		"AudioPlayback/SpatialAnchorFixedComposition",
		"AudioPlayback/SpatialAnchorPointStatic",
		"AudioPlayback/SpatialAnchorAttachedFullTransformGenerationCleanup",
		"AudioPlayback/SpatialPublicSurface",
	}
	for _, identity in ordinaryEvidenceIdentities do
		test(identity, function(scope)
			if identity == "AudioPlayback/PointRejectsDirectionalProfile" then
				local fixture = makeOrdinaryEvidenceFixture(scope, "Client", "World", 2)
				fixture.Graph.Config.SpatialProfilesById.Directional = { AngleCurve = { { Angle = 0, Gain01 = 1 } } }
				fixture.Variant.SpatialProfileId = "Directional"
				local valid, reason = fixture.Core:ValidateVariant(fixture.Variant, { Kind = "Point", Position = Vector3.zero }, nil)
				assert(not valid and reason == "DirectionalPointUnsupported" and fixture.Pool:GetStats().Active == 0)
				return
			end
			if identity == "AudioPlayback/MusicOrdinaryTypeSeparation" then
				local fixture = makeOrdinaryEvidenceFixture(scope, "Client", "SFX", 2)
				local musicVariant = table.clone(fixture.Variant); musicVariant.PlayerType = "Music"
				local handle, reason = fixture.Core:PlayVariant(musicVariant, nil, nil)
				assert(handle == nil and reason == "InvalidRequest" and fixture.Pool:GetStats().Active == 0)
				return
			end
			if identity == "AudioPlayback/ClientFailSoftHandle" then
				local events = {}
				local client = OrdinarySoundClient.new({}, makeLogger(events))
				local callOk, handle = pcall(function() return client:PlayLocal({ CueId = "Unavailable" }) end)
				assert(callOk and not handle:IsActive() and pcall(function() handle:Stop(); handle:Stop() end))
				assert(#events == 1 and events[1].Event == "PlaybackRejected"
					and events[1].Data.ReasonCode == "AudioDisabled",
					"public fail-soft must return an inert handle and emit one Logger diagnostic")
				return
			end
			if identity == "AudioPlayback/CatalogDefaultsApplied" then
				local fixture = makeProductionWrapperFixture(scope, "Client", "SFX", 2)
				fixture.Variant.SourceVolume = 0.8
				fixture.Variant.PlaybackSpeed = 1.5
				fixture.Variant.Looping = true
				fixture.Variant.PlaybackRegion = { Start = 2, End = 9 }
				fixture.Variant.LoopRegion = { Start = 3, End = 8 }
				local handle = assert(fixture.Core:ResolveAndPlay({ CueId = "Evidence" }, nil, nil))
				local player = fixture.Created[1].Player
				assert(handle:IsActive() and player.Asset == "rbxassetid://1" and player.Volume == 0.8
					and player.PlaybackSpeed == 1.5 and player.Looping
					and player.PlaybackRegion == NumberRange.new(2, 9) and player.LoopRegion == NumberRange.new(3, 8))
				handle:Stop()
				return
			end
			if identity == "AudioPlayback/SourceVolume01" then
				for _, sourceVolume in { 0, 0.5, 1 } do
					local fixture = makeProductionWrapperFixture(scope, "Client", "SFX", 1)
					fixture.Variant.SourceVolume = sourceVolume
					local handle = assert(fixture.Core:PlayVariant(fixture.Variant, nil, nil))
					assert(fixture.Created[1].Player.Volume == sourceVolume)
					handle:Stop()
				end
				return
			end
			if identity == "AudioPlayback/AttachedTargetRemoval" then
				local fixture = makeProductionWrapperFixture(scope, "Client", "World", 1)
				local target = scope:Track(Instance.new("Part")); target.Parent = workspace
				local handle = assert(fixture.Core:PlayVariant(fixture.Variant, { Kind = "Attached", Instance = target }, nil))
				assert(handle:IsActive() and fixture.Pool:GetStats().Active == 1)
			target:Destroy()
				fixture.SpatialFrameDriver:Fire()
				local completed = not handle:IsActive() and fixture.Pool:GetStats().Active == 0 and #fixture.Events == 1
				assert(completed,
					`target-removal timeout: active={tostring(handle:IsActive())} poolActive={fixture.Pool:GetStats().Active} events={#fixture.Events}`)
				assert(not handle:IsActive() and fixture.Pool:GetStats().Active == 0)
				assert(#fixture.Events == 1 and fixture.Events[1].Event == "PlaybackEnded"
					and fixture.Events[1].Data.ReasonCode == "TargetRemoved")
				return
			end
			if identity == "AudioPlayback/ConcurrentWorldPositions" or identity == "AudioPlayback/ServerWorldWrapperIsolation" then
				local side = if identity == "AudioPlayback/ServerWorldWrapperIsolation" then "Server" else "Client"
				local fixture = makeProductionWrapperFixture(scope, side, "World", 2)
				local first = assert(fixture.Core:PlayVariant(fixture.Variant, { Kind = "Point", Position = Vector3.new(1, 0, 0) }, nil))
				local second = assert(fixture.Core:PlayVariant(fixture.Variant, { Kind = "Point", Position = Vector3.new(2, 0, 0) }, nil))
				local a, b = fixture.Created[1], fixture.Created[2]
				assert(first:IsActive() and second:IsActive() and a.Emitter ~= b.Emitter and a.Anchor ~= b.Anchor)
				assert(a.Emitter.Parent == a.Anchor and b.Emitter.Parent == b.Anchor)
				assert(a.Anchor.CFrame.Position == Vector3.new(1, 0, 0) and b.Anchor.CFrame.Position == Vector3.new(2, 0, 0))
				first:Stop(); second:Stop()
				return
			end
			if identity == "AudioPlayback/ServerWrapperFullReset" then
				local fixture = makeProductionWrapperFixture(scope, "Server", "World", 1)
				fixture.Variant.Looping = true
				fixture.Variant.PlaybackRegion = { Start = 1, End = 9 }
				fixture.Variant.LoopRegion = { Start = 2, End = 8 }
				local handle = assert(fixture.Core:PlayVariant(fixture.Variant, { Kind = "Point", Position = Vector3.new(7, 8, 9) }, { TimePosition = 3 }))
				local wrapper = fixture.Created[1]
				local emitter, anchor = wrapper.Emitter, wrapper.Anchor
				assert(wrapper.Player.Asset == "rbxassetid://1" and wrapper.Wire.SourceInstance == wrapper.Player
					and wrapper.Wire.TargetInstance == emitter and emitter.Parent == anchor)
				handle:Stop()
				assert(wrapper.Root.Parent == nil and wrapper.Player.Asset == "" and not wrapper.Player.IsPlaying
					and wrapper.Wire.SourceInstance == nil and wrapper.Wire.TargetInstance == nil
					and wrapper.Player.Volume == 1 and wrapper.Player.PlaybackSpeed == 1 and not wrapper.Player.Looping
					and wrapper.Player.PlaybackRegion == NumberRange.new(0, 60000)
					and wrapper.Player.LoopRegion == NumberRange.new(0, 60000) and wrapper.Player.TimePosition == 0
					and wrapper.Emitter == emitter and wrapper.Anchor == anchor
					and not emitter.Destroyed and not anchor.Destroyed and anchor.CFrame == CFrame.new())
				return
			end
			if identity == "AudioPlayback/SpatialAnchorFixedComposition" then
				local fixture = makeProductionWrapperFixture(scope, "Server", "World", 1)
				local handle = assert(fixture.Core:PlayVariant(
					fixture.Variant,
					{ Kind = "Point", Position = Vector3.new(3, 4, 5) },
					nil
				))
				local wrapper = fixture.Created[1]
				assert(wrapper.Root.ClassName == "Part" and wrapper.Root.Name == "SpatialAnchor"
					and wrapper.Root.Anchored and not wrapper.Root.CanCollide and not wrapper.Root.CanQuery
					and not wrapper.Root.CanTouch and wrapper.Root.Transparency == 1
					and wrapper.Root.Parent == fixture.Workspace)
				assert(wrapper.Player.Parent == wrapper.Root and wrapper.Emitter.Parent == wrapper.Root
					and wrapper.Wire.Parent == wrapper.Root and wrapper.Wire.SourceInstance == wrapper.Player
					and wrapper.Wire.TargetInstance == wrapper.Emitter)
				handle:Stop()
				return
			end
			if identity == "AudioPlayback/SpatialAnchorPointStatic" then
				local fixture = makeProductionWrapperFixture(scope, "Client", "World", 1)
				local handle = assert(fixture.Core:PlayVariant(
					fixture.Variant,
					{ Kind = "Point", Position = Vector3.new(11, 12, 13) },
					nil
				))
				local wrapper = fixture.Created[1]
				local initial = wrapper.Anchor.CFrame
				assert(fixture.Core._spatialRegistry:GetActiveCount() == 0
					and fixture.SpatialFrameDriver:GetConnectionCount() == 1)
				fixture.SpatialFrameDriver:Fire()
				assert(wrapper.Anchor.CFrame == initial)
				handle:Stop()
				assert(wrapper.Root.Parent == nil and fixture.Core._spatialRegistry:GetActiveCount() == 0)
				return
			end
			if identity == "AudioPlayback/SpatialAnchorAttachedFullTransformGenerationCleanup" then
				local fixture = makeProductionWrapperFixture(scope, "Client", "World", 1)
				local target = scope:Track(Instance.new("Part"))
				target.CFrame = CFrame.fromOrientation(0.2, 0.4, 0.6) + Vector3.new(5, 6, 7)
				target.Parent = workspace
				local handle = assert(fixture.Core:PlayVariant(
					fixture.Variant,
					{ Kind = "Attached", Instance = target },
					nil
				))
				local wrapper = fixture.Created[1]
				local firstBinding = fixture.Core._spatialRegistry._bindings[wrapper]
				assert(wrapper.Anchor.CFrame == target:GetPivot()
					and fixture.Core._spatialRegistry:GetActiveCount() == 1
					and fixture.SpatialFrameDriver:GetConnectionCount() == 1)
				target.CFrame = CFrame.fromOrientation(-0.1, 0.7, 0.3) + Vector3.new(-2, 8, 9)
				fixture.SpatialFrameDriver:Fire()
				assert(wrapper.Anchor.CFrame == target:GetPivot(), "Attached must copy full transform")
				handle:Stop()
				assert(fixture.Core._spatialRegistry:GetActiveCount() == 0 and not firstBinding.IsCurrent())
				local point = assert(fixture.Core:PlayVariant(
					fixture.Variant,
					{ Kind = "Point", Position = Vector3.new(1, 2, 3) },
					nil
				))
				local reusedCFrame = wrapper.Anchor.CFrame
				firstBinding.OnInvalid("TargetRemoved")
				fixture.SpatialFrameDriver:Fire()
				assert(point:IsActive() and wrapper.Anchor.CFrame == reusedCFrame
					and fixture.Core._spatialRegistry:GetActiveCount() == 0,
					"stale Attached generation must not release or move a reused Point lease")
				point:Stop()
				return
			end
			if identity == "AudioPlayback/SpatialPublicSurface" then
				local fixture = makeOrdinaryEvidenceFixture(scope, "Client", "World", 1)
				assert(fixture.Graph.Config.PositionType == nil and fixture.Graph.Config.PositioningMode == nil)
				local valid = fixture.Core:ValidateVariant(
					fixture.Variant,
					{ Kind = "Point", Position = Vector3.zero },
					nil
				)
				assert(valid, "fixed spatial composition must preserve the existing Point public surface")
				return
			end
			if identity == "AudioPlayback/SpatialCurveBoundaryMatrix" then
				local distance400 = {}
				for index = 1, 400 do
					table.insert(distance400, {
						Distance = if index == 400 then 400 else index - 1,
						Gain01 = if index == 1 then 0 else if index == 400 then 1 else 0.5,
					})
				end
				local distance401 = table.clone(distance400)
				table.insert(distance401, { Distance = 401, Gain01 = 1 })
				local spatial = table.clone(SpatialProfiles)
				spatial.DefaultWorldProfileId = "Exact400"
				spatial.Profiles = {
					Exact400 = {
						AcousticSimulationEnabled = true,
						DistanceCurve = distance400,
						AngleCurve = { { Angle = 0, Gain01 = 0 }, { Angle = 180, Gain01 = 1 } },
					},
					TooMany = { AcousticSimulationEnabled = true, DistanceCurve = distance401, AngleCurve = nil },
					EmptyAngle = { AcousticSimulationEnabled = true, DistanceCurve = nil, AngleCurve = {} },
				}
				local normalizationEvents = {}
				local normalized = AudioConfigValidator.validate(
					RuntimeConfig,
					RoutingConfig,
					spatial,
					"Client",
					makeLogger(normalizationEvents)
				)
				assert(normalized.Enabled and #normalized.Config.SpatialProfilesById.Exact400.DistanceCurve == 400)
				local exact = normalized.Config.SpatialProfilesById.Exact400
				assert(exact.DistanceCurve[1].Distance == 0 and exact.DistanceCurve[1].Gain01 == 0
					and exact.DistanceCurve[400].Distance == 400 and exact.DistanceCurve[400].Gain01 == 1
					and exact.AngleCurve[1].Angle == 0 and exact.AngleCurve[1].Gain01 == 0
					and exact.AngleCurve[2].Angle == 180 and exact.AngleCurve[2].Gain01 == 1)
				assert(normalized.Config.SpatialProfilesById.TooMany == nil
					and normalized.Config.SpatialProfilesById.EmptyAngle == nil,
					"401 points and a present empty AngleCurve must be isolated")
				local invalidDiagnostics = 0
				for _, event in normalizationEvents do
					if event.Event == "InvalidSpatialProfile" then invalidDiagnostics += 1 end
				end
				assert(invalidDiagnostics == 2, "each invalid profile must emit one stable diagnostic")

				local isolationFixture = makeProductionWrapperFixture(scope, "Client", "World", 1)
				isolationFixture.Variant.SpatialProfileId = "RejectedProfile"
				local curveCases: { any } = {
					{ Name = "DistanceNegative", Distance = { { Distance = -1, Gain01 = 0.5 } } },
					{ Name = "DistanceDuplicate", Distance = { { Distance = 0, Gain01 = 0.5 }, { Distance = 0, Gain01 = 0.5 } } },
					{ Name = "DistanceDecreasing", Distance = { { Distance = 1, Gain01 = 0.5 }, { Distance = 0, Gain01 = 0.5 } } },
					{ Name = "DistanceCoordinateNaN", Distance = { { Distance = 0 / 0, Gain01 = 0.5 } } },
					{ Name = "DistanceGainBelow", Distance = { { Distance = 0, Gain01 = -0.01 } } },
					{ Name = "DistanceGainAbove", Distance = { { Distance = 0, Gain01 = 1.01 } } },
					{ Name = "DistanceGainNaN", Distance = { { Distance = 0, Gain01 = 0 / 0 } } },
					{ Name = "AngleBelow", Angle = { { Angle = -0.01, Gain01 = 0.5 } } },
					{ Name = "AngleAbove", Angle = { { Angle = 180.01, Gain01 = 0.5 } } },
					{ Name = "AngleDuplicate", Angle = { { Angle = 0, Gain01 = 0.5 }, { Angle = 0, Gain01 = 0.5 } } },
					{ Name = "AngleDecreasing", Angle = { { Angle = 1, Gain01 = 0.5 }, { Angle = 0, Gain01 = 0.5 } } },
					{ Name = "AngleCoordinateNaN", Angle = { { Angle = 0 / 0, Gain01 = 0.5 } } },
					{ Name = "AngleGainBelow", Angle = { { Angle = 0, Gain01 = -0.01 } } },
					{ Name = "AngleGainAbove", Angle = { { Angle = 0, Gain01 = 1.01 } } },
					{ Name = "AngleGainNaN", Angle = { { Angle = 0, Gain01 = 0 / 0 } } },
				}
				for caseIndex, case in curveCases do
					local caseSpatial = table.clone(SpatialProfiles)
					caseSpatial.DefaultWorldProfileId = "ValidSibling"
					caseSpatial.Profiles = {
						ValidSibling = {
							AcousticSimulationEnabled = true,
							DistanceCurve = { { Distance = 0, Gain01 = 0 }, { Distance = 1, Gain01 = 1 } },
							AngleCurve = { { Angle = 0, Gain01 = 0 }, { Angle = 180, Gain01 = 1 } },
						},
						RejectedProfile = {
							AcousticSimulationEnabled = true,
							DistanceCurve = case.Distance,
							AngleCurve = case.Angle,
						},
					}
					local caseEvents = {}
					local caseResult = AudioConfigValidator.validate(
						RuntimeConfig,
						RoutingConfig,
						caseSpatial,
						"Client",
						makeLogger(caseEvents)
					)
					assert(caseResult.Enabled and caseResult.Config.SpatialProfilesById.ValidSibling ~= nil
						and caseResult.Config.SpatialProfilesById.RejectedProfile == nil, case.Name)
					assert(#caseEvents == 1 and caseEvents[1].Event == "InvalidSpatialProfile"
						and caseEvents[1].Data.ProfileId == "RejectedProfile"
						and caseEvents[1].Data.ReasonCode == "InvalidCurve",
						`{case.Name}: rejection must emit one stable isolated diagnostic`)

					local good = table.clone(SoundCatalog[2])
					good.CueId = `Spatial.Good{caseIndex}`; good.VariantId = "Good"
					good.PlayerType = "World"; good.SpatialProfile = "ValidSibling"; good.AssetId = tostring(caseIndex * 2)
					good.ResourcePath = nil; good.Preload = false
					local bad = table.clone(good)
					bad.CueId = `Spatial.Bad{caseIndex}`; bad.VariantId = "Bad"
					bad.SpatialProfile = "RejectedProfile"; bad.AssetId = tostring(caseIndex * 2 + 1)
					local catalog = AudioCatalog.new({ bad, good }, caseResult.Config, {
						GetByKey = function() return nil end,
						Get = function() return nil end,
						GetPath = function() return nil end,
						FindAll = function() return {} end,
					}, makeLogger({}))
					assert(catalog:GetNamedVariant(bad.CueId, "Bad") == nil
						and catalog:GetNamedVariant(good.CueId, "Good") ~= nil,
						`{case.Name}: valid catalog sibling did not survive invalid-profile isolation`)

					local before = isolationFixture.Pool:GetStats()
					local objectsBefore = #isolationFixture.Created
					local rejected, reason = isolationFixture.Core:PlayVariant(
						isolationFixture.Variant,
						{ Kind = "Point", Position = Vector3.zero },
						nil
					)
					local after = isolationFixture.Pool:GetStats()
					assert(rejected == nil and reason == "InvalidSpatialProfile"
						and #isolationFixture.Created == objectsBefore
						and after.Active == before.Active and after.Available == before.Available
						and after.Created == before.Created and after.Acquired == before.Acquired
						and after.Released == before.Released and after.Destroyed == before.Destroyed,
						`{case.Name}: rejection changed acquisition or object baselines`)
				end

				local fixture = makeProductionWrapperFixture(scope, "Client", "World", 2)
				local point = assert(fixture.Core:PlayVariant(fixture.Variant, { Kind = "Point", Position = Vector3.zero }, nil))
				local emitter = fixture.Created[1].Emitter
				assert(emitter.DistanceAttenuation[0] == 1 and emitter.DistanceAttenuation[400] == 0
					and emitter.AngleAttenuation[0] == 1 and emitter.AngleAttenuation[180] == 1,
					"distance 0/400 and nil-angle profile must produce nondirectional gain")
				fixture.Profile.AngleCurve = { { Angle = 0, Gain01 = 0 }, { Angle = 180, Gain01 = 1 } }
				local target = scope:Track(Instance.new("Part")); target.Parent = workspace
				local attached = assert(fixture.Core:PlayVariant(fixture.Variant, { Kind = "Attached", Instance = target }, nil))
				local directional = fixture.Created[2].Emitter
				assert(directional.AngleAttenuation[0] == 0 and directional.AngleAttenuation[180] == 1)
				point:Stop(); attached:Stop()
				return
			end
			if identity == "AudioPlayback/ListenerEnabledOnceEmitterProfileIsolation" then
				local fixture = makeProductionWrapperFixture(scope, "Client", "World", 2)
				local runtime = scope:Track(Instance.new("Folder"))
				local root = Instance.new("Folder"); root.Name = "AudioRuntime"
				root:SetAttribute("CompositionId", "AudioGraph.v1")
				root:SetAttribute("SchemaVersion", 1); root:SetAttribute("Generation", 1); root:SetAttribute("Ready", true)
				local published = Instance.new("Folder"); published.Name = "PublishedGraph"; published.Parent = root
				local serverPlayback = Instance.new("Folder"); serverPlayback.Name = "ServerPlayback"; serverPlayback.Parent = root
				local fadersFolder = Instance.new("Folder"); fadersFolder.Name = "Faders"; fadersFolder.Parent = published
				local wiresFolder = Instance.new("Folder"); wiresFolder.Name = "Wires"; wiresFolder.Parent = published
				local faders = {}
				for _, id in { "Master", "UI", "SFX", "World", "Music" } do
					local fader = Instance.new("AudioFader"); fader.Name = id; fader.Parent = fadersFolder; faders[id] = fader
				end
				for _, id in { "UI", "SFX", "World", "Music" } do
					local wire = Instance.new("Wire"); wire.Name = id .. "ToMaster"
					wire.SourceInstance = faders[id]; wire.TargetInstance = faders.Master; wire.Parent = wiresFolder
				end
				root.Parent = runtime
				local signal = makeSignal()
				local graph = AudioGraphClient.new({
					RuntimeParent = runtime,
					LocalPlayer = assert(game:GetService("Players"):GetPlayers()[1]),
					PlayersModule = { CharacterAdded = signal, CharacterRemoving = signal, GetCharacter = function() return nil end },
					Workspace = workspace, GetCurrentCameraCFrame = function() return nil end,
					ListenerFrameDriver = signal, Logger = makeLogger({}),
				})
				scope:Defer(function() graph:Stop() end)
				local result = graph:Initialize({ Enabled = true, Config = fixture.Config })
				assert(result.Enabled and result.Listener.AcousticSimulationEnabled
					and graph:Initialize({ Enabled = true, Config = fixture.Config }) == result)
				local listenerCount = 0
				for _, child in result.LocalRoot:GetChildren() do if child:IsA("AudioListener") then listenerCount += 1 end end
				assert(listenerCount == 1, "valid graph initialization must enable exactly one listener")
				local first = assert(fixture.Core:PlayVariant(fixture.Variant, { Kind = "Point", Position = Vector3.zero }, nil))
				fixture.Profile.AcousticSimulationEnabled = false
				local second = assert(fixture.Core:PlayVariant(fixture.Variant, { Kind = "Point", Position = Vector3.new(1, 0, 0) }, nil))
				assert(fixture.Created[1].Emitter.AcousticSimulationEnabled == true
					and fixture.Created[2].Emitter.AcousticSimulationEnabled == false
					and result.Listener.AcousticSimulationEnabled == true,
					"listener capability is stable while each real wrapper owns its emitter profile")
				first:Stop(); second:Stop()
				return
			end
			if identity == "AudioPlayback/ServerOneLeaseNoFanout" then
				local fixture = makePublicOrdinaryService(scope, "Server", false)
				local result = fixture.Service:Play({ CueId = "Loop" })
				assert(result.Accepted and result.Handle == nil and #fixture.Created == 1
					and fixture.Pool:GetStats().Active == 1 and fixture.GetFanoutCalls() == 0,
					"server-all one-shot must own one replicated lease and never application-fanout")
				return
			end
			if identity == "AudioPlayback/LoopedDeliveryMatrix" then
				local client = makePublicOrdinaryService(scope, "Client", true)
				local server = makePublicOrdinaryService(scope, "Server", true)
				local localHandle = client.Service:PlayLocal({ CueId = "Loop" })
				local serverResult = server.Service:Play({ CueId = "Loop" })
				assert(localHandle:IsActive() and serverResult.Accepted and serverResult.Handle:IsActive())
				local prepared, sent = 0, 0
				client.Service:BindHybridIntentSender({
					PrepareIntent = function() prepared += 1; return {} end,
					SendPreparedIntent = function() sent += 1 end,
				})
				local hybrid = client.Service:PlayHybrid({ CueId = "Loop" })
				assert(not hybrid:IsActive() and prepared == 0 and sent == 0)
				assert(client.Events[#client.Events].Event == "HybridNotAllowed"
					and client.Events[#client.Events].Data.ReasonCode == "HybridLoopUnsupported")
				localHandle:Stop(); serverResult.Handle:Stop()
				assert(client.Pool:GetStats().Active == 0 and server.Pool:GetStats().Active == 0)
				return
			end
			if identity == "AudioPlayback/WrapperResetAcrossAssets"
				or identity == "AudioPlayback/RegionAbsentAndValid"
				or identity == "AudioPlayback/RegionClampAfterReady"
				or identity == "AudioPlayback/InvalidLoopUsesEffectivePlaybackRegion"
				or identity == "AudioPlayback/LoopRegionIgnoredWhenNotLooping"
			then
				local workers = {}
				local events = {}
				local wrapper = Wrapper.new("SFX", {
					InstanceFactory = makeWrapperFactory(),
					Spawn = function(callback) table.insert(workers, callback) end,
				})
				scope:Defer(function() wrapper:Destroy() end)
				local looping = identity == "AudioPlayback/InvalidLoopUsesEffectivePlaybackRegion"
				local variant = {
					ContentId = "rbxassetid://1", SourceVolume = 0.5, PlaybackSpeed = 1,
					Looping = looping, PlayerType = "SFX",
					PlaybackRegion = if identity == "AudioPlayback/RegionAbsentAndValid" then nil else { Start = 2, End = 12 },
					LoopRegion = if identity == "AudioPlayback/RegionAbsentAndValid" then nil else { Start = 1, End = 11 },
				}
				wrapper:OnAcquire({
					Variant = variant, Parent = {}, Fader = {}, InteractionGroupId = "AudioPlayback.Private.v1",
					TimePosition = 11, ReadinessWait = function() coroutine.yield() end,
					Spawn = function(callback) table.insert(workers, callback) end, Logger = makeLogger(events),
				})
				local readinessThread = coroutine.create(workers[1])
				assert(coroutine.resume(readinessThread))
				if identity == "AudioPlayback/RegionAbsentAndValid" then
					assert(wrapper.Player.PlaybackRegion == NumberRange.new(0, 10))
				elseif identity == "AudioPlayback/RegionClampAfterReady" then
					assert(wrapper.Player.PlaybackRegion == NumberRange.new(2, 10) and wrapper.Player.TimePosition == 10)
				elseif identity == "AudioPlayback/InvalidLoopUsesEffectivePlaybackRegion" then
					assert(wrapper.Player.LoopRegion == NumberRange.new(2, 10))
					assert(#events == 1 and events[1].Event == "InvalidLoopRegion"
						and events[1].Data.ReasonCode == "OutsideEffectivePlaybackRegion"
						and events[1].Data.PlayerType == "SFX" and events[1].Data.Start == nil,
						"invalid effective loop fallback must warn once without raw authored bounds")
				elseif identity == "AudioPlayback/LoopRegionIgnoredWhenNotLooping" then
					assert(not wrapper.Player.Looping and wrapper.Player.LoopRegion == nil)
				else
					wrapper:OnRelease()
					assert(wrapper.Root.Parent == nil and wrapper.Wire.SourceInstance == nil and wrapper.Player.Volume == 1)
				end
				return
			end

			local side = if identity == "AudioPlayback/ServerOneLeaseNoFanout"
				or identity == "AudioPlayback/ServerLoopLeaseLifetime"
				or identity == "AudioPlayback/ServerWorldWrapperIsolation"
				or identity == "AudioPlayback/StaleServerEndedGeneration" then "Server" else "Client"
			local world = identity == "AudioPlayback/AttachedTargetRemoval"
				or identity == "AudioPlayback/ConcurrentWorldPositions"
				or identity == "AudioPlayback/ServerWorldWrapperIsolation"
				or identity == "AudioPlayback/SpatialCurveBoundaryMatrix"
				or identity == "AudioPlayback/InvalidProfileVariantIsolation"
				or identity == "AudioPlayback/ListenerEnabledOnceEmitterProfileIsolation"
				or identity == "AudioPlayback/DirectionalPointAttachedSplit"
			local maximum = if identity == "AudioPlayback/OrdinaryFifoBudget"
				or identity == "AudioPlayback/OrdinaryFifoNPlusOne"
				or identity == "AudioPlayback/PendingOccupiesActiveSlot" then 2 else 3
			local fixture = makeOrdinaryEvidenceFixture(scope, side, if world then "World" else "SFX", maximum)
			local function sourceAt(x: number): any
				return if world then { Kind = "Point", Position = Vector3.new(x, 0, 0) } else nil
			end
			if identity == "AudioPlayback/InvalidProfileVariantIsolation" then
				local spatial = table.clone(SpatialProfiles)
				spatial.DefaultWorldProfileId = "Valid"
				spatial.Profiles = {
					Valid = { AcousticSimulationEnabled = true, DistanceCurve = nil, AngleCurve = nil },
					Invalid = { AcousticSimulationEnabled = true, DistanceCurve = nil, AngleCurve = {} },
				}
				local events = {}
				local normalized = AudioConfigValidator.validate(RuntimeConfig, RoutingConfig, spatial, "Client", makeLogger(events))
				assert(normalized.Enabled and normalized.Config.SpatialProfilesById.Valid ~= nil
					and normalized.Config.SpatialProfilesById.Invalid == nil)
				local good = table.clone(SoundCatalog[2])
				good.CueId = "Spatial.Good"; good.VariantId = "Good"; good.PlayerType = "World"
				good.SpatialProfile = "Valid"; good.AssetId = "1"
				good.ResourcePath = nil; good.Preload = false
				local bad = table.clone(good)
				bad.CueId = "Spatial.Bad"; bad.VariantId = "Bad"; bad.SpatialProfile = "Invalid"; bad.AssetId = "2"
				local catalog = AudioCatalog.new({ bad, good }, normalized.Config, {
					GetByKey = function() return nil end, Get = function() return nil end,
					GetPath = function() return nil end, FindAll = function() return {} end,
				}, makeLogger(events))
				assert(catalog:GetNamedVariant("Spatial.Bad", "Bad") == nil
					and catalog:GetNamedVariant("Spatial.Good", "Good") ~= nil,
					"an invalid profile must skip only its variant while the valid sibling survives")
				fixture.Variant.SpatialProfileId = "Missing"
				local handle, reason = fixture.Core:PlayVariant(fixture.Variant, sourceAt(0), nil)
				assert(handle == nil and reason == "InvalidSpatialProfile" and fixture.Pool:GetStats().Active == 0)
				return
			end
			if identity == "AudioPlayback/DirectionalPointAttachedSplit" then
				fixture.Graph.Config.SpatialProfilesById.Default.AngleCurve = { { Angle = 0, Gain01 = 1 } }
				local point, reason = fixture.Core:PlayVariant(fixture.Variant, sourceAt(0), nil)
				assert(point == nil and reason == "DirectionalPointUnsupported")
				local target = scope:Track(Instance.new("Part")); target.Parent = workspace
				local attached = assert(fixture.Core:PlayVariant(fixture.Variant, { Kind = "Attached", Instance = target }, nil))
				assert(attached:IsActive())
				return
			end
			if identity == "AudioPlayback/CatalogDefaultsApplied" then
				fixture.Variant.SourceVolume = 0.8; fixture.Variant.PlaybackSpeed = 1.5; fixture.Variant.Looping = true
				local handle = assert(fixture.Core:PlayVariant(fixture.Variant, nil, nil))
				assert(handle:IsActive() and fixture.Created[1].Context.Variant == fixture.Variant)
				assert(fixture.Created[1].Context.VolumeMultiplier == nil and fixture.Created[1].Context.PlaybackSpeedMultiplier == nil)
				return
			end
			if identity == "AudioPlayback/PublicPlayNeverYields" then
				fixture.Control.AutoReady = false
				local handle = assert(fixture.Core:PlayVariant(fixture.Variant, nil, nil))
				assert(handle:IsActive() and not fixture.Created[1].Player.IsReady)
				return
			end
			if identity == "AudioPlayback/ServerLoopLeaseLifetime" or identity == "AudioPlayback/LoopedDeliveryMatrix" then
				fixture.Variant.Looping = true
				local handle = assert(fixture.Core:PlayVariant(fixture.Variant, sourceAt(0), nil))
				assert(handle:IsActive() and fixture.Pool:GetStats().Active == 1)
				handle:Stop(); assert(not handle:IsActive() and fixture.Pool:GetStats().Active == 0)
				return
			end
			if identity == "AudioPlayback/StaleServerEndedGeneration" then
				local first = assert(fixture.Core:PlayVariant(fixture.Variant, nil, nil))
				local staleEnded = fixture.Created[1].Context.OnEnded
				first:Stop()
				local second = assert(fixture.Core:PlayVariant(fixture.Variant, nil, nil))
				staleEnded()
				assert(second:IsActive() and fixture.Pool:GetStats().Active == 1)
				return
			end
			if identity == "AudioPlayback/AttachedTargetRemoval" then
				local target = scope:Track(Instance.new("Part")); target.Parent = workspace
				local handle = assert(fixture.Core:PlayVariant(fixture.Variant, { Kind = "Attached", Instance = target }, nil))
				assert(handle:IsActive()); handle:Stop(); assert(not handle:IsActive())
				return
			end
			if identity == "AudioPlayback/ConcurrentWorldPositions" or identity == "AudioPlayback/ServerWorldWrapperIsolation" then
				local first = assert(fixture.Core:PlayVariant(fixture.Variant, sourceAt(1), nil))
				local second = assert(fixture.Core:PlayVariant(fixture.Variant, sourceAt(2), nil))
				assert(first:IsActive() and second:IsActive() and fixture.Created[1] ~= fixture.Created[2])
				assert(fixture.Created[1].Context.Source.Position ~= fixture.Created[2].Context.Source.Position)
				return
			end
			if identity == "AudioPlayback/SpatialCurveBoundaryMatrix" or identity == "AudioPlayback/ListenerEnabledOnceEmitterProfileIsolation" then
				local first = assert(fixture.Core:PlayVariant(fixture.Variant, sourceAt(0), nil))
				local second = assert(fixture.Core:PlayVariant(fixture.Variant, sourceAt(400), nil))
				assert(first:IsActive() and second:IsActive())
				assert(fixture.Created[1].Context.SpatialProfile == fixture.Profile)
				return
			end
			local first = assert(fixture.Core:PlayVariant(fixture.Variant, nil, nil))
			if identity == "AudioPlayback/ServerOneLeaseNoFanout" then
				assert(first:IsActive() and #fixture.Created == 1 and fixture.Pool:GetStats().Active == 1)
				return
			end
			local second = assert(fixture.Core:PlayVariant(fixture.Variant, nil, nil))
			fixture.Control.AutoReady = identity ~= "AudioPlayback/PendingOccupiesActiveSlot"
			local third = assert(fixture.Core:PlayVariant(fixture.Variant, nil, nil))
			assert(not first:IsActive() and second:IsActive() and third:IsActive())
			assert(fixture.Pool:GetStats().Active == 2)
		end)
	end

	local musicEvidenceIdentities = {
		"AudioPlayback/MusicInstantNoOverlap",
		"AudioPlayback/MusicSequentialParticipantOrder",
		"AudioPlayback/MusicCrossfadeAdjacentPair",
		"AudioPlayback/MusicPostTransitionRetain",
		"AudioPlayback/MusicPendingKeepsIncumbent",
		"AudioPlayback/MusicStableTopOnly",
		"AudioPlayback/MusicLifoSequence",
		"AudioPlayback/MusicStaleCallbacks",
		"AudioPlayback/MusicStopNonTop",
		"AudioPlayback/MusicPendingTopIncumbentEnded",
	}
	for _, identity in musicEvidenceIdentities do
		test(identity, function(scope)
			local fixture = makeMusicFixture(scope)
			local music = fixture.Music
			local a = music:PlayMusic({ CueId = "A" })
			local wa = fixture.Created[1]
			local staleReady = if identity == "AudioPlayback/MusicStaleCallbacks" then wa.Context.OnReady else nil
			local staleEnded = if identity == "AudioPlayback/MusicStaleCallbacks" then wa.Context.OnEnded else nil
			if identity == "AudioPlayback/MusicPendingKeepsIncumbent" or identity == "AudioPlayback/MusicPendingTopIncumbentEnded" then
				fixture.Control.AutoReady = false
				local b = music:PlayMusic({ CueId = "B" })
				local wb = fixture.Created[2]
				assert(a:IsActive() and b:IsActive() and wa.Player.IsPlaying and not wb.Player.IsPlaying)
				if identity == "AudioPlayback/MusicPendingTopIncumbentEnded" then
					wa:End("Ended")
					assert(not a:IsActive() and b:IsActive() and not wb.Player.IsPlaying)
				end
				return
			end
			local transition = if identity == "AudioPlayback/MusicSequentialParticipantOrder"
				then { Strategy = "SequentialFade", FadeOutSeconds = 1, FadeInSeconds = 1 }
				elseif identity == "AudioPlayback/MusicCrossfadeAdjacentPair"
				then { Strategy = "Crossfade", FadeOutSeconds = 1, FadeInSeconds = 1 }
				else nil
			local b = music:PlayMusic({ CueId = "B" }, nil, transition)
			local wb = fixture.Created[2]
			if identity == "AudioPlayback/MusicSequentialParticipantOrder" then
				assert(wa.Player.IsPlaying and not wb.Player.IsPlaying)
				finishNext(fixture.Jobs); assert(not wa.Player.IsPlaying and wb.Player.IsPlaying)
				finishNext(fixture.Jobs); assertOnlyPlaying(fixture, wb)
			elseif identity == "AudioPlayback/MusicCrossfadeAdjacentPair" then
				assert(wa.Player.IsPlaying and wb.Player.IsPlaying and fixture.Pool:GetStats().Active == 2)
				finishNext(fixture.Jobs); assertOnlyPlaying(fixture, wb)
			elseif identity == "AudioPlayback/MusicPostTransitionRetain" then
				wa.Player.TimePosition = 3
				assertOnlyPlaying(fixture, wb)
				assert(fixture.Pool:GetStats().Active == 2 and not wa.Player.IsPlaying)
			elseif identity == "AudioPlayback/MusicLifoSequence" then
				local c = music:PlayMusic({ CueId = "C" })
				local wc = fixture.Created[3]
				assertOnlyPlaying(fixture, wc); c:Stop(); assertOnlyPlaying(fixture, wb); b:Stop(); assertOnlyPlaying(fixture, wa)
			elseif identity == "AudioPlayback/MusicStaleCallbacks" then
				staleReady(wa.Generation - 1); staleEnded(wa.Generation - 1, "Ended")
				assert(a:IsActive() and b:IsActive() and wb.Player.IsPlaying)
			elseif identity == "AudioPlayback/MusicStopNonTop" then
				a:Stop(); assert(not a:IsActive() and b:IsActive() and wb.Player.IsPlaying)
			else
				assert(a:IsActive() and b:IsActive() and not wa.Player.IsPlaying and wb.Player.IsPlaying)
			end
		end)
	end

	return TestHarness.runAll("AudioPlaybackTestRunner", tests)
end

return Runner
