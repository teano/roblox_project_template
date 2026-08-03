--!strict

local RunService = game:GetService("RunService")

return table.freeze({
	DataStoreName = "PlayerData_v1",
	DataStoreScope = nil,
	KeyPrefix = "User_",
	UseMemoryStorage = RunService:IsStudio(),
	StaleLockSeconds = 30 * 60,
	LockRefreshIntervalSeconds = 5 * 60,
	LockAcquisitionRetry = table.freeze({
		MaxAttempts = 8,
		BaseDelaySeconds = 0.25,
		MaxDelaySeconds = 2,
	}),
	SoftSerializedBytesLimit = 3_500_000,
	Retry = table.freeze({
		MaxAttempts = 5,
		BaseDelaySeconds = 0.4,
		MaxDelaySeconds = 8,
		JitterSeconds = 0.25,
	}),
	ShutdownBudgetSeconds = 20,
	ShutdownMaxConcurrency = 4,
})
