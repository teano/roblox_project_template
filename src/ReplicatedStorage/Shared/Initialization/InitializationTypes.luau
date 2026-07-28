--!strict

export type InitializationContext = {
	Side: "Server" | "Client",
	Services: { [string]: any },
}

export type InitializationCommand = {
	Id: string,
	DependsOn: { string },
	Initialize: (self: InitializationCommand, context: InitializationContext) -> (),
}

export type InitializationResult =
	{
		Ok: true,
	}
	| {
		Ok: false,
		CommandId: string?,
		Error: string,
	}

return nil
