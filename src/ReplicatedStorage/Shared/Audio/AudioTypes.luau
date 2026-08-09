--!strict

export type SoundRef =
	{ CueId: string }
	| { AssetId: string }
	| { AssetKey: string }
	| { ResourcePath: string }
	| { FolderPath: string }

export type PlayOptions = {
	VolumeMultiplier: number?,
	PlaybackSpeedMultiplier: number?,
	TimePosition: number?,
}

export type MusicTransition =
	{ Strategy: "Instant" }
	| { Strategy: "SequentialFade", FadeOutSeconds: number?, FadeInSeconds: number? }
	| { Strategy: "Crossfade", FadeOutSeconds: number?, FadeInSeconds: number? }

return table.freeze({})
