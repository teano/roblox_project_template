--!strict
local BaseUiElement = require(script.Parent.Parent.BaseUiElement)
local UiActionIds = require(script.Parent.Parent.Parent.Actions.UiActionIds)
local Controller = {}
Controller.__index = Controller
setmetatable(Controller, { __index = BaseUiElement })
function Controller.new(root: GuiButton, id: string, navigation: boolean, context: any, inputSignals: any?)
	assert(root:IsA("GuiButton"), "ButtonController requires GuiButton")
	local self = BaseUiElement.new(root, id, navigation, context, inputSignals) :: any
	setmetatable(self, Controller)
	self:_Connect(if inputSignals then inputSignals.Activated else root.Activated, function()
		self:EmitAction(UiActionIds.ButtonActivated)
	end)
	return self
end
return Controller
