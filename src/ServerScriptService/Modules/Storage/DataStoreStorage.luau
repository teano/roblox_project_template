--!strict

local DataStoreService = game:GetService("DataStoreService")

local Logger = require(game:GetService("ReplicatedStorage").Shared.Util.Logger)

local DataStoreStorage = {}
DataStoreStorage.__index = DataStoreStorage

function DataStoreStorage.new(config: any, logger: any?, storeOverride: any?)
	local store = storeOverride or DataStoreService:GetDataStore(config.DataStoreName, config.DataStoreScope)
	return setmetatable({
		_store = store,
		_retry = config.Retry,
		_logger = logger or Logger.new("Storage.DataStore", "info"),
	}, DataStoreStorage)
end

function DataStoreStorage:_runWithRetry(key: string, operation: () -> any, options: any?)
	local lastError = "unknown"
	for attempt = 1, self._retry.MaxAttempts do
		if options and options.Deadline and os.clock() >= options.Deadline then
			return {
				Ok = false,
				Code = "DeadlineExceeded",
				Error = "DataStore operation deadline exceeded",
			}
		end

		local ok, value = pcall(operation)
		if ok then
			return {
				Ok = true,
				Value = value,
			}
		end

		lastError = tostring(value)
		self._logger:Warn("datastore_attempt_failed", {
			Key = key,
			Attempt = attempt,
			Error = lastError,
		})

		if attempt < self._retry.MaxAttempts then
			local exponential = self._retry.BaseDelaySeconds * (2 ^ (attempt - 1))
			local delaySeconds = math.min(self._retry.MaxDelaySeconds, exponential)
				+ math.random() * self._retry.JitterSeconds
			if options and options.Deadline then
				local remaining = options.Deadline - os.clock()
				if remaining <= 0 then
					return {
						Ok = false,
						Code = "DeadlineExceeded",
						Error = lastError,
					}
				end
				delaySeconds = math.min(delaySeconds, remaining)
			end
			task.wait(delaySeconds)
		end
	end

	return {
		Ok = false,
		Code = "RetryExhausted",
		Error = lastError,
	}
end

function DataStoreStorage:Update(key: string, transform: (any) -> any, options: any?)
	return self:_runWithRetry(key, function()
		return self._store:UpdateAsync(key, transform)
	end, options)
end

return DataStoreStorage
