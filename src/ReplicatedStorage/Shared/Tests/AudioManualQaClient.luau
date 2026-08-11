--!strict

--[[
	Manual Studio-only client driver for collaborative Audio QA.

	Nothing runs when this module is required. Start and Execute are invoked in
	the selected Test Server client after the production bootstrap has completed.
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")

local AudioProtocol = require(script.Parent.Parent.Audio.AudioProtocol)
local SaveProtocol = require(script.Parent.Parent.Save.SaveProtocol)
local TableUtil = require(script.Parent.Parent.Util.TableUtil)
local Bridge = require(script.Parent.AudioManualQaBridge)
local Contracts = require(script.Parent.AudioManualQaContracts)
local Plan = require(script.Parent.AudioManualQaPlan)

local Client = {}

local session: any? = nil
local bootstrapServices: any? = nil

local CATEGORIES = { "Master", "UI", "SFX", "World", "Music" }

local function emit(event: string, payload: any): any
	local envelope = {
		Source = "AudioManualQaClient",
		Event = event,
		Payload = payload,
	}
	print(`[AudioManualQA] {HttpService:JSONEncode(envelope)}`)
	return payload
end

local function assertRuntimeContext()
	assert(RunService:IsStudio(), "AudioManualQaClient is Studio-only")
	assert(RunService:IsClient(), "AudioManualQaClient must run in a client VM")
	assert(RunService:IsRunning(), "Start a Play/Test Server session before AudioManualQaClient")
end

local function invokeBridge(command: string, arguments: any): any
	assertRuntimeContext()
	local localPlayer = assert(Players.LocalPlayer, "Production LocalPlayer is unavailable")
	local playerScripts = assert(localPlayer:FindFirstChild("PlayerScripts"), "Production PlayerScripts is unavailable")
	local bootstrap = assert(playerScripts:FindFirstChild("Bootstrap"), "Production client Bootstrap is unavailable")
	return Bridge.Invoke(bootstrap, "Client", command, arguments)
end

local function getSession(): any
	assertRuntimeContext()
	return assert(session, "Call AudioManualQaClient.Start(runId, clientLabel) first")
end

local function vector(value: Vector3): any
	return { X = value.X, Y = value.Y, Z = value.Z }
end

local function currentOrigin(): CFrame
	local player = Players.LocalPlayer
	local character = if player then player.Character else nil
	local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
	if root ~= nil and root:IsA("BasePart") then return root.CFrame end
	local camera = Workspace.CurrentCamera
	if camera ~= nil then return camera.CFrame end
	return CFrame.new(0, 8, 0)
end

local function makeVisibleTarget(name: string, color: Color3, distance: number): Part
	local target = Instance.new("Part")
	target.Name = name
	target.Anchored = true
	target.CanCollide = false
	target.CanQuery = false
	target.CanTouch = false
	target.Material = Enum.Material.Neon
	target.Color = color
	target.Size = Vector3.new(3, 3, 3)
	target.CFrame = currentOrigin() * CFrame.new(0, 0, -distance)
	target.Parent = Workspace
	return target
end

local function poolStats(poolModule: any, id: string): any
	local pool = poolModule:GetPool(id)
	if pool == nil then return { Missing = true } end
	local stats = pool:GetStats()
	return {
		Active = stats.Active,
		Available = stats.Available,
		Created = stats.Created,
		Reused = stats.Reused,
		Released = stats.Released,
		MaxActive = stats.MaxActive,
		MaxRetained = stats.MaxRetained,
	}
end

local function playerValue(player: AudioPlayer, property: string): any
	local ok, value = pcall(function() return (player :: any)[property] end)
	if not ok then return nil end
	if property == "Asset" then return tostring(value) end
	return value
end

local function collectPlayback(parent: Instance?): { any }
	local records = {}
	if parent == nil then return records end
	for _, child in parent:GetChildren() do
		local isSpatial = child:IsA("Part") and child.Name == "SpatialAnchor"
		local spatialAnchor = if isSpatial then child :: BasePart else nil
		if not isSpatial and (not child:IsA("Folder") or not string.match(child.Name, "Playback$")) then continue end
		local player = child:FindFirstChildWhichIsA("AudioPlayer") :: AudioPlayer?
		local emitter = child:FindFirstChildWhichIsA("AudioEmitter") :: AudioEmitter?
		local wire = child:FindFirstChildWhichIsA("Wire") :: Wire?
		local directChildren = child:GetChildren()
		table.insert(records, {
			Root = child.Name,
			RootClass = child.ClassName,
			Asset = if player then playerValue(player, "Asset") else nil,
			IsPlaying = if player then playerValue(player, "IsPlaying") else nil,
			IsReady = if player then playerValue(player, "IsReady") else nil,
			Looping = if player then playerValue(player, "Looping") else nil,
			Volume = if player then playerValue(player, "Volume") else nil,
			PlaybackSpeed = if player then playerValue(player, "PlaybackSpeed") else nil,
			Anchored = if spatialAnchor then spatialAnchor.Anchored else nil,
			CanCollide = if spatialAnchor then spatialAnchor.CanCollide else nil,
			CanQuery = if spatialAnchor then spatialAnchor.CanQuery else nil,
			CanTouch = if spatialAnchor then spatialAnchor.CanTouch else nil,
			Transparency = if spatialAnchor then spatialAnchor.Transparency else nil,
			DirectAudioPlayer = player ~= nil and player.Parent == child,
			DirectAudioEmitter = emitter ~= nil and emitter.Parent == child,
			DirectWire = wire ~= nil and wire.Parent == child,
			DirectChildCount = #directChildren,
			AnchorTransform = if spatialAnchor then {
				Position = vector(spatialAnchor.Position),
				LookVector = vector(spatialAnchor.CFrame.LookVector),
				UpVector = vector(spatialAnchor.CFrame.UpVector),
			} else nil,
			WireSource = if wire and wire.SourceInstance then wire.SourceInstance.Name else nil,
			WireTarget = if wire and wire.TargetInstance then wire.TargetInstance.Name else nil,
		})
	end
	table.sort(records, function(a, b) return a.Root < b.Root end)
	return records
end

local function settingsSnapshot(settings: any): any
	local result = {}
	for _, category in CATEGORIES do
		local levelOk, level = pcall(function() return settings:GetLevel(category) end)
		local enabledOk, enabled = pcall(function() return settings:IsEnabled(category) end)
		result[category] = {
			Level = if levelOk then level else nil,
			Enabled = if enabledOk then enabled else nil,
			Loaded = levelOk and enabledOk,
		}
	end
	return result
end

local function handleSnapshot(handles: { [string]: any }): any
	local result = {}
	for label, record in handles do
		local ok, active = pcall(function() return record.Handle:IsActive() end)
		result[label] = {
			Kind = record.Kind,
			LiveAssetKey = record.LiveAssetKey,
			ExpectedContentId = Plan.LiveAssets[record.LiveAssetKey].ContentId,
			Active = ok and active == true,
		}
	end
	return result
end

local function listenerSnapshot(graph: any): any
	if graph == nil or not graph.Enabled then return { Enabled = false } end
	local listener = graph.Listener
	local anchor = graph.ListenerAnchor
	local player = Players.LocalPlayer
	local character = if player then player.Character else nil
	local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
	local camera = Workspace.CurrentCamera
	local positionDelta = nil
	local rotationDeltaDegrees = nil
	if root ~= nil and root:IsA("BasePart") and anchor ~= nil then
		positionDelta = (anchor.Position - root.Position).Magnitude
	end
	if camera ~= nil and anchor ~= nil then
		local _, angle = (anchor.CFrame.Rotation:ToObjectSpace(camera.CFrame.Rotation)):ToAxisAngle()
		rotationDeltaDegrees = math.deg(math.abs(angle))
	end
	return {
		Enabled = true,
		PositionDelta = positionDelta,
		RotationDeltaDegrees = rotationDeltaDegrees,
		PositionInstance = if listener.PositionInstance then listener.PositionInstance.Name else nil,
		AcousticSimulationEnabled = listener.AcousticSimulationEnabled,
		InteractionGroup = listener.AudioInteractionGroup,
		OutputBound = graph.LocalRoot:FindFirstChild("MasterToOutput") ~= nil,
	}
end

local function acousticProperty(): any
	local ok, value = pcall(function() return (SoundService :: any).AcousticSimulationEnabled end)
	return if ok then value else "Unavailable"
end

local function saveSnapshot(saveModule: any): any
	local controller = saveModule:GetSaveController(SaveProtocol.GlobalControllerId)
	if controller == nil then return { Present = false } end
	return {
		Present = true,
		Ready = controller:IsReady(),
		Revision = controller:GetRevision(),
	}
end

local function faderSnapshot(graph: any): any
	local result = {}
	if graph == nil or not graph.Enabled then return result end
	for _, category in CATEGORIES do
		local fader = graph.Faders[category]
		result[category] = if fader then fader.Volume else nil
	end
	return result
end

local function musicSnapshot(current: any): any
	local pool = poolStats(current.Services.Pooling, "Audio.Client.Music")
	local activeHandles = 0
	for _, record in current.Handles do
		if record.Kind == "Music" and record.Handle:IsActive() then activeHandles += 1 end
	end
	local players = {}
	for _, record in collectPlayback(current.Graph.LocalRoot) do
		if record.Root == "MusicPlayback" then table.insert(players, record) end
	end
	return {
		ActiveLeases = pool.Active,
		ActiveHandles = activeHandles,
		Playback = players,
	}
end

local function inspectGraph(runtimeRoot: Instance): any
	local published = assert(runtimeRoot:FindFirstChild(AudioProtocol.PublishedGraphName), "PublishedGraph is missing")
	local fadersFolder = assert(published:FindFirstChild("Faders"), "Published faders are missing")
	local localRoot = assert(runtimeRoot:FindFirstChild("ClientGraph"), "Production ClientGraph is missing")
	local faders = {}
	for _, category in CATEGORIES do
		local fader = assert(fadersFolder:FindFirstChild(category), `Production fader '{category}' is missing`)
		assert(fader:IsA("AudioFader"), `Production fader '{category}' has the wrong class`)
		faders[category] = fader
	end
	local anchor = assert(Workspace:FindFirstChild("AudioListenerAnchor"), "Production listener anchor is missing")
	assert(anchor:IsA("BasePart"), "Production listener anchor has the wrong class")
	local listener = assert(anchor:FindFirstChild("Listener"), "Production AudioListener is missing")
	assert(listener:IsA("AudioListener"), "Production Listener has the wrong class")
	assert(listener.PositionInstance == anchor, "Production AudioListener is not bound to its anchor")
	return {
		Enabled = true,
		Root = runtimeRoot,
		LocalRoot = localRoot,
		Faders = faders,
		Listener = listener,
		ListenerAnchor = anchor,
	}
end

local function captureOriginalSettings(settings: any): any
	local snapshot = settingsSnapshot(settings)
	for _, category in CATEGORIES do
		assert(snapshot[category].Loaded, "AudioSettings must be loaded before QA starts")
	end
	return snapshot
end

local function restoreSettings(current: any)
	if current == nil or current.OriginalSettings == nil then return end
	for _, category in CATEGORIES do
		local original = current.OriginalSettings[category]
		current.Services.AudioSettings:SetLevel(category, original.Level)
		current.Services.AudioSettings:SetEnabled(category, original.Enabled)
	end
end

local function cleanup(current: any)
	if current == nil then return end
	for _, record in current.Handles do
		pcall(function() record.Handle:Stop() end)
	end
	current.Services.Music:StopAllMusic()
	table.clear(current.Handles)
	if current.PointMarker ~= nil then current.PointMarker:Destroy(); current.PointMarker = nil end
	if current.AttachedTarget ~= nil then current.AttachedTarget:Destroy(); current.AttachedTarget = nil end
	restoreSettings(current)
end

local function playbackOptions(args: any): any?
	local options = {}
	if typeof(args.VolumeMultiplier) == "number" then options.VolumeMultiplier = args.VolumeMultiplier end
	if typeof(args.PlaybackSpeedMultiplier) == "number" then options.PlaybackSpeedMultiplier = args.PlaybackSpeedMultiplier end
	if typeof(args.TimePosition) == "number" then options.TimePosition = args.TimePosition end
	return if next(options) == nil then nil else options
end

local function storeHandle(current: any, label: any, handle: any, kind: string, liveAssetKey: string): string
	assert(handle ~= nil and handle:IsActive(), `Production {kind} request for '{liveAssetKey}' was rejected`)
	current.ActionSequence += 1
	local resolved = if typeof(label) == "string" and label ~= "" then label else `{kind}-{current.ActionSequence}`
	local prior = current.Handles[resolved]
	if prior ~= nil then pcall(function() prior.Handle:Stop() end) end
	current.Handles[resolved] = { Handle = handle, Kind = kind, LiveAssetKey = liveAssetKey }
	return resolved
end

function Client.Start(runId: string, clientLabel: string): any
	assertRuntimeContext()
	if bootstrapServices == nil then
		return invokeBridge("Start", { RunId = runId, ClientLabel = clientLabel })
	end
	assert(typeof(runId) == "string" and runId ~= "", "runId must be a non-empty string")
	assert(clientLabel == "ClientA" or clientLabel == "ClientB", "clientLabel must be ClientA or ClientB")
	if session ~= nil then cleanup(session) end
	local runtimeRoot = ReplicatedStorage:FindFirstChild(AudioProtocol.RuntimeRootName)
	assert(runtimeRoot ~= nil and runtimeRoot:GetAttribute(AudioProtocol.AttributeNames.Ready) == true, "Production Audio runtime is not ready")
	local services = bootstrapServices
	local graph = inspectGraph(runtimeRoot)
	local startup = assert(services.AudioStartup, "Production client Audio startup state is unavailable")
	assert(startup.Enabled == true and startup.Catalog ~= nil, "Production client Audio catalog is not enabled")
	local identityOk, liveAssets, identityError = Plan.ValidateLiveAssets(
		startup.Catalog,
		assert(ReplicatedStorage:FindFirstChild("Assets"), "ReplicatedStorage.Assets is missing")
	)
	assert(identityOk, identityError)
	session = {
		RunId = runId,
		ClientLabel = clientLabel,
		StartedAtUnix = os.time(),
		Services = services,
		Graph = graph,
		LiveAssets = liveAssets,
		Handles = {},
		ActionSequence = 0,
		PointMarker = nil,
		AttachedTarget = nil,
	}
	session.OriginalSettings = captureOriginalSettings(services.AudioSettings)
	return emit("Started", Client.Snapshot())
end

function Client.Snapshot(): any
	if bootstrapServices == nil then return invokeBridge("Snapshot", {}) end
	local current = getSession()
	local runtimeRoot = ReplicatedStorage:FindFirstChild(AudioProtocol.RuntimeRootName)
	local serverPlayback = if runtimeRoot then runtimeRoot:FindFirstChild(AudioProtocol.ServerPlaybackName) else nil
	local graph = current.Graph
	local pools = current.Services.Pooling
	return {
		RunId = current.RunId,
		ClientLabel = current.ClientLabel,
		PlaceId = game.PlaceId,
		GameId = game.GameId,
		RuntimeReady = runtimeRoot ~= nil and runtimeRoot:GetAttribute(AudioProtocol.AttributeNames.Ready) == true,
		RuntimeGeneration = if runtimeRoot then runtimeRoot:GetAttribute(AudioProtocol.AttributeNames.Generation) else nil,
		AcousticSimulationEnabled = acousticProperty(),
		Pools = {
			UI = poolStats(pools, "Audio.Client.UI"),
			SFX = poolStats(pools, "Audio.Client.SFX"),
			World = poolStats(pools, "Audio.Client.World"),
			Music = poolStats(pools, "Audio.Client.Music"),
		},
		LocalPlayback = collectPlayback(graph.LocalRoot),
		ServerPlayback = collectPlayback(serverPlayback),
		WorldPlayback = collectPlayback(Workspace),
		FaderVolume = faderSnapshot(graph),
		Settings = settingsSnapshot(current.Services.AudioSettings),
		Save = saveSnapshot(current.Services.Save),
		Preload = Contracts.GetAudioPreloadSnapshot(current.Services.ContentPreloader),
		Listener = listenerSnapshot(graph),
		Music = musicSnapshot(current),
		LiveAssets = current.LiveAssets,
		Handles = handleSnapshot(current.Handles),
		PointMarker = if current.PointMarker then vector(current.PointMarker.Position) else nil,
		AttachedTarget = if current.AttachedTarget then {
			Name = current.AttachedTarget.Name,
			Position = vector(current.AttachedTarget.Position),
		} else nil,
	}
end

function Client.Execute(action: string, args: any?): any
	if bootstrapServices == nil then return invokeBridge("Execute", { Action = action, Args = args }) end
	local current = getSession()
	assert(Plan.ClientActions[action] == true, `Unknown client QA action '{action}'`)
	assert(action ~= "start", "The plan 'start' action must invoke Client.Start directly")
	local parameters = args or {}
	local result: any = { Action = action }

	if action == "snapshot" then
		result.Snapshot = Client.Snapshot()
	elseif action == "play_local_sfx" then
		local key = "CartoonBubble"
		local expected = Plan.LiveAssets[key]
		local handle = current.Services.OrdinarySound:PlayLocal(Contracts.MakeCueRef(expected), playbackOptions(parameters))
		result.LiveAsset = expected
		result.Handle = storeHandle(current, parameters.Label, handle, "LocalSFX", key)
	elseif action == "create_point_marker" then
		if current.PointMarker ~= nil then current.PointMarker:Destroy() end
		current.PointMarker = makeVisibleTarget("QA_ClientPointMarker", Color3.fromRGB(0, 170, 255), parameters.Distance or 12)
		result.Position = vector(current.PointMarker.Position)
	elseif action == "play_local_at_marker" then
		assert(current.PointMarker ~= nil and current.PointMarker.Parent ~= nil, "Create the point marker first")
		local key = "OldCarEngine"
		local expected = Plan.LiveAssets[key]
		local handle = current.Services.OrdinarySound:PlayLocalAt(
			Contracts.MakeCueRef(expected),
			current.PointMarker.Position,
			playbackOptions(parameters)
		)
		result.LiveAsset = expected
		result.Handle = storeHandle(current, parameters.Label, handle, "LocalPoint", key)
	elseif action == "create_attached_target" then
		if current.AttachedTarget ~= nil then current.AttachedTarget:Destroy() end
		current.AttachedTarget = makeVisibleTarget("QA_ClientAttachedTarget", Color3.fromRGB(255, 170, 0), parameters.Distance or 12)
		result.Position = vector(current.AttachedTarget.Position)
	elseif action == "play_local_attached" then
		assert(current.AttachedTarget ~= nil and current.AttachedTarget.Parent ~= nil, "Create the attached target first")
		local key = "OldCarEngine"
		local expected = Plan.LiveAssets[key]
		local handle = current.Services.OrdinarySound:PlayLocalAttached(
			Contracts.MakeCueRef(expected),
			current.AttachedTarget,
			playbackOptions(parameters)
		)
		result.LiveAsset = expected
		result.Handle = storeHandle(current, parameters.Label, handle, "LocalAttached", key)
	elseif action == "move_attached_target" then
		assert(current.AttachedTarget ~= nil and current.AttachedTarget.Parent ~= nil, "Create the attached target first")
		local offset = Vector3.new(parameters.X or 8, parameters.Y or 0, parameters.Z or 0)
		current.AttachedTarget.CFrame = current.AttachedTarget.CFrame * CFrame.new(offset) * CFrame.Angles(0, math.rad(parameters.YawDegrees or 90), 0)
		result.Position = vector(current.AttachedTarget.Position)
	elseif action == "remove_attached_target" then
		if current.AttachedTarget ~= nil then current.AttachedTarget:Destroy(); current.AttachedTarget = nil end
	elseif action == "play_hybrid_sfx" then
		local key = "CartoonBubble"
		local expected = Plan.LiveAssets[key]
		local handle = current.Services.OrdinarySound:PlayHybrid(Contracts.MakeCueRef(expected), playbackOptions(parameters))
		result.LiveAsset = expected
		result.Handle = storeHandle(current, parameters.Label, handle, "HybridSFX", key)
	elseif action == "play_hybrid_at_marker" then
		assert(current.PointMarker ~= nil and current.PointMarker.Parent ~= nil, "Create the point marker first")
		local key = "OldCarEngine"
		local expected = Plan.LiveAssets[key]
		local handle = current.Services.OrdinarySound:PlayHybridAt(
			Contracts.MakeCueRef(expected),
			current.PointMarker.Position,
			playbackOptions(parameters)
		)
		result.LiveAsset = expected
		result.Handle = storeHandle(current, parameters.Label, handle, "HybridPoint", key)
	elseif action == "play_music" then
		local key = "PrayerRiver"
		local expected = Plan.LiveAssets[key]
		local transition = { Strategy = parameters.Strategy or "Instant" }
		if transition.Strategy ~= "Instant" then
			transition.FadeOutSeconds = parameters.FadeOutSeconds or 0.5
			transition.FadeInSeconds = parameters.FadeInSeconds or 0.5
		end
		local handle = current.Services.Music:PlayMusic(
			Contracts.MakeCueRef(expected),
			playbackOptions(parameters),
			transition
		)
		result.LiveAsset = expected
		result.Handle = storeHandle(current, parameters.Label, handle, "Music", key)
	elseif action == "stop_handle" then
		local label = assert(parameters.Label, "stop_handle requires args.Label")
		local record = assert(current.Handles[label], `Unknown handle '{tostring(label)}'`)
		if record.Kind == "Music" then
			local transition = { Strategy = parameters.Strategy or "Instant" }
			if transition.Strategy ~= "Instant" then
				transition.FadeOutSeconds = parameters.FadeOutSeconds or 0.5
				transition.FadeInSeconds = parameters.FadeInSeconds or 0.5
			end
			record.Handle:Stop(transition)
		else
			record.Handle:Stop()
		end
	elseif action == "stop_all_music" then
		current.Services.Music:StopAllMusic()
	elseif action == "set_level" then
		result.Accepted = current.Services.AudioSettings:SetLevel(
			assert(parameters.Category, "set_level requires args.Category"),
			assert(parameters.Level, "set_level requires args.Level")
		)
	elseif action == "set_enabled" then
		assert(typeof(parameters.Enabled) == "boolean", "set_enabled requires boolean args.Enabled")
		result.Accepted = current.Services.AudioSettings:SetEnabled(
			assert(parameters.Category, "set_enabled requires args.Category"),
			parameters.Enabled
		)
	elseif action == "restore_settings" then
		restoreSettings(current)
	elseif action == "validate_invalid_settings_snapshot" then
		local controller = assert(current.Services.GlobalSaveController, "Global client save controller is unavailable")
		assert(controller:IsReady(), "Global client save controller is not ready")
		local beforeRevision = controller:GetRevision()
		local beforeSettings = current.Services.AudioSettings:GetMemento()
		local providers = {}
		for _, provider in {
			current.Services.Wallet,
			current.Services.AudioSettings,
			current.Services.Version,
		} do
			if provider.BeforeMementoGet then provider:BeforeMementoGet() end
			providers[provider.Id] = {
				Version = provider.Version,
				Data = TableUtil.deepCopy(provider:GetMemento()),
			}
		end
		providers.AudioSettings.Unexpected = true
		local accepted, failure = xpcall(function()
			controller:ApplySnapshot({
				ControllerId = SaveProtocol.GlobalControllerId,
				Revision = beforeRevision + 1,
				Providers = providers,
			})
		end, debug.traceback)
		result.Rejected = not accepted
		result.ReasonCode = if not accepted and string.find(tostring(failure), "InvalidSettings", 1, true)
			then "InvalidSettings" else nil
		result.RevisionUnchanged = controller:GetRevision() == beforeRevision
		result.SettingsUnchanged = TableUtil.deepEqual(current.Services.AudioSettings:GetMemento(), beforeSettings)
		assert(result.Rejected and result.ReasonCode == "InvalidSettings"
			and result.RevisionUnchanged and result.SettingsUnchanged,
			"Invalid AudioSettings snapshot did not fail closed without mutation")
	elseif action == "cleanup" then
		cleanup(current)
	end

	if result.Snapshot == nil then result.Snapshot = Client.Snapshot() end
	return emit("Action", result)
end

function Client.GetPlan(): any
	assertRuntimeContext()
	return Plan
end

function Client.Cleanup(): any
	if bootstrapServices == nil then return invokeBridge("Cleanup", {}) end
	local current = getSession()
	cleanup(current)
	local result = Client.Snapshot()
	return emit("Cleaned", result)
end

function Client.InstallBridge(services: any, parent: Instance): any?
	assertRuntimeContext()
	assert(bootstrapServices == nil, "AudioManualQaClient bridge services are already bound")
	bootstrapServices = services
	return Bridge.Install({
		Parent = parent,
		Side = "Client",
		Commands = {
			Start = function(arguments)
				return Client.Start(arguments.RunId, arguments.ClientLabel)
			end,
			Execute = function(arguments)
				return Client.Execute(arguments.Action, arguments.Args)
			end,
			Snapshot = function()
				return Client.Snapshot()
			end,
			Cleanup = function()
				return Client.Cleanup()
			end,
		},
	})
end

return table.freeze(Client)
