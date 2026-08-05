--!strict

export type SnapshotType = "Global" | "Session" | "Place" | string
export type OperationName = "Set" | "Inc" | "Dec" | "Min" | "Max"

export type FactIdentity =
	{ Mode: "Ordered", SourceId: string, Sequence: number, EventId: string? }
	| { Mode: "EventId", SourceId: string, EventId: string }

export type StatisticOperation = {
	Operation: OperationName,
	StatisticId: string,
	Operand: number,
	FactIdentity: FactIdentity?,
}

export type SnapshotRecord = {
	SnapshotId: number,
	SnapshotType: string,
	State: "Active" | "Closed",
	StartedAt: number,
	ClosedAt: number?,
	PlaceId: number?,
	SessionId: string?,
	Metadata: { [string]: any },
	Filter: {
		Mode: "AllowOnly" | "AllowAllExcept",
		StatisticIds: { string },
	},
	Values: { [string]: number },
}

export type ClientSnapshot = {
	SnapshotId: number,
	SnapshotType: "Global" | "Session" | "Place",
	State: "Active",
	StartedAt: number,
	PlaceId: number?,
	Metadata: { [string]: any },
	Values: { [string]: number },
}

return nil
