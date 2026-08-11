--!strict

--[[
	Canonical plan for collaborative Audio Studio QA.

	The plan deliberately keeps objective runtime evidence separate from the
	human hearing observation. A scenario cannot pass unless every required
	observation is present. Deterministic runners remain the evidence owner for
	failure paths and boundaries that should not be exercised in a live session.
]]

local Contracts = require(script.Parent.AudioManualQaContracts)

local Plan = {}

local LIVE_ASSET_ORDER = { "CartoonBubble", "OldCarEngine", "PrayerRiver" }

local LIVE_ASSETS = {
	CartoonBubble = {
		CueId = "Template.SFX.CartoonBubble",
		VariantId = "Default",
		PlayerType = "SFX",
		AssetId = "5852470908",
		ContentId = "rbxassetid://5852470908",
		DescriptorPath = "Shared/Sounds/SFX/Cartoon bubble button Sound",
		Volume01 = 0.8,
		PlaybackSpeed = 1,
		Looping = false,
		Preload = true,
		AllowClientHybrid = true,
	},
	OldCarEngine = {
		CueId = "Template.World.OldCarEngine",
		VariantId = "Default",
		PlayerType = "World",
		AssetId = "137048982817372",
		ContentId = "rbxassetid://137048982817372",
		DescriptorPath = "Shared/Sounds/SFX/engine sound for old cars",
		Volume01 = 0.8,
		PlaybackSpeed = 1,
		Looping = false,
		Preload = true,
		SpatialProfileId = "WorldDefault",
		AllowClientHybrid = true,
	},
	PrayerRiver = {
		CueId = "Template.Music.PrayerRiver",
		VariantId = "Default",
		PlayerType = "Music",
		AssetId = "91760644839532",
		ContentId = "rbxassetid://91760644839532",
		DescriptorPath = "Shared/Sounds/Music/祈りの川",
		Volume01 = 0.5,
		PlaybackSpeed = 1,
		Looping = true,
		Preload = true,
		AllowClientHybrid = false,
	},
}

local VALID_SIDES = {
	Server = true,
	ClientA = true,
	ClientB = true,
	Operator = true,
}

local CLIENT_ACTIONS = {
	cleanup = true,
	create_attached_target = true,
	create_point_marker = true,
	move_attached_target = true,
	play_hybrid_at_marker = true,
	play_hybrid_sfx = true,
	play_local_at_marker = true,
	play_local_attached = true,
	play_local_sfx = true,
	play_music = true,
	remove_attached_target = true,
	restore_settings = true,
	set_enabled = true,
	set_level = true,
	snapshot = true,
	start = true,
	stop_all_music = true,
	stop_handle = true,
	validate_invalid_settings_snapshot = true,
}

local SERVER_ACTIONS = {
	cleanup = true,
	create_attached_target = true,
	create_point_marker = true,
	move_attached_target = true,
	play_at_marker = true,
	play_attached = true,
	play_sfx = true,
	remove_attached_target = true,
	snapshot = true,
	stop_handle = true,
}

local COLLABORATIVE_ACCEPTANCE = {
	[2] = true,
	[3] = true,
	[5] = true,
	[7] = true,
	[9] = true,
	[18] = true,
	[27] = true,
	[50] = true,
	[51] = true,
	[53] = true,
	[55] = true,
	[56] = true,
	[61] = true,
	[68] = true,
	[69] = true,
}

local function step(side: string, action: string, instruction: string, args: any?): any
	if args ~= nil then table.freeze(args) end
	return table.freeze({ Side = side, Action = action, Args = args, Instruction = instruction })
end

local scenarios = {
	{
		Id = "Studio-E2E-AUDIO-01/LocalOnly",
		Title = "Локальный звук не покидает клиента",
		HumanRequired = true,
		Acceptance = { 7 },
		Steps = {
			step("Operator", "", "На Client A приготовьтесь подтвердить один короткий SFX; на Client B не должно быть звука."),
			step("ClientA", "play_local_sfx", "Запустить локальный SFX.", { Label = "local-only-1" }),
			step("ClientA", "snapshot", "Зафиксировать локальный lease и маршрут SFX."),
			step("ClientB", "snapshot", "Подтвердить отсутствие локального lease."),
			step("Server", "snapshot", "Подтвердить отсутствие server playback."),
		},
	},
	{
		Id = "Studio-E2E-AUDIO-01/HybridPrediction",
		Title = "Hybrid prediction и доставка другому клиенту",
		HumanRequired = true,
		Acceptance = { 9 },
		Steps = {
			step("Operator", "", "Слушайте оба клиента: для каждого запуска initiator и второй ready-клиент должны услышать по одному cue."),
			step("ClientA", "play_hybrid_sfx", "Отправить hybrid intent с локальным prediction.", { Label = "hybrid-none-1" }),
			step("ClientA", "create_point_marker", "Создать фиксированную точку для spatial hybrid.", { Distance = 12 }),
			step("ClientA", "play_hybrid_at_marker", "Повторить hybrid через point DTO.", { Label = "hybrid-point-1" }),
			step("ClientA", "snapshot", "Зафиксировать prediction initiator."),
			step("ClientB", "snapshot", "Зафиксировать полученную presentation."),
			step("Server", "snapshot", "Подтвердить отсутствие server AudioPlayer."),
		},
	},
	{
		Id = "Studio-E2E-AUDIO-01/ServerVariantOnce",
		Title = "Один server-side выбор варианта",
		HumanRequired = true,
		Acceptance = { 18 },
		Steps = {
			step("Operator", "", "Оба клиента должны услышать один и тот же короткий вариант."),
			step("Server", "play_sfx", "Запустить именованный server SFX один раз.", { Label = "server-variant-1" }),
			step("Server", "snapshot", "Зафиксировать один server lease и exact Asset."),
			step("ClientA", "snapshot", "Зафиксировать replicated server playback."),
			step("ClientB", "snapshot", "Зафиксировать тот же replicated playback."),
		},
	},
	{
		Id = "Studio-E2E-AUDIO-01/ServerSingleAudibleReplication",
		Title = "Server playback слышен один раз на каждом клиенте",
		HumanRequired = true,
		Acceptance = { 50 },
		Steps = {
			step("Operator", "", "Считайте воспроизведения: ровно одно на Client A и ровно одно на Client B."),
			step("Server", "play_sfx", "Создать единственный server-owned playback.", { Label = "server-single-1" }),
			step("Server", "snapshot", "Проверить единичный root, не per-recipient roots."),
		},
	},
	{
		Id = "Studio-E2E-AUDIO-01/HybridNoServerPlayer",
		Title = "Hybrid не создаёт server AudioPlayer и не даёт echo",
		HumanRequired = true,
		Acceptance = { 61 },
		Steps = {
			step("Operator", "", "Client A и Client B должны услышать по одному звуку без дубля."),
			step("ClientA", "play_hybrid_sfx", "Запустить hybrid prediction.", { Label = "hybrid-no-server-1" }),
			step("Server", "snapshot", "Проверить нулевой delta server playback."),
			step("ClientA", "snapshot", "Проверить один initiator playback."),
			step("ClientB", "snapshot", "Проверить один recipient playback."),
		},
	},
	{
		Id = "Studio-E2E-AUDIO-02/NonSpatialInvariant",
		Title = "Непространственный SFX не зависит от позиции и камеры",
		HumanRequired = true,
		Acceptance = { 2 },
		Steps = {
			step("ClientA", "play_local_sfx", "Прослушать реальный CartoonBubble SFX в исходной позиции.", { Label = "sfx-before-move" }),
			step("Operator", "", "Переместите персонажа далеко и разверните камеру."),
			step("ClientA", "play_local_sfx", "Повторить тот же реальный CartoonBubble SFX.", { Label = "sfx-after-move" }),
			step("ClientA", "snapshot", "Проверить прямой SFX route без emitter/anchor."),
		},
	},
	{
		Id = "Studio-E2E-AUDIO-02/PointAttenuation",
		Title = "Point attenuation относительно фиксированной точки",
		HumanRequired = true,
		Acceptance = { 3 },
		Steps = {
			step("ClientA", "create_point_marker", "Создать видимый фиксированный marker.", { Distance = 12 }),
			step("Operator", "", "Встаньте рядом с marker и приготовьтесь слушать."),
			step("ClientA", "play_local_at_marker", "Проиграть World cue рядом.", { Label = "point-near" }),
			step("Operator", "", "Отойдите от marker на большое расстояние, не меняя marker."),
			step("ClientA", "play_local_at_marker", "Повторить World cue из той же точки.", { Label = "point-far" }),
			step("ClientA", "snapshot", "Проверить неподвижный SpatialAnchor, три direct children и nondirectional profile."),
			step("Server", "create_point_marker", "Создать server-owned marker для общей point presentation."),
			step("Server", "play_at_marker", "Проверить server PlayAt на обоих клиентах.", { Label = "server-point-1" }),
			step("Server", "snapshot", "Зафиксировать единственный server SpatialAnchor с одной native replicated lease."),
		},
	},
	{
		Id = "Studio-E2E-AUDIO-02/AttachedFollowOrientation",
		Title = "Attached source следует позиции и ориентации",
		HumanRequired = true,
		Acceptance = { 3 },
		Steps = {
			step("ClientA", "create_attached_target", "Создать видимую локальную цель.", { Distance = 12 }),
			step("ClientA", "play_local_attached", "Привязать World cue к цели.", { Label = "attached-before" }),
			step("ClientA", "snapshot", "Зафиксировать исходный full transform SpatialAnchor до движения."),
			step("ClientA", "move_attached_target", "Переместить и повернуть цель.", { X = 8, YawDegrees = 90 }),
			step("ClientA", "play_local_attached", "Повторить cue в новой позиции той же цели.", { Label = "attached-after" }),
			step("ClientA", "snapshot", "Проверить обновлённые position и orientation того же SpatialAnchor."),
			step("ClientA", "remove_attached_target", "Удалить цель и проверить освобождение lease."),
		},
	},
	{
		Id = "Studio-E2E-AUDIO-02/ServerAttachedReplication",
		Title = "Server attached source реплицируется двум клиентам",
		HumanRequired = true,
		Acceptance = { 51 },
		Steps = {
			step("Server", "create_attached_target", "Создать server-owned видимую цель."),
			step("Server", "play_attached", "Привязать server World cue.", { Label = "server-attached-before" }),
			step("Server", "snapshot", "Зафиксировать исходный full transform единственного server SpatialAnchor."),
			step("Server", "move_attached_target", "Переместить и повернуть цель.", { X = 10, YawDegrees = 90 }),
			step("Server", "play_attached", "Повторить cue после движения той же цели.", { Label = "server-attached-after" }),
			step("ClientA", "snapshot", "Проверить replicated SpatialAnchor subtree и обновлённый full transform."),
			step("ClientB", "snapshot", "Проверить ту же native replicated SpatialAnchor lease без mirror/fanout."),
			step("Server", "remove_attached_target", "Удалить цель и освободить lease."),
		},
	},
	{
		Id = "Studio-E2E-AUDIO-02/CharacterPositionCameraOrientation",
		Title = "Listener: позиция персонажа, ориентация камеры и respawn",
		HumanRequired = false,
		Acceptance = { 55 },
		Steps = {
			step("ClientA", "snapshot", "Зафиксировать нулевые position/rotation deltas."),
			step("Operator", "", "Переместитесь, поверните камеру, измените zoom и сделайте Reset Character."),
			step("ClientA", "snapshot", "Проверить rebinding и новые нулевые deltas."),
			step("ClientB", "snapshot", "Проверить независимый listener второго клиента."),
		},
	},
	{
		Id = "Studio-E2E-AUDIO-03/CategoryIsolation",
		Title = "Изоляция SFX от Music и остальных category faders",
		HumanRequired = true,
		Acceptance = { 5 },
		Steps = {
			step("ClientA", "set_enabled", "Отключить только SFX.", { Category = "SFX", Enabled = false }),
			step("ClientA", "play_local_sfx", "Реальный CartoonBubble не должен быть слышен.", { Label = "muted-sfx" }),
			step("ClientA", "play_music", "Реальный PrayerRiver должен остаться слышен.", { Label = "category-music", Strategy = "Instant" }),
			step("ClientA", "snapshot", "Проверить изменение только SFX fader и неизменные UI/World/Music routes."),
			step("ClientA", "stop_handle", "Остановить Music после сравнения.", { Label = "category-music", Strategy = "Instant" }),
			step("ClientA", "restore_settings", "Восстановить исходные settings."),
		},
	},
	{
		Id = "Studio-E2E-AUDIO-03/ClientMusicSettingsSave",
		Title = "Client settings сохраняются и откатываются безопасно",
		HumanRequired = true,
		Acceptance = { 27 },
		Steps = {
			step("ClientA", "set_level", "Изменить SFX level и сохранить snapshot через штатный save flow.", { Category = "SFX", Level = 0.25 }),
			step("ClientA", "set_enabled", "Изменить UI enabled.", { Category = "UI", Enabled = false }),
			step("Operator", "", "Выйдите и переподключитесь тем же игроком по согласованному save backend."),
			step("ClientA", "start", "После reconnect явно повторить Client.Start с тем же RunId и ClientA до snapshot."),
			step("ClientA", "snapshot", "Проверить восстановление до ready и сохранённые значения."),
			step("ClientB", "snapshot", "Проверить независимость настроек второго клиента."),
			step("ClientA", "validate_invalid_settings_snapshot", "Проверить live reject невалидного AudioSettings envelope и отсутствие mutation."),
		},
	},
	{
		Id = "Studio-E2E-AUDIO-03/IndependentFaders",
		Title = "У каждого клиента независимые faders",
		HumanRequired = true,
		Acceptance = { 56 },
		Steps = {
			step("ClientA", "set_level", "Установить Master level=0.2.", { Category = "Master", Level = 0.2 }),
			step("ClientB", "set_level", "Установить Music level=0.7.", { Category = "Music", Level = 0.7 }),
			step("ClientA", "snapshot", "Проверить только локальный Master."),
			step("ClientB", "snapshot", "Проверить только локальный Music."),
			step("ClientA", "restore_settings", "Восстановить settings Client A."),
			step("ClientB", "restore_settings", "Восстановить settings Client B."),
		},
	},
	{
		Id = "Studio-E2E-AUDIO-04/IndependentMusicStacks",
		Title = "Независимые Music stacks и LIFO",
		HumanRequired = true,
		Acceptance = { 53 },
		Steps = {
			step("ClientA", "play_music", "Push A с Instant и отличимой низкой скоростью.", { Label = "A", Strategy = "Instant", PlaybackSpeedMultiplier = 0.8 }),
			step("ClientA", "play_music", "Push B с SequentialFade.", { Label = "B", Strategy = "SequentialFade", PlaybackSpeedMultiplier = 1 }),
			step("ClientA", "play_music", "Push C с Crossfade и отличимой высокой скоростью.", { Label = "C", Strategy = "Crossfade", PlaybackSpeedMultiplier = 1.2 }),
			step("ClientA", "stop_handle", "Stop C; B должен возобновиться.", { Label = "C", Strategy = "Crossfade" }),
			step("ClientA", "stop_handle", "Stop B; A должен возобновиться.", { Label = "B", Strategy = "SequentialFade" }),
			step("ClientB", "snapshot", "Проверить отсутствие Music stack interference."),
			step("ClientA", "snapshot", "Проверить depth/top и единственный steady player."),
		},
	},
	{
		Id = "Studio-E2E-AUDIO-04/BackgroundForegroundLifo",
		Title = "Music LIFO переживает background/foreground",
		HumanRequired = true,
		Acceptance = { 68 },
		Steps = {
			step("ClientA", "play_music", "Push background A с отличимой низкой скоростью.", { Label = "background-A", Strategy = "Instant", PlaybackSpeedMultiplier = 0.85 }),
			step("ClientA", "play_music", "Push foreground B через Crossfade с отличимой высокой скоростью.", { Label = "foreground-B", Strategy = "Crossfade", PlaybackSpeedMultiplier = 1.15 }),
			step("Operator", "", "Сверните окно Client A, затем верните его на передний план."),
			step("ClientA", "stop_handle", "Stop B; должен возобновиться A.", { Label = "foreground-B", Strategy = "Crossfade" }),
			step("ClientA", "snapshot", "Проверить LIFO, позиции и отсутствие stale playback."),
			step("ClientA", "stop_all_music", "Проверить StopAll и нулевой Music active count."),
		},
	},
	{
		Id = "Studio-E2E-AUDIO-05/CleanGraphRuntime",
		EvidenceAnchor = "Studio-E2E-AUDIO-05",
		Title = "Чистый production graph и canonical acoustic property",
		HumanRequired = false,
		Acceptance = { 69 },
		Steps = {
			step("Server", "snapshot", "Проверить identity, Ready generation, routes и пустой playback baseline."),
			step("ClientA", "snapshot", "Проверить listener/output/faders и canonical acoustic flag."),
			step("ClientB", "snapshot", "Проверить независимый client graph."),
			step("Operator", "", "Agent проверяет server/client output: нет неожиданных Warning/Error."),
		},
	},
}

local publicCapabilities = {
	{ Id = "Client.PlayLocal", Evidence = { "LocalOnly", "NonSpatialInvariant", "AudioPlayback" } },
	{ Id = "Client.PlayLocalAt", Evidence = { "PointAttenuation", "AudioPlayback" } },
	{ Id = "Client.PlayLocalAttached", Evidence = { "AttachedFollowOrientation", "AudioPlayback" } },
	{ Id = "Client.PlayHybrid", Evidence = { "HybridPrediction", "HybridNoServerPlayer", "AudioIntegration" } },
	{ Id = "Client.PlayHybridAt", Evidence = { "HybridPrediction", "AudioIntegration" } },
	{ Id = "Server.Play", Evidence = { "ServerVariantOnce", "ServerSingleAudibleReplication", "AudioPlayback" } },
	{ Id = "Server.PlayAt", Evidence = { "PointAttenuation", "AudioPlayback" } },
	{ Id = "Server.PlayAttached", Evidence = { "ServerAttachedReplication", "AudioPlayback" } },
	{ Id = "PlaybackHandle.IsActiveStop", Evidence = { "AudioPlayback" } },
	{ Id = "Music.PlayMusic.Instant", Evidence = { "IndependentMusicStacks", "AudioPlayback" } },
	{ Id = "Music.PlayMusic.SequentialFade", Evidence = { "IndependentMusicStacks", "AudioPlayback" } },
	{ Id = "Music.PlayMusic.Crossfade", Evidence = { "BackgroundForegroundLifo", "AudioPlayback" } },
	{ Id = "Music.StackStopResume", Evidence = { "IndependentMusicStacks", "BackgroundForegroundLifo", "AudioPlayback" } },
	{ Id = "Music.StopAllMusic", Evidence = { "BackgroundForegroundLifo", "AudioPlayback" } },
	{ Id = "AudioSettings.GetSetLevel", Evidence = { "CategoryIsolation", "IndependentFaders", "AudioIntegration" } },
	{ Id = "AudioSettings.GetSetEnabled", Evidence = { "CategoryIsolation", "ClientMusicSettingsSave", "AudioIntegration" } },
	{ Id = "AudioSettings.SaveRestoreRollback", Evidence = { "ClientMusicSettingsSave", "AudioIntegration" } },
	{ Id = "AudioGraph.ListenerRouting", Evidence = { "CharacterPositionCameraOrientation", "CleanGraphRuntime", "AudioPlayback" } },
	{ Id = "AudioGraph.UIRouteBoundary", Evidence = { "CleanGraphRuntime", "AudioPlayback" } },
	{ Id = "Catalog.LiveDescriptorIdentity", Evidence = { "LiveAssetIdentity", "AudioCatalog" } },
	{ Id = "CatalogConfigCsvPreloadSelection", Evidence = { "AudioCatalog", "AudioStatic" } },
	{ Id = "PoolsBudgetsGenerationsCleanup", Evidence = { "AudioPlayback", "AudioConfig" } },
	{ Id = "CommunicationHybridValidationRateFanout", Evidence = { "HybridPrediction", "HybridNoServerPlayer", "AudioIntegration" } },
}

local acceptanceCoverage = {}
for number = 1, 79 do
	local id = string.format("PRD-AC-%03d", number)
	acceptanceCoverage[number] = table.freeze({
		Id = id,
		Mode = if COLLABORATIVE_ACCEPTANCE[number] then "CollaborativeStudio" else "DeterministicAutomated",
		EvidenceSource = "technical-specification.md#911-acceptance-evidence-matrix",
		StudioEvidenceAnchor = if number == 69 then "Studio-E2E-AUDIO-05" else nil,
	})
end

local scenarioById = {}
local scenarioByEvidenceAnchor = {}
for _, scenario in scenarios do
	scenarioById[scenario.Id] = scenario
	if scenario.EvidenceAnchor ~= nil then scenarioByEvidenceAnchor[scenario.EvidenceAnchor] = scenario end
end

local function validate(): (boolean, string?)
	local seenAssetIds = {}
	local seenDescriptorPaths = {}
	for _, key in LIVE_ASSET_ORDER do
		local asset = LIVE_ASSETS[key]
		if asset == nil or asset.CueId == "" or asset.VariantId == "" or asset.AssetId == ""
			or asset.ContentId ~= "rbxassetid://" .. asset.AssetId
			or string.sub(asset.DescriptorPath, 1, 14) ~= "Shared/Sounds/"
		then
			return false, `Invalid live Audio asset definition '{key}'`
		end
		if seenAssetIds[asset.AssetId] or seenDescriptorPaths[asset.DescriptorPath] then
			return false, `Duplicate live Audio asset identity '{key}'`
		end
		seenAssetIds[asset.AssetId] = true
		seenDescriptorPaths[asset.DescriptorPath] = true
	end
	if #acceptanceCoverage ~= 79 then
		return false, "Acceptance coverage must contain PRD-AC-001 through PRD-AC-079"
	end
	for number = 1, 79 do
		local record = acceptanceCoverage[number]
		if record == nil or record.Id ~= string.format("PRD-AC-%03d", number) then
			return false, `Acceptance coverage is missing index {number}`
		end
	end

	local seenScenarios = {}
	local seenEvidenceAnchors = {}
	local collaborativeSeen = {}
	for _, scenario in scenarios do
		if seenScenarios[scenario.Id] then return false, `Duplicate scenario '{scenario.Id}'` end
		seenScenarios[scenario.Id] = true
		if scenario.EvidenceAnchor ~= nil then
			if seenEvidenceAnchors[scenario.EvidenceAnchor] then
				return false, `Duplicate Studio evidence anchor '{scenario.EvidenceAnchor}'`
			end
			seenEvidenceAnchors[scenario.EvidenceAnchor] = true
		end
		if #scenario.Steps == 0 or #scenario.Acceptance == 0 then return false, `Incomplete scenario '{scenario.Id}'` end
		for _, acceptance in scenario.Acceptance do
			if not COLLABORATIVE_ACCEPTANCE[acceptance] then
				return false, `Scenario '{scenario.Id}' maps non-collaborative AC {acceptance}`
			end
			collaborativeSeen[acceptance] = true
		end
		for _, scenarioStep in scenario.Steps do
			if not VALID_SIDES[scenarioStep.Side] then return false, `Unknown side '{scenarioStep.Side}'` end
			if scenarioStep.Side == "Server" and not SERVER_ACTIONS[scenarioStep.Action] then
				return false, `Unknown server action '{scenarioStep.Action}'`
			end
			if (scenarioStep.Side == "ClientA" or scenarioStep.Side == "ClientB")
				and not CLIENT_ACTIONS[scenarioStep.Action]
			then
				return false, `Unknown client action '{scenarioStep.Action}'`
			end
		end
	end
	for acceptance in COLLABORATIVE_ACCEPTANCE do
		if not collaborativeSeen[acceptance] then return false, `Collaborative AC {acceptance} has no scenario` end
	end
	if acceptanceCoverage[69].StudioEvidenceAnchor ~= "Studio-E2E-AUDIO-05"
		or scenarioByEvidenceAnchor["Studio-E2E-AUDIO-05"] == nil
	then
		return false, "PRD-AC-069 must expose the exact Studio-E2E-AUDIO-05 evidence anchor"
	end

	local capabilities = {}
	for _, capability in publicCapabilities do
		if capabilities[capability.Id] or #capability.Evidence == 0 then
			return false, `Invalid capability mapping '{capability.Id}'`
		end
		capabilities[capability.Id] = true
	end
	return true, nil
end

function Plan.GetScenario(id: string): any?
	return scenarioById[id] or scenarioByEvidenceAnchor[id]
end

function Plan.Validate(): (boolean, string?)
	return validate()
end

function Plan.ValidateLiveAssets(catalog: any, assetsRoot: Instance): (boolean, { any }, string?)
	if typeof(catalog) ~= "table" or typeof(catalog.GetNamedVariant) ~= "function"
		or typeof(catalog.Resolve) ~= "function"
	then
		return false, {}, "Production Audio catalog is unavailable"
	end
	if typeof(assetsRoot) ~= "Instance" then
		return false, {}, "ReplicatedStorage.Assets is unavailable"
	end

	local records = {}
	for _, key in LIVE_ASSET_ORDER do
		local expected = LIVE_ASSETS[key]
		local descriptor: Instance? = assetsRoot
		for _, segment in string.split(expected.DescriptorPath, "/") do
			descriptor = if descriptor then descriptor:FindFirstChild(segment) else nil
		end
		if descriptor == nil or not descriptor:IsA("Sound") then
			return false, records, `Missing exact Sound descriptor '{expected.DescriptorPath}'`
		end
		if descriptor.SoundId ~= expected.ContentId then
			return false, records, `SoundId mismatch for '{expected.DescriptorPath}'`
		end

		local variant = catalog:GetNamedVariant(expected.CueId, expected.VariantId)
		if variant == nil then
			return false, records, `Missing catalog pair '{expected.CueId}/{expected.VariantId}'`
		end
		if variant.CueId ~= expected.CueId or variant.VariantId ~= expected.VariantId
			or variant.PlayerType ~= expected.PlayerType or variant.AssetId ~= expected.AssetId
			or variant.ContentId ~= expected.ContentId or variant.ResourcePath ~= expected.DescriptorPath
			or variant.Volume01 ~= expected.Volume01 or variant.PlaybackSpeed ~= expected.PlaybackSpeed
			or variant.Looping ~= expected.Looping or variant.Preload ~= expected.Preload
			or variant.SpatialProfileId ~= expected.SpatialProfileId
			or variant.AllowClientHybrid ~= expected.AllowClientHybrid
		then
			return false, records, `Catalog identity mismatch for '{expected.CueId}/{expected.VariantId}'`
		end
		if catalog:Resolve({ AssetId = expected.AssetId }) ~= variant
			or catalog:Resolve({ ResourcePath = expected.DescriptorPath }) ~= variant
		then
			return false, records, `Exact catalog refs do not resolve '{expected.CueId}/{expected.VariantId}'`
		end
		table.insert(records, {
			Key = key,
			CueId = expected.CueId,
			VariantId = expected.VariantId,
			PlayerType = expected.PlayerType,
			AssetId = expected.AssetId,
			ContentId = expected.ContentId,
			DescriptorPath = expected.DescriptorPath,
			DescriptorLooped = descriptor.Looped,
			CatalogVolume01 = variant.Volume01,
			CatalogPlaybackSpeed = variant.PlaybackSpeed,
			CatalogLooping = variant.Looping,
			CatalogPreload = variant.Preload,
			CatalogSpatialProfileId = variant.SpatialProfileId,
			AllowClientHybrid = variant.AllowClientHybrid,
			ExactPairResolved = true,
			ExactAssetRefResolved = true,
			ExactResourceRefResolved = true,
		})
	end
	return true, records, nil
end

function Plan.Evaluate(records: { [string]: any }): any
	local passed = 0
	local failed = 0
	local blocked = 0
	local pending = 0
	local invalid = {}
	for _, scenario in scenarios do
		local record = records[scenario.Id]
		if record == nil then
			pending += 1
		elseif record.Status == "BLOCKED" then
			blocked += 1
		elseif record.Status == "FAIL" then
			failed += 1
		elseif record.Status == "PASS" and record.ObjectivePassed == true
			and (not scenario.HumanRequired
				or (Contracts.IsOperatorEvidence(record.HumanEvidence) and record.HumanEvidence.Confirmed == true))
		then
			passed += 1
		else
			failed += 1
			table.insert(invalid, scenario.Id)
		end
	end
	local overall = if failed > 0 then "FAIL"
		elseif blocked > 0 then "BLOCKED"
		elseif pending > 0 then "PENDING"
		else "PASS"
	return {
		Overall = overall,
		Passed = passed,
		Failed = failed,
		Blocked = blocked,
		Pending = pending,
		Total = #scenarios,
		InvalidRecords = invalid,
	}
end

local valid, validationError = validate()
assert(valid, validationError)

for _, scenario in scenarios do
	table.freeze(scenario.Acceptance)
	table.freeze(scenario.Steps)
	table.freeze(scenario)
end
for _, capability in publicCapabilities do
	table.freeze(capability.Evidence)
	table.freeze(capability)
end

for _, key in LIVE_ASSET_ORDER do
	table.freeze(LIVE_ASSETS[key])
end
table.freeze(LIVE_ASSET_ORDER)
table.freeze(LIVE_ASSETS)

Plan.SchemaVersion = 3
Plan.Scenarios = table.freeze(scenarios)
Plan.PublicCapabilities = table.freeze(publicCapabilities)
Plan.AcceptanceCoverage = table.freeze(acceptanceCoverage)
Plan.ClientActions = table.freeze(CLIENT_ACTIONS)
Plan.ServerActions = table.freeze(SERVER_ACTIONS)
Plan.LiveAssetOrder = LIVE_ASSET_ORDER
Plan.LiveAssets = LIVE_ASSETS

return table.freeze(Plan)
