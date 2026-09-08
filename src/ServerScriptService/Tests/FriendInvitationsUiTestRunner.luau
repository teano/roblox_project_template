--!strict

--[[
	require(game.ServerScriptService.Tests.FriendInvitationsUiTestRunner).runAll()
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local FriendInvitationsUiController =
	require(ReplicatedStorage.Client.UI.FriendInvitations.FriendInvitationsUiController)
local InviteFriendsWindowDefinition = require(ReplicatedStorage.Client.UI.Config.Definitions.InviteFriendsWindowDefinition)
local GroupInviteWindowDefinition = require(ReplicatedStorage.Client.UI.Config.Definitions.GroupInviteWindowDefinition)
local TemplateWindowConfig = require(ReplicatedStorage.Client.UI.Config.TemplateWindowConfig)
local InviteFriendsWindowView = require(ReplicatedStorage.Client.UI.Windows.InviteFriendsWindowView)
local GroupInviteWindowView = require(ReplicatedStorage.Client.UI.Windows.GroupInviteWindowView)
local GroupInviteWindowPrefabValidator = require(ReplicatedStorage.Shared.UI.GroupInviteWindowPrefabValidator)
local UiSystem = require(ReplicatedStorage.Client.UI.UiSystem)
local PoolModule = require(ReplicatedStorage.Shared.Pooling.PoolModule)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local TestHarness = require(script.Parent.TestHarness)

local Runner = {}

local function equal(actual: any, expected: any, message: string?)
	if actual ~= expected then
		error(`{message or "assertEqual"}: expected={tostring(expected)} actual={tostring(actual)}`, 2)
	end
end

local function truthy(value: any, message: string)
	if not value then
		error(message, 2)
	end
end

local function snapshot(overrides: any?): any
	local value = {
		Min = 1,
		Max = 3,
		Current = 3,
		ConnectedCount = 0,
		CanCreateReserve = true,
		IsSlotOwner = true,
		ConnectedUserIds = {},
		Reserves = {},
		IncomingOffer = nil,
	}
	for key, item in overrides or {} do
		value[key] = item
	end
	return value
end

local function authored(className: string, name: string, parent: Instance?): Instance
	local instance = Instance.new(className)
	instance.Name = name
	instance:SetAttribute("AuthoredPhysicalNode", true)
	instance.Parent = parent
	return instance
end

local function makePhysicalWindowPrefab(): Frame
	local root = authored("Frame", "InviteFriendsWindow", nil) :: Frame
	local background = authored("TextButton", "Background", root) :: TextButton
	background.Size = UDim2.fromScale(1, 1)
	background.ZIndex = 0
	local content = authored("Frame", "Content", root) :: Frame
	content.Size = UDim2.fromScale(1, 1)
	local panel = authored("Frame", "Panel", content) :: Frame
	panel.BackgroundColor3 = Color3.fromRGB(30, 34, 45)
	panel.Size = UDim2.new(0.9, 0, 0.82, 0)
	authored("UISizeConstraint", "UISizeConstraint", panel)
	local title = authored("TextLabel", "Title", panel) :: TextLabel
	title.Text = "Invite Friends 0/0"
	title.Position = UDim2.fromOffset(18, 10)
	title.Size = UDim2.new(1, -88, 0, 34)
	local close = authored("ImageButton", "Close", panel) :: ImageButton
	close.ImageTransparency = 1
	close.AnchorPoint = Vector2.new(1, 0)
	close.Position = UDim2.new(1, -18, 0, 10)
	close.Size = UDim2.fromOffset(40, 40)
	authored("Frame", "IconLine1", close)
	authored("Frame", "IconLine2", close)
	local summaryRow = authored("Frame", "SummaryRow", panel) :: Frame
	summaryRow.Position = UDim2.fromOffset(18, 52)
	summaryRow.Size = UDim2.new(1, -36, 0, 28)
	local friendsOnline = authored("TextLabel", "FriendsOnline", summaryRow) :: TextLabel
	friendsOnline.Text = "Friends online 0/0"
	friendsOnline.Size = UDim2.new(1, -136, 1, 0)
	local refresh = authored("TextButton", "Refresh", summaryRow) :: TextButton
	refresh.Text = "Refresh"
	refresh.AnchorPoint = Vector2.new(1, 0)
	refresh.Position = UDim2.fromScale(1, 0)
	refresh.Size = UDim2.fromOffset(120, 28)
	refresh.Visible = true

	local list = authored("ScrollingFrame", "FriendsList", panel) :: ScrollingFrame
	list.Active = true
	list.ScrollingEnabled = true
	list.ScrollingDirection = Enum.ScrollingDirection.Y
	list.ClipsDescendants = true
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.CanvasSize = UDim2.new(0, 0, 0, 0)
	list.Position = UDim2.fromOffset(18, 90)
	list.Size = UDim2.new(1, -36, 1, -142)
	local status = authored("TextLabel", "Status", list) :: TextLabel
	status.Text = "Loading friends…"
	status.Size = UDim2.fromScale(1, 1)
	local noSlots = authored("TextLabel", "NoSlots", list) :: TextLabel
	noSlots.Text = "No slots available"
	noSlots.Visible = false
	noSlots.Size = UDim2.fromScale(1, 1)
	local rows = authored("Frame", "Rows", list) :: Frame
	rows.AutomaticSize = Enum.AutomaticSize.Y
	rows.Size = UDim2.new(1, 0, 0, 0)
	authored("UIListLayout", "UIListLayout", rows)
	local rowTemplate = authored("Frame", "FriendRowTemplate", rows) :: Frame
	rowTemplate.Visible = false
	rowTemplate.BackgroundTransparency = 0.37
	rowTemplate.Size = UDim2.new(1, 0, 0, 76)
	local avatar = authored("ImageLabel", "Avatar", rowTemplate) :: ImageLabel
	avatar.Image = "rbxasset://textures/ui/GuiImagePlaceholder.png"
	avatar.ImageColor3 = Color3.fromRGB(173, 181, 199)
	authored("TextLabel", "DisplayName", rowTemplate)
	authored("TextLabel", "Username", rowTemplate)
	local presenceIndicator = authored("Frame", "PresenceIndicator", rowTemplate) :: Frame
	authored("UICorner", "UICorner", presenceIndicator)
	authored("TextLabel", "Presence", rowTemplate)
	authored("TextLabel", "State", rowTemplate)
	local invite = authored("TextButton", "Invite", rowTemplate) :: TextButton
	invite.Text = "Invite"

	local pages = authored("Frame", "Pages", panel) :: Frame
	pages.AnchorPoint = Vector2.new(0.5, 1)
	pages.Position = UDim2.new(0.5, 0, 1, -10)
	pages.Size = UDim2.new(1, -36, 0, 32)
	local pagesLayout = authored("UIListLayout", "UIListLayout", pages) :: UIListLayout
	pagesLayout.FillDirection = Enum.FillDirection.Horizontal
	local back = authored("TextButton", "Back", pages) :: TextButton
	back.Text = "Back"
	local first = authored("TextButton", "First", pages) :: TextButton
	first.Text = "1"
	local leading = authored("TextLabel", "LeadingEllipsis", pages) :: TextLabel
	leading.Text = "…"
	local current = authored("TextLabel", "CurrentPage", pages) :: TextLabel
	current.Text = "1"
	local trailing = authored("TextLabel", "TrailingEllipsis", pages) :: TextLabel
	trailing.Text = "…"
	local last = authored("TextButton", "Last", pages) :: TextButton
	last.Text = "1"
	local next = authored("TextButton", "Next", pages) :: TextButton
	next.Text = "Next"
	return root
end

local function makePhysicalHudTemplate(): TextButton
	local button = authored("TextButton", "InviteFriends", nil) :: TextButton
	button.Active = true
	button.AnchorPoint = Vector2.new(0.5, 0)
	button.AutoButtonColor = true
	button.BackgroundColor3 = Color3.fromRGB(52, 98, 184)
	button.BorderSizePixel = 0
	button.Position = UDim2.new(0.5, 79, 0, 18)
	button.Size = UDim2.fromOffset(156, 42)
	button.Text = "invite"
	button.Font = Enum.Font.GothamBold
	button.TextColor3 = Color3.fromRGB(255, 255, 255)
	button.TextSize = 18
	button.TextXAlignment = Enum.TextXAlignment.Left
	local padding = authored("UIPadding", "UIPadding", button) :: UIPadding
	padding.PaddingLeft = UDim.new(0, 12)
	padding.PaddingRight = UDim.new(0, 48)
	local capacity = authored("TextLabel", "Capacity", button) :: TextLabel
	capacity.AnchorPoint = Vector2.new(1, 0.5)
	capacity.BackgroundTransparency = 1
	capacity.Font = Enum.Font.GothamBold
	capacity.Position = UDim2.new(1, -10, 0.5, 0)
	capacity.Size = UDim2.fromOffset(42, 22)
	capacity.Text = "0/0"
	capacity.TextColor3 = Color3.fromRGB(255, 255, 255)
	capacity.TextSize = 15
	return button
end

local function makePhysicalGroupInviteWindow(): Frame
	local root = authored("Frame", "GroupInviteWindow", nil) :: Frame
	root:SetAttribute("AssetKey", "game.ui.window.group-invite")
	root.Size = UDim2.fromScale(1, 1)
	local background = authored("TextButton", "Background", root) :: TextButton
	background.Size = UDim2.fromScale(1, 1)
	local content = authored("Frame", "Content", root) :: Frame
	content.Size = UDim2.fromScale(1, 1)
	local panel = authored("Frame", "Panel", content) :: Frame
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.new(0.72, 0, 0, 260)
	local constraint = authored("UISizeConstraint", "UISizeConstraint", panel) :: UISizeConstraint
	constraint.MinSize = Vector2.new(320, 260)
	constraint.MaxSize = Vector2.new(560, 260)
	authored("UICorner", "UICorner", panel)
	authored("UIStroke", "UIStroke", panel)
	authored("TextLabel", "Title", panel)
	authored("TextLabel", "Message", panel)
	authored("TextLabel", "Countdown", panel)
	local actions = authored("Frame", "Actions", panel) :: Frame
	local layout = authored("UIListLayout", "UIListLayout", actions) :: UIListLayout
	layout.FillDirection = Enum.FillDirection.Horizontal
	local decline = authored("TextButton", "Decline", actions) :: TextButton
	decline.Size = UDim2.new(0.46, -6, 1, 0)
	local accept = authored("TextButton", "Accept", actions) :: TextButton
	accept.Size = UDim2.new(0.46, -6, 1, 0)
	return root
end

local function presentation(mode: string, rows: { any }?): any
	return {
		Mode = mode,
		TitleText = "Invite Friends 1/3",
		FriendsOnlineText = "Friends online 1/2",
		IsFull = false,
		CanRefresh = true,
		Rows = rows or {},
		CurrentPage = 1,
		PageCount = 1,
		CanGoBack = false,
		CanGoNext = false,
		CanGoFirst = false,
		CanGoLast = false,
		ShowLeadingEllipsis = false,
		ShowTrailingEllipsis = false,
		ResetScroll = false,
	}
end

local function makeElementContext(): any
	local claims = {} :: { [string]: any }
	return {
		ClaimSubtree = function(_self: any, requested: { any })
			for _, claim in requested do
				if claims[claim.UIElementId] ~= nil then
					return { Kind = "Error", Error = { Code = "DuplicateUIElementId" } }
				end
			end
			for _, claim in requested do
				claims[claim.UIElementId] = claim.Owner
			end
			return { Kind = "Success" }
		end,
		ReleaseSubtree = function(_self: any, released: { any })
			for _, claim in released do
				if claims[claim.UIElementId] == claim.Owner then
					claims[claim.UIElementId] = nil
				end
			end
			return { Kind = "Success" }
		end,
		DeliverToRoot = function() return { Kind = "Success" } end,
	}
end

local function makePhysicalView(scope: TestHarness.Scope, root: Frame, initialPresentation: any): any
	local view = InviteFriendsWindowView.new(root, {
		Navigator = {},
		Elements = makeElementContext(),
	})
	view:_SetNavigatorBinding({}, {
		CanEmitAction = function() return true end,
		GetGuiService = function()
			return { SelectedObject = nil }
		end,
	})
	scope:Defer(function()
		view:Clear()
	end)
	local result = view:Initialize({
		GetPresentation = function()
			return initialPresentation
		end,
	})
	equal(result.Kind, "Success", "physical view initialization must succeed")
	view:_SetNavigationActive(true)
	return view
end

local function makeFixture(scope: TestHarness.Scope, initial: any, friendsPages: any?, options: any?)
	local resolvedOptions = options or {}
	local hudTemplate = resolvedOptions.HudAsset or scope:Track(makePhysicalHudTemplate())
	local assetKeys = {}
	local assets = resolvedOptions.Assets or {
		RequireByKey = function(_self: any, key: string, expectedClass: string)
			table.insert(assetKeys, key)
			equal(key, "game.ui.hud.invite-friends", "HUD must resolve its canonical physical AssetKey")
			equal(expectedClass, "TextButton")
			return hudTemplate
		end,
	}
	local events = Signal.new()
	local snapshotChanged = Signal.new()
	local promptChanged = Signal.new()
	local refreshSucceeded = Signal.new()
	local frame = scope:Track(Instance.new("BindableEvent")) :: BindableEvent
	local host = scope:Track(Instance.new("Frame")) :: Frame
	local currentSnapshot = initial
	local prompt = table.freeze({ IsBusy = false, Phase = "Idle" })
	local serverTime = 100
	local renders = {} :: { any }
	local groupRenders = {} :: { any }
	local groupCloseCount = 0
	local groupActive = true
	local refreshNotifications = 0
	local groupView = {
		Render = function(_self: any, presentation: any)
			table.insert(groupRenders, presentation)
		end,
		GetAction = function(_self: any, id: string)
			if id == "game.window/group-invite/accept" then return "accept" end
			if id == "game.window/group-invite/decline" then return "decline" end
			return nil
		end,
		CloseWindowAsync = function()
			groupCloseCount += 1
			return { Kind = "Success" }
		end,
	}
	local groupHandle = {
		IsValid = function() return true end,
		IsActiveWindow = function() return groupActive end,
		GetView = function() return { Kind = "Success", Value = groupView } end,
	}
	local claimCount = 0
	local fakeView = {
		Render = function(_self: any, presentation: any)
			table.insert(renders, presentation)
		end,
		GetAction = function(_self: any, id: string)
			if id == "game.window/invite-friends/next" then
				return "next", nil
			end
			return nil, nil
		end,
		CloseWindowAsync = function() return { Kind = "Success" } end,
		AddWindowTypedAsync = function(_self: any, definition: any, model: any)
			equal(definition, GroupInviteWindowDefinition)
			truthy(typeof(model.GetPresentation) == "function", "group window model must supply presentation")
			return resolvedOptions.GroupOpenResult or { Kind = "Success", Value = groupHandle }
		end,
	}
	local fakeHandle = {
		IsValid = function() return true end,
		IsActiveWindow = function() return true end,
		GetView = function() return { Kind = "Success", Value = fakeView } end,
	}
	local context = {
		ClaimSubtree = function(_self: any, _claims: any)
			claimCount += 1
			return { Kind = "Success" }
		end,
		ReleaseSubtree = function(_self: any, _claims: any) return { Kind = "Success" } end,
		DeliverToRoot = function(_self: any, _event: any) return { Kind = "Success" } end,
	}
	local ui = {
		Events = events,
		GetHudHost = function() return host end,
		GetUiElementContext = function() return context end,
		AddWindowTypedAsync = function(_self: any, definition: any, model: any)
			truthy(typeof(model.GetPresentation) == "function", "window model must supply presentation")
			if definition == GroupInviteWindowDefinition then
				return resolvedOptions.GroupOpenResult or { Kind = "Success", Value = groupHandle }
			end
			equal(definition, InviteFriendsWindowDefinition, "window must use the canonical definition")
			return resolvedOptions.OpenResult or { Kind = "Success", Value = fakeHandle }
		end,
	}
	local friends = {
		SnapshotChanged = snapshotChanged,
		PromptStateChanged = promptChanged,
		RefreshSucceeded = refreshSucceeded,
		GetSnapshot = function() return { Ok = true, Snapshot = currentSnapshot } end,
		GetPromptState = function() return prompt end,
		RequestInvite = resolvedOptions.RequestInvite or function(_self: any, _userId: number, callback: any)
			callback("PromptRequested")
			return { Ok = true }
		end,
		RespondToLocalOffer = resolvedOptions.RespondToLocalOffer or function(_self: any, _offerId: string, _decision: string, callback: any)
			callback("Declined")
			return { Ok = true }
		end,
		NotifyRefreshSucceeded = function()
			refreshNotifications += 1
			refreshSucceeded:Fire()
		end,
	}
	local controller = FriendInvitationsUiController.new({
		UI = ui,
		Assets = assets,
		Friends = friends,
		PlayersModule = { GetLocalPlayer = function() return { UserId = 17 } :: any end },
		PlayersService = {},
		StarterGui = { SetCore = function() end },
		Workspace = { GetServerTimeNow = function() return serverTime end },
		FrameSignal = frame.Event,
		GetFriends = resolvedOptions.GetFriends or function(_userId: number)
			return friendsPages or {
				IsFinished = true,
				GetCurrentPage = function() return {} end,
			}
		end,
		GetFriendsOnline = resolvedOptions.GetFriendsOnline or function(_player: Player, _amount: number) return {} end,
		GetThumbnail = function(_userId: number) return "", false end,
		Spawn = resolvedOptions.Spawn,
		Defer = resolvedOptions.Defer,
		Logger = resolvedOptions.Logger,
	})
	scope:Defer(function()
		controller:Stop()
		events:Destroy()
		snapshotChanged:Destroy()
		promptChanged:Destroy()
		refreshSucceeded:Destroy()
	end)
	return controller, {
		Host = host,
		SetSnapshot = function(value: any)
			local previous = currentSnapshot
			currentSnapshot = value
			snapshotChanged:Fire({ Previous = previous, Current = value })
		end,
		SetPrompt = function(value: any)
			prompt = value
			promptChanged:Fire({})
		end,
		SetServerTime = function(value: number)
			serverTime = value
		end,
		Renders = renders,
		Frame = frame,
		Events = events,
		HudAsset = hudTemplate,
		AssetKeys = assetKeys,
		GroupRenders = groupRenders,
		View = fakeView,
		GetGroupCloseCount = function() return groupCloseCount end,
		SetGroupActive = function(value: boolean) groupActive = value end,
		GetRefreshNotifications = function() return refreshNotifications end,
		GetClaimCount = function() return claimCount end,
	}
end

local function renderPresenceRow(scope: TestHarness.Scope, presence: "Online" | "Offline"): (Frame, number)
	local root = scope:Track(makePhysicalWindowPrefab())
	local view = makePhysicalView(scope, root, presentation("Empty", {}))
	view:Render(presentation("List", { {
		UserId = 22,
		DisplayName = "Friend",
		Username = "friend",
		Presence = presence,
		State = "Can invite",
		CanInvite = true,
	} }))
	local rows = ((root.Content :: Frame).Panel.FriendsList :: ScrollingFrame).Rows :: Frame
	local renderedRows = 0
	for _, child in rows:GetChildren() do
		if child:IsA("Frame") and child.Name ~= "FriendRowTemplate" then
			renderedRows += 1
		end
	end
	return rows:FindFirstChild("Friend22") :: Frame, renderedRows
end

function Runner.runAll()
	local tests = {}
	local function test(name: string, callback: (TestHarness.Scope) -> ())
		table.insert(tests, { Name = name, Callback = callback })
	end

	test("TS-FI-004 HUD follows only the owner snapshot and capacity projection", function(scope)
		local controller, fixture = makeFixture(scope, snapshot({ Current = 2, ConnectedCount = 1, Reserves = {
			{ TargetUserId = 22, ExpiresAtServerTime = 300, Kind = "Native" },
		} }), nil)
		controller:Initialize()
		local button = fixture.Host:FindFirstChild("InviteFriends") :: TextButton
		truthy(button ~= nil and button.Visible, "slot owner must receive the single HUD invitation button")
		equal(button.Text, "invite")
		equal((button:FindFirstChild("Capacity") :: TextLabel).Text, "2/2")
		fixture.SetSnapshot(snapshot({ IsSlotOwner = false, Current = 2 }))
		equal(button.Visible, false, "non-owner HUD button must remain created but hidden")
		controller:Initialize()
		equal(#fixture.Host:GetChildren(), 1, "repeated Initialize must preserve one physical HUD clone")
		equal(fixture.GetClaimCount(), 1, "repeated Initialize must preserve one HUD identity claim")
		equal(#fixture.AssetKeys, 1, "repeated Initialize must not repeat the physical HUD catalog lookup")
	end)

	test("TS-FI-023 physical HUD clone preserves authored properties and Stop preserves the template", function(scope)
		local catalogRoot = scope:Track(Instance.new("Folder")) :: Folder
		local template = scope:Track(makePhysicalHudTemplate())
		template.BackgroundColor3 = Color3.fromRGB(17, 29, 43)
		template:SetAttribute("DesignerMarker", "physical-hud")
		template.Parent = catalogRoot
		local controller, fixture = makeFixture(scope, snapshot(), nil, { HudAsset = template })
		controller:Initialize()
		local clone = fixture.Host:FindFirstChild("InviteFriends") :: TextButton
		truthy(clone ~= nil and clone ~= template, "HUD must be a clone of the physical template")
		equal(clone.BackgroundColor3, Color3.fromRGB(17, 29, 43), "authored HUD color must survive cloning")
		equal(clone:GetAttribute("DesignerMarker"), "physical-hud", "authored HUD attributes must survive cloning")
		controller:Stop()
		equal(fixture.Host:FindFirstChild("InviteFriends"), nil, "Stop must destroy only the runtime HUD clone")
		truthy(template.Parent == catalogRoot, "Stop must preserve the catalog-owned physical template in place")
		equal(template:GetAttribute("DesignerMarker"), "physical-hud", "Stop must not mutate the template")
	end)

	test("TS-FI-024 malformed or executable physical HUD fails before parenting and registration", function(scope)
		local candidates = {}
		local missing = makePhysicalHudTemplate()
		missing.Capacity:Destroy()
		table.insert(candidates, { Root = missing, Code = "PrefabMalformed" })
		local wrong = Instance.new("Frame")
		wrong.Name = "InviteFriends"
		table.insert(candidates, { Root = wrong, Code = "PrefabMalformed" })
		local duplicate = makePhysicalHudTemplate()
		authored("TextLabel", "Capacity", duplicate)
		table.insert(candidates, { Root = duplicate, Code = "PrefabMalformed" })
		local executable = makePhysicalHudTemplate()
		authored("ModuleScript", "Executable", executable)
		table.insert(candidates, { Root = executable, Code = "ForbiddenExecutableDescendant" })
		local uncloneable = makePhysicalHudTemplate()
		uncloneable.Archivable = false
		table.insert(candidates, { Root = uncloneable, Code = "PrefabMalformed" })
		for _, candidate in candidates do
			scope:Track(candidate.Root)
			local controller, fixture = makeFixture(scope, snapshot(), nil, { HudAsset = candidate.Root })
			local ok, message = pcall(function() controller:Initialize() end)
			equal(ok, false, "malformed HUD template must fail closed")
			truthy(string.find(tostring(message), candidate.Code, 1, true) ~= nil,
				"malformed HUD failure must preserve its stable classification")
			equal(#fixture.Host:GetChildren(), 0, "malformed HUD must fail before parenting")
			equal(fixture.GetClaimCount(), 0, "malformed HUD must fail before identity registration")
		end
	end)

	test("TS-FI-005 list cache is complete, sorted, and shared by repeat opening", function(scope)
		local pages = {
			IsFinished = true,
			GetCurrentPage = function()
				return {
					{ Id = 40, Username = "zeta", DisplayName = "Zeta" },
					{ Id = 20, Username = "beta", DisplayName = "Beta" },
					{ Id = 30, Username = "alpha", DisplayName = "Alpha" },
				}
			end,
		}
		local controller = makeFixture(scope, snapshot(), pages)
		controller:Initialize()
		controller:_openWindow()
		local deadline = os.clock() + 1
		while controller._cache == nil and os.clock() < deadline do
			task.wait()
		end
		truthy(controller._cache ~= nil, "first list load did not publish an atomic cache")
		equal(#controller._cache, 3)
		equal(controller._cache[1].UserId, 30)
		equal(controller._cache[2].UserId, 20)
		equal(controller._cache[3].UserId, 40)
		controller:_openWindow()
		equal(#controller._cache, 3, "repeat open must retain the same session cache")
	end)

	test("TS-FI-006 row projection preserves authoritative priority and allows native reserve retries", function(scope)
		local controller, fixture = makeFixture(scope, snapshot({ Reserves = {
			{ TargetUserId = 22, ExpiresAtServerTime = 100, Kind = "Native" },
		} }), nil)
		controller:Initialize()
		local entry = { UserId = 22, Username = "friend", DisplayName = "Friend", Presence = "Online" } :: any
		local opening = controller:_rowFor(entry, controller._snapshot, {
			IsBusy = true, Phase = "OpeningRoblox", TargetUserId = 22,
		})
		equal(opening.State, "Checking status", "an API check must not claim that a native window is visible")
		equal(opening.Countdown, "00:00")
		equal(opening.CanInvite, false)
		local first = controller:_rowFor(entry, controller._snapshot, { IsBusy = false, Phase = "Idle" })
		equal(first.State, "Waiting for friend · slot held")
		equal(first.Countdown, "00:00")
		equal(first.CanInvite, true)
		local second = controller:_rowFor(entry, controller._snapshot, { IsBusy = false, Phase = "Idle" })
		equal(second.State, "Waiting for friend · slot held")
		equal(second.Countdown, "00:00")
		equal(second.CanInvite, true, "native reserve must allow another prompt")
		fixture.SetSnapshot(snapshot({ ConnectedCount = 1, ConnectedUserIds = { 22 }, Reserves = {
			{ TargetUserId = 22, ExpiresAtServerTime = 200, Kind = "Native" },
		} }))
		local connected = controller:_rowFor(entry, controller._snapshot, { IsBusy = true, Phase = "OpeningRoblox", TargetUserId = 22 })
		equal(connected.State, "Connected", "connection must outrank prompt and reserve state")
	end)

	test("TS-FI-010 sent reserve keeps its countdown and allows retries before authoritative removal", function(scope)
		local controller, fixture = makeFixture(scope, snapshot({ Reserves = {
			{ TargetUserId = 22, ExpiresAtServerTime = 100, Kind = "Native" },
		} }), nil)
		controller:Initialize()
		local entry = { UserId = 22, Username = "friend", DisplayName = "Friend", Presence = "Online" } :: any
		local first = controller:_rowFor(entry, controller._snapshot, { IsBusy = false, Phase = "Idle" })
		equal(first.State, "Waiting for friend · slot held")
		equal(first.Countdown, "00:00", "the expired authoritative reserve must expose zero")
		equal(first.CanInvite, true)
		local second = controller:_rowFor(entry, controller._snapshot, { IsBusy = false, Phase = "Idle" })
		equal(second.Countdown, "00:00", "the authoritative reserve must remain stable")
		local third = controller:_rowFor(entry, controller._snapshot, { IsBusy = false, Phase = "Idle" })
		equal(third.Countdown, "00:00", "an unchanged authoritative snapshot must retain its countdown")
		fixture.SetSnapshot(snapshot({ Reserves = {
			{ TargetUserId = 22, ExpiresAtServerTime = 200, Kind = "Native" },
		} }))
		local refreshed = controller:_rowFor(entry, controller._snapshot, { IsBusy = false, Phase = "Idle" })
		equal(refreshed.State, "Waiting for friend · slot held")
		equal(refreshed.Countdown, "01:40")
		fixture.SetServerTime(200)
		local expiredAgain = controller:_rowFor(entry, controller._snapshot, { IsBusy = false, Phase = "Idle" })
		equal(expiredAgain.Countdown, "00:00")
		fixture.SetSnapshot(snapshot())
		local available = controller:_rowFor(entry, controller._snapshot, { IsBusy = false, Phase = "Idle" })
		equal(available.State, "Can invite")
		equal(available.CanInvite, true, "online friend must unlock after authoritative reserve removal")
	end)

	test("native reserve retry dispatches at full capacity and respects temporary blockers", function(scope)
		local requests = 0
		local controller = makeFixture(scope, snapshot({ Current = 1, Reserves = {
			{ TargetUserId = 22, ExpiresAtServerTime = 200, Kind = "Native" },
		} }), nil, { RequestInvite = function(_self, userId)
			equal(userId, 22)
			requests += 1
			return { Ok = true }
		end })
		controller:Initialize()
		local entry = { UserId = 22, Username = "friend", DisplayName = "Friend", Presence = "Online" } :: any
		controller._cache = { entry }
		controller:_requestInvite(22)
		equal(requests, 1, "full reserved capacity blocked repeat button dispatch")
		controller._loading = true
		controller:_requestInvite(22)
		equal(requests, 1)
		controller._loading = false
		entry.Presence = "Offline"
		controller:_requestInvite(22)
		equal(requests, 1)
		entry.Presence = "Online"
		local busy = controller:_rowFor(entry, controller._snapshot, { IsBusy = true, TargetUserId = 33 })
		equal(busy.CanInvite, false)
	end)

	test("TS-FI-026 offline friends never expose or dispatch Invite", function(scope)
		local requests = 0
		local controller = makeFixture(scope, snapshot(), nil, {
			RequestInvite = function()
				requests += 1
				return { Ok = true }
			end,
		})
		controller:Initialize()
		controller._cache = { { UserId = 22, Username = "friend", DisplayName = "Friend", Presence = "Offline" } }
		local row = controller:_rowFor(controller._cache[1], controller._snapshot, { IsBusy = false, Phase = "Idle" })
		equal(row.State, "Offline")
		equal(row.CanInvite, false)
		controller:_requestInvite(22)
		equal(requests, 0, "offline friend must not reach FriendsClient.RequestInvite")
	end)

	test("TS-FI-011 successful row registration renders separate online and offline presence indicators", function(scope)
		local onlineRow, onlineRegistrations = renderPresenceRow(scope, "Online")
		equal(onlineRegistrations, 1, "one friend must produce one clone of the physical row template")
		local onlineIndicator = onlineRow:FindFirstChild("PresenceIndicator")
		local onlineLabel = onlineRow:FindFirstChild("Presence")
		truthy(onlineIndicator ~= nil and onlineIndicator:IsA("Frame"), "online row must contain a separate presence indicator")
		truthy(onlineLabel ~= nil and onlineLabel:IsA("TextLabel"), "online row must retain its presence label")
		equal((onlineIndicator :: Frame).BackgroundColor3, Color3.fromRGB(104, 220, 136))
		equal((onlineLabel :: TextLabel).Text, "Online")

		local offlineRow, offlineRegistrations = renderPresenceRow(scope, "Offline")
		equal(offlineRegistrations, 1, "one friend must produce one clone of the physical row template")
		local offlineIndicator = offlineRow:FindFirstChild("PresenceIndicator")
		local offlineLabel = offlineRow:FindFirstChild("Presence")
		truthy(offlineIndicator ~= nil and offlineIndicator:IsA("Frame"), "offline row must contain a separate presence indicator")
		truthy(offlineLabel ~= nil and offlineLabel:IsA("TextLabel"), "offline row must retain its presence label")
		equal((offlineIndicator :: Frame).BackgroundColor3, Color3.fromRGB(180, 185, 200))
		equal((offlineLabel :: TextLabel).Text, "Offline")
	end)

	test("TS-FI-027 Refresh remains visible and is disabled for foreground and background loads", function(scope)
		local root = scope:Track(makePhysicalWindowPrefab())
		local initial = presentation("Loading", {})
		initial.CanRefresh = false
		local view = makePhysicalView(scope, root, initial)
		local panel = (root.Content :: Frame).Panel :: Frame
		local summaryRow = panel.SummaryRow :: Frame
		local refresh = summaryRow.Refresh :: TextButton
		local close = panel.Close :: ImageButton
		local guiService = view._navigationRegistry._guiService
		guiService.SelectedObject = refresh
		view:Render(initial)
		equal(guiService.SelectedObject, close,
			"disabling selected Refresh must move focus to the eligible Close default")
		equal(refresh.Interactable, false)
		view:_SetNavigationActive(false)
		view:_SetNavigationActive(true)
		equal(refresh.Interactable, false,
			"navigation pause/resume must not restore authored interactability during loading")
		equal(guiService.SelectedObject, close, "pause/resume must not reselect disabled Refresh")
		for _, mode in { "Loading", "LoadError", "Empty", "List" } do
			local model = presentation(mode, {})
			model.CanRefresh = mode ~= "Loading"
			view:Render(model)
			equal(refresh.Visible, true, `Refresh must stay visible in {mode}`)
			equal(refresh.Interactable, model.CanRefresh, `Refresh interactability mismatch in {mode}`)
		end
		local background = presentation("List", {})
		background.CanRefresh = false
		view:Render(background)
		equal(refresh.Visible, true)
		equal(refresh.Interactable, false, "background refresh must disable the same physical button")
		local ready = presentation("List", {})
		view:Render(ready)
		equal(refresh.Interactable, true, "completed load must restore dynamic Refresh eligibility")
	end)

	test("TS-FI-029 physical header summary list footer and scrolling contract remain non-overlapping", function(scope)
		local root = scope:Track(makePhysicalWindowPrefab())
		local rows = {}
		for userId = 1, 3 do
			table.insert(rows, {
				UserId = userId, DisplayName = `Friend {userId}`, Username = `friend{userId}`,
				Presence = "Online", State = "Can invite", CanInvite = true,
			})
		end
		local model = presentation("List", rows)
		model.TitleText = "Invite Friends 2/4"
		model.FriendsOnlineText = "Friends online 3/7"
		local view = makePhysicalView(scope, root, model)
		local panel = (root.Content :: Frame).Panel :: Frame
		local title = panel.Title :: TextLabel
		local summaryRow = panel.SummaryRow :: Frame
		local friendsOnline = summaryRow.FriendsOnline :: TextLabel
		local refresh = summaryRow.Refresh :: TextButton
		local list = panel.FriendsList :: ScrollingFrame
		local listRows = list.Rows :: Frame
		local pages = panel.Pages :: Frame
		equal(title.Text, "Invite Friends 2/4")
		equal(friendsOnline.Text, "Friends online 3/7")
		equal(refresh.Parent, summaryRow, "Refresh must remain inline in the physical summary row")
		equal(panel:FindFirstChild("Capacity"), nil, "window must not retain a separate capacity label")
		equal(panel:FindFirstChild("Retry"), nil, "window must not retain the obsolete Retry control")
		equal(list:FindFirstChildOfClass("UIListLayout"), nil,
			"FriendsList viewport must not contain a competing layout")
		equal(listRows.AutomaticSize, Enum.AutomaticSize.Y)
		equal(listRows.Size.Y, UDim.new(0, 0))
		equal(list.AutomaticCanvasSize, Enum.AutomaticSize.Y)
		equal(list.CanvasSize, UDim2.new(0, 0, 0, 0))
		equal(list.ScrollingDirection, Enum.ScrollingDirection.Y)
		truthy(list.Active and list.ScrollingEnabled and list.ClipsDescendants,
			"physical viewport must accept wheel, touch, and gamepad scrolling")
		equal(#listRows:GetChildren(), 5, "three rows must coexist with physical template and Rows layout")
		truthy(summaryRow.Position.Y.Offset + summaryRow.Size.Y.Offset <= list.Position.Y.Offset,
			"summary row must end before the list viewport")
		local listBottomOffset = list.Position.Y.Offset + list.Size.Y.Offset
		local pagesTopOffset = pages.Position.Y.Offset - pages.Size.Y.Offset
		truthy(listBottomOffset <= pagesTopOffset, "list viewport must end before the bottom Pages bar")
		list.CanvasPosition = Vector2.new(0, 24)
		model.ResetScroll = false
		view:Render(model)
		equal(list.CanvasPosition.Y, 24, "ordinary redraw must preserve user scroll position")
		model.ResetScroll = true
		view:Render(model)
		equal(list.CanvasPosition, Vector2.new(0, 0), "explicit page reset must return the viewport to the top")
	end)

	test("TS-FI-028 cached background refresh publishes disabled then enabled Refresh", function(scope)
		local jobs = {}
		local pages = {
			IsFinished = true,
			GetCurrentPage = function()
				return { { Id = 22, Username = "friend", DisplayName = "Friend" } }
			end,
		}
		local controller, fixture = makeFixture(scope, snapshot(), pages, {
			Spawn = function(callback: () -> ()) table.insert(jobs, callback) end,
		})
		controller:Initialize()
		controller._cache = { { UserId = 22, Username = "friend", DisplayName = "Friend", Presence = "Online" } }
		controller:_openWindow()
		equal(#jobs, 1, "background refresh work was not scheduled")
		equal(fixture.Renders[#fixture.Renders].Mode, "List")
		equal(fixture.Renders[#fixture.Renders].CanRefresh, false,
			"cached presentation must disable Refresh while background load is active")
		jobs[1]()
		equal(fixture.Renders[#fixture.Renders].CanRefresh, true,
			"completed background load must re-enable Refresh")
	end)

	test("TS-FI-009 background refresh redraws the replacement without duplicate cached redraw", function(scope)
		local displayName = "Friend"
		local pages = {
			IsFinished = true,
			GetCurrentPage = function()
				return {
					{ Id = 22, Username = "friend", DisplayName = displayName },
				}
			end,
		}
		local controller, fixture = makeFixture(scope, snapshot(), pages)
		controller:Initialize()
		controller:_openWindow()
		local deadline = os.clock() + 1
		while controller._cache == nil and os.clock() < deadline do
			task.wait()
		end
		truthy(controller._cache ~= nil, "friends cache did not load for background refresh")
		local renderCount = #fixture.Renders
		displayName = "Renamed Friend"
		fixture.Events:Fire({ ActionId = "ui.window.closed", WindowId = "game.invite-friends" })
		controller:_openWindow()
		deadline = os.clock() + 1
		while (fixture.Renders[#fixture.Renders].Rows[1] == nil or fixture.Renders[#fixture.Renders].Rows[1].DisplayName ~= displayName)
			and os.clock() < deadline do
			task.wait()
		end
		truthy(fixture.Renders[#fixture.Renders].Rows[1] ~= nil and fixture.Renders[#fixture.Renders].Rows[1].DisplayName == displayName,
			"background refresh did not publish the replacement cache")
		equal(#fixture.Renders, renderCount + 2, "background refresh must redraw the cached and replacement presentations without a duplicate cached redraw")
	end)

	test("TS-FI-007 HUD controller action opens the typed window in WindowHost", function(scope)
		equal(InviteFriendsWindowDefinition.WindowId, "game.invite-friends")
		equal(InviteFriendsWindowDefinition.AssetKey, "game.ui.window.invite-friends")
		equal(InviteFriendsWindowDefinition.AssetId, nil,
			"project window must not retain a cloud AssetId alongside its Studio-owned source")
		equal(InviteFriendsWindowDefinition.LifecyclePolicy, "Destroy")
		equal(InviteFriendsWindowDefinition.VisibilityPolicy, "KeepBelow")
		equal(InviteFriendsWindowDefinition.BackgroundPolicy, "Absorb")
		equal(InviteFriendsWindowDefinition.Preload, false)

		local playerGui = scope:Track(Instance.new("Folder")) :: Folder
		playerGui.Name = "PlayerGui"
		local localPlayer = {
			UserId = 17,
			FindFirstChildOfClass = function(_self: any, className: string)
				return if className == "PlayerGui" then playerGui else nil
			end,
		}
		local playersModule = {
			GetLocalPlayer = function()
				return localPlayer
			end,
		}
		local catalogRoot = scope:Track(Instance.new("Folder")) :: Folder
		local template = makePhysicalWindowPrefab()
		local authoredPanel = ((template:FindFirstChild("Content") :: Frame):FindFirstChild("Panel") :: Frame)
		authoredPanel.BackgroundColor3 = Color3.fromRGB(17, 29, 43)
		template.Parent = catalogRoot
		local hudTemplate = makePhysicalHudTemplate()
		hudTemplate.Parent = catalogRoot
		local assetLookups = {}
		local assets = {
			RequireByKey = function(_self: any, key: string, expectedClass: string)
				table.insert(assetLookups, key)
				equal(expectedClass, if key == "game.ui.hud.invite-friends" then "TextButton" else "GuiObject")
				if key == "game.ui.hud.invite-friends" then
					return hudTemplate
				end
				equal(key, "game.ui.window.invite-friends", "window must resolve its canonical physical AssetKey")
				return template
			end,
		}
		local pooling = PoolModule.new()
		pooling:Initialize()
		scope:Defer(function()
			pooling:Destroy()
		end)
		local ui = UiSystem.new({
			PlayersModule = playersModule,
			TemplateWindowDefinitions = { InviteFriendsWindowDefinition },
			Pooling = pooling,
			AssetRegistry = assets,
			ContentPreloader = {
				Preload = function(_self: any, _targets: { Instance }, _options: any)
					return { Failed = 0 }
				end,
			},
			Spawn = function(callback: () -> ())
				callback()
			end,
			Delay = function(_seconds: number, callback: () -> ())
				task.defer(callback)
			end,
		})
		scope:Defer(function()
			ui:Destroy()
		end)
		equal(ui:Initialize().Kind, "Success", "real UI system must initialize the typed definition")
		local openResult: any = nil
		local addWindowTypedAsync = ui.AddWindowTypedAsync
		ui.AddWindowTypedAsync = function(self: any, definition: any, model: any)
			local result = addWindowTypedAsync(self, definition, model)
			openResult = result
			return result
		end

		local snapshotChanged = scope:Track(Signal.new())
		local promptChanged = scope:Track(Signal.new())
		local frame = scope:Track(Instance.new("BindableEvent")) :: BindableEvent
		local activated = scope:Track(Instance.new("BindableEvent")) :: BindableEvent
		local mouseEntered = scope:Track(Instance.new("BindableEvent")) :: BindableEvent
		local mouseLeft = scope:Track(Instance.new("BindableEvent")) :: BindableEvent
		local controller = FriendInvitationsUiController.new({
			UI = ui,
			Assets = assets,
			Friends = {
				SnapshotChanged = snapshotChanged,
				PromptStateChanged = promptChanged,
				GetSnapshot = function()
					return { Ok = true, Snapshot = snapshot() }
				end,
				GetPromptState = function()
					return table.freeze({ IsBusy = false, Phase = "Idle" })
				end,
			},
			PlayersModule = playersModule,
			PlayersService = {},
			StarterGui = { SetCore = function() end },
			Workspace = { GetServerTimeNow = function() return 100 end },
			FrameSignal = frame.Event,
			GetFriends = function()
				return {
					IsFinished = true,
					GetCurrentPage = function() return {} end,
				}
			end,
			GetFriendsOnline = function() return {} end,
			GetThumbnail = function() return "", false end,
			Spawn = function(callback: () -> ())
				callback()
			end,
			HudInputSignals = {
				Activated = activated.Event,
				MouseEnter = mouseEntered.Event,
				MouseLeave = mouseLeft.Event,
			},
		})
		scope:Defer(function()
			controller:Stop()
		end)
		controller:Initialize()

		local root = playerGui:FindFirstChild("UiRoot") :: ScreenGui
		local windowHost = root:FindFirstChild("WindowHost") :: Frame
		local hudActivationEvents = 0
		local eventProbe = ui.Events:Connect(function(event: any)
			if event.ActionId == "ui.button.activated" and event.UIElementId == "game.hud/invite-friends" then
				hudActivationEvents += 1
			end
		end)
		scope:Defer(function()
			eventProbe:Disconnect()
		end)
		equal(#windowHost:GetChildren(), 0, "window host must start empty")
		activated:Fire()
		local deadline = os.clock() + 4
		while #windowHost:GetChildren() == 0 and os.clock() < deadline do
			task.wait()
		end
		equal(hudActivationEvents, 1, "injected GuiButton Activated must emit one canonical HUD action")
		truthy(openResult ~= nil, "HUD action must reach typed window navigation")
		truthy(openResult.Kind == "Success", `typed window navigation failed: {openResult.Error and openResult.Error.Code or "unknown"}`)
		equal(#windowHost:GetChildren(), 1,
			"HUD GuiButton Activated wiring must route through ButtonController and the UI event stream into WindowHost")
		local openedContent = windowHost:GetChildren()[1]:FindFirstChild("Content")
		local panelCount = 0
		for _, child in assert(openedContent):GetChildren() do
			if child.Name == "Panel" then
				panelCount += 1
			end
		end
		equal(panelCount, 1, "runtime view must bind the one physical authored panel")
		local openedPanel = assert(openedContent):FindFirstChild("Panel")
		truthy(openedPanel ~= nil and openedPanel:IsA("Frame"), "physical authored panel must remain in the opened window")
		equal((openedPanel :: Frame).BackgroundColor3, Color3.fromRGB(17, 29, 43),
			"runtime view must preserve authored panel styling")
		local openedRows = ((openedPanel :: Frame):FindFirstChild("FriendsList") :: ScrollingFrame):FindFirstChild("Rows")
		local openedTemplate = assert(openedRows):FindFirstChild("FriendRowTemplate")
		truthy(openedTemplate ~= nil and openedTemplate:IsA("Frame") and not openedTemplate.Visible,
			"opened production window must retain the hidden physical friend-row template")
		truthy(template.Parent == catalogRoot and hudTemplate.Parent == catalogRoot,
			"runtime binding must preserve both Studio-owned catalog originals")
		equal(#assetLookups, 2, "HUD and window must each resolve one exact physical catalog key")
	end)

	test("TS-FI-008 Next moves the friends window to the next page", function(scope)
		local entries = {}
		for userId = 1, 26 do
			table.insert(entries, {
				Id = userId,
				Username = `user{userId}`,
				DisplayName = `User {userId}`,
			})
		end
		local pages = {
			IsFinished = true,
			GetCurrentPage = function()
				return entries
			end,
		}
		local controller, fixture = makeFixture(scope, snapshot(), pages)
		controller:Initialize()
		controller:_openWindow()
		local deadline = os.clock() + 1
		while controller._cache == nil and os.clock() < deadline do
			task.wait()
		end
		truthy(controller._cache ~= nil, "friends cache did not load for pagination")
		local firstPage = fixture.Renders[#fixture.Renders]
		equal(firstPage.CurrentPage, 1)
		truthy(firstPage.CanGoNext, "first page must expose Next when another page exists")
		fixture.Events:Fire({
			ActionId = "ui.button.activated",
			UIElementId = "game.window/invite-friends/next",
			WindowId = "game.invite-friends",
		})
		local secondPage = fixture.Renders[#fixture.Renders]
		equal(secondPage.CurrentPage, 2, "Next must render the following page")
		truthy(secondPage.CanGoBack, "second page must expose Back")
		equal(secondPage.CanGoNext, false, "last page must hide Next")
		equal(#secondPage.Rows, 1, "second page must contain the remaining friend")
	end)

	test("TS-FI-012 repeated window open failure emits one exact diagnostic", function(scope)
		local diagnostics = {}
		local controller = makeFixture(scope, snapshot(), nil, {
			OpenResult = { Kind = "Error", Error = { Code = "AssetLoadFailed" } },
			Logger = {
				Warn = function(_self: any, eventName: string, fields: any)
					table.insert(diagnostics, { EventName = eventName, Fields = fields })
				end,
			},
		})
		controller:Initialize()
		controller:_openWindow()
		controller:_openWindow()
		equal(#diagnostics, 1, "identical repeat failures must not spam the log")
		equal(diagnostics[1].EventName, "window_open_failed")
		equal(diagnostics[1].Fields.Code, "AssetLoadFailed")
		equal(diagnostics[1].Fields.WindowId, InviteFriendsWindowDefinition.WindowId)
	end)

	test("TS-FI-013 view initialization preserves prefab failure classification", function(scope)
		local playerGui = scope:Track(Instance.new("Folder")) :: Folder
		local malformed = scope:Track(Instance.new("Frame")) :: Frame
		local background = Instance.new("TextButton")
		background.Name = "Background"
		background.Parent = malformed
		local pooling = PoolModule.new()
		pooling:Initialize()
		scope:Defer(function()
			pooling:Destroy()
		end)
		local ui = UiSystem.new({
			PlayersModule = {
				GetLocalPlayer = function()
					return { FindFirstChildOfClass = function() return playerGui end }
				end,
			},
			TemplateWindowDefinitions = { InviteFriendsWindowDefinition },
			Pooling = pooling,
			AssetRegistry = {
				RequireByKey = function(_self: any, key: string, expectedClass: string)
					equal(key, InviteFriendsWindowDefinition.AssetKey)
					equal(expectedClass, "GuiObject")
					return malformed
				end,
			},
			ContentPreloader = { Preload = function() return { Failed = 0 } end },
			Spawn = function(callback: () -> ()) callback() end,
			Delay = function(_seconds: number, callback: () -> ()) task.defer(callback) end,
		})
		scope:Defer(function()
			ui:Destroy()
		end)
		equal(ui:Initialize().Kind, "Success")
		local result = ui:AddWindowTypedAsync(InviteFriendsWindowDefinition, {
			GetPresentation = function() return {} end,
		})
		equal(result.Kind, "Error")
		equal(result.Error.Code, "PrefabMalformed", "structural failures must not be mislabeled ViewModelMismatch")
	end)

	test("TS-FI-016 view initialization preserves DuplicateUIElementId", function(scope)
		local root = scope:Track(makePhysicalWindowPrefab())
		local view = InviteFriendsWindowView.new(root, {
			Navigator = {},
			Elements = {
				ClaimSubtree = function() return { Kind = "Error", Error = { Code = "DuplicateUIElementId" } } end,
				ReleaseSubtree = function() return { Kind = "Success" } end,
				DeliverToRoot = function() return { Kind = "Success" } end,
			},
		})
		scope:Defer(function() view:Clear() end)
		local result = view:Initialize({ GetPresentation = function() return {} end })
		equal(result.Kind, "Error")
		equal(result.Error.Code, "DuplicateUIElementId")
	end)

	test("TS-FI-018 physical layout stays authored and rows are template clones only", function(scope)
		local root = scope:Track(makePhysicalWindowPrefab())
		local originalInstances = {} :: { [Instance]: boolean }
		for _, descendant in root:GetDescendants() do
			originalInstances[descendant] = true
		end
		local originalCount = #root:GetDescendants()
		local rows = (((root:FindFirstChild("Content") :: Frame):FindFirstChild("Panel") :: Frame)
			:FindFirstChild("FriendsList") :: ScrollingFrame):FindFirstChild("Rows") :: Frame
		local rowTemplate = rows:FindFirstChild("FriendRowTemplate") :: Frame
		local authoredAvatar = rowTemplate:FindFirstChild("Avatar") :: ImageLabel
		local view = makePhysicalView(scope, root, presentation("Empty", {}))

		equal(#root:GetDescendants(), originalCount,
			"initialization and an empty render must not create or replace authored GUI/layout nodes")
		for descendant in originalInstances do
			truthy(descendant:IsDescendantOf(root), "initialization must preserve every authored physical node")
		end
		truthy(rowTemplate.Parent == rows and not rowTemplate.Visible,
			"the physical row template must remain hidden under Rows")

		view:Render(presentation("List", { {
			UserId = 22,
			DisplayName = "Friend",
			Username = "friend",
			Presence = "Online",
			State = "Can invite",
			CanInvite = true,
		} }))
		local firstClone = rows:FindFirstChild("Friend22") :: Frame
		truthy(firstClone ~= nil and firstClone ~= rowTemplate, "friend row must clone the physical FriendRowTemplate")
		truthy(firstClone:GetAttribute("AuthoredPhysicalNode") == true,
			"runtime friend-row root must originate from the physical template clone")
		equal(firstClone.BackgroundTransparency, rowTemplate.BackgroundTransparency,
			"clone must preserve custom authored row styling")
		local clonedAvatar = firstClone:FindFirstChild("Avatar") :: ImageLabel
		local firstInvite = firstClone:FindFirstChild("Invite") :: TextButton
		local firstRowController = view._runtimeRows[22].Controller
		local firstInviteController = firstRowController.NestedUiElements[#firstRowController.NestedUiElements]
		local templateInvite = rowTemplate:FindFirstChild("Invite") :: TextButton
		equal(clonedAvatar.Image, authoredAvatar.Image,
			"a missing runtime thumbnail must preserve the physical template placeholder")
		equal(clonedAvatar.ImageColor3, authoredAvatar.ImageColor3,
			"clone must preserve custom authored child styling")
		equal(firstInvite.Interactable, true, "available online row must expose an interactable physical Invite")
		for _, descendant in firstClone:GetDescendants() do
			truthy(descendant:GetAttribute("AuthoredPhysicalNode") == true,
				"every runtime visual/layout descendant must originate from the physical template clone")
		end
		equal(#root:GetDescendants(), originalCount + 1 + #rowTemplate:GetDescendants(),
			"one friend must add exactly one cloned template subtree")
		local activeNavigationMembers = 0
		for _ in view._navigationRegistry._members do
			activeNavigationMembers += 1
		end
		equal(activeNavigationMembers, 7,
			"navigation must contain six authored buttons plus the current cloned Invite")
		view:Render(presentation("List", { {
			UserId = 22,
			DisplayName = "Renamed Friend",
			Username = "friend",
			Presence = "Online",
			State = "Waiting for response",
			Countdown = "00:12",
			CanInvite = false,
		} }))
		equal(rows:FindFirstChild("Friend22"), firstClone,
			"timer and state redraw must preserve the keyed physical row and ButtonController")
		equal(view._runtimeRows[22].Controller, firstRowController)
		equal(view._runtimeRows[22].Controller.NestedUiElements[#firstRowController.NestedUiElements], firstInviteController)
		equal(firstInviteController:EmitAction("ui.button.activated").Kind, "Success",
			"preserved row ButtonController must remain connected after timer redraw")
		equal((firstClone:FindFirstChild("DisplayName") :: TextLabel).Text, "Renamed Friend")
		equal((firstClone:FindFirstChild("State") :: TextLabel).Text, "Waiting for response 00:12")
		equal(firstInvite.Interactable, false)
		equal(#root:GetDescendants(), originalCount + 1 + #rowTemplate:GetDescendants(),
			"keyed redraw must not allocate a replacement row subtree")

		view:Render(presentation("List", { {
			UserId = 23,
			DisplayName = "Replacement",
			Username = "replacement",
			Presence = "Offline",
			State = "Unavailable",
			CanInvite = false,
		} }))
		equal(firstClone.Parent, nil, "rerender must destroy the previous runtime clone")
		equal(firstInvite.Selectable, templateInvite.Selectable,
			"removing a row must restore its authored navigation baseline before destruction")
		equal(firstInvite.Interactable, templateInvite.Interactable,
			"removing a row must restore its authored interactability baseline before destruction")
		truthy(rows:FindFirstChild("Friend23") ~= nil, "rerender must create the replacement template clone")
		equal(((rows:FindFirstChild("Friend23") :: Frame):FindFirstChild("Invite") :: TextButton).Interactable, false,
			"unavailable row must disable physical Invite.Interactable")
		truthy(rowTemplate.Parent == rows and not rowTemplate.Visible,
			"rerender must never destroy, move, or reveal the authored template")
		activeNavigationMembers = 0
		for member in view._navigationRegistry._members do
			truthy(member ~= firstInvite, "destroyed Invite must not remain in navigation membership")
			activeNavigationMembers += 1
		end
		equal(activeNavigationMembers, 7,
			"rerender must replace navigation membership instead of accumulating destroyed rows")

		view:Render(presentation("Empty", {}))
		equal(#root:GetDescendants(), originalCount,
			"clearing rows must destroy runtime clones without changing physical layout")
		truthy(rowTemplate.Parent == rows and not rowTemplate.Visible,
			"empty render must preserve the hidden physical template")
		activeNavigationMembers = 0
		for _ in view._navigationRegistry._members do
			activeNavigationMembers += 1
		end
		equal(activeNavigationMembers, 6, "empty render must retain only authored static navigation members")
	end)

	test("TS-FI-019 missing nested physical element fails with PrefabMalformed", function(scope)
		local root = scope:Track(makePhysicalWindowPrefab())
		local rowTemplate = (((((root:FindFirstChild("Content") :: Frame):FindFirstChild("Panel") :: Frame)
			:FindFirstChild("FriendsList") :: ScrollingFrame):FindFirstChild("Rows") :: Frame)
			:FindFirstChild("FriendRowTemplate") :: Frame)
		local presenceIndicator = rowTemplate:FindFirstChild("PresenceIndicator") :: Frame
		assert(presenceIndicator:FindFirstChild("UICorner")):Destroy()
		local view = InviteFriendsWindowView.new(root, {
			Navigator = {},
			Elements = makeElementContext(),
		})
		scope:Defer(function() view:Clear() end)
		local result = view:Initialize({ GetPresentation = function() return presentation("Empty", {}) end })
		equal(result.Kind, "Error")
		equal(result.Error.Code, "PrefabMalformed")
	end)

	test("TS-FI-020 duplicate required physical element fails with PrefabMalformed", function(scope)
		local root = scope:Track(makePhysicalWindowPrefab())
		local panel = (root:FindFirstChild("Content") :: Frame):FindFirstChild("Panel") :: Frame
		authored("TextLabel", "Status", panel.FriendsList)
		local view = InviteFriendsWindowView.new(root, {
			Navigator = {},
			Elements = makeElementContext(),
		})
		scope:Defer(function() view:Clear() end)
		local result = view:Initialize({ GetPresentation = function() return presentation("Empty", {}) end })
		equal(result.Kind, "Error")
		equal(result.Error.Code, "PrefabMalformed")
	end)

	test("TS-FI-030 malformed physical scrolling properties fail with PrefabMalformed", function(scope)
		for _, defect in { "Direction", "RowsHeight" } do
			local root = scope:Track(makePhysicalWindowPrefab())
			local panel = (root.Content :: Frame).Panel :: Frame
			local list = panel.FriendsList :: ScrollingFrame
			if defect == "Direction" then
				list.ScrollingDirection = Enum.ScrollingDirection.X
			else
				(list.Rows :: Frame).Size = UDim2.new(1, 0, 0, 1)
			end
			local view = InviteFriendsWindowView.new(root, { Navigator = {}, Elements = makeElementContext() })
			scope:Defer(function() view:Clear() end)
			local result = view:Initialize({ GetPresentation = function() return presentation("Empty", {}) end })
			equal(result.Kind, "Error")
			equal(result.Error.Code, "PrefabMalformed", `{defect} must fail the physical scroll contract`)
		end
	end)

	test("TS-FI-025 uncloneable physical window and row templates fail with PrefabMalformed", function(scope)
		for _, target in { "Window", "Row" } do
			local root = scope:Track(makePhysicalWindowPrefab())
			if target == "Window" then
				root.Archivable = false
			else
				local rows = (((root:FindFirstChild("Content") :: Frame):FindFirstChild("Panel") :: Frame)
					:FindFirstChild("FriendsList") :: ScrollingFrame):FindFirstChild("Rows") :: Frame
				(rows:FindFirstChild("FriendRowTemplate") :: Frame).Archivable = false
			end
			local view = InviteFriendsWindowView.new(root, {
				Navigator = {},
				Elements = makeElementContext(),
			})
			scope:Defer(function() view:Clear() end)
			local result = view:Initialize({ GetPresentation = function() return presentation("Empty", {}) end })
			equal(result.Kind, "Error")
			equal(result.Error.Code, "PrefabMalformed",
				`uncloneable physical {target} template must fail with the stable prefab classification`)
		end
	end)

	test("TS-FI-031 reserve kinds and global blockers project explicit row status", function(scope)
		local controller = makeFixture(scope, snapshot(), nil)
		controller:Initialize()
		local entry = { UserId = 22, Username = "friend", DisplayName = "Friend", Presence = "Online" } :: any
		local native = controller:_rowFor(entry, snapshot({ Reserves = {
			{ TargetUserId = 22, ExpiresAtServerTime = 130, Kind = "Native" },
		} }), { IsBusy = false, Phase = "Idle" })
		equal(native.State, "Waiting for friend · slot held")
		equal(native.Countdown, "00:30")
		equal(native.CanInvite, true, "native reserve should permit retry")
		local sameServer = controller:_rowFor(entry, snapshot({ Reserves = {
			{ TargetUserId = 22, ExpiresAtServerTime = 130, Kind = "SameServer" },
		} }), { IsBusy = false, Phase = "Idle" })
		equal(sameServer.State, "Waiting for response")
		equal(sameServer.CanInvite, false, "local offer must not permit repeat")
		local busy = controller:_rowFor(entry, snapshot(), {
			IsBusy = true, Phase = "Requesting", TargetUserId = 33,
		})
		equal(busy.State, "Finish current invite")
		equal(busy.CanInvite, false)
		local full = controller:_rowFor(entry, snapshot({ Current = 1, ConnectedCount = 1, ConnectedUserIds = { 17 }, CanCreateReserve = false }), {
			IsBusy = false, Phase = "Idle",
		})
		equal(full.State, "No free slots")
		equal(full.CanInvite, false)
	end)

	test("TS-FI-032 successful explicit Refresh clears local Unavailable through FriendsClient", function(scope)
		local controller, fixture = makeFixture(scope, snapshot(), nil, {
			Spawn = function(callback: () -> ()) callback() end,
		})
		controller:Initialize()
		controller._localStates[22] = "Unavailable"
		controller:_loadFriends(false)
		equal(controller._localStates[22], nil)
		equal(fixture.GetRefreshNotifications(), 1,
			"successful foreground refresh must notify FriendsClient exactly once")
	end)

	test("TS-FI-033 keyed rows preserve instances and update only LayoutOrder", function(scope)
		local root = scope:Track(makePhysicalWindowPrefab())
		local view = makePhysicalView(scope, root, presentation("Empty", {}))
		local rowsRoot = ((root.Content :: Frame).Panel.FriendsList :: ScrollingFrame).Rows :: Frame
		local first = {
			{ UserId = 22, DisplayName = "A", Username = "a", Presence = "Online", State = "Can invite", CanInvite = true },
			{ UserId = 23, DisplayName = "B", Username = "b", Presence = "Online", State = "Can invite", CanInvite = true },
		}
		view:Render(presentation("List", first))
		local row22 = rowsRoot:FindFirstChild("Friend22") :: Frame
		local row23 = rowsRoot:FindFirstChild("Friend23") :: Frame
		truthy(row22 ~= nil and row23 ~= nil, "both keyed rows must be created")
		view:Render(presentation("List", { first[2], first[1] }))
		equal(rowsRoot:FindFirstChild("Friend22"), row22)
		equal(rowsRoot:FindFirstChild("Friend23"), row23)
		equal(row23.LayoutOrder, 1)
		equal(row22.LayoutOrder, 2)
		view:Render(presentation("List", { {
			UserId = 22, DisplayName = "A", Username = "a", Presence = "Unknown",
			State = "Checking status", CanInvite = false,
		}, first[2] }))
		equal(rowsRoot:FindFirstChild("Friend22"), row22,
			"presence invalidation must update the keyed row without replacing its input controller")
		equal((row22:FindFirstChild("State") :: TextLabel).Text, "Checking status")
		equal((row22:FindFirstChild("Presence") :: TextLabel).Text, "Checking status")
		equal((row22:FindFirstChild("PresenceIndicator") :: Frame).BackgroundColor3,
			Color3.fromRGB(171, 184, 220), "Unknown presence must use its explicit authored-neutral color")
		equal((row22:FindFirstChild("Invite") :: TextButton).Interactable, false)
	end)

	test("TS-FI-034 physical group invitation window definition and binding are exact", function(scope)
		equal(TemplateWindowConfig[1], InviteFriendsWindowDefinition,
			"template catalog must use the same canonical friends definition table")
		equal(TemplateWindowConfig[2], GroupInviteWindowDefinition,
			"template catalog must use the same canonical group definition table")
		equal(GroupInviteWindowDefinition.WindowId, "game.group-invite")
		equal(GroupInviteWindowDefinition.AssetKey, "game.ui.window.group-invite")
		equal(GroupInviteWindowDefinition.AssetId, nil)
		equal(GroupInviteWindowDefinition.LifecyclePolicy, "Destroy")
		equal(GroupInviteWindowDefinition.VisibilityPolicy, "KeepBelow")
		equal(GroupInviteWindowDefinition.BackgroundPolicy, "Absorb")
		equal(GroupInviteWindowDefinition.Preload, false)
		local root = scope:Track(makePhysicalGroupInviteWindow())
		local binding, problem = GroupInviteWindowPrefabValidator.Validate(root)
		truthy(binding ~= nil, problem or "physical group invitation prefab rejected")
		equal(root:FindFirstChild("Close", true), nil)
		equal(root:FindFirstChild("InputSink", true), nil)
		local resumed = 0
		local view = GroupInviteWindowView.new(root, { Navigator = {}, Elements = makeElementContext() })
		view:_SetNavigatorBinding({}, {
			CanEmitAction = function() return true end,
			GetGuiService = function() return { SelectedObject = nil } end,
		})
		scope:Defer(function() view:Clear() end)
		local result = view:Initialize({
			GetPresentation = function()
				return { TitleText = "Group invitation", MessageText = "Friend invites you", CountdownText = "00:15", Processing = false }
			end,
			OnResumed = function() resumed += 1 end,
		})
		equal(result.Kind, "Success")
		view:_SetNavigationActive(true)
		equal(view:GetAction("game.window/group-invite/accept"), "accept")
		equal(view:GetAction("game.window/group-invite/decline"), "decline")
		equal(view._navigationRegistry._default, binding.Accept,
			"physical Accept must be the default navigation element")
		view:Render({ TitleText = "Group invitation", MessageText = "Processing", CountdownText = "00:14", Processing = true })
		equal(binding.Accept.Interactable, false)
		equal(binding.Decline.Interactable, false)
		view:Resume()
		equal(resumed, 1)
	end)

	test("TS-FI-035 incoming offer opens modal and response stays pending until snapshot removal", function(scope)
		local callbacks = {}
		local decisions = {}
		local initial = snapshot({ IncomingOffer = {
			OfferId = "offer-a", InviterUserId = 44, InviterUsername = "inviter",
			InviterDisplayName = "Inviter", ExpiresAtServerTime = 130, Status = "Open",
		}, CanCreateReserve = false })
		local controller, fixture = makeFixture(scope, initial, nil, {
			RespondToLocalOffer = function(_self: any, offerId: string, decision: string, callback: any)
				table.insert(decisions, `{offerId}:{decision}`)
				table.insert(callbacks, callback)
				return { Ok = true }
			end,
		})
		controller:Initialize()
		equal(#fixture.GroupRenders, 1, "initial authoritative offer must open one modal")
		equal(fixture.GroupRenders[1].Processing, false)
		fixture.Events:Fire({
			ActionId = "ui.button.activated", WindowId = "game.group-invite",
			UIElementId = "game.window/group-invite/accept",
		})
		equal(decisions[1], "offer-a:Accept")
		equal(fixture.GroupRenders[#fixture.GroupRenders].Processing, true)
		equal(fixture.GetGroupCloseCount(), 0, "local callback must not close before authoritative removal")
		fixture.SetSnapshot(snapshot({ IncomingOffer = {
			OfferId = "offer-b", InviterUserId = 55, InviterUsername = "replacement",
			InviterDisplayName = "Replacement", ExpiresAtServerTime = 140, Status = "Open",
		}, CanCreateReserve = false }))
		equal(fixture.GroupRenders[#fixture.GroupRenders].Processing, false,
			"replacement offer must clear response state from the previous generation")
		callbacks[1]("Accepted")
		equal(fixture.GroupRenders[#fixture.GroupRenders].Processing, false,
			"stale callback must not mutate the replacement offer")
		fixture.SetSnapshot(snapshot())
		equal(fixture.GetGroupCloseCount(), 1,
			"authoritative offer removal must close the active modal")
	end)

	test("TS-FI-036 paused modal defers authoritative close until Resume", function(scope)
		local deferred = {}
		local controller, fixture = makeFixture(scope, snapshot({ IncomingOffer = {
			OfferId = "offer-a", InviterUserId = 44, InviterUsername = "inviter",
			InviterDisplayName = "Inviter", ExpiresAtServerTime = 130, Status = "Open",
		}, CanCreateReserve = false }), nil, {
			Defer = function(callback: () -> ()) table.insert(deferred, callback) end,
		})
		controller:Initialize()
		fixture.SetGroupActive(false)
		fixture.SetSnapshot(snapshot())
		equal(fixture.GetGroupCloseCount(), 0, "paused window cannot be closed out of stack order")
		fixture.SetGroupActive(true)
		controller:_onGroupWindowResumed()
		equal(#deferred, 1)
		deferred[1]()
		equal(fixture.GetGroupCloseCount(), 1, "resumed top modal must apply pending authoritative close")
	end)

	test("TS-FI-037 group invitation physical layout remains usable at narrow mobile width", function(scope)
		local root = scope:Track(makePhysicalGroupInviteWindow())
		local binding = assert(GroupInviteWindowPrefabValidator.Validate(root))
		equal(binding.Panel.AnchorPoint, Vector2.new(0.5, 0.5))
		equal(binding.Panel.Position, UDim2.fromScale(0.5, 0.5))
		truthy(binding.SizeConstraint.MinSize.X <= 320,
			"minimum modal width must fit the supported narrow viewport")
		truthy(binding.SizeConstraint.MaxSize.X >= binding.SizeConstraint.MinSize.X)
		equal(binding.ActionsLayout.FillDirection, Enum.FillDirection.Horizontal)
		truthy(math.abs(binding.Accept.Size.X.Scale + binding.Decline.Size.X.Scale - 0.92) < 0.00001,
			"physical actions must fit side by side without overflowing the panel")
	end)

	test("TS-FI-038 every presence load disables all cached Online invitations and request rechecks loading", function(scope)
		for _, background in { false, true } do
			local jobs = {}
			local requests = 0
			local controller, fixture = makeFixture(scope, snapshot(), nil, {
				Spawn = function(callback: () -> ()) table.insert(jobs, callback) end,
				RequestInvite = function()
					requests += 1
					return { Ok = true }
				end,
			})
			controller:Initialize()
			controller._cache = {
				{ UserId = 22, Username = "friend", DisplayName = "Friend", Presence = "Online" },
				{ UserId = 23, Username = "other", DisplayName = "Other", Presence = "Online" },
			}
			controller._view = fixture.View
			controller:_loadFriends(background)
			equal(#jobs, 1)
			local rendered = fixture.Renders[#fixture.Renders]
			for _, row in rendered.Rows do
				equal(row.State, "Refreshing")
				equal(row.CanInvite, false)
			end
			controller:_requestInvite(22)
			equal(requests, 0, "RequestInvite must recheck loading even if a stale row action arrives")
		end
	end)

	test("TS-FI-039 connected departure invalidates stale Online before background refresh and resolves Offline", function(scope)
		local jobs = {}
		local requests = 0
		local pages = {
			IsFinished = true,
			GetCurrentPage = function()
				return { { Id = 22, Username = "friend", DisplayName = "Friend" } }
			end,
		}
		local controller, fixture = makeFixture(scope, snapshot({
			ConnectedCount = 1, ConnectedUserIds = { 22 },
		}), pages, {
			Spawn = function(callback: () -> ()) table.insert(jobs, callback) end,
			RequestInvite = function()
				requests += 1
				return { Ok = true }
			end,
			GetFriendsOnline = function() return {} end,
		})
		controller:Initialize()
		controller._cache = { { UserId = 22, Username = "friend", DisplayName = "Friend", Presence = "Online" } }
		controller._view = fixture.View
		fixture.SetSnapshot(snapshot())
		equal(controller._cache[1].Presence, "Unknown")
		equal(controller._loading, true)
		equal(#jobs, 1, "departure must start one bounded background presence refresh")
		local pending = fixture.Renders[#fixture.Renders].Rows[1]
		equal(pending.State, "Checking status")
		equal(pending.CanInvite, false)
		controller:_requestInvite(22)
		equal(requests, 0)
		jobs[1]()
		equal(controller._cache[1].Presence, "Offline")
		local refreshed = fixture.Renders[#fixture.Renders].Rows[1]
		equal(refreshed.State, "Offline")
		equal(refreshed.CanInvite, false)
	end)

	test("TS-FI-040 failed departure refresh preserves unknown disabled state", function(scope)
		local jobs = {}
		local controller, fixture = makeFixture(scope, snapshot({
			ConnectedCount = 1, ConnectedUserIds = { 22 },
		}), nil, {
			Spawn = function(callback: () -> ()) table.insert(jobs, callback) end,
			GetFriends = function() error("presence unavailable") end,
		})
		controller:Initialize()
		controller._cache = { { UserId = 22, Username = "friend", DisplayName = "Friend", Presence = "Online" } }
		controller._view = fixture.View
		fixture.SetSnapshot(snapshot())
		jobs[1]()
		equal(controller._loading, false)
		equal(controller._cache[1].Presence, "Unknown")
		local row = fixture.Renders[#fixture.Renders].Rows[1]
		equal(row.State, "Checking status")
		equal(row.CanInvite, false,
			"failed refresh must never restore permission from the stale Online cache")
	end)

	test("TS-FI-041 in-flight stale presence is discarded before one serialized recovery refresh", function(scope)
		local jobs = {}
		local requests = 0
		local presenceCalls = 0
		local pages = {
			IsFinished = true,
			GetCurrentPage = function()
				return { { Id = 22, Username = "friend", DisplayName = "Friend" } }
			end,
		}
		local resolvedController, fixture = makeFixture(scope, snapshot({
			ConnectedCount = 1, ConnectedUserIds = { 22 },
		}), pages, {
			Spawn = function(callback: () -> ()) table.insert(jobs, callback) end,
			RequestInvite = function()
				requests += 1
				return { Ok = true }
			end,
			GetFriendsOnline = function()
				presenceCalls += 1
				return if presenceCalls == 1 then { { VisitorId = 22 } } else {}
			end,
		})
		resolvedController:Initialize()
		resolvedController._cache = { { UserId = 22, Username = "friend", DisplayName = "Friend", Presence = "Online" } }
		local root = scope:Track(makePhysicalWindowPrefab())
		local physicalView = makePhysicalView(scope, root, presentation("Empty", {}))
		resolvedController._view = physicalView
		resolvedController:_render(true)
		local rowsRoot = ((root.Content :: Frame).Panel.FriendsList :: ScrollingFrame).Rows :: Frame
		local originalRow = rowsRoot:FindFirstChild("Friend22")
		truthy(originalRow ~= nil, "initial keyed row must exist")
		resolvedController:_loadFriends(true)
		equal(#jobs, 1)
		fixture.SetSnapshot(snapshot())
		equal(resolvedController._presenceInvalidatedLoadGeneration, resolvedController._generation)
		equal(resolvedController._cache[1].Presence, "Unknown")
		equal(rowsRoot:FindFirstChild("Friend22"), originalRow)
		jobs[1]()
		equal(#jobs, 2, "stale completion must queue exactly one serialized recovery refresh")
		equal(resolvedController._loading, true)
		equal(resolvedController._cache[1].Presence, "Unknown",
			"stale Online result must be discarded instead of replacing the invalidated cache")
		equal(rowsRoot:FindFirstChild("Friend22"), originalRow)
		resolvedController:_requestInvite(22)
		equal(requests, 0)
		jobs[2]()
		equal(resolvedController._cache[1].Presence, "Offline")
		equal(resolvedController._loading, false)
		equal(rowsRoot:FindFirstChild("Friend22"), originalRow,
			"serialized recovery must update the same keyed physical row")
		equal(((originalRow :: Frame):FindFirstChild("Invite") :: TextButton).Interactable, false)
	end)

	test("TS-FI-042 failed serialized recovery does not retry forever", function(scope)
		local jobs = {}
		local attempts = 0
		local controller, fixture = makeFixture(scope, snapshot({
			ConnectedCount = 1, ConnectedUserIds = { 22 },
		}), nil, {
			Spawn = function(callback: () -> ()) table.insert(jobs, callback) end,
			GetFriends = function()
				attempts += 1
				error("presence unavailable")
			end,
		})
		controller:Initialize()
		controller._cache = { { UserId = 22, Username = "friend", DisplayName = "Friend", Presence = "Online" } }
		controller._view = fixture.View
		controller:_loadFriends(true)
		fixture.SetSnapshot(snapshot())
		jobs[1]()
		equal(#jobs, 2, "invalidated failed request must still schedule one fresh attempt")
		jobs[2]()
		equal(attempts, 2)
		equal(#jobs, 2, "failed recovery must not create an automatic retry loop")
		equal(controller._loading, false)
		equal(controller._cache[1].Presence, "Unknown")
		equal(fixture.Renders[#fixture.Renders].Rows[1].CanInvite, false)
	end)

	test("TS-FI-043 new invitations obey server eligibility and disable existing rows after ownership loss", function(scope)
		local requests = 0
		local controller, fixture = makeFixture(scope, snapshot(), nil, {
			RequestInvite = function()
				requests += 1
				return { Ok = true }
			end,
		})
		controller:Initialize()
		controller._cache = { { UserId = 22, Username = "friend", DisplayName = "Friend", Presence = "Online" } }
		local root = scope:Track(makePhysicalWindowPrefab())
		controller._view = makePhysicalView(scope, root, presentation("Empty", {}))
		controller:_render(true)
		local rowsRoot = ((root.Content :: Frame).Panel.FriendsList :: ScrollingFrame).Rows :: Frame
		local row = rowsRoot:FindFirstChild("Friend22") :: Frame
		local invite = row:FindFirstChild("Invite") :: TextButton
		equal(invite.Interactable, true)
		controller:_requestInvite(22)
		equal(requests, 1)
		for _, blocked in {
			{ Snapshot = snapshot({ CanCreateReserve = false, Reserves = {
				{ TargetUserId = 33, ExpiresAtServerTime = 130, Kind = "SameServer" },
			} }), State = "Finish current invite" },
			{ Snapshot = snapshot({ CanCreateReserve = false, IncomingOffer = {
				OfferId = "incoming-eligibility", InviterUserId = 33,
				InviterUsername = "inviter", InviterDisplayName = "Inviter",
				ExpiresAtServerTime = 130, Status = "Open",
			} }), State = "Finish current invite" },
			{ Snapshot = snapshot({ CanCreateReserve = false }), State = "Checking status" },
			{ Snapshot = snapshot({ CanCreateReserve = false, IsSlotOwner = false }), State = "Unavailable" },
		} do
			fixture.SetSnapshot(blocked.Snapshot)
			equal(rowsRoot:FindFirstChild("Friend22"), row, "eligibility changes must preserve the physical row")
			equal(invite.Interactable, false, "server-ineligible row must reject pointer input")
			equal(invite.Selectable, false, "server-ineligible row must reject gamepad focus")
			equal((row:FindFirstChild("State") :: TextLabel).Text, blocked.State)
			controller:_requestInvite(22)
			equal(requests, 1, "a stale activation must recheck the server eligibility before sending")
		end
		fixture.SetSnapshot(snapshot())
		equal(invite.Interactable, true, "restored eligibility must re-enable the same physical button")
		controller:_requestInvite(22)
		equal(requests, 2)
	end)

	test("TS-FI-044 full native reserve permits retry but ownership and local offers still block it", function(scope)
		local controller = makeFixture(scope, snapshot(), nil)
		controller:Initialize()
		local entry = { UserId = 22, Username = "friend", DisplayName = "Friend", Presence = "Online" } :: any
		local idle = { IsBusy = false, Phase = "Idle" }
		local reserved = snapshot({ Current = 1, CanCreateReserve = false, Reserves = {
			{ TargetUserId = 22, ExpiresAtServerTime = 130, Kind = "Native" },
		} })
		equal(controller:_rowFor(entry, reserved, idle).CanInvite, true,
			"retry must reuse the existing reserve even while creating a new reserve is forbidden")
		reserved.IsSlotOwner = false
		equal(controller:_rowFor(entry, reserved, idle).CanInvite, false)
		reserved.IsSlotOwner = true
		reserved.Current = 3
		table.insert(reserved.Reserves, { TargetUserId = 33, ExpiresAtServerTime = 130, Kind = "SameServer" })
		equal(controller:_rowFor(entry, reserved, idle).CanInvite, false)
	end)

	test("TS-FI-045 native attempt release re-enables the physical reserve button without claiming an open window", function(scope)
		local reserved = snapshot({ Current = 1, CanCreateReserve = false, Reserves = {
			{ TargetUserId = 22, ExpiresAtServerTime = 220, Kind = "Native" },
		} })
		local controller, fixture = makeFixture(scope, reserved, nil)
		controller:Initialize()
		controller._cache = { { UserId = 22, Username = "friend", DisplayName = "Friend", Presence = "Online" } }
		local root = scope:Track(makePhysicalWindowPrefab())
		controller._view = makePhysicalView(scope, root, presentation("Empty", {}))
		fixture.SetPrompt({ IsBusy = true, Phase = "OpeningRoblox", TargetUserId = 22 })
		local rows = ((root.Content :: Frame).Panel.FriendsList :: ScrollingFrame).Rows :: Frame
		local row = rows:FindFirstChild("Friend22") :: Frame
		local invite = row:FindFirstChild("Invite") :: TextButton
		equal((row:FindFirstChild("State") :: TextLabel).Text, "Checking status 02:00")
		equal(invite.Interactable, false)
		fixture.SetPrompt({ IsBusy = true, Phase = "PromptRequested", TargetUserId = 22 })
		equal((row:FindFirstChild("State") :: TextLabel).Text, "Waiting for friend · slot held 02:00")
		equal(invite.Interactable, false, "successful API return retains only the bounded attempt lock")
		fixture.SetPrompt({ IsBusy = false, Phase = "Idle" })
		equal(rows:FindFirstChild("Friend22"), row)
		equal(invite.Interactable, true, "attempt expiry must permit retry while the full-capacity reserve remains")
		equal(controller._snapshot.Reserves[1].ExpiresAtServerTime, 220)
		reserved.Reserves[1].Kind = "SameServer"
		fixture.SetSnapshot(reserved)
		equal(invite.Interactable, false, "real local-offer waiting must retain its server-owned lock")
		equal((row:FindFirstChild("State") :: TextLabel).Text, "Waiting for response 02:00")
	end)

	return TestHarness.runAll("FriendInvitationsUiTestRunner", tests)
end

return Runner
