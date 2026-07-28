--!strict

export type SerializeIssue = {
	Path: string,
	Reason: string,
}

local SaveSerialize = {}

local function isFiniteNumber(value: number): boolean
	return value == value and value ~= math.huge and value ~= -math.huge
end

function SaveSerialize.validateValue(
	value: any,
	path: string,
	issues: { SerializeIssue },
	seen: { [{ [any]: any }]: boolean },
	depth: number?
)
	local currentDepth = depth or 0
	if currentDepth > 32 then
		table.insert(issues, { Path = path, Reason = "maximum_depth_exceeded" })
		return
	end

	local valueType = typeof(value)
	if valueType == "nil" or valueType == "boolean" or valueType == "string" then
		return
	end
	if valueType == "number" then
		if not isFiniteNumber(value) then
			table.insert(issues, { Path = path, Reason = "non_finite_number" })
		end
		return
	end
	if valueType ~= "table" then
		table.insert(issues, { Path = path, Reason = `unsupported_type:{valueType}` })
		return
	end

	local tbl = value :: { [any]: any }
	if seen[tbl] then
		table.insert(issues, { Path = path, Reason = "cyclic_table" })
		return
	end
	seen[tbl] = true

	for key, child in tbl do
		local keyType = typeof(key)
		if keyType ~= "string" and keyType ~= "number" then
			table.insert(issues, { Path = path, Reason = `invalid_key_type:{keyType}` })
			continue
		end
		local childPath = if path == "" then tostring(key) else `{path}.{key}`
		SaveSerialize.validateValue(child, childPath, issues, seen, currentDepth + 1)
	end
end

function SaveSerialize.validate(value: any): (boolean, { SerializeIssue })
	local issues: { SerializeIssue } = {}
	SaveSerialize.validateValue(value, "", issues, {}, 0)
	return #issues == 0, issues
end

function SaveSerialize.estimateSize(value: any): number
	local valueType = typeof(value)
	if valueType == "nil" then
		return 4
	elseif valueType == "boolean" then
		return 5
	elseif valueType == "number" then
		return 12
	elseif valueType == "string" then
		return #value + 2
	elseif valueType == "table" then
		local size = 2
		for key, child in value do
			size += SaveSerialize.estimateSize(key) + SaveSerialize.estimateSize(child) + 2
		end
		return size
	end
	return 16
end

return SaveSerialize
