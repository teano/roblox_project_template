--!strict

local TableUtil = {}

function TableUtil.deepCopy<T>(value: T): T
	if typeof(value) ~= "table" then
		return value
	end

	local source = value :: any
	local copy: { [any]: any } = {}
	for key, child in source do
		copy[TableUtil.deepCopy(key)] = TableUtil.deepCopy(child)
	end

	return (copy :: any) :: T
end

function TableUtil.shallowCopy<T>(value: T): T
	if typeof(value) ~= "table" then
		return value
	end

	local source = value :: any
	local copy: { [any]: any } = {}
	for key, child in source do
		copy[key] = child
	end

	return (copy :: any) :: T
end

function TableUtil.deepEqual(a: any, b: any): boolean
	if a == b then
		return true
	end

	if typeof(a) ~= typeof(b) then
		return false
	end

	if typeof(a) ~= "table" then
		return false
	end

	for key, value in a do
		if not TableUtil.deepEqual(value, b[key]) then
			return false
		end
	end

	for key in b do
		if a[key] == nil then
			return false
		end
	end

	return true
end

function TableUtil.getPath(root: any, path: { any }): any
	local current = root
	for _, key in path do
		if typeof(current) ~= "table" then
			return nil
		end
		current = current[key]
	end
	return current
end

function TableUtil.setPath(root: { [any]: any }, path: { any }, value: any)
	assert(#path > 0, "path must not be empty")
	local current = root
	for index = 1, #path - 1 do
		local key = path[index]
		local nextNode = current[key]
		if typeof(nextNode) ~= "table" then
			nextNode = {}
			current[key] = nextNode
		end
		current = nextNode
	end
	current[path[#path]] = value
end

return TableUtil
