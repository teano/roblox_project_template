--!strict

export type UiError = {
	Code: string,
	WindowId: string?,
	OperationGeneration: number?,
	Phase: string?,
}

export type UiVoidResult = { Kind: "Success" } | { Kind: "Error", Error: UiError }
export type UiValueResult<T> =
	{ Kind: "Success", Value: T }
	| { Kind: "NoOp" }
	| { Kind: "Error", Error: UiError }
export type UiCloseResult = { Kind: "Success" } | { Kind: "NoOp" } | { Kind: "Error", Error: UiError }
export type ViewResult<T> = { Kind: "Success", Value: T } | { Kind: "Error", Error: UiError }

export type PoolOptions = {
	MaxActive: number,
	MaxRetained: number,
}

export type SerializableValue =
	nil
	| boolean
	| number
	| string
	| Vector2
	| Vector3
	| CFrame
	| Color3
	| UDim
	| UDim2
	| Rect
	| NumberRange
	| BrickColor
	| EnumItem
	| { SerializableValue }
	| { [string]: SerializableValue }

export type BaseUiElement = {
	Root: GuiObject,
	UIElementId: string,
	UINavigationEnabled: boolean,
	NestedUiElements: { BaseUiElement },
}

export type BaseWindowView = BaseUiElement & {
	WindowId: string,
}

export type UiRootEvent = {
	ActionId: string,
	UIElementId: string,
	WindowId: string?,
	Payload: SerializableValue?,
}

export type UiElementClaim = {
	UIElementId: string,
	Owner: BaseUiElement,
}

export type UiElementContext = {
	ClaimSubtree: (self: UiElementContext, claims: { UiElementClaim }) -> UiVoidResult,
	ReleaseSubtree: (self: UiElementContext, claims: { UiElementClaim }) -> UiVoidResult,
	DeliverToRoot: (self: UiElementContext, event: UiRootEvent) -> UiVoidResult,
}

export type WindowHandle<TView> = {
	WindowId: string,
	IsValid: (self: WindowHandle<TView>) -> boolean,
	IsActiveWindow: (self: WindowHandle<TView>) -> boolean,
	GetView: (self: WindowHandle<TView>) -> ViewResult<TView>,
}

export type WindowNavigatorPort = {
	AddWindowAsync: (
		self: WindowNavigatorPort,
		caller: BaseWindowView,
		windowId: string,
		viewModel: unknown
	) -> UiValueResult<WindowHandle<BaseWindowView>>,
	AddWindowTypedAsync: <TView, TViewModel>(
		self: WindowNavigatorPort,
		caller: BaseWindowView,
		definition: WindowDefinition<TView, TViewModel>,
		viewModel: TViewModel
	) -> UiValueResult<WindowHandle<TView>>,
	CloseWindowAsync: (
		self: WindowNavigatorPort,
		caller: BaseWindowView,
		nextWindowId: string?,
		nextViewModel: unknown?
	) -> UiCloseResult | UiValueResult<WindowHandle<BaseWindowView>>,
	CloseWindowTypedAsync: <TView, TViewModel>(
		self: WindowNavigatorPort,
		caller: BaseWindowView,
		definition: WindowDefinition<TView, TViewModel>,
		viewModel: TViewModel
	) -> UiValueResult<WindowHandle<TView>>,
}

export type WindowConstructionContext = {
	Navigator: WindowNavigatorPort,
	Elements: UiElementContext,
}

export type WindowDefinition<TView, TViewModel> = {
	WindowId: string,
	AssetId: number,
	CreateView: (root: GuiObject, context: WindowConstructionContext) -> TView,
	TryCastView: (view: BaseWindowView) -> TView?,
	InitializeView: (view: TView, viewModel: TViewModel) -> UiVoidResult,
	LifecyclePolicy: "Destroy" | "Pool",
	VisibilityPolicy: "HideBelow" | "KeepBelow",
	BackgroundPolicy: "None" | "Absorb" | "CloseOnActivate",
	Preload: boolean?,
	PoolOptions: PoolOptions?,
}

export type ErasedWindowDefinition = unknown

export type WindowConfig = {
	Definitions: { ErasedWindowDefinition },
	ByWindowId: { [string]: ErasedWindowDefinition },
}

return table.freeze({})
