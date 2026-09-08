--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TestHarness = require(script.Parent.TestHarness)
local UiSystem = require(ReplicatedStorage.Client.UI.UiSystem)
local UiRootController = require(ReplicatedStorage.Client.UI.UiRootController)
local UiElementIdentityRegistry = require(ReplicatedStorage.Client.UI.UiElementIdentityRegistry)
local BaseWindowView = require(ReplicatedStorage.Client.UI.Windows.BaseWindowView)
local UiActionIds = require(ReplicatedStorage.Client.UI.Actions.UiActionIds)
local FrameController = require(ReplicatedStorage.Client.UI.Elements.Controllers.FrameController)
local TextController = require(ReplicatedStorage.Client.UI.Elements.Controllers.TextController)
local ImageController = require(ReplicatedStorage.Client.UI.Elements.Controllers.ImageController)
local ButtonController = require(ReplicatedStorage.Client.UI.Elements.Controllers.ButtonController)
local TextBoxController = require(ReplicatedStorage.Client.UI.Elements.Controllers.TextBoxController)
local FormController = require(ReplicatedStorage.Client.UI.Elements.Controllers.FormController)
local ScrollingFrameController = require(ReplicatedStorage.Client.UI.Elements.Controllers.ScrollingFrameController)
local UiInitializationCommand = require(ReplicatedStorage.Client.Initialization.Commands.UiInitializationCommand)
local InitializationRunner = require(ReplicatedStorage.Shared.Initialization.InitializationRunner)
local PoolModule = require(ReplicatedStorage.Shared.Pooling.PoolModule)
local WindowConfigCompiler = require(ReplicatedStorage.Client.UI.Config.WindowConfigCompiler)
local WindowAssetFixtureDefinition = require(ReplicatedStorage.Client.UI.Config.Definitions.WindowAssetFixtureDefinition)
local WindowInputBlocker = require(ReplicatedStorage.Client.UI.WindowInputBlocker)
local WindowAssetLoader = require(ReplicatedStorage.Client.UI.WindowAssetLoader)
local WindowPoolOwner = require(ReplicatedStorage.Client.UI.WindowPoolOwner)
local WindowNavigator = require(ReplicatedStorage.Client.UI.WindowNavigator)

local UiSystemTestRunner = {}
local makeIdentityContext: (onDeliver: ((any) -> ())?) -> any

local function makePlayersModule(scope: TestHarness.Scope)
	local playerGui = scope:Track(Instance.new("Folder")) :: Folder
	playerGui.Name = "PlayerGui"
	local player = {
		FindFirstChildOfClass = function(_self: any, className: string)
			return if className == "PlayerGui" then playerGui else nil
		end,
	}
	return {
		GetLocalPlayer = function()
			return player
		end,
	}, playerGui
end

local function makeBindable(scope: TestHarness.Scope): BindableEvent
	return scope:Track(Instance.new("BindableEvent")) :: BindableEvent
end

local function waitUntil(predicate: () -> boolean): boolean
	local deadline = os.clock() + 1
	repeat
		if predicate() then
			return true
		end
		task.wait()
	until os.clock() >= deadline
	return predicate()
end

local function makeDeterministicScheduler()
	local now = 0
	local delayed = {} :: { { At: number, Callback: () -> () } }
	local spawned = {} :: { thread }
	local delayRequests = {} :: { number }

	local scheduler = {}
	function scheduler.Clock(): number
		return now
	end
	function scheduler.SetNow(value: number)
		now = value
	end
	function scheduler.Spawn(callback: () -> ())
		local thread = coroutine.create(callback)
		local resumed, problem = coroutine.resume(thread)
		assert(resumed, problem)
		if coroutine.status(thread) ~= "dead" then
			table.insert(spawned, thread)
		end
	end
	function scheduler.Delay(seconds: number, callback: () -> ())
		table.insert(delayRequests, seconds)
		table.insert(delayed, { At = now + seconds, Callback = callback })
	end
	function scheduler.Wait(_signal: RBXScriptSignal, isSettled: () -> boolean)
		repeat
			assert(#delayed > 0, "deterministic scheduler has no deadline callback")
			table.sort(delayed, function(left, right)
				return left.At < right.At
			end)
			local item = table.remove(delayed, 1)
			now = item.At
			item.Callback()
		until isSettled() or #delayed == 0
	end
	function scheduler.ResumeSpawned()
		local pending = table.clone(spawned)
		table.clear(spawned)
		for _, thread in pending do
			local resumed, problem = coroutine.resume(thread)
			assert(resumed, problem)
			if coroutine.status(thread) ~= "dead" then
				table.insert(spawned, thread)
			end
		end
	end
	function scheduler.PendingSpawnCount(): number
		return #spawned
	end
	function scheduler.DelayRequests(): { number }
		return delayRequests
	end
	return scheduler
end

local function assertSuccess(result: any)
	local code = if typeof(result.Error) == "table" then result.Error.Code else nil
	assert(result.Kind == "Success", `expected Success, got {result.Kind}/{tostring(code)}`)
end

local function TS_TEST_001_RootHostsOwnership(scope: TestHarness.Scope)
	local playersModule, playerGui = makePlayersModule(scope)
	local ui = UiSystem.new({ PlayersModule = playersModule, TemplateWindowDefinitions = {} })
	scope:Defer(function()
		ui:Destroy()
	end)
	assertSuccess(ui:Initialize())
	local root = playerGui:FindFirstChild("UiRoot") :: ScreenGui
	assert(root ~= nil and root:IsA("ScreenGui"))
	assert(root.ResetOnSpawn == false)
	assert(root.ScreenInsets == Enum.ScreenInsets.CoreUISafeInsets)
	assert(root.ClipToDeviceSafeArea)
	local hud = ui:GetHudHost()
	local toast = ui:GetToastHost()
	local windows = root:FindFirstChild("WindowHost") :: Frame
	assert(hud.Parent == root and toast.Parent == root and windows.Parent == root)
	assert(hud.ZIndex < toast.ZIndex and toast.ZIndex < windows.ZIndex)
	assert(#windows:GetChildren() == 0)
	local elementContext = ui:GetUiElementContext()
	assert(elementContext ~= nil and table.isfrozen(elementContext))
	assert(typeof(elementContext.ClaimSubtree) == "function")
	assert(typeof(elementContext.ReleaseSubtree) == "function")
	assert(typeof(elementContext.DeliverToRoot) == "function")
	local sameRoot = root
	assertSuccess(ui:Initialize())
	assert(playerGui:FindFirstChild("UiRoot") == sameRoot)

	local malformedPlayers, malformedPlayerGui = makePlayersModule(scope)
	local malformed = Instance.new("ScreenGui")
	malformed.Name = "UiRoot"
	malformed.ResetOnSpawn = false
	malformed.Parent = malformedPlayerGui
	local controller = UiRootController.new(malformedPlayers)
	scope:Defer(function()
		controller:Destroy()
	end)
	local malformedResult = controller:Initialize()
	assert(malformedResult.Kind == "Error" and malformedResult.Error.Code == "UiRootMalformed")
	assert(malformed.Parent == malformedPlayerGui, "malformed pre-existing root must not be partially mutated")

	local wrongClassPlayer = scope:Track(Instance.new("Folder")) :: Folder
	local wrongClassPlayerGui = Instance.new("Folder")
	wrongClassPlayerGui.Name = "PlayerGui"
	wrongClassPlayerGui.Parent = wrongClassPlayer
	local wrongClassController = UiRootController.new({
		GetLocalPlayer = function()
			return wrongClassPlayer
		end,
	})
	scope:Defer(function()
		wrongClassController:Destroy()
	end)
	local wrongClassResult = wrongClassController:Initialize()
	assert(wrongClassResult.Kind == "Error" and wrongClassResult.Error.Code == "UiRootMalformed")
	assert(wrongClassPlayerGui.Parent == wrongClassPlayer)
end

local function TS_TEST_013_ControllerIdentityEvents(scope: TestHarness.Scope)
	local playersModule = makePlayersModule(scope)
	local ui = UiSystem.new({ PlayersModule = playersModule, TemplateWindowDefinitions = {} })
	scope:Defer(function()
		ui:Destroy()
	end)
	assertSuccess(ui:Initialize())

	local received = {}
	assert(ui.Events.Fire == nil and ui.Events.Wait == nil and ui.Events.Destroy == nil)
	local connection = ui.Events:Connect(function(event)
		table.insert(received, event)
	end)
	scope:Defer(function()
		connection:Disconnect()
	end)
	local windowRoot = scope:Track(Instance.new("Frame")) :: Frame
	local window = BaseWindowView.new(windowRoot, "inventory", "ui.window/inventory", ui:GetUiElementContext())
	assertSuccess(window:Initialize(nil))

	local pointerEntered = makeBindable(scope)
	local pointerExited = makeBindable(scope)
	local activated = makeBindable(scope)
	local buttonRoot = Instance.new("ImageButton")
	buttonRoot.Parent = windowRoot
	local button = ButtonController.new(buttonRoot, "ui.window/inventory/open", true, ui:GetUiElementContext(), {
		MouseEnter = pointerEntered.Event,
		MouseLeave = pointerExited.Event,
		Activated = activated.Event,
	})
	assertSuccess(window:AddNestedUiElement(button))

	local yieldGate = makeBindable(scope)
	local yieldingStarted = false
	local yieldingFinished = false
	local failingStarted = false
	local followingListenerCalls = 0
	local yieldingConnection = ui.Events:Connect(function()
		yieldingStarted = true
		yieldGate.Event:Wait()
		yieldingFinished = true
	end)
	local failingConnection = ui.Events:Connect(function()
		failingStarted = true
		error("ExpectedUiRootListenerFailure")
	end)
	local followingConnection = ui.Events:Connect(function()
		followingListenerCalls += 1
	end)
	scope:Defer(function()
		yieldingConnection:Disconnect()
		failingConnection:Disconnect()
		followingConnection:Disconnect()
	end)
	pointerEntered:Fire()
	assert(waitUntil(function()
		return yieldingStarted and failingStarted and followingListenerCalls == 1 and #received == 1
	end), "root listeners must all start without blocking one another")
	assert(not yieldingFinished, "a yielding listener must not be awaited by root publication")
	yieldingConnection:Disconnect()
	failingConnection:Disconnect()
	followingConnection:Disconnect()
	yieldGate:Fire()
	assert(waitUntil(function()
		return yieldingFinished
	end))

	pointerExited:Fire()
	activated:Fire()
	assert(waitUntil(function()
		return #received >= 3
	end))
	for _, event in received do
		assert(event.UIElementId == "ui.window/inventory/open")
		assert(event.WindowId == "inventory")
	end
	assert(received[1].ActionId == "ui.pointer.entered")

	local beforeCatalogPair = #received
	activated:Fire()
	assertSuccess(ui:GetUiElementContext():DeliverToRoot({
		ActionId = UiActionIds.WindowOpened,
		UIElementId = window.UIElementId,
		WindowId = window.WindowId,
	}))
	assert(waitUntil(function()
		return #received == beforeCatalogPair + 2
	end), "one root subscriber must receive user-action and window-lifecycle catalog IDs")
	local catalogPair = {}
	for index = beforeCatalogPair + 1, #received do
		catalogPair[received[index].ActionId] = received[index]
	end
	assert(catalogPair[UiActionIds.ButtonActivated] ~= nil)
	assert(catalogPair[UiActionIds.WindowOpened] ~= nil)
	assert(catalogPair[UiActionIds.ButtonActivated].UIElementId == button.UIElementId)
	assert(catalogPair[UiActionIds.WindowOpened].UIElementId == window.UIElementId)
	assert(catalogPair[UiActionIds.ButtonActivated].WindowId == window.WindowId)
	assert(catalogPair[UiActionIds.WindowOpened].WindowId == window.WindowId)

	local stableIdentityRoot = Instance.new("Frame")
	stableIdentityRoot.Parent = windowRoot
	local stableIdentity = FrameController.new(
		stableIdentityRoot,
		"ui.window/inventory/stable-identity",
		false,
		ui:GetUiElementContext()
	)
	assertSuccess(stableIdentity:Initialize())
	stableIdentity.UIElementId = "ui.window/inventory/mutated-public-field"
	local beforeStableIdentityEvent = #received
	assertSuccess(stableIdentity:EmitAction(UiActionIds.PointerEntered))
	assert(waitUntil(function()
		return #received == beforeStableIdentityEvent + 1
	end))
	assert(received[#received].UIElementId == "ui.window/inventory/stable-identity")
	assertSuccess(stableIdentity:Clear())
	local stableReplacementOwner = {}
	assertSuccess(ui:GetUiElementContext():ClaimSubtree({ {
		UIElementId = "ui.window/inventory/stable-identity",
		Owner = stableReplacementOwner,
	} }))
	assertSuccess(ui:GetUiElementContext():ReleaseSubtree({ {
		UIElementId = "ui.window/inventory/stable-identity",
		Owner = stableReplacementOwner,
	} }))

	local context = ui:GetUiElementContext()
	local unclaimedIdentityResult = context:DeliverToRoot({
		ActionId = "ui.button.activated",
		UIElementId = "ui.window/inventory/unclaimed",
	})
	assert(unclaimedIdentityResult.Kind == "Error" and unclaimedIdentityResult.Error.Code == "InvalidUIElementId")
	local extraFieldResult = context:DeliverToRoot({
		ActionId = "ui.button.activated",
		UIElementId = button.UIElementId,
		Unexpected = true,
	})
	assert(extraFieldResult.Kind == "Error" and extraFieldResult.Error.Code == "PayloadNotSerializable")

	local duplicateRoot = scope:Track(Instance.new("TextButton")) :: TextButton
	local duplicate = ButtonController.new(duplicateRoot, button.UIElementId, false, ui:GetUiElementContext())
	local nestedCount = #window.NestedUiElements
	local duplicateResult = window:AddNestedUiElement(duplicate)
	assert(duplicateResult.Kind == "Error" and duplicateResult.Error.Code == "DuplicateUIElementId")
	assert(#window.NestedUiElements == nestedCount)
	local duplicateInitializeResult = duplicate:Initialize()
	assert(duplicateInitializeResult.Kind == "Error" and duplicateInitializeResult.Error.Code == "DuplicateUIElementId")

	assertSuccess(window:RemoveNestedUiElement(button))
	local receivedBeforeDetachedSignal = #received
	activated:Fire()
	task.wait()
	assert(#received == receivedBeforeDetachedSignal, "a detached concrete handler must not publish")
	assertSuccess(button:Clear())
	assertSuccess(window:AddNestedUiElement(duplicate))
	assert(table.find(window.NestedUiElements, duplicate) ~= nil)
	assertSuccess(window:RemoveNestedUiElement(duplicate))
	assertSuccess(duplicate:Clear())
	local runtimeA = assert(UiElementIdentityRegistry.MakeRuntimeId("list/item", "a/b"))
	local runtimeB = assert(UiElementIdentityRegistry.MakeRuntimeId("list/item/a", "b"))
	assert(runtimeA ~= runtimeB, "byte-length encoding must remain injective")

	local controllerCases = {
		{
			Id = "ui.window/inventory/text-presentation",
			Root = Instance.new("TextLabel"),
			Create = function(root: GuiObject, id: string)
				return TextController.new(root, id, false, ui:GetUiElementContext())
			end,
		},
		{
			Id = "ui.window/inventory/image-presentation",
			Root = Instance.new("ImageLabel"),
			Create = function(root: GuiObject, id: string)
				return ImageController.new(root, id, false, ui:GetUiElementContext())
			end,
		},
		{
			Id = "ui.window/inventory/scrolling-presentation",
			Root = Instance.new("ScrollingFrame"),
			Create = function(root: GuiObject, id: string)
				return ScrollingFrameController.new(root :: ScrollingFrame, id, true, ui:GetUiElementContext())
			end,
		},
	}
	local expectedPointerEnteredCount = 2 + #controllerCases
	local beforePresentationEvents = #received
	for _, case in controllerCases do
		case.Root.Parent = windowRoot
		local controller = case.Create(case.Root, case.Id)
		assert(controller.Root == case.Root and controller.UIElementId == case.Id)
		assertSuccess(controller:Initialize())
		assertSuccess(controller:EmitAction(UiActionIds.PointerEntered))
		assertSuccess(controller:Clear())
	end
	assert(waitUntil(function()
		return #received == beforePresentationEvents + #controllerCases
	end), "every base presentation controller must expose the shared public action contract")
	local presentationIds = {}
	for index = beforePresentationEvents + 1, #received do
		presentationIds[received[index].UIElementId] = true
	end
	for _, case in controllerCases do
		assert(presentationIds[case.Id] == true)
	end

	local textFocused = makeBindable(scope)
	local textFocusLost = makeBindable(scope)
	local textPointerEntered = makeBindable(scope)
	local textPointerExited = makeBindable(scope)
	local textBoxRoot = Instance.new("TextBox")
	textBoxRoot.Text = "secret"
	textBoxRoot.Parent = windowRoot
	local textBox = TextBoxController.new(textBoxRoot, "ui.window/inventory/name", false, ui:GetUiElementContext(), {
		MouseEnter = textPointerEntered.Event,
		MouseLeave = textPointerExited.Event,
		Focused = textFocused.Event,
		FocusLost = textFocusLost.Event,
	})
	local formRoot = Instance.new("Frame")
	formRoot.Parent = windowRoot
	local form = FormController.new(formRoot, "ui.window/inventory/form", ui:GetUiElementContext())
	assertSuccess(form:AddField("name", textBox))
	assertSuccess(window:AddNestedUiElement(form))
	assert(form:GetFieldValue("name") == "secret")
	textFocused:Fire()
	textFocusLost:Fire(false)
	textFocusLost:Fire(true)
	assertSuccess(form:Submit({ Valid = true }))
	assertSuccess(form:Cancel({ Source = "escape" }))
	assert(waitUntil(function()
		local counts = {}
		for _, event in received do
			counts[event.ActionId] = (counts[event.ActionId] or 0) + 1
		end
		return counts[UiActionIds.PointerEntered] == expectedPointerEnteredCount
			and counts["ui.pointer.exited"] == 1
			and counts["ui.button.activated"] == 2
			and counts["ui.textbox.focused"] == 1
			and counts["ui.textbox.unfocused"] == 2
			and counts["ui.textbox.confirmed"] == 1
			and counts["ui.form.submitted"] == 1
			and counts["ui.form.cancelled"] == 1
	end), "representative semantic actions must publish from concrete Roblox signals")
	local submittedEvent: any = nil
	for _, event in received do
		if event.ActionId == "ui.form.submitted" then
			submittedEvent = event
		end
		if string.sub(event.ActionId, 1, 11) == "ui.textbox." then
			assert(event.Payload == nil or event.Payload.Text == nil)
		end
	end
	assert(submittedEvent ~= nil)
	assert(submittedEvent.Payload.Valid == true and submittedEvent.Payload.Text == nil)

	assertSuccess(form:RemoveNestedUiElement(textBox))
	assert(form:GetFieldValue("name") == nil, "detaching a field must release its form lookup")
	assertSuccess(textBox:Clear())
	local replacementTextBoxRoot = Instance.new("TextBox")
	replacementTextBoxRoot.Text = "replacement"
	replacementTextBoxRoot.Parent = windowRoot
	local replacementTextBox = TextBoxController.new(
		replacementTextBoxRoot,
		"ui.window/inventory/name",
		false,
		ui:GetUiElementContext()
	)
	assertSuccess(form:AddField("name", replacementTextBox))
	assert(form:GetFieldValue("name") == "replacement", "a detached field name must be reusable")

	local cycleRootA = scope:Track(Instance.new("Frame")) :: Frame
	local cycleRootB = scope:Track(Instance.new("Frame")) :: Frame
	local cycleA = FrameController.new(cycleRootA, "ui.cycle/a", false, ui:GetUiElementContext())
	local cycleB = FrameController.new(cycleRootB, "ui.cycle/b", false, ui:GetUiElementContext())
	assertSuccess(cycleA:AddNestedUiElement(cycleB))
	local cycleResult = cycleB:AddNestedUiElement(cycleA)
	assert(cycleResult.Kind == "Error" and cycleResult.Error.Code == "InvalidUIElementId")
	assert(#cycleA.NestedUiElements == 1 and #cycleB.NestedUiElements == 0)
	assertSuccess(cycleA:Initialize())
	assertSuccess(cycleA:Clear())

	assertSuccess(window:Clear())
	assertSuccess(window:Clear())
	local replacementOwner = {}
	assertSuccess(context:ClaimSubtree({ {
		UIElementId = "ui.window/inventory/name",
		Owner = replacementOwner,
	} }))
	assertSuccess(context:ReleaseSubtree({ {
		UIElementId = "ui.window/inventory/name",
		Owner = replacementOwner,
	} }))

	ui:Destroy()

	local invalidCatalogUi = UiSystem.new({
		PlayersModule = playersModule,
		TemplateWindowDefinitions = {},
		DerivedActionEntries = {
			{ Name = "InvalidTrailingDot", Id = "game.invalid." },
		},
	})
	local invalidCatalogResult = invalidCatalogUi:Initialize()
	assert(invalidCatalogResult.Kind == "Error" and invalidCatalogResult.Error.Code == "ActionCatalogMalformed")
	invalidCatalogUi:Destroy()

	local duplicateCatalogUi = UiSystem.new({
		PlayersModule = playersModule,
		TemplateWindowDefinitions = {},
		DerivedActionEntries = {
			{ Name = "GameOpened", Id = "game.inventory.opened" },
			{ Name = "GameOpenedAgain", Id = "game.inventory.opened" },
		},
	})
	local duplicateCatalogResult = duplicateCatalogUi:Initialize()
	assert(duplicateCatalogResult.Kind == "Error" and duplicateCatalogResult.Error.Code == "ActionCatalogMalformed")
	duplicateCatalogUi:Destroy()

	local derivedUi = UiSystem.new({
		PlayersModule = playersModule,
		TemplateWindowDefinitions = {},
		DerivedActionEntries = {
			{ Name = "GameOpened", Id = "game.inventory.opened" },
		},
	})
	scope:Defer(function()
		derivedUi:Destroy()
	end)
	assertSuccess(derivedUi:Initialize())
	local derivedEvent: any = nil
	local derivedConnection = derivedUi.Events:Once(function(event)
		derivedEvent = event
	end)
	scope:Defer(function()
		derivedConnection:Disconnect()
	end)
	local derivedRoot = scope:Track(Instance.new("Frame")) :: Frame
	local derivedController = FrameController.new(derivedRoot, "ui.project/presenter", false, derivedUi:GetUiElementContext())
	assertSuccess(derivedController:Initialize())
	assertSuccess(derivedController:EmitAction("game.inventory.opened", { Source = "project" }))
	assert(waitUntil(function()
		return derivedEvent ~= nil
	end))
	assert(derivedEvent.ActionId == "game.inventory.opened")
	assertSuccess(derivedController:Clear())
end

local function TS_TEST_015_ClientBootstrapComposition(scope: TestHarness.Scope)
	local successCalls = 0
	local successCommand = UiInitializationCommand.new({
		Initialize = function()
			successCalls += 1
			return { Kind = "Success" }
		end,
	})
	assert(successCommand.Id == "UI")
	assert(table.find(successCommand.DependsOn, "StartupContentPreload") ~= nil)
	assert(table.find(successCommand.DependsOn, "Pooling") ~= nil)
	assert(table.find(successCommand.DependsOn, "Players") ~= nil)
	successCommand:Initialize({})
	assert(successCalls == 1)

	local function assertDerivedActionFailure(failingUi: any)
		scope:Defer(function()
			failingUi:Destroy()
		end)
		local laterCommandCalls = 0
		local initializationErrors = {}
		local runner = InitializationRunner.new({
			{
				Id = "StartupContentPreload",
				DependsOn = {},
				Initialize = function() end,
			},
			{
				Id = "Pooling",
				DependsOn = {},
				Initialize = function() end,
			},
			{
				Id = "Players",
				DependsOn = {},
				Initialize = function() end,
			},
			UiInitializationCommand.new(failingUi),
			{
				Id = "LaterClientCommand",
				DependsOn = { "UI" },
				Initialize = function()
					laterCommandCalls += 1
				end,
			},
		}, {
			Logger = {
				Info = function() end,
				Error = function(_self: any, eventName: string, fields: any)
					table.insert(initializationErrors, {
						EventName = eventName,
						Fields = fields,
					})
				end,
			},
			WatchdogSeconds = 5,
		})
		local runnerResult = runner:Initialize({
			Side = "Client",
			Services = { UI = failingUi },
		})
		assert(not runnerResult.Ok)
		assert(runnerResult.CommandId == "UI", "the runner must attribute derived action failure to command UI")
		assert(string.find(runnerResult.Error, "UiInitializationFailed:ActionCatalogMalformed", 1, true) ~= nil)
		assert(laterCommandCalls == 0, "a failed UI command must suppress later client commands")
		assert(#initializationErrors == 1)
		assert(initializationErrors[1].EventName == "command_failed")
		assert(initializationErrors[1].Fields.CommandId == "UI")

		-- Bootstrap.client.luau consumes the runner result through this exact attribute branch.
		-- Use an isolated Instance so the deterministic server suite never mutates live client flags.
		local bootstrapState = scope:Track(Instance.new("Folder")) :: Folder
		local bootstrapOk, bootstrapError = pcall(function()
			if not runnerResult.Ok then
				bootstrapState:SetAttribute("ClientInitializationFailed", true)
				error(`[ClientBootstrap] command '{runnerResult.CommandId}' failed:\n{runnerResult.Error}`)
			end
			bootstrapState:SetAttribute("ClientInitialized", true)
		end)
		assert(not bootstrapOk)
		assert(string.find(tostring(bootstrapError), "command 'UI' failed", 1, true) ~= nil)
		assert(bootstrapState:GetAttribute("ClientInitializationFailed") == true)
		assert(bootstrapState:GetAttribute("ClientInitialized") == nil)
		assert(failingUi.Events == nil)
		local hudHostOk = pcall(function()
			failingUi:GetHudHost()
		end)
		local toastHostOk = pcall(function()
			failingUi:GetToastHost()
		end)
		local contextOk = pcall(function()
			failingUi:GetUiElementContext()
		end)
		assert(not hudHostOk and not toastHostOk and not contextOk, "failed UI initialization must expose no usable partial service")
	end

	local function makeDerivedActionRoot(sourceClassName: string): (Folder, Instance)
		local root = scope:Track(Instance.new("Folder")) :: Folder
		local project = Instance.new("Folder")
		project.Name = "Project"
		project.Parent = root
		local client = Instance.new("Folder")
		client.Name = "Client"
		client.Parent = project
		local ui = Instance.new("Folder")
		ui.Name = "UI"
		ui.Parent = client
		local source = Instance.new(sourceClassName)
		source.Name = "DerivedUiActionIds"
		source.Parent = ui
		return root, source
	end

	local wrongClassRoot = makeDerivedActionRoot("Folder")
	local wrongClassPlayers = makePlayersModule(scope)
	assertDerivedActionFailure(UiSystem.new({
		PlayersModule = wrongClassPlayers,
		TemplateWindowDefinitions = {},
		DerivedActionRoot = wrongClassRoot,
	}))

	local throwingRoot, throwingSource = makeDerivedActionRoot("ModuleScript")
	local throwingPlayers = makePlayersModule(scope)
	local requireCalls = 0
	assertDerivedActionFailure(UiSystem.new({
		PlayersModule = throwingPlayers,
		TemplateWindowDefinitions = {},
		DerivedActionRoot = throwingRoot,
		RequireModule = function(source: ModuleScript)
			requireCalls += 1
			assert(source == throwingSource)
			error("ExpectedDerivedUiActionRequireFailure")
		end,
	}))
	assert(requireCalls == 1, "the throwing derived ModuleScript seam must execute inside UI initialization")
end

local function makeWindowDefinition(windowId: string, lifecycle: string, counters: any)
	local definition: any = {
		WindowId = windowId,
		AssetId = 1001,
		CreateView = function(root: GuiObject, context: any)
			counters.Constructed += 1
			assert(root.Parent == nil, "window construction must remain off-tree")
			return BaseWindowView.new(root, windowId, `ui.window/{windowId}`, context.Elements)
		end,
		TryCastView = function(view: any)
			return if view.WindowId == windowId then view else nil
		end,
		InitializeView = function(view: any, viewModel: any)
			counters.Initialized += 1
			assert(view.Root.Parent == nil, "window Initialize must remain off-tree")
			assert(viewModel == nil or typeof(viewModel) == "table")
			return view:Initialize(viewModel)
		end,
		LifecyclePolicy = lifecycle,
		VisibilityPolicy = "KeepBelow",
		BackgroundPolicy = "None",
		Preload = false,
	}
	if lifecycle == "Pool" then
		definition.PoolOptions = { MaxActive = 1, MaxRetained = 1 }
	end
	return definition
end

local function TS_TEST_014_DataOnlyAuthoringTemplate(scope: TestHarness.Scope)
	local authoredRoot = scope:Track(Instance.new("Frame")) :: Frame
	authoredRoot.Name = "WindowTemplate"
	authoredRoot.BackgroundTransparency = 1
	authoredRoot.Size = UDim2.fromScale(1, 1)

	local background = Instance.new("TextButton")
	background.Name = "Background"
	background.Text = ""
	background.AutoButtonColor = false
	background.BackgroundTransparency = 1
	background.Size = UDim2.fromScale(1, 1)
	background.Parent = authoredRoot

	local content = Instance.new("Frame")
	content.Name = "Content"
	content.BackgroundTransparency = 1
	content.Size = UDim2.fromScale(1, 1)
	content.Parent = authoredRoot

	assert(content.Parent == authoredRoot and background.Parent == authoredRoot)
	assert(background:IsA("GuiButton"), "optional Background slot must be a direct GuiButton")
	for _, descendant in authoredRoot:GetDescendants() do
		assert(not descendant:IsA("LuaSourceContainer"), "authoring template must remain data-only")
	end

	local preloadCalls = 0
	local loader = WindowAssetLoader.new({
		AssetBackend = {
			LoadAssetAsync = function(_self: any, assetId: number)
				assert(assetId == 1001)
				return authoredRoot:Clone()
			end,
		},
		ContentPreloader = {
			Preload = function(_self: any, targets: { any }, options: any)
				preloadCalls += 1
				assert(#targets == 1 and targets[1]:IsA("Frame"))
				assert(options.FailurePolicy == "Fail" and options.RequestId == nil)
				return { Failed = 0 }
			end,
		},
		Clock = function()
			return 0
		end,
		Spawn = function(callback: () -> ())
			callback()
		end,
		Delay = function(_seconds: number, callback: () -> ())
			callback()
		end,
	})
	scope:Defer(function()
		loader:Destroy()
	end)
	local canonical, loadError = loader:GetTemplate({ WindowId = "authored", AssetId = 1001 }, 3)
	assert(canonical ~= nil and loadError == nil and preloadCalls == 1)
	assert((canonical :: GuiObject):FindFirstChild("Content") ~= nil)
	assert((canonical :: GuiObject):FindFirstChild("Background") ~= nil)
end

local function TS_TEST_016_LocalWindowAssetFixture(scope: TestHarness.Scope)
	local fixtureRoot = ReplicatedStorage.Client.UI.TestFixtures.WindowAssetFixture
	assert(fixtureRoot:IsA("GuiObject"), "checked-in fixture must map to one GuiObject root")
	assert(fixtureRoot:FindFirstChild("Content") ~= nil and fixtureRoot:FindFirstChild("Background") ~= nil)
	for _, descendant in fixtureRoot:GetDescendants() do
		assert(not descendant:IsA("LuaSourceContainer"), "checked-in fixture must remain recursively data-only")
	end

	local compiled, compileError = WindowConfigCompiler.compile({ WindowAssetFixtureDefinition }, {})
	assert(compiled ~= nil and compileError == nil)
	assert(WindowAssetFixtureDefinition.WindowId == "ui.test.window-asset-fixture")
	assert(WindowAssetFixtureDefinition.AssetId == 1001)
	assert(compiled.ByWindowId[WindowAssetFixtureDefinition.WindowId] == WindowAssetFixtureDefinition)
	assert(compiled.Definitions[1] == WindowAssetFixtureDefinition and table.isfrozen(WindowAssetFixtureDefinition))

	local loads = 0
	local preloads = 0
	local loader = WindowAssetLoader.new({
		AssetBackend = {
			LoadAssetAsync = function(_self: any, assetId: number)
				assert(assetId == 1001)
				loads += 1
				local wrapper = Instance.new("Folder")
				wrapper.Name = "FixtureCarrier"
				local clone = fixtureRoot:Clone()
				clone.Parent = wrapper
				assert(#wrapper:GetChildren() == 1 and wrapper:GetChildren()[1] == clone)
				return wrapper
			end,
		},
		ContentPreloader = {
			Preload = function(_self: any, targets: { Instance }, options: any)
				preloads += 1
				assert(#targets == 1 and targets[1]:IsA("GuiObject"))
				assert(options.FailurePolicy == "Fail" and options.RequestId == nil)
				return { Failed = 0 }
			end,
		},
		Clock = function() return 0 end,
		Spawn = function(callback: () -> ()) callback() end,
		Delay = function(_seconds: number, callback: () -> ()) callback() end,
	})
	scope:Defer(function() loader:Destroy() end)
	local template, templateError = loader:GetTemplate(WindowAssetFixtureDefinition, 3)
	assert(template ~= nil and templateError == nil)
	local cached, cachedError = loader:GetTemplate(WindowAssetFixtureDefinition, 3)
	assert(cached == template and cachedError == nil and loads == 1 and preloads == 1)
	local first = (template :: GuiObject):Clone()
	local second = (template :: GuiObject):Clone()
	scope:Track(first)
	scope:Track(second)
	assert(first ~= second and first.Parent == nil and second.Parent == nil)
	assert(first:FindFirstChild("Content") ~= nil and second:FindFirstChild("Content") ~= nil)

	local rejectingLoader = WindowAssetLoader.new({
		AssetBackend = {
			LoadAssetAsync = function(_self: any, assetId: number)
				assert(assetId == 1001)
				local wrapper = Instance.new("Folder")
				local root = fixtureRoot:Clone()
				local executable = Instance.new("ModuleScript")
				executable.Name = "ForbiddenFixtureExecutable"
				executable.Parent = root
				root.Parent = wrapper
				return wrapper
			end,
		},
		ContentPreloader = {
			Preload = function()
				error("preload must not run for executable fixture")
			end,
		},
		Clock = function() return 0 end,
		Spawn = function(callback: () -> ()) callback() end,
		Delay = function(_seconds: number, callback: () -> ()) callback() end,
	})
	scope:Defer(function() rejectingLoader:Destroy() end)
	local rejected, rejectedError = rejectingLoader:GetTemplate(WindowAssetFixtureDefinition, 3)
	assert(rejected == nil and rejectedError.Code == "ForbiddenExecutableDescendant")

	local physicalOwner = scope:Track(Instance.new("Folder")) :: Folder
	local physicalOriginal = fixtureRoot:Clone() :: GuiObject
	physicalOriginal:SetAttribute("DesignerMarker", "studio-owned")
	physicalOriginal.Parent = physicalOwner
	local physicalLookups = 0
	local physicalPreloads = 0
	local physicalDefinition = table.clone(WindowAssetFixtureDefinition) :: any
	physicalDefinition.WindowId = "ui.test.physical-window"
	physicalDefinition.AssetId = nil
	physicalDefinition.AssetKey = "ui.test.physical-window"
	local physicalConfig, physicalConfigError = WindowConfigCompiler.compile({ physicalDefinition }, {})
	assert(physicalConfig ~= nil and physicalConfigError == nil)
	local physicalLoader = WindowAssetLoader.new({
		AssetRegistry = {
			RequireByKey = function(_self: any, key: string, expectedClass: string)
				physicalLookups += 1
				assert(key == "ui.test.physical-window" and expectedClass == "GuiObject")
				return physicalOriginal
			end,
		},
		ContentPreloader = {
			Preload = function(_self: any, targets: { Instance }, options: any)
				physicalPreloads += 1
				assert(#targets == 1 and targets[1] ~= physicalOriginal and options.FailurePolicy == "Fail")
				return { Failed = 0 }
			end,
		},
		Clock = function() return 0 end,
		Spawn = function(callback: () -> ()) callback() end,
		Delay = function(_seconds: number, callback: () -> ()) callback() end,
	})
	scope:Defer(function() physicalLoader:Destroy() end)
	local physicalTemplate, physicalError = physicalLoader:GetTemplate(physicalDefinition, 3)
	assert(physicalTemplate ~= nil and physicalError == nil and physicalTemplate ~= physicalOriginal)
	local physicalCached, physicalCachedError = physicalLoader:GetTemplate(physicalDefinition, 3)
	assert(physicalCached == physicalTemplate and physicalCachedError == nil)
	assert(physicalLookups == 1 and physicalPreloads == 1,
		"a physical source must resolve, clone, preload, and cache exactly once")
	assert(physicalOriginal.Parent == physicalOwner
		and physicalOriginal:GetAttribute("DesignerMarker") == "studio-owned",
		"physical source lookup must not move, destroy, or mutate the catalog original")

	local uncloneableOriginal = fixtureRoot:Clone() :: GuiObject
	uncloneableOriginal.Archivable = false
	uncloneableOriginal.Parent = physicalOwner
	local uncloneableLoader = WindowAssetLoader.new({
		AssetRegistry = {
			RequireByKey = function() return uncloneableOriginal end,
		},
		ContentPreloader = { Preload = function() error("uncloneable source must not preload") end },
		Clock = function() return 0 end,
		Spawn = function(callback: () -> ()) callback() end,
		Delay = function(_seconds: number, callback: () -> ()) callback() end,
	})
	scope:Defer(function() uncloneableLoader:Destroy() end)
	local uncloneableTemplate, uncloneableError = uncloneableLoader:GetTemplate(physicalDefinition, 3)
	assert(uncloneableTemplate == nil and uncloneableError.Code == "PrefabMalformed",
		"an uncloneable physical source must fail with the stable prefab classification")

	local validBackend = { LoadAssetAsync = function() return fixtureRoot:Clone() end }
	local validRegistry = { RequireByKey = function() return physicalOriginal end }
	local preloader = { Preload = function() return { Failed = 0 } end }
	for _, malformedDependencies in {
		{ AssetBackend = {}, AssetRegistry = validRegistry },
		{ AssetBackend = validBackend, AssetRegistry = {} },
	} do
		local constructed = pcall(function()
			WindowAssetLoader.new({
				AssetBackend = malformedDependencies.AssetBackend,
				AssetRegistry = malformedDependencies.AssetRegistry,
				ContentPreloader = preloader,
			})
		end)
		assert(not constructed, "loader construction must reject every malformed provided source dependency")
	end

	local function initializeMixed(assetBackend: any?, assetRegistry: any?): any
		local players = makePlayersModule(scope)
		local pooling = PoolModule.new()
		pooling:Initialize()
		scope:Defer(function() pooling:Destroy() end)
		local ui = UiSystem.new({
			PlayersModule = players,
			TemplateWindowDefinitions = { WindowAssetFixtureDefinition, physicalDefinition },
			Pooling = pooling,
			ContentPreloader = preloader,
			AssetBackend = assetBackend,
			AssetRegistry = assetRegistry,
		})
		scope:Defer(function() ui:Destroy() end)
		return ui:Initialize()
	end

	local missingRegistryResult = initializeMixed(validBackend, nil)
	assert(missingRegistryResult.Kind == "Error"
		and missingRegistryResult.Error.Code == "WindowDependenciesMissing",
		"a physical definition must require the injected AssetRegistry even when a cloud backend exists")
	local missingBackendResult = initializeMixed(nil, validRegistry)
	assert(missingBackendResult.Kind == "Error"
		and missingBackendResult.Error.Code == "WindowDependenciesMissing",
		"a cloud definition must require its backend even when the physical registry exists")
	local malformedBackendResult = initializeMixed({}, validRegistry)
	assert(malformedBackendResult.Kind == "Error"
		and malformedBackendResult.Error.Code == "WindowDependenciesMissing",
		"a valid registry must not mask a malformed cloud backend in a mixed-source config")
	local malformedRegistryResult = initializeMixed(validBackend, {})
	assert(malformedRegistryResult.Kind == "Error"
		and malformedRegistryResult.Error.Code == "WindowDependenciesMissing",
		"a valid cloud backend must not mask a malformed registry in a mixed-source config")
	local validMixedResult = initializeMixed(validBackend, validRegistry)
	assert(validMixedResult.Kind == "Success", "mixed-source config must initialize when both source ports are valid")
end

local function TS_TEST_002_003_011_FirstWindowRuntime(scope: TestHarness.Scope)
	local counters = { Loaded = 0, Preloaded = 0, Constructed = 0, Initialized = 0 }
	local destroyDefinition = makeWindowDefinition("inventory", "Destroy", counters)
	local poolDefinition = makeWindowDefinition("pooled", "Pool", counters)
	local compiled, compileError = WindowConfigCompiler.compile({ destroyDefinition, poolDefinition }, {})
	assert(compiled ~= nil and compileError == nil)
	assert(compiled.ByWindowId.inventory == destroyDefinition)
	assert(table.isfrozen(compiled) and table.isfrozen(compiled.Definitions))
	assert(table.isfrozen(destroyDefinition) and table.isfrozen(poolDefinition.PoolOptions))

	local duplicateDefinition = makeWindowDefinition("inventory", "Destroy", {
		Constructed = 0,
		Initialized = 0,
	})
	local duplicateConfig, duplicateError = WindowConfigCompiler.compile({ destroyDefinition }, { duplicateDefinition })
	assert(duplicateConfig == nil and duplicateError.Code == "DuplicateWindowId")

	local malformedDefinition = table.clone(destroyDefinition)
	malformedDefinition.AssetId = 0
	local malformedConfig, malformedError = WindowConfigCompiler.compile({ malformedDefinition }, {})
	assert(malformedConfig == nil and malformedError.Code == "WindowConfigMalformed")

	local bothSources = table.clone(destroyDefinition)
	bothSources.AssetKey = "ui.inventory"
	local bothConfig, bothError = WindowConfigCompiler.compile({ bothSources }, {})
	assert(bothConfig == nil and bothError.Code == "WindowConfigMalformed",
		"a window definition must not combine cloud and physical sources")

	local missingSource = table.clone(destroyDefinition)
	missingSource.AssetId = nil
	local missingConfig, missingError = WindowConfigCompiler.compile({ missingSource }, {})
	assert(missingConfig == nil and missingError.Code == "WindowConfigMalformed",
		"a window definition must declare exactly one source")

	local malformedKey = table.clone(destroyDefinition)
	malformedKey.AssetId = nil
	malformedKey.AssetKey = "bad/key"
	local malformedKeyConfig, malformedKeyError = WindowConfigCompiler.compile({ malformedKey }, {})
	assert(malformedKeyConfig == nil and malformedKeyError.Code == "WindowConfigMalformed",
		"physical window keys must obey the AssetKey contract")

	local playersModule, playerGui = makePlayersModule(scope)
	local pooling = PoolModule.new()
	pooling:Initialize()
	local ui = UiSystem.new({
		PlayersModule = playersModule,
		TemplateWindowDefinitions = { destroyDefinition, poolDefinition },
		Pooling = pooling,
		AssetBackend = {
			LoadAssetAsync = function(_self: any, _assetId: number)
				counters.Loaded += 1
				local wrapper = Instance.new("Folder")
				local root = Instance.new("Frame")
				root.Name = "WindowRoot"
				root.Parent = wrapper
				return wrapper
			end,
		},
		ContentPreloader = {
			Preload = function(_self: any, targets: { any }, options: any)
				counters.Preloaded += 1
				assert(#targets == 1 and options.FailurePolicy == "Fail" and options.RequestId == nil)
				return { Failed = 0 }
			end,
		},
	})
	scope:Defer(function()
		ui:Destroy()
		pooling:Destroy()
	end)
	assertSuccess(ui:Initialize())
	local windowHost = (playerGui:FindFirstChild("UiRoot") :: ScreenGui):FindFirstChild("WindowHost") :: Frame

	local opened = ui:AddWindowAsync("inventory", { Value = 1 })
	assertSuccess(opened)
	local firstHandle = opened.Value
	assert(firstHandle.WindowId == "inventory" and firstHandle:IsValid() and firstHandle:IsActiveWindow())
	assert(firstHandle:GetView().Kind == "Success")
	assert(#windowHost:GetChildren() == 1)
	local duplicateOpen = ui:AddWindowAsync("inventory", { Value = 2 })
	assert(duplicateOpen.Kind == "Error" and duplicateOpen.Error.Code == "DuplicateWindowId")
	local firstView = firstHandle:GetView().Value
	assertSuccess(firstView:CloseWindowAsync())
	assert(not firstHandle:IsValid() and firstHandle:GetView().Kind == "Error")
	assert(#windowHost:GetChildren() == 0)

	local reopened = ui:AddWindowTypedAsync(destroyDefinition, { Value = 3 })
	assertSuccess(reopened)
	assert(counters.Loaded == 1 and counters.Preloaded == 1, "successful template must be cached for this UiSystem")
	assert(counters.Constructed == 2, "destroy lifecycle must clone and construct each issue")
	assertSuccess(reopened.Value:GetView().Value:CloseWindowAsync())

	local pooledFirst = ui:AddWindowAsync("pooled", nil)
	assertSuccess(pooledFirst)
	local pooledView = pooledFirst.Value:GetView().Value
	assertSuccess(pooledView:CloseWindowAsync())
	assert(not pooledFirst.Value:IsValid())
	local pooledSecond = ui:AddWindowAsync("pooled", nil)
	assertSuccess(pooledSecond)
	assert(pooledSecond.Value:GetView().Value == pooledView, "pooled window must reuse the view with a fresh generation")
	assertSuccess(pooledSecond.Value:GetView().Value:CloseWindowAsync())
	assert(counters.Loaded == 2 and counters.Preloaded == 2)
	assert(counters.Initialized == 4)
end

local function TS_TEST_003_ReentrantNoOpAndDuplicateAdmission(scope: TestHarness.Scope)
	local counters = { Constructed = 0, Initialized = 0 }
	local definition = makeWindowDefinition("admission", "Destroy", counters)
	local reentrant = {} :: { [string]: any }
	local navigator: any = nil
	definition.CreateView = function(root: GuiObject, context: any)
		counters.Constructed += 1
		local view = BaseWindowView.new(root, definition.WindowId, "ui.window/admission", context.Elements)
		view.Open = function()
			reentrant.ExternalSame = navigator:AddExternal(definition.WindowId, nil)
			reentrant.ActiveSame = view:AddWindowAsync(definition.WindowId, nil)
			reentrant.ReplacementSame = view:CloseWindowAsync(definition.WindowId, nil)
			reentrant.RepeatClose = view:CloseWindowAsync()
			reentrant.Other = navigator:AddExternal("other", nil)
		end
		return view
	end
	local other = makeWindowDefinition("other", "Destroy", { Constructed = 0, Initialized = 0 })
	local config = assert(WindowConfigCompiler.compile({ definition, other }, {}))
	local windowHost = scope:Track(Instance.new("Frame")) :: Frame
	local template = scope:Track(Instance.new("Frame")) :: Frame
	local pooling = PoolModule.new()
	pooling:Initialize()
	local poolOwner = WindowPoolOwner.new(pooling)
	local loads = 0
	navigator = WindowNavigator.new({
		Config = config,
		Loader = {
			GetTemplate = function()
				loads += 1
				return template, nil
			end,
		},
		PoolOwner = poolOwner,
		WindowHost = windowHost,
		Elements = makeIdentityContext(),
		Spawn = function(callback: () -> ())
			callback()
		end,
	})
	scope:Defer(function()
		navigator:Destroy()
		poolOwner:Destroy()
		pooling:Destroy()
	end)

	local opened = navigator:AddExternal(definition.WindowId, nil)
	assertSuccess(opened)
	assert(reentrant.ExternalSame.Kind == "NoOp")
	assert(reentrant.ActiveSame.Kind == "NoOp")
	assert(reentrant.ReplacementSame.Kind == "NoOp")
	assert(reentrant.RepeatClose.Kind == "NoOp")
	assert(reentrant.Other.Kind == "Error" and reentrant.Other.Error.Code == "Busy")
	assert(loads == 1 and counters.Constructed == 1, "reentrant NoOp/Busy requests must not prepare another candidate")

	local duplicate = navigator:AddExternal(definition.WindowId, nil)
	assert(duplicate.Kind == "Error" and duplicate.Error.Code == "DuplicateWindowId")
	assert(loads == 1 and counters.Constructed == 1, "duplicate stack ID must fail before load or construction")
	assertSuccess(opened.Value:GetView().Value:CloseWindowAsync())
end

local function makeNavigatorFixture(scope: TestHarness.Scope, definitions: { any }, options: any?)
	local fixtureOptions = options or {}
	local compiled = assert(WindowConfigCompiler.compile(definitions, {}))
	local windowHost = scope:Track(Instance.new("Frame")) :: Frame
	local template = scope:Track(Instance.new("Frame")) :: Frame
	local pooling = PoolModule.new()
	pooling:Initialize()
	local poolOwner = WindowPoolOwner.new(pooling)
	local navigator = WindowNavigator.new({
		Config = compiled,
		Loader = {
			GetTemplate = function()
				return template, nil
			end,
		},
		PoolOwner = poolOwner,
		WindowHost = windowHost,
		Elements = fixtureOptions.Elements or makeIdentityContext(nil),
		GuiService = fixtureOptions.GuiService,
		Logger = fixtureOptions.Logger,
		Clock = fixtureOptions.Clock,
		Spawn = fixtureOptions.Spawn,
		Delay = fixtureOptions.Delay,
		Wait = fixtureOptions.Wait,
	})
	scope:Defer(function()
		navigator:Destroy()
		poolOwner:Destroy()
		pooling:Destroy()
	end)
	return navigator, windowHost, pooling
end

local function TS_TEST_007_CloseCleanupPartitions(scope: TestHarness.Scope)
	local context = makeIdentityContext()
	local parent = FrameController.new(scope:Track(Instance.new("Frame")) :: Frame, "cleanup/parent", false, context)
	local yieldingChild = FrameController.new(scope:Track(Instance.new("Frame")) :: Frame, "cleanup/yielding", false, context)
	local sibling = FrameController.new(scope:Track(Instance.new("Frame")) :: Frame, "cleanup/sibling", false, context)
	local capturedChildThread: thread? = nil
	local capturedOnClearThread: thread? = nil
	local postYieldMutation = 0
	local siblingClearCalls = 0
	yieldingChild.Clear = function()
		capturedChildThread = coroutine.running()
		coroutine.yield()
		postYieldMutation += 1
		return { Kind = "Success" }
	end
	local siblingClear = sibling.Clear
	sibling.Clear = function(self: any)
		siblingClearCalls += 1
		return siblingClear(self)
	end
	parent.OnClear = function()
		capturedOnClearThread = coroutine.running()
		coroutine.yield()
		postYieldMutation += 1
	end
	assertSuccess(parent:AddNestedUiElement(yieldingChild))
	assertSuccess(parent:AddNestedUiElement(sibling))
	assertSuccess(parent:Initialize())
	local aggregate = parent:Clear()
	assert(aggregate.Kind == "Error" and aggregate.Error.Code == "CleanupFailed")
	assert(siblingClearCalls == 1, "yielding child cleanup must not suppress sibling cleanup")
	assert(capturedChildThread ~= nil and capturedOnClearThread ~= nil)
	assert(not coroutine.resume(capturedChildThread :: thread))
	assert(not coroutine.resume(capturedOnClearThread :: thread))
	assert(postYieldMutation == 0, "closed cleanup continuations must never mutate after Clear")
	assertSuccess(parent:Clear())

	local blockerRoot = scope:Track(Instance.new("Frame")) :: Frame
	local sink = Instance.new("TextButton")
	sink.Parent = blockerRoot
	local reference = Instance.new("ObjectValue")
	reference.Name = "BlockObjectRef"
	reference.Value = sink
	reference.Parent = blockerRoot
	local blockerView = BaseWindowView.new(blockerRoot, "cleanup-blocker", "cleanup/blocker", makeIdentityContext())
	assertSuccess(blockerView:Initialize(nil))
	local manualA = blockerView:AcquireInputBlock()
	local manualB = blockerView:AcquireInputBlock()
	assert((sink :: any).InputSink == Enum.InputSink.All)
	assertSuccess(blockerView:Clear())
	assert((sink :: any).InputSink == Enum.InputSink.None)
	manualA:Release()
	manualB:Release()
	assert((sink :: any).InputSink == Enum.InputSink.None, "late manual handle release must be inert after blocker teardown")

	local function exercise(lifecycle: string)
		local counters = { Constructed = 0, Initialized = 0 }
		local definition = makeWindowDefinition(`cleanup-{string.lower(lifecycle)}`, lifecycle, counters)
		definition.CreateView = function(root: GuiObject, context: any)
			local view = BaseWindowView.new(root, definition.WindowId, `ui.window/{definition.WindowId}`, context.Elements)
			view.Clear = function()
				return { Kind = "Error", Error = { Code = "CleanupFailed" } }
			end
			return view
		end
		local navigator, windowHost, pooling = makeNavigatorFixture(scope, { definition })
		local opened = navigator:AddExternal(definition.WindowId, nil)
		assertSuccess(opened)
		local view = opened.Value:GetView().Value
		local closed = view:CloseWindowAsync()
		assert(closed.Kind == "Error" and closed.Error.Code == "CleanupFailed")
		assert(not opened.Value:IsValid() and #windowHost:GetChildren() == 0)
		if lifecycle == "Pool" then
			local pool = pooling:GetPool(`Ui.Window/{definition.WindowId}`)
			local stats = pool:GetStats()
			assert(stats.Active == 0 and stats.Available == 0, "failed pooled cleanup must destroy the contaminated record")
		end
	end

	exercise("Destroy")
	exercise("Pool")
end

local function TS_TEST_010_ProtectedTryCast(scope: TestHarness.Scope)
	local factoryCounters = { Constructed = 0, Initialized = 0 }
	local factoryFailure = makeWindowDefinition("factory-failure", "Destroy", factoryCounters)
	factoryFailure.CreateView = function()
		error("ExpectedViewFactoryFailure")
	end

	local throwingCounters = { Constructed = 0, Initialized = 0 }
	local throwing = makeWindowDefinition("throwing-cast", "Destroy", throwingCounters)
	throwing.TryCastView = function()
		error("ExpectedTryCastFailure")
	end

	local lateCounters = { Constructed = 0, Initialized = 0 }
	local late = makeWindowDefinition("late-cast", "Destroy", lateCounters)
	local lateCastCalls = 0
	local lateView: any = nil
	late.CreateView = function(root: GuiObject, context: any)
		lateView = BaseWindowView.new(root, late.WindowId, "ui.window/late-cast", context.Elements)
		return lateView
	end
	late.TryCastView = function(view: any)
		lateCastCalls += 1
		if lateCastCalls > 1 then
			error("ExpectedLateTryCastFailure")
		end
		return view
	end

	local initializeCounters = { Constructed = 0, Initialized = 0 }
	local initializeFailure = makeWindowDefinition("initialize-failure", "Pool", initializeCounters)
	initializeFailure.InitializeView = function()
		return { Kind = "Error", Error = { Code = "ViewModelMismatch" } }
	end

	local navigator, windowHost, pooling = makeNavigatorFixture(scope, {
		factoryFailure,
		throwing,
		initializeFailure,
		late,
	})
	local factoryResult = navigator:AddExternal(factoryFailure.WindowId, nil)
	assert(factoryResult.Kind == "Error" and factoryResult.Error.Code == "ViewFactoryFailed")
	local protected, rejected = pcall(function()
		return navigator:AddExternalTyped(throwing, nil)
	end)
	assert(protected and rejected.Kind == "Error" and rejected.Error.Code == "TypedDefinitionMismatch")
	assert(#windowHost:GetChildren() == 0)
	local initializeResult = navigator:AddExternal(initializeFailure.WindowId, nil)
	assert(initializeResult.Kind == "Error" and initializeResult.Error.Code == "ViewModelMismatch")
	local initializePool = pooling:GetPool("Ui.Window/initialize-failure")
	local initializeStats = initializePool:GetStats()
	assert(initializeStats.Active == 0 and initializeStats.Available == 1, "Initialize failure must clean and release its candidate")

	local opened = navigator:AddExternalTyped(late, nil)
	assertSuccess(opened)
	local getProtected, getResult = pcall(function()
		return opened.Value:GetView()
	end)
	assert(getProtected and getResult.Kind == "Error" and getResult.Error.Code == "TypedDefinitionMismatch")
	assertSuccess(lateView:CloseWindowAsync())
	assert(#windowHost:GetChildren() == 0, "cast failure must not strand the operation gate or candidate")
end

local function TS_TEST_011_AssetPreparationPartitions(scope: TestHarness.Scope)
	local definition = { WindowId = "asset-partitions", AssetId = 3003, Preload = false }
	local function makeLoader(backend: any, preloader: any)
		local loader = WindowAssetLoader.new({
			AssetBackend = backend,
			ContentPreloader = preloader,
			Spawn = function(callback: () -> ())
				callback()
			end,
			Delay = function(_seconds: number, callback: () -> ())
				task.defer(callback)
			end,
		})
		scope:Defer(function()
			loader:Destroy()
		end)
		return loader
	end

	local malformedLoader = makeLoader({
		LoadAssetAsync = function()
			return Instance.new("Folder")
		end,
	}, { Preload = function() end })
	local malformed, malformedError = malformedLoader:GetTemplate(definition, os.clock() + 1)
	assert(malformed == nil and malformedError.Code == "PrefabMalformed")

	local executableLoader = makeLoader({
		LoadAssetAsync = function()
			local root = Instance.new("Frame")
			local source = Instance.new("ModuleScript")
			source.Parent = root
			return root
		end,
	}, { Preload = function() end })
	local executable, executableError = executableLoader:GetTemplate(definition, os.clock() + 1)
	assert(executable == nil and executableError.Code == "ForbiddenExecutableDescendant")

	local preloadLoader = makeLoader({
		LoadAssetAsync = function()
			return Instance.new("Frame")
		end,
	}, {
		Preload = function()
			error("expected preload rejection")
		end,
	})
	local preload, preloadError = preloadLoader:GetTemplate(definition, os.clock() + 1)
	assert(preload == nil and preloadError.Code == "ContentPreloadFailed")

	local loadCalls = 0
	local retryLoader = makeLoader({
		LoadAssetAsync = function()
			loadCalls += 1
			if loadCalls == 1 then
				error("expected first load failure")
			end
			return Instance.new("Frame")
		end,
	}, { Preload = function() end })
	local first, firstError = retryLoader:GetTemplate(definition, os.clock() + 1)
	assert(first == nil and firstError.Code == "AssetLoadFailed")
	local retried, retryError = retryLoader:GetTemplate(definition, os.clock() + 1)
	assert(retried ~= nil and retryError == nil and loadCalls == 2)

	local pendingSpawn: (() -> ())? = nil
	local deferSpawn = true
	local spawnCalls = 0
	local physicalLoads = 0
	local eagerDefinition = { WindowId = "eager-timeout", AssetId = 3004, Preload = true }
	local eagerLoader = WindowAssetLoader.new({
		AssetBackend = {
			LoadAssetAsync = function()
				physicalLoads += 1
				return Instance.new("Frame")
			end,
		},
		ContentPreloader = { Preload = function() end },
		Clock = function()
			return 0
		end,
		Spawn = function(callback: () -> ())
			spawnCalls += 1
			if deferSpawn then
				pendingSpawn = callback
			else
				callback()
			end
		end,
		Delay = function(_seconds: number, callback: () -> ())
			task.defer(callback)
		end,
	})
	scope:Defer(function()
		eagerLoader:Destroy()
	end)
	eagerLoader:BeginEager({ eagerDefinition }, 3)
	local unsettled, unsettledError = eagerLoader:GetTemplate(eagerDefinition, 3)
	assert(unsettled == nil and unsettledError.Code == "Timeout" and physicalLoads == 0 and spawnCalls == 1)
	assert(pendingSpawn ~= nil, "eager timeout must retain the single physical attempt until it settles")
	local settlePending = pendingSpawn :: () -> ()
	settlePending()
	deferSpawn = false
	local afterSettle, afterSettleError = eagerLoader:GetTemplate(eagerDefinition, 3)
	assert(afterSettle ~= nil and afterSettleError == nil and physicalLoads == 2 and spawnCalls == 2, "settled abandoned attempt must permit one retry")

	local eagerFailureCalls = 0
	local eagerFailureDefinition = { WindowId = "eager-failure", AssetId = 3005, Preload = true }
	local eagerFailureLoader = makeLoader({
		LoadAssetAsync = function()
			eagerFailureCalls += 1
			if eagerFailureCalls == 1 then
				error("expected eager load failure")
			end
			return Instance.new("Frame")
		end,
	}, { Preload = function() end })
	eagerFailureLoader:BeginEager({ eagerFailureDefinition }, os.clock() + 1)
	local eagerRetried, eagerRetryError = eagerFailureLoader:GetTemplate(eagerFailureDefinition, os.clock() + 1)
	assert(eagerRetried ~= nil and eagerRetryError == nil and eagerFailureCalls == 2)
end

local function TS_TEST_006_011_BackgroundAndBlockedActions(scope: TestHarness.Scope)
	local function definitionFor(windowId: string, policy: string, validBackground: boolean)
		local counters = { Constructed = 0, Initialized = 0 }
		local definition = makeWindowDefinition(windowId, "Destroy", counters)
		definition.BackgroundPolicy = policy
		definition.CreateView = function(root: GuiObject, context: any)
			if validBackground then
				local background = Instance.new("TextButton")
				background.Name = "Background"
				background.Position = UDim2.fromScale(0, 0)
				background.Size = UDim2.fromScale(1, 1)
				background.ZIndex = 1
				background.Parent = root
				local blockReference = Instance.new("ObjectValue")
				blockReference.Name = "BlockObjectRef"
				blockReference.Value = background
				blockReference.Parent = root
				local content = Instance.new("Frame")
				content.ZIndex = 2
				content.Parent = root
			end
			return BaseWindowView.new(root, windowId, `ui.window/{windowId}`, context.Elements)
		end
		return definition
	end

	local invalid = definitionFor("invalid-background", "Absorb", false)
	local absorb = definitionFor("absorb-background", "Absorb", true)
	local close = definitionFor("close-background", "CloseOnActivate", true)
	local navigator, windowHost = makeNavigatorFixture(scope, { invalid, absorb, close })
	local invalidResult = navigator:AddExternal(invalid.WindowId, nil)
	assert(invalidResult.Kind == "Error" and invalidResult.Error.Code == "InvalidBackground")
	assert(#windowHost:GetChildren() == 0)

	local absorbResult = navigator:AddExternal(absorb.WindowId, nil)
	assertSuccess(absorbResult)
	local absorbView = absorbResult.Value:GetView().Value
	local block = absorbView:AcquireInputBlock()
	local blockedAction = absorbView:EmitAction(UiActionIds.ButtonActivated)
	assert(blockedAction.Kind == "Error" and blockedAction.Error.Code == "NotActiveWindow")
	block:Release()
	assertSuccess(absorbView:EmitAction(UiActionIds.ButtonActivated))
	assertSuccess(absorbView:CloseWindowAsync())

	local closeResult = navigator:AddExternal(close.WindowId, nil)
	assertSuccess(closeResult)
	assertSuccess(closeResult.Value:GetView().Value:CloseWindowAsync())
end

local function TS_TEST_006_InputBlocking(scope: TestHarness.Scope)
	local root = scope:Track(Instance.new("Frame")) :: Frame
	local sink = Instance.new("TextButton")
	sink.Name = "InputSink"
	sink.Parent = root
	local reference = Instance.new("ObjectValue")
	reference.Name = "BlockObjectRef"
	reference.Value = sink
	reference.Parent = root

	local changes = {}
	local blocker = WindowInputBlocker.new(root, function(blocked: boolean)
		table.insert(changes, blocked)
	end)
	assertSuccess(blocker:Initialize())
	local first = blocker:Acquire()
	local second = blocker:Acquire()
	assert(blocker:IsEffective())
	assert((sink :: any).InputSink == Enum.InputSink.All)
	first:Release()
	assert(blocker:IsEffective() and (sink :: any).InputSink == Enum.InputSink.All)
	second:Release()
	assert(not blocker:IsEffective() and (sink :: any).InputSink == Enum.InputSink.None)
	second:Release()

	local outstanding = blocker:Acquire()
	assert(blocker:IsEffective())
	assertSuccess(blocker:Clear())
	assert(not blocker:IsEffective() and (sink :: any).InputSink == Enum.InputSink.None)
	outstanding:Release()
	assert(#changes >= 4)

	local missingRoot = scope:Track(Instance.new("Frame")) :: Frame
	local missing = WindowInputBlocker.new(missingRoot, nil)
	assertSuccess(missing:Initialize())
	local inert = missing:Acquire()
	assert(not missing:IsEffective())
	inert:Release()
	assertSuccess(missing:Clear())
end

makeIdentityContext = function(onDeliver: ((any) -> ())?)
	local owners = {}
	return table.freeze({
		ClaimSubtree = function(_self: any, claims: { any })
			for _, claim in claims do
				if owners[claim.UIElementId] ~= nil then
					return { Kind = "Error", Error = { Code = "DuplicateUIElementId" } }
				end
			end
			for _, claim in claims do
				owners[claim.UIElementId] = claim.Owner
			end
			return { Kind = "Success" }
		end,
		ReleaseSubtree = function(_self: any, claims: { any })
			for _, claim in claims do
				if owners[claim.UIElementId] == claim.Owner then
					owners[claim.UIElementId] = nil
				end
			end
			return { Kind = "Success" }
		end,
		DeliverToRoot = function(_self: any, event: any)
			if onDeliver ~= nil then
				onDeliver(event)
			end
			return { Kind = "Success" }
		end,
	})
end

local function TS_TEST_009_010_TransitionAndTypedFailures(scope: TestHarness.Scope)
	local function makeScenario(windowId: string, lifecycle: string, behavior: string)
		local scheduler = makeDeterministicScheduler()
		local playersModule, playerGui = makePlayersModule(scope)
		local pooling = PoolModule.new()
		pooling:Initialize()
		local capturedRoot: GuiObject? = nil
		local transitionBlocked = false
		local lateHookMutation = 0
		local definition: any = {
			WindowId = windowId,
			AssetId = 2002,
			CreateView = function(root: GuiObject, construction: any)
				capturedRoot = root
				local sink = Instance.new("TextButton")
				sink.Parent = root
				local reference = Instance.new("ObjectValue")
				reference.Name = "BlockObjectRef"
				reference.Value = sink
				reference.Parent = root
				local view = BaseWindowView.new(root, windowId, `ui.window/{windowId}`, construction.Elements)
				view.Open = function()
					transitionBlocked = (sink :: any).InputSink == Enum.InputSink.All
					if behavior == "error" then
						error("ExpectedTransitionFailure")
					elseif behavior == "yield" then
						coroutine.yield()
						lateHookMutation += 1
					end
				end
				return view
			end,
			TryCastView = function(view: any)
				return if view.WindowId == windowId then view else nil
			end,
			InitializeView = function(view: any, model: any)
				if typeof(model) ~= "table" or model.Accepted ~= true then
					return { Kind = "Error", Error = { Code = "ViewModelMismatch" } }
				end
				return view:Initialize(model)
			end,
			LifecyclePolicy = lifecycle,
			VisibilityPolicy = "KeepBelow",
			BackgroundPolicy = "None",
			PoolOptions = if lifecycle == "Pool" then { MaxActive = 1, MaxRetained = 1 } else nil,
		}
		local ui = UiSystem.new({
			PlayersModule = playersModule,
			TemplateWindowDefinitions = { definition },
			Pooling = pooling,
			ContentPreloader = {
				Preload = function()
					return { Failed = 0 }
				end,
			},
			AssetBackend = {
				LoadAssetAsync = function()
					scheduler.SetNow(scheduler.Clock() + 2)
					return Instance.new("Frame")
				end,
			},
			Clock = scheduler.Clock,
			Spawn = scheduler.Spawn,
			Delay = scheduler.Delay,
			Wait = scheduler.Wait,
		})
		assertSuccess(ui:Initialize())
		local windowHost = (playerGui:FindFirstChild("UiRoot") :: ScreenGui):FindFirstChild("WindowHost") :: Frame
		scope:Defer(function()
			ui:Destroy()
			pooling:Destroy()
		end)
		return {
			Definition = definition,
			Ui = ui,
			WindowHost = windowHost,
			Pooling = pooling,
			Scheduler = scheduler,
			CapturedRoot = function()
				return capturedRoot
			end,
			TransitionBlocked = function()
				return transitionBlocked
			end,
			LateHookMutation = function()
				return lateHookMutation
			end,
		}
	end

	local pooled = makeScenario("timeout-pool", "Pool", "yield")
	local copiedDefinition = table.clone(pooled.Definition)
	local copied = pooled.Ui:AddWindowTypedAsync(copiedDefinition, { Accepted = true })
	assert(copied.Kind == "Error" and copied.Error.Code == "TypedDefinitionMismatch")

	local timedOut = pooled.Ui:AddWindowTypedAsync(pooled.Definition, { Accepted = true })
	assert(timedOut.Kind == "Error" and timedOut.Error.Code == "Timeout")
	assert(pooled.TransitionBlocked(), "transition token must block the configured sink while Open runs")
	local pooledDelayRequests = pooled.Scheduler.DelayRequests()
	assert(#pooledDelayRequests == 2 and pooledDelayRequests[2] == 1,
		"transition timeout must use the remaining portion of one absolute deadline")
	assert(#pooled.WindowHost:GetChildren() == 0)
	local pool = pooled.Pooling:GetPool("Ui.Window/timeout-pool")
	assert(pool ~= nil and pool:GetStats().Active == 1, "timed-out pooled hook must retain its quarantined lease")
	assert(pooled.Scheduler.PendingSpawnCount() == 1)
	pooled.Scheduler.ResumeSpawned()
	assert(pooled.LateHookMutation() == 1)
	assert(pool:GetStats().Active == 0 and pool:GetStats().Available == 1,
		"settled quarantine must clear and release through the existing pool lease")
	assert(#pooled.WindowHost:GetChildren() == 0, "late continuation must not restore stack presentation")

	local wrongModelScenario = makeScenario("wrong-model", "Destroy", "success")
	local wrongModel = wrongModelScenario.Ui:AddWindowTypedAsync(wrongModelScenario.Definition, { Accepted = false })
	assert(wrongModel.Kind == "Error" and wrongModel.Error.Code == "ViewModelMismatch")
	assert(#wrongModelScenario.WindowHost:GetChildren() == 0)

	local neverEnding = makeScenario("timeout-never", "Pool", "yield")
	local neverResult = neverEnding.Ui:AddWindowTypedAsync(neverEnding.Definition, { Accepted = true })
	assert(neverResult.Kind == "Error" and neverResult.Error.Code == "Timeout")
	local neverPool = neverEnding.Pooling:GetPool("Ui.Window/timeout-never")
	assert(neverPool:GetStats().Active == 1 and neverEnding.Scheduler.PendingSpawnCount() == 1,
		"a never-settling pooled transition must keep exactly one active lease until owner destruction")

	local destroyTimeout = makeScenario("timeout-destroy", "Destroy", "yield")
	local destroyResult = destroyTimeout.Ui:AddWindowTypedAsync(destroyTimeout.Definition, { Accepted = true })
	assert(destroyResult.Kind == "Error" and destroyResult.Error.Code == "Timeout")
	assert(#destroyTimeout.WindowHost:GetChildren() == 0)
	destroyTimeout.Scheduler.ResumeSpawned()
	assert(destroyTimeout.LateHookMutation() == 1 and #destroyTimeout.WindowHost:GetChildren() == 0,
		"destroy-policy late continuation may finish its own hook but must not regain navigator authority")

	local ordinaryFailure = makeScenario("ordinary-error", "Destroy", "error")
	local ordinaryResult = ordinaryFailure.Ui:AddWindowTypedAsync(ordinaryFailure.Definition, { Accepted = true })
	assert(ordinaryResult.Kind == "Error" and ordinaryResult.Error.Code == "OpenFailed")
	assert(ordinaryFailure.TransitionBlocked() and #ordinaryFailure.WindowHost:GetChildren() == 0)
end

local function TS_TEST_009_PostYieldAuthorityRevalidation(scope: TestHarness.Scope)
	local function exercise(phase: string, boundary: string)
		local windowId = `post-yield-{string.lower(phase)}-{boundary}`
		local definition = makeWindowDefinition(windowId, "Destroy", { Constructed = 0, Initialized = 0 })
		local now = 0
		local hookThread: thread? = nil
		local postYieldMutation = 0
		local events = {} :: { string }
		local navigator: any = nil
		definition.CreateView = function(root: GuiObject, context: any)
			local view = BaseWindowView.new(root, windowId, `ui.window/{windowId}`, context.Elements)
			view[phase] = function()
				hookThread = coroutine.running()
				coroutine.yield()
				postYieldMutation += 1
			end
			return view
		end
		local function spawn(callback: () -> ())
			local thread = coroutine.create(callback)
			local resumed, problem = coroutine.resume(thread)
			assert(resumed, problem)
			if coroutine.status(thread) ~= "dead" then hookThread = thread end
		end
		local function waitForBoundary(_signal: RBXScriptSignal, _isSettled: () -> boolean)
			if boundary == "deadline" then
				now = 3
			else
				navigator:Destroy()
			end
			assert(hookThread ~= nil, "yielding transition thread must be captured before the boundary")
			local resumed, problem = coroutine.resume(hookThread :: thread)
			assert(resumed, problem)
		end
		navigator = makeNavigatorFixture(scope, { definition }, {
			Elements = makeIdentityContext(function(event: any)
				table.insert(events, `{event.ActionId}:{event.WindowId}`)
			end),
			Clock = function() return now end,
			Spawn = spawn,
			Delay = function(_seconds: number, _callback: () -> ()) end,
			Wait = waitForBoundary,
		})

		local opened = navigator:AddExternal(windowId, nil)
		if phase == "Open" then
			assert(opened.Kind == "Error" and opened.Error.Code == "Timeout",
				"post-yield Open must not commit after losing owner or reaching its deadline")
			assert(#events == 0, "rejected post-yield Open must not confirm lifecycle or visibility")
		else
			assertSuccess(opened)
			local view = opened.Value:GetView().Value
			table.clear(events)
			local closed = view:CloseWindowAsync()
			assert(closed.Kind == "Error" and closed.Error.Code == "Timeout",
				"post-yield Close must not report success after losing owner or reaching its deadline")
			if boundary == "deadline" then
				assert(#events == 1 and events[1] == `{UiActionIds.WindowClosed}:{windowId}`,
					"deadline Close must use the approved forced-removal recovery exactly once")
			else
				assert(#events == 0, "post-Destroy Close continuation must not confirm or recover lifecycle")
			end
		end
		assert(postYieldMutation == 1, "custom hook continuation remains outside generic rollback")
	end

	for _, phase in { "Open", "Close" } do
		exercise(phase, "deadline")
		exercise(phase, "destroy")
	end
end

local function TS_TEST_004_005_008_MultiWindowLifecycle(scope: TestHarness.Scope)
	local guiService = { SelectedObject = nil }
	local events = {} :: { string }
	local lifecycleBoundaries = {} :: { string }
	local sinks = {} :: { [string]: TextButton }
	local defaults = {} :: { [string]: TextButton }
	local function trackedDefinition(windowId: string)
		local definition = makeWindowDefinition(windowId, "Destroy", { Constructed = 0, Initialized = 0 })
		definition.CreateView = function(root: GuiObject, context: any)
			local sink = Instance.new("TextButton")
			sink.Name = "InputSink"
			sink.Parent = root
			local reference = Instance.new("ObjectValue")
			reference.Name = "BlockObjectRef"
			reference.Value = sink
			reference.Parent = root
			local default = Instance.new("TextButton")
			default.Name = "DefaultSelection"
			default.Parent = root
			local view = BaseWindowView.new(root, windowId, `ui.window/{windowId}`, context.Elements)
			local controller = FrameController.new(default, `{windowId}/default`, true, context.Elements)
			assertSuccess(view:AddNestedUiElement(controller))
			assertSuccess(view:ConfigureNavigation(default, {}))
			sinks[windowId] = sink
			defaults[windowId] = default
			view.Open = function()
				table.insert(lifecycleBoundaries, `Open:{windowId}`)
				assert(guiService.SelectedObject ~= default and not default.Selectable and not default.Interactable,
					"Open must complete before the new window receives navigation eligibility or focus")
			end
			view.Resume = function()
				table.insert(lifecycleBoundaries, `Resume:{windowId}`)
				assert(guiService.SelectedObject ~= default and not default.Selectable and not default.Interactable,
					"Resume must complete before the returning window regains navigation eligibility or focus")
			end
			return view
		end
		return definition
	end

	local a = trackedDefinition("stack-a")
	local b = trackedDefinition("stack-b")
	local c = trackedDefinition("stack-c")
	local replacement = trackedDefinition("stack-replacement")
	b.VisibilityPolicy = "HideBelow"
	local elements = makeIdentityContext(function(event: any)
		table.insert(events, `{event.ActionId}:{event.WindowId}`)
		if event.ActionId == UiActionIds.WindowOpened then
			assert((sinks[event.WindowId] :: any).InputSink == Enum.InputSink.All,
				"opened confirmation must be published while the transition token still blocks input")
			assert(guiService.SelectedObject == nil,
				"opened confirmation must precede transition-token focus restoration")
		end
	end)
	local navigator, windowHost = makeNavigatorFixture(scope, { a, b, c, replacement }, {
		Elements = elements,
		GuiService = guiService,
	})

	local openedA = navigator:AddExternal(a.WindowId, nil)
	assertSuccess(openedA)
	assert(table.isfrozen(openedA.Value), "WindowHandle must be immutable")
	local mutationSucceeded = pcall(function()
		(openedA.Value :: any)._generation = 999
	end)
	assert(not mutationSucceeded and openedA.Value:IsValid(),
		"caller mutation must not alter generation authority")
	assert((sinks[a.WindowId] :: any).InputSink == Enum.InputSink.None
		and guiService.SelectedObject == defaults[a.WindowId],
		"successful Open must release its transition token only after opened confirmation")
	local viewA = openedA.Value:GetView().Value
	local openedB = viewA:AddWindowAsync(b.WindowId, nil)
	assertSuccess(openedB)
	assert(guiService.SelectedObject == defaults[b.WindowId])
	local viewB = openedB.Value:GetView().Value
	assert(openedA.Value:IsValid() and not openedA.Value:IsActiveWindow(), "paused handle must stay valid but inactive")
	assert(not viewA.Root.Visible and viewB.Root.Visible, "HideBelow must hide only the lower prefix")
	local rejected = viewA:AddWindowAsync(c.WindowId, nil)
	assert(rejected.Kind == "Error" and rejected.Error.Code == "NotActiveWindow")

	local openedC = viewB:AddWindowAsync(c.WindowId, nil)
	assertSuccess(openedC)
	assert(guiService.SelectedObject == defaults[c.WindowId])
	assert(openedB.Value:IsValid() and not openedB.Value:IsActiveWindow())
	assert(not viewA.Root.Visible and viewB.Root.Visible and openedC.Value:GetView().Value.Root.Visible)
	assertSuccess(openedC.Value:GetView().Value:CloseWindowAsync())
	assert(openedB.Value:IsActiveWindow(), "closing top must resume the exact lower top")

	local replaced = viewB:CloseWindowAsync(replacement.WindowId, nil)
	assertSuccess(replaced)
	assert(guiService.SelectedObject == defaults[replacement.WindowId])
	assert(not openedB.Value:IsValid() and replaced.Value:IsActiveWindow())
	assert(#windowHost:GetChildren() == 2, "replacement must preserve the lower stack prefix")
	assertSuccess(replaced.Value:GetView().Value:CloseWindowAsync())
	assert(openedA.Value:IsActiveWindow() and viewA.Root.Visible, "final close must resume and show the remaining lower window")
	assertSuccess(viewA:CloseWindowAsync())
	assert(#lifecycleBoundaries == 6
		and lifecycleBoundaries[1] == "Open:stack-a"
		and lifecycleBoundaries[2] == "Open:stack-b"
		and lifecycleBoundaries[3] == "Open:stack-c"
		and lifecycleBoundaries[4] == "Resume:stack-b"
		and lifecycleBoundaries[5] == "Open:stack-replacement"
		and lifecycleBoundaries[6] == "Resume:stack-a",
		"Open/Resume hooks must run before focus restoration in deterministic stack order")

	local expectedEvents = {
		`{UiActionIds.WindowOpened}:stack-a`,
		`{UiActionIds.WindowShown}:stack-a`,
		`{UiActionIds.WindowPaused}:stack-a`,
		`{UiActionIds.WindowOpened}:stack-b`,
		`{UiActionIds.WindowHidden}:stack-a`,
		`{UiActionIds.WindowShown}:stack-b`,
		`{UiActionIds.WindowPaused}:stack-b`,
		`{UiActionIds.WindowOpened}:stack-c`,
		`{UiActionIds.WindowShown}:stack-c`,
		`{UiActionIds.WindowClosed}:stack-c`,
		`{UiActionIds.WindowResumed}:stack-b`,
		`{UiActionIds.WindowClosed}:stack-b`,
		`{UiActionIds.WindowOpened}:stack-replacement`,
		`{UiActionIds.WindowShown}:stack-a`,
		`{UiActionIds.WindowShown}:stack-replacement`,
		`{UiActionIds.WindowClosed}:stack-replacement`,
		`{UiActionIds.WindowResumed}:stack-a`,
		`{UiActionIds.WindowClosed}:stack-a`,
	}
	assert(#events == #expectedEvents, "lifecycle confirmation count must match the applied state changes")
	for index, expected in expectedEvents do
		assert(events[index] == expected, `lifecycle confirmation order mismatch at {index}`)
	end

	local lower = makeWindowDefinition("recovery-lower", "Destroy", { Constructed = 0, Initialized = 0 })
	local dirty = makeWindowDefinition("recovery-dirty", "Destroy", { Constructed = 0, Initialized = 0 })
	dirty.CreateView = function(root: GuiObject, context: any)
		local view = BaseWindowView.new(root, dirty.WindowId, "ui.window/recovery-dirty", context.Elements)
		view.Clear = function()
			return { Kind = "Error", Error = { Code = "CleanupFailed" } }
		end
		return view
	end
	local replacementCounters = { Constructed = 0, Initialized = 0 }
	local replacementAfterDirty = makeWindowDefinition("recovery-candidate", "Destroy", replacementCounters)
	local recoveryNavigator, recoveryHost = makeNavigatorFixture(scope, { lower, dirty, replacementAfterDirty })
	local lowerResult = recoveryNavigator:AddExternal(lower.WindowId, nil)
	assertSuccess(lowerResult)
	local dirtyResult = lowerResult.Value:GetView().Value:AddWindowAsync(dirty.WindowId, nil)
	assertSuccess(dirtyResult)
	local cleanupFailure = dirtyResult.Value:GetView().Value:CloseWindowAsync(replacementAfterDirty.WindowId, nil)
	assert(cleanupFailure.Kind == "Error" and cleanupFailure.Error.Code == "CleanupFailed",
		"replacement must propagate removed-window cleanup failure")
	assert(not dirtyResult.Value:IsValid() and lowerResult.Value:IsActiveWindow()
		and #recoveryHost:GetChildren() == 1,
		"replacement cleanup failure must keep the old window removed, discard the candidate, and resume lower top")
	assert(replacementCounters.Constructed == 1 and replacementCounters.Initialized == 1)

	local openEvents = {} :: { string }
	local openBase = makeWindowDefinition("open-recovery-base", "Destroy", { Constructed = 0, Initialized = 0 })
	local failingOpen = makeWindowDefinition("open-recovery-failure", "Destroy", { Constructed = 0, Initialized = 0 })
	local dirtyFailingOpen = makeWindowDefinition("open-recovery-dirty", "Destroy", { Constructed = 0, Initialized = 0 })
	failingOpen.CreateView = function(root: GuiObject, context: any)
		local view = BaseWindowView.new(root, failingOpen.WindowId, "ui.window/open-recovery-failure", context.Elements)
		view.Open = function()
			error("ExpectedOpenFailure")
		end
		return view
	end
	dirtyFailingOpen.CreateView = function(root: GuiObject, context: any)
		local view = BaseWindowView.new(root, dirtyFailingOpen.WindowId, "ui.window/open-recovery-dirty", context.Elements)
		view.Open = function()
			error("ExpectedDirtyOpenFailure")
		end
		view.Clear = function()
			return { Kind = "Error", Error = { Code = "CleanupFailed" } }
		end
		return view
	end
	local openNavigator, openHost = makeNavigatorFixture(scope, { openBase, failingOpen, dirtyFailingOpen }, {
		Elements = makeIdentityContext(function(event: any)
			table.insert(openEvents, `{event.ActionId}:{event.WindowId}`)
		end),
	})
	local openBaseResult = openNavigator:AddExternal(openBase.WindowId, nil)
	assertSuccess(openBaseResult)
	table.clear(openEvents)
	local openFailure = openBaseResult.Value:GetView().Value:AddWindowAsync(failingOpen.WindowId, nil)
	assert(openFailure.Kind == "Error" and openFailure.Error.Code == "OpenFailed")
	assert(openBaseResult.Value:IsActiveWindow() and #openHost:GetChildren() == 1)
	assert(#openEvents == 2
		and openEvents[1] == `{UiActionIds.WindowPaused}:open-recovery-base`
		and openEvents[2] == `{UiActionIds.WindowResumed}:open-recovery-base`,
		"failed Open must emit only applied pause/resume confirmations and no temporary opened/closed event")
	table.clear(openEvents)
	local dirtyOpenFailure = openBaseResult.Value:GetView().Value:AddWindowAsync(dirtyFailingOpen.WindowId, nil)
	assert(dirtyOpenFailure.Kind == "Error" and dirtyOpenFailure.Error.Code == "CleanupFailed"
		and dirtyOpenFailure.Error.WindowId == dirtyFailingOpen.WindowId,
		"failed Add Open must propagate cleanup failure for the rejected new candidate")
	assert(openBaseResult.Value:IsActiveWindow() and #openHost:GetChildren() == 1
		and #openEvents == 2
		and openEvents[1] == `{UiActionIds.WindowPaused}:open-recovery-base`
		and openEvents[2] == `{UiActionIds.WindowResumed}:open-recovery-base`,
		"dirty Add candidate cleanup must preserve the applied old-window pause/resume recovery")

	local replaceLower = makeWindowDefinition("replace-open-lower", "Destroy", { Constructed = 0, Initialized = 0 })
	local replaceOld = makeWindowDefinition("replace-open-old", "Destroy", { Constructed = 0, Initialized = 0 })
	local dirtyReplacement = makeWindowDefinition("replace-open-dirty", "Destroy", { Constructed = 0, Initialized = 0 })
	dirtyReplacement.CreateView = function(root: GuiObject, context: any)
		local view = BaseWindowView.new(root, dirtyReplacement.WindowId, "ui.window/replace-open-dirty", context.Elements)
		view.Open = function()
			error("ExpectedDirtyReplacementOpenFailure")
		end
		view.Clear = function()
			return { Kind = "Error", Error = { Code = "CleanupFailed" } }
		end
		return view
	end
	local replaceNavigator, replaceHost = makeNavigatorFixture(scope, { replaceLower, replaceOld, dirtyReplacement })
	local replaceLowerResult = replaceNavigator:AddExternal(replaceLower.WindowId, nil)
	assertSuccess(replaceLowerResult)
	local replaceOldResult = replaceLowerResult.Value:GetView().Value:AddWindowAsync(replaceOld.WindowId, nil)
	assertSuccess(replaceOldResult)
	local dirtyReplacementFailure = replaceOldResult.Value:GetView().Value:CloseWindowAsync(dirtyReplacement.WindowId, nil)
	assert(dirtyReplacementFailure.Kind == "Error" and dirtyReplacementFailure.Error.Code == "CleanupFailed"
		and dirtyReplacementFailure.Error.WindowId == dirtyReplacement.WindowId,
		"failed replacement Open must propagate cleanup failure for its new candidate")
	assert(not replaceOldResult.Value:IsValid() and replaceLowerResult.Value:IsActiveWindow()
		and #replaceHost:GetChildren() == 1,
		"replacement must keep the successfully cleaned old window removed and resume the lower prefix")

	local closeEvents = {} :: { string }
	local closeBase = makeWindowDefinition("close-recovery-base", "Destroy", { Constructed = 0, Initialized = 0 })
	local failingClose = makeWindowDefinition("close-recovery-failure", "Destroy", { Constructed = 0, Initialized = 0 })
	local dirtyFailingClose = makeWindowDefinition("close-recovery-dirty-failure", "Destroy", { Constructed = 0, Initialized = 0 })
	failingClose.CreateView = function(root: GuiObject, context: any)
		local view = BaseWindowView.new(root, failingClose.WindowId, "ui.window/close-recovery-failure", context.Elements)
		view.Close = function()
			error("ExpectedCloseFailure")
		end
		return view
	end
	dirtyFailingClose.CreateView = function(root: GuiObject, context: any)
		local view = BaseWindowView.new(root, dirtyFailingClose.WindowId, "ui.window/close-recovery-dirty-failure", context.Elements)
		view.Close = function()
			error("ExpectedDirtyCloseFailure")
		end
		view.Clear = function()
			return { Kind = "Error", Error = { Code = "CleanupFailed" } }
		end
		return view
	end
	local closeNavigator, closeHost = makeNavigatorFixture(scope, { closeBase, failingClose, dirtyFailingClose }, {
		Elements = makeIdentityContext(function(event: any)
			table.insert(closeEvents, `{event.ActionId}:{event.WindowId}`)
		end),
	})
	local closeBaseResult = closeNavigator:AddExternal(closeBase.WindowId, nil)
	assertSuccess(closeBaseResult)
	local failingCloseResult = closeBaseResult.Value:GetView().Value:AddWindowAsync(failingClose.WindowId, nil)
	assertSuccess(failingCloseResult)
	table.clear(closeEvents)
	local closeFailure = failingCloseResult.Value:GetView().Value:CloseWindowAsync()
	assert(closeFailure.Kind == "Error" and closeFailure.Error.Code == "CloseFailed")
	assert(not failingCloseResult.Value:IsValid() and closeBaseResult.Value:IsActiveWindow()
		and #closeHost:GetChildren() == 1)
	assert(#closeEvents == 2
		and closeEvents[1] == `{UiActionIds.WindowClosed}:close-recovery-failure`
		and closeEvents[2] == `{UiActionIds.WindowResumed}:close-recovery-base`,
		"failed Close must publish closed before resumed after the applied removal")
	local dirtyFailingCloseResult = closeBaseResult.Value:GetView().Value:AddWindowAsync(dirtyFailingClose.WindowId, nil)
	assertSuccess(dirtyFailingCloseResult)
	local dirtyCloseFailure = dirtyFailingCloseResult.Value:GetView().Value:CloseWindowAsync()
	assert(dirtyCloseFailure.Kind == "Error" and dirtyCloseFailure.Error.Code == "CleanupFailed"
		and dirtyCloseFailure.Error.WindowId == dirtyFailingClose.WindowId,
		"direct Close cleanup failure must take precedence over the simultaneous Close hook failure")
	assert(not dirtyFailingCloseResult.Value:IsValid() and closeBaseResult.Value:IsActiveWindow()
		and #closeHost:GetChildren() == 1,
		"direct Close simultaneous failure must keep removal committed and resume the lower top")

	local replaceCloseLower = makeWindowDefinition("replace-close-lower", "Destroy", { Constructed = 0, Initialized = 0 })
	local replaceCloseOld = makeWindowDefinition("replace-close-old", "Destroy", { Constructed = 0, Initialized = 0 })
	local replaceCloseDirty = makeWindowDefinition("replace-close-dirty", "Destroy", { Constructed = 0, Initialized = 0 })
	local replaceCloseOldDirty = makeWindowDefinition("replace-close-old-dirty", "Destroy", { Constructed = 0, Initialized = 0 })
	local replaceCloseClean = makeWindowDefinition("replace-close-clean", "Destroy", { Constructed = 0, Initialized = 0 })
	replaceCloseOld.CreateView = function(root: GuiObject, context: any)
		local view = BaseWindowView.new(root, replaceCloseOld.WindowId, "ui.window/replace-close-old", context.Elements)
		view.Close = function()
			error("ExpectedReplacementCloseFailure")
		end
		return view
	end
	replaceCloseDirty.CreateView = function(root: GuiObject, context: any)
		local view = BaseWindowView.new(root, replaceCloseDirty.WindowId, "ui.window/replace-close-dirty", context.Elements)
		view.Clear = function()
			return { Kind = "Error", Error = { Code = "CleanupFailed" } }
		end
		return view
	end
	replaceCloseOldDirty.CreateView = function(root: GuiObject, context: any)
		local view = BaseWindowView.new(root, replaceCloseOldDirty.WindowId, "ui.window/replace-close-old-dirty", context.Elements)
		view.Close = function()
			error("ExpectedDirtyReplacementCloseFailure")
		end
		view.Clear = function()
			return { Kind = "Error", Error = { Code = "CleanupFailed" } }
		end
		return view
	end
	local replaceCloseNavigator, replaceCloseHost = makeNavigatorFixture(
		scope,
		{ replaceCloseLower, replaceCloseOld, replaceCloseDirty, replaceCloseOldDirty, replaceCloseClean }
	)
	local replaceCloseLowerResult = replaceCloseNavigator:AddExternal(replaceCloseLower.WindowId, nil)
	assertSuccess(replaceCloseLowerResult)
	local replaceCloseOldResult = replaceCloseLowerResult.Value:GetView().Value:AddWindowAsync(replaceCloseOld.WindowId, nil)
	assertSuccess(replaceCloseOldResult)
	local replaceCloseFailure = replaceCloseOldResult.Value:GetView().Value:CloseWindowAsync(replaceCloseDirty.WindowId, nil)
	assert(replaceCloseFailure.Kind == "Error" and replaceCloseFailure.Error.Code == "CleanupFailed"
		and replaceCloseFailure.Error.WindowId == replaceCloseDirty.WindowId,
		"replacement old-Close failure must not hide failure to clean the prepared new candidate")
	assert(not replaceCloseOldResult.Value:IsValid() and replaceCloseLowerResult.Value:IsActiveWindow()
		and #replaceCloseHost:GetChildren() == 1,
		"replacement old-Close recovery must stay committed when new-candidate cleanup also fails")
	local replaceCloseOldDirtyResult = replaceCloseLowerResult.Value:GetView().Value:AddWindowAsync(replaceCloseOldDirty.WindowId, nil)
	assertSuccess(replaceCloseOldDirtyResult)
	local replaceRemovedCleanupFailure = replaceCloseOldDirtyResult.Value:GetView().Value:CloseWindowAsync(replaceCloseClean.WindowId, nil)
	assert(replaceRemovedCleanupFailure.Kind == "Error" and replaceRemovedCleanupFailure.Error.Code == "CleanupFailed"
		and replaceRemovedCleanupFailure.Error.WindowId == replaceCloseOldDirty.WindowId,
		"replacement removed-window cleanup failure must take precedence over the simultaneous Close hook failure")
	assert(not replaceCloseOldDirtyResult.Value:IsValid() and replaceCloseLowerResult.Value:IsActiveWindow()
		and #replaceCloseHost:GetChildren() == 1,
		"replacement simultaneous failure must discard the prepared candidate and resume the lower top")

	local function dirtyPrepareDefinition(windowId: string)
		local definition = makeWindowDefinition(windowId, "Destroy", { Constructed = 0, Initialized = 0 })
		definition.CreateView = function(root: GuiObject, context: any)
			local view = BaseWindowView.new(root, windowId, `ui.window/{windowId}`, context.Elements)
			view.Clear = function()
				return { Kind = "Error", Error = { Code = "CleanupFailed" } }
			end
			return view
		end
		return definition
	end

	local dirtyCast = dirtyPrepareDefinition("prepare-dirty-cast")
	dirtyCast.TryCastView = function()
		return nil
	end
	local dirtyInitialize = dirtyPrepareDefinition("prepare-dirty-initialize")
	dirtyInitialize.InitializeView = function()
		return { Kind = "Error", Error = { Code = "ViewModelMismatch" } }
	end
	local dirtyBackground = dirtyPrepareDefinition("prepare-dirty-background")
	dirtyBackground.BackgroundPolicy = "Absorb"
	local prepareNavigator = makeNavigatorFixture(scope, { dirtyCast, dirtyInitialize, dirtyBackground })
	for _, definition in { dirtyCast, dirtyInitialize, dirtyBackground } do
		local result = prepareNavigator:AddExternal(definition.WindowId, nil)
		assert(result.Kind == "Error" and result.Error.Code == "CleanupFailed"
			and result.Error.WindowId == definition.WindowId and result.Error.Phase == "Cleanup",
			`{definition.WindowId} must propagate failed candidate cleanup over its prepare failure`)
	end
end

local function TS_TEST_008_SyncHookPartitions(scope: TestHarness.Scope)
	for _, partition in {
		{ Phase = "Pause", Behavior = "error" },
		{ Phase = "Pause", Behavior = "yield" },
		{ Phase = "Resume", Behavior = "error" },
		{ Phase = "Resume", Behavior = "yield" },
	} do
		local suffix = string.lower(`{partition.Phase}-{partition.Behavior}`)
		local baseId = `hook-{suffix}`
		local overlayId = `hook-overlay-{suffix}`
		local trace = {} :: { string }
		local diagnostics = {} :: { any }
		local capturedThread: thread? = nil
		local postYieldMutation = 0
		local customCalls = 0
		local base = makeWindowDefinition(baseId, "Destroy", { Constructed = 0, Initialized = 0 })
		local overlay = makeWindowDefinition(overlayId, "Destroy", { Constructed = 0, Initialized = 0 })
		base.CreateView = function(root: GuiObject, context: any)
			local view = BaseWindowView.new(root, baseId, `ui.window/{baseId}`, context.Elements)
			local function runHook(phase: string)
				table.insert(trace, `{phase}Hook`)
				if partition.Phase == phase then
					if partition.Behavior == "error" then
						error(`Expected{phase}Failure`)
					end
					capturedThread = coroutine.running()
					coroutine.yield()
					postYieldMutation += 1
				end
			end
			view.Pause = function()
				runHook("Pause")
			end
			view.Resume = function()
				runHook("Resume")
			end
			view.ReadCustomPausedState = function()
				customCalls += 1
				return "custom-paused-state"
			end
			return view
		end
		local elements = makeIdentityContext(function(event: any)
			if event.WindowId == baseId and event.ActionId == UiActionIds.WindowPaused then
				table.insert(trace, "PausedEvent")
			elseif event.WindowId == baseId and event.ActionId == UiActionIds.WindowResumed then
				table.insert(trace, "ResumedEvent")
			end
		end)
		local navigator = makeNavigatorFixture(scope, { base, overlay }, {
			Elements = elements,
			Logger = {
				Warn = function(_self: any, name: string, fields: any)
					table.insert(diagnostics, { Name = name, Phase = fields.Phase, Reason = fields.Reason })
				end,
			},
		})
		local baseResult = navigator:AddExternal(baseId, nil)
		assertSuccess(baseResult)
		local baseView = baseResult.Value:GetView().Value
		local overlayResult = baseView:AddWindowAsync(overlayId, nil)
		assertSuccess(overlayResult)
		assert(baseResult.Value:IsValid() and not baseResult.Value:IsActiveWindow(),
			"isolated Pause hook failure must preserve the committed Paused base state")
		assert(baseResult.Value:GetView().Value:ReadCustomPausedState() == "custom-paused-state" and customCalls == 1,
			"a valid paused handle must retain access to concrete custom methods")
		assertSuccess(overlayResult.Value:GetView().Value:CloseWindowAsync())
		assert(baseResult.Value:IsActiveWindow(),
			"isolated Resume hook failure must preserve the committed Active recovery state")
		assert(#trace == 4
			and trace[1] == "PauseHook" and trace[2] == "PausedEvent"
			and trace[3] == "ResumeHook" and trace[4] == "ResumedEvent",
			"Pause/Resume confirmations must follow their completed or isolated hook boundary")
		local expectedReason = if partition.Behavior == "yield" then "Yielded" else "Error"
		assert(#diagnostics == 1 and diagnostics[1].Name == "ui_window_hook_failed"
			and diagnostics[1].Phase == partition.Phase
			and diagnostics[1].Reason == expectedReason
			and #diagnostics[1].Name < 1024,
			"each injected sync-hook failure must emit one bounded phase-appropriate developer diagnostic")
		if partition.Behavior == "yield" then
			assert(capturedThread ~= nil and not coroutine.resume(capturedThread :: thread),
				"yielding Pause/Resume hook thread must be closed at the sync boundary")
			assert(postYieldMutation == 0, "closed Pause/Resume hook must never execute its post-yield mutation")
		else
			assert(capturedThread == nil and postYieldMutation == 0)
		end
	end
end

local function TS_TEST_006_NavigationOwnership(scope: TestHarness.Scope)
	local selected = { SelectedObject = nil }
	local root = scope:Track(Instance.new("Frame")) :: Frame
	local view = BaseWindowView.new(root, "navigation", "ui.window/navigation", makeIdentityContext())
	view:_SetNavigatorBinding({}, table.freeze({
		CanEmitAction = function() return true end,
		GetGuiService = function() return selected end,
	}))
	local firstRoot = scope:Track(Instance.new("TextButton")) :: TextButton
	firstRoot.Selectable = true
	firstRoot.Interactable = true
	local first = FrameController.new(firstRoot, "navigation/first", true, view._context)
	assertSuccess(view:AddNestedUiElement(first, firstRoot))
	assertSuccess(view:ConfigureNavigation(firstRoot, {}))
	assertSuccess(view:Initialize(nil))
	view:_SetNavigationActive(true)
	assert(selected.SelectedObject == firstRoot)

	local secondRoot = scope:Track(Instance.new("TextButton")) :: TextButton
	local second = FrameController.new(secondRoot, "navigation/second", true, view._context)
	assertSuccess(view:AddNestedUiElement(second))
	local missingReplacement = view:RemoveNestedUiElement(first)
	assert(missingReplacement.Kind == "Error" and missingReplacement.Error.Code == "InvalidDefaultNavigation")
	assert(first._parent == view and selected.SelectedObject == firstRoot, "failed replacement nomination must be atomic")
	assertSuccess(view:RemoveNestedUiElement(first, secondRoot))
	assert(selected.SelectedObject == secondRoot)

	assertSuccess(view:RemoveNestedUiElement(second))
	assert(selected.SelectedObject == nil)
	local thirdRoot = scope:Track(Instance.new("TextButton")) :: TextButton
	local third = FrameController.new(thirdRoot, "navigation/third", true, view._context)
	local missingDefault = view:AddNestedUiElement(third)
	assert(missingDefault.Kind == "Error" and missingDefault.Error.Code == "InvalidDefaultNavigation")
	assert(third._parent == nil, "failed 0 -> nonzero nomination must leave hierarchy unchanged")
	assertSuccess(view:AddNestedUiElement(third, thirdRoot))
	assert(selected.SelectedObject == thirdRoot)
	assertSuccess(view:Clear())
	assert(selected.SelectedObject == nil and thirdRoot.Selectable, "Clear must restore authored navigation baseline")

	local dynamicRoot = scope:Track(Instance.new("Frame")) :: Frame
	local dynamicView = BaseWindowView.new(dynamicRoot, "navigation-dynamic", "ui.window/navigation-dynamic", makeIdentityContext())
	dynamicView:_SetNavigatorBinding({}, table.freeze({
		CanEmitAction = function() return true end,
		GetGuiService = function() return selected end,
	}))
	local closeRoot = scope:Track(Instance.new("TextButton")) :: TextButton
	local refreshRoot = scope:Track(Instance.new("TextButton")) :: TextButton
	local authoredDisabledRoot = scope:Track(Instance.new("TextButton")) :: TextButton
	closeRoot.NextSelectionRight = closeRoot
	authoredDisabledRoot.Selectable = false
	authoredDisabledRoot.Interactable = false
	local closeController = FrameController.new(closeRoot, "navigation-dynamic/close", true, dynamicView._context)
	local refreshController = FrameController.new(refreshRoot, "navigation-dynamic/refresh", true, dynamicView._context)
	local disabledController = FrameController.new(authoredDisabledRoot, "navigation-dynamic/disabled", true, dynamicView._context)
	assertSuccess(dynamicView:AddNestedUiElement(closeController, closeRoot))
	assertSuccess(dynamicView:AddNestedUiElement(refreshController))
	assertSuccess(dynamicView:AddNestedUiElement(disabledController))
	assertSuccess(dynamicView:ConfigureNavigation(closeRoot, {
		{ From = closeRoot, Direction = "Right", To = refreshRoot },
	}))
	assertSuccess(dynamicView:Initialize(nil))
	dynamicView:_SetNavigationActive(true)
	assert(selected.SelectedObject == closeRoot and closeRoot.NextSelectionRight == refreshRoot)
	selected.SelectedObject = refreshRoot
	assert(dynamicView._navigationRegistry:SetMemberEligibility(refreshRoot, false, false))
	assert(selected.SelectedObject == closeRoot,
		"disabling the selected member must move focus to the eligible default")
	assert(not refreshRoot.Selectable and not refreshRoot.Interactable
		and closeRoot.NextSelectionRight == closeRoot,
		"disabled member must be excluded from the override while preserving the authored fallback direction")
	dynamicView:_SetNavigationActive(false)
	dynamicView:_SetNavigationActive(true)
	assert(selected.SelectedObject == closeRoot, "pause/resume must not reselect a disabled last member")
	assert(dynamicView._navigationRegistry:SetMemberEligibility(authoredDisabledRoot, true, true))
	assert(not authoredDisabledRoot.Selectable and not authoredDisabledRoot.Interactable,
		"dynamic true must not override authored-disabled properties")
	assert(dynamicView._navigationRegistry:SetMemberEligibility(refreshRoot, true, true))
	assert(refreshRoot.Selectable and refreshRoot.Interactable and closeRoot.NextSelectionRight == refreshRoot)
	selected.SelectedObject = refreshRoot
	dynamicView:_SetNavigationActive(false)
	dynamicView:_SetNavigationActive(true)
	assert(selected.SelectedObject == refreshRoot, "eligible last selection must survive pause/resume")
	dynamicView:_SetNavigationActive(false)
	assert(dynamicView._navigationRegistry:SetMemberEligibility(refreshRoot, false, false))
	dynamicView:_SetNavigationActive(true)
	assert(selected.SelectedObject == closeRoot, "disabled paused last selection must fall back to the default")
	assertSuccess(dynamicView:Clear())
	assert(refreshRoot.Selectable and refreshRoot.Interactable
		and not authoredDisabledRoot.Selectable and not authoredDisabledRoot.Interactable
		and closeRoot.NextSelectionRight == closeRoot,
		"Clear must restore exact authored flags and directions and discard dynamic state")

	local overrideRoot = scope:Track(Instance.new("Frame")) :: Frame
	local overrideView = BaseWindowView.new(
		overrideRoot,
		"navigation-overrides",
		"ui.window/navigation-overrides",
		makeIdentityContext(nil)
	)
	overrideView:_SetNavigatorBinding({}, table.freeze({
		CanEmitAction = function() return true end,
		GetGuiService = function() return selected end,
	}))
	local fromA = scope:Track(Instance.new("TextButton")) :: TextButton
	local fromB = scope:Track(Instance.new("TextButton")) :: TextButton
	local target = scope:Track(Instance.new("TextButton")) :: TextButton
	fromA.Name = "SameAuthoredName"
	fromB.Name = "SameAuthoredName"
	target.Name = "Target"
	fromA.Parent = overrideRoot
	fromB.Parent = overrideRoot
	target.Parent = overrideRoot
	local fromAController = FrameController.new(fromA, "navigation-overrides/from-a", true, overrideView._context)
	local fromBController = FrameController.new(fromB, "navigation-overrides/from-b", true, overrideView._context)
	local targetController = FrameController.new(target, "navigation-overrides/target", true, overrideView._context)
	assertSuccess(overrideView:AddNestedUiElement(fromAController, fromA))
	assertSuccess(overrideView:AddNestedUiElement(fromBController))
	assertSuccess(overrideView:AddNestedUiElement(targetController))
	assertSuccess(overrideView:ConfigureNavigation(fromA, {
		{ From = fromA, Direction = "Down", To = target },
		{ From = fromB, Direction = "Down", To = target },
	}))
	assertSuccess(overrideView:Initialize(nil))
	overrideView:_SetNavigationActive(true)
	assert(fromA.NextSelectionDown == target and fromB.NextSelectionDown == target,
		"same-name authored controls are distinct override sources by exact Instance identity")
	local foreignHud = scope:Track(Instance.new("TextButton")) :: TextButton
	overrideView:_SetNavigationActive(false)
	selected.SelectedObject = foreignHud
	overrideView:_SetNavigationActive(true)
	assert(selected.SelectedObject == fromA, "activating a window must take navigation focus from a foreign HUD")
	selected.SelectedObject = target
	overrideView:_SetNavigationActive(false)
	selected.SelectedObject = foreignHud
	overrideView:_SetNavigationActive(true)
	assert(selected.SelectedObject == target, "resuming must restore the window's own last focus rather than a foreign HUD")
	selected.SelectedObject = foreignHud
	assert(overrideView._navigationRegistry:SetMemberEligibility(fromB, true, true))
	assert(selected.SelectedObject == foreignHud, "ordinary presentation updates must not repeatedly steal unrelated focus")
	assertSuccess(overrideView:Clear())
end

local function TS_TEST_017_VisibleBeforeSelection(scope: TestHarness.Scope)
	local host: Frame? = nil
	local selected: GuiObject? = nil
	local assignments = 0
	local guiService = setmetatable({}, {
		__index = function(_self, key)
			assert(key == "SelectedObject")
			return selected
		end,
		__newindex = function(_self, key, value)
			assert(key == "SelectedObject")
			if value ~= nil then
				assert(host ~= nil and value:IsDescendantOf(host), "selection target must already be parented to the window host")
				assert(value.Selectable and value.Interactable, "selection target must already be eligible")
				local ancestor = value
				while ancestor ~= nil do
					if ancestor:IsA("GuiObject") then
						assert(ancestor.Visible, "selection target and every ancestor must be visible before SelectedObject is assigned")
					end
					if ancestor == host then break end
					ancestor = ancestor.Parent
				end
				assignments += 1
			end
			selected = value
		end,
	})
	local defaults = {}
	local alternatives = {}
	local function hiddenDefinition(id: string): any
		local definition = makeWindowDefinition(id, "Destroy", { Constructed = 0, Initialized = 0 })
		definition.CreateView = function(root: GuiObject, context: any)
			root.Visible = false
			local default = Instance.new("TextButton")
			default.Parent = root
			local alternative = Instance.new("TextButton")
			alternative.Parent = root
			local view = BaseWindowView.new(root, id, `ui.window/{id}`, context.Elements)
			assertSuccess(view:AddNestedUiElement(FrameController.new(default, `{id}/default`, true, context.Elements)))
			assertSuccess(view:AddNestedUiElement(FrameController.new(alternative, `{id}/alternative`, true, context.Elements)))
			assertSuccess(view:ConfigureNavigation(default, {}))
			defaults[id] = default
			alternatives[id] = alternative
			return view
		end
		return definition
	end
	local lower = hiddenDefinition("visible-lower")
	local modal = hiddenDefinition("visible-modal")
	local replacement = hiddenDefinition("visible-replacement")
	modal.VisibilityPolicy = "HideBelow"
	replacement.VisibilityPolicy = "HideBelow"
	local navigator, windowHost = makeNavigatorFixture(scope, { lower, modal, replacement }, { GuiService = guiService })
	host = windowHost
	local openedLower = navigator:AddExternal(lower.WindowId, nil)
	assertSuccess(openedLower)
	assert(selected == defaults[lower.WindowId], "initial hidden template must become selectable after being shown")
	guiService.SelectedObject = alternatives[lower.WindowId]
	local lowerView = openedLower.Value:GetView().Value
	local openedModal = lowerView:AddWindowAsync(modal.WindowId, nil)
	assertSuccess(openedModal)
	assert(not lowerView.Root.Visible and selected == defaults[modal.WindowId])
	local replaced = openedModal.Value:GetView().Value:CloseWindowAsync(replacement.WindowId, nil)
	assertSuccess(replaced)
	assert(selected == defaults[replacement.WindowId], "replacement must be visible before taking focus")
	assertSuccess(replaced.Value:GetView().Value:CloseWindowAsync())
	assert(lowerView.Root.Visible and selected == alternatives[lower.WindowId],
		"a hidden lower window must be shown before its last focus is restored")
	assert(assignments >= 5, "visibility assertions must cover add, replace, and resume focus assignments")
end

function UiSystemTestRunner.runAll()
	return TestHarness.runAll("UiSystemTestRunner", {
		{ Name = "TS-TEST-001 root hosts ownership", Callback = TS_TEST_001_RootHostsOwnership },
		{ Name = "TS-TEST-014 data-only authoring template", Callback = TS_TEST_014_DataOnlyAuthoringTemplate },
		{ Name = "TS-TEST-016 deterministic local window asset fixture", Callback = TS_TEST_016_LocalWindowAssetFixture },
		{ Name = "SLICE-002 first-window config, cache, and pool reuse", Callback = TS_TEST_002_003_011_FirstWindowRuntime },
		{ Name = "TS-TEST-003 deterministic admission and reentrant NoOp partitions", Callback = TS_TEST_003_ReentrantNoOpAndDuplicateAdmission },
		{ Name = "TS-TEST-007 destroy and pooled cleanup failure partitions", Callback = TS_TEST_007_CloseCleanupPartitions },
		{ Name = "TS-TEST-010 protected canonical TryCastView partitions", Callback = TS_TEST_010_ProtectedTryCast },
		{ Name = "TS-TEST-011 asset, preload, single-flight, and retry partitions", Callback = TS_TEST_011_AssetPreparationPartitions },
		{ Name = "TS-TEST-006/011 Background and blocked-action partitions", Callback = TS_TEST_006_011_BackgroundAndBlockedActions },
		{ Name = "TS-TEST-006 input blocking", Callback = TS_TEST_006_InputBlocking },
		{ Name = "TS-TEST-009 transition timeout and pooled quarantine", Callback = TS_TEST_009_010_TransitionAndTypedFailures },
		{ Name = "TS-TEST-009 post-yield owner, generation, and deadline revalidation", Callback = TS_TEST_009_PostYieldAuthorityRevalidation },
		{ Name = "TS-TEST-004/005/008 multi-window lifecycle", Callback = TS_TEST_004_005_008_MultiWindowLifecycle },
		{ Name = "TS-TEST-008 sync hook error, yield, and paused custom method partitions", Callback = TS_TEST_008_SyncHookPartitions },
		{ Name = "TS-TEST-006 navigation ownership", Callback = TS_TEST_006_NavigationOwnership },
		{ Name = "TS-TEST-017 visible windows before navigation selection", Callback = TS_TEST_017_VisibleBeforeSelection },
		{ Name = "TS-TEST-013 controller identity events", Callback = TS_TEST_013_ControllerIdentityEvents },
		{ Name = "TS-TEST-015 client bootstrap composition", Callback = TS_TEST_015_ClientBootstrapComposition },
	}, 8)
end

return UiSystemTestRunner
