--!strict
local BaseUiElement = require(script.Parent.Parent.BaseUiElement)
local Controller = {}
Controller.__index = Controller
setmetatable(Controller, { __index = BaseUiElement })
function Controller.new(root: GuiObject, id: string, navigation: boolean, context: any)
	assert(root:IsA("ImageLabel") or root:IsA("ImageButton"), "ImageController requires image presentation")
	local self = BaseUiElement.new(root, id, navigation, context) :: any
	return setmetatable(self, Controller)
end
return Controller
