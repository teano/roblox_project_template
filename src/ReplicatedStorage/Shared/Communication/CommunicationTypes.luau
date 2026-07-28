--!strict

export type Message = {
	Type: string,
	Payload: any,
	RequestId: string?,
}

export type Batch = {
	Epoch: number?,
	Sequence: number,
	Messages: { Message },
}

export type MessagePriority = "Critical" | "State" | "Presentation"

export type QueueOptions = {
	Priority: MessagePriority?,
}

return nil
