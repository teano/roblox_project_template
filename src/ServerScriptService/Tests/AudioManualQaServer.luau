--!strict

--[[
	Manual Studio-only server driver and report coordinator for collaborative
	Audio QA. It uses the already initialized production services and creates no
	transport or startup path of its own.
]]

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")

local AudioProtocol = require(ReplicatedStorage.Shared.Audio.AudioProtocol)
local Bridge = require(ReplicatedStorage.Shared.Tests.AudioManualQaBridge)
local Contracts = require(ReplicatedStorage.Shared.Tests.AudioManualQaContracts)
local Plan = require(ReplicatedStorage.Shared.Tests.AudioManualQaPlan)

local Server = {}

local session: any? = nil
local bootstrapServices: any? = nil

local function emit(event: string, payload: any): any
	local envelope = {
		Source = "AudioManualQaServer",
		Event = event,
		Payload = payload,
	}
	print(`[AudioManualQA] {HttpService:JSONEncode(envelope)}`)
	return payload
end

local function assertRuntimeContext()
	assert(RunService:IsStudio(), "AudioManualQaServer is Studio-only")
	assert(RunService:IsServer(), "AudioManualQaServer must run in the server VM")
	assert(RunService:IsRunning(), "Start a Play/Test Server session before AudioManualQaServer")
end

local function invokeBridge(command: string, arguments: any): any
	assertRuntimeContext()
	local bootstrap = assert(game.ServerScriptService:FindFirstChild("Bootstrap"),
		"Production server Bootstrap is unavailable")
	return Bridge.Invoke(bootstrap, "Server", command, arguments)
end

local function getSession(): any
	assertRuntimeContext()
	return assert(session, "Call AudioManualQaServer.Start(runId) first")
end

local function vector(value: Vector3): any
	return { X = value.X, Y = value.Y, Z = value.Z }
end

local function makeVisibleTarget(name: string, color: Color3, position: Vector3): Part
	local target = Instance.new("Part")
	target.Name = name
	target.Anchored = true
	target.CanCollide = false
	target.CanQuery = false
	target.CanTouch = false
	target.Material = Enum.Material.Neon
	target.Color = color
	target.Size = Vector3.new(4, 4, 4)
	target.CFrame = CFrame.new(position)
	target.Parent = Workspace
	return target
end

local function defaultTargetPosition(): Vector3
	local spawn = Workspace:FindFirstChildWhichIsA("SpawnLocation", true) :: SpawnLocation?
	if spawn ~= nil then return spawn.Position + Vector3.new(0, 4, -12) end
	return Vector3.new(0, 8, 0)
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

local function graphSnapshot(graph: any): any
	local faders = {}
	local published = graph.Root:FindFirstChild(AudioProtocol.PublishedGraphName)
	local fadersFolder = if published then published:FindFirstChild("Faders") else nil
	local wiresFolder = if published then published:FindFirstChild("Wires") else nil
	for _, category in { "Master", "UI", "SFX", "World", "Music" } do
		local fader = if fadersFolder then fadersFolder:FindFirstChild(category) else nil
		faders[category] = if fader and fader:IsA("AudioFader") then fader.Volume else nil
	end
	return {
		Enabled = true,
		Generation = graph.Root:GetAttribute(AudioProtocol.AttributeNames.Generation),
		Ready = graph.Root:GetAttribute(AudioProtocol.AttributeNames.Ready),
		FaderCount = if fadersFolder then #fadersFolder:GetChildren() else 0,
		WireCount = if wiresFolder then #wiresFolder:GetChildren() else 0,
		FaderVolume = faders,
	}
end

local function acousticProperty(): any
	local ok, value = pcall(function() return (SoundService :: any).AcousticSimulationEnabled end)
	return if ok then value else "Unavailable"
end

local function playbackOptions(args: any): any?
	local options = {}
	if typeof(args.VolumeMultiplier) == "number" then options.VolumeMultiplier = args.VolumeMultiplier end
	if typeof(args.PlaybackSpeedMultiplier) == "number" then options.PlaybackSpeedMultiplier = args.PlaybackSpeedMultiplier end
	if typeof(args.TimePosition) == "number" then options.TimePosition = args.TimePosition end
	return if next(options) == nil then nil else options
end

local function cleanup(current: any)
	if current == nil then return end
	for _, record in current.Handles do pcall(function() record.Handle:Stop() end) end
	table.clear(current.Handles)
	table.clear(current.AcceptedOneShots)
	if current.PointMarker ~= nil then current.PointMarker:Destroy(); current.PointMarker = nil end
	if current.AttachedTarget ~= nil then current.AttachedTarget:Destroy(); current.AttachedTarget = nil end
end

function Server.Start(runId: string): any
	assertRuntimeContext()
	if bootstrapServices == nil then return invokeBridge("Start", { RunId = runId }) end
	assert(typeof(runId) == "string" and runId ~= "", "runId must be a non-empty string")
	if session ~= nil then cleanup(session) end
	local runtimeRoot = ReplicatedStorage:FindFirstChild(AudioProtocol.RuntimeRootName)
	assert(runtimeRoot ~= nil and runtimeRoot:GetAttribute(AudioProtocol.AttributeNames.Ready) == true, "Production Audio runtime is not ready")
	local services = bootstrapServices
	local serverPlayback = assert(runtimeRoot:FindFirstChild(AudioProtocol.ServerPlaybackName), "Production ServerPlayback is missing")
	local graph = { Root = runtimeRoot, ServerPlayback = serverPlayback }
	local startup = assert(services.AudioStartup, "Production server Audio startup state is unavailable")
	assert(startup.Enabled == true and startup.Catalog ~= nil, "Production server Audio catalog is not enabled")
	local identityOk, liveAssets, identityError = Plan.ValidateLiveAssets(
		startup.Catalog,
		assert(ReplicatedStorage:FindFirstChild("Assets"), "ReplicatedStorage.Assets is missing")
	)
	assert(identityOk, identityError)
	session = {
		RunId = runId,
		StartedAtUnix = os.time(),
		Services = services,
		Graph = graph,
		LiveAssets = liveAssets,
		Handles = {},
		AcceptedOneShots = {},
		Records = {},
		ActionSequence = 0,
		PointMarker = nil,
		AttachedTarget = nil,
	}
	return emit("Started", Server.Snapshot())
end

function Server.Snapshot(): any
	if bootstrapServices == nil then return invokeBridge("Snapshot", {}) end
	local current = getSession()
	local graph = current.Graph
	local pools = current.Services.Pooling
	return {
		RunId = current.RunId,
		PlaceId = game.PlaceId,
		GameId = game.GameId,
		StartedAtUnix = current.StartedAtUnix,
		AcousticSimulationEnabled = acousticProperty(),
		Graph = graphSnapshot(graph),
		Pools = {
			UI = poolStats(pools, "Audio.Server.UI"),
			SFX = poolStats(pools, "Audio.Server.SFX"),
			World = poolStats(pools, "Audio.Server.World"),
		},
		ServerPlayback = collectPlayback(graph.ServerPlayback),
		WorldPlayback = collectPlayback(Workspace),
		Preload = Contracts.GetAudioPreloadSnapshot(current.Services.ContentPreloader),
		LiveAssets = current.LiveAssets,
		Handles = handleSnapshot(current.Handles),
		AcceptedOneShots = current.AcceptedOneShots,
		PointMarker = if current.PointMarker then vector(current.PointMarker.Position) else nil,
		AttachedTarget = if current.AttachedTarget then {
			Name = current.AttachedTarget.Name,
			Position = vector(current.AttachedTarget.Position),
		} else nil,
	}
end

function Server.Execute(action: string, args: any?): any
	if bootstrapServices == nil then return invokeBridge("Execute", { Action = action, Args = args }) end
	local current = getSession()
	assert(Plan.ServerActions[action] == true, `Unknown server QA action '{action}'`)
	local parameters = args or {}
	local result: any = { Action = action }

	if action == "snapshot" then
		result.Snapshot = Server.Snapshot()
	elseif action == "play_sfx" then
		local key = "CartoonBubble"
		local expected = Plan.LiveAssets[key]
		local playback = current.Services.OrdinarySound:Play(Contracts.MakeCueRef(expected), playbackOptions(parameters))
		result.Accepted = playback.Accepted
		result.ReasonCode = playback.ReasonCode
		result.LiveAsset = expected
		local stored = Contracts.StoreAcceptedServerPlayback(current, parameters.Label, playback, "ServerSFX", key)
		result.Label = stored.Label
		result.HasHandle = stored.HasHandle
	elseif action == "create_point_marker" then
		if current.PointMarker ~= nil then current.PointMarker:Destroy() end
		current.PointMarker = makeVisibleTarget("QA_ServerPointMarker", Color3.fromRGB(85, 255, 127), defaultTargetPosition())
		result.Position = vector(current.PointMarker.Position)
	elseif action == "play_at_marker" then
		assert(current.PointMarker ~= nil and current.PointMarker.Parent ~= nil, "Create the point marker first")
		local key = "OldCarEngine"
		local expected = Plan.LiveAssets[key]
		local playback = current.Services.OrdinarySound:PlayAt(
			Contracts.MakeCueRef(expected),
			current.PointMarker.Position,
			playbackOptions(parameters)
		)
		result.Accepted = playback.Accepted
		result.ReasonCode = playback.ReasonCode
		result.LiveAsset = expected
		local stored = Contracts.StoreAcceptedServerPlayback(current, parameters.Label, playback, "ServerPoint", key)
		result.Label = stored.Label
		result.HasHandle = stored.HasHandle
	elseif action == "create_attached_target" then
		if current.AttachedTarget ~= nil then current.AttachedTarget:Destroy() end
		current.AttachedTarget = makeVisibleTarget("QA_ServerAttachedTarget", Color3.fromRGB(255, 80, 80), defaultTargetPosition())
		result.Position = vector(current.AttachedTarget.Position)
	elseif action == "play_attached" then
		assert(current.AttachedTarget ~= nil and current.AttachedTarget.Parent ~= nil, "Create the attached target first")
		local key = "OldCarEngine"
		local expected = Plan.LiveAssets[key]
		local playback = current.Services.OrdinarySound:PlayAttached(
			Contracts.MakeCueRef(expected),
			current.AttachedTarget,
			playbackOptions(parameters)
		)
		result.Accepted = playback.Accepted
		result.ReasonCode = playback.ReasonCode
		result.LiveAsset = expected
		local stored = Contracts.StoreAcceptedServerPlayback(current, parameters.Label, playback, "ServerAttached", key)
		result.Label = stored.Label
		result.HasHandle = stored.HasHandle
	elseif action == "move_attached_target" then
		assert(current.AttachedTarget ~= nil and current.AttachedTarget.Parent ~= nil, "Create the attached target first")
		local offset = Vector3.new(parameters.X or 10, parameters.Y or 0, parameters.Z or 0)
		current.AttachedTarget.CFrame = current.AttachedTarget.CFrame * CFrame.new(offset) * CFrame.Angles(0, math.rad(parameters.YawDegrees or 90), 0)
		result.Position = vector(current.AttachedTarget.Position)
	elseif action == "remove_attached_target" then
		if current.AttachedTarget ~= nil then current.AttachedTarget:Destroy(); current.AttachedTarget = nil end
	elseif action == "stop_handle" then
		local label = assert(parameters.Label, "stop_handle requires args.Label")
		local record = assert(current.Handles[label], `Unknown handle '{tostring(label)}'`)
		record.Handle:Stop()
	elseif action == "cleanup" then
		cleanup(current)
	end

	if result.Snapshot == nil then result.Snapshot = Server.Snapshot() end
	return emit("Action", result)
end

function Server.RecordScenario(
	scenarioId: string,
	status: string,
	objectivePassed: boolean?,
	humanEvidence: any?,
	note: string?
): any
	if bootstrapServices == nil then
		return invokeBridge("RecordScenario", {
			ScenarioId = scenarioId,
			Status = status,
			ObjectivePassed = objectivePassed,
			HumanEvidence = humanEvidence,
			Note = note,
		})
	end
	local current = getSession()
	local scenario = assert(Plan.GetScenario(scenarioId), `Unknown Audio QA scenario '{scenarioId}'`)
	scenarioId = scenario.Id
	assert(status == "PASS" or status == "FAIL" or status == "BLOCKED", "status must be PASS, FAIL, or BLOCKED")
	assert(objectivePassed == nil or typeof(objectivePassed) == "boolean", "objectivePassed must be boolean or nil")
	assert(note == nil or typeof(note) == "string", "note must be string or nil")
	local copiedHumanEvidence = nil
	if humanEvidence ~= nil then copiedHumanEvidence = Contracts.CopyOperatorEvidence(humanEvidence) end
	if scenario.HumanRequired and status == "PASS" then
		assert(copiedHumanEvidence ~= nil,
			"A hearing-required PASS needs explicit OperatorStatement evidence")
	elseif not scenario.HumanRequired then
		assert(copiedHumanEvidence == nil, "Non-auditory scenarios must not record hearing evidence")
	end
	if status == "PASS" then
		assert(#current.LiveAssets == #Plan.LiveAssetOrder, "Exact live Audio asset identity is incomplete")
	end
	current.Records[scenarioId] = {
		Status = status,
		ObjectivePassed = objectivePassed,
		HumanEvidence = copiedHumanEvidence,
		Note = note,
		RecordedAtUnix = os.time(),
	}
	return emit("ScenarioRecorded", {
		ScenarioId = scenarioId,
		Record = current.Records[scenarioId],
		Evaluation = Plan.Evaluate(current.Records),
	})
end

function Server.Export(): any
	if bootstrapServices == nil then return invokeBridge("Export", {}) end
	local current = getSession()
	local result = {
		SchemaVersion = Plan.SchemaVersion,
		RunId = current.RunId,
		PlaceId = game.PlaceId,
		GameId = game.GameId,
		StartedAtUnix = current.StartedAtUnix,
		ExportedAtUnix = os.time(),
		LiveAssets = current.LiveAssets,
		Records = current.Records,
		Evaluation = Plan.Evaluate(current.Records),
		FinalSnapshot = Server.Snapshot(),
	}
	return emit("Report", result)
end

function Server.GetPlan(): any
	assertRuntimeContext()
	return Plan
end

function Server.Cleanup(): any
	if bootstrapServices == nil then return invokeBridge("Cleanup", {}) end
	local current = getSession()
	cleanup(current)
	local result = Server.Snapshot()
	return emit("Cleaned", result)
end

function Server.InstallBridge(services: any, parent: Instance): any?
	assertRuntimeContext()
	assert(bootstrapServices == nil, "AudioManualQaServer bridge services are already bound")
	bootstrapServices = services
	return Bridge.Install({
		Parent = parent,
		Side = "Server",
		Commands = {
			Start = function(arguments)
				return Server.Start(arguments.RunId)
			end,
			Execute = function(arguments)
				return Server.Execute(arguments.Action, arguments.Args)
			end,
			Snapshot = function()
				return Server.Snapshot()
			end,
			RecordScenario = function(arguments)
				return Server.RecordScenario(
					arguments.ScenarioId,
					arguments.Status,
					arguments.ObjectivePassed,
					arguments.HumanEvidence,
					arguments.Note
				)
			end,
			Export = function()
				return Server.Export()
			end,
			Cleanup = function()
				return Server.Cleanup()
			end,
		},
	})
end

return table.freeze(Server)
