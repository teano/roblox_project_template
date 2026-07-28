--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Logger = require(ReplicatedStorage.Shared.Util.Logger)
local PlayersModule = require(ReplicatedStorage.Client.Players.PlayersModule)
local CommunicationClient = require(ReplicatedStorage.Client.Communication.CommunicationClient)
local SaveModule = require(ReplicatedStorage.Client.Save.SaveModule)
local VersionClient = require(ReplicatedStorage.Client.Version.VersionClient)
local WalletClient = require(ReplicatedStorage.Client.Wallet.WalletClient)

local Commands = script.Parent.Commands
local PlayersInitializationCommand = require(Commands.PlayersInitializationCommand)
local CommunicationInitializationCommand = require(Commands.CommunicationInitializationCommand)
local SaveInitializationCommand = require(Commands.SaveInitializationCommand)
local DomainDataInitializationCommand = require(Commands.DomainDataInitializationCommand)
local GlobalSaveInitializationCommand = require(Commands.GlobalSaveInitializationCommand)

local playersModule = PlayersModule.new()
local communication = CommunicationClient.new()
local saveModule = SaveModule.new(communication)
local versionClient = VersionClient.new()
local walletClient = WalletClient.new(communication)

local services = {
	Players = playersModule,
	Communication = communication,
	Save = saveModule,
	Version = versionClient,
	Wallet = walletClient,
}

return {
	Services = services,
	Logger = Logger.new("ClientInitialization", "info"),
	Commands = {
		PlayersInitializationCommand.new(playersModule),
		CommunicationInitializationCommand.new(communication),
		SaveInitializationCommand.new(saveModule),
		DomainDataInitializationCommand.new({
			versionClient,
			walletClient,
		}),
		GlobalSaveInitializationCommand.new({
			SaveModule = saveModule,
			Communication = communication,
			Version = versionClient,
			Wallet = walletClient,
		}),
	},
}
