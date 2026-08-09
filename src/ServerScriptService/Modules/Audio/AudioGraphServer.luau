--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AudioProtocol = require(ReplicatedStorage.Shared.Audio.AudioProtocol)
local AudioConfigValidator = require(ReplicatedStorage.Shared.Audio.AudioConfigValidator)

local AudioGraphServer = {}
AudioGraphServer.__index = AudioGraphServer

local FADER_IDS = { "Master", "UI", "SFX", "World", "Music" }

function AudioGraphServer.new(runtimeParent: Instance, logger: any, dependencies: any?)
	return setmetatable({ _runtimeParent = runtimeParent, _logger = logger, _dependencies = dependencies or {}, _result = nil }, AudioGraphServer)
end

function AudioGraphServer:Initialize(startup: any): any
	if self._result ~= nil then
		return self._result
	end
	if not startup.Enabled then
		self._result = table.freeze({ Enabled = false, ReasonCode = "AudioDisabled" })
		return self._result
	end
	if self._runtimeParent:FindFirstChild(AudioProtocol.RuntimeRootName) ~= nil then
		self._logger:Warn("GraphPublishFailed", { ReasonCode = "RuntimeRootExists" })
		self._result = table.freeze({ Enabled = false, ReasonCode = "RuntimeRootExists" })
		return self._result
	end
	local create = self._dependencies.InstanceFactory or Instance.new
	local root: Folder? = nil
	local ok, resultOrError = xpcall(function()
		root = create("Folder") :: Folder
		root.Name = AudioProtocol.RuntimeRootName
		local published = create("Folder")
		published.Name = AudioProtocol.PublishedGraphName
		published.Parent = root
		local fadersFolder = create("Folder")
		fadersFolder.Name = "Faders"
		fadersFolder.Parent = published
		local wiresFolder = create("Folder")
		wiresFolder.Name = "Wires"
		wiresFolder.Parent = published
		local playback = create("Folder")
		playback.Name = AudioProtocol.ServerPlaybackName
		playback.Parent = root
		local faders = {}
		for _, id in FADER_IDS do
			local fader = create("AudioFader")
			fader.Name = id
			local profile = startup.Config.FaderProfiles[id]
			fader.Volume = AudioConfigValidator.levelToGain(profile, profile.DefaultLevel01)
			fader.Parent = fadersFolder
			faders[id] = fader
		end
		for _, id in { "UI", "SFX", "World", "Music" } do
			local wire = create("Wire")
			wire.Name = id .. "ToMaster"
			wire.SourceInstance = faders[id]
			wire.TargetInstance = faders.Master
			wire.Parent = wiresFolder
		end
		root:SetAttribute(AudioProtocol.AttributeNames.CompositionId, AudioProtocol.CompositionId)
		root:SetAttribute(AudioProtocol.AttributeNames.SchemaVersion, AudioProtocol.SchemaVersion)
		root:SetAttribute(AudioProtocol.AttributeNames.Generation, AudioProtocol.Generation)
		root:SetAttribute(AudioProtocol.AttributeNames.Ready, true)
		root.Parent = self._runtimeParent
		return table.freeze({
			Enabled = true,
			Generation = AudioProtocol.Generation,
			Root = root,
			Faders = table.freeze(faders),
			ServerPlayback = playback,
			Config = startup.Config,
		})
	end, debug.traceback)
	if not ok then
		if root ~= nil then root:Destroy() end
		self._logger:Warn("GraphPublishFailed", { ReasonCode = "GraphConstructionFailed" })
		self._result = table.freeze({ Enabled = false, ReasonCode = "GraphConstructionFailed" })
		return self._result
	end
	self._result = resultOrError
	return self._result
end

return AudioGraphServer
