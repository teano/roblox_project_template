--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local InviteFriendsWindowView = require(ReplicatedStorage.Client.UI.Windows.InviteFriendsWindowView)
local WindowTypes = require(ReplicatedStorage.Client.UI.Config.WindowTypes)

type UiVoidResult = WindowTypes.UiVoidResult
type BaseWindowViewContract = WindowTypes.BaseWindowView
type WindowConstructionContext = WindowTypes.WindowConstructionContext
type ViewModel = InviteFriendsWindowView.ViewModel

local WINDOW_ID = "game.invite-friends"
local ASSET_KEY = "game.ui.window.invite-friends"

local function createView(root: GuiObject, context: WindowConstructionContext): InviteFriendsWindowView.View
	return InviteFriendsWindowView.new(root, context)
end

local function tryCastView(view: BaseWindowViewContract): InviteFriendsWindowView.View?
	return InviteFriendsWindowView.tryCast(view)
end

local function initializeView(view: InviteFriendsWindowView.View, viewModel: ViewModel): UiVoidResult
	return view:Initialize(viewModel)
end

local definition: WindowTypes.WindowDefinition<InviteFriendsWindowView.View, ViewModel> = {
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
