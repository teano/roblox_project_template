--!strict

local Players = game:GetService("Players")
local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local WindowConfigCompiler = require(ReplicatedStorage.Client.UI.Config.WindowConfigCompiler)
local WindowAssetLoader = require(ReplicatedStorage.Client.UI.WindowAssetLoader)
local WindowAssetFixtureDefinition = require(ReplicatedStorage.Client.UI.Config.Definitions.WindowAssetFixtureDefinition)

local Fixture = {}
local activeSession: Session? = nil

type CounterState = {
	Loads: number,
	Preloads: number,
	PointerActivations: number,
	BackgroundActivations: number,
	PrimaryActivations: number,
	SecondaryActivations: number,
}

export type Session = {
	Definition: unknown,
	Root: GuiObject,
	ScreenGui: ScreenGui,
	Counters: CounterState,
	ReleaseBlock: (self: Session) -> (),
	Snapshot: (self: Session) -> { [string]: unknown },
	Finish: (self: Session) -> (),
}

local function assertDataOnly(root: GuiObject)
	for _, descendant in root:GetDescendants() do
		assert(not descendant:IsA("LuaSourceContainer"), "fixture must remain recursively data-only")
	end
end

function Fixture.start(): Session
	assert(activeSession == nil, "WindowAssetFixturePlaySetup already active")
	local compiled, compileError = WindowConfigCompiler.compile({ WindowAssetFixtureDefinition }, {})
	assert(compiled ~= nil and compileError == nil, "fixture definition must compile")
	local definition = compiled.ByWindowId[WindowAssetFixtureDefinition.WindowId]
	assert(definition == WindowAssetFixtureDefinition and table.isfrozen(WindowAssetFixtureDefinition))

	local counters: CounterState = {
		Loads = 0,
		Preloads = 0,
		PointerActivations = 0,
		BackgroundActivations = 0,
		PrimaryActivations = 0,
		SecondaryActivations = 0,
	}
	local sourceRoot = script.Parent.WindowAssetFixture
	assert(sourceRoot:IsA("GuiObject"))
	assertDataOnly(sourceRoot :: GuiObject)

	local loader = WindowAssetLoader.new({
		AssetBackend = {
			LoadAssetAsync = function(_self: unknown, assetId: number): Instance
				assert(assetId == 1001)
				counters.Loads += 1
				local wrapper = Instance.new("Folder")
				local clone = (sourceRoot :: GuiObject):Clone()
				clone.Parent = wrapper
				return wrapper
			end,
		},
		ContentPreloader = {
			Preload = function(_self: unknown, targets: { Instance }, options: { [string]: unknown })
				assert(#targets == 1 and options.FailurePolicy == "Fail" and options.RequestId == nil)
				counters.Preloads += 1
				return { Failed = 0 }
			end,
		},
	}) :: any

	local templateRoot, loadError = loader:GetTemplate(WindowAssetFixtureDefinition, os.clock() + 3)
	assert(templateRoot ~= nil and loadError == nil)
	local cachedRoot, cachedError = loader:GetTemplate(WindowAssetFixtureDefinition, os.clock() + 3)
	assert(cachedRoot == templateRoot and cachedError == nil and counters.Loads == 1 and counters.Preloads == 1)
	local firstClone = (templateRoot :: GuiObject):Clone()
	local secondClone = (templateRoot :: GuiObject):Clone()
	assert(firstClone ~= secondClone)
	secondClone:Destroy()

	local player = Players.LocalPlayer
	assert(player ~= nil)
	local playerGui = player:WaitForChild("PlayerGui")
	local productionRoot = playerGui:FindFirstChild("UiRoot")
	assert(productionRoot ~= nil and productionRoot:IsA("ScreenGui"))
	local hudHost = productionRoot:FindFirstChild("HudHost")
	local toastHost = productionRoot:FindFirstChild("ToastHost")
	local windowHost = productionRoot:FindFirstChild("WindowHost")
	assert(hudHost ~= nil and toastHost ~= nil and windowHost ~= nil)
	assert(#(windowHost :: Instance):GetChildren() == 0, "production WindowHost must stay untouched")

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "UiSystemLocalFixtureEvidence"
	screenGui.ResetOnSpawn = false
	screenGui.ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets
	screenGui.DisplayOrder = 10000
	firstClone.Name = "WindowRoot"
	firstClone.Parent = screenGui

	local inputSink = firstClone:FindFirstChild("InputSink")
	assert(inputSink ~= nil and inputSink:IsA("GuiObject"))
	local blockReference = Instance.new("ObjectValue")
	blockReference.Name = "BlockObjectRef"
	blockReference.Value = inputSink
	blockReference.Parent = firstClone

	local content = firstClone:FindFirstChild("Content")
	local background = firstClone:FindFirstChild("Background")
	assert(content ~= nil and content:IsA("Frame"))
	assert(background ~= nil and background:IsA("GuiButton"))
	local pointer = content:FindFirstChild("PointerButton")
	local primary = content:FindFirstChild("GamepadPrimary")
	local secondary = content:FindFirstChild("GamepadSecondary")
	assert(pointer ~= nil and pointer:IsA("GuiButton"))
	assert(primary ~= nil and primary:IsA("GuiButton"))
	assert(secondary ~= nil and secondary:IsA("GuiButton"))
	primary.NextSelectionRight = secondary
	secondary.NextSelectionLeft = primary

	local connections = {
		pointer.Activated:Connect(function() counters.PointerActivations += 1 end),
		background.Activated:Connect(function() counters.BackgroundActivations += 1 end),
		primary.Activated:Connect(function() counters.PrimaryActivations += 1 end),
		secondary.Activated:Connect(function() counters.SecondaryActivations += 1 end),
	}
	screenGui.Parent = playerGui
	GuiService.SelectedObject = primary :: GuiObject

	local blocker = require(ReplicatedStorage.Client.UI.WindowInputBlocker).new(firstClone) :: any
	assert(blocker:Initialize().Kind == "Success")
	local blockHandle = blocker:Acquire()
	assert((inputSink :: GuiObject).InputSink == Enum.InputSink.All)

	local finished = false
	local session = {} :: Session
	session.Definition = definition
	session.Root = firstClone
	session.ScreenGui = screenGui
	session.Counters = counters
	function session:ReleaseBlock()
		blockHandle:Release()
		assert((inputSink :: GuiObject).InputSink == Enum.InputSink.None)
		-- The fixture keeps the production block surface above all content while blocked.
		-- Hide that inert test surface after release so physical input reaches the buttons.
		inputSink.Visible = false
	end
	function session:Snapshot(): { [string]: unknown }
		return {
			WindowId = WindowAssetFixtureDefinition.WindowId,
			AssetId = WindowAssetFixtureDefinition.AssetId,
			Loads = counters.Loads,
			Preloads = counters.Preloads,
			PointerActivations = counters.PointerActivations,
			BackgroundActivations = counters.BackgroundActivations,
			PrimaryActivations = counters.PrimaryActivations,
			SecondaryActivations = counters.SecondaryActivations,
			SelectedObject = if GuiService.SelectedObject then GuiService.SelectedObject.Name else nil,
			ViewportSize = `{firstClone.AbsoluteSize.X}x{firstClone.AbsoluteSize.Y}`,
			InputSink = (inputSink :: GuiObject).InputSink.Name,
		}
	end
	function session:Finish()
		if finished then
			return
		end
		finished = true
		if GuiService.SelectedObject ~= nil and GuiService.SelectedObject:IsDescendantOf(screenGui) then
			GuiService.SelectedObject = nil
		end
		blocker:Clear()
		for _, connection in connections do
			connection:Disconnect()
		end
		loader:Destroy()
		screenGui:Destroy()
		assert(#(windowHost :: Instance):GetChildren() == 0)
		activeSession = nil
	end
	activeSession = session
	return session
end

function Fixture.getActiveSession(): Session?
	return activeSession
end

return table.freeze(Fixture)
