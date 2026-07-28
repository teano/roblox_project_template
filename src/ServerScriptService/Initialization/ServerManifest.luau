--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Logger = require(ReplicatedStorage.Shared.Util.Logger)

local Modules = script.Parent.Parent.Modules
local PlayersModule = require(Modules.Players.PlayersModule)
local CommunicationServer = require(Modules.Communication.CommunicationServer)
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
local WalletModule = require(Modules.Wallet.WalletModule)

local Commands = script.Parent.Commands
local PlayersInitializationCommand = require(Commands.PlayersInitializationCommand)
local CommunicationInitializationCommand = require(Commands.CommunicationInitializationCommand)
local SaveInitializationCommand = require(Commands.SaveInitializationCommand)
local DomainDataInitializationCommand = require(Commands.DomainDataInitializationCommand)
local GlobalSaveInitializationCommand = require(Commands.GlobalSaveInitializationCommand)
local PersistenceScheduleInitializationCommand = require(Commands.PersistenceScheduleInitializationCommand)

local playersModule = PlayersModule.new()
local communication = CommunicationServer.new({
	PlayersModule = playersModule,
})
local saveModule = SaveModule.new()
local baseStorage = if StorageConfig.UseMemoryStorage
	then MemoryStorage.new()
	else DataStoreStorage.new(StorageConfig)
local storage = SessionLockingStorage.new(baseStorage, StorageConfig)
local autoSaveModule = AutoSaveModule.new()
local sessionLockModule = SessionLockModule.new(StorageConfig.LockRefreshIntervalSeconds)
local shutdownSaveCoordinator = ShutdownSaveCoordinator.new({
	BudgetSeconds = StorageConfig.ShutdownBudgetSeconds,
	MaxConcurrency = StorageConfig.ShutdownMaxConcurrency,
})
local versionModule = VersionModule.new()
local migrationModule = MigrationModule.new()
local walletModule = WalletModule.new(communication)

local services = {
	Players = playersModule,
	Communication = communication,
	Save = saveModule,
	Storage = storage,
	AutoSave = autoSaveModule,
	SessionLock = sessionLockModule,
	ShutdownSave = shutdownSaveCoordinator,
	Version = versionModule,
	Migration = migrationModule,
	Wallet = walletModule,
}

local commands = {
	PlayersInitializationCommand.new(playersModule),
	CommunicationInitializationCommand.new(communication),
	SaveInitializationCommand.new(saveModule),
	DomainDataInitializationCommand.new(versionModule, migrationModule, walletModule),
	GlobalSaveInitializationCommand.new({
		SaveModule = saveModule,
		Storage = storage,
		StorageConfig = StorageConfig,
		PlayersModule = playersModule,
		Communication = communication,
		MigrationModule = migrationModule,
		AutoSaveModule = autoSaveModule,
		SessionLockModule = sessionLockModule,
		ShutdownSaveCoordinator = shutdownSaveCoordinator,
		VersionModule = versionModule,
		WalletModule = walletModule,
	}),
	PersistenceScheduleInitializationCommand.new(autoSaveModule, sessionLockModule, playersModule),
}

return {
	Commands = commands,
	Services = services,
	Logger = Logger.new("ServerInitialization", "info"),
}
