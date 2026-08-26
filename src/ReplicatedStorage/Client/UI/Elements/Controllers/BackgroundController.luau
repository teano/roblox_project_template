--!strict

local Controller = {}
Controller.__index = Controller

local function validBackground(root: GuiObject, background: GuiButton): boolean
	if background.Parent ~= root
		or background.Position ~= UDim2.fromScale(0, 0)
		or background.Size ~= UDim2.fromScale(1, 1)
		or not background.Visible
	then
		return false
	end
	for _, sibling in root:GetChildren() do
		if sibling ~= background and sibling:IsA("GuiObject") and sibling.ZIndex <= background.ZIndex then
			return false
		end
	end
	return true
end

function Controller.new(view: any, policy: string)
	if policy == "None" then
		return setmetatable({ _connection = nil }, Controller), nil
	end
	local found = view.Root:FindFirstChild("Background")
	if found == nil or not found:IsA("GuiButton") or not validBackground(view.Root, found) then
		return nil, { Code = "InvalidBackground" }
	end
	local self = setmetatable({ _connection = nil }, Controller)
	self._connection = found.Activated:Connect(function()
		if not view:_CanAcceptUserAction() then
			return
		end
		if policy == "CloseOnActivate" then
			view:CloseWindowAsync()
		end
	end)
	return self, nil
end

function Controller:Clear()
	if self._connection ~= nil then
		self._connection:Disconnect()
		self._connection = nil
	end
end

return Controller
