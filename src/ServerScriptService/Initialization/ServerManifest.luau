--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local ConfigService = game:GetService("ConfigService")
local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")
local Workspace = game:GetService("Workspace")

local Logger = require(ReplicatedStorage.Shared.Util.Logger)
local AssetRegistry = require(ReplicatedStorage.Shared.Assets.AssetRegistry)
local PoolModule = require(ReplicatedStorage.Shared.Pooling.PoolModule)

local Modules = script.Parent.Parent.Modules
local PlayersModule = require(Modules.Players.PlayersModule)
local CommunicationServer = require(Modules.Communication.CommunicationServer)
local TeleportModule = require(Modules.Teleport.TeleportModule)
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

local Commands = script.Parent.Commands
local AssetRegistryInitializationCommand = require(Commands.AssetRegistryInitializationCommand)
local PoolingInitializationCommand = require(Commands.PoolingInitializationCommand)
local PlayersInitializationCommand = require(Commands.PlayersInitializationCommand)
local CommunicationInitializationCommand = require(Commands.CommunicationInitializationCommand)
local TeleportInitializationCommand = require(Commands.TeleportInitializationCommand)
local TeleportValidationPadInitializationCommand = require(Commands.TeleportValidationPadInitializationCommand)
local ConfigInitializationCommand = require(Commands.ConfigInitializationCommand)
local SaveInitializationCommand = require(Commands.SaveInitializationCommand)
local MigrationInitializationCommand = require(Commands.MigrationInitializationCommand)
local DomainDataInitializationCommand = require(Commands.DomainDataInitializationCommand)
local StatisticsInitializationCommand = require(Commands.StatisticsInitializationCommand)
local GlobalSaveInitializationCommand = require(Commands.GlobalSaveInitializationCommand)
local PersistenceScheduleInitializationCommand = require(Commands.PersistenceScheduleInitializationCommand)

local replicatedAssets = ReplicatedStorage:FindFirstChild("Assets")
assert(replicatedAssets ~= nil and replicatedAssets:IsA("Folder"), "ReplicatedStorage.Assets must be a Folder")
local sharedAssets = replicatedAssets:FindFirstChild("Shared")
assert(sharedAssets ~= nil and sharedAssets:IsA("Folder"), "ReplicatedStorage.Assets.Shared must be a Folder")
local serverAssets = ServerStorage:FindFirstChild("Assets")
assert(serverAssets ~= nil and serverAssets:IsA("Folder"), "ServerStorage.Assets must be a Folder")

local assetRegistry = AssetRegistry.new({
	{
		Namespace = "Shared",
		Root = sharedAssets,
	},
	{
		Namespace = "Server",
		Root = serverAssets,
	},
})
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
local autoSaveModule = AutoSaveModule.new()
local saveModule = SaveModule.new({
	OnControllerRemoving = function(controller)
		autoSaveModule:UnregisterController(controller)
	end,
})
local baseStorage = if StorageConfig.UseMemoryStorage
	then MemoryStorage.new()
	else DataStoreStorage.new(StorageConfig)
local storage = SessionLockingStorage.new(baseStorage, StorageConfig)
local sessionLockModule = SessionLockModule.new(StorageConfig.LockRefreshIntervalSeconds)
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

local services = {
	Assets = assetRegistry,
	Pooling = poolModule,
	Players = playersModule,
	Communication = communication,
	Teleport = teleportModule,
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
}

local commands = {
	AssetRegistryInitializationCommand.new(assetRegistry),
	PoolingInitializationCommand.new(poolModule),
	PlayersInitializationCommand.new(playersModule),
	CommunicationInitializationCommand.new(communication),
	TeleportInitializationCommand.new(teleportModule),
	TeleportValidationPadInitializationCommand.new(teleportValidationPad),
	ConfigInitializationCommand.new(configCatalog),
	StatisticsInitializationCommand.new({
		Statistics = statisticsModule,
		WalletController = walletStatisticsController,
		RequestController = statisticsRequestController,
		ClientFactController = statisticsClientFactController,
	}),
	SaveInitializationCommand.new(saveModule),
	MigrationInitializationCommand.new(migrationModule),
	DomainDataInitializationCommand.new(versionModule, walletModule),
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
	}),
	PersistenceScheduleInitializationCommand.new(autoSaveModule, sessionLockModule, playersModule),
}

return {
	Commands = commands,
	Services = services,
	Logger = Logger.new("ServerInitialization", "info"),
}
