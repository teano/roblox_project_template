--!strict

return table.freeze({
	MaxMessagesPerBatch = 64,
	MaxBatchInvocationsPerSecond = 120,
	MaxMessagesPerSecond = 240,
	MaxBytesPerSecond = 256 * 1024,
	MaxEstimatedPayloadBytes = 64 * 1024,
	MaxSingleMessageEstimatedBytes = 60 * 1024,
	MaxQueuedMessagesPerPeer = 256,
	MaxQueuedPayloadBytesPerPeer = 256 * 1024,
	MaxMessageTypeLength = 128,
	MaxRequestIdLength = 128,
	MaxRequestTypeLength = 128,
	MaxRequestsPerSecond = 16,
	MaxRequestResponseBytesPerSecond = 256 * 1024,
	SnapshotRequestCooldownSeconds = 0.5,
	MaxSnapshotEnvelopeEstimatedBytes = 64 * 1024,
	MaxSnapshotInspectionNodes = 500_000,
})
