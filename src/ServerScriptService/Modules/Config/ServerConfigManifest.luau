--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ConfigProtocol = require(ReplicatedStorage.Shared.Config.ConfigProtocol)
local Codecs = script.Parent.Codecs
local GlobalSaveConfigCodec = require(Codecs.GlobalSaveConfigCodec)
local WalletConfigCodec = require(Codecs.WalletConfigCodec)
local StatisticsConfigCodec = require(Codecs.StatisticsConfigCodec)
local CharactersConfigCodec = require(Codecs.CharactersConfigCodec)
local PlayerSlotsConfigCodec = require(Codecs.PlayerSlotsConfigCodec)
local FriendsConfigCodec = require(Codecs.FriendsConfigCodec)

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
		table.freeze({
			Id = "Characters",
			Key = "characters_config",
			Decode = CharactersConfigCodec.decode,
		}),
		table.freeze({
			Id = "PlayerSlots",
			Key = "player_slots_config",
			Decode = PlayerSlotsConfigCodec.decode,
		}),
		table.freeze({
			Id = "Friends",
			Key = "friends_config",
			Decode = FriendsConfigCodec.decode,
		}),
	}),
	ClientBundles = table.freeze({
		[ConfigProtocol.DefaultClientBundleId] = table.freeze({
			"GlobalSave",
		}),
	}),
})
