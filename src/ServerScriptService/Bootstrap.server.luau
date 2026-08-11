--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local InitializationRunner = require(ReplicatedStorage.Shared.Initialization.InitializationRunner)
local manifest = require(script.Parent.Initialization.ServerManifest)

local runner = InitializationRunner.new(manifest.Commands, {
	Logger = manifest.Logger,
	WatchdogSeconds = 30,
})

local result = runner:Initialize({
	Side = "Server",
	Services = manifest.Services,
})
if not result.Ok then
	error(`[ServerBootstrap] command '{result.CommandId}' failed:\n{result.Error}`)
end

if RunService:IsStudio() then
	local AudioManualQaServer = require(script.Parent.Tests.AudioManualQaServer)
	AudioManualQaServer.InstallBridge(manifest.Services, script)
end
