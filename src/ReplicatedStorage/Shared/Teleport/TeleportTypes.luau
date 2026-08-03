--!strict

export type EntryKind = "External" | "Teleported"
export type AttemptState = "Started" | "Accepted"

export type SessionSnapshot = {
	SessionId: string,
	EntryKind: EntryKind,
	SourcePlaceId: number?,
}

export type TeleportDestination =
	{ Kind: "Public", PlaceId: number }
	| { Kind: "ServerInstance", PlaceId: number, ServerInstanceId: string }
	| { Kind: "ReservedServer", PlaceId: number, ReservedServerAccessCode: string }
	| { Kind: "NewReservedServer", PlaceId: number }

export type AttemptSnapshot = {
	AttemptId: string,
	State: AttemptState,
	DestinationKind: string,
	PlaceId: number,
}

export type TeleportRequestResult =
	{ Ok: true, AttemptId: string }
	| { Ok: false, Code: string, Error: string, AttemptId: string? }

return nil
