--!strict

export type Binding = {
	Root: GuiObject,
	Background: GuiButton,
	Content: Frame,
	Panel: Frame,
	SizeConstraint: UISizeConstraint,
	Corner: UICorner,
	Stroke: UIStroke,
	Title: TextLabel,
	Message: TextLabel,
	Countdown: TextLabel,
	Actions: Frame,
	ActionsLayout: UIListLayout,
	Decline: TextButton,
	Accept: TextButton,
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

function Validator.Validate(root: Instance?): (Binding?, string?)
	if root == nil
		or root.Name ~= "GroupInviteWindow"
		or not root:IsA("GuiObject")
		or not root.Archivable
		or root:GetAttribute("AssetKey") ~= "game.ui.window.group-invite"
	then
		return nil, "PrefabMalformed"
	end
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("LuaSourceContainer") then
			return nil, "ForbiddenExecutableDescendant"
		end
		if descendant.Name == "Close" or descendant.Name == "InputSink" then
			return nil, "PrefabMalformed"
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
	local corner = direct(panel, "UICorner", "UICorner")
	local stroke = direct(panel, "UIStroke", "UIStroke")
	local title = direct(panel, "Title", "TextLabel")
	local message = direct(panel, "Message", "TextLabel")
	local countdown = direct(panel, "Countdown", "TextLabel")
	local actions = direct(panel, "Actions", "Frame")
	if sizeConstraint == nil or corner == nil or stroke == nil or title == nil
		or message == nil or countdown == nil or actions == nil
	then
		return nil, "PrefabMalformed"
	end
	local actionsLayout = direct(actions, "UIListLayout", "UIListLayout")
	local decline = direct(actions, "Decline", "TextButton")
	local accept = direct(actions, "Accept", "TextButton")
	if actionsLayout == nil or decline == nil or accept == nil then
		return nil, "PrefabMalformed"
	end
	return table.freeze({
		Root = root :: GuiObject,
		Background = background :: GuiButton,
		Content = content :: Frame,
		Panel = panel :: Frame,
		SizeConstraint = sizeConstraint :: UISizeConstraint,
		Corner = corner :: UICorner,
		Stroke = stroke :: UIStroke,
		Title = title :: TextLabel,
		Message = message :: TextLabel,
		Countdown = countdown :: TextLabel,
		Actions = actions :: Frame,
		ActionsLayout = actionsLayout :: UIListLayout,
		Decline = decline :: TextButton,
		Accept = accept :: TextButton,
	}), nil
end

return table.freeze(Validator)
