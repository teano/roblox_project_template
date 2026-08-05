--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ConfigProtocol = require(ReplicatedStorage.Shared.Config.ConfigProtocol)
local Codecs = script.Parent.Codecs
local GlobalSaveConfigCodec = require(Codecs.GlobalSaveConfigCodec)
local WalletConfigCodec = require(Codecs.WalletConfigCodec)
local StatisticsConfigCodec = require(Codecs.StatisticsConfigCodec)

-- Project definitions belong here. Values remain in Experience Configs; this
-- manifest owns code-reviewed schemas, logical IDs, and client disclosure.
return table.freeze({
	Definitions = table.freeze({
		table.freeze({
			Id = "Wallet",
			Key = "wallet_config",
			Decode = WalletConfigCodec.decode,
		}),
		table.freeze({
			Id = "GlobalSave",
			Key = "global_save_config",
			Decode = GlobalSaveConfigCodec.decode,
			ToClient = GlobalSaveConfigCodec.toClient,
		}),
		table.freeze({
			Id = "Statistics",
			Key = "statistics_config",
			Decode = StatisticsConfigCodec.decode,
		}),
	}),
	ClientBundles = table.freeze({
		[ConfigProtocol.DefaultClientBundleId] = table.freeze({
			"GlobalSave",
		}),
	}),
})
