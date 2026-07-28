--!strict

return table.freeze({
	RemoteFolderName = "Communication",
	ClientToServerEventName = "ClientToServer",
	ServerToClientEventName = "ServerToClient",

	Priorities = table.freeze({
		Critical = "Critical",
		State = "State",
		Presentation = "Presentation",
	}),

	SystemMessages = table.freeze({
		ClientReady = "System.ClientReady",
		ResyncRequired = "System.ResyncRequired",
		SaveClientPatch = "Save.ClientPatch",
		SaveClientPatchResult = "Save.ClientPatchResult",
	}),
})
