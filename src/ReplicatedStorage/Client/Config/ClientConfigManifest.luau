--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ConfigProtocol = require(ReplicatedStorage.Shared.Config.ConfigProtocol)
local GlobalSaveConfigCodec = require(script.Parent.Codecs.GlobalSaveConfigCodec)

-- Client definitions decode only server-approved DTOs from one named bundle.
return table.freeze({
	BundleId = ConfigProtocol.DefaultClientBundleId,
	Definitions = table.freeze({
		table.freeze({
			Id = "GlobalSave",
			Decode = GlobalSaveConfigCodec.decode,
		}),
	}),
})
