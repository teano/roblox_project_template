--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local StatisticsProtocol = require(ReplicatedStorage.Shared.Statistics.StatisticsProtocol)
local TableUtil = require(ReplicatedStorage.Shared.Util.TableUtil)

local StatisticsClient = {}
StatisticsClient.__index = StatisticsClient

function StatisticsClient.new(communication: any)
	return setmetatable({ _communication = communication, _initialized = false }, StatisticsClient)
end

function StatisticsClient:Initialize()
	self._initialized = true
end

function StatisticsClient:GetCurrentSnapshot(snapshotType: string)
	if not self._initialized then return { Ok = false, Code = "NotInitialized" } end
	local ok, payload, requestError = self._communication:Request(
		StatisticsProtocol.RequestTypes.GetCurrentSnapshot,
		{ SnapshotType = snapshotType }
	)
	if not ok then return { Ok = false, Code = requestError or "Unavailable" } end
	local valid, sanitized = StatisticsProtocol.ValidateClientSnapshot(payload)
	if not valid then return { Ok = false, Code = "InvalidResponse" } end
	return { Ok = true, Snapshot = TableUtil.deepCopy(sanitized) }
end

function StatisticsClient:GetCurrentValue(snapshotType: string, statisticId: string)
	if not self._initialized then return { Ok = false, Code = "NotInitialized" } end
	local ok, payload, requestError = self._communication:Request(
		StatisticsProtocol.RequestTypes.GetCurrentValue,
		{ SnapshotType = snapshotType, StatisticId = statisticId }
	)
	if not ok then return { Ok = false, Code = requestError or "Unavailable" } end
	local valid, sanitized = StatisticsProtocol.ValidateClientValue(payload)
	if not valid then return { Ok = false, Code = "InvalidResponse" } end
	return { Ok = true, Value = TableUtil.deepCopy(sanitized) }
end

return StatisticsClient
