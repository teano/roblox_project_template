--!strict

local TableUtil = require(game:GetService("ReplicatedStorage").Shared.Util.TableUtil)

local MemoryStorage = {}
MemoryStorage.__index = MemoryStorage

function MemoryStorage.new(seed: { [string]: any }?)
	return setmetatable({
		_data = TableUtil.deepCopy(seed or {}),
	}, MemoryStorage)
end

function MemoryStorage:Update(key: string, transform: (any) -> any)
	local current = TableUtil.deepCopy(self._data[key])
	local ok, nextValue = pcall(transform, current)
	if not ok then
		return {
			Ok = false,
			Code = "TransformFailed",
			Error = tostring(nextValue),
		}
	end
	if nextValue == nil then
		return {
			Ok = true,
			Value = nil,
		}
	end
	self._data[key] = TableUtil.deepCopy(nextValue)
	return {
		Ok = true,
		Value = TableUtil.deepCopy(nextValue),
	}
end

function MemoryStorage:Read(key: string): any
	return TableUtil.deepCopy(self._data[key])
end

return MemoryStorage
