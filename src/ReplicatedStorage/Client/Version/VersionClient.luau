--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TableUtil = require(ReplicatedStorage.Shared.Util.TableUtil)
local VersionConfig = require(ReplicatedStorage.Shared.Version.VersionConfig)

local VersionClient = {}
VersionClient.__index = VersionClient

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
		or typeof(value.InstallationVersion) ~= "string"
		or typeof(value.PreviousVersion) ~= "string"
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
