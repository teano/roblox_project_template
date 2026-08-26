--!strict

local BaseUiElement = require(script.Parent.Parent.Elements.BaseUiElement)
local WindowInputBlocker = require(script.Parent.Parent.WindowInputBlocker)
local WindowNavigationRegistry = require(script.Parent.Parent.WindowNavigationRegistry)
local BackgroundController = require(script.Parent.Parent.Elements.Controllers.BackgroundController)
local WindowTypes = require(script.Parent.Parent.Config.WindowTypes)
local WindowHandleModule = require(script.Parent.Parent.WindowHandle)

type WindowDefinition<TView, TViewModel> = WindowTypes.WindowDefinition<TView, TViewModel>
type UiValueResult<T> = WindowTypes.UiValueResult<T>
type WindowHandle<T> = WindowHandleModule.WindowHandle<T>

local BaseWindowView = {}
BaseWindowView.__index = BaseWindowView
setmetatable(BaseWindowView, { __index = BaseUiElement })

function BaseWindowView.new(root: GuiObject, windowId: string, uiElementId: string, context: any)
	local self = BaseUiElement.new(root, uiElementId, false, context) :: any
	self.WindowId = windowId
	self._navigator = nil
	self._navigatorBinding = nil
	self._windowElementBinding = nil
	self._backgroundController = nil
	self._navigationDefault = nil
	self._navigationOverrides = {}
	self._navigationRegistry = WindowNavigationRegistry.new(nil)
	self._inputBlocker = WindowInputBlocker.new(root, function(_isBlocked: boolean)
		self._navigationRegistry:SetBlocked(_isBlocked)
	end)
	setmetatable(self, BaseWindowView)
	return self
end

function BaseWindowView:_ReceiveOwnedEvent(event: any, source: any)
	local enriched = table.clone(event)
	enriched.WindowId = self.WindowId
	return BaseUiElement._ReceiveOwnedEvent(self, enriched, source)
end

function BaseWindowView:Initialize(_viewModel: unknown)
	local blockerResult = self._inputBlocker:Initialize()
	if blockerResult.Kind == "Error" then
		return blockerResult
	end
	local navigationResult = self._navigationRegistry:Initialize(
		self,
		self._navigationDefault,
		self._navigationOverrides
	)
	if navigationResult.Kind == "Error" then
		self._inputBlocker:Clear()
		return navigationResult
	end
	local result = BaseUiElement.Initialize(self)
	if result.Kind == "Error" then
		self._navigationRegistry:Clear()
		self._inputBlocker:Clear()
	end
	return result
end

function BaseWindowView:Pause()
end

function BaseWindowView:Resume()
end

function BaseWindowView:Open()
end

function BaseWindowView:Close()
end

function BaseWindowView:AcquireInputBlock()
	return self._inputBlocker:Acquire()
end

function BaseWindowView:_AcquireSystemInputBlock()
	return self._inputBlocker:Acquire()
end

function BaseWindowView:_CanAcceptUserAction(): boolean
	return self._navigatorBinding ~= nil
		and self._navigatorBinding:CanEmitAction()
end

function BaseWindowView:_ConfigureForDefinition(definition: any)
	if self._backgroundController ~= nil then
		self._backgroundController:Clear()
	end
	local controller, backgroundError = BackgroundController.new(self, definition.BackgroundPolicy)
	if controller == nil then
		return { Kind = "Error", Error = backgroundError }
	end
	self._backgroundController = controller
	return { Kind = "Success" }
end

function BaseWindowView:_SetNavigatorBinding(navigator: any, binding: any)
	self._navigator = navigator
	self._navigatorBinding = binding
	self._navigationRegistry = WindowNavigationRegistry.new(binding:GetGuiService())
	local registry = self._navigationRegistry
	local coordinator = table.freeze({
		CanEmitAction = function()
			return binding:CanEmitAction()
		end,
		PrepareAdd = function(_binding: any, child: any, nominatedDefault: GuiObject?)
			return registry:PrepareAdd(child, nominatedDefault)
		end,
		CommitAdd = function(_binding: any, token: any)
			registry:CommitAdd(token)
		end,
		PrepareRemove = function(_binding: any, child: any, nominatedDefault: GuiObject?)
			return registry:PrepareRemove(child, nominatedDefault)
		end,
		CommitRemove = function(_binding: any, token: any)
			registry:CommitRemove(token)
		end,
	})
	self._windowElementBinding = coordinator
	self:_SetWindowBinding(coordinator)
end

function BaseWindowView:_SetNavigationActive(active: boolean)
	self._navigationRegistry:SetActive(active)
end

function BaseWindowView:_EmitLifecycle(actionId: string)
	return self:_ReceiveOwnedEvent({
		ActionId = actionId,
		UIElementId = self._claimedUIElementId or self.UIElementId,
	}, self)
end


function BaseWindowView:ConfigureNavigation(defaultElement: GuiObject?, overrides: { any })
	if self._state == "initialized" then
		return { Kind = "Error", Error = { Code = "InvalidDefaultNavigation" } }
	end
	self._navigationDefault = defaultElement
	self._navigationOverrides = overrides
	return { Kind = "Success" }
end

local function unavailable()
	return { Kind = "Error", Error = { Code = "NotActiveWindow" } }
end

function BaseWindowView:AddWindowAsync(_windowId: string, _viewModel: unknown)
	return if self._navigator then self._navigator:AddWindowAsync(self, _windowId, _viewModel) else unavailable()
end

function BaseWindowView.AddWindowTypedAsync<TView, TViewModel>(
	self: any,
	definition: WindowDefinition<TView, TViewModel>,
	viewModel: TViewModel
): UiValueResult<WindowHandle<TView>>
	return if self._navigator then self._navigator:AddWindowTypedAsync(self, definition, viewModel) else unavailable()
end

function BaseWindowView:CloseWindowAsync(nextWindowId: string?, nextViewModel: unknown?)
	return if self._navigator then self._navigator:CloseWindowAsync(self, nextWindowId, nextViewModel) else unavailable()
end

function BaseWindowView.CloseWindowTypedAsync<TView, TViewModel>(
	self: any,
	definition: WindowDefinition<TView, TViewModel>,
	viewModel: TViewModel
): UiValueResult<WindowHandle<TView>>
	return if self._navigator then self._navigator:CloseWindowTypedAsync(self, definition, viewModel) else unavailable()
end

function BaseWindowView:Clear()
	self._navigationRegistry:SetActive(false)
	self._windowElementBinding = nil
	self:_SetWindowBinding(nil)
	if self._backgroundController ~= nil then
		self._backgroundController:Clear()
		self._backgroundController = nil
	end
	self._inputBlocker:Clear()
	self._navigationRegistry:Clear()
	local result = BaseUiElement.Clear(self)
	self._navigatorBinding = nil
	self._navigator = nil
	return result
end

return BaseWindowView
