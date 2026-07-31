--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TableUtil = require(ReplicatedStorage.Shared.Util.TableUtil)
local VersionConfig = require(ReplicatedStorage.Shared.Version.VersionConfig)

local VersionClient = {}
VersionClient.__index = VersionClient

local function isVersion(value: any): boolean
	if typeof(value) ~= "string" then
		return false
	end
	local major, minor, patch = string.match(value, "^(%d+)%.(%d+)%.(%d+)$")
	if major == nil or minor == nil or patch == nil then
		return false
	end
	for _, componentText in { major, minor, patch } do
		if #componentText > 1 and string.sub(componentText, 1, 1) == "0" then
			return false
		end
		local component = tonumber(componentText)
		if component == nil
			or component ~= component
			or component == math.huge
			or component > 9_007_199_254_740_991
		then
			return false
		end
	end
	return true
end

function VersionClient.new()
	return setmetatable({
		Id = VersionConfig.ProviderId,
		Version = VersionConfig.ProviderVersion,
		Authority = "Server",
		_data = nil,
		_running = false,
	}, VersionClient)
end

function VersionClient:Initialize()
end

function VersionClient:ValidateMemento(value: any): (boolean, any?, string?)
	if typeof(value) ~= "table"
		or not isVersion(value.InstallationVersion)
		or not isVersion(value.PreviousVersion)
		or typeof(value.PlaceVersion) ~= "number"
		or value.PlaceVersion ~= value.PlaceVersion
		or value.PlaceVersion == math.huge
		or value.PlaceVersion == -math.huge
		or value.PlaceVersion < 0
		or value.PlaceVersion ~= math.floor(value.PlaceVersion)
	then
		return false, nil, "Invalid version memento"
	end
	return true, TableUtil.deepCopy(value), nil
end

function VersionClient:SetMemento(value: any)
	self._data = TableUtil.deepCopy(value)
end

function VersionClient:GetMemento()
	return TableUtil.deepCopy(self._data)
end

function VersionClient:Run()
	self._running = true
end

function VersionClient:Stop()
	self._running = false
	self._data = nil
end

return VersionClient
