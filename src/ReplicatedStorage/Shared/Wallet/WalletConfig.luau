--!strict

return table.freeze({
	ProviderId = "Wallet",
	ProviderVersion = 3,
	MaxBalance = 9_007_199_254_740_991,
	CurrencyIds = table.freeze({
		Coins = true,
		Gems = true,
	}),
	MessageTypes = table.freeze({
		Changed = "Wallet.Changed",
	}),
})
