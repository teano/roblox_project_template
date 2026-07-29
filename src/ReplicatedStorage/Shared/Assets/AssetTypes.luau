--!strict

export type AssetRoot = {
	Namespace: string,
	Root: Instance,
}

export type AssetQuery = {
	Under: string?,
	Recursive: boolean?,
	Name: string?,
	ClassName: string?,
	IsA: string?,
	Tags: { string }?,
	Attributes: { [string]: any }?,
}

export type AssetRegistry = {
	Initialize: (self: AssetRegistry) -> (),
	IsInitialized: (self: AssetRegistry) -> boolean,
	GetState: (self: AssetRegistry) -> string,
	Get: (self: AssetRegistry, path: string) -> Instance?,
	Require: (self: AssetRegistry, path: string, expectedClassName: string?) -> Instance,
	GetByKey: (self: AssetRegistry, key: string) -> Instance?,
	RequireByKey: (self: AssetRegistry, key: string, expectedClassName: string?) -> Instance,
	GetPath: (self: AssetRegistry, instance: Instance) -> string?,
	GetChildren: (self: AssetRegistry, path: string) -> { Instance },
	GetDescendants: (self: AssetRegistry, path: string) -> { Instance },
	FindByName: (self: AssetRegistry, name: string) -> { Instance },
	FindByClassName: (self: AssetRegistry, className: string) -> { Instance },
	FindAll: (self: AssetRegistry, query: AssetQuery?) -> { Instance },
	Clone: (self: AssetRegistry, path: string, expectedClassName: string?) -> Instance,
}

return {}
