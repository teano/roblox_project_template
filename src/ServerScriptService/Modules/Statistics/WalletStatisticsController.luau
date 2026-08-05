--!strict

local Logger = require(game:GetService("ReplicatedStorage").Shared.Util.Logger)
local WalletStatisticsContract = require(script.Parent.WalletStatisticsContract)

local WalletStatisticsController = {}
WalletStatisticsController.__index = WalletStatisticsController

local DIAGNOSTIC_COOLDOWN_SECONDS = 1

function WalletStatisticsController.new(deps: { Wallet: any, Statistics: any, Logger: any?, Clock: (() -> number)? })
	return setmetatable({
		_wallet = deps.Wallet,
		_statistics = deps.Statistics,
		_logger = deps.Logger or Logger.new("Statistics.WalletAdapter", "info"),
		_clock = deps.Clock or os.clock,
		_diagnosticAt = setmetatable({}, { __mode = "k" }),
		_registration = nil,
	}, WalletStatisticsController)
end

function WalletStatisticsController:_diagnose(player: Player, code: string)
	local now = self._clock()
	local playerDiagnostics = self._diagnosticAt[player]
	if playerDiagnostics == nil then
		playerDiagnostics = {}
		self._diagnosticAt[player] = playerDiagnostics
	end
	local lastAt = playerDiagnostics[code]
	if lastAt ~= nil and now - lastAt < DIAGNOSTIC_COOLDOWN_SECONDS then return end
	playerDiagnostics[code] = now
	self._logger:Warn("wallet_fact_rejected", {
		UserId = player.UserId,
		Code = code,
	})
end

function WalletStatisticsController:Initialize()
	if self._registration ~= nil then return end
	self._registration = self._wallet:RegisterCommittedChangeHandler(function(player, change)
		if change.Delta <= 0 then return { Ok = true, Code = "Ignored" } end
		local currencyId = change.Path[1]
		local result = self._statistics:ApplyOperation(player, {
			Operation = "Inc",
			StatisticId = WalletStatisticsContract.StatisticIdForCurrency(currencyId),
			Operand = change.Delta,
			FactIdentity = {
				Mode = "Ordered",
				SourceId = WalletStatisticsContract.SourceId,
				Sequence = change.TransactionSequence,
				EventId = change.TransactionId,
			},
		})
		if not result.Ok then
			self:_diagnose(player, result.Code)
		end
		return result
	end)
end

function WalletStatisticsController:Destroy()
	if self._registration ~= nil then
		self._registration:Disconnect()
		self._registration = nil
	end
end

return WalletStatisticsController
