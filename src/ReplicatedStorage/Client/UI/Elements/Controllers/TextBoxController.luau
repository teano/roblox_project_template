--!strict
local BaseUiElement = require(script.Parent.Parent.BaseUiElement)
local UiActionIds = require(script.Parent.Parent.Parent.Actions.UiActionIds)
local Controller = {}
Controller.__index = Controller
setmetatable(Controller, { __index = BaseUiElement })
function Controller.new(root: TextBox, id: string, navigation: boolean, context: any, inputSignals: any?)
	assert(root:IsA("TextBox"), "TextBoxController requires TextBox")
	local self = BaseUiElement.new(root, id, navigation, context, inputSignals) :: any
	setmetatable(self, Controller)
	self:_Connect(if inputSignals then inputSignals.Focused else root.Focused, function()
		self:EmitAction(UiActionIds.TextBoxFocused)
	end)
	self:_Connect(if inputSignals then inputSignals.FocusLost else root.FocusLost, function(enterPressed: boolean)
		self:EmitAction(UiActionIds.TextBoxUnfocused, { Confirmed = enterPressed })
		if enterPressed then
			self:EmitAction(UiActionIds.TextBoxConfirmed, { Confirmed = true })
		end
	end)
	return self
end
function Controller:GetValue(): string
	return (self.Root :: TextBox).Text
end
return Controller
