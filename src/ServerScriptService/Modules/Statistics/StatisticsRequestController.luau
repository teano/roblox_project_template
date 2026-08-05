--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CommunicationSerialize = require(ReplicatedStorage.Shared.Communication.CommunicationSerialize)
local StatisticsProtocol = require(ReplicatedStorage.Shared.Statistics.StatisticsProtocol)

local StatisticsRequestController = {}
StatisticsRequestController.__index = StatisticsRequestController

function StatisticsRequestController.new(deps: { Statistics: any, Communication: any })
	return setmetatable({
		_statistics = deps.Statistics,
		_communication = deps.Communication,
		_initialized = false,
	}, StatisticsRequestController)
end

function StatisticsRequestController:_bounded(value: any): (boolean, any?, string?)
	local valid, _, estimatedBytes = CommunicationSerialize.inspect(value, {
		MaxBytes = self._statistics:GetClientResponseLimit(),
	})
	if not valid or estimatedBytes > self._statistics:GetClientResponseLimit() then
		return false, nil, "ResponseTooLarge"
	end
	return true, value, nil
end

function StatisticsRequestController:Initialize()
	if self._initialized then return end
	self._initialized = true
	self._communication:RegisterRequestHandler(
		StatisticsProtocol.RequestTypes.GetCurrentSnapshot,
		StatisticsProtocol.ValidateSnapshotRequest,
		function(player, payload)
			local snapshot, snapshotError = self._statistics:BuildClientSnapshot(player, payload.SnapshotType)
			if snapshot == nil then return false, nil, snapshotError or "Unavailable" end
			return self:_bounded(snapshot)
		end
	)
	self._communication:RegisterRequestHandler(
		StatisticsProtocol.RequestTypes.GetCurrentValue,
		StatisticsProtocol.ValidateValueRequest,
		function(player, payload)
			local value, valueError = self._statistics:BuildClientValue(
				player,
				payload.SnapshotType,
				payload.StatisticId
			)
			if value == nil then return false, nil, valueError or "Unavailable" end
			return self:_bounded(value)
		end
	)
end

return StatisticsRequestController
