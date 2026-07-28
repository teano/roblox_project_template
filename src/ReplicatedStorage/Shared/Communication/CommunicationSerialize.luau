--!strict

local CommunicationSerialize = {}

local FIXED_SIZE_TYPES = table.freeze({
	Vector2 = 16,
	Vector3 = 24,
	CFrame = 64,
	Color3 = 24,
	UDim = 16,
	UDim2 = 32,
	Rect = 32,
	BrickColor = 8,
	NumberRange = 16,
	EnumItem = 8,
})

local function isFinite(value: number): boolean
	return value == value and value ~= math.huge and value ~= -math.huge
end

local function inspect(value: any, path: string, issues: { any }, seen: { [any]: boolean }, depth: number): number
	if depth > 32 then
		table.insert(issues, { Path = path, Reason = "maximum_depth_exceeded" })
		return 0
	end

	local valueType = typeof(value)
	if valueType == "nil" then
		return 4
	elseif valueType == "boolean" then
		return 5
	elseif valueType == "string" then
		return #value + 2
	elseif valueType == "number" then
		if not isFinite(value) then
			table.insert(issues, { Path = path, Reason = "non_finite_number" })
		end
		return 12
	end

	local fixedSize = FIXED_SIZE_TYPES[valueType]
	if fixedSize then
		return fixedSize
	end
	if valueType ~= "table" then
		table.insert(issues, { Path = path, Reason = `unsupported_type:{valueType}` })
		return 0
	end
	if seen[value] then
		table.insert(issues, { Path = path, Reason = "cyclic_table" })
		return 0
	end

	seen[value] = true
	local size = 2
	for key, child in value do
		local keyType = typeof(key)
		if keyType ~= "string" and keyType ~= "number" then
			table.insert(issues, { Path = path, Reason = `invalid_key_type:{keyType}` })
			continue
		end
		local childPath = if path == "" then tostring(key) else `{path}.{key}`
		size += inspect(key, childPath, issues, seen, depth + 1)
		size += inspect(child, childPath, issues, seen, depth + 1) + 2
	end
	seen[value] = nil
	return size
end

function CommunicationSerialize.inspect(value: any): (boolean, { any }, number)
	local issues = {}
	local size = inspect(value, "", issues, {}, 0)
	return #issues == 0, issues, size
end

function CommunicationSerialize.validate(value: any): (boolean, { any })
	local valid, issues = CommunicationSerialize.inspect(value)
	return valid, issues
end

function CommunicationSerialize.estimateSize(value: any): number
	local _, _, size = CommunicationSerialize.inspect(value)
	return size
end

return CommunicationSerialize
