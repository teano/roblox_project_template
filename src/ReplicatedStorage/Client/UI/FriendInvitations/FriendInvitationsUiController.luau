--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ButtonController = require(ReplicatedStorage.Client.UI.Elements.Controllers.ButtonController)
local InviteFriendsWindowDefinition = require(ReplicatedStorage.Client.UI.Config.Definitions.InviteFriendsWindowDefinition)
local GroupInviteWindowDefinition = require(ReplicatedStorage.Client.UI.Config.Definitions.GroupInviteWindowDefinition)
local InviteFriendsWindowView = require(ReplicatedStorage.Client.UI.Windows.InviteFriendsWindowView)
local GroupInviteWindowView = require(ReplicatedStorage.Client.UI.Windows.GroupInviteWindowView)
local InviteFriendsHudPrefabValidator = require(script.Parent.InviteFriendsHudPrefabValidator)

type FriendRow = InviteFriendsWindowView.FriendRow
type Presentation = InviteFriendsWindowView.Presentation

local PAGE_SIZE = 25
local HUD_ID = "game.hud/invite-friends"
local HUD_ASSET_KEY = "game.ui.hud.invite-friends"
local WINDOW_ID = "game.invite-friends"
local GROUP_WINDOW_ID = "game.group-invite"
local BUTTON_ACTIVATED = "ui.button.activated"
local WINDOW_CLOSED = "ui.window.closed"

export type FriendEntry = {
	UserId: number,
	Username: string,
	DisplayName: string,
	Presence: "Online" | "Offline" | "Unknown",
	ThumbnailContent: string?,
}

local Controller = {}
Controller.__index = Controller

local function finitePositiveInteger(value: any): boolean
	return typeof(value) == "number"
		and value == value
		and value ~= math.huge
		and value ~= -math.huge
		and value == math.floor(value)
		and value > 0
end

local function disconnect(connection: any?)
	if connection ~= nil then
		connection:Disconnect()
	end
end

local function formatRemaining(seconds: number): string
	local minutes = math.floor(seconds / 60)
	local remainder = seconds % 60
	return string.format("%02d:%02d", minutes, remainder)
end

local function copiedEntry(value: any): FriendEntry?
	if typeof(value) ~= "table" or not finitePositiveInteger(value.Id) then
		return nil
	end
	if typeof(value.Username) ~= "string" or typeof(value.DisplayName) ~= "string" then
		return nil
	end
	return {
		UserId = value.Id,
		Username = value.Username,
		DisplayName = value.DisplayName,
		Presence = "Offline",
	}
end

local function compareEntries(left: FriendEntry, right: FriendEntry): boolean
	if left.Presence ~= right.Presence then
		return left.Presence == "Online"
	end
	local leftDisplay = string.lower(left.DisplayName)
	local rightDisplay = string.lower(right.DisplayName)
	if leftDisplay ~= rightDisplay then
		return leftDisplay < rightDisplay
	end
	local leftUsername = string.lower(left.Username)
	local rightUsername = string.lower(right.Username)
	if leftUsername ~= rightUsername then
		return leftUsername < rightUsername
	end
	return left.UserId < right.UserId
end

function Controller.new(dependencies: {
	UI: any,
	Friends: any,
	PlayersModule: any,
	PlayersService: any,
	StarterGui: any,
	Workspace: any,
	FrameSignal: RBXScriptSignal,
	Assets: any,
	GetFriends: ((number) -> any)?,
	GetFriendsOnline: ((Player, number) -> any)?,
	GetThumbnail: ((number) -> (string, boolean))?,
	Spawn: (((() -> ()) -> ()))?,
	Defer: (((() -> ()) -> ()))?,
	HudInputSignals: any?,
	Logger: any?,
})
	assert(dependencies.UI ~= nil, "FriendInvitations UI is required")
	assert(dependencies.Friends ~= nil, "FriendInvitations Friends is required")
	assert(dependencies.PlayersModule ~= nil, "FriendInvitations PlayersModule is required")
	assert(dependencies.PlayersService ~= nil, "FriendInvitations PlayersService is required")
	assert(dependencies.StarterGui ~= nil, "FriendInvitations StarterGui is required")
	assert(dependencies.Workspace ~= nil, "FriendInvitations Workspace is required")
	assert(dependencies.FrameSignal ~= nil, "FriendInvitations FrameSignal is required")
	assert(dependencies.Assets ~= nil and typeof(dependencies.Assets.RequireByKey) == "function",
		"FriendInvitations Assets is required")
	return setmetatable({
		_ui = dependencies.UI,
		_friends = dependencies.Friends,
		_players = dependencies.PlayersModule,
		_playersService = dependencies.PlayersService,
		_starterGui = dependencies.StarterGui,
		_workspace = dependencies.Workspace,
		_frameSignal = dependencies.FrameSignal,
		_assets = dependencies.Assets,
		_getFriends = dependencies.GetFriends or function(userId: number)
			return dependencies.PlayersService:GetFriendsAsync(userId)
		end,
		_getFriendsOnline = dependencies.GetFriendsOnline or function(player: Player, amount: number)
			return player:GetFriendsOnlineAsync(amount)
		end,
		_getThumbnail = dependencies.GetThumbnail or function(userId: number)
			return dependencies.PlayersService:GetUserThumbnailAsync(userId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size100x100)
		end,
		_spawn = dependencies.Spawn or task.spawn,
		_defer = dependencies.Defer or task.defer,
		_hudInputSignals = dependencies.HudInputSignals,
		_logger = dependencies.Logger,
		_lastWindowOpenFailureCode = nil,
		_state = "fresh",
		_snapshot = nil,
		_hudButton = nil,
		_hudCapacity = nil,
		_hudController = nil,
		_windowHandle = nil,
		_view = nil,
		_offerWindowHandle = nil,
		_offerView = nil,
		_offerId = nil,
		_offerResponding = false,
		_offerClosePending = false,
		_offerResponseGeneration = 0,
		_offerOpenFailureCode = nil,
		_cache = nil :: { FriendEntry }?,
		_loading = false,
		_presenceInvalidatedLoadGeneration = nil,
		_firstLoadFailed = false,
		_localStates = {} :: { [number]: "Unavailable" | "Error" },
		_page = 1,
		_resetScroll = false,
		_lastPresentationKey = nil,
		_generation = 0,
		_uiConnection = nil,
		_snapshotConnection = nil,
		_promptConnection = nil,
		_refreshConnection = nil,
		_frameConnection = nil,
	}, Controller)
end

function Controller:_reportWindowOpenFailure(code: string)
	if code == self._lastWindowOpenFailureCode then
		return
	end
	self._lastWindowOpenFailureCode = code
	local logger = self._logger
	if logger ~= nil and typeof(logger.Warn) == "function" then
		logger:Warn("window_open_failed", {
			WindowId = WINDOW_ID,
			Code = code,
		})
	end
end

function Controller:_getSnapshot(): any?
	local result = self._friends:GetSnapshot()
	if typeof(result) == "table" and result.Ok == true and typeof(result.Snapshot) == "table" then
		return result.Snapshot
	end
	return nil
end

function Controller:_capacityText(snapshot: any?): string
	if snapshot == nil then
		return "0/0"
	end
	return `{snapshot.ConnectedCount + #snapshot.Reserves}/{snapshot.Current}`
end

function Controller:_isFull(snapshot: any?): boolean
	return snapshot ~= nil and snapshot.ConnectedCount + #snapshot.Reserves >= snapshot.Current
end

function Controller:_friendsOnlineText(): string
	local online = 0
	local total = 0
	if self._cache ~= nil then
		total = #self._cache
		for _, entry in self._cache do
			if entry.Presence == "Online" then online += 1 end
		end
	end
	return `Friends online {online}/{total}`
end

function Controller:_updateHud()
	if self._hudButton == nil or self._hudCapacity == nil then
		return
	end
	local snapshot = self._snapshot
	self._hudButton.Visible = snapshot ~= nil and snapshot.IsSlotOwner == true
	self._hudCapacity.Text = self:_capacityText(snapshot)
end

function Controller:_rowFor(entry: FriendEntry, snapshot: any, prompt: any): FriendRow
	local connected = false
	for _, userId in snapshot.ConnectedUserIds do
		if userId == entry.UserId then
			connected = true
			break
		end
	end
	if connected then
		return {
			UserId = entry.UserId, DisplayName = entry.DisplayName, Username = entry.Username, Presence = entry.Presence,
			ThumbnailContent = entry.ThumbnailContent, State = "Connected", CanInvite = false,
		}
	end
	if prompt.IsBusy == true and prompt.TargetUserId == entry.UserId then
		local countdown = nil
		for _, candidate in snapshot.Reserves do
			if candidate.TargetUserId == entry.UserId then
				local remaining = math.ceil(math.max(0, candidate.ExpiresAtServerTime - self._workspace:GetServerTimeNow()))
				countdown = formatRemaining(remaining)
				break
			end
		end
		return {
			UserId = entry.UserId, DisplayName = entry.DisplayName, Username = entry.Username, Presence = entry.Presence,
			ThumbnailContent = entry.ThumbnailContent,
			State = if prompt.Phase == "OpeningRoblox" then "Checking status"
				elseif prompt.Phase == "PromptRequested" then "Waiting for friend · slot held"
				else "Finish current invite",
			Countdown = countdown, CanInvite = false,
		}
	end
	local reserve = nil
	local hasLocalOffer = false
	for _, candidate in snapshot.Reserves do
		if candidate.Kind == "SameServer" then hasLocalOffer = true end
		if candidate.TargetUserId == entry.UserId then reserve = candidate end
	end
	if reserve ~= nil then
		local remaining = math.ceil(math.max(0, reserve.ExpiresAtServerTime - self._workspace:GetServerTimeNow()))
		return {
			UserId = entry.UserId, DisplayName = entry.DisplayName, Username = entry.Username, Presence = entry.Presence,
			ThumbnailContent = entry.ThumbnailContent,
			State = if reserve.Kind == "SameServer" then "Waiting for response" else "Waiting for friend · slot held",
			Countdown = formatRemaining(remaining),
			CanInvite = reserve.Kind == "Native" and snapshot.IsSlotOwner == true
				and snapshot.IncomingOffer == nil and not hasLocalOffer and entry.Presence == "Online"
				and not self._loading and prompt.IsBusy ~= true,
		}
	end
	if entry.Presence == "Offline" then
		return {
			UserId = entry.UserId, DisplayName = entry.DisplayName, Username = entry.Username, Presence = entry.Presence,
			ThumbnailContent = entry.ThumbnailContent, State = "Offline", CanInvite = false,
		}
	end
	if entry.Presence == "Unknown" then
		return {
			UserId = entry.UserId, DisplayName = entry.DisplayName, Username = entry.Username, Presence = entry.Presence,
			ThumbnailContent = entry.ThumbnailContent, State = "Checking status", CanInvite = false,
		}
	end
	local localState = self._localStates[entry.UserId]
	local state = if self._loading then "Refreshing"
		elseif prompt.IsBusy == true or hasLocalOffer or snapshot.IncomingOffer ~= nil then "Finish current invite"
		elseif snapshot.IsSlotOwner ~= true then "Unavailable"
		elseif self:_isFull(snapshot) then "No free slots"
		elseif snapshot.CanCreateReserve ~= true then "Checking status"
		else localState or "Can invite"
	return {
		UserId = entry.UserId, DisplayName = entry.DisplayName, Username = entry.Username, Presence = entry.Presence,
		ThumbnailContent = entry.ThumbnailContent, State = state,
		CanInvite = (state == "Can invite" or state == "Error") and snapshot.CanCreateReserve == true
			and snapshot.IsSlotOwner == true and snapshot.IncomingOffer == nil and not hasLocalOffer
			and not self:_isFull(snapshot) and prompt.IsBusy ~= true,
	}
end

function Controller:_presentation(): Presentation
	local snapshot = self._snapshot
	local capacity = self:_capacityText(snapshot)
	local title = `Invite Friends {capacity}`
	local friendsOnline = self:_friendsOnlineText()
	local full = self:_isFull(snapshot)
	if self._cache == nil then
		return {
			Mode = if self._firstLoadFailed then "LoadError" else "Loading", TitleText = title,
			FriendsOnlineText = friendsOnline, IsFull = full, Rows = {},
			CanRefresh = not self._loading,
			CanGoBack = false, CanGoNext = false, CanGoFirst = false, CanGoLast = false,
			ShowLeadingEllipsis = false, ShowTrailingEllipsis = false, ResetScroll = self._resetScroll,
		}
	end
	if #self._cache == 0 then
		return {
			Mode = "Empty", TitleText = title, FriendsOnlineText = friendsOnline, IsFull = full, Rows = {},
			CanRefresh = not self._loading,
			CanGoBack = false, CanGoNext = false, CanGoFirst = false, CanGoLast = false,
			ShowLeadingEllipsis = false, ShowTrailingEllipsis = false, ResetScroll = self._resetScroll,
		}
	end
	local pageCount = math.ceil(#self._cache / PAGE_SIZE)
	if self._page > pageCount then
		self._page = pageCount
		self._resetScroll = true
	end
	local prompt = self._friends:GetPromptState()
	local rows = {}
	local first = (self._page - 1) * PAGE_SIZE + 1
	local last = math.min(#self._cache, first + PAGE_SIZE - 1)
	for index = first, last do
		table.insert(rows, self:_rowFor(self._cache[index], snapshot, prompt))
	end
	return {
		Mode = "List", TitleText = title, FriendsOnlineText = friendsOnline, IsFull = full, Rows = rows,
		CanRefresh = not self._loading,
		CurrentPage = self._page, PageCount = pageCount,
		CanGoBack = self._page > 1, CanGoNext = self._page < pageCount,
		CanGoFirst = self._page > 1, CanGoLast = self._page < pageCount,
		ShowLeadingEllipsis = self._page > 2, ShowTrailingEllipsis = self._page < pageCount - 1,
		ResetScroll = self._resetScroll,
	}
end

function Controller:_presentationKey(presentation: Presentation): string
	local values = { presentation.Mode, presentation.TitleText, presentation.FriendsOnlineText, tostring(presentation.IsFull), tostring(presentation.CanRefresh), tostring(presentation.CurrentPage), tostring(presentation.PageCount), tostring(presentation.ResetScroll) }
	for _, row in presentation.Rows do
		table.insert(values, `{row.UserId}:{row.DisplayName}:{row.Username}:{row.Presence}:{row.State}:{row.Countdown or ""}:{row.CanInvite}:{row.ThumbnailContent or ""}`)
	end
	return table.concat(values, "|")
end

function Controller:_render(force: boolean?)
	self:_updateHud()
	if self._view == nil then
		return
	end
	local presentation = self:_presentation()
	local key = self:_presentationKey(presentation)
	if not force and key == self._lastPresentationKey then
		return
	end
	self._lastPresentationKey = key
	self._view:Render(presentation)
	self._resetScroll = false
end

function Controller:_groupInvitePresentation(): GroupInviteWindowView.Presentation
	local offer = if self._snapshot ~= nil then self._snapshot.IncomingOffer else nil
	if offer == nil then
		return {
			TitleText = "Group invitation",
			MessageText = "This invitation is no longer available.",
			CountdownText = "00:00",
			Processing = true,
		}
	end
	local remaining = math.ceil(math.max(0, offer.ExpiresAtServerTime - self._workspace:GetServerTimeNow()))
	local displayName = if offer.InviterDisplayName ~= "" then offer.InviterDisplayName else offer.InviterUsername
	return {
		TitleText = "Group invitation",
		MessageText = `{displayName} (@{offer.InviterUsername}) invites you to join their group.`,
		CountdownText = if offer.Status == "Processing" or self._offerResponding
			then `Processing · {formatRemaining(remaining)}`
			else `Expires in {formatRemaining(remaining)}`,
		Processing = offer.Status == "Processing" or self._offerResponding or remaining <= 0,
	}
end

function Controller:_reportGroupWindowOpenFailure(code: string)
	if self._offerOpenFailureCode == code then
		return
	end
	self._offerOpenFailureCode = code
	local logger = self._logger
	if logger ~= nil and typeof(logger.Warn) == "function" then
		logger:Warn("group_invite_window_open_failed", {
			WindowId = GROUP_WINDOW_ID,
			Code = code,
		})
	end
end

function Controller:_onGroupWindowResumed()
	self._defer(function()
		if self._state == "active" then
			self:_syncIncomingOffer()
		end
	end)
end

function Controller:_syncIncomingOffer()
	if self._state ~= "active" then
		return
	end
	local offer = if self._snapshot ~= nil then self._snapshot.IncomingOffer else nil
	local handle = self._offerWindowHandle
	if handle ~= nil and not handle:IsValid() then
		self._offerWindowHandle = nil
		self._offerView = nil
		handle = nil
	end
	if offer == nil then
		self._offerId = nil
		self._offerResponding = false
		self._offerResponseGeneration += 1
		if handle == nil or self._offerView == nil then
			self._offerClosePending = false
			return
		end
		if handle:IsActiveWindow() then
			self._offerClosePending = false
			self._offerView:CloseWindowAsync()
		else
			self._offerClosePending = true
		end
		return
	end
	if self._offerId ~= offer.OfferId then
		self._offerId = offer.OfferId
		self._offerResponding = false
		self._offerClosePending = false
		self._offerResponseGeneration += 1
	end
	if handle ~= nil and self._offerView ~= nil then
		self._offerClosePending = false
		self._offerView:Render(self:_groupInvitePresentation())
		return
	end
	local model = {
		GetPresentation = function()
			return self:_groupInvitePresentation()
		end,
		OnResumed = function()
			self:_onGroupWindowResumed()
		end,
	}
	local result
	if self._windowHandle ~= nil and self._windowHandle:IsValid() and self._windowHandle:IsActiveWindow()
		and self._view ~= nil
	then
		result = self._view:AddWindowTypedAsync(GroupInviteWindowDefinition, model)
	else
		result = (self._ui :: any).AddWindowTypedAsync(self._ui, GroupInviteWindowDefinition, model)
	end
	if result.Kind ~= "Success" then
		local code = if typeof(result.Error) == "table" and typeof(result.Error.Code) == "string"
			then result.Error.Code
			else "WindowOpenFailed"
		if code ~= "Busy" and code ~= "NotActiveWindow" and code ~= "DuplicateWindowId" then
			self:_reportGroupWindowOpenFailure(code)
		end
		return
	end
	self._offerOpenFailureCode = nil
	self._offerWindowHandle = result.Value
	local viewResult = self._offerWindowHandle:GetView()
	if viewResult.Kind ~= "Success" then
		self:_reportGroupWindowOpenFailure(
			if typeof(viewResult.Error) == "table" and typeof(viewResult.Error.Code) == "string"
				then viewResult.Error.Code
				else "WindowViewUnavailable"
		)
		self._offerWindowHandle = nil
		return
	end
	self._offerView = viewResult.Value
	self._offerView:Render(self:_groupInvitePresentation())
end

function Controller:_respondToIncomingOffer(decision: "Accept" | "Decline")
	local offer = if self._snapshot ~= nil then self._snapshot.IncomingOffer else nil
	if offer == nil or offer.OfferId ~= self._offerId or offer.Status ~= "Open" or self._offerResponding then
		return
	end
	self._offerResponding = true
	self._offerResponseGeneration += 1
	local generation = self._offerResponseGeneration
	if self._offerView ~= nil then
		self._offerView:Render(self:_groupInvitePresentation())
	end
	local result = self._friends:RespondToLocalOffer(offer.OfferId, decision, function(_category: string)
		if self._state ~= "active" or generation ~= self._offerResponseGeneration
			or self._offerId ~= offer.OfferId
		then
			return
		end
		if self._offerView ~= nil then
			self._offerView:Render(self:_groupInvitePresentation())
		end
	end)
	if typeof(result) ~= "table" or result.Ok ~= true then
		if generation == self._offerResponseGeneration and self._offerId == offer.OfferId then
			self._offerResponding = false
			if self._offerView ~= nil then
				self._offerView:Render(self:_groupInvitePresentation())
			end
		end
	end
end

function Controller:_notifyTemporaryFailure()
	pcall(function()
		self._starterGui:SetCore("SendNotification", {
			Title = "Invite failed",
			Text = "Please try again.",
			Duration = 5,
		})
	end)
end

function Controller:_applyInviteResult(userId: number, category: string)
	if self._state ~= "active" then
		return
	end
	if category == "InviteUnavailable" or category == "TargetUnavailable" or category == "TargetIneligible"
		or category == "TargetBusy" or category == "NotFriends"
	then
		self._localStates[userId] = "Unavailable"
	elseif category == "TechnicalError" or category == "InvalidTargetUserId" or category == "Stopped" or category == "NotOwner" then
		self._localStates[userId] = "Error"
	elseif category == "TemporaryError" or category == "AnotherPromptActive" or category == "NotReady" or category == "CommunicationUnavailable" then
		self._localStates[userId] = nil
		self:_notifyTemporaryFailure()
	elseif category == "Cancelled" or category == "PromptRequested" or category == "LocalOfferPresented"
		or category == "ReserveRefreshed" or category == "NoCapacity"
	then
		self._localStates[userId] = nil
	end
	self:_render()
end

function Controller:_requestInvite(userId: number)
	if self._loading or self._snapshot == nil
		or self._friends:GetPromptState().IsBusy == true
	then
		return
	end
	local row = nil
	if self._cache ~= nil then
		for _, entry in self._cache do
			if entry.UserId == userId then
				row = self:_rowFor(entry, self._snapshot, self._friends:GetPromptState())
				break
			end
		end
	end
	if row == nil or not row.CanInvite then
		return
	end
	local result = self._friends:RequestInvite(userId, function(category: string)
		self:_applyInviteResult(userId, category)
	end)
	if typeof(result) == "table" and result.Ok ~= true then
		self:_applyInviteResult(userId, result.Error)
	end
end

function Controller:_invalidateRemovedConnected(previous: any, current: any): boolean
	if self._cache == nil or typeof(previous) ~= "table" or typeof(current) ~= "table"
		or typeof(previous.ConnectedUserIds) ~= "table" or typeof(current.ConnectedUserIds) ~= "table"
	then
		return false
	end
	local currentConnected = {} :: { [number]: boolean }
	for _, userId in current.ConnectedUserIds do
		currentConnected[userId] = true
	end
	local removed = {} :: { [number]: boolean }
	for _, userId in previous.ConnectedUserIds do
		if currentConnected[userId] ~= true then
			removed[userId] = true
		end
	end
	local invalidated = false
	for _, entry in self._cache do
		if removed[entry.UserId] == true then
			entry.Presence = "Unknown"
			invalidated = true
		end
	end
	return invalidated
end

function Controller:_loadFriends(background: boolean)
	if self._loading or self._state ~= "active" then
		return
	end
	self._loading = true
	if not background then
		self._firstLoadFailed = false
	end
	self:_render()
	self._generation += 1
	local generation = self._generation
	self._spawn(function()
		local ok, entriesOrError = xpcall(function()
			local localPlayer = self._players:GetLocalPlayer()
			local pages = self._getFriends(localPlayer.UserId)
			local entries = {} :: { FriendEntry }
			while true do
				local page = pages:GetCurrentPage()
				for _, raw in page do
					local entry = copiedEntry(raw)
					if entry ~= nil then
						table.insert(entries, entry)
					end
				end
				if pages.IsFinished then
					break
				end
				pages:AdvanceToNextPageAsync()
			end
			if #entries > 0 then
				local online = {}
				local presenceOk, presence = pcall(function()
					return self._getFriendsOnline(localPlayer, #entries)
				end)
				if presenceOk and typeof(presence) == "table" then
					for _, visitor in presence do
						if typeof(visitor) == "table" and finitePositiveInteger(visitor.VisitorId) then
							online[visitor.VisitorId] = true
						end
					end
				end
				for _, entry in entries do
					entry.Presence = if online[entry.UserId] then "Online" else "Offline"
				end
			end
			table.sort(entries, compareEntries)
			return entries
		end, debug.traceback)
		if self._state ~= "active" or generation ~= self._generation then
			return
		end
		if self._presenceInvalidatedLoadGeneration == generation then
			self._presenceInvalidatedLoadGeneration = nil
			self._loading = false
			self:_loadFriends(true)
			return
		end
		self._loading = false
		if not ok then
			if self._cache == nil then
				self._firstLoadFailed = true
			end
			self:_render()
			return
		end
		self._cache = entriesOrError :: { FriendEntry }
		self._firstLoadFailed = false
		if not background then
			table.clear(self._localStates)
			if typeof(self._friends.NotifyRefreshSucceeded) == "function" then
				self._friends:NotifyRefreshSucceeded()
			end
		end
		local pageCount = math.max(1, math.ceil(#self._cache / PAGE_SIZE))
		if self._page > pageCount then
			self._page = pageCount
			self._resetScroll = true
		end
		self:_render(true)
		for _, entry in self._cache do
			self:_loadThumbnail(entry, generation)
		end
	end)
end

function Controller:_loadThumbnail(entry: FriendEntry, generation: number)
	self._spawn(function()
		local ok, content, ready = pcall(function()
			return self._getThumbnail(entry.UserId)
		end)
		if self._state ~= "active" or generation ~= self._generation or not ok or ready ~= true or typeof(content) ~= "string" then
			return
		end
		entry.ThumbnailContent = content
		self:_render()
	end)
end

function Controller:_openWindow()
	if self._snapshot == nil or self._snapshot.IsSlotOwner ~= true then
		return
	end
	if self._snapshot.IncomingOffer ~= nil then
		self:_syncIncomingOffer()
		return
	end
	if self._windowHandle ~= nil and self._windowHandle:IsValid() then
		return
	end
	table.clear(self._localStates)
	self._lastPresentationKey = nil
	local model = {
		GetPresentation = function()
			return self:_presentation()
		end,
	}
	local result = (self._ui :: any).AddWindowTypedAsync(self._ui, InviteFriendsWindowDefinition, model)
	if result.Kind ~= "Success" then
		self:_reportWindowOpenFailure(
			if typeof(result.Error) == "table" and typeof(result.Error.Code) == "string"
				then result.Error.Code
				else "WindowOpenFailed"
		)
		return
	end
	self._lastWindowOpenFailureCode = nil
	self._windowHandle = result.Value
	local viewResult = self._windowHandle:GetView()
	if viewResult.Kind ~= "Success" then
		self:_reportWindowOpenFailure(
			if typeof(viewResult.Error) == "table" and typeof(viewResult.Error.Code) == "string"
				then viewResult.Error.Code
				else "WindowViewUnavailable"
		)
		self._windowHandle = nil
		return
	end
	self._view = viewResult.Value
	self._resetScroll = true
	self:_loadFriends(self._cache ~= nil)
end

function Controller:_setPage(page: number)
	if self._cache == nil or #self._cache == 0 then
		return
	end
	local pageCount = math.ceil(#self._cache / PAGE_SIZE)
	local target = math.clamp(page, 1, pageCount)
	if target ~= self._page then
		self._page = target
		self._resetScroll = true
		self:_render(true)
	end
end

function Controller:_handleWindowAction(action: string, userId: number?)
	if action == "close" and self._view ~= nil then
		self._view:CloseWindowAsync()
	elseif action == "refresh" then
		self:_loadFriends(false)
	elseif action == "back" then
		self:_setPage(self._page - 1)
	elseif action == "first" then
		self:_setPage(1)
	elseif action == "last" and self._cache ~= nil then
		self:_setPage(math.ceil(#self._cache / PAGE_SIZE))
	elseif action == "next" then
		self:_setPage(self._page + 1)
	elseif action == "invite" and userId ~= nil then
		self:_requestInvite(userId)
	end
end

function Controller:_onUiEvent(event: any)
	if self._state ~= "active" or typeof(event) ~= "table" then
		return
	end
	if event.ActionId == WINDOW_CLOSED and event.WindowId == WINDOW_ID then
		self._windowHandle = nil
		self._view = nil
		self._lastPresentationKey = nil
		return
	end
	if event.ActionId == WINDOW_CLOSED and event.WindowId == GROUP_WINDOW_ID then
		self._offerWindowHandle = nil
		self._offerView = nil
		self._offerClosePending = false
		if self._snapshot ~= nil and self._snapshot.IncomingOffer ~= nil then
			self._defer(function()
				self:_syncIncomingOffer()
			end)
		end
		return
	end
	if event.ActionId ~= BUTTON_ACTIVATED then
		return
	end
	if event.UIElementId == HUD_ID then
		self:_openWindow()
		return
	end
	if self._offerView ~= nil and event.WindowId == GROUP_WINDOW_ID then
		local action = self._offerView:GetAction(event.UIElementId)
		if action == "accept" then
			self:_respondToIncomingOffer("Accept")
		elseif action == "decline" then
			self:_respondToIncomingOffer("Decline")
		end
		return
	end
	if self._view ~= nil and event.WindowId == WINDOW_ID then
		local action, userId = self._view:GetAction(event.UIElementId)
		if action ~= nil then
			self:_handleWindowAction(action, userId)
		end
	end
end

function Controller:Initialize()
	if self._state == "active" then
		return
	end
	if self._state ~= "fresh" then
		error("FriendInvitationsUiControllerTerminal", 2)
	end
	local resolved, templateOrProblem = xpcall(function()
		return self._assets:RequireByKey(HUD_ASSET_KEY, "TextButton")
	end, debug.traceback)
	if not resolved then
		self._state = "failed"
		error("FriendInvitationsHudAssetUnavailable", 0)
	end
	local template = templateOrProblem :: Instance
	local templateBinding, templateProblem = InviteFriendsHudPrefabValidator.Validate(template)
	if templateBinding == nil then
		self._state = "failed"
		error(`FriendInvitationsHudAssetInvalid:{templateProblem or "PrefabMalformed"}`, 0)
	end
	local buttonInstance = templateBinding.Root:Clone()
	if buttonInstance == nil or not buttonInstance:IsA("TextButton") then
		self._state = "failed"
		error("FriendInvitationsHudCloneInvalid:PrefabMalformed", 0)
	end
	local button = buttonInstance :: TextButton
	local cloneBinding, cloneProblem = InviteFriendsHudPrefabValidator.Validate(button)
	if cloneBinding == nil then
		self._state = "failed"
		button:Destroy()
		error(`FriendInvitationsHudCloneInvalid:{cloneProblem or "PrefabMalformed"}`, 0)
	end
	local hudController = ButtonController.new(
		button,
		HUD_ID,
		true,
		self._ui:GetUiElementContext(),
		self._hudInputSignals
	)
	local initialized = hudController:Initialize()
	if initialized.Kind == "Error" then
		self._state = "failed"
		hudController:Clear()
		button:Destroy()
		error(`FriendInvitationsHudInitializationFailed:{initialized.Error.Code}`, 0)
	end
	self._state = "active"
	self._hudButton = button
	self._hudCapacity = cloneBinding.Capacity
	self._hudController = hudController
	self._snapshot = self:_getSnapshot()
	self:_updateHud()
	button.Parent = self._ui:GetHudHost()
	self._uiConnection = self._ui.Events:Connect(function(event: any)
		self:_onUiEvent(event)
	end)
	self._snapshotConnection = self._friends.SnapshotChanged:Connect(function(payload: any)
		if self._state == "active" and typeof(payload) == "table" then
			local previous = self._snapshot or payload.Previous
			self._snapshot = payload.Current
			local invalidated = self:_invalidateRemovedConnected(previous, payload.Current)
			self:_syncIncomingOffer()
			if invalidated and self._loading then
				self._presenceInvalidatedLoadGeneration = self._generation
				self:_render()
			elseif invalidated and self._view ~= nil and self._cache ~= nil then
				self:_loadFriends(true)
			else
				self:_render()
			end
		end
	end)
	self._promptConnection = self._friends.PromptStateChanged:Connect(function()
		if self._state == "active" then
			self:_render()
		end
	end)
	if self._friends.RefreshSucceeded ~= nil and typeof(self._friends.RefreshSucceeded.Connect) == "function" then
		self._refreshConnection = self._friends.RefreshSucceeded:Connect(function()
			if self._state == "active" then
				table.clear(self._localStates)
				self:_render()
			end
		end)
	end
	self._frameConnection = self._frameSignal:Connect(function()
		if self._state == "active" then
			if self._view ~= nil then
				self:_render()
			end
			if self._offerView ~= nil then
				self._offerView:Render(self:_groupInvitePresentation())
			end
			self:_syncIncomingOffer()
		end
	end)
	self:_render(true)
	self:_syncIncomingOffer()
end

function Controller:Stop()
	if self._state == "stopped" then
		return
	end
	self._state = "stopped"
	self._generation += 1
	self._offerResponseGeneration += 1
	disconnect(self._uiConnection)
	disconnect(self._snapshotConnection)
	disconnect(self._promptConnection)
	disconnect(self._refreshConnection)
	disconnect(self._frameConnection)
	self._uiConnection = nil
	self._snapshotConnection = nil
	self._promptConnection = nil
	self._refreshConnection = nil
	self._frameConnection = nil
	if self._offerWindowHandle ~= nil and self._offerWindowHandle:IsValid()
		and self._offerWindowHandle:IsActiveWindow() and self._offerView ~= nil
	then
		pcall(function()
			self._offerView:CloseWindowAsync()
		end)
	end
	self._offerWindowHandle = nil
	self._offerView = nil
	self._offerId = nil
	self._offerResponding = false
	self._offerClosePending = false
	if self._windowHandle ~= nil and self._windowHandle:IsValid()
		and self._windowHandle:IsActiveWindow() and self._view ~= nil
	then
		pcall(function()
			self._view:CloseWindowAsync()
		end)
	end
	self._windowHandle = nil
	self._view = nil
	if self._hudController ~= nil then
		self._hudController:Clear()
		self._hudController = nil
	end
	if self._hudButton ~= nil then
		self._hudButton:Destroy()
		self._hudButton = nil
	end
	self._hudCapacity = nil
	self._snapshot = nil
	self._cache = nil
	self._presenceInvalidatedLoadGeneration = nil
	table.clear(self._localStates)
end

return Controller
