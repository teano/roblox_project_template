--!strict

return table.freeze({
	ProviderId = "Wallet",
	ProviderVersion = 2,
	CurrencyIds = table.freeze({
		Coins = true,
		Gems = true,
	}),
	MessageTypes = table.freeze({
		Changed = "Wallet.Changed",
	}),
})
