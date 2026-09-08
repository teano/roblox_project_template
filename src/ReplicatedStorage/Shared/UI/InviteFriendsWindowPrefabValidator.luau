--!strict

export type FriendRowBinding = {
	Root: Frame,
	Avatar: ImageLabel,
	DisplayName: TextLabel,
	Username: TextLabel,
	PresenceIndicator: Frame,
	PresenceCorner: UICorner,
	Presence: TextLabel,
	State: TextLabel,
	Invite: TextButton,
}

export type WindowBinding = {
	Root: GuiObject,
	Background: GuiButton,
	Content: Frame,
	Panel: Frame,
	SizeConstraint: UISizeConstraint,
	Title: TextLabel,
	Close: ImageButton,
	IconLine1: Frame,
	IconLine2: Frame,
	NoSlots: TextLabel,
	SummaryRow: Frame,
	FriendsOnline: TextLabel,
	Status: TextLabel,
	FriendsList: ScrollingFrame,
	Rows: Frame,
	RowsLayout: UIListLayout,
	FriendRowTemplate: Frame,
	FriendRow: FriendRowBinding,
	Refresh: TextButton,
	Pages: Frame,
	PagesLayout: UIListLayout,
	Back: TextButton,
	First: TextButton,
	LeadingEllipsis: TextLabel,
	CurrentPage: TextLabel,
	TrailingEllipsis: TextLabel,
	Last: TextButton,
	Next: TextButton,
}

local Validator = {}

local function direct(parent: Instance, name: string, className: string): Instance?
	local match: Instance? = nil
	local count = 0
	for _, child in parent:GetChildren() do
		if child.Name == name then
			count += 1
			match = child
		end
	end
	if count ~= 1 or match == nil or not match:IsA(className) then
		return nil
	end
	return match
end

function Validator.BindFriendRow(root: Instance?): (FriendRowBinding?, string?)
	if root == nil or not root:IsA("Frame") then
		return nil, "PrefabMalformed"
	end
	local avatar = direct(root, "Avatar", "ImageLabel")
	local displayName = direct(root, "DisplayName", "TextLabel")
	local username = direct(root, "Username", "TextLabel")
	local presenceIndicator = direct(root, "PresenceIndicator", "Frame")
	local presence = direct(root, "Presence", "TextLabel")
	local state = direct(root, "State", "TextLabel")
	local invite = direct(root, "Invite", "TextButton")
	if avatar == nil
		or displayName == nil
		or username == nil
		or presenceIndicator == nil
		or presence == nil
		or state == nil
		or invite == nil
	then
		return nil, "PrefabMalformed"
	end
	local presenceCorner = direct(presenceIndicator, "UICorner", "UICorner")
	if presenceCorner == nil then
		return nil, "PrefabMalformed"
	end
	return table.freeze({
		Root = root :: Frame,
		Avatar = avatar :: ImageLabel,
		DisplayName = displayName :: TextLabel,
		Username = username :: TextLabel,
		PresenceIndicator = presenceIndicator :: Frame,
		PresenceCorner = presenceCorner :: UICorner,
		Presence = presence :: TextLabel,
		State = state :: TextLabel,
		Invite = invite :: TextButton,
	}), nil
end

function Validator.Validate(root: Instance?): (WindowBinding?, string?)
	if root == nil or not root:IsA("GuiObject") or not root.Archivable then
		return nil, "PrefabMalformed"
	end
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("LuaSourceContainer") then
			return nil, "ForbiddenExecutableDescendant"
		end
	end

	local background = direct(root, "Background", "GuiButton")
	local content = direct(root, "Content", "Frame")
	if background == nil or content == nil then
		return nil, "PrefabMalformed"
	end
	local panel = direct(content, "Panel", "Frame")
	if panel == nil then
		return nil, "PrefabMalformed"
	end

	local sizeConstraint = direct(panel, "UISizeConstraint", "UISizeConstraint")
	local title = direct(panel, "Title", "TextLabel")
	local close = direct(panel, "Close", "ImageButton")
	local summaryRow = direct(panel, "SummaryRow", "Frame")
	local friendsList = direct(panel, "FriendsList", "ScrollingFrame")
	local pages = direct(panel, "Pages", "Frame")
	if sizeConstraint == nil
		or title == nil
		or close == nil
		or summaryRow == nil
		or friendsList == nil
		or pages == nil
	then
		return nil, "PrefabMalformed"
	end

	local iconLine1 = direct(close, "IconLine1", "Frame")
	local iconLine2 = direct(close, "IconLine2", "Frame")
	local friendsOnline = direct(summaryRow, "FriendsOnline", "TextLabel")
	local refresh = direct(summaryRow, "Refresh", "TextButton")
	local status = direct(friendsList, "Status", "TextLabel")
	local noSlots = direct(friendsList, "NoSlots", "TextLabel")
	local rows = direct(friendsList, "Rows", "Frame")
	local pagesLayout = direct(pages, "UIListLayout", "UIListLayout")
	if iconLine1 == nil or iconLine2 == nil or friendsOnline == nil or refresh == nil
		or status == nil or noSlots == nil or rows == nil or pagesLayout == nil
	then
		return nil, "PrefabMalformed"
	end
	if not friendsList.Active
		or not friendsList.ScrollingEnabled
		or not friendsList.ClipsDescendants
		or friendsList.ScrollingDirection ~= Enum.ScrollingDirection.Y
		or friendsList.AutomaticCanvasSize ~= Enum.AutomaticSize.Y
		or friendsList.CanvasSize ~= UDim2.new(0, 0, 0, 0)
		or (rows :: Frame).AutomaticSize ~= Enum.AutomaticSize.Y
		or (rows :: Frame).Position ~= UDim2.new(0, 0, 0, 0)
		or (rows :: Frame).Size.X.Scale ~= 1
		or (rows :: Frame).Size.X.Offset ~= 0
		or (rows :: Frame).Size.Y.Scale ~= 0
		or (rows :: Frame).Size.Y.Offset ~= 0
		or (pagesLayout :: UIListLayout).FillDirection ~= Enum.FillDirection.Horizontal
	then
		return nil, "PrefabMalformed"
	end
	local rowsLayout = direct(rows, "UIListLayout", "UIListLayout")
	local friendRowTemplate = direct(rows, "FriendRowTemplate", "Frame")
	if rowsLayout == nil
		or friendRowTemplate == nil
		or (friendRowTemplate :: Frame).Visible
		or not friendRowTemplate.Archivable
	then
		return nil, "PrefabMalformed"
	end
	local friendRow, friendRowProblem = Validator.BindFriendRow(friendRowTemplate)
	if friendRow == nil then
		return nil, friendRowProblem or "PrefabMalformed"
	end

	local back = direct(pages, "Back", "TextButton")
	local first = direct(pages, "First", "TextButton")
	local leadingEllipsis = direct(pages, "LeadingEllipsis", "TextLabel")
	local currentPage = direct(pages, "CurrentPage", "TextLabel")
	local trailingEllipsis = direct(pages, "TrailingEllipsis", "TextLabel")
	local last = direct(pages, "Last", "TextButton")
	local next = direct(pages, "Next", "TextButton")
	if back == nil
		or first == nil
		or leadingEllipsis == nil
		or currentPage == nil
		or trailingEllipsis == nil
		or last == nil
		or next == nil
	then
		return nil, "PrefabMalformed"
	end

	return table.freeze({
		Root = root :: GuiObject,
		Background = background :: GuiButton,
		Content = content :: Frame,
		Panel = panel :: Frame,
		SizeConstraint = sizeConstraint :: UISizeConstraint,
		Title = title :: TextLabel,
		Close = close :: ImageButton,
		IconLine1 = iconLine1 :: Frame,
		IconLine2 = iconLine2 :: Frame,
		NoSlots = noSlots :: TextLabel,
		SummaryRow = summaryRow :: Frame,
		FriendsOnline = friendsOnline :: TextLabel,
		Status = status :: TextLabel,
		FriendsList = friendsList :: ScrollingFrame,
		Rows = rows :: Frame,
		RowsLayout = rowsLayout :: UIListLayout,
		FriendRowTemplate = friendRowTemplate :: Frame,
		FriendRow = friendRow,
		Refresh = refresh :: TextButton,
		Pages = pages :: Frame,
		PagesLayout = pagesLayout :: UIListLayout,
		Back = back :: TextButton,
		First = first :: TextButton,
		LeadingEllipsis = leadingEllipsis :: TextLabel,
		CurrentPage = currentPage :: TextLabel,
		TrailingEllipsis = trailingEllipsis :: TextLabel,
		Last = last :: TextButton,
		Next = next :: TextButton,
	}), nil
end

return table.freeze(Validator)
