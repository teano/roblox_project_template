--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TestHarness = require(script.Parent.TestHarness)
local Codec = require(ReplicatedStorage.Shared.Audio.AudioHybridCodec)
local AudioProtocol = require(ReplicatedStorage.Shared.Audio.AudioProtocol)
local AudioSafetyLimits = require(ReplicatedStorage.Shared.Audio.AudioSafetyLimits)
local CommunicationSerialize = require(ReplicatedStorage.Shared.Communication.CommunicationSerialize)
local Validator = require(ReplicatedStorage.Shared.Audio.AudioConfigValidator)
local RuntimeConfig = require(ReplicatedStorage.Shared.Configs.Audio.AudioRuntimeConfig)
local RoutingConfig = require(ReplicatedStorage.Shared.Configs.Audio.RoutingConfig)
local SpatialProfiles = require(ReplicatedStorage.Shared.Configs.Audio.SpatialProfiles)
local MementoTransaction = require(ReplicatedStorage.Shared.Save.MementoTransaction)
local SaveSerialize = require(ReplicatedStorage.Shared.Save.SaveSerialize)
local TableUtil = require(ReplicatedStorage.Shared.Util.TableUtil)
local PoolModule = require(ReplicatedStorage.Shared.Pooling.PoolModule)
local AudioGraphClient = require(ReplicatedStorage.Client.Audio.AudioGraphClient)
local AudioSettingsClient = require(ReplicatedStorage.Client.Audio.AudioSettingsClient)
local OrdinarySoundClient = require(ReplicatedStorage.Client.Audio.OrdinarySoundClient)
local HybridClient = require(ReplicatedStorage.Client.Audio.HybridOneShotClientController)
local ClientSaveController = require(ReplicatedStorage.Client.Save.ClientSaveController)
local HybridServer = require(game.ServerScriptService.Modules.Audio.HybridOneShotServerController)
local AudioGraphServer = require(game.ServerScriptService.Modules.Audio.AudioGraphServer)
local AudioSettingsModule = require(game.ServerScriptService.Modules.Audio.AudioSettingsModule)
local CommunicationServer = require(game.ServerScriptService.Modules.Communication.CommunicationServer)
local ServerSaveController = require(game.ServerScriptService.Modules.Save.ServerSaveController)
local ServerManifest = require(game.ServerScriptService.Initialization.ServerManifest)
local ClientManifest = require(ReplicatedStorage.Client.Initialization.ClientManifest)

local Runner = {}

local function makeLogger(events: { any })
	local function record(_self, event, data)
		table.insert(events, { Event = event, Data = data })
	end
	return { Warn = record, Error = record }
end

local function makeSignal(): any
	local callbacks = {}
	local signal = {}
	function signal:Connect(callback)
		local active = true
		table.insert(callbacks, callback)
		return { Disconnect = function() active = false end, IsConnected = function() return active end }
	end
	function signal:Fire(...)
		for _, callback in callbacks do callback(...) end
	end
	return signal
end

local function makePublishedGraph(scope: any): (Folder, any)
	local runtime = scope:Track(Instance.new("Folder")) :: Folder
	runtime.Name = "AudioIntegrationRuntime"
	local root = Instance.new("Folder")
	root.Name = AudioProtocol.RuntimeRootName
	root:SetAttribute(AudioProtocol.AttributeNames.CompositionId, AudioProtocol.CompositionId)
	root:SetAttribute(AudioProtocol.AttributeNames.SchemaVersion, AudioProtocol.SchemaVersion)
	root:SetAttribute(AudioProtocol.AttributeNames.Generation, AudioProtocol.Generation)
	root:SetAttribute(AudioProtocol.AttributeNames.Ready, true)
	local published = Instance.new("Folder"); published.Name = AudioProtocol.PublishedGraphName; published.Parent = root
	local serverPlayback = Instance.new("Folder"); serverPlayback.Name = AudioProtocol.ServerPlaybackName; serverPlayback.Parent = root
	local fadersFolder = Instance.new("Folder"); fadersFolder.Name = "Faders"; fadersFolder.Parent = published
	local wiresFolder = Instance.new("Folder"); wiresFolder.Name = "Wires"; wiresFolder.Parent = published
	local faders = {}
	for _, id in { "Master", "UI", "SFX", "World", "Music" } do
		local fader = Instance.new("AudioFader"); fader.Name = id; fader.Parent = fadersFolder; faders[id] = fader
	end
	for _, id in { "UI", "SFX", "World", "Music" } do
		local wire = Instance.new("Wire"); wire.Name = id .. "ToMaster"; wire.SourceInstance = faders[id]; wire.TargetInstance = faders.Master; wire.Parent = wiresFolder
	end
	root.Parent = runtime
	return runtime, { Root = root, Faders = faders }
end

local function validatedConfig(): any
	local result = Validator.validate(RuntimeConfig, RoutingConfig, SpatialProfiles, "Client", makeLogger({}))
	assert(result.Enabled)
	return result.Config
end

local function makePlaybackWrapper(created: { any }): any
	local player = { IsPlaying = false, IsReady = true }
	local wrapper = { Player = player, Generation = 0, Context = nil }
	function wrapper:OnAcquire(context)
		self.Generation += 1
		self.Context = context
		self.Player.IsPlaying = true
		if context.OnReady then context.OnReady(self.Generation) end
	end
	function wrapper:UpdateCallbacks(onReady, onEnded)
		if self.Context then
			self.Context.OnReady = onReady
			self.Context.OnEnded = onEnded
		end
	end
	function wrapper:OnRelease()
		self.Generation += 1
		self.Context = nil
		self.Player.IsPlaying = false
	end
	function wrapper:IsPoolableValid() return true end
	function wrapper:Destroy() self:OnRelease() end
	table.insert(created, wrapper)
	return wrapper
end

local function makeOrdinaryClient(scope: any, catalog: any, config: any, events: { any }): (any, { any })
	local created = {}
	local pools = PoolModule.new()
	pools:Initialize()
	scope:Defer(function() pools:Destroy() end)
	local ordinary = OrdinarySoundClient.new(pools, makeLogger(events), {
		WrapperFactory = function() return makePlaybackWrapper(created) end,
	})
	ordinary:Initialize({ Enabled = true, Catalog = catalog, Config = config }, {
		Enabled = true,
		LocalRoot = {},
		Faders = { UI = {}, SFX = {}, World = {} },
		Config = config,
	})
	return ordinary, created
end

local function makeSettingsGraphOwner(): any
	local config = validatedConfig()
	local faders = {}
	for _, id in { "Master", "UI", "SFX", "World", "Music" } do
		faders[id] = { Volume = -1 }
	end
	local owner = {
		_result = { Enabled = true, Config = config, Faders = faders },
		Bound = false,
	}
	function owner:BindOutput() self.Bound = true; return true end
	function owner:UnbindOutput() self.Bound = false end
	return owner
end

local function makeStorage(document: any): any
	return {
		Load = function() return { Ok = true, Document = document, Created = false } end,
		Release = function() return { Ok = true } end,
		Save = function() return { Ok = true } end,
	}
end

local function makeClientTestProvider(id: string): any
	local provider = {
		Id = id,
		Version = 1,
		Authority = "Client",
		Value = nil,
		Running = false,
		HookMode = "Accept",
		FailNextRun = false,
	}
	function provider:ValidateEnvelope(envelope)
		if self.HookMode == "Throw" then error("injected client envelope exception") end
		if self.HookMode == "Reject" then return false end
		return typeof(envelope) == "table" and envelope.Version == 1 and envelope.Data ~= nil
	end
	function provider:ReconcileSnapshotEnvelope(envelope)
		return true, envelope or { Version = 1, Data = "default" }
	end
	function provider:ValidateMemento(value)
		return typeof(value) == "string", value, "InvalidTestValue"
	end
	function provider:SetMemento(value) self.Value = value end
	function provider:GetMemento() return self.Value end
	function provider:Run()
		if self.FailNextRun then self.FailNextRun = false; error("injected client Run failure") end
		self.Running = true
	end
	function provider:Stop() self.Running = false; self.Value = nil end
	return provider
end

local function makeServerTestProvider(id: string, withEnvelopeHook: boolean): any
	local provider = {
		Id = id,
		Version = 1,
		Authority = "Client",
		ClientSnapshotPolicy = "Include",
		Values = {},
		Running = {},
		HookMode = "Accept",
		FailNextRun = false,
		SetCount = 0,
	}
	function provider:CreateDefault(_player) return "default" end
	function provider:ReconcileMemento(_player, value) return value end
	if withEnvelopeHook then
		function provider:ValidateEnvelope(_player, envelope)
			if self.HookMode == "Throw" then error("injected server envelope exception") end
			if self.HookMode == "Reject" then return false end
			if self.HookMode == "YieldReject" then
				coroutine.yield("ValidateEnvelopeYielded")
				return false
			end
			return typeof(envelope) == "table" and envelope.Version == 1 and envelope.Data ~= nil
		end
	end
	function provider:ValidateMemento(_player, value)
		return typeof(value) == "string", value, "InvalidTestValue"
	end
	function provider:SetMemento(player, value) self.SetCount += 1; self.Values[player] = value end
	function provider:ApplyClientMemento(player, value) self:SetMemento(player, value) end
	function provider:GetMemento(player) return self.Values[player] end
	function provider:Run(player)
		if self.FailNextRun then self.FailNextRun = false; error("injected server Run failure") end
		self.Running[player] = true
	end
	function provider:Stop(player) self.Running[player] = nil; self.Values[player] = nil end
	return provider
end

function Runner.runAll()
	local tests = {}
	local function test(name, callback) table.insert(tests, { Name = name, Callback = callback }) end

	test("AudioIntegration/ClientGraphExactBindListenerLifecycleAndCleanup", function(scope)
		local runtime = makePublishedGraph(scope)
		local config = validatedConfig()
		local frame = makeSignal()
		local added = makeSignal()
		local removing = makeSignal()
		local character: Model? = scope:Track(Instance.new("Model")) :: Model
		character.Name = "AudioListenerCharacter"
		local rootPart = Instance.new("Part"); rootPart.Name = "HumanoidRootPart"; rootPart.Position = Vector3.new(4, 5, 6); rootPart.Parent = character
		character.Parent = workspace
		local cameraCFrame = CFrame.new(100, 200, 300) * CFrame.Angles(0, math.rad(90), 0)
		local fakePlayer = assert(game:GetService("Players"):GetPlayers()[1], "Play fixture requires the current Studio player")
		local playersModule = {
			CharacterAdded = added,
			CharacterRemoving = removing,
			GetCharacter = function() return character end,
		}
		local graph = AudioGraphClient.new({
			RuntimeParent = runtime,
			LocalPlayer = fakePlayer,
			PlayersModule = playersModule,
			Workspace = workspace,
			GetCurrentCameraCFrame = function() return cameraCFrame end,
			ListenerFrameDriver = frame,
			Logger = makeLogger({}),
		})
		scope:Defer(function() graph:Stop() end)
		local result = graph:Initialize({ Enabled = true, Config = config })
		assert(result.Enabled and result.Listener.Parent == result.ListenerAnchor)
		assert(result.Listener.PositionInstance == result.ListenerAnchor)
		assert(result.ListenerAnchor.Parent == workspace, "listener binding anchor must be world-positioned")
		assert(result.ListenerAnchor.Position == rootPart.Position)
		assert(result.ListenerAnchor.CFrame.Rotation == cameraCFrame.Rotation, "listener must use camera rotation only")
		character = nil
		removing:Fire()
		assert(result.Listener.Parent == result.LocalRoot and result.Listener.PositionInstance == nil)
		assert(result.ListenerAnchor.Parent == workspace)
		local replacement = scope:Track(Instance.new("Model")) :: Model
		local replacementRoot = Instance.new("Part"); replacementRoot.Name = "HumanoidRootPart"; replacementRoot.Position = Vector3.new(8, 9, 10); replacementRoot.Parent = replacement
		replacement.Parent = workspace
		character = replacement
		cameraCFrame = CFrame.new(-500, 20, 9) * CFrame.Angles(math.rad(30), 0, 0)
		added:Fire(replacement)
		frame:Fire()
		assert(result.Listener.Parent == result.ListenerAnchor and result.Listener.PositionInstance == result.ListenerAnchor)
		assert(result.ListenerAnchor.Position == replacementRoot.Position)
		assert(result.ListenerAnchor.CFrame.Rotation == cameraCFrame.Rotation)
		graph:Stop()
		assert(result.Listener.PositionInstance == nil and result.Listener.Parent == nil and result.ListenerAnchor.Parent == nil)
		assert(result.LocalRoot.Parent == nil)
	end)

	test("AudioIntegration/ClientGraphWaitsForExactTreeAndFailsSoftAtomically", function(scope)
		local runtime, published = makePublishedGraph(scope)
		local extra = Instance.new("Folder"); extra.Name = "Unexpected"; extra.Parent = published.Root
		local now = 0
		local player = assert(game:GetService("Players"):GetPlayers()[1], "Play fixture requires the current Studio player")
		local noCharacterSignal = makeSignal()
		local dependencies = {
			RuntimeParent = runtime,
			LocalPlayer = player,
			PlayersModule = { CharacterAdded = noCharacterSignal, CharacterRemoving = noCharacterSignal, GetCharacter = function() return nil end },
			Workspace = workspace,
			GetCurrentCameraCFrame = function() return nil end,
			ListenerFrameDriver = makeSignal(),
			Logger = makeLogger({}),
			Clock = function() return now end,
			Wait = function() now += 1 end,
		}
		local mismatch = AudioGraphClient.new(dependencies)
		local result = mismatch:Initialize({ Enabled = true, Config = validatedConfig() })
		assert(not result.Enabled and result.ReasonCode == "GraphMismatchOrTimeout" and now >= 10)
		extra:Destroy()
		local createCount = 0
		dependencies.InstanceFactory = function(className)
			createCount += 1
			if className == "AudioDeviceOutput" then error("injected output construction failure") end
			return Instance.new(className)
		end
		local failing = AudioGraphClient.new(dependencies)
		local failed = failing:Initialize({ Enabled = true, Config = validatedConfig() })
		assert(not failed.Enabled and failed.ReasonCode == "GraphConstructionFailed")
		assert(published.Root:FindFirstChild("ClientGraph") == nil)
		local countAfterFailure = createCount
		assert(failing:Initialize({ Enabled = true, Config = validatedConfig() }) == failed and createCount == countAfterFailure)
	end)

	test("AudioIntegration/ServerGraphConstructionFailureAtomic", function(scope)
		local runtime = scope:Track(Instance.new("Folder"))
		local calls = 0
		local graph = AudioGraphServer.new(runtime, makeLogger({}), {
			InstanceFactory = function(className)
				calls += 1
				if calls == 4 then error("injected graph stage failure") end
				return Instance.new(className)
			end,
		})
		local result = graph:Initialize({ Enabled = true, Config = validatedConfig() })
		assert(not result.Enabled and result.ReasonCode == "GraphConstructionFailed")
		assert(runtime:FindFirstChild(AudioProtocol.RuntimeRootName) == nil)
		local after = calls
		assert(graph:Initialize({ Enabled = true, Config = validatedConfig() }) == result and calls == after)
	end)

	test("AudioIntegration/AudioSettingsInitialCleanupAndReplacementRollback", function()
		local config = validatedConfig()
		local faders = {}
		for _, id in { "Master", "UI", "SFX", "World", "Music" } do faders[id] = { Volume = -1 } end
		local graphOwner = { _result = { Enabled = true, Config = config, Faders = faders }, Bound = false }
		function graphOwner:BindOutput() self.Bound = true; return true end
		function graphOwner:UnbindOutput() self.Bound = false end
		local settings = AudioSettingsClient.new(graphOwner)
		local failing = { Value = nil, FailNext = true }
		function failing:SetMemento(value) self.Value = value end
		function failing:GetMemento() return self.Value end
		function failing:Run() if self.FailNext then self.FailNext = false; error("injected later provider failure") end end
		function failing:Stop() self.Value = nil end
		local defaults = settings:_defaults()
		local target = settings:_defaults(); target.Levels.Master = 0.2; target.Enabled.SFX = false
		local initial = MementoTransaction.apply({
			Providers = { settings, failing }, TargetValues = { [settings] = target, [failing] = "target" }, WasRunning = false,
			Capture = function(provider) return provider:GetMemento() end,
			Stop = function(provider) provider:Stop() end,
			SetMemento = function(provider, value) provider:SetMemento(value) end,
			Run = function(provider) provider:Run() end,
		})
		assert(not initial.Ok and not graphOwner.Bound and settings._data == nil)
		for _, id in { "Master", "UI", "SFX", "World", "Music" } do
			assert(faders[id].Volume == Validator.levelToGain(config.FaderProfiles[id], defaults.Levels[id]))
		end
		local old = settings:_defaults(); old.Levels.Master = 0.7
		settings:SetMemento(old); settings:Run(); failing.Value = "old"; failing.FailNext = true
		local mementoChanged = 0
		local changed = 0
		settings.MementoChanged:Connect(function() mementoChanged += 1 end)
		settings.Changed:Connect(function() changed += 1 end)
		local masterVolume = faders.Master.Volume
		assert(settings:SetLevel("Master", settings:GetLevel("Master")))
		assert(settings:SetEnabled("SFX", settings:IsEnabled("SFX")))
		assert(mementoChanged == 0 and changed == 0 and faders.Master.Volume == masterVolume,
			"equal-value settings writes must be completely inert")
		local replacement = MementoTransaction.apply({
			Providers = { settings, failing },
			TargetValues = { [settings] = target, [failing] = "target" },
			PreviousValues = { [settings] = old, [failing] = "old" },
			WasRunning = true,
			Capture = function(provider) return provider:GetMemento() end,
			Stop = function(provider) provider:Stop() end,
			SetMemento = function(provider, value) provider:SetMemento(value) end,
			Run = function(provider) provider:Run() end,
		})
		assert(not replacement.Ok and replacement.RolledBack and graphOwner.Bound)
		assert(settings:GetMemento().Levels.Master == 0.7)
		assert(faders.Master.Volume == Validator.levelToGain(config.FaderProfiles.Master, 0.7))
		settings:Stop()
	end)

	test("AudioIntegration/AudioSettingsClientControllerSnapshotPatchAndTwoClientIsolation", function(scope)
		local function makeController(): (any, any, any, { any })
			local owner = makeSettingsGraphOwner()
			local settings = AudioSettingsClient.new(owner)
			local queued = {}
			local communication = {
				Queue = function(_self, messageType, payload, requestId, options)
					table.insert(queued, { Type = messageType, Payload = payload, RequestId = requestId, Options = options })
					return true
				end,
			}
			local controller = ClientSaveController.new({
				Id = "Global",
				Providers = { settings },
				Communication = communication,
				Logger = makeLogger({}),
			})
			scope:Defer(function() controller:Destroy() end)
			return controller, settings, owner, { queued, function(payload, requestId)
				controller:HandlePatchResult(payload, requestId)
			end }
		end

		local first, firstSettings, firstOwner, firstTransport = makeController()
		first:ApplySnapshot({ ControllerId = "Global", Revision = 1, Providers = {} })
		assert(first:IsReady() and first:GetRevision() == 1 and firstOwner.Bound)
		assert(firstSettings:GetLevel("Master") == validatedConfig().FaderProfiles.Master.DefaultLevel01)
		first:ApplySnapshot({
			ControllerId = "Global",
			Revision = 2,
			Providers = { AudioSettings = { Version = 1, Data = { Levels = { Master = 0.25 } } } },
		})
		assert(firstSettings:GetLevel("Master") == 0.25 and firstSettings:IsEnabled("SFX"))
		local before = firstSettings:GetMemento()
		local rejected = pcall(function()
			first:ApplySnapshot({
				ControllerId = "Global",
				Revision = 99,
				Providers = { AudioSettings = { Version = 1, Data = { Unknown = true } } },
			})
		end)
		assert(not rejected and first:GetRevision() == 2 and firstSettings:GetMemento().Levels.Master == before.Levels.Master,
			"unknown present settings must reject before runtime/revision mutation")
		assert(firstSettings:SetLevel("Master", 0.4))
		first:FlushClientChanges()
		local sent = firstTransport[1][1]
		assert(sent.Payload.ControllerId == "Global" and sent.Payload.BaseRevision == 2)
		assert(sent.Payload.Providers.AudioSettings.Version == 1 and sent.Payload.Providers.AudioSettings.Data.Levels.Master == 0.4)
		firstTransport[2]({ AcceptedProviders = { "AudioSettings" }, Revision = 3 }, sent.RequestId)
		assert(first:GetRevision() == 3 and first._pendingRequestId == nil)
		assert(firstSettings:SetLevel("Master", 0.5))
		first:FlushClientChanges()
		local pending = firstTransport[1][2]
		assert(pending.Payload.BaseRevision == 3 and pending.Payload.Providers.AudioSettings.Data.Levels.Master == 0.5)
		assert(firstSettings:SetLevel("Master", 0.6))
		assert(firstSettings:SetLevel("Master", 0.7))
		first:FlushClientChanges()
		assert(#firstTransport[1] == 2, "mutations while a patch is pending must coalesce instead of queueing in parallel")
		firstTransport[2]({ AcceptedProviders = { "AudioSettings" }, Revision = 4 }, pending.RequestId)
		assert(first:GetRevision() == 4 and first._pendingRequestId == nil)
		first:FlushClientChanges()
		local later = firstTransport[1][3]
		assert(later.Payload.BaseRevision == 4)
		assert(later.Payload.Providers.AudioSettings.Data.Levels.Master == 0.7,
			"the later patch must carry the exact latest coalesced value")
		firstTransport[2]({ AcceptedProviders = { "AudioSettings" }, Revision = 5 }, later.RequestId)
		assert(first:GetRevision() == 5 and first._pendingRequestId == nil)

		local second, secondSettings, secondOwner = makeController()
		second:ApplySnapshot({
			ControllerId = "Global",
			Revision = 7,
			Providers = { AudioSettings = { Version = 1, Data = { Levels = { Master = 0.8 }, Enabled = { SFX = false } } } },
		})
		assert(secondSettings:GetLevel("Master") == 0.8 and not secondSettings:IsEnabled("SFX"))
		assert(firstSettings:GetLevel("Master") == 0.7 and firstSettings:IsEnabled("SFX"))
		assert(firstOwner._result.Faders.Master.Volume ~= secondOwner._result.Faders.Master.Volume,
			"two client controllers must apply independent settings")
	end)

	test("AudioIntegration/AudioSettingsClientControllerHooksMandatoryEnvelopeAndRollback", function(scope)
		local function newController(providers)
			local communication = { RegisterHandler = function() end, Queue = function() return true end }
			local controller = ClientSaveController.new({ Id = "Global", Providers = providers, Communication = communication, Logger = makeLogger({}) })
			scope:Defer(function() controller:Destroy() end)
			return controller
		end
		local guarded = makeClientTestProvider("Guarded")
		local guardedController = newController({ guarded })
		guardedController:ApplySnapshot({ ControllerId = "Global", Revision = 4, Providers = { Guarded = { Version = 1, Data = "old" } } })
		for _, mode in { "Reject", "Throw" } do
			guarded.HookMode = mode
			assert(not pcall(function()
				guardedController:ApplySnapshot({ ControllerId = "Global", Revision = 5, Providers = { Guarded = { Version = 1, Data = "new" } } })
			end))
			assert(guardedController:GetRevision() == 4 and guarded.Value == "old" and guarded.Running,
				"protected envelope hook failure must preserve the running snapshot")
		end

		local noHook = makeClientTestProvider("NoHook")
		noHook.ValidateEnvelope = nil
		noHook.ReconcileSnapshotEnvelope = nil
		local noHookController = newController({ noHook })
		assert(not pcall(function()
			noHookController:ApplySnapshot({ ControllerId = "Global", Revision = 1, Providers = {} })
		end), "provider without reconciliation must retain mandatory envelope semantics")
		noHookController:ApplySnapshot({ ControllerId = "Global", Revision = 1, Providers = { NoHook = { Version = 1, Data = "value" } } })
		assert(noHook.Value == "value" and noHookController:GetRevision() == 1)

		local firstProvider = makeClientTestProvider("First")
		local failingProvider = makeClientTestProvider("Failing")
		local rollbackController = newController({ firstProvider, failingProvider })
		rollbackController:ApplySnapshot({
			ControllerId = "Global", Revision = 10,
			Providers = { First = { Version = 1, Data = "old-first" }, Failing = { Version = 1, Data = "old-failing" } },
		})
		failingProvider.FailNextRun = true
		assert(not pcall(function()
			rollbackController:ApplySnapshot({
				ControllerId = "Global", Revision = 11,
				Providers = { First = { Version = 1, Data = "new-first" }, Failing = { Version = 1, Data = "new-failing" } },
			})
		end))
		assert(rollbackController:GetRevision() == 10 and rollbackController:IsReady())
		assert(firstProvider.Value == "old-first" and failingProvider.Value == "old-failing")
	end)

	test("AudioIntegration/AudioSettingsServerControllerReconcilePatchHooksAndRollback", function(scope)
		local player = { UserId = 501 }
		local settings = AudioSettingsModule.new()
		settings:Initialize({ Enabled = true, Config = validatedConfig() })
		local missingDocument = {
			FormatVersion = 1, Revision = 0, Providers = {}, Metadata = { CreatedAt = 1, UpdatedAt = 1 }, Session = nil,
		}
		local controller = ServerSaveController.new({
			Id = "Global", Providers = { settings }, Storage = makeStorage(missingDocument), KeyResolver = function() return "settings" end, Logger = makeLogger({}),
		})
		scope:Defer(function() controller:Destroy() end)
		assert(controller:Load(player).Ok)
		local snapshot = controller:BuildSnapshot(player)
		assert(snapshot.Revision == 1 and snapshot.Providers.AudioSettings.Data.Levels.Master ~= nil,
			"missing known provider must reconcile defaults and advance the server revision")
		local acceptedData = settings:GetMemento(player)
		acceptedData.Levels.Master = 0.22
		local accepted = controller:ApplyClientPatch(player, {
			Providers = { AudioSettings = { Version = 1, Data = acceptedData } },
		})
		assert(#accepted.AcceptedProviders == 1 and accepted.Revision == 2 and settings:GetMemento(player).Levels.Master == 0.22)
		local partial = controller:ApplyClientPatch(player, {
			Providers = { AudioSettings = { Version = 1, Data = { Levels = { Master = 0.5 } } } },
		})
		assert(#partial.RejectedProviders == 1 and partial.Revision == 2 and settings:GetMemento(player).Levels.Master == 0.22)
		local unknown = controller:ApplyClientPatch(player, { Providers = { Unknown = { Version = 1, Data = {} } } })
		assert(#unknown.RejectedProviders == 1 and unknown.Revision == 2,
			"all-rejected patches must not advance revision")

		for _, mode in { "Reject", "Throw" } do
			local guarded = makeServerTestProvider("Guarded", true)
			guarded.HookMode = mode
			local guardedController = ServerSaveController.new({
				Id = "Guarded", Providers = { guarded },
				Storage = makeStorage({ FormatVersion = 1, Revision = 3, Providers = { Guarded = { Version = 1, Data = "value" } }, Metadata = { CreatedAt = 1, UpdatedAt = 1 } }),
				KeyResolver = function() return mode end, Logger = makeLogger({}),
			})
			scope:Defer(function() guardedController:Destroy() end)
			local load = guardedController:Load({ UserId = if mode == "Reject" then 601 else 602 })
			assert(not load.Ok and load.Code == "ApplyFailed" and guarded.SetCount == 0,
				"protected server envelope hook failure must reject before provider mutation")
		end

		local noHook = makeServerTestProvider("NoHook", false)
		local noHookPlayer = { UserId = 603 }
		local noHookController = ServerSaveController.new({
			Id = "NoHook", Providers = { noHook },
			Storage = makeStorage({ FormatVersion = 1, Revision = 0, Providers = {}, Metadata = { CreatedAt = 1, UpdatedAt = 1 } }),
			KeyResolver = function() return "no-hook" end, Logger = makeLogger({}),
		})
		scope:Defer(function() noHookController:Destroy() end)
		assert(noHookController:Load(noHookPlayer).Ok and noHook.Values[noHookPlayer] == "default")

		local firstProvider = makeServerTestProvider("First", true)
		local failingProvider = makeServerTestProvider("Failing", true)
		local rollbackPlayer = { UserId = 604 }
		local rollbackDocument = {
			FormatVersion = 1, Revision = 8,
			Providers = { First = { Version = 1, Data = "old-first" }, Failing = { Version = 1, Data = "old-failing" } },
			Metadata = { CreatedAt = 1, UpdatedAt = 1 },
		}
		local rollbackController = ServerSaveController.new({
			Id = "Rollback", Providers = { firstProvider, failingProvider }, Storage = makeStorage(rollbackDocument),
			KeyResolver = function() return "rollback" end, Logger = makeLogger({}),
		})
		scope:Defer(function() rollbackController:Destroy() end)
		assert(rollbackController:Load(rollbackPlayer).Ok)
		firstProvider.Values[rollbackPlayer] = "dirty-first"
		rollbackController:MarkDirty(rollbackPlayer, "First")
		failingProvider.FailNextRun = true
		assert(not pcall(function()
			rollbackController:ApplyMemento(rollbackPlayer, {
				FormatVersion = 1, Revision = 9,
				Providers = { First = { Version = 1, Data = "new-first" }, Failing = { Version = 1, Data = "new-failing" } },
				Metadata = { CreatedAt = 1, UpdatedAt = 1 },
			})
		end))
		assert(rollbackController:GetState(rollbackPlayer) == "Loaded")
		assert(firstProvider.Values[rollbackPlayer] == "dirty-first" and failingProvider.Values[rollbackPlayer] == "old-failing")
		local rolledBack = rollbackController:BuildSnapshot(rollbackPlayer)
		assert(rolledBack.Revision == 9 and rolledBack.Providers.First.Data == "dirty-first",
			"rollback must keep dirty data under the revision produced by shared capture")
		assert(rollbackController:FlushDirty(rollbackPlayer))
		assert(rollbackController:BuildSnapshot(rollbackPlayer).Revision == 9,
			"a later capture must not discover dirty data already folded into an old revision")
	end)

	test("AudioIntegration/ServerApplyPreparationLifecycleReservation", function(scope)
		local provider = makeServerTestProvider("Yielding", true)
		local player = { UserId = 605 }
		local saveCount = 0
		local releaseCount = 0
		local storage = {
			Load = function()
				return {
					Ok = true,
					Document = {
						FormatVersion = 1, Revision = 4,
						Providers = { Yielding = { Version = 1, Data = "old" } },
						Metadata = { CreatedAt = 1, UpdatedAt = 1 },
					},
				}
			end,
			Save = function() saveCount += 1; return { Ok = true } end,
			Release = function() releaseCount += 1; return { Ok = true } end,
		}
		local controller = ServerSaveController.new({
			Id = "Yielding", Providers = { provider }, Storage = storage,
			KeyResolver = function() return "yielding" end, Logger = makeLogger({}),
		})
		scope:Defer(function() controller:Destroy() end)
		assert(controller:Load(player).Ok)
		provider.Values[player] = "dirty"
		controller:MarkDirty(player, "Yielding")
		local runtime = controller._runtimes[player]
		local beforeDocument = runtime.Document
		provider.HookMode = "YieldReject"
		local applyThread = coroutine.create(function()
			return pcall(function()
				controller:ApplyMemento(player, {
					FormatVersion = 1, Revision = 5,
					Providers = { Yielding = { Version = 1, Data = "target" } },
					Metadata = { CreatedAt = 1, UpdatedAt = 1 },
				})
			end)
		end)
		local resumed, marker = coroutine.resume(applyThread)
		assert(resumed and marker == "ValidateEnvelopeYielded" and controller:GetState(player) == "Applying")
		local flushed, flushReason = controller:FlushDirty(player)
		assert(not flushed and flushReason == "Busy")
		task.wait()
		assert(runtime.Document == beforeDocument and runtime.Document.Revision == 4
			and runtime.Document.Providers.Yielding.Data == "old" and runtime.DirtyProviders.Yielding,
			"Heartbeat and explicit flush must not consume dirty state while preparation is reserved")

		local closeDone = false
		local closeResult = nil
		task.spawn(function()
			closeResult = controller:Close(player, true)
			closeDone = true
		end)
		task.wait()
		assert(not closeDone and saveCount == 0 and releaseCount == 0 and provider.Running[player],
			"Close must wait without saving, stopping, releasing, or removing a reserved runtime")
		local finished, applyOk = coroutine.resume(applyThread)
		assert(finished and not applyOk and coroutine.status(applyThread) == "dead")
		for _ = 1, 10 do
			if closeDone then break end
			task.wait()
		end
		assert(closeDone and closeResult.Ok and saveCount == 1 and releaseCount == 1)
		assert(controller:GetState(player) == "NotLoaded" and not provider.Running[player])
	end)

	test("AudioIntegration/ServerLifecycleOwnershipReciprocalInterleavings", function(scope)
		local function document(providerId: string, revision: number, value: string): any
			return {
				FormatVersion = 1,
				Revision = revision,
				Providers = { [providerId] = { Version = 1, Data = value } },
				Metadata = { CreatedAt = 1, UpdatedAt = 1 },
			}
		end

		do
			local player = { UserId = 606 }
			local provider = makeServerTestProvider("SaveOwned", true)
			local saved = {}
			local releases = 0
			local storage = {
				Load = function() return { Ok = true, Document = document("SaveOwned", 11, "old") } end,
				Save = function(_self, _key, candidate)
					table.insert(saved, TableUtil.deepCopy(candidate))
					coroutine.yield("SaveYielded")
					return { Ok = true }
				end,
				Release = function() releases += 1; return { Ok = true } end,
			}
			local controller = ServerSaveController.new({
				Id = "SaveOwned", Providers = { provider }, Storage = storage,
				KeyResolver = function() return "save-owned" end, Logger = makeLogger({}),
			})
			scope:Defer(function() controller:Destroy(false) end)
			assert(controller:Load(player).Ok)
			provider.Values[player] = "dirty-before-save"
			controller:MarkDirty(player, "SaveOwned")
			local saveThread = coroutine.create(function() return controller:ForceSave(player, "Race") end)
			local started, marker = coroutine.resume(saveThread)
			assert(started and marker == "SaveYielded" and controller:GetState(player) == "Saving")
			local beforeApply = TableUtil.deepCopy(controller._runtimes[player].Document)
			assert(not pcall(function() controller:ApplyMemento(player, document("SaveOwned", 1, "target")) end),
				"Apply must reject while an older persistence operation owns the runtime")
			assert(controller:GetState(player) == "Saving" and provider.Values[player] == "dirty-before-save")
			assert(TableUtil.deepEqual(controller._runtimes[player].Document, beforeApply)
				and controller._runtimes[player].Dirty,
				"rejected Apply must not overwrite the save generation or clear its dirty acknowledgement")
			local resumed, result = coroutine.resume(saveThread)
			assert(resumed and result.Ok and coroutine.status(saveThread) == "dead")
			assert(#saved == 1 and saved[1].Providers.SaveOwned.Data == "dirty-before-save"
				and controller:GetState(player) == "Loaded" and not controller._runtimes[player].Dirty)
			assert(releases == 0 and provider.Running[player],
				"save/apply exclusion must not stop providers or release the session lock")
		end

		do
			local player = { UserId = 607 }
			local provider = makeServerTestProvider("CloseOwned", true)
			local releaseCount = 0
			local saveCount = 0
			provider.BeforeMementoGet = function()
				coroutine.yield("CloseCaptureYielded")
			end
			local storage = {
				Load = function() return { Ok = true, Document = document("CloseOwned", 4, "old") } end,
				Save = function() saveCount += 1; return { Ok = true } end,
				Release = function() releaseCount += 1; return { Ok = true } end,
			}
			local controller = ServerSaveController.new({
				Id = "CloseOwned", Providers = { provider }, Storage = storage,
				KeyResolver = function() return "close-owned" end, Logger = makeLogger({}),
			})
			scope:Defer(function() controller:Destroy(false) end)
			assert(controller:Load(player).Ok)
			local closeThread = coroutine.create(function() return controller:Close(player, true) end)
			local started, marker = coroutine.resume(closeThread)
			assert(started and marker == "CloseCaptureYielded" and controller:GetState(player) == "Closing")
			assert(not pcall(function() controller:ApplyMemento(player, document("CloseOwned", 5, "target")) end),
				"Apply must reject while Close owns the runtime")
			assert(controller:GetState(player) == "Closing" and provider.Values[player] == "old"
				and provider.Running[player] and saveCount == 0 and releaseCount == 0,
				"rejected Apply must not overwrite Close state or create an orphan continuation")
			provider.BeforeMementoGet = nil
			local resumed, result = coroutine.resume(closeThread)
			assert(resumed and result.Ok and coroutine.status(closeThread) == "dead")
			assert(controller:GetState(player) == "NotLoaded" and not provider.Running[player]
				and saveCount == 0 and releaseCount == 1,
				`close result state={controller:GetState(player)} running={tostring(provider.Running[player])} saves={saveCount} releases={releaseCount}`)
		end
	end)

	test("AudioIntegration/ServerStandaloneCaptureOwnershipReciprocalInterleavings", function(scope)
		local function document(providerId: string, revision: number, value: string): any
			return {
				FormatVersion = 1,
				Revision = revision,
				Providers = { [providerId] = { Version = 1, Data = value } },
				Metadata = { CreatedAt = 1, UpdatedAt = 1 },
			}
		end

		for index, captureKind in { "FlushDirty", "Heartbeat", "BuildSnapshot" } do
			local providerId = `Capture{captureKind}`
			local player = { UserId = 6_100 + index }
			local provider = makeServerTestProvider(providerId, true)
			local heartbeat = makeSignal()
			local saved = {}
			local releaseCount = 0
			local runCount = 0
			local stopCount = 0
			local yieldCapture = false
			local yieldProjection = false
			local baseGet = provider.GetMemento
			local baseRun = provider.Run
			local baseStop = provider.Stop
			function provider:GetMemento(owner)
				local capturedValue = baseGet(self, owner)
				if yieldCapture then
					yieldCapture = false
					coroutine.yield(`{captureKind}CaptureYielded`)
				end
				return capturedValue
			end
			function provider:ToClientMemento(_owner, value)
				if yieldProjection then
					yieldProjection = false
					coroutine.yield("BuildSnapshotProjectionYielded")
				end
				return value
			end
			function provider:Run(owner)
				runCount += 1
				baseRun(self, owner)
			end
			function provider:Stop(owner)
				stopCount += 1
				baseStop(self, owner)
			end
			local storage = {
				Load = function() return { Ok = true, Document = document(providerId, 7, "loaded") } end,
				Save = function(_self, _key, candidate)
					table.insert(saved, TableUtil.deepCopy(candidate))
					return { Ok = true }
				end,
				Release = function() releaseCount += 1; return { Ok = true } end,
			}
			local controller = ServerSaveController.new({
				Id = providerId,
				Providers = { provider },
				Storage = storage,
				KeyResolver = function() return string.lower(captureKind) end,
				Heartbeat = heartbeat,
				Logger = makeLogger({}),
			})
			scope:Defer(function() controller:Destroy(false) end)
			assert(controller:Load(player).Ok and runCount == 1)
			provider.Values[player] = "dirty-before-capture"
			controller:MarkDirty(player, providerId)
			yieldCapture = true
			yieldProjection = captureKind == "BuildSnapshot"

			local captureThread = coroutine.create(function()
				if captureKind == "FlushDirty" then
					return controller:FlushDirty(player)
				elseif captureKind == "Heartbeat" then
					heartbeat:Fire()
					return true
				else
					return controller:BuildSnapshot(player)
				end
			end)
			local started, marker = coroutine.resume(captureThread)
			assert(started and marker == `{captureKind}CaptureYielded`)
			local runtime = controller._runtimes[player]
			local captureState = if captureKind == "BuildSnapshot" then "Snapshotting" else "Capturing"
			assert(runtime.State == captureState and runtime.ActiveOperation ~= nil
				and next(runtime.DirtyProviders) == nil and runtime.Document.Revision == 7)
			assert(not pcall(function()
				controller:ApplyMemento(player, document(providerId, 50, "target"))
			end), `{captureKind}: Apply must reject while the older capture owns the runtime`)
			assert(runtime.State == captureState and runtime.Document.Providers[providerId].Data == "loaded"
				and provider.Values[player] == "dirty-before-capture" and #saved == 0
				and releaseCount == 0 and stopCount == 0 and runCount == 1,
				`{captureKind}: rejected Apply changed capture state or provider/storage ownership`)

			local resumed, result = coroutine.resume(captureThread)
			if captureKind == "BuildSnapshot" then
				assert(resumed and result == "BuildSnapshotProjectionYielded")
				assert(not pcall(function()
					controller:ApplyMemento(player, document(providerId, 50, "target"))
				end), "Apply must also reject while BuildSnapshot projection owns the runtime")
				resumed, result = coroutine.resume(captureThread)
			end
			assert(resumed and coroutine.status(captureThread) == "dead")
			if captureKind == "FlushDirty" then
				assert(result == true)
			elseif captureKind == "BuildSnapshot" then
				assert(result.Revision == 8 and result.Providers[providerId].Data == "dirty-before-capture")
			end
			assert(runtime.State == "Loaded" and runtime.ActiveOperation == nil
				and runtime.Document.Revision == 8
				and runtime.Document.Providers[providerId].Data == "dirty-before-capture"
				and next(runtime.DirtyProviders) == nil and runtime.Dirty,
				`{captureKind}: owned capture did not commit one coherent generation`)

			controller:ApplyMemento(player, document(providerId, 50, "target"))
			assert(runtime.State == "Loaded" and runtime.Document.Revision == 50
				and runtime.Document.Providers[providerId].Data == "target"
				and provider.Values[player] == "target" and next(runtime.DirtyProviders) == nil
				and not runtime.Dirty and stopCount == 1 and runCount == 2,
				`{captureKind}: replacement did not preserve document/provider equality`)
			controller:MarkDirty(player, providerId)
			local saveResult = controller:ForceSave(player, "PostReplacement")
			assert(saveResult.Ok and #saved == 1 and saved[1].Revision == 50
				and saved[1].Providers[providerId].Data == "target" and not runtime.Dirty,
				`{captureKind}: post-replacement persistence observed stale capture data`)
			task.wait()
			assert(runtime.State == "Loaded" and runtime.ActiveOperation == nil
				and runtime.Document.Providers[providerId].Data == provider.Values[player]
				and #saved == 1 and releaseCount == 0 and provider.Running[player],
				`{captureKind}: an orphan continuation changed runtime/document/storage state`)
		end
	end)

	test("AudioIntegration/FailedRollbackTerminalProviderCleanup", function(scope)
		local function makeTracked(id: string, client: boolean): any
			local provider = {
				Id = id, Version = 1, Authority = if client then "Client" else "Server",
				ClientSnapshotPolicy = "Include", Values = {}, Value = nil,
				Active = false, StopCount = 0, FailTargetRun = false, FailTargetStop = false,
			}
			function provider:CreateDefault() return "old" end
			function provider:ReconcileMemento(_player, value) return value end
			function provider:ReconcileSnapshotEnvelope(envelope) return true, envelope end
			function provider:ValidateMemento(...)
				local args = { ... }
				local value = args[#args]
				return typeof(value) == "string", value, "InvalidTestValue"
			end
			function provider:SetMemento(...)
				local args = { ... }
				local value = args[#args]
				if client then self.Value = value else self.Values[args[1]] = value end
			end
			function provider:GetMemento(player)
				return if client then self.Value else self.Values[player]
			end
			function provider:Run(player)
				local value = if client then self.Value else self.Values[player]
				self.Active = true
				if self.FailTargetRun and value == "new" then error("injected target Run failure") end
			end
			function provider:Stop(player)
				local value = if client then self.Value else self.Values[player]
				self.StopCount += 1
				if self.FailTargetStop and value == "new" then
					self.FailTargetStop = false
					error("injected target cleanup failure")
				end
				self.Active = false
			end
			return provider
		end

		do
			local first = makeTracked("ClientFirst", true)
			local failing = makeTracked("ClientFailing", true)
			local controller = ClientSaveController.new({
				Id = "Cleanup", Providers = { first, failing },
				Communication = { RegisterHandler = function() end, Queue = function() return true end },
				Logger = makeLogger({}),
			})
			controller:ApplySnapshot({ ControllerId = "Cleanup", Revision = 1, Providers = {
				ClientFirst = { Version = 1, Data = "old" }, ClientFailing = { Version = 1, Data = "old" },
			} })
			failing.FailTargetRun = true; failing.FailTargetStop = true
			assert(not pcall(function() controller:ApplySnapshot({ ControllerId = "Cleanup", Revision = 2, Providers = {
				ClientFirst = { Version = 1, Data = "new" }, ClientFailing = { Version = 1, Data = "new" },
			} }) end))
			assert(not controller:IsReady() and first.Active and failing.Active,
				"failed cleanup must retain exact possibly-active provider ownership")
			local firstStops, failingStops = first.StopCount, failing.StopCount
			controller:Destroy()
			assert(not first.Active and not failing.Active and first.StopCount == firstStops + 1
				and failing.StopCount == failingStops + 1,
				"Destroy must reverse-stop restored providers even when aggregate Running is false")
		end

		do
			local player = { UserId = 608 }
			local first = makeTracked("ServerFirst", false)
			local failing = makeTracked("ServerFailing", false)
			local releases = 0
			local storage = {
				Load = function() return { Ok = true, Document = {
					FormatVersion = 1, Revision = 1, Providers = {
						ServerFirst = { Version = 1, Data = "old" }, ServerFailing = { Version = 1, Data = "old" },
					}, Metadata = { CreatedAt = 1, UpdatedAt = 1 },
				} } end,
				Save = function() return { Ok = true } end,
				Release = function() releases += 1; return { Ok = true } end,
			}
			local controller = ServerSaveController.new({
				Id = "Cleanup", Providers = { first, failing }, Storage = storage,
				KeyResolver = function() return "cleanup" end, Logger = makeLogger({}),
			})
			scope:Defer(function() controller:Destroy(false) end)
			assert(controller:Load(player).Ok)
			failing.FailTargetRun = true; failing.FailTargetStop = true
			assert(not pcall(function() controller:ApplyMemento(player, {
				FormatVersion = 1, Revision = 2, Providers = {
					ServerFirst = { Version = 1, Data = "new" }, ServerFailing = { Version = 1, Data = "new" },
				}, Metadata = { CreatedAt = 1, UpdatedAt = 1 },
			}) end))
			assert(controller:GetState(player) == "ApplyFailed" and first.Active and failing.Active)
			local firstStops, failingStops = first.StopCount, failing.StopCount
			local closed = controller:Close(player, false)
			assert(closed.Ok and releases == 1 and controller:GetState(player) == "NotLoaded")
			assert(not first.Active and not failing.Active and first.StopCount == firstStops + 1
				and failing.StopCount == failingStops + 1,
				"Close must stop restored providers before releasing storage/removing runtime")
		end
	end)

	test("AudioIntegration/ServerPreparedSizeFinalRevisionBoundary", function(scope)
		local timestamp = os.time()
		local expectedFinal = {
			FormatVersion = 1, Revision = 10,
			Providers = { Sized = { Version = 1, Data = "default" } },
			Metadata = { CreatedAt = 1, UpdatedAt = timestamp },
		}
		local measured, exactSize = SaveSerialize.measureEncodedSize(expectedFinal)
		assert(measured and exactSize ~= nil)
		local initial = {
			FormatVersion = 1, Revision = 8,
			Providers = { Sized = { Version = 1, Data = "old" } },
			Metadata = { CreatedAt = 1, UpdatedAt = 1 },
		}
		local target = {
			FormatVersion = 1, Revision = 9, Providers = {},
			Metadata = { CreatedAt = 1, UpdatedAt = timestamp },
		}
		local function makeSized(limit: number, userId: number): (any, any, any)
			local provider = makeServerTestProvider("Sized", true)
			local player = { UserId = userId }
			local controller = ServerSaveController.new({
				Id = `Sized{userId}`, Providers = { provider }, Storage = makeStorage(initial),
				KeyResolver = function() return tostring(userId) end,
				SoftSerializedBytesLimit = limit, Logger = makeLogger({}),
			})
			scope:Defer(function() controller:Destroy() end)
			assert(controller:Load(player).Ok)
			return controller, provider, player
		end
		local equalController, equalProvider, equalPlayer = makeSized(exactSize :: number, 606)
		equalController:ApplyMemento(equalPlayer, target)
		local equalRuntime = equalController._runtimes[equalPlayer]
		local finalMeasured, finalSize = SaveSerialize.measureEncodedSize(equalRuntime.Document)
		assert(finalMeasured and finalSize == exactSize and equalRuntime.Document.Revision == 10)
		assert(equalProvider.Values[equalPlayer] == "default")

		local belowController, belowProvider, belowPlayer = makeSized((exactSize :: number) - 1, 607)
		local before = belowController._runtimes[belowPlayer].Document
		assert(not pcall(function() belowController:ApplyMemento(belowPlayer, target) end))
		assert(belowController:GetState(belowPlayer) == "Loaded"
			and belowController._runtimes[belowPlayer].Document == before
			and belowController._runtimes[belowPlayer].Document.Revision == 8
			and belowProvider.Values[belowPlayer] == "old",
			"one byte below the finalized candidate must reject before live mutation")
	end)

	test("AudioIntegration/AudioSettingsEnvelopeHookFailureIsolation", function(scope)
		for index, mode in { "Reject", "Throw" } do
			local firstProvider = makeServerTestProvider("First", true)
			local secondProvider = makeServerTestProvider("Second", true)
			local player = { UserId = 700 + index }
			local controller = ServerSaveController.new({
				Id = `Dirty{mode}`,
				Providers = { firstProvider, secondProvider },
				Storage = makeStorage({
					FormatVersion = 1,
					Revision = 12,
					Providers = {
						First = { Version = 1, Data = "old-first" },
						Second = { Version = 1, Data = "old-second" },
					},
					Metadata = { CreatedAt = 1, UpdatedAt = 1 },
				}),
				KeyResolver = function() return mode end,
				Logger = makeLogger({}),
			})
			scope:Defer(function() controller:Destroy() end)
			assert(controller:Load(player).Ok)
			firstProvider.Values[player] = "dirty-first"
			controller:MarkDirty(player, "First")
			local runtime = controller._runtimes[player]
			local firstSetCount = firstProvider.SetCount
			local secondSetCount = secondProvider.SetCount
			secondProvider.HookMode = mode
			assert(not pcall(function()
				controller:ApplyMemento(player, {
					FormatVersion = 1,
					Revision = 13,
					Providers = {
						First = { Version = 1, Data = "target-first" },
						Second = { Version = 1, Data = "target-second" },
					},
					Metadata = { CreatedAt = 1, UpdatedAt = 1 },
				})
			end), `dirty second-provider {mode} must reject the target before current-state capture`)
			assert(firstProvider.Values[player] == "dirty-first" and secondProvider.Values[player] == "old-second")
			assert(firstProvider.SetCount == firstSetCount and secondProvider.SetCount == secondSetCount,
				"failed target preparation must not invoke provider mutation")
			assert(runtime.Document.Revision == 12 and runtime.Document.Providers.First.Data == "old-first")
			assert(runtime.Dirty and runtime.DirtyProviders.First and next(runtime.DirtyProviders, "First") == nil,
				"failed target preparation must preserve the exact dirty-provider set")
		end
	end)

	test("AudioIntegration/HybridAuthoritativeRateAndPlayerCleanup", function()
		local events = {}
		local removing = makeSignal()
		local sender = { UserId = 10 }
		local recipients = { { UserId = 20 }, { UserId = 30 } }
		local registered = nil
		local queued = {}
		local communication = {
			RegisterHandler = function(_self, messageType, validator, handler) registered = { Type = messageType, Validate = validator, Handle = handler } end,
			IsClientReady = function() return true end,
			QueuePresentationAtomic = function(_self, players, messageType, payload)
				for _, player in players do
					table.insert(queued, { Player = player, Type = messageType, Payload = payload })
				end
				return true
			end,
		}
		local playersModule = { PlayerRemoving = removing, GetPlayers = function() return recipients end }
		local variant = { CueId = "Cue", VariantId = "V", PlayerType = "SFX", AllowClientHybrid = true, Looping = false, SourceVolume = 0.5, PlaybackSpeed = 1, PlaybackRegion = { Start = 1, End = 3 } }
		local startup = {
			Enabled = true,
			Catalog = { GetNamedVariant = function() return variant end },
			Config = { PlayerTypes = { SFX = { HybridRatePerSecond = 1, HybridBurst = 1, SourceVolumeMin = 0, SourceVolumeMax = 1, PlaybackSpeedMin = 0.5, PlaybackSpeedMax = 2 } } },
		}
		local controller = HybridServer.new({ Communication = communication, PlayersModule = playersModule, Clock = function() return 0 end, Logger = makeLogger(events) })
		controller:Register(startup)
		assert(registered.Type == AudioProtocol.MessageTypes.HybridIntent)
		local invalid = { Version = 1, CueId = "Cue", VariantId = "V", TimePosition = 3, Spatial = { Kind = "None" } }
		assert(registered.Validate(invalid)); registered.Handle(sender, invalid)
		assert(#queued == 0 and next(controller._rate) == nil)
		local valid = { Version = 1, CueId = "Cue", VariantId = "V", TimePosition = 1, Spatial = { Kind = "None" } }
		registered.Handle(sender, valid)
		assert(#queued == 2)
		registered.Handle(sender, valid)
		assert(#queued == 2 and events[#events].Event == "RateLimited")
		removing:Fire(sender)
		for key in controller._rate do assert(not key:find(":10", 1, true), "departed player buckets must be removed") end
	end)

	test("AudioIntegration/HybridFanoutAtomicAndRegistrationRetry", function()
		local removing = makeSignal()
		local registerAttempts = 0
		local registered = nil
		local queued = 0
		local communication = {
			RegisterHandler = function(_self, _messageType, _validator, handler)
				registerAttempts += 1
				if registerAttempts == 1 then error("injected register failure") end
				registered = handler
			end,
			IsClientReady = function() return true end,
			QueuePresentationAtomic = function(_self, players)
				queued += #players
				return true
			end,
		}
		local recipients = {}
		for userId = 1, 2049 do recipients[userId] = { UserId = userId + 100 } end
		local playersModule = { PlayerRemoving = removing, GetPlayers = function() return recipients end }
		local variant = { CueId = "Cue", VariantId = "V", PlayerType = "SFX", AllowClientHybrid = true, Looping = false, SourceVolume = 0.5, PlaybackSpeed = 1 }
		local startup = { Enabled = true, Catalog = { GetNamedVariant = function() return variant end }, Config = { PlayerTypes = { SFX = { HybridRatePerSecond = 30, HybridBurst = 60, SourceVolumeMin = 0, SourceVolumeMax = 1, PlaybackSpeedMin = 0.5, PlaybackSpeedMax = 2 } } } }
		local controller = HybridServer.new({ Communication = communication, PlayersModule = playersModule, Clock = function() return 0 end, Logger = makeLogger({}) })
		assert(not pcall(function() controller:Register(startup) end) and not controller._registered and controller._startup == nil)
		controller:Register(startup)
		assert(controller._registered and registerAttempts == 2)
		local payload = { Version = 1, CueId = "Cue", VariantId = "V", Spatial = { Kind = "None" } }
		registered({ UserId = 1 }, payload)
		assert(queued == 0, "fanout over budget must queue nobody")
		recipients = { { UserId = 999 } }
		registered({ UserId = 1 }, payload)
		assert(queued == 1, "failed atomic reservation must not consume other buckets")
		local clientAttempts = 0
		local clientCommunication = { RegisterHandler = function() clientAttempts += 1; if clientAttempts == 1 then error("injected") end end }
		local client = HybridClient.new({ Communication = clientCommunication, Logger = makeLogger({}), PlayReceivedPresentation = function() end })
		assert(not pcall(function() client:Register(startup) end) and not client._registered)
		client:Register(startup)
		assert(client._registered and clientAttempts == 2)
	end)

	test("AudioIntegration/HybridPolicyBeforePredictionAndQueueRejection", function(scope)
		local events = {}
		local queueCount = 0
		local config = {
			InteractionGroupId = "AudioPlayback.Private.v1",
			SpatialProfilesById = { Default = { DistanceAttenuation = NumberSequence.new(1) } },
			PlayerTypes = {
				UI = { ClientMaxActive = 0, ClientMaxRetained = 0, HybridRatePerSecond = 0, HybridBurst = 0 },
				SFX = { ClientMaxActive = 2, ClientMaxRetained = 1, HybridRatePerSecond = 0, HybridBurst = 0, SourceVolumeMin = 0, SourceVolumeMax = 1, PlaybackSpeedMin = 0.5, PlaybackSpeedMax = 2, LoadTimeoutSeconds = 3 },
				World = { ClientMaxActive = 2, ClientMaxRetained = 1, HybridRatePerSecond = 2, HybridBurst = 2, SourceVolumeMin = 0, SourceVolumeMax = 1, PlaybackSpeedMin = 0.5, PlaybackSpeedMax = 2, LoadTimeoutSeconds = 3 },
			},
		}
		local variant = { CueId = "Cue", VariantId = "V", ContentId = "rbxassetid://1", PlayerType = "SFX", AllowClientHybrid = true, Looping = false, SourceVolume = 0.5, PlaybackSpeed = 1 }
		local named: any = variant
		local catalog = {
			Resolve = function() return variant end,
			GetNamedVariant = function() return named end,
		}
		local ordinary, created = makeOrdinaryClient(scope, catalog, config, events)
		local hybrid = HybridClient.new({
			Communication = { Queue = function() queueCount += 1; return false end },
			Logger = makeLogger(events),
			PlayReceivedPresentation = function() end,
		})
		ordinary:BindHybridIntentSender(hybrid)

		local function reject(expectedReason: string, callback: () -> any)
			local beforeWarnings = #events
			local handle = callback()
			assert(not handle:IsActive() and #created == 0 and queueCount == 0)
			assert(#events == beforeWarnings + 1 and events[#events].Event == "HybridNotAllowed")
			assert(events[#events].Data.ReasonCode == expectedReason)
		end

		reject("HybridTypeDisabled", function() return ordinary:PlayHybrid({ CueId = "Cue", VariantId = "V" }) end)
		config.PlayerTypes.SFX.HybridRatePerSecond = 2
		config.PlayerTypes.SFX.HybridBurst = 2
		named = table.clone(variant)
		reject("HybridNamedVariantRequired", function() return ordinary:PlayHybrid({ CueId = "Cue", VariantId = "V" }) end)
		named = variant
		variant.PlayerType = "Music"
		reject("TypeMismatch", function() return ordinary:PlayHybrid({ CueId = "Cue", VariantId = "V" }) end)
		variant.PlayerType = "SFX"
		variant.Looping = true
		reject("HybridLoopUnsupported", function() return ordinary:PlayHybrid({ CueId = "Cue", VariantId = "V" }) end)
		variant.Looping = false
		variant.AllowClientHybrid = false
		reject("HybridNotAllowed", function() return ordinary:PlayHybrid({ CueId = "Cue", VariantId = "V" }) end)
		variant.AllowClientHybrid = true
		reject("UnexpectedSpatialSource", function() return ordinary:PlayHybridAt({ CueId = "Cue", VariantId = "V" }, Vector3.zero) end)
		reject("InvalidRequest", function() return ordinary:PlayHybrid({ CueId = "Cue", VariantId = "V" }, { VolumeMultiplier = 3 }) end)
		variant.PlayerType = "World"
		variant.SpatialProfileId = "Default"
		reject("InvalidSchema", function()
			return ordinary:PlayHybridAt({ CueId = "Cue", VariantId = "V" }, Vector3.new(1_000_001, 0, 0))
		end)
		variant.PlayerType = "SFX"
		variant.SpatialProfileId = nil

		local handle = ordinary:PlayHybrid({ CueId = "Cue", VariantId = "V" })
		assert(handle:IsActive() and #created == 1 and queueCount == 1)
		assert(events[#events].Event == "HybridQueueRejected", "Queue false must log once after prediction")
		assert(handle:IsActive() and queueCount == 1, "Queue false must keep prediction and never retry")
		handle:Stop()
	end)

	test("AudioIntegration/HybridAtomicQueueFailureAndExactPairReuse", function(scope)
		local first = { UserId = 1 }
		local second = { UserId = 2 }
		local host: any = {
			_outgoing = { [first] = { { Message = { Type = "Before" }, Priority = "Presentation", EstimatedBytes = 1 } } },
			_outgoingBytes = { [first] = 1 },
			_droppedPresentation = { [first] = 4 },
		}
		function host:Queue(player, messageType, payload)
			if player == second then return false end
			local queue = self._outgoing[player] or {}
			self._outgoing[player] = queue
			table.insert(queue, { Message = { Type = messageType, Payload = payload }, Priority = "Presentation", EstimatedBytes = 2 })
			self._outgoingBytes[player] = (self._outgoingBytes[player] or 0) + 2
			self._droppedPresentation[player] = (self._droppedPresentation[player] or 0) + 1
			return true
		end
		assert(not pcall(function()
			CommunicationServer.QueuePresentationAtomic(host, { [1] = first, [3] = second },
				"Audio.HybridPresentationV1", { Value = 1 }, nil)
		end), "QueuePresentationAtomic must reject sparse public input before queue mutation")
		assert(#host._outgoing[first] == 1 and host._outgoing[second] == nil)
		assert(not CommunicationServer.QueuePresentationAtomic(host, { first, second }, "Audio.HybridPresentationV1", { Value = 1 }, nil))
		assert(#host._outgoing[first] == 1 and host._outgoing[first][1].Message.Type == "Before")
		assert(host._outgoingBytes[first] == 1 and host._droppedPresentation[first] == 4)
		assert(host._outgoing[second] == nil and host._outgoingBytes[second] == nil,
			"failed atomic fanout must restore every recipient")

		local config = {
			InteractionGroupId = "AudioPlayback.Private.v1",
			SpatialProfilesById = {},
			PlayerTypes = {
				UI = { ClientMaxActive = 0, ClientMaxRetained = 0, HybridRatePerSecond = 0, HybridBurst = 0 },
				SFX = { ClientMaxActive = 2, ClientMaxRetained = 1, HybridRatePerSecond = 2, HybridBurst = 2, SourceVolumeMin = 0, SourceVolumeMax = 1, PlaybackSpeedMin = 0.5, PlaybackSpeedMax = 2, LoadTimeoutSeconds = 3 },
				World = { ClientMaxActive = 0, ClientMaxRetained = 0, HybridRatePerSecond = 0, HybridBurst = 0 },
			},
		}
		local variant = { CueId = "Cue", VariantId = "V", ContentId = "rbxassetid://1", PlayerType = "SFX", AllowClientHybrid = true, Looping = false, SourceVolume = 0.5, PlaybackSpeed = 1 }
		local catalog = { Resolve = function() return variant end, GetNamedVariant = function() return variant end }
		local startup = { Enabled = true, Catalog = catalog, Config = config }
		local initiatorOrdinary, initiatorCreated = makeOrdinaryClient(scope, catalog, config, {})
		local recipientOrdinary, recipientCreated = makeOrdinaryClient(scope, catalog, config, {})
		local initiator = { UserId = 10 }
		local recipient = { UserId = 20 }
		local serverHandler = nil
		local recipientHandler = nil
		local intentPayload = nil
		local presentationPayload = nil
		local serverCommunication = {
			RegisterHandler = function(_self, _, _, handler) serverHandler = handler end,
			IsClientReady = function() return true end,
			QueuePresentationAtomic = function(_self, recipients, _, payload)
				assert(#recipients == 1 and recipients[1] == recipient)
				presentationPayload = payload
				recipientHandler(payload)
				return true
			end,
		}
		local server = HybridServer.new({
			Communication = serverCommunication,
			PlayersModule = { PlayerRemoving = makeSignal(), GetPlayers = function() return { initiator, recipient } end },
			Clock = function() return 0 end,
			Logger = makeLogger({}),
		})
		server:Register(startup)
		local recipientHybrid = HybridClient.new({
			Communication = { RegisterHandler = function(_self, _, handler) recipientHandler = handler end },
			Logger = makeLogger({}),
			PlayReceivedPresentation = function(payload) recipientOrdinary:PlayReceivedPresentation(payload) end,
		})
		recipientHybrid:Register(startup)
		local initiatorHybrid = HybridClient.new({
			Communication = { Queue = function(_self, _, payload)
				intentPayload = payload
				serverHandler(initiator, payload)
				return true
			end },
			Logger = makeLogger({}),
			PlayReceivedPresentation = function() end,
		})
		initiatorOrdinary:BindHybridIntentSender(initiatorHybrid)
		local handle = initiatorOrdinary:PlayHybrid({ CueId = "Cue", VariantId = "V" })
		assert(handle:IsActive() and #initiatorCreated == 1 and #recipientCreated == 1)
		assert(intentPayload == presentationPayload, "the exact validated pair payload must cross client/server/recipient")
		assert(intentPayload.CueId == "Cue" and intentPayload.VariantId == "V" and intentPayload.AssetKey == nil)
		handle:Stop()
	end)

	test("AudioIntegration/HybridCodecFiniteExactAndBounded", function()
		local good = { Version = 1, CueId = "A", VariantId = "B", Spatial = { Kind = "Point", Position = Vector3.new(1, 2, 3) } }
		assert(Codec.validate(good))
		assert(not Codec.validate({ Version = 1, CueId = "A", VariantId = "B", Spatial = { Kind = "Point", Position = Vector3.new(math.huge, 0, 0) } }))
		assert(not Codec.validate({ Version = 1, CueId = "A", VariantId = "B", Looping = true, Spatial = { Kind = "None" } }))
	end)

	test("AudioIntegration/ManifestDependencyAndProviderOrder", function()
		local serverCommands = {}; for _, command in ServerManifest.Commands do serverCommands[command.Id] = command end
		local clientCommands = {}; for _, command in ClientManifest.Commands do clientCommands[command.Id] = command end
		assert(table.concat(serverCommands.AudioGraph.DependsOn, ",") == "AudioStartup,Players")
		assert(table.concat(clientCommands.AudioGraph.DependsOn, ",") == "AudioStartup,Players")
		local modules = clientCommands.DomainData._modules
		assert(modules[1].Id == "Wallet" and modules[2].Id == "AudioSettings" and modules[3].Id == "Version")
	end)

	test("AudioIntegration/ServerGraphNoPartialPublish", function(scope)
		local runtime = scope:Track(Instance.new("Folder"))
		local calls = 0
		local graph = AudioGraphServer.new(runtime, makeLogger({}), {
			InstanceFactory = function(className)
				calls += 1
				if calls == 4 then error("injected graph stage failure") end
				return Instance.new(className)
			end,
		})
		local result = graph:Initialize({ Enabled = true, Config = validatedConfig() })
		assert(not result.Enabled and result.ReasonCode == "GraphConstructionFailed")
		assert(runtime:FindFirstChild(AudioProtocol.RuntimeRootName) == nil)
	end)

	test("AudioIntegration/ClientGraphMismatchOrTimeoutNoOp", function(scope)
		local runtime, published = makePublishedGraph(scope)
		local extra = Instance.new("Folder"); extra.Name = "Unexpected"; extra.Parent = published.Root
		local now = 0
		local player = assert(game:GetService("Players"):GetPlayers()[1], "Play fixture requires the current Studio player")
		local emptySignal = makeSignal()
		local graph = AudioGraphClient.new({
			RuntimeParent = runtime,
			LocalPlayer = player,
			PlayersModule = { CharacterAdded = emptySignal, CharacterRemoving = emptySignal, GetCharacter = function() return nil end },
			Workspace = workspace,
			GetCurrentCameraCFrame = function() return nil end,
			ListenerFrameDriver = emptySignal,
			Logger = makeLogger({}),
			Clock = function() return now end,
			Wait = function() now += 1 end,
		})
		local result = graph:Initialize({ Enabled = true, Config = validatedConfig() })
		assert(not result.Enabled and result.ReasonCode == "GraphMismatchOrTimeout" and now >= 10)
		assert(published.Root:FindFirstChild("ClientGraph") == nil)
	end)

	test("AudioIntegration/AudioSettingsEnvelopePatchMatrix", function(scope)
		local player = { UserId = 801 }
		local settings = AudioSettingsModule.new(); settings:Initialize({ Enabled = true, Config = validatedConfig() })
		local controller = ServerSaveController.new({
			Id = "Global", Providers = { settings },
			Storage = makeStorage({ FormatVersion = 1, Revision = 0, Providers = {}, Metadata = { CreatedAt = 1, UpdatedAt = 1 } }),
			KeyResolver = function() return "patch" end, Logger = makeLogger({}),
		})
		scope:Defer(function() controller:Destroy() end)
		assert(controller:Load(player).Ok)
		local data = settings:GetMemento(player); data.Levels.Master = 0.33
		local accepted = controller:ApplyClientPatch(player, { Providers = { AudioSettings = { Version = 1, Data = data } } })
		assert(#accepted.AcceptedProviders == 1 and settings:GetMemento(player).Levels.Master == 0.33)
		local revision = accepted.Revision
		for _, envelope in {
			{ Version = 2, Data = data }, { Version = 1, Data = { Unknown = true } }, { Version = 1 },
		} do
			local rejected = controller:ApplyClientPatch(player, { Providers = { AudioSettings = envelope } })
			assert(#rejected.RejectedProviders == 1 and rejected.Revision == revision)
			assert(settings:GetMemento(player).Levels.Master == 0.33)
		end
	end)

	local settingsEvidenceIdentities = {
		"AudioIntegration/SettingsBeforeClientReady",
		"AudioIntegration/AudioSettingsClientSnapshotReconciliation",
	}
	for _, identity in settingsEvidenceIdentities do
		test(identity, function(scope)
			local owner = makeSettingsGraphOwner()
			local settings = AudioSettingsClient.new(owner)
			local controller = ClientSaveController.new({
				Id = "Global", Providers = { settings },
				Communication = { RegisterHandler = function() end, Queue = function() return true end },
				Logger = makeLogger({}),
			})
			scope:Defer(function() controller:Destroy() end)
			controller:ApplySnapshot({ ControllerId = "Global", Revision = 2, Providers = {} })
			assert(controller:IsReady() and owner.Bound)
			assert(settings:GetLevel("Master") == validatedConfig().FaderProfiles.Master.DefaultLevel01)
			if identity == "AudioIntegration/AudioSettingsClientSnapshotReconciliation" then
				controller:ApplySnapshot({
					ControllerId = "Global", Revision = 3,
					Providers = { AudioSettings = { Version = 1, Data = { Levels = { Master = 0.42 } } } },
				})
				assert(controller:GetRevision() == 3 and settings:GetLevel("Master") == 0.42 and settings:IsEnabled("SFX"))
			end
		end)
	end

	test("AudioIntegration/InitializeIdentity", function(scope)
		local runtime = scope:Track(Instance.new("Folder"))
		local graph = AudioGraphServer.new(runtime, makeLogger({}))
		local first = graph:Initialize({ Enabled = true, Config = validatedConfig() })
		local second = graph:Initialize({ Enabled = true, Config = validatedConfig() })
		assert(first == second and first.Enabled and runtime:FindFirstChild(AudioProtocol.RuntimeRootName) == first.Root)
	end)

	test("AudioIntegration/ManifestDependencyAssertions", function()
		local serverCommands = {}; for _, command in ServerManifest.Commands do serverCommands[command.Id] = command end
		local clientCommands = {}; for _, command in ClientManifest.Commands do clientCommands[command.Id] = command end
		assert(table.concat(serverCommands.AudioGraph.DependsOn, ",") == "AudioStartup,Players")
		assert(table.concat(clientCommands.AudioGraph.DependsOn, ",") == "AudioStartup,Players")
		assert(table.concat(clientCommands.StartupContentPreload.DependsOn, ",") == "AudioStartup")
	end)

	local hybridEvidenceIdentities = {
		"AudioIntegration/HybridRejectUnknowns",
		"AudioIntegration/DeliveryTransportSeparation",
		"AudioIntegration/HybridPolicyBeforePrediction",
		"AudioIntegration/HybridQueueRejectedKeepsPrediction",
		"AudioIntegration/HybridNoRequestIdOrReplay",
		"AudioIntegration/ReadyRecipientsMomentary",
		"AudioIntegration/HybridStopLocalOnly",
		"AudioIntegration/HybridVariantChosenOnce",
		"AudioIntegration/HybridRequiresNamedVariant",
		"AudioIntegration/HybridAdversarialMatrix",
	}
	for _, identity in hybridEvidenceIdentities do
		test(identity, function(scope)
			if identity == "AudioIntegration/HybridNoRequestIdOrReplay" then
				local valid = { Version = 1, CueId = "Cue", VariantId = "V", Spatial = { Kind = "None" } }
				assert(Codec.validate(valid))
				assert(not Codec.validate({ Version = 1, CueId = "Cue", VariantId = "V", RequestId = "forbidden", Spatial = { Kind = "None" } }))
				assert(not Codec.validate({ Version = 1, CueId = string.rep("x", 200), VariantId = "V", Spatial = { Kind = "None" } }))
				assert(not Codec.validate({ Version = 1, CueId = "Cue", VariantId = "V", Looping = true, Spatial = { Kind = "None" } }))
				return
			end
			if identity == "AudioIntegration/HybridAdversarialMatrix" then
				local valid = { Version = 1, CueId = "Cue", VariantId = "V", Spatial = { Kind = "None" } }
				assert(Codec.validate(valid))
				assert(CommunicationSerialize.estimateSize(valid) < AudioSafetyLimits.HybridIntentMaxEstimatedBytes,
					"the exact legal schema cannot naturally reach the absolute byte ceiling")
				for _, simulatedBytes in {
					AudioSafetyLimits.HybridIntentMaxEstimatedBytes,
					AudioSafetyLimits.HybridIntentMaxEstimatedBytes + 1,
				} do
					local calls = 0
					local accepted = Codec.validateWithSerializer(valid, function(candidate, options)
						calls += 1
						assert(candidate == valid and options.MaxBytes == AudioSafetyLimits.HybridIntentMaxEstimatedBytes
							and options.MaxNodes == 32 and options.MaxIssues == 1,
							"HybridAdversarialMatrix lost the production serializer gate arguments")
						return simulatedBytes <= options.MaxBytes
					end)
					assert(calls == 1 and accepted == (simulatedBytes == AudioSafetyLimits.HybridIntentMaxEstimatedBytes),
						`size-isolated codec gate failed at {simulatedBytes} bytes`)
				end
				for _, invalidVersion in {
					{ CueId = "Cue", VariantId = "V", Spatial = { Kind = "None" } },
					{ Version = 1.5, CueId = "Cue", VariantId = "V", Spatial = { Kind = "None" } },
					{ Version = 2, CueId = "Cue", VariantId = "V", Spatial = { Kind = "None" } },
					{ Version = "1", CueId = "Cue", VariantId = "V", Spatial = { Kind = "None" } },
					{ Version = 1, ExtraVersion = 1, CueId = "Cue", VariantId = "V", Spatial = { Kind = "None" } },
				} do assert(not Codec.validate(invalidVersion), "every non-exact Version class must reject") end
				assert(not Codec.validate({ Version = 1, CueId = "Cue", VariantId = "V", RequestId = "forbidden", Spatial = { Kind = "None" } }))
				assert(not Codec.validate({ Version = 1, CueId = string.rep("x", 129), VariantId = "V", Spatial = { Kind = "None" } }))
				assert(not Codec.validate({ Version = 1, CueId = "Cue", VariantId = "V", Looping = true, Spatial = { Kind = "None" } }))
				assert(not Codec.validate({ Version = 1, CueId = "Cue", VariantId = "V", Spatial = { Kind = "Point", Position = Vector3.new(1_000_001, 0, 0) } }))
				local oversized = { Version = 1, CueId = string.rep("x", 2_100), VariantId = "V", Spatial = { Kind = "None" } }
				assert(CommunicationSerialize.estimateSize(oversized) > AudioSafetyLimits.HybridIntentMaxEstimatedBytes
					and not Codec.validate(oversized),
					"generic over-limit plus identifier-invalid intent must remain rejected independently")

				local function makeAuthoritative(options: any): any
					local events = {}
					local handler = nil
					local queued = 0
					local now = 0
					local variant = {
						CueId = "Cue", VariantId = "V", PlayerType = options.PlayerType or "SFX", AllowClientHybrid = options.Allowed ~= false,
						Looping = options.Looping == true, SourceVolume = 0.5, PlaybackSpeed = 1,
					}
					local communication = {
						RegisterHandler = function(_self, _, validator, callback)
							assert(validator == Codec.validate); handler = callback
						end,
						IsClientReady = function() return true end,
						QueuePresentationAtomic = function(_self, recipients)
							queued += 1
							if options.QueueResult == false then return false end
							assert(#recipients == #(options.Recipients or {}))
							return true
						end,
					}
					local controller = HybridServer.new({
						Communication = communication,
						PlayersModule = { PlayerRemoving = makeSignal(), GetPlayers = function() return options.Recipients or {} end },
						Clock = function() return now end, Logger = makeLogger(events),
					})
					controller:Register({
						Enabled = true, Catalog = { GetNamedVariant = function() return if options.Unknown then nil else variant end },
						Config = { PlayerTypes = { [variant.PlayerType] = {
							HybridRatePerSecond = options.TypeRate or 30, HybridBurst = options.TypeBurst or 60,
							SourceVolumeMin = 0, SourceVolumeMax = 1, PlaybackSpeedMin = 0.5, PlaybackSpeedMax = 2,
						} } },
					})
					return {
						Handle = handler, Events = events, Queued = function() return queued end,
						Advance = function(delta) now += delta end,
					}
				end

				for _, rejected in {
					makeAuthoritative({ Unknown = true }),
					makeAuthoritative({ Allowed = false }),
					makeAuthoritative({ Looping = true }),
					makeAuthoritative({ PlayerType = "Music" }),
					makeAuthoritative({ PlayerType = "World" }),
				} do
					rejected.Handle({ UserId = 1 }, valid)
					assert(rejected.Queued() == 0 and #rejected.Events == 1 and rejected.Events[1].Event == "HybridNotAllowed")
				end

				local typeLimited = makeAuthoritative({ TypeRate = 1, TypeBurst = 2 })
				typeLimited.Handle({ UserId = 10 }, valid); typeLimited.Handle({ UserId = 10 }, valid)
				assert(typeLimited.Queued() == 2, "type burst equality must be accepted")
				typeLimited.Handle({ UserId = 10 }, valid)
				assert(typeLimited.Queued() == 2 and typeLimited.Events[#typeLimited.Events].Event == "RateLimited")
				typeLimited.Advance(1)
				typeLimited.Handle({ UserId = 10 }, valid)
				assert(typeLimited.Queued() == 3, "type rate refill must accept exactly one later intent")

				local ownerLimited = makeAuthoritative({})
				local owner = { UserId = 20 }
				for _ = 1, AudioSafetyLimits.HybridAggregateBurstPerOwner do ownerLimited.Handle(owner, valid) end
				assert(ownerLimited.Queued() == AudioSafetyLimits.HybridAggregateBurstPerOwner,
					"owner burst equality must be accepted")
				ownerLimited.Handle(owner, valid)
				assert(ownerLimited.Queued() == AudioSafetyLimits.HybridAggregateBurstPerOwner
					and ownerLimited.Events[#ownerLimited.Events].Event == "RateLimited")
				ownerLimited.Advance(1 / AudioSafetyLimits.HybridAggregateRatePerOwner)
				ownerLimited.Handle(owner, valid)
				assert(ownerLimited.Queued() == AudioSafetyLimits.HybridAggregateBurstPerOwner + 1,
					"owner rate refill must accept one exact token")

				local serverLimited = makeAuthoritative({})
				for userId = 1, AudioSafetyLimits.HybridAcceptedBurstServer do
					serverLimited.Handle({ UserId = 1_000 + userId }, valid)
				end
				assert(serverLimited.Queued() == AudioSafetyLimits.HybridAcceptedBurstServer,
					"server burst equality must be accepted")
				serverLimited.Handle({ UserId = 9_000 }, valid)
				assert(serverLimited.Queued() == AudioSafetyLimits.HybridAcceptedBurstServer
					and serverLimited.Events[#serverLimited.Events].Event == "RateLimited")
				serverLimited.Advance(1 / AudioSafetyLimits.HybridAcceptedRateServer)
				serverLimited.Handle({ UserId = 9_001 }, valid)
				assert(serverLimited.Queued() == AudioSafetyLimits.HybridAcceptedBurstServer + 1,
					"server rate refill must accept one exact token")

				local exactRecipients = {}
				for userId = 1, AudioSafetyLimits.HybridFanoutRecipientsBurstServer do
					table.insert(exactRecipients, { UserId = 10_000 + userId })
				end
				local fanoutExact = makeAuthoritative({ Recipients = exactRecipients })
				fanoutExact.Handle({ UserId = 30 }, valid)
				assert(fanoutExact.Queued() == 1, "exact 2048 fanout burst must be accepted")
				local overRecipients = table.clone(exactRecipients)
				table.insert(overRecipients, { UserId = 99_999 })
				for _ = 1, AudioSafetyLimits.HybridFanoutRecipientsRateServer do table.remove(exactRecipients) end
				fanoutExact.Advance(1)
				fanoutExact.Handle({ UserId = 30 }, valid)
				assert(fanoutExact.Queued() == 2,
					"one second must refill the exact 1024-recipient fanout rate after burst exhaustion")
				local fanoutLimited = makeAuthoritative({ Recipients = overRecipients })
				fanoutLimited.Handle({ UserId = 31 }, valid)
				assert(fanoutLimited.Queued() == 0 and fanoutLimited.Events[#fanoutLimited.Events].Event == "FanoutBudgetExceeded")
				fanoutLimited.Advance(1)
				fanoutLimited.Handle({ UserId = 32 }, valid)
				assert(fanoutLimited.Queued() == 0 and fanoutLimited.Events[#fanoutLimited.Events].Event == "FanoutBudgetExceeded",
					"one second refills 1024 recipients, still below the 2049 request")

				local firstRecipient = { UserId = 2 }
				local secondRecipient = { UserId = 3 }
				local outgoing = { [firstRecipient] = { { Existing = "first" } }, [secondRecipient] = { { Existing = "second" } } }
				local outgoingBytes = { [firstRecipient] = 10, [secondRecipient] = 20 }
				local dropped = { [firstRecipient] = 1, [secondRecipient] = 2 }
				local host = {
					_outgoing = outgoing, _outgoingBytes = outgoingBytes, _droppedPresentation = dropped,
					Queue = function(self, recipient)
						table.insert(self._outgoing[recipient], { New = true })
						self._outgoingBytes[recipient] += 5
						self._droppedPresentation[recipient] += 1
						return recipient ~= secondRecipient
					end,
				}
				local atomicRejected = makeAuthoritative({
					Recipients = { firstRecipient, secondRecipient },
					QueueResult = false,
				})
				-- Replace only the injected communication callback with the real public atomic helper.
				local realAtomicEvents = {}
				local realHandler = nil
				local realController = HybridServer.new({
					Communication = {
						RegisterHandler = function(_self, _, validator, callback) assert(validator == Codec.validate); realHandler = callback end,
						IsClientReady = function() return true end,
						QueuePresentationAtomic = function(_self, recipients, messageType, payload, requestId)
							return CommunicationServer.QueuePresentationAtomic(host, recipients, messageType, payload, requestId)
						end,
					},
					PlayersModule = { PlayerRemoving = makeSignal(), GetPlayers = function() return { firstRecipient, secondRecipient } end },
					Clock = function() return 0 end, Logger = makeLogger(realAtomicEvents),
				})
				realController:Register({
					Enabled = true, Catalog = { GetNamedVariant = function() return {
						CueId = "Cue", VariantId = "V", PlayerType = "SFX", AllowClientHybrid = true,
						Looping = false, SourceVolume = 0.5, PlaybackSpeed = 1,
					} end },
					Config = { PlayerTypes = { SFX = {
						HybridRatePerSecond = 30, HybridBurst = 60, SourceVolumeMin = 0, SourceVolumeMax = 1,
						PlaybackSpeedMin = 0.5, PlaybackSpeedMax = 2,
					} } },
				})
				realHandler({ UserId = 40 }, valid)
				assert(#outgoing[firstRecipient] == 1 and #outgoing[secondRecipient] == 1
					and outgoingBytes[firstRecipient] == 10 and outgoingBytes[secondRecipient] == 20
					and dropped[firstRecipient] == 1 and dropped[secondRecipient] == 2,
					"real atomic helper must roll back every recipient after a partial failure")
				assert(realAtomicEvents[#realAtomicEvents].Event == "HybridQueueRejected")
				atomicRejected.Handle({ UserId = 40 }, valid)
				assert(atomicRejected.Queued() == 1 and atomicRejected.Events[#atomicRejected.Events].Event == "HybridQueueRejected")
				for _, fixture in { typeLimited, ownerLimited, serverLimited, fanoutExact, fanoutLimited, atomicRejected } do
					for _, event in fixture.Events do
						assert(event.Data.CueId == nil and event.Data.VariantId == nil and event.Data.Spatial == nil,
							"authoritative rejects must not log raw hybrid payload fields")
					end
				end
				return
			end
			if identity == "AudioIntegration/HybridRejectUnknowns" or identity == "AudioIntegration/ReadyRecipientsMomentary" then
				local registered = nil
				local queued = {}
				local ready = { [2] = true, [3] = false }
				local recipients = { { UserId = 2 }, { UserId = 3 } }
				local known = identity == "AudioIntegration/ReadyRecipientsMomentary"
				local controller = HybridServer.new({
					Communication = {
						RegisterHandler = function(_self, _, _, handler) registered = handler end,
						IsClientReady = function(_self, player) return ready[player.UserId] == true end,
						QueuePresentationAtomic = function(_self, players) for _, player in players do table.insert(queued, player) end; return true end,
					},
					PlayersModule = { PlayerRemoving = makeSignal(), GetPlayers = function() return recipients end },
					Clock = function() return 0 end, Logger = makeLogger({}),
				})
				controller:Register({
					Enabled = true,
					Catalog = { GetNamedVariant = function() return if known then {
						CueId = "Cue", VariantId = "V", PlayerType = "SFX", AllowClientHybrid = true,
						Looping = false, SourceVolume = 0.5, PlaybackSpeed = 1,
					} else nil end },
					Config = { PlayerTypes = { SFX = {
						HybridRatePerSecond = 2, HybridBurst = 2, SourceVolumeMin = 0, SourceVolumeMax = 1,
						PlaybackSpeedMin = 0.5, PlaybackSpeedMax = 2,
					} } },
				})
				registered({ UserId = 1 }, { Version = 1, CueId = "Cue", VariantId = "V", Spatial = { Kind = "None" } })
				if known then assert(#queued == 1 and queued[1].UserId == 2) else assert(#queued == 0) end
				return
			end

			local config = validatedConfig()
			local variant = {
				CueId = "Cue", VariantId = "V", ContentId = "rbxassetid://1", PlayerType = "SFX",
				AllowClientHybrid = true, Looping = false, SourceVolume = 0.5, PlaybackSpeed = 1,
			}
			local named: any = variant
			local catalog = { Resolve = function() return variant end, GetNamedVariant = function() return named end }
			local events = {}
			local ordinary, created = makeOrdinaryClient(scope, catalog, config, events)
			local queueCount = 0
			local queuedPayload = nil
			local hybrid = HybridClient.new({
				Communication = { Queue = function(_self, _, payload) queueCount += 1; queuedPayload = payload; return identity ~= "AudioIntegration/HybridQueueRejectedKeepsPrediction" end },
				Logger = makeLogger(events), PlayReceivedPresentation = function() end,
			})
			ordinary:BindHybridIntentSender(hybrid)
			if identity == "AudioIntegration/DeliveryTransportSeparation" then
				local localHandle = ordinary:PlayLocal({ CueId = "Cue", VariantId = "V" })
				assert(localHandle:IsActive() and queueCount == 0)
				local hybridHandle = ordinary:PlayHybrid({ CueId = "Cue", VariantId = "V" })
				assert(hybridHandle:IsActive() and queueCount == 1)
				return
			end
			if identity == "AudioIntegration/HybridPolicyBeforePrediction" then
				variant.AllowClientHybrid = false
				local rejected = ordinary:PlayHybrid({ CueId = "Cue", VariantId = "V" })
				assert(not rejected:IsActive() and #created == 0 and queueCount == 0)
				return
			end
			if identity == "AudioIntegration/HybridRequiresNamedVariant" then
				named = table.clone(variant)
				local rejected = ordinary:PlayHybrid({ CueId = "Cue", VariantId = "V" })
				assert(not rejected:IsActive() and #created == 0 and queueCount == 0)
				return
			end
			local handle = ordinary:PlayHybrid({ CueId = "Cue", VariantId = "V" })
			assert(handle:IsActive() and queueCount == 1 and queuedPayload.CueId == "Cue" and queuedPayload.VariantId == "V")
			if identity == "AudioIntegration/HybridQueueRejectedKeepsPrediction" then
				assert(events[#events].Event == "HybridQueueRejected" and handle:IsActive())
			elseif identity == "AudioIntegration/HybridStopLocalOnly" then
				handle:Stop(); assert(not handle:IsActive() and queueCount == 1)
			elseif identity == "AudioIntegration/HybridVariantChosenOnce" then
				assert(queuedPayload.AssetKey == nil and #created == 1)
			end
		end)
	end

	return TestHarness.runAll("AudioIntegrationTestRunner", tests, 10)
end

return Runner
