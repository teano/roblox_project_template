--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TableUtil = require(ReplicatedStorage.Shared.Util.TableUtil)
local VersionConfig = require(ReplicatedStorage.Shared.Version.VersionConfig)

local MigrationModule = {}
MigrationModule.__index = MigrationModule

local function parseVersion(value: string): { number }
	local parts = {}
	for part in string.gmatch(value, "%d+") do
		table.insert(parts, tonumber(part) :: number)
	end
	while #parts < 3 do
		table.insert(parts, 0)
	end
	return parts
end

local function compareVersions(a: string, b: string): number
	local left = parseVersion(a)
	local right = parseVersion(b)
	for index = 1, math.max(#left, #right) do
		local lv = left[index] or 0
		local rv = right[index] or 0
		if lv < rv then
			return -1
		elseif lv > rv then
			return 1
		end
	end
	return 0
end

function MigrationModule.new()
	return setmetatable({
		_controllers = {},
	}, MigrationModule)
end

function MigrationModule:Initialize()
end

function MigrationModule:Register(controller: any)
	assert(typeof(controller.TargetVersion) == "string", "Migration TargetVersion required")
	table.insert(self._controllers, controller)
end

function MigrationModule:Migrate(document: any)
	local result = TableUtil.deepCopy(document)
	local versionEnvelope = if typeof(result) == "table"
		and typeof(result.Providers) == "table"
		then result.Providers[VersionConfig.ProviderId]
		else nil
	local previous = if typeof(versionEnvelope) == "table"
		and typeof(versionEnvelope.Data) == "table"
		and typeof(versionEnvelope.Data.PreviousVersion) == "string"
		then versionEnvelope.Data.PreviousVersion
		else VersionConfig.CurrentVersion

	local selected = {}
	for _, controller in self._controllers do
		if compareVersions(controller.TargetVersion, previous) > 0
			and compareVersions(controller.TargetVersion, VersionConfig.CurrentVersion) <= 0
		then
			table.insert(selected, controller)
		end
	end

	table.sort(selected, function(a, b)
		local comparison = compareVersions(a.TargetVersion, b.TargetVersion)
		if comparison == 0 then
			return (a.Order or 0) < (b.Order or 0)
		end
		return comparison < 0
	end)

	for _, controller in selected do
		result = controller:Migrate(result)
	end
	return result
end

MigrationModule.compareVersions = compareVersions

return MigrationModule
