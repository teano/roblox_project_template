--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local TeleportProtocol = require(ReplicatedStorage.Shared.Teleport.TeleportProtocol)
local CommunicationProtocol = require(ReplicatedStorage.Shared.Communication.CommunicationProtocol)
local CommunicationConfig = require(ReplicatedStorage.Shared.Communication.CommunicationConfig)
local CommunicationSerialize = require(ReplicatedStorage.Shared.Communication.CommunicationSerialize)
local CommunicationClient = require(ReplicatedStorage.Client.Communication.CommunicationClient)
local TeleportClient = require(ReplicatedStorage.Client.Teleport.TeleportClient)
local CommunicationServer = require(ServerScriptService.Modules.Communication.CommunicationServer)
local TeleportModule = require(ServerScriptService.Modules.Teleport.TeleportModule)
local TeleportPolicy = require(ServerScriptService.Modules.Teleport.TeleportPolicy)
local TeleportValidationConfig = require(ServerScriptService.Modules.Teleport.TeleportValidationConfig)
local TeleportValidationPad = require(ServerScriptService.Modules.Teleport.TeleportValidationPad)
local TestHarness = require(script.Parent.TestHarness)

local PLACE_ID = 91045933836846
local SECONDARY_PLACE_ID = 101736951773632
local TEMPLATE_GAME_ID = 10596427617
local MAX_SUPPORTED_TEST_PLAYERS = 100
local AUTHORIZED_USER_ID = 11330628810

local function assertEqual(actual: any, expected: any, message: string?)
	assert(actual == expected, message or `Expected {tostring(expected)}, got {tostring(actual)}`)
end

local function assertTrue(value: any, message: string?)
	assert(value == true, message or "Expected true")
end

local function guid(index: number): string
	return string.format("00000000-0000-4000-8000-%012d", index)
end

local function newSignal()
	local listeners = {}
	local signal = {}
	function signal:Connect(callback)
		local connected = true
		table.insert(listeners, callback)
		return {
			Disconnect = function()
				connected = false
			end,
			_IsConnected = function()
				return connected
			end,
		}
	end
	function signal:Fire(...)
		for _, callback in listeners do
			callback(...)
		end
	end
	return signal
end

local function newPlayer(userId: number, joinData: any?)
	local player = {
		UserId = userId,
		_IsTeleportTestPlayer = true,
		_JoinData = joinData,
	}
	function player:GetJoinData()
		if self._JoinData == "THROW" then
			error("join unavailable")
		end
		return self._JoinData
	end
	return player
end

local function newPlayersModule(initialPlayers: { any })
	local players = table.clone(initialPlayers)
	local onAdded = nil
	local onRemoving = nil
	local module = { ObserveCalls = 0 }
	function module:ObservePlayers(added, removing)
		self.ObserveCalls += 1
		onAdded = added
		onRemoving = removing
		for _, player in players do
			added(player)
		end
		return function()
			onAdded = nil
			onRemoving = nil
		end
	end
	function module:GetPlayers()
		return table.clone(players)
	end
	function module:Add(player)
		table.insert(players, player)
		if onAdded then
			onAdded(player)
		end
	end
	function module:Remove(player)
		local index = table.find(players, player)
		if index then
			table.remove(players, index)
			if onRemoving then
				onRemoving(player)
			end
		end
	end
	return module
end

local function enabledValidationConfig(): any
	return {
		Enabled = true,
		GameId = TEMPLATE_GAME_ID,
		RoutesBySourcePlaceId = {
			[PLACE_ID] = SECONDARY_PLACE_ID,
			[SECONDARY_PLACE_ID] = PLACE_ID,
		},
		AuthorizedUserIds = {
			[AUTHORIZED_USER_ID] = true,
		},
	}
end

local function newValidationPlayersModule(initialPlayers: { any })
	local module = newPlayersModule(initialPlayers)
	local characterPlayers = {}
	function module:SetCharacterPlayer(character, player)
		characterPlayers[character] = player
	end
	function module:GetPlayerFromCharacter(character)
		return characterPlayers[character]
	end
	return module
end

local function newValidationPadFactory()
	local handles = {}
	local function factory(_workspaceRoot, destinationPlaceId)
		local touched = newSignal()
		local connection = nil
		local handle = {
			DestinationPlaceId = destinationPlaceId,
			Destroyed = false,
			DestroyCount = 0,
		}
		function handle:ConnectTouched(callback)
			connection = touched:Connect(callback)
		end
		function handle:Touch(part)
			touched:Fire(part)
		end
		function handle:Destroy()
			if self.Destroyed then
				return
			end
			self.Destroyed = true
			self.DestroyCount += 1
			if connection then
				connection:Disconnect()
				connection = nil
			end
		end
		table.insert(handles, handle)
		return handle
	end
	return factory, handles
end

local function newCommunication()
	local communication = {
		Messages = {},
		RequestHandlers = {},
		Resyncs = {},
		RejectType = nil,
	}
	function communication:Queue(player, messageType, payload, _requestId, options)
		if self.RejectType == messageType then
			return false
		end
		table.insert(self.Messages, {
			Player = player,
			Type = messageType,
			Payload = payload,
			Priority = options.Priority,
		})
		return true
	end
	function communication:RegisterRequestHandler(requestType, validator, handler)
		self.RequestHandlers[requestType] = { Validate = validator, Handle = handler }
	end
	function communication:RequireResync(player, reason)
		table.insert(self.Resyncs, { Player = player, Reason = reason })
	end
	return communication
end

local function newTeleportService()
	local service = {
		TeleportInitFailed = newSignal(),
		Throw = false,
		Yield = false,
		Calls = {},
	}
	function service:TeleportAsync(placeId, players, options)
		table.insert(self.Calls, { PlaceId = placeId, Players = players, Options = options })
		if self.Yield then
			coroutine.yield("TeleportAsyncYielded")
		end
		if self.Throw then
			error("platform rejected synchronously")
		end
		return { ReservedServerAccessCode = "private-result" }
	end
	return service
end

local function newOptions()
	local options = {
		TeleportData = nil,
		ServerInstanceId = nil,
		ReservedServerAccessCode = nil,
		ShouldReserveServer = false,
	}
	function options:SetTeleportData(value)
		self.TeleportData = value
	end
	function options:GetTeleportData()
		return self.TeleportData
	end
	return options
end

local function newServer(
	scope: any,
	initialPlayers: { any },
	service: any?,
	communication: any?,
	teleportOptionsFactory: (() -> any)?
)
	local nextGuid = 0
	local playersModule = newPlayersModule(initialPlayers)
	local teleportService = service or newTeleportService()
	local comm = communication or newCommunication()
	local module = TeleportModule.new({
		TeleportService = teleportService,
		HttpService = {
			GenerateGUID = function(_self, _wrap)
				nextGuid += 1
				return guid(nextGuid)
			end,
		},
		PlayersModule = playersModule,
		Communication = comm,
		Policy = TeleportPolicy.new({
			AllowedPlaceIds = { [PLACE_ID] = true },
			MaxGroupSize = 50,
			MaxSessionIdLength = 36,
			MaxAttemptIdLength = 36,
		}),
		PlaceId = PLACE_ID,
		TeleportOptionsFactory = teleportOptionsFactory or newOptions,
		IsPlayer = function(value)
			return typeof(value) == "table" and value._IsTeleportTestPlayer == true
		end,
		Logger = {
			Warn = function() end,
			Error = function() end,
		},
	})
	scope:Defer(function()
		module:Stop()
	end)
	module:Initialize()
	return module, playersModule, teleportService, comm
end

local function continuationJoinData(userId: number, sessionId: string, sourcePlaceId: number?): any
	local source = sourcePlaceId or PLACE_ID
	return {
		SourcePlaceId = source,
		TeleportData = {
			[TeleportProtocol.EnvelopeKey] = {
				Version = TeleportProtocol.EnvelopeVersion,
				SourcePlaceId = source,
				AttemptId = guid(899),
				SessionsByUserId = {
					[tostring(userId)] = sessionId,
				},
			},
		},
	}
end

local tests = {}

local function test(name: string, callback: (any) -> ())
	table.insert(tests, { Name = name, Callback = callback })
end

test("template policy allows recorded places and keeps unpublished local Play inert", function(scope)
	local primaryPolicy = TeleportPolicy.Template(PLACE_ID, TEMPLATE_GAME_ID)
	assertEqual(primaryPolicy.AllowedPlaceIds[PLACE_ID], true)
	assertEqual(primaryPolicy.AllowedPlaceIds[SECONDARY_PLACE_ID], true)
	local count = 0
	for _ in primaryPolicy.AllowedPlaceIds do
		count += 1
	end
	assertEqual(count, 2)

	local secondaryPolicy = TeleportPolicy.Template(SECONDARY_PLACE_ID, TEMPLATE_GAME_ID)
	assertEqual(secondaryPolicy.AllowedPlaceIds[PLACE_ID], true)
	assertEqual(secondaryPolicy.AllowedPlaceIds[SECONDARY_PLACE_ID], true)

	local derivedPolicy = TeleportPolicy.Template(777001, 777002)
	assertEqual(derivedPolicy.AllowedPlaceIds[777001], true)
	assertEqual(derivedPolicy.AllowedPlaceIds[PLACE_ID], nil)
	assertEqual(derivedPolicy.AllowedPlaceIds[SECONDARY_PLACE_ID], nil)

	local ok = pcall(function()
		TeleportPolicy.Template(777001, TEMPLATE_GAME_ID)
	end)
	assertEqual(ok, false, "unrecorded places in the template Experience must fail closed")

	local unpublishedPolicy = TeleportPolicy.Template(0, 0)
	assertEqual(next(unpublishedPolicy.AllowedPlaceIds), nil, "unpublished policy exposed a destination")
	for _, identity in {
		{ PlaceId = 0, GameId = TEMPLATE_GAME_ID },
		{ PlaceId = PLACE_ID, GameId = 0 },
	} do
		local mixedIdentityOk = pcall(function()
			TeleportPolicy.Template(identity.PlaceId, identity.GameId)
		end)
		assertEqual(mixedIdentityOk, false, "mixed zero/nonzero cloud identity did not fail closed")
	end
	local player = newPlayer(100, nil)
	local playersModule = newPlayersModule({ player })
	local teleportService = newTeleportService()
	local module = TeleportModule.new({
		TeleportService = teleportService,
		HttpService = {
			GenerateGUID = function()
				return guid(1)
			end,
		},
		PlayersModule = playersModule,
		Communication = newCommunication(),
		Policy = unpublishedPolicy,
		PlaceId = 0,
		TeleportOptionsFactory = newOptions,
		IsPlayer = function(value)
			return typeof(value) == "table" and value._IsTeleportTestPlayer == true
		end,
		Logger = {
			Warn = function() end,
			Error = function() end,
		},
	})
	scope:Defer(function()
		module:Stop()
	end)
	module:Initialize()
	assertEqual(module:GetSession(player).EntryKind, "External", "unpublished bootstrap did not create a session")
	local request = module:Teleport({ player }, { Kind = "Public", PlaceId = PLACE_ID })
	assertEqual(request.Code, "InvalidDestination", "unpublished policy accepted a teleport destination")
	assertEqual(#teleportService.Calls, 0, "unpublished policy reached TeleportService")
end)

test("validation pad default is inert before player observation or scene mutation", function(scope)
	local workspaceRoot = Instance.new("Folder")
	scope:Defer(function()
		workspaceRoot:Destroy()
	end)
	local player = newPlayer(AUTHORIZED_USER_ID, nil)
	local playersModule = newValidationPlayersModule({ player })
	local factory, handles = newValidationPadFactory()
	local controller = TeleportValidationPad.new({
		PlayersModule = playersModule,
		Teleport = { Teleport = function() error("disabled validation must not teleport") end },
		Workspace = workspaceRoot,
		CurrentPlaceId = PLACE_ID,
		CurrentGameId = TEMPLATE_GAME_ID,
		Config = TeleportValidationConfig,
		PadFactory = factory,
	})
	controller:Initialize()
	controller:Stop()
	assertEqual(TeleportValidationConfig.Enabled, false)
	assertEqual(TeleportValidationConfig.GameId, 0)
	assertEqual(next(TeleportValidationConfig.RoutesBySourcePlaceId), nil)
	assertEqual(next(TeleportValidationConfig.AuthorizedUserIds), nil)
	assertEqual(playersModule.ObserveCalls, 0, "disabled validation installed a player observer")
	assertEqual(#handles, 0)
end)

test("validation pad fails closed for incomplete malformed or mismatched opt-in", function(scope)
	local workspaceRoot = Instance.new("Folder")
	scope:Defer(function()
		workspaceRoot:Destroy()
	end)
	local authorized = newPlayer(AUTHORIZED_USER_ID, nil)
	local wrongUser = newPlayer(AUTHORIZED_USER_ID + 1, nil)

	local function assertNoPad(placeId, gameId, player, config)
		local factory, handles = newValidationPadFactory()
		local playersModule = newValidationPlayersModule({ player })
		local controller = TeleportValidationPad.new({
			PlayersModule = playersModule,
			Teleport = { Teleport = function() error("teleport must remain gated") end },
			Workspace = workspaceRoot,
			CurrentPlaceId = placeId,
			CurrentGameId = gameId,
			Config = config,
			PadFactory = factory,
		})
		controller:Initialize()
		controller:Stop()
		assertEqual(#handles, 0)
		return playersModule
	end

	assertNoPad(PLACE_ID, TEMPLATE_GAME_ID + 1, authorized, enabledValidationConfig())
	assertNoPad(PLACE_ID + 1, TEMPLATE_GAME_ID, authorized, enabledValidationConfig())
	local wrongUserPlayers = assertNoPad(PLACE_ID, TEMPLATE_GAME_ID, wrongUser, enabledValidationConfig())
	assertEqual(wrongUserPlayers.ObserveCalls, 1, "valid config did not observe tester presence")

	local missingConfigPlayers = assertNoPad(PLACE_ID, TEMPLATE_GAME_ID, authorized, nil)
	assertEqual(missingConfigPlayers.ObserveCalls, 0, "missing validation config installed a player observer")

	local invalidConfigs = {
		{},
		setmetatable({
			Enabled = true,
			GameId = TEMPLATE_GAME_ID,
			RoutesBySourcePlaceId = { [PLACE_ID] = SECONDARY_PLACE_ID },
			AuthorizedUserIds = { [AUTHORIZED_USER_ID] = true },
		}, {}),
		{ Enabled = true, GameId = TEMPLATE_GAME_ID },
		{
			Enabled = true,
			GameId = TEMPLATE_GAME_ID,
			RoutesBySourcePlaceId = setmetatable({ [PLACE_ID] = SECONDARY_PLACE_ID }, {}),
			AuthorizedUserIds = { [AUTHORIZED_USER_ID] = true },
		},
		{
			Enabled = true,
			GameId = TEMPLATE_GAME_ID,
			RoutesBySourcePlaceId = { [PLACE_ID] = SECONDARY_PLACE_ID },
			AuthorizedUserIds = setmetatable({ [AUTHORIZED_USER_ID] = true }, {}),
		},
		{
			Enabled = true,
			GameId = TEMPLATE_GAME_ID,
			RoutesBySourcePlaceId = { [PLACE_ID] = SECONDARY_PLACE_ID },
			AuthorizedUserIds = {},
		},
		{
			Enabled = true,
			GameId = TEMPLATE_GAME_ID,
			RoutesBySourcePlaceId = { [1.5] = SECONDARY_PLACE_ID },
			AuthorizedUserIds = { [AUTHORIZED_USER_ID] = true },
		},
		{
			Enabled = true,
			GameId = TEMPLATE_GAME_ID,
			RoutesBySourcePlaceId = { [PLACE_ID] = PLACE_ID },
			AuthorizedUserIds = { [AUTHORIZED_USER_ID] = true },
		},
		{
			Enabled = true,
			GameId = TEMPLATE_GAME_ID,
			RoutesBySourcePlaceId = { [PLACE_ID] = SECONDARY_PLACE_ID },
			AuthorizedUserIds = { [AUTHORIZED_USER_ID] = false },
		},
		{
			Enabled = true,
			GameId = TEMPLATE_GAME_ID,
			RoutesBySourcePlaceId = { [PLACE_ID] = SECONDARY_PLACE_ID },
			AuthorizedUserIds = { [AUTHORIZED_USER_ID] = true },
			UnexpectedIdentityFallback = true,
		},
	}
	for _, invalidConfig in invalidConfigs do
		local playersModule = assertNoPad(PLACE_ID, TEMPLATE_GAME_ID, authorized, invalidConfig)
		assertEqual(playersModule.ObserveCalls, 0, "invalid validation config installed a player observer")
	end
end)

test("validation pad selects the lowest present allowlisted tester independent of delivery order", function(scope)
	local workspaceRoot = Instance.new("Folder")
	local lowerPlayer = newPlayer(AUTHORIZED_USER_ID, nil)
	local higherPlayer = newPlayer(AUTHORIZED_USER_ID + 1, nil)
	local lowerCharacter = Instance.new("Model")
	local lowerBody = Instance.new("Part")
	lowerBody.Parent = lowerCharacter
	local higherCharacter = Instance.new("Model")
	local higherBody = Instance.new("Part")
	higherBody.Parent = higherCharacter
	scope:Defer(function()
		workspaceRoot:Destroy()
		lowerCharacter:Destroy()
		higherCharacter:Destroy()
	end)

	local playersModule = newValidationPlayersModule({ higherPlayer, lowerPlayer })
	playersModule:SetCharacterPlayer(lowerCharacter, lowerPlayer)
	playersModule:SetCharacterPlayer(higherCharacter, higherPlayer)
	local config = enabledValidationConfig()
	config.AuthorizedUserIds[higherPlayer.UserId] = true
	local calls = {}
	local factory, handles = newValidationPadFactory()
	local controller = TeleportValidationPad.new({
		PlayersModule = playersModule,
		Teleport = {
			Teleport = function(_self, players, destination)
				table.insert(calls, { Players = players, Destination = destination })
				return { Ok = true, AttemptId = guid(#calls) }
			end,
		},
		Workspace = workspaceRoot,
		CurrentPlaceId = PLACE_ID,
		CurrentGameId = TEMPLATE_GAME_ID,
		Config = config,
		PadFactory = factory,
	})
	scope:Defer(function()
		controller:Stop()
	end)
	controller:Initialize()

	assertEqual(#handles, 1, "initial player enumeration created transient duplicate pads")
	handles[1]:Touch(higherBody)
	assertEqual(#calls, 0, "higher UserId unexpectedly owned the validation pad")
	handles[1]:Touch(lowerBody)
	assertEqual(#calls, 1)
	assertEqual(calls[1].Players[1], lowerPlayer)

	playersModule:Remove(lowerPlayer)
	assertTrue(handles[1].Destroyed)
	assertEqual(#handles, 2, "remaining higher UserId was not promoted")
	handles[2]:Touch(higherBody)
	assertEqual(#calls, 2)

	playersModule:Add(lowerPlayer)
	assertTrue(handles[2].Destroyed, "new lower UserId did not preempt the active tester")
	assertEqual(#handles, 3)
	handles[3]:Touch(higherBody)
	assertEqual(#calls, 2, "preempted higher UserId still controlled the replacement pad")
	handles[3]:Touch(lowerBody)
	assertEqual(#calls, 3)
	assertEqual(calls[3].Players[1], lowerPlayer)
end)

test("validation pad promotes another present allowlisted tester after active removal", function(scope)
	local workspaceRoot = Instance.new("Folder")
	scope:Defer(function()
		workspaceRoot:Destroy()
	end)
	local firstPlayer = newPlayer(AUTHORIZED_USER_ID, nil)
	local secondPlayer = newPlayer(AUTHORIZED_USER_ID + 1, nil)
	local playersModule = newValidationPlayersModule({ firstPlayer, secondPlayer })
	local factory, handles = newValidationPadFactory()
	local config = enabledValidationConfig()
	config.AuthorizedUserIds[secondPlayer.UserId] = true
	local controller = TeleportValidationPad.new({
		PlayersModule = playersModule,
		Teleport = { Teleport = function() error("touch was not requested") end },
		Workspace = workspaceRoot,
		CurrentPlaceId = PLACE_ID,
		CurrentGameId = TEMPLATE_GAME_ID,
		Config = config,
		PadFactory = factory,
	})
	scope:Defer(function()
		controller:Stop()
	end)
	controller:Initialize()

	assertEqual(#handles, 1)
	playersModule:Remove(firstPlayer)
	assertTrue(handles[1].Destroyed, "departing tester's pad was not destroyed")
	assertEqual(#handles, 2, "remaining allowlisted tester did not receive a replacement pad")
	playersModule:Remove(secondPlayer)
	assertTrue(handles[2].Destroyed, "replacement pad survived its tester's departure")
end)

test("authorized collision uses the public Teleport facade once and recreates after arrival", function(scope)
	local workspaceRoot = Instance.new("Folder")
	local character = Instance.new("Model")
	local body = Instance.new("Part")
	body.Parent = character
	scope:Defer(function()
		workspaceRoot:Destroy()
		character:Destroy()
	end)

	local player = newPlayer(AUTHORIZED_USER_ID, nil)
	local playersModule = newValidationPlayersModule({ player })
	playersModule:SetCharacterPlayer(character, player)
	local calls = {}
	local teleport = {}
	function teleport:Teleport(players, destination)
		table.insert(calls, { Players = players, Destination = destination })
		return { Ok = true, AttemptId = guid(#calls) }
	end
	local factory, handles = newValidationPadFactory()
	local config = enabledValidationConfig()
	local controller = TeleportValidationPad.new({
		PlayersModule = playersModule,
		Teleport = teleport,
		Workspace = workspaceRoot,
		CurrentPlaceId = PLACE_ID,
		CurrentGameId = TEMPLATE_GAME_ID,
		Config = config,
		PadFactory = factory,
	})
	config.RoutesBySourcePlaceId[PLACE_ID] = PLACE_ID
	config.AuthorizedUserIds[AUTHORIZED_USER_ID] = nil
	scope:Defer(function()
		controller:Stop()
	end)
	controller:Initialize()

	assertEqual(#handles, 1)
	assertEqual(handles[1].DestinationPlaceId, SECONDARY_PLACE_ID)
	handles[1]:Touch(body)
	handles[1]:Touch(body)
	assertEqual(#calls, 1, "touch re-entry invoked Teleport twice")
	assertEqual(#calls[1].Players, 1)
	assertEqual(calls[1].Players[1], player)
	assertEqual(calls[1].Destination.Kind, "Public")
	assertEqual(calls[1].Destination.PlaceId, SECONDARY_PLACE_ID)

	playersModule:Remove(player)
	assertTrue(handles[1].Destroyed)
	handles[1]:Touch(body)
	assertEqual(#calls, 1, "removed pad retained an active touch callback")

	local arrivedPlayer = newPlayer(AUTHORIZED_USER_ID, nil)
	local arrivedCharacter = Instance.new("Model")
	local arrivedBody = Instance.new("Part")
	arrivedBody.Parent = arrivedCharacter
	scope:Defer(function()
		arrivedCharacter:Destroy()
	end)
	playersModule:SetCharacterPlayer(arrivedCharacter, arrivedPlayer)
	playersModule:Add(arrivedPlayer)
	assertEqual(#handles, 2, "arrival did not recreate the runtime validation pad")
	handles[2]:Touch(arrivedBody)
	assertEqual(#calls, 2)
end)

test("secondary validation pad targets primary and Stop cleanup is terminal and idempotent", function(scope)
	local workspaceRoot = Instance.new("Folder")
	scope:Defer(function()
		workspaceRoot:Destroy()
	end)
	local player = newPlayer(AUTHORIZED_USER_ID, nil)
	local playersModule = newValidationPlayersModule({ player })
	local factory, handles = newValidationPadFactory()
	local controller = TeleportValidationPad.new({
		PlayersModule = playersModule,
		Teleport = { Teleport = function() error("touch was not requested") end },
		Workspace = workspaceRoot,
		CurrentPlaceId = SECONDARY_PLACE_ID,
		CurrentGameId = TEMPLATE_GAME_ID,
		Config = enabledValidationConfig(),
		PadFactory = factory,
	})
	controller:Initialize()
	assertEqual(#handles, 1)
	assertEqual(handles[1].DestinationPlaceId, PLACE_ID)
	controller:Stop()
	controller:Stop()
	assertEqual(handles[1].DestroyCount, 1)
	playersModule:Add(newPlayer(AUTHORIZED_USER_ID, nil))
	assertEqual(#handles, 1, "stopped controller recreated its pad")
end)

test("external arrivals create unique sessions and exactly one arrival", function(scope)
	local first = newPlayer(101, nil)
	local second = newPlayer(102, "THROW")
	local module, _, _, communication = newServer(scope, { first, second })
	local firstSession = module:GetSession(first)
	local secondSession = module:GetSession(second)
	assertEqual(firstSession.EntryKind, "External")
	assertEqual(secondSession.EntryKind, "External")
	assert(firstSession.SessionId ~= secondSession.SessionId, "external sessions must be unique")
	local arrivals = 0
	for _, message in communication.Messages do
		if message.Type == TeleportProtocol.MessageTypes.LocalArrived then
			arrivals += 1
		end
	end
	assertEqual(arrivals, 2)
end)

test("valid continuation preserves the canonical session across three visits", function(scope)
	local sessionId = guid(900)
	for visit = 1, 3 do
		local player = newPlayer(201, continuationJoinData(201, sessionId))
		local module = newServer(scope, { player })
		local snapshot = module:GetSession(player)
		assertEqual(snapshot.SessionId, sessionId, `visit {visit}`)
		assertEqual(snapshot.EntryKind, "Teleported")
		assertEqual(snapshot.SourcePlaceId, PLACE_ID)
	end
end)

test("invalid continuation shapes fail closed to a new external session", function(scope)
	local invalidJoinData = {
		nil,
		"bad",
		continuationJoinData(301, string.rep("x", 500)),
		continuationJoinData(301, guid(1), PLACE_ID + 1),
		{
			SourcePlaceId = PLACE_ID,
			TeleportData = {
				[TeleportProtocol.EnvelopeKey] = {
					Version = 2,
					SourcePlaceId = PLACE_ID,
					AttemptId = guid(899),
					SessionsByUserId = { ["301"] = guid(1) },
				},
			},
		},
		continuationJoinData(999, guid(1)),
	}
	for index, joinData in invalidJoinData do
		local player = newPlayer(301, joinData)
		local module = newServer(scope, { player })
		assertEqual(module:GetSession(player).EntryKind, "External", `invalid case {index}`)
	end
end)

test("accepted request carries only the module envelope and does not publish arrival", function(scope)
	local player = newPlayer(401, nil)
	local module, _, teleportService, communication = newServer(scope, { player })
	local arrivalsBefore = 0
	for _, message in communication.Messages do
		if message.Type == TeleportProtocol.MessageTypes.LocalArrived then
			arrivalsBefore += 1
		end
	end
	local result = module:Teleport({ player }, { Kind = "NewReservedServer", PlaceId = PLACE_ID })
	assertTrue(result.Ok)
	assertEqual(module:GetAttempt(player).State, "Accepted")
	assertEqual(#teleportService.Calls, 1)
	local options = teleportService.Calls[1].Options
	assertTrue(options.ShouldReserveServer)
	assertEqual(options.TeleportData.TeleportModule.SessionsByUserId["401"], module:GetSession(player).SessionId)
	local arrivalsAfter = 0
	for _, message in communication.Messages do
		if message.Type == TeleportProtocol.MessageTypes.LocalArrived then
			arrivalsAfter += 1
		end
	end
	assertEqual(arrivalsAfter, arrivalsBefore, "acceptance must not synthesize target arrival")
end)

test("destination is an exact closed union before any state or platform mutation", function(scope)
	local invalidDestinations = {
		{ Name = "nil", Value = nil },
		{ Name = "wrong root type", Value = "Public" },
		{ Name = "missing kind", Value = { PlaceId = PLACE_ID } },
		{ Name = "unknown kind", Value = { Kind = "Unknown", PlaceId = PLACE_ID } },
		{ Name = "missing place", Value = { Kind = "Public" } },
		{ Name = "nil place", Value = { Kind = "Public", PlaceId = nil } },
		{ Name = "disallowed place", Value = { Kind = "Public", PlaceId = PLACE_ID + 1 } },
		{
			Name = "public extra selector",
			Value = { Kind = "Public", PlaceId = PLACE_ID, ServerInstanceId = "server" },
		},
		{
			Name = "public conflicting selectors",
			Value = {
				Kind = "Public",
				PlaceId = PLACE_ID,
				ServerInstanceId = "server",
				ReservedServerAccessCode = "reserved",
			},
		},
		{ Name = "server instance missing selector", Value = { Kind = "ServerInstance", PlaceId = PLACE_ID } },
		{
			Name = "server instance nil selector",
			Value = { Kind = "ServerInstance", PlaceId = PLACE_ID, ServerInstanceId = nil },
		},
		{
			Name = "server instance empty selector",
			Value = { Kind = "ServerInstance", PlaceId = PLACE_ID, ServerInstanceId = "" },
		},
		{
			Name = "server instance oversized selector",
			Value = { Kind = "ServerInstance", PlaceId = PLACE_ID, ServerInstanceId = string.rep("s", 129) },
		},
		{
			Name = "server instance control selector",
			Value = { Kind = "ServerInstance", PlaceId = PLACE_ID, ServerInstanceId = "server\nother" },
		},
		{
			Name = "server instance wrong selector type",
			Value = { Kind = "ServerInstance", PlaceId = PLACE_ID, ServerInstanceId = 42 },
		},
		{
			Name = "server instance conflicting selector",
			Value = {
				Kind = "ServerInstance",
				PlaceId = PLACE_ID,
				ServerInstanceId = "server",
				ReservedServerAccessCode = "reserved",
			},
		},
		{ Name = "reserved missing selector", Value = { Kind = "ReservedServer", PlaceId = PLACE_ID } },
		{
			Name = "reserved nil selector",
			Value = { Kind = "ReservedServer", PlaceId = PLACE_ID, ReservedServerAccessCode = nil },
		},
		{
			Name = "reserved empty selector",
			Value = { Kind = "ReservedServer", PlaceId = PLACE_ID, ReservedServerAccessCode = "" },
		},
		{
			Name = "reserved oversized selector",
			Value = {
				Kind = "ReservedServer",
				PlaceId = PLACE_ID,
				ReservedServerAccessCode = string.rep("r", 129),
			},
		},
		{
			Name = "reserved control selector",
			Value = { Kind = "ReservedServer", PlaceId = PLACE_ID, ReservedServerAccessCode = "reserved\0other" },
		},
		{
			Name = "reserved wrong selector type",
			Value = { Kind = "ReservedServer", PlaceId = PLACE_ID, ReservedServerAccessCode = false },
		},
		{
			Name = "reserved conflicting selector",
			Value = {
				Kind = "ReservedServer",
				PlaceId = PLACE_ID,
				ReservedServerAccessCode = "reserved",
				ServerInstanceId = "server",
			},
		},
		{
			Name = "new reserved selector",
			Value = { Kind = "NewReservedServer", PlaceId = PLACE_ID, ReservedServerAccessCode = "reserved" },
		},
		{
			Name = "new reserved platform option",
			Value = { Kind = "NewReservedServer", PlaceId = PLACE_ID, ShouldReserveServer = true },
		},
	}

	for _, case in invalidDestinations do
		local player = newPlayer(450, nil)
		local module, _, service, communication = newServer(scope, { player })
		local messagesBefore = #communication.Messages
		local result = module:Teleport({ player }, case.Value)
		assertEqual(result.Ok, false, case.Name)
		assertEqual(result.Code, "InvalidDestination", case.Name)
		assertEqual(module:GetAttempt(player), nil, case.Name)
		assertEqual(#communication.Messages, messagesBefore, `{case.Name}: emitted a message`)
		assertEqual(#service.Calls, 0, `{case.Name}: called TeleportAsync`)
	end
end)

test("validated destination snapshot defeats scheduled caller mutation", function(scope)
	local player = newPlayer(451, nil)
	local service = newTeleportService()
	local module = newServer(scope, { player }, service, nil, function()
		task.wait()
		return newOptions()
	end)
	local callerDestination: any = {
		Kind = "ServerInstance",
		PlaceId = PLACE_ID,
		ServerInstanceId = "validated-server",
	}
	local listenerRan = false
	module.AttemptStarted:Connect(function()
		callerDestination.Kind = "ReservedServer"
		callerDestination.PlaceId = PLACE_ID + 1
		callerDestination.ServerInstanceId = "mutated-server"
		callerDestination.ReservedServerAccessCode = "mutated-reserved"
		listenerRan = true
	end)

	local result = module:Teleport({ player }, callerDestination)
	assertTrue(result.Ok)
	assertTrue(listenerRan, "scheduled AttemptStarted listener did not run during the options-factory yield")
	assertEqual(callerDestination.PlaceId, PLACE_ID + 1, "caller destination was not mutated by the regression setup")
	assertEqual(#service.Calls, 1)
	assertEqual(service.Calls[1].PlaceId, PLACE_ID, "platform call bypassed the validated place policy")
	assertEqual(service.Calls[1].Options.ServerInstanceId, "validated-server")
	assertEqual(service.Calls[1].Options.ReservedServerAccessCode, nil)
	assertEqual(service.Calls[1].Options.ShouldReserveServer, false)
	local attempt = module:GetAttempt(player)
	assertEqual(attempt.State, "Accepted")
	assertEqual(attempt.DestinationKind, "ServerInstance")
	assertEqual(attempt.PlaceId, PLACE_ID)
end)

test("synchronous failure clears only the attempt and preserves the session", function(scope)
	local player = newPlayer(501, nil)
	local service = newTeleportService()
	service.Throw = true
	local module, _, _, communication = newServer(scope, { player }, service)
	local sessionId = module:GetSession(player).SessionId
	local result = module:Teleport({ player }, { Kind = "Public", PlaceId = PLACE_ID })
	assertEqual(result.Ok, false)
	assertEqual(result.Code, "TeleportRequestFailed")
	assertEqual(module:GetAttempt(player), nil)
	assertEqual(module:GetSession(player).SessionId, sessionId)
	local failureCount = 0
	local departureCount = 0
	for _, message in communication.Messages do
		if message.Type == TeleportProtocol.MessageTypes.LocalAttemptFailed then
			failureCount += 1
		elseif message.Type == TeleportProtocol.MessageTypes.PlayerDeparted then
			departureCount += 1
		end
	end
	assertEqual(failureCount, 1)
	assertEqual(departureCount, 0)
end)

test("yielding successful request is isolated from caller group mutation", function(scope)
	local first = newPlayer(521, nil)
	local second = newPlayer(522, nil)
	local service = newTeleportService()
	service.Yield = true
	local module = newServer(scope, { first, second }, service)
	local callerGroup = { first, second }
	local result = nil
	local requestThread = coroutine.create(function()
		result = module:Teleport(callerGroup, { Kind = "Public", PlaceId = PLACE_ID })
	end)
	local resumed, marker = coroutine.resume(requestThread)
	assertTrue(resumed)
	assertEqual(marker, "TeleportAsyncYielded")
	table.remove(callerGroup, 1)
	assertEqual(#callerGroup, 1)
	resumed = coroutine.resume(requestThread)
	assertTrue(resumed)
	assertEqual(coroutine.status(requestThread), "dead")
	assertTrue(result.Ok)
	assertEqual(module:GetAttempt(first).State, "Accepted")
	assertEqual(module:GetAttempt(second).State, "Accepted")
	assertEqual(#service.Calls[1].Players, 2)
	assert(service.Calls[1].Players ~= callerGroup, "TeleportAsync received the caller-owned group")
	assertEqual(table.isfrozen(service.Calls[1].Players), true)
end)

test("yielding failed request clears every snapshotted participant after caller mutation", function(scope)
	local first = newPlayer(531, nil)
	local second = newPlayer(532, nil)
	local service = newTeleportService()
	service.Yield = true
	service.Throw = true
	local module, _, _, communication = newServer(scope, { first, second }, service)
	local callerGroup = { first, second }
	local result = nil
	local requestThread = coroutine.create(function()
		result = module:Teleport(callerGroup, { Kind = "Public", PlaceId = PLACE_ID })
	end)
	local resumed, marker = coroutine.resume(requestThread)
	assertTrue(resumed)
	assertEqual(marker, "TeleportAsyncYielded")
	table.clear(callerGroup)
	resumed = coroutine.resume(requestThread)
	assertTrue(resumed)
	assertEqual(coroutine.status(requestThread), "dead")
	assertEqual(result.Ok, false)
	assertEqual(module:GetAttempt(first), nil)
	assertEqual(module:GetAttempt(second), nil)
	local failedUserIds = {}
	for _, message in communication.Messages do
		if message.Type == TeleportProtocol.MessageTypes.LocalAttemptFailed then
			failedUserIds[message.Player.UserId] = true
		end
	end
	assertTrue(failedUserIds[first.UserId])
	assertTrue(failedUserIds[second.UserId])
end)

test("matching init failure before successful return publishes Accepted then Failed exactly once", function(scope)
	local player = newPlayer(541, nil)
	local service = newTeleportService()
	service.Yield = true
	local module, _, _, communication = newServer(scope, { player }, service)
	local messagesBefore = #communication.Messages
	local result = nil
	local requestThread = coroutine.create(function()
		result = module:Teleport({ player }, { Kind = "Public", PlaceId = PLACE_ID })
	end)

	local resumed, marker = coroutine.resume(requestThread)
	assertTrue(resumed)
	assertEqual(marker, "TeleportAsyncYielded")
	local options = service.Calls[1].Options
	service.TeleportInitFailed:Fire(player, "Failure", "failed before return", PLACE_ID, options)
	service.TeleportInitFailed:Fire(player, "Failure", "duplicate before return", PLACE_ID, options)
	assertEqual(module:GetAttempt(player).State, "Started")
	assertEqual(#communication.Messages, messagesBefore + 1, "failure published before platform return was classified")

	resumed = coroutine.resume(requestThread)
	assertTrue(resumed)
	assertEqual(coroutine.status(requestThread), "dead")
	assertTrue(result.Ok)
	assertEqual(module:GetAttempt(player), nil)
	local lifecycle = {}
	for index = messagesBefore + 1, #communication.Messages do
		table.insert(lifecycle, communication.Messages[index])
	end
	assertEqual(#lifecycle, 3)
	assertEqual(lifecycle[1].Type, TeleportProtocol.MessageTypes.LocalAttemptStarted)
	assertEqual(lifecycle[2].Type, TeleportProtocol.MessageTypes.LocalAttemptAccepted)
	assertEqual(lifecycle[3].Type, TeleportProtocol.MessageTypes.LocalAttemptFailed)
	assertEqual(lifecycle[3].Payload.Error, "failed before return")

	service.TeleportInitFailed:Fire(player, "Failure", "duplicate after terminal", PLACE_ID, options)
	assertEqual(#communication.Messages, messagesBefore + 3, "duplicate failure published a second terminal result")
end)

test("matching init failure before synchronous exception does not double fail", function(scope)
	local player = newPlayer(542, nil)
	local service = newTeleportService()
	service.Yield = true
	service.Throw = true
	local module, _, _, communication = newServer(scope, { player }, service)
	local messagesBefore = #communication.Messages
	local result = nil
	local requestThread = coroutine.create(function()
		result = module:Teleport({ player }, { Kind = "Public", PlaceId = PLACE_ID })
	end)

	local resumed, marker = coroutine.resume(requestThread)
	assertTrue(resumed)
	assertEqual(marker, "TeleportAsyncYielded")
	local options = service.Calls[1].Options
	service.TeleportInitFailed:Fire(player, "Failure", "event raced exception", PLACE_ID, options)
	resumed = coroutine.resume(requestThread)
	assertTrue(resumed)
	assertEqual(coroutine.status(requestThread), "dead")
	assertEqual(result.Ok, false)
	assertEqual(result.Code, "TeleportRequestFailed")
	assertEqual(module:GetAttempt(player), nil)

	local acceptedCount = 0
	local failed = {}
	for index = messagesBefore + 1, #communication.Messages do
		local message = communication.Messages[index]
		if message.Type == TeleportProtocol.MessageTypes.LocalAttemptAccepted then
			acceptedCount += 1
		elseif message.Type == TeleportProtocol.MessageTypes.LocalAttemptFailed then
			table.insert(failed, message)
		end
	end
	assertEqual(acceptedCount, 0)
	assertEqual(#failed, 1)
	assertEqual(failed[1].Payload.Code, "TeleportRequestFailed")
	service.TeleportInitFailed:Fire(player, "Failure", "duplicate after exception", PLACE_ID, options)
	assertEqual(#communication.Messages, messagesBefore + 2, "exception path published a duplicate terminal result")
end)

test("pending failure cannot terminate a retry installed after removal", function(scope)
	local player = newPlayer(543, nil)
	local service = newTeleportService()
	service.Yield = true
	local module, playersModule = newServer(scope, { player }, service)
	local firstResult = nil
	local requestThread = coroutine.create(function()
		firstResult = module:Teleport({ player }, { Kind = "Public", PlaceId = PLACE_ID })
	end)

	local resumed, marker = coroutine.resume(requestThread)
	assertTrue(resumed)
	assertEqual(marker, "TeleportAsyncYielded")
	local staleOptions = service.Calls[1].Options
	service.TeleportInitFailed:Fire(player, "Failure", "pending before removal", PLACE_ID, staleOptions)
	playersModule:Remove(player)
	playersModule:Add(player)
	service.Yield = false
	local retry = module:Teleport({ player }, { Kind = "Public", PlaceId = PLACE_ID })
	assertTrue(retry.Ok)
	assertEqual(module:GetAttempt(player).AttemptId, retry.AttemptId)

	resumed = coroutine.resume(requestThread)
	assertTrue(resumed)
	assertEqual(coroutine.status(requestThread), "dead")
	assertTrue(firstResult.Ok)
	assertEqual(module:GetAttempt(player).AttemptId, retry.AttemptId)
	service.TeleportInitFailed:Fire(player, "Failure", "stale after retry", PLACE_ID, staleOptions)
	assertEqual(module:GetAttempt(player).AttemptId, retry.AttemptId)
end)

test("Stop retires a pending pre-return failure", function(scope)
	local player = newPlayer(544, nil)
	local service = newTeleportService()
	service.Yield = true
	local module, _, _, communication = newServer(scope, { player }, service)
	local result = nil
	local requestThread = coroutine.create(function()
		result = module:Teleport({ player }, { Kind = "Public", PlaceId = PLACE_ID })
	end)

	local resumed, marker = coroutine.resume(requestThread)
	assertTrue(resumed)
	assertEqual(marker, "TeleportAsyncYielded")
	service.TeleportInitFailed:Fire(player, "Failure", "pending before stop", PLACE_ID, service.Calls[1].Options)
	module:Stop()
	local messagesAfterStop = #communication.Messages
	resumed = coroutine.resume(requestThread)
	assertTrue(resumed)
	assertEqual(coroutine.status(requestThread), "dead")
	assertTrue(result.Ok)
	assertEqual(module:GetAttempt(player), nil)
	assertEqual(module:GetSession(player), nil)
	assertEqual(#communication.Messages, messagesAfterStop, "stopped module published a post-return transition")
end)

test("lost state queueing explicitly requires snapshot recovery", function(scope)
	local player = newPlayer(551, nil)
	local communication = newCommunication()
	local module = newServer(scope, { player }, nil, communication)
	communication.RejectType = TeleportProtocol.MessageTypes.LocalAttemptStarted
	local result = module:Teleport({ player }, { Kind = "Public", PlaceId = PLACE_ID })
	assertTrue(result.Ok)
	assertEqual(module:GetAttempt(player).State, "Accepted")
	assertEqual(#communication.Resyncs, 1)
	assertEqual(communication.Resyncs[1].Player, player)
	assertEqual(communication.Resyncs[1].Reason, "TeleportProjectionQueueFailed")
end)

test("group late failure is correlated per player and stale options cannot end a newer attempt", function(scope)
	local first = newPlayer(601, nil)
	local second = newPlayer(602, nil)
	local module, _, service = newServer(scope, { first, second })
	local result = module:Teleport({ first, second }, { Kind = "Public", PlaceId = PLACE_ID })
	assertTrue(result.Ok)
	local firstOptions = service.Calls[1].Options
	service.TeleportInitFailed:Fire(first, "Failure", "late failure", PLACE_ID, firstOptions)
	assertEqual(module:GetAttempt(first), nil)
	assertEqual(module:GetAttempt(second).State, "Accepted")
	local retry = module:Teleport({ first }, { Kind = "Public", PlaceId = PLACE_ID })
	assertTrue(retry.Ok)
	service.TeleportInitFailed:Fire(first, "Failure", "stale", PLACE_ID, firstOptions)
	assertEqual(module:GetAttempt(first).AttemptId, retry.AttemptId)
end)

test("group validation is atomic and repeated removal and stop are idempotent", function(scope)
	local first = newPlayer(701, nil)
	local second = newPlayer(702, nil)
	local module, playersModule, service, communication = newServer(scope, { first, second })
	local rejected = module:Teleport({ first, first }, { Kind = "Public", PlaceId = PLACE_ID })
	assertEqual(rejected.Ok, false)
	assertEqual(module:GetAttempt(first), nil)
	assertEqual(#service.Calls, 0)
	playersModule:Remove(first)
	playersModule:Remove(first)
	assertEqual(module:GetSession(first), nil)
	local departures = 0
	for _, message in communication.Messages do
		if message.Type == TeleportProtocol.MessageTypes.PlayerDeparted then
			departures += 1
		end
	end
	assertEqual(departures, 1)
	module:Stop()
	module:Stop()
end)

test("bootstrap exposes own session and only safe other-player appearance", function(scope)
	local first = newPlayer(801, nil)
	local second = newPlayer(802, nil)
	local module, _, _, communication = newServer(scope, { first, second })
	local handler = communication.RequestHandlers[TeleportProtocol.RequestTypes.Bootstrap]
	local valid = handler.Validate({})
	assertTrue(valid)
	local handled, payload = handler.Handle(first, {})
	assertTrue(handled)
	assertEqual(payload.Arrival.SessionId, module:GetSession(first).SessionId)
	assertEqual(#payload.PresentPlayers, 1)
	assertEqual(payload.PresentPlayers[1].UserId, 802)
	assertEqual(payload.PresentPlayers[1].SessionId, nil)
	assertEqual(payload.PresentPlayers[1].AttemptId, nil)
end)

test("client bootstrap and lifecycle projection are ordered and subscriber optional", function(scope)
	local handlers = {}
	local communication = {}
	function communication:RegisterHandler(messageType, handler)
		handlers[messageType] = handler
	end
	function communication:Request(requestType, payload)
		assertEqual(requestType, TeleportProtocol.RequestTypes.Bootstrap)
		assertEqual(next(payload), nil)
		return true, {
			Arrival = { SessionId = guid(100), EntryKind = "External" },
			Attempt = nil,
			PresentPlayers = {
				{ UserId = 902, EntryKind = "External" },
			},
		}, nil
	end
	local playersModule = {
		GetLocalPlayer = function()
			return { UserId = 901 }
		end,
	}
	local client = TeleportClient.new({
		Communication = communication,
		PlayersModule = playersModule,
		MaxPlayers = 2,
	})
	scope:Defer(function()
		client:Stop()
	end)
	client:Initialize()
	assertEqual(client:GetLocalArrival().SessionId, guid(100))
	assertEqual(client:GetPresentPlayers()[902].EntryKind, "External")

	local failures = 0
	client.LocalAttemptFailed:Connect(function()
		failures += 1
	end)
	local attemptId = guid(101)
	handlers[TeleportProtocol.MessageTypes.LocalAttemptStarted]({
		AttemptId = attemptId,
		State = "Started",
		DestinationKind = "Public",
		PlaceId = PLACE_ID,
	})
	handlers[TeleportProtocol.MessageTypes.LocalAttemptAccepted]({
		AttemptId = attemptId,
		State = "Accepted",
		DestinationKind = "Public",
		PlaceId = PLACE_ID,
	})
	handlers[TeleportProtocol.MessageTypes.LocalAttemptFailed]({
		AttemptId = attemptId,
		Code = "Failure",
		Error = "late",
	})
	handlers[TeleportProtocol.MessageTypes.LocalAttemptFailed]({
		AttemptId = attemptId,
		Code = "Failure",
		Error = "duplicate",
	})
	task.wait()
	assertEqual(failures, 1)
	assertEqual(client:GetLocalAttempt(), nil)

	local invalidAppearanceOk = pcall(function()
		handlers[TeleportProtocol.MessageTypes.PlayerAppeared]({
			UserId = 903,
			EntryKind = "External",
			SessionId = guid(102),
		})
	end)
	assertEqual(invalidAppearanceOk, false, "private appearance fields must be rejected")

	local noSubscriberClient = TeleportClient.new({ Communication = {
		RegisterHandler = function(_self, messageType, handler)
			handlers[`second:{messageType}`] = handler
		end,
		Request = communication.Request,
	}, PlayersModule = playersModule, MaxPlayers = 2 })
	scope:Defer(function()
		noSubscriberClient:Stop()
	end)
	noSubscriberClient:Initialize()
	handlers[`second:{TeleportProtocol.MessageTypes.LocalAttemptStarted}`]({
		AttemptId = guid(103),
		State = "Started",
		DestinationKind = "Public",
		PlaceId = PLACE_ID,
	})
	assertEqual(noSubscriberClient:GetLocalAttempt().State, "Started")

	client:Stop()
	handlers[TeleportProtocol.MessageTypes.LocalAttemptStarted]({
		AttemptId = guid(104),
		State = "Started",
		DestinationKind = "Public",
		PlaceId = PLACE_ID,
	})
	assertEqual(client:GetLocalAttempt(), nil, "retained handler repopulated a stopped client")
end)

test("appearance and departure traverse the template communication boundary", function(scope)
	local localPlayer = newPlayer(1001, nil)
	local communicationClient = CommunicationClient.new({
		Warn = function() end,
		Error = function() end,
	}, nil, nil, {
		ClientToServer = {},
	})
	scope:Defer(function()
		communicationClient:Stop()
	end)
	local teleportClient = TeleportClient.new({
		Communication = communicationClient,
		PlayersModule = {
			GetLocalPlayer = function()
				return localPlayer
			end,
		},
		MaxPlayers = 2,
	})
	scope:Defer(function()
		teleportClient:Stop()
	end)

	local communicationServer = CommunicationServer.new({
		PlayersModule = { PlayerRemoving = newSignal() },
		Transport = {
			ClientToServer = {},
			Request = {},
			ServerToClient = {
				FireClient = function(_self, player, batch)
					assertEqual(player, localPlayer)
					communicationClient:ReceiveBatch(batch)
				end,
			},
		},
		Logger = {
			Warn = function() end,
			Error = function() end,
		},
	})
	scope:Defer(function()
		communicationServer:Stop()
	end)
	local epoch = communicationServer:BeginSnapshot(localPlayer)
	communicationClient:ResumeAfterSnapshot(epoch)
	assertTrue(communicationServer:SetClientReady(localPlayer, epoch))
	assertTrue(communicationServer:Queue(
		localPlayer,
		TeleportProtocol.MessageTypes.PlayerAppeared,
		{ UserId = 1002, EntryKind = "External" },
		nil,
		{ Priority = CommunicationProtocol.Priorities.Presentation }
	))
	communicationServer:Flush()
	assertEqual(teleportClient:GetPresentPlayers()[1002].EntryKind, "External")
	assertTrue(communicationServer:Queue(
		localPlayer,
		TeleportProtocol.MessageTypes.PlayerDeparted,
		{ UserId = 1002 },
		nil,
		{ Priority = CommunicationProtocol.Priorities.Presentation }
	))
	communicationServer:Flush()
	assertEqual(teleportClient:GetPresentPlayers()[1002], nil)
end)

test("snapshot reconciliation is observable after lost lifecycle and presentation transitions", function(scope)
	local handlers = {}
	local communication = {}
	function communication:RegisterHandler(messageType, handler)
		handlers[messageType] = handler
	end
	function communication:Request()
		return true, {
			Arrival = { SessionId = guid(110), EntryKind = "External" },
			Attempt = nil,
			PresentPlayers = {
				{ UserId = 1102, EntryKind = "External" },
			},
		}, nil
	end
	local client = TeleportClient.new({
		Communication = communication,
		PlayersModule = {
			GetLocalPlayer = function()
				return { UserId = 1101 }
			end,
		},
		MaxPlayers = 4,
	})
	scope:Defer(function()
		client:Stop()
	end)
	client:Initialize()

	local observed = {}
	client.ProjectionReconciled:Connect(function()
		local arrival = client:GetLocalArrival()
		local attempt = client:GetLocalAttempt()
		local present = client:GetPresentPlayers()
		table.insert(observed, {
			SessionId = arrival and arrival.SessionId,
			AttemptState = attempt and attempt.State,
			Has1102 = present[1102] ~= nil,
			Has1103 = present[1103] ~= nil,
		})
	end)

	local attemptId = guid(111)
	client:ApplySnapshot({
		Arrival = { SessionId = guid(110), EntryKind = "External" },
		Attempt = {
			AttemptId = attemptId,
			State = "Started",
			DestinationKind = "Public",
			PlaceId = PLACE_ID,
		},
		PresentPlayers = {
			{ UserId = 1102, EntryKind = "External" },
		},
	})
	task.wait()
	assertEqual(observed[#observed].AttemptState, "Started", "lost Started was not observable after recovery")

	client:ApplySnapshot({
		Arrival = { SessionId = guid(110), EntryKind = "External" },
		Attempt = {
			AttemptId = attemptId,
			State = "Accepted",
			DestinationKind = "Public",
			PlaceId = PLACE_ID,
		},
		PresentPlayers = {
			{ UserId = 1102, EntryKind = "External" },
		},
	})
	task.wait()
	assertEqual(observed[#observed].AttemptState, "Accepted", "lost Accepted was not observable after recovery")

	client:ApplySnapshot({
		Arrival = { SessionId = guid(112), EntryKind = "Teleported", SourcePlaceId = PLACE_ID },
		Attempt = nil,
		PresentPlayers = {
			{ UserId = 1103, EntryKind = "Teleported", SourcePlaceId = PLACE_ID },
		},
	})
	task.wait()
	local recovered = observed[#observed]
	assertEqual(recovered.SessionId, guid(112), "lost arrival was not observable after recovery")
	assertEqual(recovered.AttemptState, nil, "lost Failed was not observable after recovery")
	assertEqual(recovered.Has1102, false, "lost departure was not observable after recovery")
	assertEqual(recovered.Has1103, true, "lost appearance was not observable after recovery")
end)

test("bootstrap and resync accept present-player projection at configured maximum capacity", function(scope)
	local players = table.create(MAX_SUPPORTED_TEST_PLAYERS)
	for userId = 1, MAX_SUPPORTED_TEST_PLAYERS do
		players[userId] = newPlayer(20_000 + userId, nil)
	end
	local localPlayer = players[1]
	local module, _, _, communication = newServer(scope, players)
	local handler = communication.RequestHandlers[TeleportProtocol.RequestTypes.Bootstrap]
	local handled, bootstrap = handler.Handle(localPlayer, {})
	assertTrue(handled)
	assertEqual(#bootstrap.PresentPlayers, MAX_SUPPORTED_TEST_PLAYERS - 1)
	local networkSafe, issues, estimatedBytes = CommunicationSerialize.inspect({
		Ok = true,
		Snapshot = { ControllerId = "capacity", Revision = 1, Providers = {} },
		TeleportSnapshot = bootstrap,
		CommunicationEpoch = 1,
	}, {
		MaxBytes = CommunicationConfig.MaxSnapshotNetworkEstimatedBytes,
		MaxNodes = CommunicationConfig.MaxSnapshotInspectionNodes,
	})
	assertTrue(networkSafe, if issues[1] then issues[1].Reason else "maximum-capacity snapshot was unsafe")
	assertTrue(estimatedBytes <= CommunicationConfig.MaxSnapshotNetworkEstimatedBytes)

	local clientCommunication = {}
	function clientCommunication:RegisterHandler() end
	function clientCommunication:Request()
		return true, bootstrap, nil
	end
	local client = TeleportClient.new({
		Communication = clientCommunication,
		PlayersModule = {
			GetLocalPlayer = function()
				return localPlayer
			end,
		},
		MaxPlayers = MAX_SUPPORTED_TEST_PLAYERS,
	})
	scope:Defer(function()
		client:Stop()
	end)
	client:Initialize()
	assertEqual(#bootstrap.PresentPlayers, MAX_SUPPORTED_TEST_PLAYERS - 1)
	assertEqual(client:GetPresentPlayers()[players[MAX_SUPPORTED_TEST_PLAYERS].UserId].EntryKind, "External")
	client:ApplyPreparedSnapshot(client:PrepareSnapshot(module:BuildClientSnapshot(localPlayer)))
	task.wait()
	assertEqual(client:GetPresentPlayers()[players[MAX_SUPPORTED_TEST_PLAYERS].UserId].EntryKind, "External")
end)

local Runner = {}

function Runner.runAll()
	return TestHarness.runAll("TeleportModuleTestRunner", tests, 8)
end

return Runner
