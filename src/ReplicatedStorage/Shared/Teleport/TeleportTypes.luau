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

export type FriendsTeleportContinuation = {
	Version: number,
	Token: string,
	TargetJobId: string,
	Attempt: number,
}

export type FriendsContinuationResult =
	{ Status: "Absent" }
	| { Status: "Valid", Continuation: FriendsTeleportContinuation }
	| { Status: "Invalid", Code: string }

export type AdmissionTeleportContinuation = {
	Version: number,
	ServerKey: string,
	Generation: string,
	SlotId: number,
	Token: string,
	Hop: number,
}

export type AdmissionContinuationResult =
	{ Status: "Absent" }
	| { Status: "Valid", Continuation: AdmissionTeleportContinuation }
	| { Status: "Invalid", Code: string }

export type ReserveServerResult =
	{ Ok: true, AccessCode: string, PrivateServerId: string }
	| { Ok: false, Error: string }

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
