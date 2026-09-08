--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BaseWindowView = require(ReplicatedStorage.Client.UI.Windows.BaseWindowView)
local FrameController = require(ReplicatedStorage.Client.UI.Elements.Controllers.FrameController)
local TextController = require(ReplicatedStorage.Client.UI.Elements.Controllers.TextController)
local ButtonController = require(ReplicatedStorage.Client.UI.Elements.Controllers.ButtonController)
local WindowTypes = require(ReplicatedStorage.Client.UI.Config.WindowTypes)
local GroupInviteWindowPrefabValidator =
	require(ReplicatedStorage.Shared.UI.GroupInviteWindowPrefabValidator)

type UiVoidResult = WindowTypes.UiVoidResult
type BaseWindowViewContract = WindowTypes.BaseWindowView
type WindowConstructionContext = WindowTypes.WindowConstructionContext

export type Presentation = {
	TitleText: string,
	MessageText: string,
	CountdownText: string,
	Processing: boolean,
}

export type ViewModel = {
	GetPresentation: () -> Presentation,
	OnResumed: (() -> ())?,
}

export type View = BaseWindowViewContract & {
	Initialize: (self: View, viewModel: ViewModel) -> UiVoidResult,
	Render: (self: View, presentation: Presentation) -> (),
	GetAction: (self: View, uiElementId: string) -> string?,
	Resume: (self: View) -> (),
}

local WINDOW_ID = "game.group-invite"
local ROOT_ID = "game.window/group-invite"

local View = {}
View.__index = View
setmetatable(View, { __index = BaseWindowView })

local function uiResult(code: string?): UiVoidResult
	if code == nil then
		return { Kind = "Success" }
	end
	return { Kind = "Error", Error = { Code = code } }
end

local function addChild(parent: any, child: any): UiVoidResult
	local result = parent:AddNestedUiElement(child, nil)
	if result.Kind == "Error" then
		return result
	end
	return uiResult(nil)
end

local function requireSuccessfulRegistration(result: UiVoidResult)
	if result.Kind == "Error" then
		error(result.Error.Code, 2)
	end
end

local function classifyInitializationProblem(problem: any): string
	local rendered = tostring(problem)
	if string.find(rendered, "PrefabMalformed", 1, true) ~= nil
		or string.find(rendered, "ForbiddenExecutableDescendant", 1, true) ~= nil
	then
		return if string.find(rendered, "ForbiddenExecutableDescendant", 1, true) ~= nil
			then "ForbiddenExecutableDescendant"
			else "PrefabMalformed"
	end
	for _, code in { "InvalidDefaultNavigation", "InvalidUIElementId", "DuplicateUIElementId", "CleanupFailed" } do
		if string.find(rendered, code, 1, true) ~= nil then
			return code
		end
	end
	return "ViewInitializationFailed"
end

function View.new(root: GuiObject, context: WindowConstructionContext): View
	local self = BaseWindowView.new(root, WINDOW_ID, ROOT_ID, context.Elements) :: any
	self._construction = context
	self._viewModel = nil
	self._actions = {}
	self._isInitialized = false
	setmetatable(self, View)
	return self
end

function View.tryCast(value: BaseWindowViewContract): View?
	if value.WindowId ~= WINDOW_ID or getmetatable(value) ~= View then
		return nil
	end
	return value :: any
end

function View:Initialize(viewModel: ViewModel): UiVoidResult
	if self._isInitialized then
		return uiResult(nil)
	end
	if typeof(viewModel) ~= "table" or typeof(viewModel.GetPresentation) ~= "function"
		or (viewModel.OnResumed ~= nil and typeof(viewModel.OnResumed) ~= "function")
	then
		return uiResult("ViewModelMismatch")
	end
	local ok, problem = xpcall(function()
		local binding, prefabProblem = GroupInviteWindowPrefabValidator.Validate(self.Root)
		if binding == nil then
			error(prefabProblem or "PrefabMalformed", 2)
		end
		local staticControllers = {
			FrameController.new(binding.Panel, ROOT_ID .. "/panel", false, self._construction.Elements),
			TextController.new(binding.Title, ROOT_ID .. "/title", false, self._construction.Elements),
			TextController.new(binding.Message, ROOT_ID .. "/message", false, self._construction.Elements),
			TextController.new(binding.Countdown, ROOT_ID .. "/countdown", false, self._construction.Elements),
			FrameController.new(binding.Actions, ROOT_ID .. "/actions", false, self._construction.Elements),
		}
		for _, controller in staticControllers do
			requireSuccessfulRegistration(addChild(self, controller))
		end
		local declineId = ROOT_ID .. "/decline"
		local acceptId = ROOT_ID .. "/accept"
		local declineController = ButtonController.new(binding.Decline, declineId, true, self._construction.Elements)
		local acceptController = ButtonController.new(binding.Accept, acceptId, true, self._construction.Elements)
		requireSuccessfulRegistration(addChild(self, declineController))
		requireSuccessfulRegistration(addChild(self, acceptController))
		self._actions[declineId] = "decline"
		self._actions[acceptId] = "accept"
		requireSuccessfulRegistration(self:ConfigureNavigation(binding.Accept, {}))
		self._title = binding.Title
		self._message = binding.Message
		self._countdown = binding.Countdown
		self._decline = binding.Decline
		self._accept = binding.Accept
		self._viewModel = viewModel
		local baseResult = BaseWindowView.Initialize(self, viewModel)
		if baseResult.Kind == "Error" then
			error(baseResult.Error.Code, 2)
		end
		self._isInitialized = true
		self:Render(viewModel.GetPresentation())
	end, debug.traceback)
	if not ok then
		return uiResult(classifyInitializationProblem(problem))
	end
	return uiResult(nil)
end

function View:Render(presentation: Presentation)
	if not self._isInitialized then
		return
	end
	self._title.Text = presentation.TitleText
	self._message.Text = presentation.MessageText
	self._countdown.Text = presentation.CountdownText
	local enabled = not presentation.Processing
	for _, button in { self._decline, self._accept } do
		button.Active = enabled
		button.AutoButtonColor = enabled
		button.TextTransparency = if enabled then 0 else 0.35
		assert(self._navigationRegistry:SetMemberEligibility(button, enabled, enabled), "GroupInviteNavigationMissing")
	end
end

function View:GetAction(uiElementId: string): string?
	return self._actions[uiElementId]
end

function View:Resume()
	BaseWindowView.Resume(self)
	if self._isInitialized and self._viewModel ~= nil and self._viewModel.OnResumed ~= nil then
		self._viewModel.OnResumed()
	end
end

function View:OnClear()
	table.clear(self._actions)
	self._viewModel = nil
	self._isInitialized = false
end

return View
