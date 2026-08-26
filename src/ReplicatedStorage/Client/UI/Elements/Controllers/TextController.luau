--!strict
local BaseUiElement = require(script.Parent.Parent.BaseUiElement)
local Controller = {}
Controller.__index = Controller
setmetatable(Controller, { __index = BaseUiElement })
function Controller.new(root: GuiObject, id: string, navigation: boolean, context: any)
	assert(root:IsA("TextLabel") or root:IsA("TextButton") or root:IsA("TextBox"), "TextController requires text presentation")
	local self = BaseUiElement.new(root, id, navigation, context) :: any
	return setmetatable(self, Controller)
end
return Controller
