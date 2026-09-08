--!strict

local Registry = {}
Registry.__index = Registry

local DIRECTIONS = {
	Up = "NextSelectionUp",
	Down = "NextSelectionDown",
	Left = "NextSelectionLeft",
	Right = "NextSelectionRight",
}

local function collectEligible(controller: any, output: { any })
	if controller.UINavigationEnabled then
		table.insert(output, controller)
	end
	for _, child in controller.NestedUiElements do
		collectEligible(child, output)
	end
end

local function containsController(controller: any, target: any): boolean
	if controller == target then
		return true
	end
	for _, child in controller.NestedUiElements do
		if containsController(child, target) then
			return true
		end
	end
	return false
end

local function failure()
	return { Kind = "Error", Error = { Code = "InvalidDefaultNavigation" } }
end

local function success()
	return { Kind = "Success" }
end

local function authoredFocusable(root: GuiObject?): boolean
	return root ~= nil and root.Selectable and root.Interactable
end

local function makeMemberRecord(controller: any, root: GuiObject): any
	local directions = {}
	for _, property in DIRECTIONS do
		directions[property] = (root :: any)[property]
	end
	return {
		Controller = controller,
		Authored = table.freeze({
			Selectable = root.Selectable,
			Interactable = root.Interactable,
			Directions = table.freeze(directions),
		}),
		Dynamic = {
			Selectable = true,
			Interactable = true,
		},
	}
end

function Registry.new(guiService: any?)
	return setmetatable({
		_guiService = guiService,
		_members = {} :: { [any]: any },
		_default = nil,
		_overrides = {},
		_active = false,
		_blocked = false,
		_initialized = false,
		_lastSelected = nil,
	}, Registry)
end

function Registry:_selected()
	return if self._guiService ~= nil then self._guiService.SelectedObject else nil
end

function Registry:_setSelected(value: GuiObject?)
	if self._guiService ~= nil then
		self._guiService.SelectedObject = value
	end
end

function Registry:_isMemberRoot(root: any): boolean
	return self._members[root] ~= nil
end

function Registry:_canFocus(root: any): boolean
	local record = self._members[root]
	return record ~= nil
		and record.Authored.Selectable
		and record.Authored.Interactable
		and record.Dynamic.Selectable
		and record.Dynamic.Interactable
end

function Registry:_authoredDirection(record: any, property: string): GuiObject?
	local target = record.Authored.Directions[property]
	if target ~= nil and self:_isMemberRoot(target) and not self:_canFocus(target) then
		return nil
	end
	return target
end

function Registry:_applyOverride(override: any, enabled: boolean)
	local from = override.From
	local target = override.To
	local property = DIRECTIONS[override.Direction]
	local fromRecord = self._members[from]
	if property ~= nil and fromRecord ~= nil then
		if enabled and self:_canFocus(from) and self:_canFocus(target) then
			(from :: any)[property] = target
		else
			(from :: any)[property] = if enabled and self:_canFocus(from)
				then self:_authoredDirection(fromRecord, property) else nil
		end
	end
end

function Registry:_applyEligibility(takeFocus: boolean?)
	local enabled = self._initialized and self._active and not self._blocked
	local selected = self:_selected()
	if enabled and takeFocus and selected ~= nil and not self:_isMemberRoot(selected) then
		self:_setSelected(nil)
		selected = nil
	end
	if selected ~= nil and self:_isMemberRoot(selected) then
		if self:_canFocus(selected) then
			self._lastSelected = selected
		elseif self._lastSelected == selected then
			self._lastSelected = nil
		end
		if not enabled or not self:_canFocus(selected) then
			self:_setSelected(nil)
		end
	end
	if self._lastSelected ~= nil and not self:_canFocus(self._lastSelected) then
		self._lastSelected = nil
	end
	for root, record in self._members do
		root.Selectable = enabled and record.Authored.Selectable and record.Dynamic.Selectable
		root.Interactable = enabled and record.Authored.Interactable and record.Dynamic.Interactable
		for _, property in DIRECTIONS do
			(root :: any)[property] = if enabled and self:_canFocus(root)
				then self:_authoredDirection(record, property) else nil
		end
	end
	for _, override in self._overrides do
		self:_applyOverride(override, enabled)
	end
	if enabled and self:_selected() == nil then
		local target = if self._lastSelected ~= nil and self:_canFocus(self._lastSelected)
			then self._lastSelected else self._default
		if target ~= nil and self:_canFocus(target) then
			self:_setSelected(target)
		end
	end
end

function Registry:Initialize(rootController: any, defaultElement: GuiObject?, overrides: { any })
	self:Clear()
	local controllers = {}
	collectEligible(rootController, controllers)
	local roots = {}
	for _, controller in controllers do
		roots[controller.Root] = true
	end
	if (#controllers > 0 and (defaultElement == nil or not roots[defaultElement] or not authoredFocusable(defaultElement)))
		or (#controllers == 0 and defaultElement ~= nil)
	then
		return failure()
	end
	local seen = {} :: { [GuiObject]: { [string]: boolean } }
	local frozenOverrides = {}
	if typeof(overrides) ~= "table" then
		return failure()
	end
	for index, override in overrides do
		if index ~= #frozenOverrides + 1
			or typeof(override) ~= "table"
			or not roots[override.From]
			or not roots[override.To]
			or DIRECTIONS[override.Direction] == nil
		then
			return failure()
		end
		local fromSeen = seen[override.From]
		if fromSeen == nil then
			fromSeen = {}
			seen[override.From] = fromSeen
		end
		if fromSeen[override.Direction] then
			return failure()
		end
		fromSeen[override.Direction] = true
		table.insert(frozenOverrides, table.freeze({
			From = override.From,
			Direction = override.Direction,
			To = override.To,
		}))
	end
	for _, controller in controllers do
		local root = controller.Root
		self._members[root] = makeMemberRecord(controller, root)
	end
	self._default = defaultElement
	self._overrides = table.freeze(frozenOverrides)
	self._initialized = true
	self:_applyEligibility()
	return success()
end

function Registry:PrepareAdd(child: any, nominatedDefault: GuiObject?)
	if not self._initialized then
		return { Kind = "Success", Token = { Kind = "Uninitialized" } }
	end
	local controllers = {}
	collectEligible(child, controllers)
	local transitioning = next(self._members) == nil and #controllers > 0
	if transitioning then
		local valid = false
		for _, controller in controllers do
			if controller.Root == nominatedDefault and authoredFocusable(nominatedDefault) then
				valid = true
			end
		end
		if not valid then return failure() end
	elseif nominatedDefault ~= nil then
		return failure()
	end
	return { Kind = "Success", Token = { Kind = "Add", Controllers = controllers, Default = nominatedDefault } }
end

function Registry:CommitAdd(token: any)
	if token.Kind ~= "Add" then return end
	for _, controller in token.Controllers do
		local root = controller.Root
		self._members[root] = makeMemberRecord(controller, root)
	end
	if token.Default ~= nil then self._default = token.Default end
	self:_applyEligibility()
end

function Registry:PrepareRemove(child: any, nominatedDefault: GuiObject?)
	if not self._initialized then
		return { Kind = "Success", Token = { Kind = "Uninitialized" } }
	end
	local removed = {}
	for root, record in self._members do
		if containsController(child, record.Controller) then removed[root] = true end
	end
	local remaining = {}
	for root in self._members do if not removed[root] then remaining[root] = true end end
	local removesDefault = self._default ~= nil and removed[self._default] == true
	if removesDefault and next(remaining) ~= nil then
		if nominatedDefault == nil or not remaining[nominatedDefault] or not self:_canFocus(nominatedDefault) then
			return failure()
		end
	elseif nominatedDefault ~= nil then
		return failure()
	end
	return { Kind = "Success", Token = { Kind = "Remove", Removed = removed, Default = nominatedDefault } }
end

function Registry:CommitRemove(token: any)
	if token.Kind ~= "Remove" then return end
	local selected = self:_selected()
	for root in token.Removed do
		local record = self._members[root]
		if record ~= nil then
			root.Selectable = record.Authored.Selectable
			root.Interactable = record.Authored.Interactable
			for _, property in DIRECTIONS do
				(root :: any)[property] = record.Authored.Directions[property]
			end
			self._members[root] = nil
		end
	end
	if selected ~= nil and token.Removed[selected] then self:_setSelected(nil) end
	if self._lastSelected ~= nil and token.Removed[self._lastSelected] then self._lastSelected = nil end
	if self._default ~= nil and token.Removed[self._default] then self._default = token.Default end
	self:_applyEligibility()
end

function Registry:SetActive(active: boolean)
	local takeFocus = active and not self._active
	self._active = active
	self:_applyEligibility(takeFocus)
end

function Registry:SetBlocked(blocked: boolean)
	local takeFocus = self._blocked and not blocked
	self._blocked = blocked
	self:_applyEligibility(takeFocus)
end

function Registry:SetMemberEligibility(root: GuiObject, selectable: boolean, interactable: boolean): boolean
	local record = self._members[root]
	if record == nil then
		return false
	end
	record.Dynamic.Selectable = selectable
	record.Dynamic.Interactable = interactable
	self:_applyEligibility()
	return true
end

function Registry:Clear()
	if self._members ~= nil then
		local selected = self:_selected()
		if selected ~= nil and self:_isMemberRoot(selected) then self:_setSelected(nil) end
		for root, record in self._members do
			root.Selectable = record.Authored.Selectable
			root.Interactable = record.Authored.Interactable
			for _, property in DIRECTIONS do
				(root :: any)[property] = record.Authored.Directions[property]
			end
		end
	end
	self._members = {}
	self._default = nil
	self._overrides = {}
	self._lastSelected = nil
	self._active = false
	self._blocked = false
	self._initialized = false
	return success()
end

return Registry
