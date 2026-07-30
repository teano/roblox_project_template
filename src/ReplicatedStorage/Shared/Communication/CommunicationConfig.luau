--!strict

return table.freeze({
	MaxMessagesPerBatch = 64,
	MaxMessagesPerSecond = 240,
	MaxBytesPerSecond = 256 * 1024,
	MaxEstimatedPayloadBytes = 64 * 1024,
	MaxSingleMessageEstimatedBytes = 60 * 1024,
	MaxQueuedMessagesPerPeer = 256,
	MaxQueuedPayloadBytesPerPeer = 256 * 1024,
	MaxRequestIdLength = 128,
	MaxRequestTypeLength = 128,
	MaxRequestsPerSecond = 16,
	MaxRequestResponseBytesPerSecond = 256 * 1024,
})
