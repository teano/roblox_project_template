--!strict

local AssetTypes = require(script.Parent.Parent.Assets.AssetTypes)

export type AssetQuery = AssetTypes.AssetQuery

export type PreloadTarget = Instance | string
export type FailurePolicy = "Warn" | "Fail"

export type PreloadOptions = {
	RequestId: string?,
	FailurePolicy: FailurePolicy?,
}

export type PreloadFailure = {
	ContentId: string,
	Status: string,
	Error: string?,
}

export type PreloadProgress = {
	RequestId: string?,
	RequestedTargets: number,
	ResolvedContent: number,
	Loaded: number,
	Failed: number,
	ContentId: string,
	Status: string,
}

export type PreloadResult = {
	RequestId: string?,
	RequestedTargets: number,
	RequestedCatalogPaths: { string },
	ResolvedContent: number,
	Loaded: number,
	Failed: number,
	Failures: { PreloadFailure },
	DurationSeconds: number,
}

export type ContentPreloader = {
	Progress: any,
	RequestCompleted: any,
	Preload: (self: ContentPreloader, targets: { PreloadTarget }, options: PreloadOptions?) -> PreloadResult,
	PreloadQuery: (self: ContentPreloader, query: AssetQuery?, options: PreloadOptions?) -> PreloadResult,
	PreloadByKeys: (self: ContentPreloader, keys: { string }, options: PreloadOptions?) -> PreloadResult,
	GetRequestResult: (self: ContentPreloader, requestId: string) -> PreloadResult?,
}

return {}
