--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local InitializationRunner = require(ReplicatedStorage.Shared.Initialization.InitializationRunner)
local manifest = require(ReplicatedStorage.Client.Initialization.ClientManifest)

local runner = InitializationRunner.new(manifest.Commands, {
	Logger = manifest.Logger,
	WatchdogSeconds = 30,
})

local result = runner:Initialize({
	Side = "Client",
	Services = manifest.Services,
})
if not result.Ok then
	ReplicatedStorage:SetAttribute("ClientInitializationFailed", true)
	error(`[ClientBootstrap] command '{result.CommandId}' failed:\n{result.Error}`)
end

ReplicatedStorage:SetAttribute("ClientInitialized", true)

if RunService:IsStudio() then
	local AudioManualQaClient = require(ReplicatedStorage.Shared.Tests.AudioManualQaClient)
	AudioManualQaClient.InstallBridge(manifest.Services, script)
end
