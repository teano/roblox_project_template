--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local AssetService = game:GetService("AssetService")
local ContentProvider = game:GetService("ContentProvider")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local SocialService = game:GetService("SocialService")
local Workspace = game:GetService("Workspace")

local Logger = require(ReplicatedStorage.Shared.Util.Logger)
local AssetRegistry = require(ReplicatedStorage.Shared.Assets.AssetRegistry)
local ContentPreloader = require(ReplicatedStorage.Shared.ContentPreloading.ContentPreloader)
local PoolModule = require(ReplicatedStorage.Shared.Pooling.PoolModule)
local PlayersModule = require(ReplicatedStorage.Client.Players.PlayersModule)
local CharacterClient = require(ReplicatedStorage.Client.Characters.CharacterClient)
local CommunicationClient = require(ReplicatedStorage.Client.Communication.CommunicationClient)
local TeleportClient = require(ReplicatedStorage.Client.Teleport.TeleportClient)
local ClientConfigCatalog = require(ReplicatedStorage.Client.Config.ClientConfigCatalog)
local ClientConfigManifest = require(ReplicatedStorage.Client.Config.ClientConfigManifest)
local SaveModule = require(ReplicatedStorage.Client.Save.SaveModule)
local VersionClient = require(ReplicatedStorage.Client.Version.VersionClient)
local WalletClient = require(ReplicatedStorage.Client.Wallet.WalletClient)
local StatisticsClient = require(ReplicatedStorage.Client.Statistics.StatisticsClient)
local FriendsSnapshotClientProvider = require(ReplicatedStorage.Client.Friends.FriendsSnapshotClientProvider)
local FriendsClient = require(ReplicatedStorage.Client.Friends.FriendsClient)
local AudioGraphClient = require(ReplicatedStorage.Client.Audio.AudioGraphClient)
local OrdinarySoundClient = require(ReplicatedStorage.Client.Audio.OrdinarySoundClient)
local HybridOneShotClientController = require(ReplicatedStorage.Client.Audio.HybridOneShotClientController)
local MusicClient = require(ReplicatedStorage.Client.Audio.MusicClient)
local AudioSettingsClient = require(ReplicatedStorage.Client.Audio.AudioSettingsClient)
local UiSystem = require(ReplicatedStorage.Client.UI.UiSystem)
local FriendInvitationsUiController = require(ReplicatedStorage.Client.UI.FriendInvitations.FriendInvitationsUiController)
local FriendInvitationsUiInitializationCommand =
	require(ReplicatedStorage.Client.Initialization.Commands.FriendInvitationsUiInitializationCommand)

local Commands = script.Parent.Commands
local AssetRegistryInitializationCommand = require(Commands.AssetRegistryInitializationCommand)
local StartupContentPreloadCommand = require(Commands.StartupContentPreloadCommand)
local PoolingInitializationCommand = require(Commands.PoolingInitializationCommand)
local PlayersInitializationCommand = require(Commands.PlayersInitializationCommand)
local CharacterInitializationCommand = require(Commands.CharacterInitializationCommand)
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
local UiInitializationCommand = require(Commands.UiInitializationCommand)

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
local characterClient = CharacterClient.new(playersModule)
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
local friendsSnapshotProvider = FriendsSnapshotClientProvider.new()
local friendsClient = FriendsClient.new(friendsSnapshotProvider, {
	Communication = communication,
	SocialService = SocialService,
	LocalPlayer = Players.LocalPlayer,
})
local audioGraph = AudioGraphClient.new({
	RuntimeParent = ReplicatedStorage,
	LocalPlayer = Players.LocalPlayer,
	CharacterClient = characterClient,
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
local uiSystem = UiSystem.new({
	PlayersModule = playersModule,
	DerivedActionRoot = ReplicatedStorage,
	DerivedWindowConfigRoot = ReplicatedStorage,
	Pooling = poolModule,
	ContentPreloader = contentPreloader,
	AssetRegistry = assetRegistry,
	AssetBackend = {
		LoadAssetAsync = function(_self, assetId: number)
			return AssetService:LoadAssetAsync(assetId)
		end,
	},
	GuiService = GuiService,
	Logger = Logger.new("UI.Client", "info"),
})
local friendInvitationsUiController = FriendInvitationsUiController.new({
	UI = uiSystem,
	Assets = assetRegistry,
	Friends = friendsClient,
	PlayersModule = playersModule,
	PlayersService = Players,
	StarterGui = StarterGui,
	Workspace = Workspace,
	FrameSignal = RunService.RenderStepped,
	Logger = Logger.new("FriendInvitations.UI", "info"),
})
local sharedRoot = ReplicatedStorage:FindFirstChild("Shared")
local configsRoot = if sharedRoot then sharedRoot:FindFirstChild("Configs") else nil
local audioConfigRoot = if configsRoot then configsRoot:FindFirstChild("Audio") else nil

local services = {
	Assets = assetRegistry,
	ContentPreloader = contentPreloader,
	Pooling = poolModule,
	Players = playersModule,
	Characters = characterClient,
	Communication = communication,
	Teleport = teleportClient,
	Config = configCatalog,
	Save = saveModule,
	Version = versionClient,
	Wallet = walletClient,
	Statistics = statisticsClient,
	Friends = friendsClient,
	AudioGraph = audioGraph,
	OrdinarySound = ordinarySound,
	Music = music,
	AudioSettings = audioSettings,
	UI = uiSystem,
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
		CharacterInitializationCommand.new(characterClient),
		UiInitializationCommand.new(uiSystem),
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
		FriendsSnapshotProvider = friendsSnapshotProvider,
		FriendsClient = friendsClient,
	}),
		FriendInvitationsUiInitializationCommand.new(friendInvitationsUiController),
	},
}
