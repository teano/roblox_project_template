--!strict

local UiActionIds = require(script.Parent.Actions.UiActionIds)
local UiActionCatalog = require(script.Parent.Actions.UiActionCatalog)
local UiElementIdentityRegistry = require(script.Parent.UiElementIdentityRegistry)
local UiRootEventStream = require(script.Parent.UiRootEventStream)
local UiRootController = require(script.Parent.UiRootController)
local TemplateWindowConfig = require(script.Parent.Config.TemplateWindowConfig)
local WindowConfigCompiler = require(script.Parent.Config.WindowConfigCompiler)
local WindowAssetLoader = require(script.Parent.WindowAssetLoader)
local WindowPoolOwner = require(script.Parent.WindowPoolOwner)
local WindowNavigator = require(script.Parent.WindowNavigator)
local WindowTypes = require(script.Parent.Config.WindowTypes)
local WindowHandleModule = require(script.Parent.WindowHandle)

type WindowDefinition<TView, TViewModel> = WindowTypes.WindowDefinition<TView, TViewModel>
type UiValueResult<T> = WindowTypes.UiValueResult<T>
type WindowHandle<T> = WindowHandleModule.WindowHandle<T>

export type UiVoidResult = { Kind: "Success" } | { Kind: "Error", Error: { Code: string } }

local UiSystem = {}
UiSystem.__index = UiSystem

local function failure(code: string): UiVoidResult
	return { Kind = "Error", Error = { Code = code } }
end

local function hasMethod(value: any, methodName: string): boolean
	if value == nil then
		return false
	end
	local ok, member = pcall(function()
		return value[methodName]
	end)
	return ok and typeof(member) == "function"
end

function UiSystem.new(dependencies: {
	PlayersModule: any,
	DerivedActionEntries: { any }?,
	DerivedActionRoot: Instance?,
	RequireModule: ((ModuleScript) -> any)?,
	TemplateWindowDefinitions: { any }?,
	DerivedWindowConfigRoot: Instance?,
	Pooling: any?,
	ContentPreloader: any?,
	AssetBackend: any?,
	AssetRegistry: any?,
	Clock: (() -> number)?,
	Spawn: (((() -> ()) -> ()))?,
	Delay: (((number, () -> ()) -> ()))?,
	Wait: ((RBXScriptSignal, () -> boolean) -> ())?,
	Logger: any?,
	GuiService: any?,
})
	assert(dependencies.PlayersModule ~= nil, "UiSystem requires PlayersModule")
	return setmetatable({
		_playersModule = dependencies.PlayersModule,
		_derivedActionEntries = dependencies.DerivedActionEntries,
		_derivedActionRoot = dependencies.DerivedActionRoot,
		_requireModule = dependencies.RequireModule or require,
		_templateWindowDefinitions = dependencies.TemplateWindowDefinitions or TemplateWindowConfig,
		_derivedWindowConfigRoot = dependencies.DerivedWindowConfigRoot,
		_pooling = dependencies.Pooling,
		_contentPreloader = dependencies.ContentPreloader,
		_assetBackend = dependencies.AssetBackend,
		_assetRegistry = dependencies.AssetRegistry,
		_clock = dependencies.Clock or os.clock,
		_spawn = dependencies.Spawn or task.spawn,
		_delay = dependencies.Delay or task.delay,
		_wait = dependencies.Wait,
		_logger = dependencies.Logger,
		_guiService = dependencies.GuiService,
		_state = "fresh",
		_rootController = nil,
		_eventStream = nil,
		_identityRegistry = nil,
		_context = nil,
		_windowConfig = nil,
		_assetLoader = nil,
		_poolOwner = nil,
		_navigator = nil,
		Events = nil,
	}, UiSystem)
end

local function loadDerivedWindowDefinitions(self: any): ({ any }?, string?)
	local root = self._derivedWindowConfigRoot
	if root == nil then
		return nil, nil
	end
	local ok, definitions = pcall(function()
		local project = root:FindFirstChild("Project")
		local client = if project then project:FindFirstChild("Client") else nil
		local ui = if client then client:FindFirstChild("UI") else nil
		local source = if ui then ui:FindFirstChild("DerivedWindowConfig") else nil
		if source == nil then
			return nil
		end
		assert(source:IsA("ModuleScript"), "Project.Client.UI.DerivedWindowConfig must be a ModuleScript")
		return self._requireModule(source)
	end)
	if not ok then
		return nil, "WindowConfigMalformed"
	end
	return definitions, nil
end

local function loadDerivedActionEntries(self: any): ({ any }?, string?)
	if self._derivedActionEntries ~= nil then
		return self._derivedActionEntries, nil
	end
	local root = self._derivedActionRoot
	if root == nil then
		return nil, nil
	end

	local ok, entries = pcall(function()
		local projectRoot = root:FindFirstChild("Project")
		local projectClient = if projectRoot then projectRoot:FindFirstChild("Client") else nil
		local projectUi = if projectClient then projectClient:FindFirstChild("UI") else nil
		local derivedSource = if projectUi then projectUi:FindFirstChild("DerivedUiActionIds") else nil
		if derivedSource == nil then
			return nil
		end
		assert(derivedSource:IsA("ModuleScript"), "Project.Client.UI.DerivedUiActionIds must be a ModuleScript")
		return self._requireModule(derivedSource)
	end)
	if not ok then
		return nil, "ActionCatalogMalformed"
	end
	return entries, nil
end

function UiSystem:Initialize(): UiVoidResult
	if self._state == "active" then
		return { Kind = "Success" }
	elseif self._state ~= "fresh" then
		return failure("UiRootMalformed")
	end
	self._state = "initializing"
	local derivedWindowDefinitions, derivedWindowError = loadDerivedWindowDefinitions(self)
	if derivedWindowError ~= nil then
		self._state = "failed"
		return failure(derivedWindowError)
	end
	local windowConfig, windowConfigError = WindowConfigCompiler.compile(
		self._templateWindowDefinitions,
		derivedWindowDefinitions
	)
	if windowConfig == nil then
		self._state = "failed"
		return failure((windowConfigError and windowConfigError.Code) or "WindowConfigMalformed")
	end

	local derivedActionEntries, loadError = loadDerivedActionEntries(self)
	if loadError ~= nil then
		self._state = "failed"
		return failure(loadError)
	end
	local catalog, catalogError = UiActionCatalog.compile(UiActionIds.Entries, derivedActionEntries)
	if catalog == nil then
		self._state = "failed"
		return failure(catalogError or "ActionCatalogMalformed")
	end
	local eventStream = UiRootEventStream.new(catalog)
	local identityRegistry = UiElementIdentityRegistry.new(function(event)
		return eventStream:Publish(event)
	end)
	local rootController = UiRootController.new(self._playersModule)
	local rootResult = rootController:Initialize()
	if rootResult.Kind == "Error" then
		identityRegistry:Destroy()
		eventStream:Destroy()
		rootController:Destroy()
		self._state = "failed"
		return rootResult
	end

	local hasWindowDefinitions = #windowConfig.Definitions > 0
	local needsAssetBackend = false
	local needsAssetRegistry = false
	for _, definition in windowConfig.Definitions do
		if definition.AssetKey ~= nil then
			needsAssetRegistry = true
		else
			needsAssetBackend = true
		end
	end
	local hasValidAssetBackend = hasMethod(self._assetBackend, "LoadAssetAsync")
	local hasValidAssetRegistry = hasMethod(self._assetRegistry, "RequireByKey")
	if hasWindowDefinitions and (
		self._pooling == nil
		or self._contentPreloader == nil
		or (needsAssetBackend and not hasValidAssetBackend)
		or (needsAssetRegistry and not hasValidAssetRegistry)
	) then
		identityRegistry:Destroy()
		eventStream:Destroy()
		rootController:Destroy()
		self._state = "failed"
		return failure("WindowDependenciesMissing")
	end
	local assetLoader = nil
	local poolOwner = nil
	local navigator = nil
	if self._pooling ~= nil
		and self._contentPreloader ~= nil
		and (hasValidAssetBackend or hasValidAssetRegistry)
	then
		local windowOk = xpcall(function()
			assetLoader = WindowAssetLoader.new({
				AssetBackend = self._assetBackend,
				AssetRegistry = self._assetRegistry,
				ContentPreloader = self._contentPreloader,
				Clock = self._clock,
				Spawn = self._spawn,
				Delay = self._delay,
				Logger = self._logger,
			})
			poolOwner = WindowPoolOwner.new(self._pooling)
			navigator = WindowNavigator.new({
				Config = windowConfig,
				Loader = assetLoader,
				PoolOwner = poolOwner,
				WindowHost = rootController:GetWindowHost(),
				Elements = identityRegistry:GetContext(),
				GuiService = self._guiService,
				Clock = self._clock,
				Spawn = self._spawn,
				Delay = self._delay,
				Wait = self._wait,
				Logger = self._logger,
			})
			assetLoader:BeginEager(windowConfig.Definitions, self._clock() + 3)
		end, debug.traceback)
		if not windowOk then
			pcall(function()
				if navigator then navigator:Destroy() end
			end)
			pcall(function()
				if poolOwner then poolOwner:Destroy() end
			end)
			pcall(function()
				if assetLoader then assetLoader:Destroy() end
			end)
			identityRegistry:Destroy()
			eventStream:Destroy()
			rootController:Destroy()
			self._state = "failed"
			return failure("WindowInitializationFailed")
		end
	end

	self._rootController = rootController
	self._eventStream = eventStream
	self._identityRegistry = identityRegistry
	self._context = identityRegistry:GetContext()
	self._windowConfig = windowConfig
	self._assetLoader = assetLoader
	self._poolOwner = poolOwner
	self._navigator = navigator
	self.Events = eventStream:GetSource()
	self._state = "active"
	return { Kind = "Success" }
end

function UiSystem:GetHudHost(): Frame
	assert(self._state == "active", "UiSystemNotInitialized")
	return self._rootController:GetHudHost()
end

function UiSystem:GetToastHost(): Frame
	assert(self._state == "active", "UiSystemNotInitialized")
	return self._rootController:GetToastHost()
end

function UiSystem:GetUiElementContext()
	assert(self._state == "active", "UiSystemNotInitialized")
	return self._context
end

function UiSystem:AddWindowAsync(windowId: string, viewModel: unknown)
	if self._state ~= "active" or self._navigator == nil then
		return { Kind = "Error", Error = { Code = "UnknownWindowId", WindowId = windowId } }
	end
	return self._navigator:AddExternal(windowId, viewModel)
end

function UiSystem.AddWindowTypedAsync<TView, TViewModel>(
	self: any,
	definition: WindowDefinition<TView, TViewModel>,
	viewModel: TViewModel
): UiValueResult<WindowHandle<TView>>
	if self._state ~= "active" or self._navigator == nil then
		return { Kind = "Error", Error = { Code = "UnknownWindowId" } }
	end
	return self._navigator:AddExternalTyped(definition, viewModel)
end

function UiSystem:Destroy()
	if self._state == "destroyed" then
		return
	end
	self._state = "destroyed"
	local cleanupErrors = {}
	local function attempt(label: string, callback: () -> ())
		local ok = xpcall(callback, debug.traceback)
		if not ok then
			table.insert(cleanupErrors, label)
		end
	end
	if self._navigator then attempt("Navigator", function() self._navigator:Destroy() end) end
	if self._poolOwner then attempt("PoolOwner", function() self._poolOwner:Destroy() end) end
	if self._assetLoader then attempt("AssetLoader", function() self._assetLoader:Destroy() end) end
	if self._identityRegistry then attempt("IdentityRegistry", function() self._identityRegistry:Destroy() end) end
	if self._eventStream then attempt("EventStream", function() self._eventStream:Destroy() end) end
	if self._rootController then attempt("RootController", function() self._rootController:Destroy() end) end
	self.Events = nil
	self._context = nil
	self._windowConfig = nil
	self._navigator = nil
	self._poolOwner = nil
	self._assetLoader = nil
	if #cleanupErrors > 0 then
		error(`UiSystem cleanup failed: {table.concat(cleanupErrors, ",")}`, 2)
	end
end

return UiSystem
