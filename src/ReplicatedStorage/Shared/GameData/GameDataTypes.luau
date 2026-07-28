--!strict

export type ChangeRecord = {
	ProviderId: string,
	ItemId: string?,
	Path: { any },
	OldValue: any,
	NewValue: any,
	Delta: number?,
	Reason: string?,
	Metadata: { [string]: any }?,
	TransactionId: string?,
	ProfileRevision: number?,
	ItemRevision: number?,
}

return nil
