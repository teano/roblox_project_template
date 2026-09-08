--!strict

local MAX_SAFE_INTEGER = 9007199254740991
local Compiler = {}
local ALLOWED_FIELDS = table.freeze({
	WindowId = true,
	AssetId = true,
	AssetKey = true,
	CreateView = true,
	TryCastView = true,
	InitializeView = true,
	LifecyclePolicy = true,
	VisibilityPolicy = true,
	BackgroundPolicy = true,
	Preload = true,
	PoolOptions = true,
})

local function failure(code: string)
	return nil, { Code = code }
end

local function isDenseSequence(value: any): boolean
	if typeof(value) ~= "table" then
		return false
	end
	local count = 0
	local maximum = 0
	for key in value do
		if typeof(key) ~= "number" or key < 1 or key % 1 ~= 0 then
			return false
		end
		count += 1
		maximum = math.max(maximum, key)
	end
	return count == maximum
end

local function validLimit(value: any): boolean
	return typeof(value) == "number"
		and (value == math.huge or (value >= 0 and value % 1 == 0))
end

local function validAssetId(value: any): boolean
	return typeof(value) == "number"
		and value >= 1
		and value <= MAX_SAFE_INTEGER
		and value % 1 == 0
end

local function validAssetKey(value: any): boolean
	return typeof(value) == "string"
		and value ~= ""
		and #value <= 128
		and string.match(value, "^[A-Za-z0-9][A-Za-z0-9._-]*$") ~= nil
end

local function validDefinition(definition: any): boolean
	if typeof(definition) ~= "table"
		or typeof(definition.WindowId) ~= "string"
		or definition.WindowId == ""
		or #definition.WindowId > 128
		or string.match(definition.WindowId, "^[A-Za-z0-9][A-Za-z0-9._-]*$") == nil
		or typeof(definition.CreateView) ~= "function"
		or typeof(definition.TryCastView) ~= "function"
		or typeof(definition.InitializeView) ~= "function"
		or (definition.LifecyclePolicy ~= "Destroy" and definition.LifecyclePolicy ~= "Pool")
		or (definition.VisibilityPolicy ~= "HideBelow" and definition.VisibilityPolicy ~= "KeepBelow")
		or (definition.BackgroundPolicy ~= "None"
			and definition.BackgroundPolicy ~= "Absorb"
			and definition.BackgroundPolicy ~= "CloseOnActivate")
		or (definition.Preload ~= nil and typeof(definition.Preload) ~= "boolean")
	then
		return false
	end
	local hasAssetId = definition.AssetId ~= nil
	local hasAssetKey = definition.AssetKey ~= nil
	if hasAssetId == hasAssetKey
		or (hasAssetId and not validAssetId(definition.AssetId))
		or (hasAssetKey and not validAssetKey(definition.AssetKey))
	then
		return false
	end
	for key in definition do
		if typeof(key) ~= "string" or ALLOWED_FIELDS[key] ~= true then
			return false
		end
	end
	if definition.LifecyclePolicy == "Pool" then
		local options = definition.PoolOptions
		return typeof(options) == "table"
			and validLimit(options.MaxActive)
			and validLimit(options.MaxRetained)
	end
	return definition.PoolOptions == nil
end

function Compiler.compile(templateDefinitions: { any }, derivedDefinitions: { any }?)
	local derived = derivedDefinitions or {}
	if not isDenseSequence(templateDefinitions) or not isDenseSequence(derived) then
		return failure("WindowConfigMalformed")
	end

	local ordered = {}
	local byWindowId = {}
	for _, source in { templateDefinitions, derived } do
		for _, definition in source do
			if not validDefinition(definition) then
				return failure("WindowConfigMalformed")
			end
			if byWindowId[definition.WindowId] ~= nil then
				return failure("DuplicateWindowId")
			end
			byWindowId[definition.WindowId] = definition
			table.insert(ordered, definition)
		end
	end

	-- Validation is total before the first mutation. Canonical definition
	-- identity is preserved and frozen in place for typed callers.
	for _, definition in ordered do
		if definition.PoolOptions ~= nil and not table.isfrozen(definition.PoolOptions) then
			table.freeze(definition.PoolOptions)
		end
		if not table.isfrozen(definition) then
			table.freeze(definition)
		end
	end
	return table.freeze({
		Definitions = table.freeze(ordered),
		ByWindowId = table.freeze(byWindowId),
	}), nil
end

return table.freeze(Compiler)
