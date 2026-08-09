--!strict

return {
	Version = 1,
	PlayerTypes = {
		UI = { PlayerType = "UI", ServerMaxActive = 0, ServerMaxRetained = 0, ClientMaxActive = 24, ClientMaxRetained = 12, HybridRatePerSecond = 0, HybridBurst = 0, SourceVolumeMin = 0, SourceVolumeMax = 1, PlaybackSpeedMin = 0.5, PlaybackSpeedMax = 2, LoadTimeoutSeconds = 2 },
		SFX = { PlayerType = "SFX", ServerMaxActive = 32, ServerMaxRetained = 16, ClientMaxActive = 32, ClientMaxRetained = 16, HybridRatePerSecond = 12, HybridBurst = 16, SourceVolumeMin = 0, SourceVolumeMax = 1, PlaybackSpeedMin = 0.5, PlaybackSpeedMax = 2, LoadTimeoutSeconds = 3 },
		World = { PlayerType = "World", ServerMaxActive = 64, ServerMaxRetained = 32, ClientMaxActive = 48, ClientMaxRetained = 24, HybridRatePerSecond = 12, HybridBurst = 16, SourceVolumeMin = 0, SourceVolumeMax = 1, PlaybackSpeedMin = 0.5, PlaybackSpeedMax = 2, LoadTimeoutSeconds = 3 },
		Music = { PlayerType = "Music", ClientMaxActive = 8, ClientMaxRetained = 2, MusicStackMaxDepth = 8, SourceVolumeMin = 0, SourceVolumeMax = 1, PlaybackSpeedMin = 0.5, PlaybackSpeedMax = 2, LoadTimeoutSeconds = 15 },
	},
	Faders = {
		Master = { DefaultLevel01 = 1, MinDb = -60, MaxDb = 0, Curve = "LinearDb" },
		UI = { DefaultLevel01 = 1, MinDb = -60, MaxDb = 0, Curve = "LinearDb" },
		SFX = { DefaultLevel01 = 1, MinDb = -60, MaxDb = 0, Curve = "LinearDb" },
		World = { DefaultLevel01 = 1, MinDb = -60, MaxDb = 0, Curve = "LinearDb" },
		Music = { DefaultLevel01 = 1, MinDb = -60, MaxDb = 0, Curve = "LinearDb" },
	},
}
