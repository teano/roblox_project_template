--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TestHarness = require(script.Parent.TestHarness)
local AudioCatalog = require(ReplicatedStorage.Shared.Audio.AudioCatalog)
local AudioConfigValidator = require(ReplicatedStorage.Shared.Audio.AudioConfigValidator)
local RuntimeConfig = require(ReplicatedStorage.Shared.Configs.Audio.AudioRuntimeConfig)
local RoutingConfig = require(ReplicatedStorage.Shared.Configs.Audio.RoutingConfig)
local SoundCatalog = require(ReplicatedStorage.Shared.Configs.Audio.SoundCatalog)
local SpatialProfiles = require(ReplicatedStorage.Shared.Configs.Audio.SpatialProfiles)
local Bridge = require(ReplicatedStorage.Shared.Tests.AudioManualQaBridge)
local Contracts = require(ReplicatedStorage.Shared.Tests.AudioManualQaContracts)
local Plan = require(ReplicatedStorage.Shared.Tests.AudioManualQaPlan)

local function makeLiveFixture(scope: any): (Instance, any)
	local assets = scope:Track(Instance.new("Folder"))
	assets.Name = "Assets"
	local shared = Instance.new("Folder")
	shared.Name = "Shared"
	shared.Parent = assets
	local sounds = Instance.new("Folder")
	sounds.Name = "Sounds"
	sounds.Parent = shared
	local sfx = Instance.new("Folder")
	sfx.Name = "SFX"
	sfx.Parent = sounds
	local music = Instance.new("Folder")
	music.Name = "Music"
	music.Parent = sounds

	local byPath = {}
	local pathBySound = {}
	local allSounds = {}
	for _, key in Plan.LiveAssetOrder do
		local expected = Plan.LiveAssets[key]
		local parent = sounds
		local name = string.sub(expected.DescriptorPath, #"Shared/Sounds/" + 1)
		if string.sub(name, 1, #"SFX/") == "SFX/" then
			parent = sfx
			name = string.sub(name, #"SFX/" + 1)
		elseif string.sub(name, 1, #"Music/") == "Music/" then
			parent = music
			name = string.sub(name, #"Music/" + 1)
		end
		local sound = Instance.new("Sound")
		sound.Name = name
		sound.SoundId = expected.ContentId
		sound.Parent = parent
		byPath[expected.DescriptorPath] = sound
		pathBySound[sound] = expected.DescriptorPath
		table.insert(allSounds, sound)
	end

	local logger = { Warn = function() end }
	local validation = AudioConfigValidator.validate(
		RuntimeConfig,
		RoutingConfig,
		SpatialProfiles,
		"Client",
		logger
	)
	assert(validation.Enabled, "Shipped client Audio config must validate for the live identity fixture")
	local registry = {
		GetByKey = function() return nil end,
		Get = function(_self: any, path: string): Instance? return byPath[path] end,
		GetPath = function(_self: any, sound: Instance): string? return pathBySound[sound] end,
		FindAll = function() return allSounds end,
	}
	local catalog = AudioCatalog.new(SoundCatalog, validation.Config, registry, logger, function() return 0 end)
	return assets, catalog
end

local function makeBridgeParent(scope: any, side: string): Instance
	local className = if side == "Server" then "Script" else "LocalScript"
	local parent = scope:Track(Instance.new(className))
	parent.Name = "Bootstrap"
	return parent
end

local function makeBridgeCommands(side: string, dispatch: (string, any) -> any): any
	local commands = {}
	for _, command in Bridge.Whitelists[side] do
		commands[command] = function(arguments)
			return dispatch(command, arguments)
		end
	end
	return commands
end

local function installBridgeFixture(scope: any, side: string, dispatch: (string, any) -> any): (Instance, any)
	local parent = makeBridgeParent(scope, side)
	local owner = scope:Track(Bridge.Install({
		Parent = parent,
		Side = side,
		Commands = makeBridgeCommands(side, dispatch),
	}))
	return parent, owner
end

local tests = {
	{
		Name = "PlanValidates",
		Callback = function()
			local valid, validationError = Plan.Validate()
			assert(valid, validationError)
		end,
	},
	{
		Name = "AllAcceptanceCriteriaMapped",
		Callback = function()
			assert(#Plan.AcceptanceCoverage == 79, "Expected exact PRD-AC-001 through PRD-AC-079 coverage")
			for number = 1, 79 do
				local record = Plan.AcceptanceCoverage[number]
				assert(record.Id == string.format("PRD-AC-%03d", number), `Wrong AC identity at {number}`)
				assert(record.Mode == "DeterministicAutomated" or record.Mode == "CollaborativeStudio", "Invalid coverage mode")
				assert(record.EvidenceSource ~= "", "Evidence source required")
			end
		end,
	},
	{
		Name = "ExactLiveAssetDefinitions",
		Callback = function()
			local expected = {
				CartoonBubble = { "Template.SFX.CartoonBubble", "5852470908", "Shared/Sounds/SFX/Cartoon bubble button Sound" },
				OldCarEngine = { "Template.World.OldCarEngine", "137048982817372", "Shared/Sounds/SFX/engine sound for old cars" },
				PrayerRiver = { "Template.Music.PrayerRiver", "91760644839532", "Shared/Sounds/Music/祈りの川" },
			}
			assert(#Plan.LiveAssetOrder == 3, "Collaborative QA must use exactly three reviewed live assets")
			for key, identity in expected do
				local asset = Plan.LiveAssets[key]
				assert(asset.CueId == identity[1] and asset.VariantId == "Default", `Wrong exact pair for '{key}'`)
				assert(asset.AssetId == identity[2] and asset.ContentId == "rbxassetid://" .. identity[2], `Wrong asset ID for '{key}'`)
				assert(asset.DescriptorPath == identity[3], `Wrong descriptor path for '{key}'`)
			end
			assert(Plan.ClientActions.play_local_ui == nil, "Audible UI placeholder action must not exist")
			assert(Plan.ClientActions.start == true, "Reconnect flow must expose the Client.Start orchestration action")
			assert(Plan.ClientActions.validate_invalid_settings_snapshot == true,
				"Live invalid AudioSettings rollback action must remain registered")
			local saveScenario = Plan.GetScenario("Studio-E2E-AUDIO-03/ClientMusicSettingsSave")
			local hasRollbackStep = false
			for _, scenarioStep in saveScenario.Steps do
				if scenarioStep.Action == "validate_invalid_settings_snapshot" then hasRollbackStep = true end
			end
			assert(hasRollbackStep, "Mandatory settings scenario must retain live invalid-snapshot rollback")
		end,
	},
	{
		Name = "PlaybackRefsAreExactCueDictionaries",
		Callback = function()
			for _, key in Plan.LiveAssetOrder do
				local expected = Plan.LiveAssets[key]
				local ref = Contracts.MakeCueRef(expected)
				assert(ref.CueId == expected.CueId, `Wrong exact cue ref for '{key}'`)
				local count = 0
				for field in ref do
					assert(field == "CueId", "QA playback refs must not add ambiguous identity fields")
					count += 1
				end
				assert(count == 1, "QA playback ref must contain exactly CueId")
			end
		end,
	},
	{
		Name = "AcceptedServerOneShotNeedsNoFakeHandle",
		Callback = function()
			local state = { Handles = {}, AcceptedOneShots = {}, ActionSequence = 0 }
			local stored = Contracts.StoreAcceptedServerPlayback(
				state,
				"one-shot",
				{ Accepted = true },
				"ServerSFX",
				"CartoonBubble"
			)
			assert(stored.Label == "one-shot" and stored.HasHandle == false,
				"Accepted non-looping server playback must remain accepted without a handle")
			assert(state.Handles["one-shot"] == nil, "One-shot must not fabricate a stoppable handle")
			assert(state.AcceptedOneShots["one-shot"].LiveAssetKey == "CartoonBubble",
				"One-shot label must remain observable in snapshots")
			local rejected = pcall(function()
				Contracts.StoreAcceptedServerPlayback(state, nil, { Accepted = false }, "ServerSFX", "CartoonBubble")
			end)
			assert(not rejected, "Rejected production playback must still fail closed")
		end,
	},
	{
		Name = "FixedSpatialObservationSchema",
		Callback = function()
			local record = {
				Root = "SpatialAnchor",
				RootClass = "Part",
				Anchored = true,
				CanCollide = false,
				CanQuery = false,
				CanTouch = false,
				Transparency = 1,
				DirectAudioPlayer = true,
				DirectAudioEmitter = true,
				DirectWire = true,
				DirectChildCount = 3,
				WireSource = "Player",
				WireTarget = "Emitter",
				AnchorTransform = { Position = { X = 1, Y = 2, Z = 3 } },
			}
			assert(Contracts.IsFixedSpatialPlaybackRecord(record))
			local mirror = table.clone(record); mirror.RootClass = "Folder"
			assert(not Contracts.IsFixedSpatialPlaybackRecord(mirror),
				"manual QA must reject non-fixed or mirrored playback topology")
		end,
	},
	{
		Name = "PreloadSnapshotUsesOnlyPublicExactRequestResult",
		Callback = function()
			local requestedId = nil
			local snapshot = Contracts.GetAudioPreloadSnapshot({
				GetRequestResult = function(_self, requestId)
					requestedId = requestId
					return {
						RequestedTargets = 3,
						ResolvedContent = 3,
						Loaded = 0,
						Failed = 3,
						Failures = {
							{ ContentId = "rbxassetid://5852470908", Status = "Failure", Error = "private" },
							{ ContentId = "rbxassetid://91760644839532", Status = "TimedOut", Error = "private" },
							{ ContentId = "rbxassetid://137048982817372", Status = "NoPermission", Error = "private" },
						},
					}
				end,
			})
			assert(requestedId == "AudioCatalog.Preload.v1" and snapshot.RequestId == requestedId,
				"QA preload observation must use the exact public sticky request identity")
			assert(snapshot.Available and snapshot.Completed and snapshot.Failed == 3 and #snapshot.Failures == 3,
				"QA preload observation must retain exact public counts")
			assert(snapshot.Failures[1].ContentId == "rbxassetid://5852470908"
				and snapshot.Failures[2].Status == "TimedOut"
				and snapshot.Failures[3].Status == "NoPermission",
				"QA preload observation must retain exact ContentId and status")
			assert(snapshot.Failures[1].Error == nil,
				"QA preload observation must not copy backend error details")
			local unavailable = Contracts.GetAudioPreloadSnapshot(nil)
			assert(not unavailable.Available and unavailable.ReasonCode == "ServiceNotBound",
				"An unbound side must report preload inspection unavailable without a service lookup")
		end,
	},
	{
		Name = "StudioBridgeExactWhitelistsAreFrozen",
		Callback = function()
			local expected = {
				Server = { "Start", "Execute", "Snapshot", "RecordScenario", "Export", "Cleanup" },
				Client = { "Start", "Execute", "Snapshot", "Cleanup" },
			}
			assert(table.isfrozen(Bridge.Whitelists), "Bridge whitelist root must be frozen")
			for side, commands in expected do
				local actual = Bridge.Whitelists[side]
				assert(table.isfrozen(actual) and #actual == #commands, `Wrong frozen {side} bridge whitelist size`)
				for index, command in commands do
					assert(actual[index] == command, `Wrong {side} bridge command at index {index}`)
				end
				local mutationOk = pcall(function() actual[1] = "Mutated" end)
				assert(not mutationOk, `{side} bridge whitelist must reject mutation`)
			end
		end,
	},
	{
		Name = "StudioBridgeGatingPlacementSchemaBindingAndCleanup",
		Callback = function(scope)
			assert(Bridge.ShouldInstall(true) and not Bridge.ShouldInstall(false),
				"Pure bridge gate predicate must fail closed")
			local disabledParent = makeBridgeParent(scope, "Server")
			local disabled = Bridge.Install({
				Parent = disabledParent,
				Side = "Server",
				Enabled = false,
				Commands = makeBridgeCommands("Server", function() return {} end),
			})
			assert(disabled == nil and disabledParent:FindFirstChild(Bridge.Names.Server) == nil,
				"A narrowed/disabled Studio gate must create no bridge")

			local boundServices = { Marker = "production-service-binding" }
			local parent, owner = installBridgeFixture(scope, "Server", function(command, arguments)
				return { BoundMarker = boundServices.Marker, Command = command, Echo = arguments.Echo }
			end)
			local bindable = assert(parent:FindFirstChild(Bridge.Names.Server))
			assert(bindable:IsA("BindableFunction") and bindable.Parent == parent,
				"Server bridge must be the exact side-local BindableFunction child")
			assert(bindable:GetAttribute("AudioManualQaBridgeSchema") == Bridge.SchemaVersion,
				"Server bridge must publish the exact schema marker")
			local response = Bridge.Invoke(parent, "Server", "Start", { Echo = 7 })
			assert(response.BoundMarker == "production-service-binding" and response.Echo == 7,
				"Bridge callback must execute against the actually bound service closure")
			local unknownOk = pcall(function()
				Bridge.Invoke(parent, "Server", "Unknown", {})
			end)
			assert(not unknownOk, "Unknown bridge commands must fail closed")
			owner:Destroy()
			owner:Destroy()
			assert(parent:FindFirstChild(Bridge.Names.Server) == nil,
				"Bridge cleanup must destroy its exact owned instance")

			local clientParent, clientOwner = installBridgeFixture(scope, "Client", function() return {} end)
			local clientBindable = assert(clientParent:FindFirstChild(Bridge.Names.Client))
			assert(clientParent:IsA("LocalScript") and clientBindable:IsA("BindableFunction")
				and clientBindable:GetAttribute("AudioManualQaBridgeSchema") == Bridge.SchemaVersion,
				"Client bridge must use the exact LocalScript placement, name, class, and schema")
			clientOwner:Destroy()

			for _, wrongSide in { "Server", "Client" } do
				local wrongParent = scope:Track(Instance.new(if wrongSide == "Server" then "LocalScript" else "Script"))
				wrongParent.Name = "Bootstrap"
				local wrongOk = pcall(function()
					Bridge.Install({
						Parent = wrongParent,
						Side = wrongSide,
						Commands = makeBridgeCommands(wrongSide, function() return {} end),
					})
				end)
				assert(not wrongOk, `{wrongSide} bridge must reject the opposite executable parent class`)
			end

			local missingParent = makeBridgeParent(scope, "Server")
			local missingCommands = makeBridgeCommands("Server", function() return {} end)
			missingCommands.Cleanup = nil
			local missingOk = pcall(function()
				Bridge.Install({ Parent = missingParent, Side = "Server", Commands = missingCommands })
			end)
			assert(not missingOk and missingParent:FindFirstChild(Bridge.Names.Server) == nil,
				"Bridge installation must reject an incomplete exact whitelist before creating an Instance")
			local extraParent = makeBridgeParent(scope, "Client")
			local extraCommands = makeBridgeCommands("Client", function() return {} end)
			extraCommands.Unreviewed = function() return {} end
			local extraOk = pcall(function()
				Bridge.Install({ Parent = extraParent, Side = "Client", Commands = extraCommands })
			end)
			assert(not extraOk and extraParent:FindFirstChild(Bridge.Names.Client) == nil,
				"Bridge installation must reject an extra command before creating an Instance")
		end,
	},
	{
		Name = "StudioBridgeRejectsUnsafeArgumentsAndResults",
		Callback = function(scope)
			local currentResult: any = {}
			local dispatchCount = 0
			local parent = installBridgeFixture(scope, "Server", function()
				dispatchCount += 1
				return currentResult
			end)
			local instanceValue = scope:Track(Instance.new("Folder"))
			local threadValue = coroutine.create(function() end)
			local cycle = {}
			cycle.Self = cycle
			local iterCalled = false
			local metatableValue = setmetatable({ Safe = true }, {
				__iter = function()
					iterCalled = true
					return next, {}
				end,
			})
			table.freeze(metatableValue)
			local unsafeValues = {
				Instance = instanceValue,
				Function = function() end,
				Thread = coroutine.create(function() end),
				RobloxValue = Vector3.new(1, 2, 3),
				Cycle = cycle,
				Metatable = metatableValue,
				NaN = 0 / 0,
				PositiveInfinity = math.huge,
				NegativeInfinity = -math.huge,
				Mixed = { [1] = "array", Named = "dictionary" },
				Sparse = { [2] = "gap" },
			}
			for identity, unsafeValue in unsafeValues do
				local beforeDispatch = dispatchCount
				local argumentOk = pcall(function()
					Bridge.Invoke(parent, "Server", "Start", { Value = unsafeValue })
				end)
				assert(not argumentOk and dispatchCount == beforeDispatch,
					`Unsafe bridge argument '{identity}' must fail before handler dispatch`)
				currentResult = { Value = unsafeValue }
				local resultOk = pcall(function()
					Bridge.Invoke(parent, "Server", "Start", {})
				end)
				assert(not resultOk, `Unsafe bridge result '{identity}' must fail closed`)
			end
			assert(not iterCalled, "Metatable rejection must occur before __iter can execute")
		end,
	},
	{
		Name = "StudioBridgeRawBindableBoundaryContract",
		Callback = function(scope)
			local dispatchCount = 0
			local receivedArguments: any = nil
			local parent = installBridgeFixture(scope, "Server", function(_command, arguments)
				dispatchCount += 1
				receivedArguments = arguments
				if arguments.Nested ~= nil then arguments.Nested.Value = 2 end
				return { Accepted = true }
			end)
			local bindable = parent:FindFirstChild(Bridge.Names.Server) :: BindableFunction
			assert(bindable ~= nil and bindable:IsA("BindableFunction"),
				"Raw bridge fixture must expose the installed BindableFunction")

			local instanceValue = scope:Track(Instance.new("Folder"))
			local cycle = {}
			cycle.Self = cycle
			local iterCalled = false
			local metatableValue = setmetatable({ Safe = true }, {
				__iter = function()
					iterCalled = true
					return next, {}
				end,
			})
			table.freeze(metatableValue)
			local deep = {}
			local cursor = deep
			for _ = 1, 12 do
				cursor.Child = {}
				cursor = cursor.Child
			end
			local manyNodes = {}
			for index = 1, 4097 do manyNodes[index] = index end
			local longString = string.rep("x", 4097)

			local unsafeValues = {
				{ Identity = "Instance", Value = instanceValue },
				{ Identity = "Function", Value = function() end },
				{ Identity = "RobloxValue", Value = Vector3.new(1, 2, 3) },
				{ Identity = "NaN", Value = 0 / 0 },
				{ Identity = "PositiveInfinity", Value = math.huge },
				{ Identity = "NegativeInfinity", Value = -math.huge },
				{ Identity = "Depth", Value = deep },
				{ Identity = "Nodes", Value = manyNodes },
				{ Identity = "String", Value = longString },
				{ Identity = "Key", Value = { [longString] = true } },
			}
			for _, unsafeCase in unsafeValues do
				local response = bindable:Invoke("Start", { Value = unsafeCase.Value })
				assert(response.Ok == false and response.ErrorCode == "InvalidArguments",
					`Raw unsafe bridge argument '{unsafeCase.Identity}' must return InvalidArguments`)
				assert(dispatchCount == 0,
					`Raw unsafe bridge argument '{unsafeCase.Identity}' must fail before handler dispatch`)
			end
			local cycleOk, cycleError = pcall(function()
				bindable:Invoke("Start", { Value = cycle })
			end)
			assert(not cycleOk and string.find(tostring(cycleError), "cyclic", 1, true) ~= nil
				and dispatchCount == 0,
				"Roblox BindableFunction must reject a cyclic raw table before OnInvoke dispatch")

			local threadArguments = { Value = threadValue }
			local threadResponse = bindable:Invoke("Start", threadArguments)
			assert(threadResponse.Ok == true and dispatchCount == 1
				and receivedArguments ~= threadArguments and receivedArguments.Value == nil,
				"Roblox BindableFunction must normalize a raw coroutine to nil before OnInvoke")

			local metatableArguments = { Value = metatableValue }
			local metatableResponse = bindable:Invoke("Start", metatableArguments)
			assert(metatableResponse.Ok == true and dispatchCount == 2,
				"Roblox BindableFunction must normalize the metatable-bearing raw table before OnInvoke")
			assert(table.isfrozen(metatableValue) and not iterCalled and receivedArguments ~= metatableArguments
				and receivedArguments.Value ~= metatableValue
				and getmetatable(receivedArguments.Value) == nil
				and not table.isfrozen(receivedArguments.Value),
				"Raw Bindable normalization must strip metatable/frozen state, avoid __iter, and copy the table")

			local mixedArguments = { Value = { [1] = "array", Named = "dictionary" } }
			local mixedResponse = bindable:Invoke("Start", mixedArguments)
			assert(mixedResponse.Ok == true and dispatchCount == 3
				and receivedArguments ~= mixedArguments
				and receivedArguments.Value[1] == "array"
				and receivedArguments.Value.Named == nil,
				"Roblox BindableFunction must copy a mixed raw table and drop its dictionary field before OnInvoke")

			local sparseArguments = { Value = { [2] = "gap" } }
			local sparseResponse = bindable:Invoke("Start", sparseArguments)
			assert(sparseResponse.Ok == true and dispatchCount == 4
				and receivedArguments ~= sparseArguments
				and receivedArguments.Value[2] == nil
				and receivedArguments.Value["2"] == "gap",
				"Roblox BindableFunction must copy a sparse raw table and stringify its key before OnInvoke")

			local original = { Nested = { Value = 1 } }
			local accepted = bindable:Invoke("Start", original)
			assert(accepted.Ok == true and accepted.Result.Accepted == true and dispatchCount == 5,
				"Raw safe bridge argument must reach the handler after the normalized boundary cases")
			assert(original.Nested.Value == 1 and receivedArguments ~= original
				and receivedArguments.Nested ~= original.Nested,
				"Installed OnInvoke sanitizer must deep-copy raw arguments before handler mutation")
		end,
	},
	{
		Name = "StudioBridgeRejectsEveryPayloadLimitInBothDirections",
		Callback = function(scope)
			local currentResult: any = {}
			local parent = installBridgeFixture(scope, "Server", function()
				return currentResult
			end)
			local deep = {}
			local cursor = deep
			for _ = 1, 12 do
				cursor.Child = {}
				cursor = cursor.Child
			end
			local manyNodes = {}
			for index = 1, 4097 do manyNodes[index] = index end
			local longString = string.rep("x", 4097)
			local longKey = { [longString] = true }
			for identity, unsafeValue in {
				Depth = deep,
				Nodes = manyNodes,
				String = longString,
				Key = longKey,
			} do
				local argumentOk = pcall(function()
					Bridge.Invoke(parent, "Server", "Start", { Value = unsafeValue })
				end)
				assert(not argumentOk, `Over-limit bridge argument '{identity}' must fail closed`)
				currentResult = { Value = unsafeValue }
				local resultOk = pcall(function()
					Bridge.Invoke(parent, "Server", "Start", {})
				end)
				assert(not resultOk, `Over-limit bridge result '{identity}' must fail closed`)
			end
		end,
	},
	{
		Name = "StudioBridgeDeepCopiesBothDirections",
		Callback = function(scope)
			local receivedArguments: any = nil
			local retainedResult: any = nil
			local parent = installBridgeFixture(scope, "Server", function(_command, arguments)
				receivedArguments = arguments
				arguments.Nested.Value = 2
				retainedResult = { Nested = { Value = 3 } }
				return retainedResult
			end)
			local original = { Nested = { Value = 1 } }
			local response = Bridge.Invoke(parent, "Server", "Start", original)
			assert(original.Nested.Value == 1 and receivedArguments ~= original
				and receivedArguments.Nested ~= original.Nested,
				"Handler mutation must not alias or modify the caller's argument graph")
			assert(response ~= retainedResult and response.Nested ~= retainedResult.Nested,
				"Caller result must not alias the handler-owned result graph")
			response.Nested.Value = 4
			assert(retainedResult.Nested.Value == 3,
				"Caller mutation must not modify the handler-owned result graph")
			original.Nested.Value = 5
			assert(receivedArguments.Nested.Value == 2,
				"Post-call caller mutation must not modify the handler argument copy")
		end,
	},
	{
		Name = "LiveAssetIdentityPassesOnlyExactDescriptorsAndCatalog",
		Callback = function(scope)
			local assets, catalog = makeLiveFixture(scope)
			local ok, records, reason = Plan.ValidateLiveAssets(catalog, assets)
			assert(ok and reason == nil and #records == 3, "Exact live fixture must pass")
			local shared = assert(assets:FindFirstChild("Shared"))
			local sounds = assert(shared:FindFirstChild("Sounds"))
			local music = assert(sounds:FindFirstChild("Music"))
			local prayer = assert(music:FindFirstChild("祈りの川")) :: Sound
			prayer.SoundId = "rbxassetid://1"
			local mismatch, partial, mismatchReason = Plan.ValidateLiveAssets(catalog, assets)
			assert(not mismatch and #partial == 2, "SoundId mismatch must fail closed at exact descriptor")
			assert(string.find(mismatchReason or "", "SoundId mismatch", 1, true) ~= nil, "Mismatch reason must identify SoundId")
		end,
	},
	{
		Name = "MandatoryStudioObservationsPresent",
		Callback = function()
			local expected = {
				"Studio-E2E-AUDIO-01/LocalOnly",
				"Studio-E2E-AUDIO-01/HybridPrediction",
				"Studio-E2E-AUDIO-01/ServerVariantOnce",
				"Studio-E2E-AUDIO-01/ServerSingleAudibleReplication",
				"Studio-E2E-AUDIO-01/HybridNoServerPlayer",
				"Studio-E2E-AUDIO-02/NonSpatialInvariant",
				"Studio-E2E-AUDIO-02/PointAttenuation",
				"Studio-E2E-AUDIO-02/AttachedFollowOrientation",
				"Studio-E2E-AUDIO-02/ServerAttachedReplication",
				"Studio-E2E-AUDIO-02/CharacterPositionCameraOrientation",
				"Studio-E2E-AUDIO-03/CategoryIsolation",
				"Studio-E2E-AUDIO-03/ClientMusicSettingsSave",
				"Studio-E2E-AUDIO-03/IndependentFaders",
				"Studio-E2E-AUDIO-04/IndependentMusicStacks",
				"Studio-E2E-AUDIO-04/BackgroundForegroundLifo",
				"Studio-E2E-AUDIO-05/CleanGraphRuntime",
			}
			assert(#Plan.Scenarios == #expected, "Unexpected Studio scenario count")
			for _, id in expected do assert(Plan.GetScenario(id) ~= nil, `Missing scenario '{id}'`) end
			local ac69 = Plan.GetScenario("Studio-E2E-AUDIO-05")
			assert(ac69 ~= nil and ac69.Id == "Studio-E2E-AUDIO-05/CleanGraphRuntime",
				"Exact accepted AC-069 Studio evidence anchor must resolve to its unique scenario")
			assert(Plan.AcceptanceCoverage[69].StudioEvidenceAnchor == "Studio-E2E-AUDIO-05",
				"PRD-AC-069 coverage must expose the frozen evidence identity")
		end,
	},
	{
		Name = "ReconnectScenarioExplicitlyRestartsClientDriver",
		Callback = function()
			local scenario = Plan.GetScenario("Studio-E2E-AUDIO-03/ClientMusicSettingsSave")
			local reconnectIndex = nil
			local startIndex = nil
			local snapshotIndex = nil
			for index, scenarioStep in scenario.Steps do
				if scenarioStep.Side == "Operator" and string.find(scenarioStep.Instruction, "переподключ", 1, true) then
					reconnectIndex = index
				elseif scenarioStep.Side == "ClientA" and scenarioStep.Action == "start" then
					startIndex = index
				elseif startIndex ~= nil and scenarioStep.Side == "ClientA" and scenarioStep.Action == "snapshot" then
					snapshotIndex = index
					break
				end
			end
			assert(reconnectIndex ~= nil and startIndex ~= nil and snapshotIndex ~= nil
				and reconnectIndex < startIndex and startIndex < snapshotIndex,
				"Reconnect must explicitly rerun Client.Start before the first post-rejoin snapshot")
		end,
	},
	{
		Name = "EveryPublicCapabilityHasEvidence",
		Callback = function()
			local seen = {}
			for _, capability in Plan.PublicCapabilities do
				assert(not seen[capability.Id], `Duplicate capability '{capability.Id}'`)
				assert(#capability.Evidence > 0, `Capability '{capability.Id}' has no evidence`)
				seen[capability.Id] = true
			end
			for _, required in {
				"Client.PlayLocal",
				"Client.PlayLocalAt",
				"Client.PlayLocalAttached",
				"Client.PlayHybrid",
				"Client.PlayHybridAt",
				"Server.Play",
				"Server.PlayAt",
				"Server.PlayAttached",
				"Music.StopAllMusic",
				"AudioSettings.SaveRestoreRollback",
			} do
				assert(seen[required], `Missing public capability '{required}'`)
			end
		end,
	},
	{
		Name = "CanonicalPlanIsImmutable",
		Callback = function()
			local scenario = Plan.Scenarios[1]
			local scenarioOk = pcall(function() scenario.Title = "mutated" end)
			local stepsOk = pcall(function() table.insert(scenario.Steps, scenario.Steps[1]) end)
			local argsScenario = Plan.GetScenario("Studio-E2E-AUDIO-03/CategoryIsolation")
			local argsOk = pcall(function() argsScenario.Steps[1].Args.Level = 1 end)
			local assetOk = pcall(function() Plan.LiveAssets.CartoonBubble.AssetId = "1" end)
			assert(not scenarioOk and not stepsOk and not argsOk and not assetOk, "Canonical plan tables must be frozen recursively")
		end,
	},
	{
		Name = "IncompleteReportCannotPass",
		Callback = function()
			local result = Plan.Evaluate({})
			assert(result.Overall == "PENDING" and result.Pending == #Plan.Scenarios, "Empty report must stay pending")
		end,
	},
	{
		Name = "HumanPassRequiresExplicitOperatorProvenance",
		Callback = function()
			local scenario = Plan.GetScenario("Studio-E2E-AUDIO-01/LocalOnly")
			assert(scenario.HumanRequired, "Fixture must require human evidence")
			local result = Plan.Evaluate({
				[scenario.Id] = { Status = "PASS", ObjectivePassed = true, HumanPassed = true },
			})
			assert(result.Overall == "FAIL" and result.Failed == 1,
				"A bare boolean without operator evidence metadata must fail validation")
			assert(result.InvalidRecords[1] == scenario.Id, "Invalid scenario identity must be reported")
			local evidence = {
				Source = "OperatorStatement",
				Confirmed = true,
				Observation = "Operator explicitly reported the expected audible distinction.",
			}
			assert(Contracts.IsOperatorEvidence(evidence), "Explicit operator provenance fixture must validate")
			local evidenced = Plan.Evaluate({
				[scenario.Id] = { Status = "PASS", ObjectivePassed = true, HumanEvidence = evidence },
			})
			assert(evidenced.Passed == 1 and evidenced.Failed == 0,
				"Explicit positive operator evidence may satisfy the hearing field")
		end,
	},
	{
		Name = "BlockedAndFailedPrecedence",
		Callback = function()
			local blockedId = Plan.Scenarios[1].Id
			local failedId = Plan.Scenarios[2].Id
			local blocked = Plan.Evaluate({
				[blockedId] = { Status = "BLOCKED" },
			})
			assert(blocked.Overall == "BLOCKED", "Blocked report must remain blocked when no failure exists")
			local failed = Plan.Evaluate({
				[blockedId] = { Status = "BLOCKED" },
				[failedId] = { Status = "FAIL", ObjectivePassed = false },
			})
			assert(failed.Overall == "FAIL", "Failure must take precedence over blocked/pending")
		end,
	},
	{
		Name = "CompleteEvidencePasses",
		Callback = function()
			local records = {}
			for _, scenario in Plan.Scenarios do
				records[scenario.Id] = {
					Status = "PASS",
					ObjectivePassed = true,
					HumanEvidence = if scenario.HumanRequired then {
						Source = "OperatorStatement",
						Confirmed = true,
						Observation = "Explicit operator confirmation fixture.",
					} else nil,
				}
			end
			local result = Plan.Evaluate(records)
			assert(result.Overall == "PASS", "Complete valid evidence must pass")
			assert(result.Passed == #Plan.Scenarios and result.Pending == 0, "Every scenario must be counted")
		end,
	},
}

local Runner = {}

function Runner.runAll()
	return TestHarness.runAll("AudioManualQaTestRunner", tests, 5)
end

return Runner
