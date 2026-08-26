--!strict
local BaseUiElement = require(script.Parent.Parent.BaseUiElement)
local UiActionIds = require(script.Parent.Parent.Parent.Actions.UiActionIds)
local Controller = {}
Controller.__index = Controller
setmetatable(Controller, { __index = BaseUiElement })
function Controller.new(root: GuiObject, id: string, context: any)
	local self = BaseUiElement.new(root, id, false, context) :: any
	self._fields = {}
	return setmetatable(self, Controller)
end
function Controller:AddField(name: string, field: any)
	assert(name ~= "" and self._fields[name] == nil, "Form field name must be unique")
	local result = self:AddNestedUiElement(field)
	if result.Kind == "Success" then
		self._fields[name] = field
	end
	return result
end
function Controller:RemoveNestedUiElement(child: any, nominatedReplacementDefault: GuiObject?)
	local result = BaseUiElement.RemoveNestedUiElement(self, child, nominatedReplacementDefault)
	if result.Kind == "Success" then
		for name, field in self._fields do
			if field == child then
				self._fields[name] = nil
			end
		end
	end
	return result
end
function Controller:GetFieldValue(name: string): string?
	local field = self._fields[name]
	return if field then field:GetValue() else nil
end
function Controller:Submit(payload: any?)
	return self:EmitAction(UiActionIds.FormSubmitted, payload)
end
function Controller:Cancel(payload: any?)
	return self:EmitAction(UiActionIds.FormCancelled, payload)
end
function Controller:OnClear()
	table.clear(self._fields)
end
return Controller
