--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TestHarness = require(script.Parent.TestHarness)
local Validator = require(ReplicatedStorage.Shared.Audio.AudioConfigValidator)
local Catalog = require(ReplicatedStorage.Shared.Audio.AudioCatalog)
local AssetRegistry = require(ReplicatedStorage.Shared.Assets.AssetRegistry)
local RuntimeConfig = require(ReplicatedStorage.Shared.Configs.Audio.AudioRuntimeConfig)
local RoutingConfig = require(ReplicatedStorage.Shared.Configs.Audio.RoutingConfig)
local SpatialProfiles = require(ReplicatedStorage.Shared.Configs.Audio.SpatialProfiles)
local SoundCatalog = require(ReplicatedStorage.Shared.Configs.Audio.SoundCatalog)
local AudioStartupCommand = require(ReplicatedStorage.Shared.Audio.AudioStartupCommand)
local AudioSafetyLimits = require(ReplicatedStorage.Shared.Audio.AudioSafetyLimits)
local AudioHybridCodec = require(ReplicatedStorage.Shared.Audio.AudioHybridCodec)
local CommunicationSerialize = require(ReplicatedStorage.Shared.Communication.CommunicationSerialize)
local OrdinaryPlaybackCore = require(ReplicatedStorage.Shared.Audio.OrdinaryPlaybackCore)
local PoolModule = require(ReplicatedStorage.Shared.Pooling.PoolModule)
local AudioGraphClient = require(ReplicatedStorage.Client.Audio.AudioGraphClient)
local MusicClient = require(ReplicatedStorage.Client.Audio.MusicClient)
local AudioGraphServer = require(game.ServerScriptService.Modules.Audio.AudioGraphServer)
local HybridServer = require(game.ServerScriptService.Modules.Audio.HybridOneShotServerController)
local CommunicationServer = require(game.ServerScriptService.Modules.Communication.CommunicationServer)

local Runner = {}
local function logger(events: { any }?) return { Warn = function(_self, event, data) if events then table.insert(events, { Event = event, Data = data }) end end } end
local function validated(side: string, runtime: any?, spatial: any?): any
	local result = Validator.validate(runtime or RuntimeConfig, RoutingConfig, spatial or SpatialProfiles, side, logger())
	assert(result.Enabled, "audio config must validate")
	return result.Config
end
local function emptyRegistry(): any
	return {
		GetByKey = function() return nil end,
		Get = function() return nil end,
		GetPath = function() return nil end,
		FindAll = function() return {} end,
	}
end

local function deepClone(value: any): any
	if typeof(value) ~= "table" then return value end
	local result = {}
	for key, child in value do result[deepClone(key)] = deepClone(child) end
	return result
end

function Runner.runAll()
	local tests = {}
	local function test(name, callback) table.insert(tests, { Name = name, Callback = callback }) end
	test("AudioConfig/ShippedExactConfigAndMapping", function()
		local config = validated("Client")
		assert(config.PlayerTypes.UI.LoadTimeoutSeconds == 2 and config.PlayerTypes.Music.LoadTimeoutSeconds == 15)
		assert(table.isfrozen(config) and Validator.levelToGain(config.FaderProfiles.Master, 0) == 0)
		local runtime = table.clone(RuntimeConfig); runtime.PlayerTypes = table.clone(RuntimeConfig.PlayerTypes)
		runtime.PlayerTypes.SFX = table.clone(RuntimeConfig.PlayerTypes.SFX)
		runtime.PlayerTypes.SFX.SourceVolumeMin = 1; runtime.PlayerTypes.SFX.SourceVolumeMax = 2
		local catalog = Catalog.new({ table.clone(SoundCatalog[2]) }, validated("Client", runtime), emptyRegistry(), logger())
		assert(catalog:GetSnapshot().Variants[1].SourceVolume == 1.8)
	end)
	test("AudioConfig/FatalSchemaAndAggregateCeilings", function()
		local missing = table.clone(RuntimeConfig); missing.PlayerTypes = table.clone(RuntimeConfig.PlayerTypes); missing.PlayerTypes.UI = nil
		assert(not Validator.validate(missing, RoutingConfig, SpatialProfiles, "Client", logger()).Enabled)
		local oversized = table.clone(RuntimeConfig); oversized.PlayerTypes = table.clone(RuntimeConfig.PlayerTypes)
		oversized.PlayerTypes.SFX = table.clone(RuntimeConfig.PlayerTypes.SFX); oversized.PlayerTypes.SFX.ClientMaxActive = 10_000
		assert(not Validator.validate(oversized, RoutingConfig, SpatialProfiles, "Client", logger()).Enabled)
	end)
	test("AudioConfig/SpatialProfileIsolationAndRegistryCeiling", function()
		local events = {}
		local sparse = table.clone(SpatialProfiles)
		sparse.Profiles = {
			BrokenDefault = { AcousticSimulationEnabled = true, DistanceCurve = {}, AngleCurve = nil },
			WorldGood = table.clone(SpatialProfiles.Profiles.WorldDefault),
		}
		sparse.DefaultWorldProfileId = "BrokenDefault"
		for index = 1, 400 do sparse.Profiles.BrokenDefault.DistanceCurve[index] = { Distance = index, Gain01 = 1 } end
		sparse.Profiles.BrokenDefault.DistanceCurve[1000] = { Distance = 1000, Gain01 = 1 }
		local isolated = Validator.validate(RuntimeConfig, RoutingConfig, sparse, "Client", logger(events))
		assert(isolated.Enabled and isolated.Config.SpatialProfilesById.BrokenDefault == nil)
		assert(isolated.Config.DefaultWorldProfileId == nil, "unresolved default must normalize to nil")
		local explicitWorld = table.clone(SoundCatalog[2]); explicitWorld.CueId = "World.Explicit"; explicitWorld.PlayerType = "World"; explicitWorld.SpatialProfile = "WorldGood"; explicitWorld.AssetId = "1"
		local implicitWorld = table.clone(explicitWorld); implicitWorld.CueId = "World.Implicit"; implicitWorld.SpatialProfile = nil; implicitWorld.AssetId = "2"
		local unrelated = table.clone(SoundCatalog[2]); unrelated.CueId = "SFX.Unrelated"; unrelated.AssetId = "3"
		local catalog = Catalog.new({ explicitWorld, implicitWorld, unrelated }, isolated.Config, emptyRegistry(), logger(events))
		assert(#catalog:GetSnapshot().Variants == 2)
		assert(catalog:GetNamedVariant("World.Explicit", explicitWorld.VariantId) ~= nil)
		assert(catalog:GetNamedVariant("SFX.Unrelated", unrelated.VariantId) ~= nil)
		local sawProfileWarning = false
		for _, event in events do if event.Event == "InvalidSpatialProfile" then sawProfileWarning = true end end
		assert(sawProfileWarning)
		local many = table.clone(SpatialProfiles); many.Profiles = {}
		for index = 1, 65 do many.Profiles["P" .. index] = { AcousticSimulationEnabled = true } end
		many.DefaultWorldProfileId = "P1"
		assert(not Validator.validate(RuntimeConfig, RoutingConfig, many, "Client", logger()).Enabled)
	end)
	test("AudioConfig/MissingAndInvalidDefaultSpatialProfileStayFailSoft", function()
		for _, authoredDefault in { false, "bad/profile" } do
			local events = {}
			local spatial = table.clone(SpatialProfiles)
			spatial.Profiles = { WorldGood = table.clone(SpatialProfiles.Profiles.WorldDefault) }
			spatial.DefaultWorldProfileId = if authoredDefault == false then nil else authoredDefault
			local result = Validator.validate(RuntimeConfig, RoutingConfig, spatial, "Client", logger(events))
			assert(result.Enabled and result.Config.DefaultWorldProfileId == nil)
			assert(result.Config.SpatialProfilesById.WorldGood ~= nil)
			local explicitWorld = table.clone(SoundCatalog[2]); explicitWorld.CueId = "World.Explicit"; explicitWorld.PlayerType = "World"; explicitWorld.SpatialProfile = "WorldGood"; explicitWorld.AssetId = "1"
			local implicitWorld = table.clone(explicitWorld); implicitWorld.CueId = "World.Implicit"; implicitWorld.SpatialProfile = nil; implicitWorld.AssetId = "2"
			local unrelated = table.clone(SoundCatalog[2]); unrelated.CueId = "SFX.Unrelated"; unrelated.AssetId = "3"
			local catalog = Catalog.new({ explicitWorld, implicitWorld, unrelated }, result.Config, emptyRegistry(), logger(events))
			assert(catalog:GetNamedVariant("World.Explicit", explicitWorld.VariantId) ~= nil)
			assert(catalog:GetNamedVariant("World.Implicit", implicitWorld.VariantId) == nil)
			assert(catalog:GetNamedVariant("SFX.Unrelated", unrelated.VariantId) ~= nil)
			assert(events[1].Event == "InvalidSpatialProfile" and events[1].Data.ReasonCode == "InvalidDefaultWorldProfile")
		end
	end)
	test("AudioCatalog/UnreadableCatalogIsFatal", function()
		assert(not pcall(function() Catalog.new("bad", validated("Client"), emptyRegistry(), logger()) end))
	end)
	test("AudioCatalog/StablePairAndExactSoundRef", function()
		local catalog = Catalog.new(SoundCatalog, validated("Client"), emptyRegistry(), logger(), function() return 0 end)
		local variant = catalog:GetNamedVariant("Template.SFX.Pulse", "Default")
		assert(variant and variant.AssetId == "9120386436" and variant.SourceVolume == 0.8)
		assert(catalog:Resolve({ AssetId = "9120386436" }) == variant)
		assert(catalog:Resolve({}) == nil)
		assert(catalog:Resolve({ CueId = "Template.SFX.Pulse", AssetId = "9120386436" }) == nil)
		assert(table.isfrozen(catalog:GetSnapshot()) and table.isfrozen(variant))
	end)
	test("AudioCatalog/IdentifierAndFiniteNumericGrammar", function()
		local base = table.clone(SoundCatalog[2])
		local leading = table.clone(base); leading.AssetId = "0001"
		local long = table.clone(base); long.VariantId = "Long"; long.AssetId = string.rep("1", 33)
		local invalidKey = table.clone(base); invalidKey.VariantId = "Key"; invalidKey.AssetId = "1"; invalidKey.AssetKey = "bad/key"
		local infinite = table.clone(base); infinite.VariantId = "Infinite"; infinite.AssetId = "2"; infinite.Volume01 = math.huge
		local catalog = Catalog.new({ leading, long, invalidKey, infinite }, validated("Client"), emptyRegistry(), logger())
		assert(#catalog:GetSnapshot().Variants == 0)
	end)
	test("AudioCatalog/PresentOptionalFieldsRejectAndWeightFallsBack", function()
		local function row(cueId: string, assetId: string): any
			local result = table.clone(SoundCatalog[2]); result.CueId = cueId; result.AssetId = assetId
			return result
		end
		local speed = row("Bad.Speed", "1"); speed.PlaybackSpeed = math.huge
		local spatial = row("Bad.Spatial", "2"); spatial.PlayerType = "World"; spatial.SpatialProfile = "bad/profile"
		local looping = row("Bad.Looping", "3"); looping.Looping = "false"
		local preload = row("Bad.Preload", "4"); preload.Preload = 1
		local hybrid = row("Bad.Hybrid", "5"); hybrid.AllowClientHybrid = "true"
		local weight = row("Good.Weight", "6"); weight.Weight = -1
		local absent = row("Good.Absent", "7"); absent.PlaybackSpeed = nil; absent.Looping = nil; absent.Preload = nil
		local events = {}
		local catalog = Catalog.new({ speed, spatial, looping, preload, hybrid, weight, absent }, validated("Client"), emptyRegistry(), logger(events))
		assert(#catalog:GetSnapshot().Variants == 2)
		assert(catalog:GetNamedVariant("Good.Weight", weight.VariantId).Weight == 1)
		assert(catalog:GetNamedVariant("Good.Absent", absent.VariantId).PlaybackSpeed == 1)
		local weightWarning = false
		for _, event in events do
			if event.Event == "CatalogRowDefaulted" and event.Data.Field == "Weight" then weightWarning = true end
		end
		assert(weightWarning, "invalid Weight fallback must emit its stable warning")
	end)
	test("AudioCatalog/InvalidRowIsolation", function()
		local function row(cue: string, assetId: string): any
			local value = table.clone(SoundCatalog[2])
			value.CueId = cue; value.VariantId = cue; value.AssetId = assetId
			return value
		end
		local rows = {
			[1] = SoundCatalog[2],
			[5] = row("Sparse", "9"),
			[0] = row("Zero", "10"),
			[-1] = row("Negative", "11"),
			[0.5] = row("Fractional", "12"),
			[math.huge] = row("PositiveInfinity", "13"),
			[-math.huge] = row("NegativeInfinity", "14"),
		}
		assert(not pcall(function()
			local impossible = {}
			impossible[0 / 0] = row("NaN", "15")
		end), "Luau itself must reject a NaN table key before the catalog boundary")
		local events = {}
		local catalog = Catalog.new(rows, validated("Client"), emptyRegistry(), logger(events), function() return 0 end)
		assert(#catalog:GetSnapshot().Variants == 2 and catalog:GetNamedVariant("Sparse", "Sparse") ~= nil,
			"sparse finite positive-integer source keys remain valid")
		local invalidRows = 0
		for _, event in events do
			if event.Event == "CatalogRowSkipped" and event.Data.ReasonCode == "InvalidRow" then
				assert(typeof(event.Data.RowIndex) == "string")
				invalidRows += 1
			end
		end
		assert(invalidRows == 5,
			"zero, negative, fractional, and both infinite keys need one stable InvalidRow diagnostic each")
	end)
	test("AudioCatalog/PhysicalAssetIdBuildsRecursiveFolders", function(scope)
		local sound = scope:Track(Instance.new("Sound")); sound.SoundId = "rbxassetid://9120386436"
		local registry = {
			GetByKey = function() return nil end, Get = function() return nil end,
			GetPath = function(_self, instance) return if instance == sound then "Shared/Sounds/Nested/Tone" else nil end,
			FindAll = function() return { sound } end,
		}
		local catalog = Catalog.new({ SoundCatalog[2] }, validated("Client"), registry, logger(), function() return 0 end)
		local variant = catalog:GetNamedVariant("Template.SFX.Pulse", "Default")
		assert(variant.ResourcePath == "Shared/Sounds/Nested/Tone")
		assert(catalog:Resolve({ FolderPath = "Nested" }) == variant)
		assert(catalog:Resolve({ FolderPath = "Shared/Sounds/Nested" }) == variant)
		assert(catalog:Resolve({ FolderPath = "ReplicatedStorage/Assets/Shared/Sounds/Nested" }) == variant)
		assert(catalog:Resolve({ FolderPath = "Assets/Shared/Sounds/Assets/Shared/Sounds/Nested" }) == nil)
	end)
	test("AudioCatalog/PhysicalMultiIdentityConflictExcluded", function(scope)
		local sound = scope:Track(Instance.new("Sound")); sound.SoundId = "rbxassetid://1"
		local rows = {
			{ CueId = "One", VariantId = "V", PlayerType = "SFX", AssetId = "1" },
			{ CueId = "Two", VariantId = "V", PlayerType = "SFX", ResourcePath = "Shared/Sounds/Nested/Tone" },
		}
		local events = {}
		local registry = {
			GetByKey = function() return nil end, Get = function() return sound end,
			GetPath = function() return "Shared/Sounds/Nested/Tone" end,
			FindAll = function() return { sound } end,
		}
		local catalog = Catalog.new(rows, validated("Client"), registry, logger(events), function() return 0 end)
		assert(catalog:Resolve({ FolderPath = "Nested" }) == nil)
		local sawConflict = false
		for _, event in events do if event.Event == "PhysicalIdentityConflict" then sawConflict = true end end
		assert(sawConflict)
	end)
	test("AudioCatalog/WeightedAntiRepeatUsesRemainingWeights", function()
		local first = table.clone(SoundCatalog[2]); first.CueId = "Weighted"; first.VariantId = "A"; first.AssetId = "1"; first.Weight = 100
		local second = table.clone(first); second.VariantId = "B"; second.AssetId = "2"; second.Weight = 1
		local catalog = Catalog.new({ first, second }, validated("Client"), emptyRegistry(), logger(), function() return 0 end)
		local a = catalog:Resolve({ CueId = "Weighted" })
		local b = catalog:Resolve({ CueId = "Weighted" })
		local c = catalog:Resolve({ CueId = "Weighted" })
		assert(a.VariantId == "A" and b.VariantId == "B" and c.VariantId == "A")
	end)
	test("AudioConfig/StartupMissingModuleFailsSoftAndMemoizes", function(scope)
		local root = scope:Track(Instance.new("Folder"))
		local sharedAssets = scope:Track(Instance.new("Folder"))
		local sounds = Instance.new("Folder"); sounds.Name = "Sounds"; sounds.Parent = sharedAssets
		local events = {}
		local command = AudioStartupCommand.new(root, emptyRegistry(), "Client", logger(events), sharedAssets)
		local context = { Services = {} }
		command:Initialize(context)
		local first = context.Services.AudioStartup
		assert(not first.Enabled and first.ReasonCode == "MissingModule:AudioRuntimeConfig")
		local impostor = Instance.new("Folder"); impostor.Name = "AudioRuntimeConfig"; impostor.Parent = root
		command:Initialize(context)
		assert(context.Services.AudioStartup == first and #events == 1)
	end)
	test("AudioConfig/PhysicalSoundsRootFailsClosedBeforeCatalogQuery", function(scope)
		for _, wrongClass in { false, true } do
			local sharedAssets = scope:Track(Instance.new("Folder"))
			if wrongClass then
				local impostor = Instance.new("Part"); impostor.Name = "Sounds"; impostor.Parent = sharedAssets
			end
			local queries = 0
			local registry = emptyRegistry()
			registry.FindAll = function() queries += 1; return {} end
			local command = AudioStartupCommand.new(nil, registry, "Client", logger(), sharedAssets)
			local context = { Services = {} }
			command:Initialize(context)
			assert(not context.Services.AudioStartup.Enabled and queries == 0)
			assert(context.Services.AudioStartup.ReasonCode == if wrongClass then "InvalidPhysicalSoundsRoot" else "MissingPhysicalSoundsRoot")
		end
	end)
	test("AudioCatalog/PhysicalQueryFailureDisablesInsteadOfPublishingEmpty", function()
		local sharedAssets = ReplicatedStorage.Assets.Shared
		local registry = emptyRegistry()
		local queries = 0
		registry.FindAll = function() queries += 1; error("injected AssetRegistry query failure") end
		local command = AudioStartupCommand.new(ReplicatedStorage.Shared.Configs.Audio, registry, "Client", logger(), sharedAssets)
		local context = { Services = {} }
		command:Initialize(context)
		assert(queries == 1 and not context.Services.AudioStartup.Enabled)
		assert(context.Services.AudioStartup.ReasonCode == "CatalogBuildFailed")
	end)
	test("AssetRegistry/AudioFirstWinsOnly", function(scope)
		local root = scope:Track(Instance.new("Folder")); local sounds = Instance.new("Folder"); sounds.Name = "Sounds"; sounds.Parent = root
		for _, name in { "B", "A" } do local sound = Instance.new("Sound"); sound.Name = name; sound:SetAttribute("AssetKey", "audio.same"); sound.Parent = sounds end
		local reg = AssetRegistry.new({ { Namespace = "Shared", Root = root } }, { AllowAudioDuplicateKeys = true, Logger = logger() }); reg:Initialize()
		assert(reg:GetByKey("audio.same").Name == "A")
	end)
	test("AssetRegistry/NonAudioDuplicateStillFatal", function(scope)
		local root = scope:Track(Instance.new("Folder")); for _, name in { "A", "B" } do local folder = Instance.new("Folder"); folder.Name=name; folder:SetAttribute("AssetKey", "same"); folder.Parent=root end
		local ok = pcall(function() AssetRegistry.new({ { Namespace="Shared", Root=root } }, { AllowAudioDuplicateKeys=true, Logger=logger() }):Initialize() end)
		assert(not ok)
	end)

	-- The immutable specification maps every acceptance criterion to one of
	-- these literal named fixtures. Keep these cases granular: the coverage
	-- manifest validates the names mechanically instead of pointing at a broad
	-- aggregate case.
	test("AudioCatalog/RawAssetExactVariant", function()
		local catalog = Catalog.new(SoundCatalog, validated("Client"), emptyRegistry(), logger(), function() return 0 end)
		local expected = catalog:GetNamedVariant("Template.SFX.Pulse", "Default")
		assert(expected ~= nil and catalog:Resolve({ AssetId = "rbxassetid://9120386436" }) == expected)
	end)
	test("AudioCatalog/RequiredStableCueVariantPair", function()
		local valid = table.clone(SoundCatalog[2])
		local missingCue = table.clone(valid); missingCue.CueId = ""; missingCue.AssetId = "1"
		local missingVariant = table.clone(valid); missingVariant.VariantId = ""; missingVariant.AssetId = "2"
		local duplicate = table.clone(valid); duplicate.AssetId = "3"
		local events = {}
		local catalog = Catalog.new({ valid, missingCue, missingVariant, duplicate }, validated("Client"), emptyRegistry(), logger(events))
		assert(#catalog:GetSnapshot().Variants == 1)
		local rejected = 0
		for _, event in events do
			if event.Event == "CatalogRowSkipped" and event.Data.ReasonCode == "InvalidCueVariant" then rejected += 1 end
		end
		assert(rejected == 3)
	end)
	test("AudioConfig/RoutingCycleOrMissingTargetDisablesSide", function()
		local routing = table.clone(RoutingConfig); routing.Faders = table.clone(RoutingConfig.Faders)
		routing.Faders.SFX = { ParentFaderId = "UI" }
		local result = Validator.validate(RuntimeConfig, routing, SpatialProfiles, "Client", logger())
		assert(not result.Enabled and result.ReasonCode == "InvalidRouteParent:SFX")
	end)
	test("AudioConfig/MissingTypesAndMusicBudgets", function(scope)
		local function assertDisabled(case: any)
			local runtime = deepClone(RuntimeConfig)
			local routing = deepClone(RoutingConfig)
			case.Mutate(runtime, routing)
			local events = {}
			local result = Validator.validate(runtime, routing, SpatialProfiles, case.Side or "Client", logger(events))
			assert(not result.Enabled and result.Config == nil and result.ReasonCode == case.Reason)
			assert(table.isfrozen(result) and #events == 1 and events[1].Event == "InvalidConfig"
				and events[1].Data.ReasonCode == case.Reason, case.Name)

			local runtimeParent = scope:Track(Instance.new("Folder"))
			local graph = AudioGraphServer.new(runtimeParent, logger(events))
			local disabledGraph = graph:Initialize(result)
			assert(not disabledGraph.Enabled and #runtimeParent:GetChildren() == 0,
				`{case.Name}: disabled startup must publish no graph instances`)
			local poolCreates = 0
			local core = OrdinaryPlaybackCore.new("Server", {
				CreatePoolablePool = function() poolCreates += 1; error("disabled config constructed a pool") end,
				RemovePool = function() return true end,
			}, logger(events))
			core:Initialize(result, disabledGraph)
			assert(poolCreates == 0 and not core._enabled, `{case.Name}: disabled startup must construct zero pools`)
		end

		local cases = {}
		for _, playerType in { "UI", "SFX", "World", "Music" } do
			table.insert(cases, {
				Name = `Missing{playerType}`, Reason = "InvalidRuntimeConfig",
				Mutate = function(runtime) runtime.PlayerTypes[playerType] = nil end,
			})
		end
		for _, field in { "ServerMaxActive", "ServerMaxRetained", "HybridRatePerSecond", "HybridBurst" } do
			table.insert(cases, {
				Name = `MusicForbids{field}`, Reason = "InvalidPlayerType:Music",
				Mutate = function(runtime) runtime.PlayerTypes.Music[field] = 0 end,
			})
		end
		for _, case in {
			{ Name = "MusicActiveStackMismatch", Reason = "InvalidPlayerType:Music", Mutate = function(r) r.PlayerTypes.Music.ClientMaxActive = 7 end },
			{ Name = "MusicRetainedAboveActive", Reason = "InvalidPlayerType:Music", Mutate = function(r) r.PlayerTypes.Music.ClientMaxRetained = 9 end },
			{ Name = "NegativeServerBudget", Reason = "InvalidPlayerType:SFX", Mutate = function(r) r.PlayerTypes.SFX.ServerMaxActive = -1 end },
			{ Name = "FractionalClientBudget", Reason = "InvalidPlayerType:SFX", Mutate = function(r) r.PlayerTypes.SFX.ClientMaxRetained = 1.5 end },
			{ Name = "InfiniteServerRetained", Reason = "InvalidPlayerType:SFX", Mutate = function(r) r.PlayerTypes.SFX.ServerMaxRetained = math.huge end },
			{ Name = "NaNClientActive", Reason = "InvalidPlayerType:SFX", Mutate = function(r) r.PlayerTypes.SFX.ClientMaxActive = 0 / 0 end },
			{ Name = "ServerRetainedAboveActive", Reason = "InvalidPlayerType:SFX", Mutate = function(r) r.PlayerTypes.SFX.ServerMaxRetained = r.PlayerTypes.SFX.ServerMaxActive + 1 end },
			{ Name = "ClientRetainedAboveActive", Reason = "InvalidPlayerType:SFX", Mutate = function(r) r.PlayerTypes.SFX.ClientMaxRetained = r.PlayerTypes.SFX.ClientMaxActive + 1 end },
			{ Name = "NegativeHybridRate", Reason = "InvalidPlayerType:SFX", Mutate = function(r) r.PlayerTypes.SFX.HybridRatePerSecond = -0.01 end },
			{ Name = "InfiniteHybridBurst", Reason = "InvalidPlayerType:SFX", Mutate = function(r) r.PlayerTypes.SFX.HybridBurst = math.huge end },
			{ Name = "UnknownBus", Reason = "InvalidRoutingConfig", Mutate = function(_, routing) routing.Routes.Unknown = { PlayerType = "Unknown", SourceKind = "Direct", FaderId = "Unknown" } end },
			{ Name = "UnknownRouteTarget", Reason = "InvalidRoute:SFX", Mutate = function(_, routing) routing.Routes.SFX.FaderId = "Unknown" end },
			{ Name = "PerTypeHardCap", Reason = "InvalidPlayerType:SFX", Mutate = function(r) r.PlayerTypes.SFX.ClientMaxActive = AudioSafetyLimits.MaxOrdinaryActivePerType + 1 end },
			{ Name = "AggregateActive", Reason = "AggregateBudgetExceeded", Mutate = function(r) r.PlayerTypes.UI.ClientMaxActive = 41 end },
			{ Name = "AggregateRetained", Reason = "AggregateBudgetExceeded", Mutate = function(r) r.PlayerTypes.UI.ClientMaxRetained = 23 end },
			{ Name = "WorstCaseObjects", Reason = "AggregateBudgetExceeded", Mutate = function(r) r.PlayerTypes.UI.ClientMaxActive = 40; r.PlayerTypes.UI.ClientMaxRetained = 23 end },
			{ Name = "ServerAggregateActive", Side = "Server", Reason = "AggregateBudgetExceeded", Mutate = function(r) r.PlayerTypes.UI.ServerMaxActive = 33 end },
			{ Name = "ServerAggregateRetained", Side = "Server", Reason = "AggregateBudgetExceeded", Mutate = function(r) r.PlayerTypes.UI.ServerMaxActive = 32; r.PlayerTypes.UI.ServerMaxRetained = 17 end },
			{ Name = "SourceVolume", Reason = "InvalidPlayerType:SFX", Mutate = function(r) r.PlayerTypes.SFX.SourceVolumeMax = 10.01 end },
			{ Name = "SourceVolumeLower", Reason = "InvalidPlayerType:SFX", Mutate = function(r) r.PlayerTypes.SFX.SourceVolumeMin = -0.01 end },
			{ Name = "SourceVolumeOrder", Reason = "InvalidPlayerType:SFX", Mutate = function(r) r.PlayerTypes.SFX.SourceVolumeMin = 0.9; r.PlayerTypes.SFX.SourceVolumeMax = 0.8 end },
			{ Name = "SourceVolumeFinite", Reason = "InvalidPlayerType:SFX", Mutate = function(r) r.PlayerTypes.SFX.SourceVolumeMax = math.huge end },
			{ Name = "SourceVolumeNaN", Reason = "InvalidPlayerType:SFX", Mutate = function(r) r.PlayerTypes.SFX.SourceVolumeMax = 0 / 0 end },
			{ Name = "PlaybackSpeed", Reason = "InvalidPlayerType:SFX", Mutate = function(r) r.PlayerTypes.SFX.PlaybackSpeedMin = 0.04 end },
			{ Name = "PlaybackSpeedUpper", Reason = "InvalidPlayerType:SFX", Mutate = function(r) r.PlayerTypes.SFX.PlaybackSpeedMax = 20.01 end },
			{ Name = "PlaybackSpeedOrder", Reason = "InvalidPlayerType:SFX", Mutate = function(r) r.PlayerTypes.SFX.PlaybackSpeedMin = 2; r.PlayerTypes.SFX.PlaybackSpeedMax = 1 end },
			{ Name = "PlaybackSpeedFinite", Reason = "InvalidPlayerType:SFX", Mutate = function(r) r.PlayerTypes.SFX.PlaybackSpeedMin = 0 / 0 end },
			{ Name = "LoadTimeoutLower", Reason = "InvalidPlayerType:SFX", Mutate = function(r) r.PlayerTypes.SFX.LoadTimeoutSeconds = 0.49 end },
			{ Name = "LoadTimeoutUpper", Reason = "InvalidPlayerType:SFX", Mutate = function(r) r.PlayerTypes.SFX.LoadTimeoutSeconds = 30.01 end },
			{ Name = "LoadTimeoutFinite", Reason = "InvalidPlayerType:SFX", Mutate = function(r) r.PlayerTypes.SFX.LoadTimeoutSeconds = -math.huge end },
			{ Name = "LoadTimeoutNaN", Reason = "InvalidPlayerType:SFX", Mutate = function(r) r.PlayerTypes.SFX.LoadTimeoutSeconds = 0 / 0 end },
			{ Name = "FaderDb", Reason = "InvalidFader:SFX", Mutate = function(r) r.Faders.SFX.MinDb = -61 end },
			{ Name = "FaderDbUpper", Reason = "InvalidFader:SFX", Mutate = function(r) r.Faders.SFX.MaxDb = 0.01 end },
			{ Name = "FaderDbOrder", Reason = "InvalidFader:SFX", Mutate = function(r) r.Faders.SFX.MinDb = -1; r.Faders.SFX.MaxDb = -2 end },
			{ Name = "FaderLevelLower", Reason = "InvalidFader:SFX", Mutate = function(r) r.Faders.SFX.DefaultLevel01 = -0.01 end },
			{ Name = "FaderLevelUpper", Reason = "InvalidFader:SFX", Mutate = function(r) r.Faders.SFX.DefaultLevel01 = 1.01 end },
			{ Name = "FaderFinite", Reason = "InvalidFader:SFX", Mutate = function(r) r.Faders.SFX.MaxDb = math.huge end },
			{ Name = "FaderNaN", Reason = "InvalidFader:SFX", Mutate = function(r) r.Faders.SFX.MaxDb = 0 / 0 end },
			{ Name = "InvalidSide", Side = "Hybrid", Reason = "InvalidSide", Mutate = function() end },
		} do table.insert(cases, case) end
		for _, case in cases do assertDisabled(case) end
	end)
	test("AudioCatalog/WeightedAntiRepeat", function()
		local a = table.clone(SoundCatalog[2]); a.CueId = "Weighted.Exact"; a.VariantId = "A"; a.AssetId = "1"; a.Weight = 4
		local b = table.clone(a); b.VariantId = "B"; b.AssetId = "2"; b.Weight = 1
		local catalog = Catalog.new({ a, b }, validated("Client"), emptyRegistry(), logger(), function() return 0 end)
		assert(catalog:Resolve({ CueId = a.CueId }).VariantId == "A")
		assert(catalog:Resolve({ CueId = a.CueId }).VariantId == "B")
		assert(catalog:Resolve({ CueId = a.CueId }).VariantId == "A")
	end)
	test("AudioCatalog/OptionalDefaults", function()
		local authored = table.clone(SoundCatalog[2])
		authored.Volume01 = nil; authored.PlaybackSpeed = nil; authored.Weight = nil
		authored.Looping = nil; authored.Preload = nil; authored.AllowClientHybrid = nil
		local variant = Catalog.new({ authored }, validated("Client"), emptyRegistry(), logger()):GetSnapshot().Variants[1]
		assert(variant.Volume01 == 1 and variant.PlaybackSpeed == 1 and variant.Weight == 1)
		assert(not variant.Looping and not variant.Preload and not variant.AllowClientHybrid)
	end)
	test("AudioCatalog/CanonicalPathNormalization", function(scope)
		local sound = scope:Track(Instance.new("Sound")); sound.SoundId = "rbxassetid://9120386436"
		local registry = {
			GetByKey = function() return nil end, Get = function() return nil end,
			GetPath = function() return "Shared/Sounds/Nested/Tone" end,
			FindAll = function() return { sound } end,
		}
		local catalog = Catalog.new({ SoundCatalog[2] }, validated("Client"), registry, logger(), function() return 0 end)
		local relative = catalog:Resolve({ FolderPath = "Nested" })
		assert(relative ~= nil and catalog:Resolve({ FolderPath = "Shared/Sounds/Nested" }) == relative)
		assert(catalog:Resolve({ FolderPath = "ReplicatedStorage/Assets/Shared/Sounds/Nested" }) == relative)
	end)
	test("AudioCatalog/RecursivePhysicalFolder", function(scope)
		local a = scope:Track(Instance.new("Sound")); a.SoundId = "rbxassetid://1"
		local b = scope:Track(Instance.new("Sound")); b.SoundId = "rbxassetid://2"
		local first = table.clone(SoundCatalog[2]); first.CueId = "Folder.A"; first.AssetId = "1"
		local second = table.clone(first); second.CueId = "Folder.B"; second.AssetId = "2"
		local paths = { [a] = "Shared/Sounds/Nested/A", [b] = "Shared/Sounds/Nested/Deep/B" }
		local registry = {
			GetByKey = function() return nil end, Get = function() return nil end,
			GetPath = function(_self, value) return paths[value] end,
			FindAll = function() return { b, a } end,
		}
		local catalog = Catalog.new({ first, second }, validated("Client"), registry, logger(), function() return 0 end)
		local snapshot = catalog:GetSnapshot()
		assert(#snapshot.Indexes.ByFolderPath["Shared/Sounds/Nested"] == 2)
		assert(catalog:Resolve({ FolderPath = "Nested/Deep" }).CueId == "Folder.B")
	end)
	test("AudioCatalog/CuePolicyFirstRow", function()
		local first = table.clone(SoundCatalog[2]); first.CueId = "Policy"; first.VariantId = "A"; first.AssetId = "1"
		local mismatch = table.clone(first); mismatch.VariantId = "B"; mismatch.AssetId = "2"; mismatch.PlayerType = "UI"
		local events = {}
		local catalog = Catalog.new({ first, mismatch }, validated("Client"), emptyRegistry(), logger(events), function() return 0 end)
		assert(catalog:GetNamedVariant("Policy", "B") == nil and catalog:Resolve({ CueId = "Policy" }).VariantId == "A")
		assert(events[#events].Event == "CatalogConflictFirstWins" and events[#events].Data.Index == "CueId")
	end)
	test("AudioCatalog/PhysicalCatalogIdentityConflict", function(scope)
		local sound = scope:Track(Instance.new("Sound")); sound.SoundId = "rbxassetid://2"
		local authored = table.clone(SoundCatalog[2]); authored.AssetId = "1"; authored.ResourcePath = "Shared/Sounds/Tone"
		local events = {}
		local registry = {
			GetByKey = function() return nil end, Get = function() return sound end,
			GetPath = function() return "Shared/Sounds/Tone" end, FindAll = function() return { sound } end,
		}
		local catalog = Catalog.new({ authored }, validated("Client"), registry, logger(events))
		assert(#catalog:GetSnapshot().Variants == 0)
		assert(events[1].Event == "CatalogRowSkipped" and events[1].Data.ReasonCode == "PhysicalIdentityConflict")
	end)
	test("AudioCatalog/WeightedBoundarySelection", function()
		local first = table.clone(SoundCatalog[2]); first.CueId = "Boundary"; first.VariantId = "A"; first.AssetId = "1"; first.Weight = 1
		local second = table.clone(first); second.VariantId = "B"; second.AssetId = "2"; second.Weight = 3
		local catalog = Catalog.new({ first, second }, validated("Client"), emptyRegistry(), logger(), function() return 0.99 end)
		assert(catalog:Resolve({ CueId = "Boundary" }).VariantId == "B")
	end)
	test("AudioCatalog/HugeFiniteWeightsRemainProportional", function()
		local function resolve(firstWeight: number, secondWeight: number, sample: number): string
			local first = table.clone(SoundCatalog[2]); first.CueId = "Huge"; first.VariantId = "A"; first.AssetId = "1"; first.Weight = firstWeight
			local second = table.clone(first); second.VariantId = "B"; second.AssetId = "2"; second.Weight = secondWeight
			local catalog = Catalog.new({ first, second }, validated("Client"), emptyRegistry(), logger(), function() return sample end)
			return catalog:Resolve({ CueId = "Huge" }).VariantId
		end
		assert(resolve(1e308, 1e308, 0) == "A", "zero sample did not select the first huge equal bucket")
		assert(resolve(1e308, 1e308, 0.5) == "B", "exact huge-equal midpoint did not enter the second half-open bucket")
		assert(resolve(1e308, 1e308, 0.75) == "B", "positive sample collapsed to huge-weight fallback")
		assert(resolve(1e308, 5e307, 0.5) == "A", "huge unequal first bucket lost proportional width")
		assert(resolve(1e308, 5e307, 0.9) == "B", "huge unequal second bucket was unreachable")
		assert(resolve(1, 3, 0.24) == "A", "ordinary small-weight first-bucket parity regressed")
		assert(resolve(1, 3, 0.25) == "B", "ordinary small-weight boundary parity regressed")
		assert(
			resolve(1e13, 1, 0.99999999999995) == "B",
			"representable high sample could not reach the tiny tail bucket"
		)
		assert(
			resolve(1, 1e13, 0.99999999999995) == "B",
			"reversed huge/tiny order changed the high-sample dominant bucket"
		)
		do
			local first = table.clone(SoundCatalog[2]); first.CueId = "Huge.ReversedTie"; first.VariantId = "A"; first.AssetId = "1"; first.Weight = 1e308
			local second = table.clone(first); second.VariantId = "B"; second.AssetId = "2"
			local reversed = Catalog.new({ second, first }, validated("Client"), emptyRegistry(), logger(), function() return 0.5 end)
			assert(reversed:Resolve({ CueId = first.CueId }).VariantId == "A", "reversed tie did not preserve catalog-order half-open intervals")
		end
		local smallestPositive = 5e-324
		assert(smallestPositive > 0, "fixture did not construct the smallest positive double")
		assert(resolve(1e-308, 1e308, 0) == "A", "zero did not reach the tiny first interval")
		assert(
			resolve(1e-308, 1e308, smallestPositive) == "B",
			"smallest positive sample incorrectly remained inside an underflow-scale interval"
		)
		assert(resolve(1e308, 1e-308, 0) == "A", "reversed huge first interval was not selected")
		assert(
			resolve(1e308, 1e-308, smallestPositive) == "A",
			"reversed tiny/huge ordering changed the dominant interval"
		)

		local first = table.clone(SoundCatalog[2]); first.CueId = "Huge.AntiRepeat"; first.VariantId = "A"; first.AssetId = "1"; first.Weight = 1e308
		local second = table.clone(first); second.VariantId = "B"; second.AssetId = "2"; second.Weight = 1e308
		local antiRepeat = Catalog.new({ first, second }, validated("Client"), emptyRegistry(), logger(), function() return 0.9 end)
		assert(antiRepeat:Resolve({ CueId = first.CueId }).VariantId == "B")
		assert(antiRepeat:Resolve({ CueId = first.CueId }).VariantId == "A")
		assert(antiRepeat:Resolve({ CueId = first.CueId }).VariantId == "B")

		local tiny = table.clone(first); tiny.CueId = "Huge.TinyAntiRepeat"; tiny.VariantId = "Tiny"; tiny.AssetId = "3"; tiny.Weight = 1e-308
		local dominant = table.clone(tiny); dominant.VariantId = "Dominant"; dominant.AssetId = "4"; dominant.Weight = 1e308
		local fullDomainAntiRepeat = Catalog.new(
			{ tiny, dominant },
			validated("Client"),
			emptyRegistry(),
			logger(),
			function() return smallestPositive end
		)
		assert(fullDomainAntiRepeat:Resolve({ CueId = tiny.CueId }).VariantId == "Dominant")
		assert(fullDomainAntiRepeat:Resolve({ CueId = tiny.CueId }).VariantId == "Tiny")
		assert(fullDomainAntiRepeat:Resolve({ CueId = tiny.CueId }).VariantId == "Dominant")
	end)
	test("AudioCatalog/IndependentAntiRepeatOwners", function(scope)
		local a = scope:Track(Instance.new("Sound")); a.SoundId = "rbxassetid://1"
		local b = scope:Track(Instance.new("Sound")); b.SoundId = "rbxassetid://2"
		local first = table.clone(SoundCatalog[2]); first.CueId = "Owners"; first.VariantId = "A"; first.AssetId = "1"
		local second = table.clone(first); second.VariantId = "B"; second.AssetId = "2"
		local paths = { [a] = "Shared/Sounds/Owners/A", [b] = "Shared/Sounds/Owners/B" }
		local registry = {
			GetByKey = function() return nil end, Get = function() return nil end,
			GetPath = function(_self, value) return paths[value] end, FindAll = function() return { a, b } end,
		}
		local catalog = Catalog.new({ first, second }, validated("Client"), registry, logger(), function() return 0 end)
		assert(catalog:Resolve({ CueId = "Owners" }).VariantId == "A")
		assert(catalog:Resolve({ FolderPath = "Owners" }).VariantId == "A",
			"cue and folder selectors must own independent anti-repeat history")
	end)
	test("AudioCatalog/SoundRefExactOne", function(scope)
		local sound = scope:Track(Instance.new("Sound")); sound.SoundId = "rbxassetid://1"; sound:SetAttribute("AssetKey", "tone")
		local authored = table.clone(SoundCatalog[2]); authored.CueId = "Refs"; authored.VariantId = "Only"; authored.AssetId = "1"; authored.AssetKey = "tone"; authored.ResourcePath = "Shared/Sounds/Refs/Tone"
		local registry = {
			GetByKey = function() return sound end, Get = function() return sound end,
			GetPath = function() return "Shared/Sounds/Refs/Tone" end, FindAll = function() return { sound } end,
		}
		local catalog = Catalog.new({ authored }, validated("Client"), registry, logger(), function() return 0 end)
		local expected = catalog:GetNamedVariant("Refs", "Only")
		for _, ref in {
			{ CueId = "Refs" }, { AssetId = "1" }, { AssetKey = "tone" },
			{ ResourcePath = "Shared/Sounds/Refs/Tone" }, { FolderPath = "Refs" },
		} do assert(catalog:Resolve(ref) == expected) end
		assert(catalog:Resolve({}) == nil and catalog:Resolve({ AssetId = "1", AssetKey = "tone" }) == nil)
	end)
	test("AudioCatalog/PhysicalDescriptorMapsToNamedVariant", function(scope)
		local sound = scope:Track(Instance.new("Sound")); sound.SoundId = "rbxassetid://9120386436"
		local registry = {
			GetByKey = function() return nil end, Get = function() return nil end,
			GetPath = function() return "Shared/Sounds/Named/Tone" end, FindAll = function() return { sound } end,
		}
		local catalog = Catalog.new({ SoundCatalog[2] }, validated("Client"), registry, logger())
		assert(catalog:Resolve({ FolderPath = "Named" }) == catalog:GetNamedVariant("Template.SFX.Pulse", "Default"))
	end)
	test("AudioCatalog/ResourcePathAssetIdNormalization", function(scope)
		local sound = scope:Track(Instance.new("Sound")); sound.SoundId = "rbxassetid://1"
		local authored = table.clone(SoundCatalog[2]); authored.AssetId = "1"; authored.ResourcePath = "Shared/Sounds/Tone"
		local registry = {
			GetByKey = function() return nil end, Get = function() return sound end,
			GetPath = function() return "Shared/Sounds/Tone" end, FindAll = function() return { sound } end,
		}
		local variant = Catalog.new({ authored }, validated("Client"), registry, logger()):GetSnapshot().Variants[1]
		assert(variant.AssetId == "1" and variant.ContentId == "rbxassetid://1")
	end)
	test("AudioCatalog/PerIndexFirstWins", function()
		local first = table.clone(SoundCatalog[2]); first.CueId = "First"; first.AssetId = "1"
		local second = table.clone(first); second.CueId = "Second"; second.AssetId = "1"
		local events = {}
		local catalog = Catalog.new({ first, second }, validated("Client"), emptyRegistry(), logger(events))
		assert(catalog:Resolve({ AssetId = "1" }).CueId == "First")
		assert(catalog:GetNamedVariant("Second", second.VariantId) ~= nil)
		assert(events[#events].Event == "CatalogConflictFirstWins" and events[#events].Data.Index == "AssetId")
	end)
	test("AudioConfig/ShippedLoadTimeouts", function()
		local config = validated("Client")
		assert(config.PlayerTypes.UI.LoadTimeoutSeconds == 2 and config.PlayerTypes.SFX.LoadTimeoutSeconds == 3)
		assert(config.PlayerTypes.World.LoadTimeoutSeconds == 3 and config.PlayerTypes.Music.LoadTimeoutSeconds == 15)
	end)
	test("AudioConfig/StartupCeilingsAndFailures", function(scope)
		local shippedClient = Validator.validate(RuntimeConfig, RoutingConfig, SpatialProfiles, "Client", logger())
		local shippedServer = Validator.validate(RuntimeConfig, RoutingConfig, SpatialProfiles, "Server", logger())
		assert(shippedClient.Enabled and shippedServer.Enabled and table.isfrozen(shippedClient.Config))
		assert(shippedClient.Config.PlayerTypes.UI.ClientMaxActive == 24
			and shippedClient.Config.PlayerTypes.SFX.ClientMaxActive == 32
			and shippedClient.Config.PlayerTypes.World.ClientMaxActive == 48
			and shippedClient.Config.PlayerTypes.Music.MusicStackMaxDepth == 8)
		assert(shippedServer.Config.PlayerTypes.SFX.ServerMaxActive == 32
			and shippedServer.Config.PlayerTypes.World.ServerMaxActive == 64)

		local function validateMutation(name: string, side: string, mutate: (any, any, any) -> (), expectedReason: string?): any
			local runtime = deepClone(RuntimeConfig)
			local routing = deepClone(RoutingConfig)
			local spatial = deepClone(SpatialProfiles)
			mutate(runtime, routing, spatial)
			local events = {}
			local result = Validator.validate(runtime, routing, spatial, side, logger(events))
			if expectedReason == nil then
				assert(result.Enabled and #events == 0, `{name}: exact boundary must be accepted`)
			else
				assert(not result.Enabled and result.ReasonCode == expectedReason and result.Config == nil and table.isfrozen(result))
				assert(#events == 1 and events[1].Event == "InvalidConfig" and events[1].Data.ReasonCode == expectedReason)
				local runtimeParent = scope:Track(Instance.new("Folder"))
				local graph = AudioGraphServer.new(runtimeParent, logger(events)):Initialize(result)
				local creates = 0
				OrdinaryPlaybackCore.new(side, {
					CreatePoolablePool = function() creates += 1; error("pre-resource failure violated") end,
					RemovePool = function() return true end,
				}, logger(events)):Initialize(result, graph)
				assert(creates == 0 and #runtimeParent:GetChildren() == 0, `{name}: resources changed after rejection`)
			end
			return result
		end

		for _, boundary in {
			{ "MusicStack", "Client", function(r) r.PlayerTypes.Music.ClientMaxActive = 16; r.PlayerTypes.Music.MusicStackMaxDepth = 16 end,
				function(r) r.PlayerTypes.Music.ClientMaxActive = 17; r.PlayerTypes.Music.MusicStackMaxDepth = 17 end, "InvalidPlayerType:Music" },
			{ "HybridRate", "Client", function(r) r.PlayerTypes.SFX.HybridRatePerSecond = 30 end,
				function(r) r.PlayerTypes.SFX.HybridRatePerSecond = 31 end, "InvalidPlayerType:SFX" },
			{ "HybridBurst", "Client", function(r) r.PlayerTypes.SFX.HybridBurst = 60 end,
				function(r) r.PlayerTypes.SFX.HybridBurst = 61 end, "InvalidPlayerType:SFX" },
			{ "AggregateActive", "Client", function(r) r.PlayerTypes.UI.ClientMaxActive = 40 end,
				function(r) r.PlayerTypes.UI.ClientMaxActive = 41 end, "AggregateBudgetExceeded" },
			{ "AggregateRetained", "Client", function(r) r.PlayerTypes.UI.ClientMaxRetained = 22 end,
				function(r) r.PlayerTypes.UI.ClientMaxRetained = 23 end, "AggregateBudgetExceeded" },
			{ "SourceVolume", "Client", function(r) r.PlayerTypes.SFX.SourceVolumeMax = 10 end,
				function(r) r.PlayerTypes.SFX.SourceVolumeMax = 11 end, "InvalidPlayerType:SFX" },
			{ "SourceVolumeLower", "Client", function(r) r.PlayerTypes.SFX.SourceVolumeMin = 0 end,
				function(r) r.PlayerTypes.SFX.SourceVolumeMin = -0.01 end, "InvalidPlayerType:SFX" },
			{ "PlaybackSpeed", "Client", function(r) r.PlayerTypes.SFX.PlaybackSpeedMax = 20 end,
				function(r) r.PlayerTypes.SFX.PlaybackSpeedMax = 21 end, "InvalidPlayerType:SFX" },
			{ "PlaybackSpeedLower", "Client", function(r) r.PlayerTypes.SFX.PlaybackSpeedMin = 0.05 end,
				function(r) r.PlayerTypes.SFX.PlaybackSpeedMin = 0.049 end, "InvalidPlayerType:SFX" },
			{ "LoadTimeout", "Client", function(r) r.PlayerTypes.SFX.LoadTimeoutSeconds = 30 end,
				function(r) r.PlayerTypes.SFX.LoadTimeoutSeconds = 31 end, "InvalidPlayerType:SFX" },
			{ "LoadTimeoutLower", "Client", function(r) r.PlayerTypes.SFX.LoadTimeoutSeconds = 0.5 end,
				function(r) r.PlayerTypes.SFX.LoadTimeoutSeconds = 0.49 end, "InvalidPlayerType:SFX" },
			{ "FaderLevel", "Client", function(r) r.Faders.SFX.DefaultLevel01 = 1 end,
				function(r) r.Faders.SFX.DefaultLevel01 = 1.01 end, "InvalidFader:SFX" },
			{ "FaderLevelLower", "Client", function(r) r.Faders.SFX.DefaultLevel01 = 0 end,
				function(r) r.Faders.SFX.DefaultLevel01 = -0.01 end, "InvalidFader:SFX" },
			{ "FaderMinDb", "Client", function(r) r.Faders.SFX.MinDb = -60 end,
				function(r) r.Faders.SFX.MinDb = -61 end, "InvalidFader:SFX" },
			{ "ServerAggregateActive", "Server", function(r) r.PlayerTypes.UI.ServerMaxActive = 32 end,
				function(r) r.PlayerTypes.UI.ServerMaxActive = 33 end, "AggregateBudgetExceeded" },
			{ "ServerAggregateRetained", "Server", function(r)
				r.PlayerTypes.UI.ServerMaxActive = 32; r.PlayerTypes.UI.ServerMaxRetained = 16
			end, function(r)
				r.PlayerTypes.UI.ServerMaxActive = 32; r.PlayerTypes.UI.ServerMaxRetained = 17
			end, "AggregateBudgetExceeded" },
		} do
			validateMutation(boundary[1], boundary[2], boundary[3], nil)
			validateMutation(boundary[1] .. "+1", boundary[2], boundary[4], boundary[5])
		end
		local objectBoundary = validateMutation("WorstCaseObjects", "Client", function(r)
			r.PlayerTypes.UI.ClientMaxActive = 40
			r.PlayerTypes.UI.ClientMaxRetained = 22
		end, nil)
		local totalActive, totalRetained = 0, 0
		for _, record in objectBoundary.Config.PlayerTypes do
			totalActive += record.ClientMaxActive
			totalRetained += record.ClientMaxRetained
		end
		assert(totalActive == 128 and totalRetained == 64
			and 4 * (totalActive + totalRetained) == AudioSafetyLimits.MaxWorstCasePlaybackObjectsPerSide)
		validateMutation("WorstCaseObjects+1", "Client", function(r)
			r.PlayerTypes.UI.ClientMaxActive = 40
			r.PlayerTypes.UI.ClientMaxRetained = 23
		end, "AggregateBudgetExceeded")
		local serverObjectBoundary = validateMutation("ServerWorstCaseObjects", "Server", function(r)
			r.PlayerTypes.UI.ServerMaxActive = 32
			r.PlayerTypes.UI.ServerMaxRetained = 16
		end, nil)
		local serverActive, serverRetained = 0, 0
		for id, record in serverObjectBoundary.Config.PlayerTypes do
			if id ~= "Music" then
				serverActive += record.ServerMaxActive
				serverRetained += record.ServerMaxRetained
			end
		end
		assert(serverActive == AudioSafetyLimits.MaxTotalActivePerSide
			and serverRetained == AudioSafetyLimits.MaxTotalRetainedPerSide
			and 4 * (serverActive + serverRetained) == AudioSafetyLimits.MaxWorstCasePlaybackObjectsPerSide,
			"server exact aggregate/object equality must be 128/64/768")
		validateMutation("ServerWorstCaseObjects+1", "Server", function(r)
			r.PlayerTypes.UI.ServerMaxActive = 32
			r.PlayerTypes.UI.ServerMaxRetained = 17
		end, "AggregateBudgetExceeded")

		-- The absolute 256/128 ordinary per-type limits cannot be reached because
		-- the tighter 128/64 side aggregate rejects first. Execute that effective
		-- server boundary explicitly instead of claiming the unreachable maxima.
		validateMutation("EffectivePerTypeActive", "Server", function(r)
			r.PlayerTypes.SFX.ServerMaxActive = 128; r.PlayerTypes.SFX.ServerMaxRetained = 0
			r.PlayerTypes.UI.ServerMaxActive = 0; r.PlayerTypes.UI.ServerMaxRetained = 0
			r.PlayerTypes.World.ServerMaxActive = 0; r.PlayerTypes.World.ServerMaxRetained = 0
		end, nil)
		validateMutation("EffectivePerTypeActive+1", "Server", function(r)
			r.PlayerTypes.SFX.ServerMaxActive = 129; r.PlayerTypes.SFX.ServerMaxRetained = 0
			r.PlayerTypes.UI.ServerMaxActive = 0; r.PlayerTypes.UI.ServerMaxRetained = 0
			r.PlayerTypes.World.ServerMaxActive = 0; r.PlayerTypes.World.ServerMaxRetained = 0
		end, "AggregateBudgetExceeded")
		validateMutation("EffectivePerTypeRetained", "Server", function(r)
			r.PlayerTypes.SFX.ServerMaxActive = 64; r.PlayerTypes.SFX.ServerMaxRetained = 64
			r.PlayerTypes.UI.ServerMaxActive = 0; r.PlayerTypes.UI.ServerMaxRetained = 0
			r.PlayerTypes.World.ServerMaxActive = 0; r.PlayerTypes.World.ServerMaxRetained = 0
		end, nil)
		validateMutation("EffectivePerTypeRetained+1", "Server", function(r)
			r.PlayerTypes.SFX.ServerMaxActive = 65; r.PlayerTypes.SFX.ServerMaxRetained = 65
			r.PlayerTypes.UI.ServerMaxActive = 0; r.PlayerTypes.UI.ServerMaxRetained = 0
			r.PlayerTypes.World.ServerMaxActive = 0; r.PlayerTypes.World.ServerMaxRetained = 0
		end, "AggregateBudgetExceeded")

		-- PlayerType/Fader/Route key counts are exact authored schemas (4/5/4),
		-- so their larger absolute registry ceilings are unreachable. The extra-key
		-- cases execute the effective +1 boundaries with the same frozen/no-resource baseline.
		assert(AudioSafetyLimits.MaxPlayerTypes > 4 and AudioSafetyLimits.MaxFaders > 5 and AudioSafetyLimits.MaxRoutes > 4)
		validateMutation("EffectivePlayerTypeCount+1", "Client", function(r)
			r.PlayerTypes[string.rep("P", AudioSafetyLimits.MaxPlayerTypeBytes)] = deepClone(r.PlayerTypes.SFX)
		end, "InvalidRuntimeConfig")
		validateMutation("EffectiveFaderCount+1", "Client", function(r)
			r.Faders.Extra = deepClone(r.Faders.SFX)
		end, "InvalidRuntimeConfig")
		validateMutation("EffectiveRouteCount+1", "Client", function(_, routing)
			routing.Routes.Extra = { PlayerType = "Extra", SourceKind = "Direct", FaderId = "SFX" }
		end, "InvalidRoutingConfig")

		validateMutation("SpatialProfileCount", "Client", function(_, _, spatial)
			spatial.Profiles = {}
			for index = 1, AudioSafetyLimits.MaxSpatialProfiles do
				spatial.Profiles[`P{index}`] = { AcousticSimulationEnabled = true }
			end
			spatial.DefaultWorldProfileId = "P1"
		end, nil)
		validateMutation("SpatialProfileCount+1", "Client", function(_, _, spatial)
			spatial.Profiles = {}
			for index = 1, AudioSafetyLimits.MaxSpatialProfiles + 1 do
				spatial.Profiles[`P{index}`] = { AcousticSimulationEnabled = true }
			end
			spatial.DefaultWorldProfileId = "P1"
		end, "SpatialProfileBudgetExceeded")

		-- Graph timeout is code-owned rather than authored. Execute its exact
		-- effective deadline against the production client graph and prove it
		-- leaves the empty runtime untouched.
		local graphNow = 0
		local graphWaits = 0
		local graphEvents = {}
		local graphRuntime = scope:Track(Instance.new("Folder"))
		local graph = AudioGraphClient.new({
			RuntimeParent = graphRuntime,
			Clock = function() return graphNow end,
			Wait = function() graphWaits += 1; graphNow += 1 end,
			Logger = logger(graphEvents),
		})
		local graphResult = graph:Initialize(shippedClient)
		assert(AudioSafetyLimits.GraphBindTimeoutSeconds == 10
			and not graphResult.Enabled and table.isfrozen(graphResult)
			and graphNow == AudioSafetyLimits.GraphBindTimeoutSeconds
			and graphWaits == AudioSafetyLimits.GraphBindTimeoutSeconds
			and #graphRuntime:GetChildren() == 0
			and #graphEvents == 1 and graphEvents[1].Event == "GraphBindFailed",
			"the code-owned graph timeout must stop at exactly 10 seconds without resources")

		local function transitionAccepted(duration: number): (boolean, number)
			local pools = PoolModule.new()
			pools:Initialize()
			scope:Defer(function() pools:Destroy() end)
			local function wrapperFactory(): any
				local player = { IsPlaying = false, TimePosition = 0 }
				function player:Play() self.IsPlaying = true end
				function player:Stop() self.IsPlaying = false end
				local wrapper = { Player = player, _TransitionGain = 0, Context = nil }
				function wrapper:OnAcquire(context)
					self.Context = context
					if context.OnReady then context.OnReady() end
				end
				function wrapper:OnRelease() self.Context = nil; self.Player:Stop(); self._TransitionGain = 0 end
				function wrapper:SetTransitionGain(value) self._TransitionGain = value end
				function wrapper:IsPoolableValid() return true end
				function wrapper:Destroy() self:OnRelease() end
				return wrapper
			end
			local music = MusicClient.new(pools, logger({}), { WrapperFactory = wrapperFactory })
			local variant = {
				CueId = "Boundary.Music", VariantId = "Default", PlayerType = "Music",
				ContentId = "rbxassetid://1", SourceVolume = 0.5, PlaybackSpeed = 1, Looping = true,
			}
			music:Initialize({ Enabled = true, Config = shippedClient.Config, Catalog = {
				Resolve = function() return variant end,
			} }, {
				Enabled = true,
				LocalRoot = {},
				Faders = { Music = {} },
				Config = shippedClient.Config,
			})
			local handle = music:PlayMusic({ CueId = variant.CueId }, nil, {
				Strategy = "Crossfade", FadeOutSeconds = duration, FadeInSeconds = duration,
			})
			local acquired = pools:GetPool("Audio.Client.Music"):GetStats().Acquired
			local active = handle:IsActive()
			music:StopAllMusic()
			return active, acquired
		end
		local transitionExact, transitionExactAcquires = transitionAccepted(AudioSafetyLimits.MaxTransitionSeconds)
		local transitionZero, transitionZeroAcquires = transitionAccepted(0)
		local transitionAbove, transitionAboveAcquires = transitionAccepted(AudioSafetyLimits.MaxTransitionSeconds + 0.01)
		local transitionBelow, transitionBelowAcquires = transitionAccepted(-0.01)
		assert(transitionExact and transitionZero and transitionExactAcquires == 1 and transitionZeroAcquires == 1
			and not transitionAbove and not transitionBelow and transitionAboveAcquires == 0 and transitionBelowAcquires == 0,
			"production Music transition normalization must accept 0/10 and reject below/+1 before acquisition")

		local identifierBoundary = "A" .. string.rep("x", AudioSafetyLimits.MaxIdentifierBytes - 1)
		assert(AudioHybridCodec.validate({ Version = 1, CueId = identifierBoundary, VariantId = "V", Spatial = { Kind = "None" } }))
		assert(not AudioHybridCodec.validate({ Version = 1, CueId = identifierBoundary .. "x", VariantId = "V", Spatial = { Kind = "None" } }))
		assert(AudioHybridCodec.validate({ Version = 1, CueId = "C", VariantId = identifierBoundary, Spatial = { Kind = "None" } }))
		assert(not AudioHybridCodec.validate({ Version = 1, CueId = "C", VariantId = identifierBoundary .. "x", Spatial = { Kind = "None" } }))
		assert(AudioHybridCodec.validate({ Version = 1, CueId = "C", VariantId = "V", Spatial = { Kind = "Point", Position = Vector3.new(AudioSafetyLimits.HybridWorldCoordinateAbsMax, 0, 0) } }))
		assert(not AudioHybridCodec.validate({ Version = 1, CueId = "C", VariantId = "V", Spatial = { Kind = "Point", Position = Vector3.new(AudioSafetyLimits.HybridWorldCoordinateAbsMax + 1, 0, 0) } }))
		local catalogBoundary = table.clone(SoundCatalog[2])
		catalogBoundary.CueId = identifierBoundary
		catalogBoundary.VariantId = identifierBoundary
		catalogBoundary.AssetId = string.rep("1", 32)
		assert(#Catalog.new({ catalogBoundary }, shippedClient.Config, emptyRegistry(), logger()):GetSnapshot().Variants == 1)
		for _, field in { "CueId", "VariantId", "AssetId" } do
			local invalid = table.clone(catalogBoundary)
			invalid[field] ..= "1"
			assert(#Catalog.new({ invalid }, shippedClient.Config, emptyRegistry(), logger()):GetSnapshot().Variants == 0,
				`catalog {field} +1 must reject`)
		end
		local profileIdentifier = "P" .. string.rep("x", AudioSafetyLimits.MaxPlayerTypeBytes - 1)
		validateMutation("SpatialProfileIdentifier", "Client", function(_, _, spatial)
			spatial.DefaultWorldProfileId = profileIdentifier
			spatial.Profiles = { [profileIdentifier] = { AcousticSimulationEnabled = true } }
		end, nil)
		local invalidProfileEvents = {}
		local invalidProfileIdentifier = profileIdentifier .. "x"
		local invalidProfileConfig = {
			Version = 1,
			DefaultWorldProfileId = invalidProfileIdentifier,
			Profiles = { [invalidProfileIdentifier] = { AcousticSimulationEnabled = true } },
		}
		local invalidProfileResult = Validator.validate(RuntimeConfig, RoutingConfig, invalidProfileConfig, "Client", logger(invalidProfileEvents))
		assert(invalidProfileResult.Enabled and next(invalidProfileResult.Config.SpatialProfilesById) == nil
			and #invalidProfileEvents == 2,
			"65-byte spatial identifiers must isolate the profile/default without disabling valid audio")
		local sound = scope:Track(Instance.new("Sound")); sound.SoundId = "rbxassetid://9120386436"
		local assetKeyBoundary = "K" .. string.rep("x", AudioSafetyLimits.MaxIdentifierBytes - 1)
		local assetKeyRow = table.clone(SoundCatalog[2]); assetKeyRow.AssetId = nil; assetKeyRow.AssetKey = assetKeyBoundary
		local assetKeyRegistry = {
			GetByKey = function(_self, key) return if key == assetKeyBoundary then sound else nil end,
			Get = function() return nil end,
			GetPath = function() return nil end,
			FindAll = function() return {} end,
		}
		assert(#Catalog.new({ assetKeyRow }, shippedClient.Config, assetKeyRegistry, logger()):GetSnapshot().Variants == 1)
		assetKeyRow = table.clone(assetKeyRow); assetKeyRow.AssetKey ..= "x"
		assert(#Catalog.new({ assetKeyRow }, shippedClient.Config, assetKeyRegistry, logger()):GetSnapshot().Variants == 0)
		local pathBoundary = "Shared/Sounds/" .. string.rep("a", AudioSafetyLimits.MaxPathBytes - #"Shared/Sounds/")
		local registry = {
			GetByKey = function() return nil end,
			Get = function() return sound end,
			GetPath = function() return pathBoundary end,
			FindAll = function() return { sound } end,
		}
		local pathRow = table.clone(SoundCatalog[2]); pathRow.ResourcePath = pathBoundary
		local acceptedPath = Catalog.new({ pathRow }, shippedClient.Config, registry, logger())
		assert(acceptedPath:GetSnapshot().Variants[1].ResourcePath == pathBoundary)
		pathRow = table.clone(pathRow); pathRow.ResourcePath = pathBoundary .. "x"
		local pathEvents = {}
		assert(#Catalog.new({ pathRow }, shippedClient.Config, registry, logger(pathEvents)):GetSnapshot().Variants == 0)
		assert(pathEvents[1].Event == "CatalogRowSkipped" and pathEvents[1].Data.ReasonCode == "InvalidAssetIdentity")
		local maximumLegalDto = {
			Version = 1,
			CueId = "A" .. string.rep("x", AudioSafetyLimits.MaxIdentifierBytes - 1),
			VariantId = "B" .. string.rep("y", AudioSafetyLimits.MaxIdentifierBytes - 1),
			VolumeMultiplier = 2,
			PlaybackSpeedMultiplier = 2,
			TimePosition = 1_000_000,
			Spatial = { Kind = "Point", Position = Vector3.new(AudioSafetyLimits.HybridWorldCoordinateAbsMax, 0, 0) },
		}
		local maximumLegalBytes = CommunicationSerialize.estimateSize(maximumLegalDto)
		assert(AudioHybridCodec.validate(maximumLegalDto)
			and maximumLegalBytes < AudioSafetyLimits.HybridIntentMaxEstimatedBytes,
			"exact schema maxima intentionally make the absolute 2048-byte HybridIntent boundary unreachable")
		for _, simulatedBytes in { AudioSafetyLimits.HybridIntentMaxEstimatedBytes, AudioSafetyLimits.HybridIntentMaxEstimatedBytes + 1 } do
			local serializerCalls = 0
			local accepted = AudioHybridCodec.validateWithSerializer(maximumLegalDto, function(candidate, options)
				serializerCalls += 1
				assert(candidate == maximumLegalDto and options.MaxBytes == AudioSafetyLimits.HybridIntentMaxEstimatedBytes
					and options.MaxNodes == 32 and options.MaxIssues == 1,
					"production codec did not pass the exact serializer gate options")
				return simulatedBytes <= options.MaxBytes
			end)
			assert(serializerCalls == 1 and accepted == (simulatedBytes == AudioSafetyLimits.HybridIntentMaxEstimatedBytes),
				`isolated serializer boundary failed at {simulatedBytes} bytes`)
		end
		local payload = { Version = 1, CueId = "", VariantId = "V", Spatial = { Kind = "None" } }
		local baseSize = CommunicationSerialize.estimateSize(payload)
		payload.CueId = string.rep("x", AudioSafetyLimits.HybridIntentMaxEstimatedBytes - baseSize)
		local acceptedPayload, _, exactBytes = CommunicationSerialize.inspect(payload, { MaxBytes = AudioSafetyLimits.HybridIntentMaxEstimatedBytes })
		assert(acceptedPayload and exactBytes == AudioSafetyLimits.HybridIntentMaxEstimatedBytes)
		assert(not AudioHybridCodec.validate(payload), "exact-byte DTO shape must still enforce identifier grammar")
		payload.CueId ..= "x"
		assert(not CommunicationSerialize.validate(payload, { MaxBytes = AudioSafetyLimits.HybridIntentMaxEstimatedBytes })
			and not AudioHybridCodec.validate(payload),
			"generic over-limit plus identifier-invalid input remains rejected independently of the isolated codec gate")

		local function reservationController(typeRate: number, typeBurst: number): (any, () -> (), (number) -> ())
			local now = 0
			local controller = HybridServer.new({ Clock = function() return now end })
			controller._startup = { Config = { PlayerTypes = { SFX = {
				HybridRatePerSecond = typeRate,
				HybridBurst = typeBurst,
			} } } }
			return controller, function() table.clear(controller._rate) end, function(delta) now += delta end
		end
		do
			local controller, _, advance = reservationController(1, 2)
			local owner = { UserId = 1 }
			assert(controller:_reserve(owner, "SFX", 0))
			assert(controller:_reserve(owner, "SFX", 0))
			local accepted, reason = controller:_reserve(owner, "SFX", 0)
			assert(not accepted and reason == "RateLimited", "type burst +1 must reject")
			advance(1)
			assert(controller:_reserve(owner, "SFX", 0), "type rate must refill exactly one token per second")
		end
		do
			local controller, _, advance = reservationController(1_000_000, 1_000_000)
			local owner = { UserId = 2 }
			for _ = 1, AudioSafetyLimits.HybridAggregateBurstPerOwner do assert(controller:_reserve(owner, "SFX", 0)) end
			local accepted, reason = controller:_reserve(owner, "SFX", 0)
			assert(not accepted and reason == "RateLimited", "owner burst +1 must reject")
			advance(1 / AudioSafetyLimits.HybridAggregateRatePerOwner)
			assert(controller:_reserve(owner, "SFX", 0), "owner aggregate rate must refill at the shipped rate")
		end
		do
			local controller, _, advance = reservationController(1_000_000, 1_000_000)
			for userId = 1, AudioSafetyLimits.HybridAcceptedBurstServer do
				assert(controller:_reserve({ UserId = 10_000 + userId }, "SFX", 0))
			end
			local accepted, reason = controller:_reserve({ UserId = 20_000 }, "SFX", 0)
			assert(not accepted and reason == "RateLimited", "server accepted burst +1 must reject")
			advance(1 / AudioSafetyLimits.HybridAcceptedRateServer)
			assert(controller:_reserve({ UserId = 20_001 }, "SFX", 0),
				"server accepted rate must refill at the shipped rate")
		end

		local function publicLimiter(typeRate: number, typeBurst: number): any
			local registered = nil
			local queueCalls = 0
			local events = {}
			local now = 0
			local communication = {
				RegisterHandler = function(_self, _, validator, callback)
					assert(validator == AudioHybridCodec.validate)
					registered = callback
				end,
				IsClientReady = function() return true end,
				QueuePresentationAtomic = function(_self, recipients)
					assert(#recipients == 0, "limiter fixture must not create a partial audience")
					queueCalls += 1
					return true
				end,
			}
			local controller = HybridServer.new({
				Communication = communication,
				PlayersModule = { PlayerRemoving = { Connect = function() return { Disconnect = function() end } end }, GetPlayers = function() return {} end },
				Clock = function() return now end,
				Logger = logger(events),
			})
			controller:Register({
				Enabled = true,
				Catalog = { GetNamedVariant = function(_self, cueId)
					local playerType = if cueId == "WorldCue" then "World" else "SFX"
					return {
						CueId = cueId, VariantId = "V", PlayerType = playerType, AllowClientHybrid = true,
						Looping = false, SourceVolume = 0.5, PlaybackSpeed = 1,
					}
				end },
				Config = { PlayerTypes = {
					SFX = { HybridRatePerSecond = typeRate, HybridBurst = typeBurst,
						SourceVolumeMin = 0, SourceVolumeMax = 1, PlaybackSpeedMin = 0.5, PlaybackSpeedMax = 2 },
					World = { HybridRatePerSecond = typeRate, HybridBurst = typeBurst,
						SourceVolumeMin = 0, SourceVolumeMax = 1, PlaybackSpeedMin = 0.5, PlaybackSpeedMax = 2 },
				} },
			})
			return {
				Handle = registered,
				Events = events,
				Queued = function() return queueCalls end,
				Advance = function(delta) now += delta end,
			}
		end
		local sfxIntent = { Version = 1, CueId = "SFXCue", VariantId = "V", Spatial = { Kind = "None" } }
		local worldIntent = { Version = 1, CueId = "WorldCue", VariantId = "V", Spatial = { Kind = "Point", Position = Vector3.zero } }
		do
			local fixture = publicLimiter(1, 2)
			local owner = { UserId = 40_001 }
			fixture.Handle(owner, sfxIntent); fixture.Handle(owner, sfxIntent)
			assert(fixture.Queued() == 2 and #fixture.Events == 0)
			fixture.Handle(owner, sfxIntent); fixture.Handle(owner, sfxIntent)
			assert(fixture.Queued() == 2 and #fixture.Events == 2
				and fixture.Events[1].Event == "RateLimited" and fixture.Events[2].Event == "RateLimited",
				"public type-bucket +1/repeat rejects must reach Logger without warning-cache suppression")
			fixture.Advance(1)
			fixture.Handle(owner, sfxIntent)
			assert(fixture.Queued() == 3, "public type bucket must refill one exact token")
		end
		do
			local fixture = publicLimiter(30, 60)
			local owner = { UserId = 40_002 }
			for index = 1, AudioSafetyLimits.HybridAggregateBurstPerOwner do
				fixture.Handle(owner, if index % 2 == 0 then worldIntent else sfxIntent)
			end
			assert(fixture.Queued() == AudioSafetyLimits.HybridAggregateBurstPerOwner and #fixture.Events == 0)
			fixture.Handle(owner, sfxIntent); fixture.Handle(owner, worldIntent)
			assert(fixture.Queued() == AudioSafetyLimits.HybridAggregateBurstPerOwner
				and #fixture.Events == 2 and fixture.Events[1].Event == "RateLimited" and fixture.Events[2].Event == "RateLimited",
				"public owner-bucket +1/repeat rejects must reach Logger with zero partial queue")
			fixture.Advance(1 / AudioSafetyLimits.HybridAggregateRatePerOwner)
			fixture.Handle(owner, sfxIntent)
			assert(fixture.Queued() == AudioSafetyLimits.HybridAggregateBurstPerOwner + 1)
		end
		do
			local fixture = publicLimiter(30, 60)
			for userId = 1, AudioSafetyLimits.HybridAcceptedBurstServer do
				fixture.Handle({ UserId = 50_000 + userId }, sfxIntent)
			end
			assert(fixture.Queued() == AudioSafetyLimits.HybridAcceptedBurstServer and #fixture.Events == 0)
			fixture.Handle({ UserId = 60_001 }, sfxIntent); fixture.Handle({ UserId = 60_002 }, sfxIntent)
			assert(fixture.Queued() == AudioSafetyLimits.HybridAcceptedBurstServer
				and #fixture.Events == 2 and fixture.Events[1].Event == "RateLimited" and fixture.Events[2].Event == "RateLimited",
				"public server-bucket +1/repeat rejects must reach Logger with zero partial queue")
			fixture.Advance(1 / AudioSafetyLimits.HybridAcceptedRateServer)
			fixture.Handle({ UserId = 60_003 }, sfxIntent)
			assert(fixture.Queued() == AudioSafetyLimits.HybridAcceptedBurstServer + 1)
		end

		local recipients = {}
		for userId = 1, AudioSafetyLimits.HybridFanoutRecipientsBurstServer do
			table.insert(recipients, { UserId = 30_000 + userId })
		end
		local outgoing = {}
		local outgoingBytes = {}
		local dropped = {}
		local queueCalls = 0
		local host = {
			_outgoing = outgoing, _outgoingBytes = outgoingBytes, _droppedPresentation = dropped,
			Queue = function(self, recipient, messageType, queuedPayload)
				queueCalls += 1
				self._outgoing[recipient] = self._outgoing[recipient] or {}
				table.insert(self._outgoing[recipient], { MessageType = messageType, Payload = queuedPayload })
				self._outgoingBytes[recipient] = (self._outgoingBytes[recipient] or 0) + 1
				return true
			end,
		}
		local registered = nil
		local events = {}
		local now = 0
		local removing = { Connect = function() return { Disconnect = function() end } end }
		local communication = {
			RegisterHandler = function(_self, _, validator, callback)
				assert(validator == AudioHybridCodec.validate); registered = callback
			end,
			IsClientReady = function() return true end,
			QueuePresentationAtomic = function(_self, players, messageType, queuedPayload, requestId)
				return CommunicationServer.QueuePresentationAtomic(host, players, messageType, queuedPayload, requestId)
			end,
		}
		local controller = HybridServer.new({
			Communication = communication,
			PlayersModule = { PlayerRemoving = removing, GetPlayers = function() return recipients end },
			Clock = function() return now end,
			Logger = logger(events),
		})
		controller:Register({
			Enabled = true,
			Catalog = { GetNamedVariant = function() return {
				CueId = "Cue", VariantId = "V", PlayerType = "SFX", AllowClientHybrid = true,
				Looping = false, SourceVolume = 0.5, PlaybackSpeed = 1,
			} end },
			Config = { PlayerTypes = { SFX = {
				HybridRatePerSecond = 30, HybridBurst = 60,
				SourceVolumeMin = 0, SourceVolumeMax = 1, PlaybackSpeedMin = 0.5, PlaybackSpeedMax = 2,
			} } },
		})
		local intent = { Version = 1, CueId = "Cue", VariantId = "V", Spatial = { Kind = "None" } }
		registered({ UserId = 99 }, intent)
		assert(queueCalls == AudioSafetyLimits.HybridFanoutRecipientsBurstServer,
			"the exact 2048-recipient burst must execute through the production atomic helper")
		local acceptedRecipients = queueCalls
		table.insert(recipients, { UserId = 99_999 })
		registered({ UserId = 100 }, intent)
		assert(queueCalls == acceptedRecipients and events[#events].Event == "FanoutBudgetExceeded",
			"fanout burst +1 must reject atomically with zero new recipient queues")
		now += 1
		registered({ UserId = 101 }, intent)
		assert(queueCalls == acceptedRecipients and events[#events].Event == "FanoutBudgetExceeded",
			"one second must refill exactly the configured fanout rate, still below 2049")
		for _ = 1, 1_025 do table.remove(recipients) end
		registered({ UserId = 102 }, intent)
		assert(queueCalls == acceptedRecipients + AudioSafetyLimits.HybridFanoutRecipientsRateServer,
			"the one-second fanout refill must accept exactly 1024 recipients")
		for _, event in events do
			assert(event.Data.CueId == nil and event.Data.VariantId == nil and event.Data.Spatial == nil,
				"common Logger diagnostics must not repeat raw hybrid payload data")
		end
		assert(table.isfrozen(AudioSafetyLimits)
			and AudioSafetyLimits.HybridAggregateRatePerOwner == 20 and AudioSafetyLimits.HybridAggregateBurstPerOwner == 30
			and AudioSafetyLimits.HybridAcceptedRateServer == 128 and AudioSafetyLimits.HybridAcceptedBurstServer == 256
			and AudioSafetyLimits.HybridFanoutRecipientsRateServer == 1024 and AudioSafetyLimits.HybridFanoutRecipientsBurstServer == 2048
			and AudioSafetyLimits.MaxPathBytes == 512)
	end)
	test("AudioConfig/AuthoringCannotRaiseSafetyLimits", function()
		local authored = table.clone(RuntimeConfig); authored.PlayerTypes = table.clone(RuntimeConfig.PlayerTypes)
		authored.PlayerTypes.SFX = table.clone(RuntimeConfig.PlayerTypes.SFX)
		authored.PlayerTypes.SFX.ClientMaxActive = AudioSafetyLimits.MaxOrdinaryActivePerType + 1
		assert(not Validator.validate(authored, RoutingConfig, SpatialProfiles, "Client", logger()).Enabled)
		assert(AudioSafetyLimits.MaxOrdinaryActivePerType == 256 and table.isfrozen(AudioSafetyLimits))
	end)
	return TestHarness.runAll("AudioCatalogTestRunner", tests)
end
return Runner
