--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CommunicationProtocol = require(ReplicatedStorage.Shared.Communication.CommunicationProtocol)
local SaveProtocol = require(ReplicatedStorage.Shared.Save.SaveProtocol)
local GameDataClient = require(ReplicatedStorage.Client.GameData.GameDataClient)
local Logger = require(ReplicatedStorage.Shared.Util.Logger)

local Command = {}
Command.__index = Command

function Command.new(deps: {
	SaveModule: any,
	Communication: any,
	Config: any,
	Version: any,
	Wallet: any,
})
	return setmetatable({
		Id = "GlobalSave",
		DependsOn = { "DomainData" },
		_deps = deps,
		_logger = Logger.new("GlobalSave.Client", "info"),
		_controller = nil,
		_snapshotFunction = nil,
		_config = nil,
	}, Command)
end

function Command:_requestSnapshot()
	local response
	local config = assert(self._config, "GlobalSave client config is not initialized")
	for attempt = 1, config.SnapshotRequestAttempts do
		local ok, result = pcall(function()
			return self._snapshotFunction:InvokeServer()
		end)
		if ok
			and typeof(result) == "table"
			and result.Ok == true
			and result.Snapshot ~= nil
			and typeof(result.CommunicationEpoch) == "number"
		then
			response = result
			break
		end
		self._logger:Warn("snapshot_attempt_failed", {
			Attempt = attempt,
			Code = if ok and typeof(result) == "table" then result.Code else tostring(result),
		})
		task.wait(config.SnapshotRetryDelaySeconds)
	end
	assert(response ~= nil, "Global save snapshot could not be loaded")

	self._controller:ApplySnapshot(response.Snapshot)
	self._deps.Communication:ResumeAfterSnapshot(response.CommunicationEpoch)
	self._deps.Communication:Queue(CommunicationProtocol.SystemMessages.ClientReady, {
		Revision = self._controller:GetRevision(),
	}, nil, {
		Priority = CommunicationProtocol.Priorities.Critical,
	})
end

function Command:Initialize(context: any)
	local deps = self._deps
	self._config = deps.Config:GetRequired("GlobalSave")
	local controller = deps.SaveModule:BuildSaveController(SaveProtocol.GlobalControllerId)
		:WithSaveProvider(deps.Version)
		:WithSaveProvider(deps.Wallet)
		:Build()
	self._controller = controller
	context.Services.GlobalSaveController = controller

	local gameData = GameDataClient.new(controller, {
		deps.Version,
		deps.Wallet,
	})
	GameDataClient.set(gameData)
	context.Services.GameData = gameData

	local root = ReplicatedStorage:WaitForChild("Remotes")
	assert(root:IsA("Folder"), "ReplicatedStorage.Remotes must be a Folder")
	local folder = root:WaitForChild(SaveProtocol.RemoteFolderName)
	assert(folder:IsA("Folder"), "Save remote container must be a Folder")
	local snapshotFunction = folder:WaitForChild(SaveProtocol.GlobalSnapshotFunctionName)
	assert(snapshotFunction:IsA("RemoteFunction"), "Global snapshot remote must be a RemoteFunction")
	self._snapshotFunction = snapshotFunction
	deps.Communication:SetResyncHandler(function()
		self:_requestSnapshot()
	end)
	self:_requestSnapshot()
end

return Command
