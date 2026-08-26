--!strict

local BaseWindowView = require(script.Parent.Parent.Parent.Windows.BaseWindowView)
local WindowTypes = require(script.Parent.Parent.WindowTypes)

type UiVoidResult = WindowTypes.UiVoidResult
type BaseWindowViewContract = WindowTypes.BaseWindowView
type WindowConstructionContext = WindowTypes.WindowConstructionContext
type InitializableWindowView = BaseWindowViewContract & {
	Initialize: (self: unknown, viewModel: nil) -> UiVoidResult,
}

local WINDOW_ID = "ui.test.window-asset-fixture"

local function createFixtureView(root: GuiObject, context: WindowConstructionContext): BaseWindowViewContract
	local concrete = BaseWindowView.new(root, WINDOW_ID, "ui.window/asset-fixture", context.Elements) :: any
	return concrete :: BaseWindowViewContract
end

local function tryCastFixtureView(view: BaseWindowViewContract): BaseWindowViewContract?
	if view.WindowId ~= WINDOW_ID then
		return nil
	end
	return view
end

local function initializeFixtureView(view: BaseWindowViewContract, viewModel: nil): UiVoidResult
	local initializable = (view :: any) :: InitializableWindowView
	return initializable.Initialize(initializable, viewModel)
end

local definition: WindowTypes.WindowDefinition<BaseWindowViewContract, nil> = {
	WindowId = WINDOW_ID,
	AssetId = 1001,
	CreateView = createFixtureView,
	TryCastView = tryCastFixtureView,
	InitializeView = initializeFixtureView,
	LifecyclePolicy = "Destroy",
	VisibilityPolicy = "KeepBelow",
	BackgroundPolicy = "Absorb",
	Preload = false,
}

return definition
