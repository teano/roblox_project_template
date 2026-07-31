--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local TableUtil = require(ReplicatedStorage.Shared.Util.TableUtil)
local VersionConfig = require(ReplicatedStorage.Shared.Version.VersionConfig)

local VersionModule = {}
VersionModule.__index = VersionModule

local function isNonNegativeInteger(value: any): boolean
	return typeof(value) == "number"
		and value == value
		and value ~= math.huge
		and value ~= -math.huge
		and value >= 0
		and value == math.floor(value)
end

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

function VersionModule.new()
	return setmetatable({
		Id = VersionConfig.ProviderId,
		Version = VersionConfig.ProviderVersion,
		Authority = "Server",
		_data = {} :: { [Player]: any },
		_running = {} :: { [Player]: boolean },
		MementoChanged = Signal.new(),
	}, VersionModule)
end

function VersionModule:Initialize()
end

function VersionModule:CreateDefault(_player: Player)
	return {
		InstallationVersion = VersionConfig.CurrentVersion,
		PreviousVersion = VersionConfig.CurrentVersion,
		PlaceVersion = game.PlaceVersion,
	}
end

function VersionModule:ReconcileMemento(player: Player, value: any, _fromVersion: number)
	local result = self:CreateDefault(player)
	if typeof(value) == "table" then
		if isVersion(value.InstallationVersion) then
			result.InstallationVersion = value.InstallationVersion
		end
		if isVersion(value.PreviousVersion) then
			result.PreviousVersion = value.PreviousVersion
		end
		if isNonNegativeInteger(value.PlaceVersion) then
			result.PlaceVersion = value.PlaceVersion
		end
	end
	return result
end

function VersionModule:ValidateMemento(player: Player, value: any): (boolean, any?, string?)
	local data = self:ReconcileMemento(player, value, self.Version)
	if not isVersion(data.InstallationVersion)
		or not isVersion(data.PreviousVersion)
		or not isNonNegativeInteger(data.PlaceVersion)
	then
		return false, nil, "Invalid version memento"
	end
	return true, data, nil
end

function VersionModule:SetMemento(player: Player, value: any)
	self._data[player] = TableUtil.deepCopy(value)
end

function VersionModule:GetMemento(player: Player)
	return TableUtil.deepCopy(assert(self._data[player], "Version memento is not set"))
end

function VersionModule:BeforeMementoGet(_player: Player)
end

function VersionModule:Run(player: Player)
	local data = assert(self._data[player], "Version memento is not set")
	local changed = data.PreviousVersion ~= VersionConfig.CurrentVersion
		or data.PlaceVersion ~= game.PlaceVersion
	data.PreviousVersion = VersionConfig.CurrentVersion
	data.PlaceVersion = game.PlaceVersion
	self._running[player] = true
	if changed then
		self.MementoChanged:Fire(player)
	end
end

function VersionModule:Stop(player: Player)
	self._running[player] = nil
	self._data[player] = nil
end

function VersionModule:ToClientMemento(_player: Player, value: any)
	return TableUtil.deepCopy(value)
end

return VersionModule
