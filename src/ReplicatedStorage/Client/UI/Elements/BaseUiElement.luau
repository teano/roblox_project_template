--!strict

local UiActionIds = require(script.Parent.Parent.Actions.UiActionIds)

export type UiVoidResult = { Kind: "Success" } | { Kind: "Error", Error: { Code: string } }

local BaseUiElement = {}
BaseUiElement.__index = BaseUiElement

local function success(): UiVoidResult
	return { Kind = "Success" }
end

local function failure(code: string): UiVoidResult
	return { Kind = "Error", Error = { Code = code } }
end

local function collectClaims(controller: any, output: { any })
	table.insert(output, { UIElementId = controller._claimedUIElementId or controller.UIElementId, Owner = controller })
	for _, child in controller.NestedUiElements do
		collectClaims(child, output)
	end
end

local function commitClaims(claims: { any })
	for _, claim in claims do
		claim.Owner._claimedUIElementId = claim.UIElementId
	end
end

local function usesContext(controller: any, context: any): boolean
	if controller._context ~= context then
		return false
	end
	for _, child in controller.NestedUiElements do
		if not usesContext(child, context) then
			return false
		end
	end
	return true
end

local function subtreeContains(controller: any, target: any, visited: { [any]: boolean }): boolean
	if controller == target then
		return true
	end
	if visited[controller] then
		return false
	end
	visited[controller] = true
	for _, child in controller.NestedUiElements do
		if subtreeContains(child, target, visited) then
			return true
		end
	end
	return false
end

local function setSubtreeState(controller: any, state: string)
	controller._state = state
	if state == "fresh" then
		controller._claimedUIElementId = nil
	end
	for _, child in controller.NestedUiElements do
		setSubtreeState(child, state)
	end
end

local function connectOwned(self: any, signal: any, callback: (...any) -> ())
	local connection = signal:Connect(callback)
	table.insert(self._connections, connection)
	return connection
end

local function activateSubtree(controller: any)
	controller._state = "initialized"
	if not controller._baseSignalsConnected then
		controller._baseSignalsConnected = true
		local inputSignals = controller._inputSignals
		connectOwned(controller, if inputSignals then inputSignals.MouseEnter else controller.Root.MouseEnter, function()
			controller:EmitAction(UiActionIds.PointerEntered)
		end)
		connectOwned(controller, if inputSignals then inputSignals.MouseLeave else controller.Root.MouseLeave, function()
			controller:EmitAction(UiActionIds.PointerExited)
		end)
	end
	for _, child in controller.NestedUiElements do
		activateSubtree(child)
	end
end

function BaseUiElement.new(root: GuiObject, uiElementId: string, uiNavigationEnabled: boolean, context: any, inputSignals: any?)
	assert(typeof(root) == "Instance" and root:IsA("GuiObject"), "BaseUiElement root must be a GuiObject")
	return setmetatable({
		Root = root,
		UIElementId = uiElementId,
		_claimedUIElementId = nil,
		UINavigationEnabled = uiNavigationEnabled,
		NestedUiElements = {},
		_context = context,
		_inputSignals = inputSignals,
		_parent = nil,
		_windowBinding = nil,
		_connections = {},
		_baseSignalsConnected = false,
		_state = "fresh",
	}, BaseUiElement)
end

function BaseUiElement:_Connect(signal: any, callback: (...any) -> ())
	return connectOwned(self, signal, callback)
end

function BaseUiElement:_CanEmitAction(): boolean
	local binding = self._windowBinding
	return binding == nil or binding:CanEmitAction()
end

function BaseUiElement:_ReceiveOwnedEvent(event: any, source: any): UiVoidResult
	if self._state ~= "initialized" then
		return failure("CleanupFailed")
	end
	if self._parent ~= nil then
		return self._parent:_ReceiveOwnedEvent(event, source)
	end
	return self._context:DeliverToRoot(event)
end

function BaseUiElement:EmitAction(actionId: string, payload: any?): UiVoidResult
	if self._state ~= "initialized" or not self:_CanEmitAction() then
		return failure("NotActiveWindow")
	end
	return self:_ReceiveOwnedEvent({
		ActionId = actionId,
		UIElementId = self._claimedUIElementId or self.UIElementId,
		Payload = payload,
	}, self)
end

function BaseUiElement:_SetWindowBinding(binding: any?)
	self._windowBinding = binding
	for _, child in self.NestedUiElements do
		child:_SetWindowBinding(binding)
	end
end

function BaseUiElement:Initialize(): UiVoidResult
	if self._state == "initialized" then
		return success()
	elseif self._state == "cleared" then
		self._state = "fresh"
		self._claimedUIElementId = nil
	elseif self._state ~= "fresh" then
		return failure("CleanupFailed")
	end
	local claims = {}
	collectClaims(self, claims)
	local claimed = self._context:ClaimSubtree(claims)
	if claimed.Kind == "Error" then
		return claimed
	end
	commitClaims(claims)
	activateSubtree(self)
	return success()
end

function BaseUiElement:AddNestedUiElement(child: any, nominatedDefault: GuiObject?): UiVoidResult
	if (self._state ~= "fresh" and self._state ~= "initialized")
		or child == self
		or child._parent ~= nil
		or child._state ~= "fresh"
		or subtreeContains(child, self, {})
		or not usesContext(child, self._context)
	then
		return failure("InvalidUIElementId")
	end
	local navigationToken = nil
	if self._windowBinding ~= nil then
		local prepared = self._windowBinding:PrepareAdd(child, nominatedDefault)
		if prepared.Kind == "Error" then
			return prepared
		end
		navigationToken = prepared.Token
	elseif nominatedDefault ~= nil then
		return failure("InvalidDefaultNavigation")
	end
	if self._state == "fresh" then
		child._parent = self
		child:_SetWindowBinding(self._windowBinding)
		table.insert(self.NestedUiElements, child)
		if self._windowBinding ~= nil then self._windowBinding:CommitAdd(navigationToken) end
		return success()
	end
	local claims = {}
	collectClaims(child, claims)
	local claimed = self._context:ClaimSubtree(claims)
	if claimed.Kind == "Error" then
		return claimed
	end
	commitClaims(claims)
	child._parent = self
	child:_SetWindowBinding(self._windowBinding)
	activateSubtree(child)
	table.insert(self.NestedUiElements, child)
	if self._windowBinding ~= nil then self._windowBinding:CommitAdd(navigationToken) end
	return success()
end

function BaseUiElement:RemoveNestedUiElement(child: any, nominatedReplacementDefault: GuiObject?): UiVoidResult
	if self._state ~= "fresh" and self._state ~= "initialized" then
		return failure("CleanupFailed")
	end
	local index = table.find(self.NestedUiElements, child)
	if index == nil then
		return failure("InvalidUIElementId")
	end
	local navigationToken = nil
	if self._windowBinding ~= nil then
		local prepared = self._windowBinding:PrepareRemove(child, nominatedReplacementDefault)
		if prepared.Kind == "Error" then
			return prepared
		end
		navigationToken = prepared.Token
	elseif nominatedReplacementDefault ~= nil then
		return failure("InvalidDefaultNavigation")
	end
	if self._state == "initialized" then
		local claims = {}
		collectClaims(child, claims)
		self._context:ReleaseSubtree(claims)
	end
	table.remove(self.NestedUiElements, index)
	child._parent = nil
	child:_SetWindowBinding(nil)
	setSubtreeState(child, "fresh")
	if self._windowBinding ~= nil then self._windowBinding:CommitRemove(navigationToken) end
	return success()
end

function BaseUiElement:OnClear()
end

local function callWithoutYield(callback: () -> ()): boolean
	local thread = coroutine.create(callback)
	local ok = coroutine.resume(thread)
	if not ok or coroutine.status(thread) ~= "dead" then
		if coroutine.status(thread) ~= "dead" then
			coroutine.close(thread)
		end
		return false
	end
	return true
end

function BaseUiElement:Clear(): UiVoidResult
	if self._state == "cleared" then
		return success()
	elseif self._state == "clearing" then
		return failure("CleanupFailed")
	end
	self._state = "clearing"
	local cleanupFailed = false
	local children = table.clone(self.NestedUiElements)
	local claims = {}
	collectClaims(self, claims)
	for _, child in children do
		if not callWithoutYield(function()
			local result = child:Clear()
			if result.Kind == "Error" then
				error(result.Error.Code)
			end
		end) then
			cleanupFailed = true
		end
	end
	table.clear(self.NestedUiElements)
	if not callWithoutYield(function()
		self:OnClear()
	end) then
		cleanupFailed = true
	end
	for _, connection in self._connections do
		if not pcall(function()
			connection:Disconnect()
		end) then
			cleanupFailed = true
		end
	end
	table.clear(self._connections)
	self._baseSignalsConnected = false
	self._context:ReleaseSubtree(claims)
	self._parent = nil
	self._windowBinding = nil
	self._state = "cleared"
	return if cleanupFailed then failure("CleanupFailed") else success()
end

return BaseUiElement
