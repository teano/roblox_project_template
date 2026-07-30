--!strict

local HttpService = game:GetService("HttpService")

export type SerializeIssue = {
	Path: string,
	Reason: string,
}

type ValidationState = {
	Seen: { [any]: boolean },
	Nodes: number,
	MaxNodes: number,
	MaxIssues: number,
	LimitReached: boolean,
}

local MAX_DEPTH = 32
local MAX_NODES = 200_000
local MAX_ISSUES = 32

local SaveSerialize = {}

local function isFiniteNumber(value: number): boolean
	return value == value and value ~= math.huge and value ~= -math.huge
end

local function isValidUtf8(value: string): boolean
	local ok, length = pcall(utf8.len, value)
	return ok and length ~= nil
end

local function addIssue(issues: { SerializeIssue }, state: ValidationState, path: string, reason: string)
	if #issues < state.MaxIssues then
		table.insert(issues, {
			Path = path,
			Reason = reason,
		})
	end
end

local function consumeNode(issues: { SerializeIssue }, state: ValidationState, path: string): boolean
	state.Nodes += 1
	if state.Nodes <= state.MaxNodes then
		return true
	end
	if not state.LimitReached then
		state.LimitReached = true
		addIssue(issues, state, path, "maximum_nodes_exceeded")
	end
	return false
end

local function validateValue(
	value: any,
	path: string,
	issues: { SerializeIssue },
	state: ValidationState,
	depth: number
)
	if #issues >= state.MaxIssues or state.LimitReached then
		return
	end

	if not consumeNode(issues, state, path) then
		return
	end
	if depth > MAX_DEPTH then
		addIssue(issues, state, path, "maximum_depth_exceeded")
		return
	end

	local valueType = typeof(value)
	if valueType == "nil" or valueType == "boolean" then
		return
	end
	if valueType == "string" then
		if not isValidUtf8(value) then
			addIssue(issues, state, path, "invalid_utf8")
		end
		return
	end
	if valueType == "number" then
		if not isFiniteNumber(value) then
			addIssue(issues, state, path, "non_finite_number")
		end
		return
	end
	if valueType ~= "table" then
		addIssue(issues, state, path, `unsupported_type:{valueType}`)
		return
	end

	local tbl = value :: { [any]: any }
	if getmetatable(tbl) ~= nil then
		addIssue(issues, state, path, "table_metatable")
		return
	end
	if state.Seen[tbl] then
		addIssue(issues, state, path, "cyclic_table")
		return
	end
	state.Seen[tbl] = true

	local stringKeyCount = 0
	local numericKeyCount = 0
	local maximumArrayIndex = 0
	for key in tbl do
		if not consumeNode(issues, state, path) then
			state.Seen[tbl] = nil
			return
		end
		local keyType = typeof(key)
		if keyType == "string" then
			stringKeyCount += 1
			if not isValidUtf8(key) then
				addIssue(issues, state, path, "invalid_utf8_key")
			end
		elseif keyType == "number" then
			numericKeyCount += 1
			if not isFiniteNumber(key) or key < 1 or key ~= math.floor(key) then
				addIssue(issues, state, path, "invalid_array_index")
			else
				maximumArrayIndex = math.max(maximumArrayIndex, key)
			end
		else
			addIssue(issues, state, path, `invalid_key_type:{keyType}`)
		end
	end

	if stringKeyCount > 0 and numericKeyCount > 0 then
		addIssue(issues, state, path, "mixed_table_keys")
	elseif numericKeyCount > 0 and maximumArrayIndex ~= numericKeyCount then
		addIssue(issues, state, path, "sparse_array")
	end

	for key, child in tbl do
		if state.LimitReached or #issues >= state.MaxIssues then
			break
		end
		local childPath = if path == "" then tostring(key) else `{path}.{tostring(key)}`
		validateValue(child, childPath, issues, state, depth + 1)
	end

	state.Seen[tbl] = nil
end

function SaveSerialize.validate(value: any): (boolean, { SerializeIssue })
	local issues: { SerializeIssue } = {}
	validateValue(value, "", issues, {
		Seen = {},
		Nodes = 0,
		MaxNodes = MAX_NODES,
		MaxIssues = MAX_ISSUES,
		LimitReached = false,
	}, 0)
	return #issues == 0, issues
end

function SaveSerialize.measureEncodedSize(value: any): (boolean, number?, string?)
	local ok, encodedOrError = pcall(function()
		return HttpService:JSONEncode(value)
	end)
	if not ok then
		return false, nil, tostring(encodedOrError)
	end
	return true, #(encodedOrError :: string), nil
end

function SaveSerialize.estimateSize(value: any): number
	local ok, size = SaveSerialize.measureEncodedSize(value)
	return if ok then size :: number else math.huge
end

return SaveSerialize
