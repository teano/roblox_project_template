--!strict

local AssetTypes = require(script.Parent.AssetTypes)

type AssetRoot = AssetTypes.AssetRoot
type AssetQuery = AssetTypes.AssetQuery

type Indexes = {
	ByPath: { [string]: Instance },
	PathByInstance: { [Instance]: string },
	ByKey: { [string]: Instance },
	ByName: { [string]: { Instance } },
	ByClassName: { [string]: { Instance } },
	ByTag: { [string]: { Instance } },
	TagsByInstance: { [Instance]: { [string]: boolean } },
	AttributesByInstance: { [Instance]: { [string]: any } },
	NameByInstance: { [Instance]: string },
	ChildrenByPath: { [string]: { Instance } },
	DescendantsByPath: { [string]: { Instance } },
	All: { Instance },
}

local AssetRegistry = {}
AssetRegistry.__index = AssetRegistry

local ASSET_KEY_ATTRIBUTE = "AssetKey"
local MAX_KEY_LENGTH = 128
local MAX_NAMESPACE_LENGTH = 64

local function assertValidNamespace(namespace: string)
	assert(namespace ~= "", "Asset namespace must not be empty")
	assert(#namespace <= MAX_NAMESPACE_LENGTH, `Asset namespace '{namespace}' is too long`)
	assert(
		namespace:match("^[%w][%w_%-]*$") ~= nil,
		`Asset namespace '{namespace}' must contain only letters, digits, underscores, and hyphens`
	)
end

local function assertValidPathSegment(name: string, instance: Instance)
	assert(name ~= "", `Asset path contains an empty name at {instance:GetFullName()}`)
	assert(not name:find("/", 1, true), `Asset name '{name}' must not contain '/'`)
	assert(name ~= "." and name ~= "..", `Asset name '{name}' is not a valid path segment`)
	assert(name:find("[%c]") == nil, `Asset name '{name}' must not contain control characters`)
end

local function assertValidKey(key: string, instance: Instance)
	assert(key ~= "", `AssetKey on {instance:GetFullName()} must not be empty`)
	assert(#key <= MAX_KEY_LENGTH, `AssetKey '{key}' is longer than {MAX_KEY_LENGTH} characters`)
	assert(
		key:match("^[%w][%w%._%-]*$") ~= nil,
		`AssetKey '{key}' must contain only letters, digits, dots, underscores, and hyphens`
	)
end

local function appendToIndex(index: { [string]: { Instance } }, key: string, instance: Instance)
	local values = index[key]
	if values == nil then
		values = {}
		index[key] = values
	end
	table.insert(values, instance)
end

local function buildPath(root: Instance, namespace: string, instance: Instance): string
	if instance == root then
		return namespace
	end

	local segments = {}
	local current: Instance? = instance
	while current ~= nil and current ~= root do
		assertValidPathSegment(current.Name, current)
		table.insert(segments, 1, current.Name)
		current = current.Parent
	end
	assert(current == root, `{instance:GetFullName()} is no longer below asset root '{namespace}'`)
	return `{namespace}/{table.concat(segments, "/")}`
end

local function assertRootsDoNotOverlap(roots: { AssetRoot })
	for firstIndex = 1, #roots do
		local first = roots[firstIndex]
		for secondIndex = firstIndex + 1, #roots do
			local second = roots[secondIndex]
			assert(
				first.Root ~= second.Root
					and not first.Root:IsDescendantOf(second.Root)
					and not second.Root:IsDescendantOf(first.Root),
				`Asset roots '{first.Namespace}' and '{second.Namespace}' must not overlap`
			)
		end
	end
end

local function freezeListIndex(index: { [string]: { Instance } }, pathByInstance: { [Instance]: string })
	for _, values in index do
		table.sort(values, function(first, second)
			return (pathByInstance[first] or "") < (pathByInstance[second] or "")
		end)
		table.freeze(values)
	end
	table.freeze(index)
end

local function buildIndexes(roots: { AssetRoot }): Indexes
	assert(#roots > 0, "AssetRegistry requires at least one explicit root")

	local orderedRoots = table.clone(roots)
	table.sort(orderedRoots, function(first, second)
		return first.Namespace < second.Namespace
	end)

	local namespaces: { [string]: boolean } = {}
	for _, assetRoot in orderedRoots do
		assert(typeof(assetRoot.Root) == "Instance", `Asset root '{assetRoot.Namespace}' must be an Instance`)
		assertValidNamespace(assetRoot.Namespace)
		assert(not namespaces[assetRoot.Namespace], `Duplicate asset namespace '{assetRoot.Namespace}'`)
		namespaces[assetRoot.Namespace] = true
	end
	assertRootsDoNotOverlap(orderedRoots)

	local byPath: { [string]: Instance } = {}
	local pathByInstance: { [Instance]: string } = {}
	local byKey: { [string]: Instance } = {}
	local byName: { [string]: { Instance } } = {}
	local byClassName: { [string]: { Instance } } = {}
	local byTag: { [string]: { Instance } } = {}
	local tagsByInstance: { [Instance]: { [string]: boolean } } = {}
	local attributesByInstance: { [Instance]: { [string]: any } } = {}
	local nameByInstance: { [Instance]: string } = {}
	local all: { Instance } = {}

	local function add(instance: Instance, path: string)
		local existingAtPath = byPath[path]
		assert(
			existingAtPath == nil,
			`Duplicate asset path '{path}' from {existingAtPath and existingAtPath:GetFullName() or "unknown"} and {instance:GetFullName()}`
		)
		assert(pathByInstance[instance] == nil, `{instance:GetFullName()} belongs to more than one asset root`)

		byPath[path] = instance
		pathByInstance[instance] = path
		nameByInstance[instance] = instance.Name
		table.insert(all, instance)
		appendToIndex(byName, instance.Name, instance)
		appendToIndex(byClassName, instance.ClassName, instance)

		local tagSet: { [string]: boolean } = {}
		for _, tag in instance:GetTags() do
			tagSet[tag] = true
			appendToIndex(byTag, tag, instance)
		end
		tagsByInstance[instance] = table.freeze(tagSet)

		local attributes = table.freeze(instance:GetAttributes())
		attributesByInstance[instance] = attributes
		local key = attributes[ASSET_KEY_ATTRIBUTE]
		if key ~= nil then
			assert(typeof(key) == "string", `{ASSET_KEY_ATTRIBUTE} on {instance:GetFullName()} must be a string`)
			assertValidKey(key, instance)
			local existingByKey = byKey[key]
			assert(
				existingByKey == nil,
				`Duplicate AssetKey '{key}' on {existingByKey and existingByKey:GetFullName() or "unknown"} and {instance:GetFullName()}`
			)
			byKey[key] = instance
		end
	end

	for _, assetRoot in orderedRoots do
		add(assetRoot.Root, assetRoot.Namespace)
		for _, descendant in assetRoot.Root:GetDescendants() do
			add(descendant, buildPath(assetRoot.Root, assetRoot.Namespace, descendant))
		end
	end

	table.sort(all, function(first, second)
		return pathByInstance[first] < pathByInstance[second]
	end)

	local childrenByPath: { [string]: { Instance } } = {}
	local descendantsByPath: { [string]: { Instance } } = {}
	for _, instance in all do
		local path = pathByInstance[instance]
		childrenByPath[path] = {}
		descendantsByPath[path] = {}
	end

	for _, instance in all do
		local parent = instance.Parent
		if parent ~= nil then
			local parentPath = pathByInstance[parent]
			if parentPath ~= nil then
				table.insert(childrenByPath[parentPath], instance)
			end

			local ancestor: Instance? = parent
			while ancestor ~= nil do
				local ancestorPath = pathByInstance[ancestor]
				if ancestorPath == nil then
					break
				end
				table.insert(descendantsByPath[ancestorPath], instance)
				ancestor = ancestor.Parent
			end
		end
	end

	freezeListIndex(byName, pathByInstance)
	freezeListIndex(byClassName, pathByInstance)
	freezeListIndex(byTag, pathByInstance)
	freezeListIndex(childrenByPath, pathByInstance)
	freezeListIndex(descendantsByPath, pathByInstance)
	table.freeze(all)
	table.freeze(byPath)
	table.freeze(pathByInstance)
	table.freeze(byKey)
	table.freeze(tagsByInstance)
	table.freeze(attributesByInstance)
	table.freeze(nameByInstance)

	return {
		ByPath = byPath,
		PathByInstance = pathByInstance,
		ByKey = byKey,
		ByName = byName,
		ByClassName = byClassName,
		ByTag = byTag,
		TagsByInstance = tagsByInstance,
		AttributesByInstance = attributesByInstance,
		NameByInstance = nameByInstance,
		ChildrenByPath = childrenByPath,
		DescendantsByPath = descendantsByPath,
		All = all,
	}
end

local function frozenCopy(values: { Instance }?): { Instance }
	local result = if values == nil then {} else table.clone(values)
	return table.freeze(result)
end

function AssetRegistry.new(roots: { AssetRoot })
	local copiedRoots: { AssetRoot } = {}
	for _, assetRoot in roots do
		table.insert(copiedRoots, {
			Namespace = assetRoot.Namespace,
			Root = assetRoot.Root,
		})
	end

	return setmetatable({
		_roots = copiedRoots,
		_state = "Idle",
		_failure = nil :: string?,
		_byPath = {} :: { [string]: Instance },
		_pathByInstance = {} :: { [Instance]: string },
		_byKey = {} :: { [string]: Instance },
		_byName = {} :: { [string]: { Instance } },
		_byClassName = {} :: { [string]: { Instance } },
		_byTag = {} :: { [string]: { Instance } },
		_tagsByInstance = {} :: { [Instance]: { [string]: boolean } },
		_attributesByInstance = {} :: { [Instance]: { [string]: any } },
		_nameByInstance = {} :: { [Instance]: string },
		_childrenByPath = {} :: { [string]: { Instance } },
		_descendantsByPath = {} :: { [string]: { Instance } },
		_all = {} :: { Instance },
	}, AssetRegistry)
end

function AssetRegistry:Initialize()
	if self._state == "Initialized" then
		return
	end
	if self._state == "Failed" then
		error(`AssetRegistry initialization previously failed:\n{self._failure}`, 2)
	end
	assert(self._state == "Idle", `AssetRegistry cannot initialize from state '{self._state}'`)

	self._state = "Initializing"
	local ok, result = xpcall(function()
		return buildIndexes(self._roots)
	end, debug.traceback)
	if not ok then
		self._state = "Failed"
		self._failure = tostring(result)
		error(self._failure, 0)
	end

	local indexes = result :: Indexes
	self._byPath = indexes.ByPath
	self._pathByInstance = indexes.PathByInstance
	self._byKey = indexes.ByKey
	self._byName = indexes.ByName
	self._byClassName = indexes.ByClassName
	self._byTag = indexes.ByTag
	self._tagsByInstance = indexes.TagsByInstance
	self._attributesByInstance = indexes.AttributesByInstance
	self._nameByInstance = indexes.NameByInstance
	self._childrenByPath = indexes.ChildrenByPath
	self._descendantsByPath = indexes.DescendantsByPath
	self._all = indexes.All
	self._state = "Initialized"
end

function AssetRegistry:IsInitialized(): boolean
	return self._state == "Initialized"
end

function AssetRegistry:GetState(): string
	return self._state
end

function AssetRegistry:_assertInitialized()
	assert(self._state == "Initialized", `AssetRegistry is not initialized (state={self._state})`)
end

function AssetRegistry:Get(path: string): Instance?
	self:_assertInitialized()
	return self._byPath[path]
end

function AssetRegistry:Require(path: string, expectedClassName: string?): Instance
	self:_assertInitialized()
	local instance = self._byPath[path]
	assert(instance ~= nil, `Unknown asset path '{path}'`)
	if expectedClassName ~= nil then
		assert(expectedClassName ~= "", "Expected class name must not be empty")
		assert(instance:IsA(expectedClassName), `Asset '{path}' must be a {expectedClassName}, got {instance.ClassName}`)
	end
	return instance
end

function AssetRegistry:GetByKey(key: string): Instance?
	self:_assertInitialized()
	return self._byKey[key]
end

function AssetRegistry:RequireByKey(key: string, expectedClassName: string?): Instance
	self:_assertInitialized()
	local instance = self._byKey[key]
	assert(instance ~= nil, `Unknown AssetKey '{key}'`)
	if expectedClassName ~= nil then
		assert(expectedClassName ~= "", "Expected class name must not be empty")
		assert(instance:IsA(expectedClassName), `AssetKey '{key}' must reference a {expectedClassName}, got {instance.ClassName}`)
	end
	return instance
end

function AssetRegistry:GetPath(instance: Instance): string?
	self:_assertInitialized()
	return self._pathByInstance[instance]
end

function AssetRegistry:GetChildren(path: string): { Instance }
	self:_assertInitialized()
	assert(self._byPath[path] ~= nil, `Unknown asset path '{path}'`)
	return frozenCopy(self._childrenByPath[path])
end

function AssetRegistry:GetDescendants(path: string): { Instance }
	self:_assertInitialized()
	assert(self._byPath[path] ~= nil, `Unknown asset path '{path}'`)
	return frozenCopy(self._descendantsByPath[path])
end

function AssetRegistry:FindByName(name: string): { Instance }
	self:_assertInitialized()
	return frozenCopy(self._byName[name])
end

function AssetRegistry:FindByClassName(className: string): { Instance }
	self:_assertInitialized()
	return frozenCopy(self._byClassName[className])
end

function AssetRegistry:FindAll(query: AssetQuery?): { Instance }
	self:_assertInitialized()
	local actualQuery: AssetQuery = query or {}

	if actualQuery.Recursive ~= nil then
		assert(actualQuery.Under ~= nil, "Asset query Recursive requires Under")
	end

	local candidates: { Instance }
	if actualQuery.Under ~= nil then
		assert(self._byPath[actualQuery.Under] ~= nil, `Unknown asset query scope '{actualQuery.Under}'`)
		candidates = if actualQuery.Recursive == false
			then self._childrenByPath[actualQuery.Under]
			else self._descendantsByPath[actualQuery.Under]
	elseif actualQuery.Name ~= nil then
		candidates = self._byName[actualQuery.Name] or {}
	elseif actualQuery.ClassName ~= nil then
		candidates = self._byClassName[actualQuery.ClassName] or {}
	elseif actualQuery.Tags ~= nil and #actualQuery.Tags > 0 then
		candidates = self._byTag[actualQuery.Tags[1]] or {}
	else
		candidates = self._all
	end

	local result: { Instance } = {}
	for _, instance in candidates do
		if actualQuery.Name ~= nil and self._nameByInstance[instance] ~= actualQuery.Name then
			continue
		end
		if actualQuery.ClassName ~= nil and instance.ClassName ~= actualQuery.ClassName then
			continue
		end
		if actualQuery.IsA ~= nil and not instance:IsA(actualQuery.IsA) then
			continue
		end

		local matchesTags = true
		if actualQuery.Tags ~= nil then
			local tagSet = self._tagsByInstance[instance] or {}
			for _, tag in actualQuery.Tags do
				if not tagSet[tag] then
					matchesTags = false
					break
				end
			end
		end
		if not matchesTags then
			continue
		end

		local matchesAttributes = true
		if actualQuery.Attributes ~= nil then
			local attributes = self._attributesByInstance[instance] or {}
			for attributeName, expectedValue in actualQuery.Attributes do
				if attributes[attributeName] ~= expectedValue then
					matchesAttributes = false
					break
				end
			end
		end
		if not matchesAttributes then
			continue
		end

		table.insert(result, instance)
	end

	table.sort(result, function(first, second)
		return self._pathByInstance[first] < self._pathByInstance[second]
	end)
	return table.freeze(result)
end

function AssetRegistry:Clone(path: string, expectedClassName: string?): Instance
	local template = self:Require(path, expectedClassName)
	local clone = template:Clone()
	assert(clone ~= nil, `Asset '{path}' is not archivable and cannot be cloned`)
	return clone
end

return AssetRegistry
