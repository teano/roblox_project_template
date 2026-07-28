--!strict

return table.freeze({
	ProviderId = "Wallet",
	ProviderVersion = 1,
	CurrencyIds = table.freeze({
		Coins = true,
		Gems = true,
	}),
	Defaults = table.freeze({
		Coins = 0,
		Gems = 0,
	}),
	MessageTypes = table.freeze({
		Changed = "Wallet.Changed",
	}),
})
