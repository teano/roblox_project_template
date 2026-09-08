--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GroupInviteWindowView = require(ReplicatedStorage.Client.UI.Windows.GroupInviteWindowView)
local WindowTypes = require(ReplicatedStorage.Client.UI.Config.WindowTypes)

type UiVoidResult = WindowTypes.UiVoidResult
type BaseWindowViewContract = WindowTypes.BaseWindowView
type WindowConstructionContext = WindowTypes.WindowConstructionContext
type ViewModel = GroupInviteWindowView.ViewModel

local WINDOW_ID = "game.group-invite"
local ASSET_KEY = "game.ui.window.group-invite"

local function createView(root: GuiObject, context: WindowConstructionContext): GroupInviteWindowView.View
	return GroupInviteWindowView.new(root, context)
end

local function tryCastView(view: BaseWindowViewContract): GroupInviteWindowView.View?
	return GroupInviteWindowView.tryCast(view)
end

local function initializeView(view: GroupInviteWindowView.View, viewModel: ViewModel): UiVoidResult
	return view:Initialize(viewModel)
end

local definition: WindowTypes.WindowDefinition<GroupInviteWindowView.View, ViewModel> = {
	WindowId = WINDOW_ID,
	AssetKey = ASSET_KEY,
	CreateView = createView,
	TryCastView = tryCastView,
	InitializeView = initializeView,
	LifecyclePolicy = "Destroy",
	VisibilityPolicy = "KeepBelow",
	BackgroundPolicy = "Absorb",
	Preload = false,
}

return table.freeze(definition)
