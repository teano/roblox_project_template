--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BaseWindowView = require(ReplicatedStorage.Client.UI.Windows.BaseWindowView)
local FrameController = require(ReplicatedStorage.Client.UI.Elements.Controllers.FrameController)
local TextController = require(ReplicatedStorage.Client.UI.Elements.Controllers.TextController)
local ImageController = require(ReplicatedStorage.Client.UI.Elements.Controllers.ImageController)
local ButtonController = require(ReplicatedStorage.Client.UI.Elements.Controllers.ButtonController)
local ScrollingFrameController = require(ReplicatedStorage.Client.UI.Elements.Controllers.ScrollingFrameController)
local UiElementIdentityRegistry = require(ReplicatedStorage.Client.UI.UiElementIdentityRegistry)
local WindowTypes = require(ReplicatedStorage.Client.UI.Config.WindowTypes)
local InviteFriendsWindowPrefabValidator =
	require(ReplicatedStorage.Shared.UI.InviteFriendsWindowPrefabValidator)

type UiVoidResult = WindowTypes.UiVoidResult
type BaseWindowViewContract = WindowTypes.BaseWindowView
type WindowConstructionContext = WindowTypes.WindowConstructionContext

export type FriendRow = {
	UserId: number,
	DisplayName: string,
	Username: string,
	Presence: "Online" | "Offline" | "Unknown",
	ThumbnailContent: string?,
	State: "Can invite" | "Opening Roblox" | "Waiting for friend · slot held" | "Waiting for response"
		| "Finish current invite" | "No free slots" | "Checking status" | "Refreshing"
		| "Connected" | "Offline" | "Unavailable" | "Error",
	Countdown: string?,
	CanInvite: boolean,
}

export type Presentation = {
	Mode: "Loading" | "LoadError" | "Empty" | "List",
	TitleText: string,
	FriendsOnlineText: string,
	IsFull: boolean,
	CanRefresh: boolean,
	Rows: { FriendRow },
	CurrentPage: number?,
	PageCount: number?,
	CanGoBack: boolean,
	CanGoNext: boolean,
	CanGoFirst: boolean,
	CanGoLast: boolean,
	ShowLeadingEllipsis: boolean,
	ShowTrailingEllipsis: boolean,
	ResetScroll: boolean,
}

export type ViewModel = {
	GetPresentation: () -> Presentation,
}

export type View = BaseWindowViewContract & {
	Initialize: (self: View, viewModel: ViewModel) -> UiVoidResult,
	Render: (self: View, presentation: Presentation) -> (),
	GetAction: (self: View, uiElementId: string) -> (string?, number?),
}

local WINDOW_ID = "game.invite-friends"
local ROOT_ID = "game.window/invite-friends"

local View = {}
View.__index = View
setmetatable(View, { __index = BaseWindowView })

local function uiResult(code: string?): UiVoidResult
	if code == nil then
		return { Kind = "Success" }
	end
	return { Kind = "Error", Error = { Code = code } }
end

local function runtimeId(path: string, userId: number): string
	local id, problem = UiElementIdentityRegistry.MakeRuntimeId(path, tostring(userId))
	assert(id ~= nil, problem and problem.Code or "InvalidUIElementId")
	return id
end

local function addChild(parent: any, child: any, defaultElement: GuiObject?): UiVoidResult
	local result = parent:AddNestedUiElement(child, defaultElement)
	if result.Kind == "Error" then
		return result
	end
	return uiResult(nil)
end

local function requireSuccessfulRegistration(result: UiVoidResult)
	if result.Kind == "Error" then
		error(result.Error.Code, 2)
	end
end

local function classifyInitializationProblem(problem: any): string
	local rendered = tostring(problem)
	if string.find(rendered, "PrefabMalformed", 1, true) ~= nil then
		return "PrefabMalformed"
	end
	for _, code in { "InvalidDefaultNavigation", "InvalidUIElementId", "DuplicateUIElementId", "CleanupFailed", "NotActiveWindow" } do
		if string.find(rendered, code, 1, true) ~= nil then
			return code
		end
	end
	return "ViewInitializationFailed"
end

function View.new(root: GuiObject, context: WindowConstructionContext): View
	local self = BaseWindowView.new(root, WINDOW_ID, ROOT_ID, context.Elements) :: any
	self._construction = context
	self._viewModel = nil
	self._rowsController = nil
	self._runtimeRows = {}
	self._actions = {}
	self._isInitialized = false
	setmetatable(self, View)
	return self
end

function View.tryCast(value: BaseWindowViewContract): View?
	if value.WindowId ~= WINDOW_ID or getmetatable(value) ~= View then
		return nil
	end
	return value :: any
end

function View:_registerAction(controller: any, id: string, action: string, userId: number?)
	self._actions[id] = { Action = action, UserId = userId }
	local result = addChild(self, controller, nil)
	requireSuccessfulRegistration(result)
end

function View:_bindAuthoredLayout()
	local binding, problem = InviteFriendsWindowPrefabValidator.Validate(self.Root)
	if binding == nil then
		error(problem or "PrefabMalformed", 2)
	end
	local panel = binding.Panel
	local title = binding.Title
	local close = binding.Close
	local summaryRow = binding.SummaryRow
	local friendsOnline = binding.FriendsOnline
	local full = binding.NoSlots
	local status = binding.Status
	local list = binding.FriendsList
	local rowsRoot = binding.Rows
	local rowTemplate = binding.FriendRowTemplate
	local refresh = binding.Refresh
	local pages = binding.Pages
	local back = binding.Back
	local first = binding.First
	local leading = binding.LeadingEllipsis
	local current = binding.CurrentPage
	local trailing = binding.TrailingEllipsis
	local last = binding.Last
	local next = binding.Next

	local rowsController = FrameController.new(rowsRoot, ROOT_ID .. "/rows", false, self._construction.Elements)
	local staticControllers = {
		FrameController.new(panel, ROOT_ID .. "/panel", false, self._construction.Elements),
		TextController.new(title, ROOT_ID .. "/title", false, self._construction.Elements),
		TextController.new(full, ROOT_ID .. "/no-slots", false, self._construction.Elements),
		FrameController.new(summaryRow, ROOT_ID .. "/summary-row", false, self._construction.Elements),
		TextController.new(friendsOnline, ROOT_ID .. "/friends-online", false, self._construction.Elements),
		TextController.new(status, ROOT_ID .. "/status", false, self._construction.Elements),
		ScrollingFrameController.new(list, ROOT_ID .. "/friends-list", false, self._construction.Elements),
		rowsController,
		FrameController.new(pages, ROOT_ID .. "/pages", false, self._construction.Elements),
		TextController.new(leading, ROOT_ID .. "/leading-ellipsis", false, self._construction.Elements),
		TextController.new(current, ROOT_ID .. "/current-page", false, self._construction.Elements),
		TextController.new(trailing, ROOT_ID .. "/trailing-ellipsis", false, self._construction.Elements),
	}
	for _, controller in staticControllers do
		requireSuccessfulRegistration(addChild(self, controller, nil))
	end
	self:_registerAction(ButtonController.new(close, ROOT_ID .. "/close", true, self._construction.Elements), ROOT_ID .. "/close", "close")
	self:_registerAction(ButtonController.new(refresh, ROOT_ID .. "/refresh", true, self._construction.Elements), ROOT_ID .. "/refresh", "refresh")
	self:_registerAction(ButtonController.new(back, ROOT_ID .. "/back", true, self._construction.Elements), ROOT_ID .. "/back", "back")
	self:_registerAction(ButtonController.new(first, ROOT_ID .. "/first", true, self._construction.Elements), ROOT_ID .. "/first", "first")
	self:_registerAction(ButtonController.new(last, ROOT_ID .. "/last", true, self._construction.Elements), ROOT_ID .. "/last", "last")
	self:_registerAction(ButtonController.new(next, ROOT_ID .. "/next", true, self._construction.Elements), ROOT_ID .. "/next", "next")
	requireSuccessfulRegistration(self:ConfigureNavigation(close, {}))

	self._title = title
	self._friendsOnline = friendsOnline
	self._full = full
	self._status = status
	self._list = list
	self._rowsRoot = rowsRoot
	self._rowTemplate = rowTemplate
	self._rowsController = rowsController
	self._refresh = refresh
	self._pages = pages
	self._back = back
	self._first = first
	self._leading = leading
	self._current = current
	self._trailing = trailing
	self._last = last
	self._next = next
end

function View:Initialize(viewModel: ViewModel): UiVoidResult
	if self._isInitialized then
		return uiResult(nil)
	end
	if typeof(viewModel) ~= "table" or typeof(viewModel.GetPresentation) ~= "function" then
		return uiResult("ViewModelMismatch")
	end
	local ok, problem = xpcall(function()
		self._viewModel = viewModel
		self:_bindAuthoredLayout()
		local result = BaseWindowView.Initialize(self, viewModel)
		if result.Kind == "Error" then
			error(result.Error.Code)
		end
		self._isInitialized = true
		self:Render(viewModel.GetPresentation())
	end, debug.traceback)
	if not ok then
		return uiResult(classifyInitializationProblem(problem))
	end
	return uiResult(nil)
end

function View:_clearRows()
	if self._rowsController == nil then
		return
	end
	for userId, record in self._runtimeRows do
		local removed = self._rowsController:RemoveNestedUiElement(record.Controller)
		requireSuccessfulRegistration(removed)
		local cleared = record.Controller:Clear()
		requireSuccessfulRegistration(cleared)
		record.Root:Destroy()
		self._actions[record.ActionId] = nil
		self._runtimeRows[userId] = nil
	end
end

function View:_renderRows(rows: { FriendRow }, resetScroll: boolean)
	local previousCanvasPosition = self._list.CanvasPosition
	local wanted = {} :: { [number]: boolean }
	for _, row in rows do
		wanted[row.UserId] = true
	end
	for userId, record in self._runtimeRows do
		if wanted[userId] ~= true then
			local removed = self._rowsController:RemoveNestedUiElement(record.Controller)
			requireSuccessfulRegistration(removed)
			local cleared = record.Controller:Clear()
			requireSuccessfulRegistration(cleared)
			record.Root:Destroy()
			self._actions[record.ActionId] = nil
			self._runtimeRows[userId] = nil
		end
	end
	for order, row in rows do
		local record = self._runtimeRows[row.UserId]
		if record == nil then
			local cloned = self._rowTemplate:Clone()
			if cloned == nil or not cloned:IsA("Frame") then
				if cloned ~= nil then
					cloned:Destroy()
				end
				error("PrefabMalformed", 2)
			end
			local root = cloned :: Frame
			root.Name = `Friend{row.UserId}`
			root.Visible = true
			local rowBinding, rowProblem = InviteFriendsWindowPrefabValidator.BindFriendRow(root)
			if rowBinding == nil then
				root:Destroy()
				error(rowProblem or "PrefabMalformed", 2)
			end
			local rootController = FrameController.new(root, runtimeId("friend-invitations/row", row.UserId), false, self._construction.Elements)
			local avatarController = ImageController.new(rowBinding.Avatar, runtimeId("friend-invitations/avatar", row.UserId), false, self._construction.Elements)
			local nameController = TextController.new(rowBinding.DisplayName, runtimeId("friend-invitations/display-name", row.UserId), false, self._construction.Elements)
			local usernameController = TextController.new(rowBinding.Username, runtimeId("friend-invitations/username", row.UserId), false, self._construction.Elements)
			local presenceIndicatorController = FrameController.new(rowBinding.PresenceIndicator, runtimeId("friend-invitations/presence-indicator", row.UserId), false, self._construction.Elements)
			local presenceController = TextController.new(rowBinding.Presence, runtimeId("friend-invitations/presence", row.UserId), false, self._construction.Elements)
			local stateController = TextController.new(rowBinding.State, runtimeId("friend-invitations/state", row.UserId), false, self._construction.Elements)
			local inviteId = runtimeId("friend-invitations/invite", row.UserId)
			local inviteController = ButtonController.new(rowBinding.Invite, inviteId, true, self._construction.Elements)
			for _, child in { avatarController, nameController, usernameController, presenceIndicatorController, presenceController, stateController, inviteController } do
				requireSuccessfulRegistration(addChild(rootController, child, nil))
			end
			requireSuccessfulRegistration(addChild(self._rowsController, rootController, nil))
			self._actions[inviteId] = { Action = "invite", UserId = row.UserId }
			root.Parent = self._rowsRoot
			record = { Controller = rootController, Root = root, ActionId = inviteId, Binding = rowBinding }
			self._runtimeRows[row.UserId] = record
		end
		local root = record.Root
		local rowBinding = record.Binding
		root.LayoutOrder = order
		local avatar = rowBinding.Avatar
		local displayName = rowBinding.DisplayName
		local username = rowBinding.Username
		local presenceIndicator = rowBinding.PresenceIndicator
		local presence = rowBinding.Presence
		local state = rowBinding.State
		local invite = rowBinding.Invite
		if row.ThumbnailContent ~= nil then
			avatar.Image = row.ThumbnailContent
		end
		displayName.Text = row.DisplayName
		username.Text = "@" .. row.Username
		local presenceColor = if row.Presence == "Online" then Color3.fromRGB(104, 220, 136)
			elseif row.Presence == "Offline" then Color3.fromRGB(180, 185, 200)
			else Color3.fromRGB(171, 184, 220)
		presenceIndicator.BackgroundColor3 = presenceColor
		presence.Text = if row.Presence == "Unknown" then "Checking status" else row.Presence
		presence.TextColor3 = presenceColor
		state.Text = row.State .. if row.Countdown then " " .. row.Countdown else ""
		state.TextColor3 = if row.State == "Error" then Color3.fromRGB(255, 146, 146) else Color3.fromRGB(220, 226, 244)
		invite.Active = row.CanInvite
		invite.AutoButtonColor = row.CanInvite
		invite.BackgroundColor3 = if row.CanInvite then Color3.fromRGB(52, 98, 184) else Color3.fromRGB(78, 80, 88)
		invite.TextTransparency = if row.CanInvite then 0 else 0.4
		assert(self._navigationRegistry:SetMemberEligibility(invite, row.CanInvite, row.CanInvite),
			"InviteNavigationMissing")
	end
	self._list.CanvasPosition = if resetScroll then Vector2.new(0, 0) else previousCanvasPosition
end

function View:Render(presentation: Presentation)
	if not self._isInitialized then
		return
	end
	self._title.Text = presentation.TitleText
	self._friendsOnline.Text = presentation.FriendsOnlineText
	self._full.Visible = presentation.IsFull
	self._refresh.Visible = true
	self._refresh.Active = presentation.CanRefresh
	self._refresh.AutoButtonColor = presentation.CanRefresh
	assert(self._navigationRegistry:SetMemberEligibility(
		self._refresh,
		presentation.CanRefresh,
		presentation.CanRefresh
	), "RefreshNavigationMissing")
	self._pages.Visible = presentation.Mode == "List"
	if presentation.Mode == "Loading" then
		self._status.Text = "Loading friends…"
		self:_renderRows({}, presentation.ResetScroll)
	elseif presentation.Mode == "LoadError" then
		self._status.Text = "Couldn’t load friends. Try Refresh."
		self:_renderRows({}, presentation.ResetScroll)
	elseif presentation.Mode == "Empty" then
		self._status.Text = "No friends found"
		self:_renderRows({}, presentation.ResetScroll)
	else
		self._status.Text = ""
		self:_renderRows(presentation.Rows, presentation.ResetScroll)
		self._back.Visible = presentation.CanGoBack
		self._first.Visible = presentation.CanGoFirst
		self._leading.Visible = presentation.ShowLeadingEllipsis
		self._current.Text = tostring(presentation.CurrentPage)
		self._last.Text = tostring(presentation.PageCount)
		self._last.Visible = presentation.CanGoLast
		self._trailing.Visible = presentation.ShowTrailingEllipsis
		self._next.Visible = presentation.CanGoNext
	end
end

function View:GetAction(uiElementId: string): (string?, number?)
	local detail = self._actions[uiElementId]
	if detail == nil then
		return nil, nil
	end
	return detail.Action, detail.UserId
end

function View:_SetNavigationActive(active: boolean)
	BaseWindowView._SetNavigationActive(self, active)
	if active and self._isInitialized and self._viewModel ~= nil then
		self:Render(self._viewModel.GetPresentation())
	end
end

function View:OnClear()
	for _, record in self._runtimeRows do
		record.Root:Destroy()
	end
	table.clear(self._runtimeRows)
	table.clear(self._actions)
	self._rowsController = nil
	self._isInitialized = false
	self._viewModel = nil
end

return View
