--!strict

local function deepFreeze<T>(value: T): T
	if typeof(value) ~= "table" then
		return value
	end

	local tbl = value :: any
	if table.isfrozen(tbl) then
		return value
	end

	for key, child in tbl do
		tbl[key] = deepFreeze(child)
	end

	return table.freeze(tbl) :: T
end

return deepFreeze
