--!strict

return table.freeze({
	RequestTypes = table.freeze({
		GetClientBundle = "Config.GetClientBundle",
	}),

	DefaultClientBundleId = "Bootstrap",
	MaxIdentifierLength = 128,
	MaxClientBundleEstimatedBytes = 56 * 1024,
	StartupRequestAttempts = 40,
	StartupRetryDelaySeconds = 0.25,
})
