--!strict

export type ProviderEnvelope = {
	Version: number,
	Data: any,
}

export type SaveMemento = {
	FormatVersion: number,
	Revision: number,
	Providers: { [string]: ProviderEnvelope },
	Metadata: {
		CreatedAt: number,
		UpdatedAt: number,
	},
	Session: any?,
}

export type SaveSnapshot = {
	ControllerId: string,
	Revision: number,
	Providers: { [string]: ProviderEnvelope },
}

export type SaveResult =
	{
		Ok: true,
		Revision: number,
	}
	| {
		Ok: false,
		Code: string,
		Error: string,
	}

return nil
