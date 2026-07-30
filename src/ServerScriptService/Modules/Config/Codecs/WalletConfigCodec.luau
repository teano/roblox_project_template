--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local WalletConfig = require(ReplicatedStorage.Shared.Wallet.WalletConfig)

local WalletConfigCodec = {}

local function isNonNegativeInteger(value: any): boolean
	return typeof(value) == "number"
		and value == value
		and value ~= math.huge
		and value ~= -math.huge
		and value >= 0
		and value <= WalletConfig.MaxBalance
		and value == math.floor(value)
end

function WalletConfigCodec.decode(value: any): (boolean, any?, string?)
	if typeof(value) ~= "table" then
		return false, nil, "wallet_config: expected object"
	end
	for key in value do
		if key ~= "startingBalances" then
			return false, nil, `wallet_config.{tostring(key)}: unknown field`
		end
	end
	if typeof(value.startingBalances) ~= "table" then
		return false, nil, "wallet_config.startingBalances: expected object"
	end

	local startingBalances: { [string]: number } = {}
	for key in value.startingBalances do
		if WalletConfig.CurrencyIds[key] ~= true then
			return false, nil, `wallet_config.startingBalances.{tostring(key)}: unknown currency`
		end
	end
	for currencyId in WalletConfig.CurrencyIds do
		local amount = value.startingBalances[currencyId]
		if not isNonNegativeInteger(amount) then
			return false, nil, `wallet_config.startingBalances.{currencyId}: expected safe non-negative integer`
		end
		startingBalances[currencyId] = amount
	end

	return true, {
		StartingBalances = startingBalances,
	}, nil
end

return WalletConfigCodec
