--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CommunicationConfig = require(ReplicatedStorage.Shared.Communication.CommunicationConfig)
local CommunicationProtocol = require(ReplicatedStorage.Shared.Communication.CommunicationProtocol)
local CommunicationSerialize = require(ReplicatedStorage.Shared.Communication.CommunicationSerialize)
local SaveProtocol = require(ReplicatedStorage.Shared.Save.SaveProtocol)
local Logger = require(ReplicatedStorage.Shared.Util.Logger)

local Command = {}
Command.__index = Command

local function isPositiveInteger(value: any): boolean
	return typeof(value) == "number"
		and value == value
		and value ~= math.huge
		and value ~= -math.huge
		and value >= 1
		and value == math.floor(value)
end

local function ensureFolder(parent: Instance, name: string): Folder
	local existing = parent:FindFirstChild(name)
	if existing ~= nil then
		assert(existing:IsA("Folder"), `{parent:GetFullName()}.{name} must be a Folder`)
		return existing
	end

	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = parent
	return folder
end

local function ensureSnapshotRemote(): RemoteFunction
	local root = ensureFolder(ReplicatedStorage, "Remotes")
	local folder = ensureFolder(root, SaveProtocol.RemoteFolderName)
	local existing = folder:FindFirstChild(SaveProtocol.GlobalSnapshotFunctionName)
	if existing ~= nil then
		assert(existing:IsA("RemoteFunction"), "Global snapshot remote must be a RemoteFunction")
		return existing
	end

	local remote = Instance.new("RemoteFunction")
	remote.Name = SaveProtocol.GlobalSnapshotFunctionName
	remote.Parent = folder
	return remote
end

function Command.new(deps: {
	SaveModule: any,
	Storage: any,
	StorageConfig: any,
	Config: any,
	PlayersModule: any,
	Communication: any,
	MigrationModule: any,
	AutoSaveModule: any,
	SessionLockModule: any,
	ShutdownSaveCoordinator: any,
	VersionModule: any,
	WalletModule: any,
})
	return setmetatable({
		Id = "GlobalSave",
		DependsOn = { "DomainData" },
		_deps = deps,
		_logger = Logger.new("GlobalSave", "info"),
	}, Command)
end

function Command:_waitUntilLoaded(controller: any, player: Player, timeout: number): boolean
	local deadline = os.clock() + timeout
	while os.clock() < deadline do
		if controller:IsLoaded(player) then
			return true
		end
		if controller:GetState(player) == "LoadFailed" then
			return false
		end
		task.wait(0.05)
	end
	return controller:IsLoaded(player)
end

function Command:Initialize(context: any)
	local deps = self._deps
	local globalSaveConfig = deps.Config:GetRequired("GlobalSave")
	local controller = deps.SaveModule:BuildSaveController(SaveProtocol.GlobalControllerId)
		:WithStorage(deps.Storage)
		:WithKeyResolver(function(player)
			return `{deps.StorageConfig.KeyPrefix}{player.UserId}`
		end)
		:WithSoftSerializedBytesLimit(deps.StorageConfig.SoftSerializedBytesLimit)
		:WithSaveProvider(deps.VersionModule)
		:WithSaveProvider(deps.WalletModule)
		:Build()

	context.Services.GlobalSaveController = controller
	deps.AutoSaveModule:RegisterController(controller, {
		IntervalSeconds = globalSaveConfig.AutoSaveIntervalSeconds,
	})
	deps.SessionLockModule:RegisterController(controller)

	deps.Communication:RegisterHandler(
		CommunicationProtocol.SystemMessages.ClientReady,
		function(payload)
			if typeof(payload) ~= "table" or not isPositiveInteger(payload.Epoch) then
				return false, nil, "Epoch required"
			end
			return true, {
				Epoch = payload.Epoch,
			}, nil
		end,
		function(player, payload)
			if controller:IsLoaded(player) then
				deps.Communication:SetClientReady(player, payload.Epoch)
			end
		end
	)

	deps.Communication:RegisterHandler(
		CommunicationProtocol.SystemMessages.SaveClientPatch,
		function(payload)
			if typeof(payload) ~= "table"
				or payload.ControllerId ~= SaveProtocol.GlobalControllerId
				or typeof(payload.Providers) ~= "table"
			then
				return false, nil, "Invalid save patch envelope"
			end
			return true, payload, nil
		end,
		function(player, payload, requestId)
			local result = controller:ApplyClientPatch(player, payload)
			deps.Communication:Queue(
				player,
				CommunicationProtocol.SystemMessages.SaveClientPatchResult,
				result,
				requestId,
				{
					Priority = CommunicationProtocol.Priorities.Critical,
				}
			)
		end
	)

	local snapshotRemote = ensureSnapshotRemote()
	snapshotRemote.OnServerInvoke = function(player: Player)
		local allowed, denialCode = deps.Communication:TryBeginSnapshotRequest(player)
		if not allowed then
			return {
				Ok = false,
				Code = denialCode or "RateLimited",
			}
		end

		local callOk, response = xpcall(function()
			if not self:_waitUntilLoaded(controller, player, globalSaveConfig.SnapshotLoadTimeoutSeconds) then
				return {
					Ok = false,
					Code = "NotLoaded",
				}
			end
			local communicationEpoch = deps.Communication:BeginSnapshot(player)
			local snapshot = controller:BuildSnapshot(player)
			if snapshot == nil then
				return {
					Ok = false,
					Code = "SnapshotFailed",
				}
			end

			local successResponse = {
				Ok = true,
				Snapshot = snapshot,
				CommunicationEpoch = communicationEpoch,
			}
			local responseValid, issues, estimatedBytes = CommunicationSerialize.inspect(successResponse, {
				MaxBytes = deps.StorageConfig.SoftSerializedBytesLimit
					+ CommunicationConfig.MaxSnapshotEnvelopeEstimatedBytes,
				MaxNodes = CommunicationConfig.MaxSnapshotInspectionNodes,
			})
			if not responseValid then
				self._logger:Error("snapshot_response_invalid", {
					UserId = player.UserId,
					Error = if issues[1] then issues[1].Reason else "snapshot_too_large",
					EstimatedBytes = estimatedBytes,
				})
				return {
					Ok = false,
					Code = "SnapshotFailed",
				}
			end
			return successResponse
		end, debug.traceback)
		deps.Communication:EndSnapshotRequest(player)

		if not callOk then
			self._logger:Error("snapshot_request_failed", {
				UserId = player.UserId,
				Error = tostring(response),
			})
			return {
				Ok = false,
				Code = "InternalError",
			}
		end
		return response
	end

	deps.PlayersModule:ObservePlayers(function(player)
		task.spawn(function()
			local result = controller:Load(player, function(document)
				return deps.MigrationModule:Migrate(document)
			end)
			if not result.Ok and player.Parent ~= nil then
				self._logger:Error("player_load_failed", {
					UserId = player.UserId,
					Code = result.Code,
					Error = result.Error,
				})
				player:Kick("We couldn't load your data. Please rejoin in a moment.")
			end
		end)
	end, function(player)
		local result = controller:Close(player, true)
		if not result.Ok then
			self._logger:Error("player_close_failed", {
				UserId = player.UserId,
				Code = result.Code,
				Error = result.Error,
			})
		end
	end)

	game:BindToClose(function()
		deps.AutoSaveModule:Stop()
		deps.SessionLockModule:Stop()
		local summary = deps.ShutdownSaveCoordinator:ClosePlayers(controller, deps.PlayersModule:GetPlayers())
		if summary.TimedOut or summary.Failed > 0 then
			self._logger:Error("shutdown_save_incomplete", {
				Succeeded = summary.Succeeded,
				Failed = summary.Failed,
				Unfinished = summary.Unfinished,
			})
		end
	end)
end

return Command
