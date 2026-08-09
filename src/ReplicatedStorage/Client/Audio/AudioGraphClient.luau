--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local AudioProtocol = require(ReplicatedStorage.Shared.Audio.AudioProtocol)

local AudioGraphClient = {}
AudioGraphClient.__index = AudioGraphClient

local FADER_IDS = { "Master", "UI", "SFX", "World", "Music" }
local ROUTE_IDS = { "UI", "SFX", "World", "Music" }

local function hasExactChildren(parent: Instance, expected: { [string]: string }): boolean
	local count = 0
	for _, child in parent:GetChildren() do
		count += 1
		if expected[child.Name] ~= child.ClassName then return false end
	end
	local expectedCount = 0
	for _ in expected do expectedCount += 1 end
	return count == expectedCount
end

function AudioGraphClient.new(dependencies: any)
	return setmetatable({
		_dependencies = dependencies,
		_result = nil,
		_outputWire = nil,
		_frameConnection = nil,
		_characterConnections = {},
		_listener = nil,
		_listenerAnchor = nil,
		_localGraph = nil,
	}, AudioGraphClient)
end

function AudioGraphClient:_disabled(reason: string): any
	self._dependencies.Logger:Warn("GraphBindFailed", { ReasonCode = reason })
	self._result = table.freeze({ Enabled = false, ReasonCode = reason })
	return self._result
end

function AudioGraphClient:_inspectRoot(startup: any): any?
	local root = self._dependencies.RuntimeParent:FindFirstChild(AudioProtocol.RuntimeRootName)
	if root == nil or not root:IsA("Folder")
		or root:GetAttribute(AudioProtocol.AttributeNames.CompositionId) ~= AudioProtocol.CompositionId
		or root:GetAttribute(AudioProtocol.AttributeNames.SchemaVersion) ~= AudioProtocol.SchemaVersion
		or root:GetAttribute(AudioProtocol.AttributeNames.Generation) ~= AudioProtocol.Generation
		or root:GetAttribute(AudioProtocol.AttributeNames.Ready) ~= true
		or not hasExactChildren(root, {
			[AudioProtocol.PublishedGraphName] = "Folder",
			[AudioProtocol.ServerPlaybackName] = "Folder",
		})
	then return nil end
	local published = root:FindFirstChild(AudioProtocol.PublishedGraphName)
	local serverPlayback = root:FindFirstChild(AudioProtocol.ServerPlaybackName)
	if published == nil or serverPlayback == nil
		or not hasExactChildren(published, { Faders = "Folder", Wires = "Folder" })
	then return nil end
	local fadersFolder = published:FindFirstChild("Faders") :: Folder
	local wiresFolder = published:FindFirstChild("Wires") :: Folder
	local expectedFaders = {}
	for _, id in FADER_IDS do expectedFaders[id] = "AudioFader" end
	local expectedWires = {}
	for _, id in ROUTE_IDS do expectedWires[id .. "ToMaster"] = "Wire" end
	if not hasExactChildren(fadersFolder, expectedFaders) or not hasExactChildren(wiresFolder, expectedWires) then return nil end
	local faders = {}
	for _, id in FADER_IDS do faders[id] = fadersFolder:FindFirstChild(id) end
	for _, id in ROUTE_IDS do
		local wire = wiresFolder:FindFirstChild(id .. "ToMaster") :: Wire
		if wire.SourceInstance ~= faders[id] or wire.TargetInstance ~= faders.Master then return nil end
	end
	return { Root = root, ServerPlayback = serverPlayback, Faders = faders, Config = startup.Config }
end

function AudioGraphClient:_updateListener()
	local listener = self._listener
	local anchor = self._listenerAnchor
	if listener == nil or anchor == nil then return end
	local character = self._dependencies.PlayersModule:GetCharacter()
	local humanoidRoot = if character then character:FindFirstChild("HumanoidRootPart") else nil
	local cameraCFrame = self._dependencies.GetCurrentCameraCFrame()
	if humanoidRoot ~= nil and humanoidRoot:IsA("BasePart") and cameraCFrame ~= nil then
		anchor.CFrame = CFrame.new(humanoidRoot.Position) * cameraCFrame.Rotation
		anchor.Parent = self._dependencies.Workspace
		listener.Parent = anchor
		listener.PositionInstance = anchor
	else
		listener.PositionInstance = nil
		listener.Parent = self._localGraph
	end
end

function AudioGraphClient:Initialize(startup: any): any
	if self._result ~= nil then return self._result end
	if not startup.Enabled then return self:_disabled("AudioDisabled") end
	local clock = self._dependencies.Clock or os.clock
	local waitStep = self._dependencies.Wait or task.wait
	local deadline = clock() + 10
	local inspected = self:_inspectRoot(startup)
	while inspected == nil and clock() < deadline do
		waitStep()
		inspected = self:_inspectRoot(startup)
	end
	if inspected == nil then return self:_disabled("GraphMismatchOrTimeout") end

	local create = self._dependencies.InstanceFactory or Instance.new
	local localGraph: Folder? = nil
	local anchor: Part? = nil
	local listener: AudioListener? = nil
	local frameConnection = nil
	local characterConnections = {}
	local ok, resultOrError = xpcall(function()
		localGraph = create("Folder") :: Folder
		localGraph.Name = "ClientGraph"
		listener = create("AudioListener") :: AudioListener
		listener.Name = "Listener"
		listener.AcousticSimulationEnabled = true
		listener.AudioInteractionGroup = startup.Config.InteractionGroupId
		listener.Parent = localGraph
		anchor = create("Part") :: Part
		anchor.Name = "AudioListenerAnchor"
		anchor.Anchored = true
		anchor.CanCollide = false
		anchor.CanQuery = false
		anchor.CanTouch = false
		anchor.Transparency = 1
		anchor.Parent = self._dependencies.Workspace
		local output = create("AudioDeviceOutput") :: AudioDeviceOutput
		output.Name = "Output"
		output.Player = self._dependencies.LocalPlayer
		output.Parent = localGraph
		local worldWire = create("Wire") :: Wire
		worldWire.Name = "ListenerToWorld"
		worldWire.SourceInstance = listener
		worldWire.TargetInstance = inspected.Faders.World
		worldWire.Parent = localGraph
		self._listener = listener
		self._listenerAnchor = anchor
		self._localGraph = localGraph
		frameConnection = self._dependencies.ListenerFrameDriver:Connect(function() self:_updateListener() end)
		table.insert(characterConnections, self._dependencies.PlayersModule.CharacterRemoving:Connect(function()
			if self._listener ~= nil then
				self._listener.PositionInstance = nil
				self._listener.Parent = self._localGraph
			end
		end))
		table.insert(characterConnections, self._dependencies.PlayersModule.CharacterAdded:Connect(function()
			self:_updateListener()
		end))
		self:_updateListener()
		localGraph.Parent = inspected.Root
		return table.freeze({
			Enabled = true,
			Generation = AudioProtocol.Generation,
			Root = inspected.Root,
			LocalRoot = localGraph,
			Faders = table.freeze(inspected.Faders),
			Listener = listener,
			ListenerAnchor = anchor,
			Output = output,
			Config = startup.Config,
		})
	end, debug.traceback)
	if not ok then
		if frameConnection ~= nil then frameConnection:Disconnect() end
		for _, connection in characterConnections do connection:Disconnect() end
		if listener ~= nil then listener.PositionInstance = nil end
		self._listener = nil
		self._listenerAnchor = nil
		self._localGraph = nil
		if anchor ~= nil then anchor:Destroy() end
		if localGraph ~= nil then localGraph:Destroy() end
		return self:_disabled("GraphConstructionFailed")
	end
	self._frameConnection = frameConnection
	self._characterConnections = characterConnections
	self._result = resultOrError
	return self._result
end

function AudioGraphClient:BindOutput(): boolean
	local graph = self._result
	if graph == nil or not graph.Enabled then return false end
	if self._outputWire ~= nil then return true end
	local create = self._dependencies.InstanceFactory or Instance.new
	local wire: Wire? = nil
	local ok = xpcall(function()
		wire = create("Wire") :: Wire
		wire.Name = "MasterToOutput"
		wire.SourceInstance = graph.Faders.Master
		wire.TargetInstance = graph.Output
		wire.Parent = graph.LocalRoot
	end, debug.traceback)
	if not ok then
		if wire ~= nil then wire:Destroy() end
		return false
	end
	self._outputWire = wire
	return true
end

function AudioGraphClient:UnbindOutput()
	if self._outputWire ~= nil then self._outputWire:Destroy(); self._outputWire = nil end
end

function AudioGraphClient:Stop()
	self:UnbindOutput()
	if self._frameConnection ~= nil then self._frameConnection:Disconnect(); self._frameConnection = nil end
	for _, connection in self._characterConnections do connection:Disconnect() end
	table.clear(self._characterConnections)
	local graph = self._result
	if graph ~= nil and graph.Enabled then
		graph.Listener.PositionInstance = nil
		graph.LocalRoot:Destroy()
	end
	self._listener = nil
	if self._listenerAnchor ~= nil then self._listenerAnchor:Destroy(); self._listenerAnchor = nil end
	self._localGraph = nil
	self._result = nil
end

return AudioGraphClient
