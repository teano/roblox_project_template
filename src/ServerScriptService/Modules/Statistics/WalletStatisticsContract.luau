--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local WalletConfig = require(ReplicatedStorage.Shared.Wallet.WalletConfig)

local SOURCE_ID = "Wallet"
local CANONICAL_TRANSACTION_ID_LENGTH = 36

local function statisticIdForCurrency(currencyId: string): string
	assert(WalletConfig.CurrencyIds[currencyId] == true, `Unknown Wallet currency '{currencyId}'`)
	return `Wallet.{currencyId}.Earned`
end

local requiredIdentifierLength = math.max(#SOURCE_ID, CANONICAL_TRANSACTION_ID_LENGTH)
for currencyId in WalletConfig.CurrencyIds do
	requiredIdentifierLength = math.max(requiredIdentifierLength, #statisticIdForCurrency(currencyId))
end

return table.freeze({
	SourceId = SOURCE_ID,
	CanonicalTransactionIdLength = CANONICAL_TRANSACTION_ID_LENGTH,
	RequiredIdentifierLength = requiredIdentifierLength,
	StatisticIdForCurrency = statisticIdForCurrency,
})
