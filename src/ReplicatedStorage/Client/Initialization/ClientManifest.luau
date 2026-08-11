--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ContentProvider = game:GetService("ContentProvider")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

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
local AudioGraphClient = require(ReplicatedStorage.Client.Audio.AudioGraphClient)
local OrdinarySoundClient = require(ReplicatedStorage.Client.Audio.OrdinarySoundClient)
local HybridOneShotClientController = require(ReplicatedStorage.Client.Audio.HybridOneShotClientController)
local MusicClient = require(ReplicatedStorage.Client.Audio.MusicClient)
local AudioSettingsClient = require(ReplicatedStorage.Client.Audio.AudioSettingsClient)

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
local AudioStartupInitializationCommand = require(Commands.AudioStartupInitializationCommand)
local AudioGraphInitializationCommand = require(Commands.AudioGraphInitializationCommand)
local OrdinarySoundInitializationCommand = require(Commands.OrdinarySoundInitializationCommand)
local MusicInitializationCommand = require(Commands.MusicInitializationCommand)

local replicatedAssets = ReplicatedStorage:FindFirstChild("Assets")
assert(replicatedAssets ~= nil and replicatedAssets:IsA("Folder"), "ReplicatedStorage.Assets must be a Folder")
local sharedAssets = replicatedAssets:FindFirstChild("Shared")
assert(sharedAssets ~= nil and sharedAssets:IsA("Folder"), "ReplicatedStorage.Assets.Shared must be a Folder")
local clientAssets = replicatedAssets:FindFirstChild("Client")
assert(clientAssets ~= nil and clientAssets:IsA("Folder"), "ReplicatedStorage.Assets.Client must be a Folder")

local initializationLogger = Logger.new("ClientInitialization", "info")
local audioLogger = Logger.new("Audio.Client", "info")

local assetRegistry = AssetRegistry.new({
	{
		Namespace = "Shared",
		Root = sharedAssets,
	},
	{
		Namespace = "Client",
		Root = clientAssets,
	},
}, { AllowAudioDuplicateKeys = true, Logger = audioLogger })
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
local audioGraph = AudioGraphClient.new({
	RuntimeParent = ReplicatedStorage,
	LocalPlayer = Players.LocalPlayer,
	PlayersModule = playersModule,
	Workspace = Workspace,
	GetCurrentCameraCFrame = function()
		local camera = Workspace.CurrentCamera
		return if camera == nil then nil else camera.CFrame
	end,
	ListenerFrameDriver = RunService.RenderStepped,
	Logger = audioLogger,
})
local ordinarySound = OrdinarySoundClient.new(poolModule, audioLogger, {
	Workspace = Workspace,
	SpatialFrameDriver = RunService.RenderStepped,
})
local hybridAudio = HybridOneShotClientController.new({
	Communication = communication,
	Logger = audioLogger,
	PlayReceivedPresentation = function(payload) ordinarySound:PlayReceivedPresentation(payload) end,
})
ordinarySound:BindHybridIntentSender(hybridAudio)
local music = MusicClient.new(poolModule, audioLogger)
local audioSettings = AudioSettingsClient.new(audioGraph)
local sharedRoot = ReplicatedStorage:FindFirstChild("Shared")
local configsRoot = if sharedRoot then sharedRoot:FindFirstChild("Configs") else nil
local audioConfigRoot = if configsRoot then configsRoot:FindFirstChild("Audio") else nil

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
	AudioGraph = audioGraph,
	OrdinarySound = ordinarySound,
	Music = music,
	AudioSettings = audioSettings,
}

return {
	Services = services,
	Logger = initializationLogger,
	Commands = {
		AssetRegistryInitializationCommand.new(assetRegistry),
		AudioStartupInitializationCommand.new(audioConfigRoot, assetRegistry, "Client", audioLogger, sharedAssets),
		StartupContentPreloadCommand.new(contentPreloader),
		PoolingInitializationCommand.new(poolModule),
		PlayersInitializationCommand.new(playersModule),
		CommunicationInitializationCommand.new(communication),
		AudioGraphInitializationCommand.new(audioGraph),
		OrdinarySoundInitializationCommand.new(ordinarySound, hybridAudio),
		MusicInitializationCommand.new(music),
		StatisticsInitializationCommand.new(statisticsClient),
		TeleportInitializationCommand.new(teleportClient),
		ConfigInitializationCommand.new(configCatalog),
		SaveInitializationCommand.new(saveModule),
		DomainDataInitializationCommand.new({
			walletClient,
			audioSettings,
			versionClient,
		}),
		GlobalSaveInitializationCommand.new({
			SaveModule = saveModule,
			Communication = communication,
			Config = configCatalog,
			Teleport = teleportClient,
			Version = versionClient,
			Wallet = walletClient,
			AudioSettings = audioSettings,
		}),
	},
}
