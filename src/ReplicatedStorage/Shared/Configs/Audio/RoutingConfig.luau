--!strict

return {
	Version = 1,
	InteractionGroupId = "AudioPlayback.Private.v1",
	Faders = {
		Master = { ParentFaderId = nil },
		UI = { ParentFaderId = "Master" },
		SFX = { ParentFaderId = "Master" },
		World = { ParentFaderId = "Master" },
		Music = { ParentFaderId = "Master" },
	},
	Routes = {
		UI = { PlayerType = "UI", SourceKind = "Direct", FaderId = "UI" },
		SFX = { PlayerType = "SFX", SourceKind = "Direct", FaderId = "SFX" },
		World = { PlayerType = "World", SourceKind = "Spatial", FaderId = "World" },
		Music = { PlayerType = "Music", SourceKind = "Direct", FaderId = "Music" },
	},
}
