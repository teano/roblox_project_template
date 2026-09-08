--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local ConfigService = game:GetService("ConfigService")
local HttpService = game:GetService("HttpService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local TeleportService = game:GetService("TeleportService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local CollectionService = game:GetService("CollectionService")
local Teams = game:GetService("Teams")
local Players = game:GetService("Players")

local Logger = require(ReplicatedStorage.Shared.Util.Logger)
local AssetRegistry = require(ReplicatedStorage.Shared.Assets.AssetRegistry)
local PoolModule = require(ReplicatedStorage.Shared.Pooling.PoolModule)

local Modules = script.Parent.Parent.Modules
local PlayersModule = require(Modules.Players.PlayersModule)
local CharacterModule = require(Modules.Characters.CharacterModule)
local CommunicationServer = require(Modules.Communication.CommunicationServer)
local TeleportModule = require(Modules.Teleport.TeleportModule)
local PlayerSlotModule = require(Modules.PlayerSlots.PlayerSlotModule)
local FriendsModule = require(Modules.Friends.FriendsModule)
local PlayerAdmissionCoordinator = require(Modules.PlayerAdmission.PlayerAdmissionCoordinator)
local AdmissionRouting = require(Modules.PlayerAdmission.AdmissionRouting)
local TeleportPolicy = require(Modules.Teleport.TeleportPolicy)
local TeleportValidationConfig = require(Modules.Teleport.TeleportValidationConfig)
local TeleportValidationPad = require(Modules.Teleport.TeleportValidationPad)
local ExperienceConfigCatalog = require(Modules.Config.ExperienceConfigCatalog)
local ServerConfigManifest = require(Modules.Config.ServerConfigManifest)
local SaveModule = require(Modules.Save.SaveModule)
local ShutdownSaveCoordinator = require(Modules.Save.ShutdownSaveCoordinator)
local StorageConfig = require(Modules.Storage.StorageConfig)
local MemoryStorage = require(Modules.Storage.MemoryStorage)
local DataStoreStorage = require(Modules.Storage.DataStoreStorage)
local SessionLockingStorage = require(Modules.Storage.SessionLockingStorage)
local SessionLockModule = require(Modules.Storage.SessionLockModule)
local AutoSaveModule = require(Modules.AutoSave.AutoSaveModule)
local VersionModule = require(Modules.Version.VersionModule)
local MigrationModule = require(Modules.Migration.MigrationModule)
local MigrationManifest = require(Modules.Migration.MigrationManifest)
local WalletModule = require(Modules.Wallet.WalletModule)
local StatisticsModule = require(Modules.Statistics.StatisticsModule)
local WalletStatisticsController = require(Modules.Statistics.WalletStatisticsController)
local StatisticsRequestController = require(Modules.Statistics.StatisticsRequestController)
local StatisticsClientFactController = require(Modules.Statistics.StatisticsClientFactController)
local StatisticsClientFactManifest = require(Modules.Statistics.StatisticsClientFactManifest)
local AudioGraphServer = require(Modules.Audio.AudioGraphServer)
local OrdinarySoundServer = require(Modules.Audio.OrdinarySoundServer)
local HybridOneShotServerController = require(Modules.Audio.HybridOneShotServerController)
local AudioSettingsModule = require(Modules.Audio.AudioSettingsModule)

local Commands = script.Parent.Commands
local AssetRegistryInitializationCommand = require(Commands.AssetRegistryInitializationCommand)
local PoolingInitializationCommand = require(Commands.PoolingInitializationCommand)
local PlayersInitializationCommand = require(Commands.PlayersInitializationCommand)
local CharacterInitializationCommand = require(Commands.CharacterInitializationCommand)
local CommunicationInitializationCommand = require(Commands.CommunicationInitializationCommand)
local TeleportInitializationCommand = require(Commands.TeleportInitializationCommand)
local PlayerSlotInitializationCommand = require(Commands.PlayerSlotInitializationCommand)
local PlayerAdmissionInitializationCommand = require(Commands.PlayerAdmissionInitializationCommand)
local AdmissionRoutingInitializationCommand = require(Commands.AdmissionRoutingInitializationCommand)
local TeleportValidationPadInitializationCommand = require(Commands.TeleportValidationPadInitializationCommand)
local ConfigInitializationCommand = require(Commands.ConfigInitializationCommand)
local SaveInitializationCommand = require(Commands.SaveInitializationCommand)
local MigrationInitializationCommand = require(Commands.MigrationInitializationCommand)
local DomainDataInitializationCommand = require(Commands.DomainDataInitializationCommand)
local StatisticsInitializationCommand = require(Commands.StatisticsInitializationCommand)
local GlobalSaveInitializationCommand = require(Commands.GlobalSaveInitializationCommand)
local PersistenceScheduleInitializationCommand = require(Commands.PersistenceScheduleInitializationCommand)
local AudioStartupInitializationCommand = require(Commands.AudioStartupInitializationCommand)
local AudioGraphInitializationCommand = require(Commands.AudioGraphInitializationCommand)
local OrdinarySoundInitializationCommand = require(Commands.OrdinarySoundInitializationCommand)

local replicatedAssets = ReplicatedStorage:FindFirstChild("Assets")
assert(replicatedAssets ~= nil and replicatedAssets:IsA("Folder"), "ReplicatedStorage.Assets must be a Folder")
local sharedAssets = replicatedAssets:FindFirstChild("Shared")
assert(sharedAssets ~= nil and sharedAssets:IsA("Folder"), "ReplicatedStorage.Assets.Shared must be a Folder")
local serverAssets = ServerStorage:FindFirstChild("Assets")
assert(serverAssets ~= nil and serverAssets:IsA("Folder"), "ServerStorage.Assets must be a Folder")

local initializationLogger = Logger.new("ServerInitialization", "info")
local audioLogger = Logger.new("Audio.Server", "info")

local assetRegistry = AssetRegistry.new({
	{
		Namespace = "Shared",
		Root = sharedAssets,
	},
	{
		Namespace = "Server",
		Root = serverAssets,
	},
}, { AllowAudioDuplicateKeys = true, Logger = audioLogger })
local poolModule = PoolModule.new()
local playersModule = PlayersModule.new()
local communication = CommunicationServer.new({
	PlayersModule = playersModule,
})
local teleportModule = TeleportModule.new({
	TeleportService = TeleportService,
	HttpService = HttpService,
	PlayersModule = playersModule,
	Communication = communication,
	Policy = TeleportPolicy.Template(game.PlaceId, game.GameId),
})
local teleportValidationPad = TeleportValidationPad.new({
	PlayersModule = playersModule,
	Teleport = teleportModule,
	Workspace = Workspace,
	CurrentPlaceId = game.PlaceId,
	CurrentGameId = game.GameId,
	Config = TeleportValidationConfig,
})
local configCatalog = ExperienceConfigCatalog.new({
	ConfigService = ConfigService,
	Communication = communication,
	Definitions = ServerConfigManifest.Definitions,
	ClientBundles = ServerConfigManifest.ClientBundles,
})
local playerSlotModule = PlayerSlotModule.new({
	PlayersModule = playersModule,
	Config = configCatalog,
	CollectionService = CollectionService,
	Workspace = Workspace,
	Teams = Teams,
	MaxPlayers = Players.MaxPlayers,
})
local playerAdmissionCoordinator: any = nil
local admissionRouting = AdmissionRouting.new({
	Store = MemoryStoreService:GetSortedMap("PlayerAdmission_v1_" .. tostring(game.PlaceId)),
	TeleportModule = teleportModule,
	GenerateId = function() return HttpService:GenerateGUID(false) end,
	PlaceId = game.PlaceId,
	JobId = if game.JobId == "" then "studio-" .. HttpService:GenerateGUID(false) else game.JobId,
	PrivateServerId = game.PrivateServerId,
	MatchmakingType = game.MatchmakingType.Name,
})
local friendsModule = FriendsModule.new({
	Config = configCatalog,
	PlayerSlots = playerSlotModule,
	PlayersModule = playersModule,
	Communication = communication,
	GenerateId = function() return HttpService:GenerateGUID(false) end,
	EncodeJson = function(value: any) return HttpService:JSONEncode(value) end,
	JobId = game.JobId,
	Clock = function() return Workspace:GetServerTimeNow() end,
	CanCreateLocalOffer = function(inviter: Player, target: Player)
		local coordinator = playerAdmissionCoordinator
		if coordinator == nil then return false, "TargetIneligible" end
		return coordinator:CanCreateLocalOffer(inviter, target)
	end,
})
local characterModule = CharacterModule.new({
	PlayersModule = playersModule,
	Config = configCatalog,
})
playerAdmissionCoordinator = PlayerAdmissionCoordinator.new({
	PlayersModule = playersModule,
	FriendsModule = friendsModule,
	PlayerSlots = playerSlotModule,
	TeleportModule = teleportModule,
	CharacterModule = characterModule,
	AdmissionRouting = admissionRouting,
	PlaceId = game.PlaceId,
	JobId = game.JobId,
	DecodeJson = function(value: string) return HttpService:JSONDecode(value) end,
})
local autoSaveModule = AutoSaveModule.new()
local baseStorage = if StorageConfig.UseMemoryStorage
	then MemoryStorage.new()
	else DataStoreStorage.new(StorageConfig)
local storage = SessionLockingStorage.new(baseStorage, StorageConfig)
local sessionLockModule = SessionLockModule.new(StorageConfig.LockRefreshIntervalSeconds)
local saveModule = SaveModule.new({
	OnControllerRemoving = function(controller)
		autoSaveModule:UnregisterController(controller)
		sessionLockModule:UnregisterController(controller)
	end,
})
local shutdownSaveCoordinator = ShutdownSaveCoordinator.new({
	BudgetSeconds = StorageConfig.ShutdownBudgetSeconds,
	MaxConcurrency = StorageConfig.ShutdownMaxConcurrency,
})
local versionModule = VersionModule.new()
local migrationModule = MigrationModule.new(MigrationManifest.Controllers, {
	LegacyBaselineVersion = MigrationManifest.LegacyBaselineVersion,
	MaxSerializedBytes = StorageConfig.SoftSerializedBytesLimit,
})
local walletModule = WalletModule.new(communication, configCatalog)
local statisticsModule = StatisticsModule.new({
	Config = configCatalog,
	Teleport = teleportModule,
	AutoSave = autoSaveModule,
	PlaceId = game.PlaceId,
})
local walletStatisticsController = WalletStatisticsController.new({
	Wallet = walletModule,
	Statistics = statisticsModule,
})
local statisticsRequestController = StatisticsRequestController.new({
	Statistics = statisticsModule,
	Communication = communication,
})
local statisticsClientFactController = StatisticsClientFactController.new({
	Statistics = statisticsModule,
	Communication = communication,
	Definitions = StatisticsClientFactManifest,
})
local audioGraph = AudioGraphServer.new(ReplicatedStorage, audioLogger)
local ordinarySound = OrdinarySoundServer.new(poolModule, audioLogger, {
	Workspace = Workspace,
	SpatialFrameDriver = RunService.Heartbeat,
})
local hybridAudio = HybridOneShotServerController.new({
	Communication = communication,
	PlayersModule = playersModule,
	Clock = os.clock,
	Logger = audioLogger,
})
local audioSettings = AudioSettingsModule.new()
local sharedRoot = ReplicatedStorage:FindFirstChild("Shared")
local configsRoot = if sharedRoot then sharedRoot:FindFirstChild("Configs") else nil
local audioConfigRoot = if configsRoot then configsRoot:FindFirstChild("Audio") else nil

local services = {
	Assets = assetRegistry,
	Pooling = poolModule,
	Players = playersModule,
	Characters = characterModule,
	Communication = communication,
	Teleport = teleportModule,
	PlayerSlots = playerSlotModule,
	Friends = friendsModule,
	PlayerAdmission = playerAdmissionCoordinator,
	AdmissionRouting = admissionRouting,
	TeleportValidationPad = teleportValidationPad,
	Config = configCatalog,
	Save = saveModule,
	Storage = storage,
	AutoSave = autoSaveModule,
	SessionLock = sessionLockModule,
	ShutdownSave = shutdownSaveCoordinator,
	Version = versionModule,
	Migration = migrationModule,
	Wallet = walletModule,
	Statistics = statisticsModule,
	AudioGraph = audioGraph,
	OrdinarySound = ordinarySound,
	AudioSettings = audioSettings,
}

local commands = {
	AssetRegistryInitializationCommand.new(assetRegistry),
	AudioStartupInitializationCommand.new(audioConfigRoot, assetRegistry, "Server", audioLogger, sharedAssets),
	PoolingInitializationCommand.new(poolModule),
	PlayersInitializationCommand.new(playersModule),
	CommunicationInitializationCommand.new(communication),
	ConfigInitializationCommand.new(configCatalog),
	CharacterInitializationCommand.new(characterModule),
	AudioGraphInitializationCommand.new(audioGraph),
	OrdinarySoundInitializationCommand.new(ordinarySound, hybridAudio),
	TeleportInitializationCommand.new(teleportModule),
	PlayerSlotInitializationCommand.new(playerSlotModule),
	AdmissionRoutingInitializationCommand.new(admissionRouting, playerSlotModule, function(callback: any) game:BindToClose(callback) end),
	TeleportValidationPadInitializationCommand.new(teleportValidationPad),
	StatisticsInitializationCommand.new({
		Statistics = statisticsModule,
		WalletController = walletStatisticsController,
		RequestController = statisticsRequestController,
		ClientFactController = statisticsClientFactController,
	}),
	SaveInitializationCommand.new(saveModule),
	MigrationInitializationCommand.new(migrationModule),
	DomainDataInitializationCommand.new(versionModule, walletModule, audioSettings),
	GlobalSaveInitializationCommand.new({
		SaveModule = saveModule,
		Storage = storage,
		StorageConfig = StorageConfig,
		Config = configCatalog,
		PlayersModule = playersModule,
		Communication = communication,
		Teleport = teleportModule,
		MigrationModule = migrationModule,
		AutoSaveModule = autoSaveModule,
		SessionLockModule = sessionLockModule,
		ShutdownSaveCoordinator = shutdownSaveCoordinator,
		VersionModule = versionModule,
		WalletModule = walletModule,
		StatisticsModule = statisticsModule,
		AudioSettingsModule = audioSettings,
		FriendsModule = friendsModule,
	}),
	PlayerAdmissionInitializationCommand.new(playerAdmissionCoordinator),
	PersistenceScheduleInitializationCommand.new(autoSaveModule, sessionLockModule, playersModule),
}

return {
	Commands = commands,
	Services = services,
	Logger = initializationLogger,
}
