--!strict

return table.freeze({
	Version = 1,
	MessageTypes = table.freeze({
		HybridIntent = "Audio.HybridOneShot.Intent",
		HybridPresentation = "Audio.HybridOneShot.Presentation",
	}),
	RuntimeRootName = "AudioRuntime",
	PublishedGraphName = "PublishedGraph",
	ServerPlaybackName = "ServerPlayback",
	CompositionId = "AudioGraph.v1",
	SchemaVersion = 1,
	Generation = 1,
	AttributeNames = table.freeze({
		CompositionId = "CompositionId",
		SchemaVersion = "SchemaVersion",
		Generation = "Generation",
		Ready = "Ready",
	}),
	PreloadRequestId = "AudioCatalog.Preload.v1",
})
