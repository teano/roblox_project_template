--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ContentProvider = game:GetService("ContentProvider")
local Players = game:GetService("Players")

local Logger = require(ReplicatedStorage.Shared.Util.Logger)
local AssetRegistry = require(ReplicatedStorage.Shared.Assets.AssetRegistry)
local ContentPreloader = require(ReplicatedStorage.Shared.ContentPreloading.ContentPreloader)
local PoolModule = require(ReplicatedStorage.Shared.Pooling.PoolModule)
local PlayersModule = require(ReplicatedStorage.Client.Players.PlayersModule)
local CommunicationClient = require(ReplicatedStorage.Client.Communication.CommunicationClient)
local TeleportClient = require(ReplicatedStorage.Client.Teleport.TeleportClient)
local ClientConfigCatalog = require(ReplicatedStorage.Client.Config.ClientConfigCatalog)
local ClientConfigManifest = require(ReplicatedStorage.Client.Config.ClientConfigManifest)
local SaveModule = require(ReplicatedStorage.Client.Save.SaveModule)
local VersionClient = require(ReplicatedStorage.Client.Version.VersionClient)
local WalletClient = require(ReplicatedStorage.Client.Wallet.WalletClient)
local StatisticsClient = require(ReplicatedStorage.Client.Statistics.StatisticsClient)

local Commands = script.Parent.Commands
local AssetRegistryInitializationCommand = require(Commands.AssetRegistryInitializationCommand)
local StartupContentPreloadCommand = require(Commands.StartupContentPreloadCommand)
local PoolingInitializationCommand = require(Commands.PoolingInitializationCommand)
local PlayersInitializationCommand = require(Commands.PlayersInitializationCommand)
local CommunicationInitializationCommand = require(Commands.CommunicationInitializationCommand)
local TeleportInitializationCommand = require(Commands.TeleportInitializationCommand)
local ConfigInitializationCommand = require(Commands.ConfigInitializationCommand)
local SaveInitializationCommand = require(Commands.SaveInitializationCommand)
local DomainDataInitializationCommand = require(Commands.DomainDataInitializationCommand)
local StatisticsInitializationCommand = require(Commands.StatisticsInitializationCommand)
local GlobalSaveInitializationCommand = require(Commands.GlobalSaveInitializationCommand)

local replicatedAssets = ReplicatedStorage:FindFirstChild("Assets")
assert(replicatedAssets ~= nil and replicatedAssets:IsA("Folder"), "ReplicatedStorage.Assets must be a Folder")
local sharedAssets = replicatedAssets:FindFirstChild("Shared")
assert(sharedAssets ~= nil and sharedAssets:IsA("Folder"), "ReplicatedStorage.Assets.Shared must be a Folder")
local clientAssets = replicatedAssets:FindFirstChild("Client")
assert(clientAssets ~= nil and clientAssets:IsA("Folder"), "ReplicatedStorage.Assets.Client must be a Folder")

local assetRegistry = AssetRegistry.new({
	{
		Namespace = "Shared",
		Root = sharedAssets,
	},
	{
		Namespace = "Client",
		Root = clientAssets,
	},
})
local contentPreloader = ContentPreloader.new({
	Assets = assetRegistry,
	ContentProvider = ContentProvider,
	Logger = Logger.new("ContentPreloader.Client", "info"),
})
local poolModule = PoolModule.new()
local playersModule = PlayersModule.new()
local communication = CommunicationClient.new()
local teleportClient = TeleportClient.new({
	Communication = communication,
	PlayersModule = playersModule,
	MaxPlayers = Players.MaxPlayers,
})
local configCatalog = ClientConfigCatalog.new({
	Communication = communication,
	BundleId = ClientConfigManifest.BundleId,
	Definitions = ClientConfigManifest.Definitions,
})
local saveModule = SaveModule.new(communication)
local versionClient = VersionClient.new()
local walletClient = WalletClient.new(communication)
local statisticsClient = StatisticsClient.new(communication)

local services = {
	Assets = assetRegistry,
	ContentPreloader = contentPreloader,
	Pooling = poolModule,
	Players = playersModule,
	Communication = communication,
	Teleport = teleportClient,
	Config = configCatalog,
	Save = saveModule,
	Version = versionClient,
	Wallet = walletClient,
	Statistics = statisticsClient,
}

return {
	Services = services,
	Logger = Logger.new("ClientInitialization", "info"),
	Commands = {
		AssetRegistryInitializationCommand.new(assetRegistry),
		StartupContentPreloadCommand.new(contentPreloader),
		PoolingInitializationCommand.new(poolModule),
		PlayersInitializationCommand.new(playersModule),
		CommunicationInitializationCommand.new(communication),
		StatisticsInitializationCommand.new(statisticsClient),
		TeleportInitializationCommand.new(teleportClient),
		ConfigInitializationCommand.new(configCatalog),
		SaveInitializationCommand.new(saveModule),
		DomainDataInitializationCommand.new({
			versionClient,
			walletClient,
		}),
		GlobalSaveInitializationCommand.new({
			SaveModule = saveModule,
			Communication = communication,
			Config = configCatalog,
			Teleport = teleportClient,
			Version = versionClient,
			Wallet = walletClient,
		}),
	},
}
