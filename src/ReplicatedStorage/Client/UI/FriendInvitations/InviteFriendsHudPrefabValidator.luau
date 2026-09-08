--!strict

export type Binding = {
	Root: TextButton,
	Capacity: TextLabel,
	Padding: UIPadding,
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
		or root.Name ~= "InviteFriends"
		or not root:IsA("TextButton")
		or not root.Archivable
	then
		return nil, "PrefabMalformed"
	end
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("LuaSourceContainer") then
			return nil, "ForbiddenExecutableDescendant"
		end
	end
	local capacity = direct(root, "Capacity", "TextLabel")
	local padding = direct(root, "UIPadding", "UIPadding")
	if capacity == nil or padding == nil then
		return nil, "PrefabMalformed"
	end
	return table.freeze({
		Root = root :: TextButton,
		Capacity = capacity :: TextLabel,
		Padding = padding :: UIPadding,
	}), nil
end

return table.freeze(Validator)
