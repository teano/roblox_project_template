--!strict

export type InspectOptions = {
	MaxBytes: number?,
	MaxNodes: number?,
	MaxIssues: number?,
}

type InspectionState = {
	Issues: { any },
	Seen: { [any]: boolean },
	Nodes: number,
	EstimatedBytes: number,
	MaxBytes: number,
	MaxNodes: number,
	MaxIssues: number,
	Aborted: boolean,
	Invalid: boolean,
}

local MAX_DEPTH = 32
local DEFAULT_MAX_NODES = 100_000
local DEFAULT_MAX_ISSUES = 16

local CommunicationSerialize = {}

local function isFinite(value: number): boolean
	return value == value and value ~= math.huge and value ~= -math.huge
end

local function addIssue(state: InspectionState, path: string, reason: string, abort: boolean?)
	state.Invalid = true
	if #state.Issues < state.MaxIssues then
		table.insert(state.Issues, {
			Path = path,
			Reason = reason,
		})
	end
	if abort then
		state.Aborted = true
	end
end

local function addBytes(state: InspectionState, path: string, amount: number)
	state.EstimatedBytes += amount
	if state.EstimatedBytes > state.MaxBytes then
		addIssue(state, path, "maximum_estimated_bytes_exceeded", true)
	end
end

local function validateFiniteComponents(path: string, state: InspectionState, ...: number)
	for index = 1, select("#", ...) do
		local component = select(index, ...)
		if not isFinite(component) then
			addIssue(state, path, `non_finite_component:{index}`)
			return
		end
	end
end

local function inspect(value: any, path: string, state: InspectionState, depth: number)
	if state.Aborted then
		return
	end

	state.Nodes += 1
	if state.Nodes > state.MaxNodes then
		addIssue(state, path, "maximum_nodes_exceeded", true)
		return
	end
	if depth > MAX_DEPTH then
		addIssue(state, path, "maximum_depth_exceeded")
		return
	end

	local valueType = typeof(value)
	if valueType == "nil" then
		addBytes(state, path, 4)
		return
	elseif valueType == "boolean" then
		addBytes(state, path, 5)
		return
	elseif valueType == "string" then
		addBytes(state, path, #value + 2)
		return
	elseif valueType == "number" then
		if not isFinite(value) then
			addIssue(state, path, "non_finite_number")
		end
		addBytes(state, path, 12)
		return
	elseif valueType == "Vector2" then
		validateFiniteComponents(path, state, value.X, value.Y)
		addBytes(state, path, 16)
		return
	elseif valueType == "Vector3" then
		validateFiniteComponents(path, state, value.X, value.Y, value.Z)
		addBytes(state, path, 24)
		return
	elseif valueType == "CFrame" then
		validateFiniteComponents(path, state, value:GetComponents())
		addBytes(state, path, 64)
		return
	elseif valueType == "Color3" then
		validateFiniteComponents(path, state, value.R, value.G, value.B)
		addBytes(state, path, 24)
		return
	elseif valueType == "UDim" then
		validateFiniteComponents(path, state, value.Scale, value.Offset)
		addBytes(state, path, 16)
		return
	elseif valueType == "UDim2" then
		validateFiniteComponents(path, state, value.X.Scale, value.X.Offset, value.Y.Scale, value.Y.Offset)
		addBytes(state, path, 32)
		return
	elseif valueType == "Rect" then
		validateFiniteComponents(path, state, value.Min.X, value.Min.Y, value.Max.X, value.Max.Y)
		addBytes(state, path, 32)
		return
	elseif valueType == "NumberRange" then
		validateFiniteComponents(path, state, value.Min, value.Max)
		addBytes(state, path, 16)
		return
	elseif valueType == "BrickColor" then
		addBytes(state, path, 8)
		return
	elseif valueType == "EnumItem" then
		addBytes(state, path, 8)
		return
	elseif valueType ~= "table" then
		addIssue(state, path, `unsupported_type:{valueType}`)
		return
	end

	if getmetatable(value) ~= nil then
		addIssue(state, path, "table_metatable")
		return
	end
	if state.Seen[value] then
		addIssue(state, path, "cyclic_table")
		return
	end

	state.Seen[value] = true
	addBytes(state, path, 2)

	local keyKind = nil :: string?
	local numericCount = 0
	local maximumNumericIndex = 0
	for key, child in value do
		if state.Aborted then
			break
		end

		local keyType = typeof(key)
		local currentKeyKind = nil :: string?
		if keyType == "string" then
			currentKeyKind = "string"
		elseif keyType == "number" then
			if not isFinite(key) or key < 1 or key ~= math.floor(key) then
				state.Nodes += 1
				if state.Nodes > state.MaxNodes then
					addIssue(state, path, "maximum_nodes_exceeded", true)
					break
				end
				addIssue(state, path, "invalid_numeric_key")
				continue
			end
			currentKeyKind = "number"
			numericCount += 1
			maximumNumericIndex = math.max(maximumNumericIndex, key)
		else
			state.Nodes += 1
			if state.Nodes > state.MaxNodes then
				addIssue(state, path, "maximum_nodes_exceeded", true)
				break
			end
			addIssue(state, path, `invalid_key_type:{keyType}`)
			continue
		end

		if keyKind == nil then
			keyKind = currentKeyKind
		elseif keyKind ~= currentKeyKind and keyKind ~= "mixed" then
			keyKind = "mixed"
			addIssue(state, path, "mixed_table_keys")
		end

		local childPath = if path == "" then tostring(key) else `{path}.{key}`
		inspect(key, childPath, state, depth + 1)
		inspect(child, childPath, state, depth + 1)
		addBytes(state, childPath, 2)
	end

	if keyKind == "number" and numericCount ~= maximumNumericIndex then
		addIssue(state, path, "sparse_array")
	end

	state.Seen[value] = nil
end

function CommunicationSerialize.inspect(value: any, options: InspectOptions?): (boolean, { any }, number)
	local state: InspectionState = {
		Issues = {},
		Seen = {},
		Nodes = 0,
		EstimatedBytes = 0,
		MaxBytes = if options and options.MaxBytes then options.MaxBytes else math.huge,
		MaxNodes = if options and options.MaxNodes then options.MaxNodes else DEFAULT_MAX_NODES,
		MaxIssues = if options and options.MaxIssues then options.MaxIssues else DEFAULT_MAX_ISSUES,
		Aborted = false,
		Invalid = false,
	}
	inspect(value, "", state, 0)
	return not state.Invalid, state.Issues, state.EstimatedBytes
end

function CommunicationSerialize.validate(value: any, options: InspectOptions?): (boolean, { any })
	local valid, issues = CommunicationSerialize.inspect(value, options)
	return valid, issues
end

function CommunicationSerialize.estimateSize(value: any, options: InspectOptions?): number
	local _, _, size = CommunicationSerialize.inspect(value, options)
	return size
end

function CommunicationSerialize.inspectDenseArray(value: any, maxLength: number?): (boolean, number)
	if typeof(value) ~= "table" then
		return false, 0
	end

	local count = 0
	local maximumIndex = 0
	for key in value do
		count += 1
		if maxLength ~= nil and count > maxLength then
			return false, count
		end
		if typeof(key) ~= "number" or not isFinite(key) or key < 1 or key ~= math.floor(key) then
			return false, count
		end
		maximumIndex = math.max(maximumIndex, key)
	end
	return count == maximumIndex, count
end

return CommunicationSerialize
