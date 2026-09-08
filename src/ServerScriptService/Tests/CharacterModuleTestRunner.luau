--!strict

--[[
	Направленная проверка владельцев жизненного цикла персонажей.

	require(game.ServerScriptService.Tests.CharacterModuleTestRunner).runAll()
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local ClientPlayersModule = require(ReplicatedStorage.Client.Players.PlayersModule)
local CharacterClient = require(ReplicatedStorage.Client.Characters.CharacterClient)
local PlayersModule = require(ServerScriptService.Modules.Players.PlayersModule)
local CharacterModule = require(ServerScriptService.Modules.Characters.CharacterModule)
local TestHarness = require(script.Parent.TestHarness)

local Runner = {}

local function assertEqual(actual: any, expected: any, message: string?)
	if actual ~= expected then error(`{message or "assertEqual"}: expected={tostring(expected)} actual={tostring(actual)}`, 2) end
end

local function assertTrue(value: any, message: string)
	if not value then error(message, 2) end
end

local function waitUntil(predicate: () -> boolean)
	while not predicate() do task.wait() end
end

local function makeServerFixture(scope: any)
	local players = {}
	local playerAdded = Signal.new()
	local playerRemoving = Signal.new()
	local deferred = {}
	local waits = {}
	local playersService = {
		CharacterAutoLoads = true,
		PlayerAdded = playerAdded,
		PlayerRemoving = playerRemoving,
	}
	function playersService:GetPlayers() return table.clone(players) end
	function playersService:GetPlayerByUserId(userId)
		for _, player in players do if player.UserId == userId then return player end end
		return nil
	end
	function playersService:GetPlayerFromCharacter(character)
		for _, player in players do if player.Character == character then return player end end
		return nil
	end
	local function makePlayer(userId: number, failures: number?)
		local player = {
			UserId = userId,
			Character = nil,
			CharacterAdded = Signal.new(),
			CharacterRemoving = Signal.new(),
			Failures = failures or 0,
			Loads = 0,
			Kicks = {},
			PendingCharacter = nil :: Model?,
			LoadHook = nil :: ((any) -> ())?,
		} :: any
		function player:LoadCharacterAsync()
			self.Loads += 1
			if self.Loads <= self.Failures then error("planned creation failure") end
			if self.LoadHook ~= nil then
				self.LoadHook(self)
				return
			end
			local character = Instance.new("Model")
			local humanoid = Instance.new("Humanoid")
			humanoid.Parent = character
			self.PendingCharacter = character
		end
		function player:Kick(reason)
			table.insert(self.Kicks, reason)
		end
		scope:Defer(function()
			player.CharacterAdded:Destroy()
			player.CharacterRemoving:Destroy()
			if player.Character ~= nil then player.Character:Destroy() end
		end)
		return player
	end
	local playersModule = PlayersModule.new(playersService :: any)
	local characterModule = CharacterModule.new({
		PlayersModule = playersModule,
		Config = { GetRequired = function(_self, id) assertEqual(id, "Characters"); return { RespawnDelaySeconds = 2.5 } end },
		Scheduler = {
			Defer = function(callback) table.insert(deferred, callback) end,
			Wait = function(seconds) table.insert(waits, seconds) end,
		},
	})
	playersModule:Initialize()
	scope:Defer(function()
		characterModule:Stop()
		playersModule:Stop()
		playerAdded:Destroy()
		playerRemoving:Destroy()
	end)
	return {
		PlayersService = playersService,
		PlayersModule = playersModule,
		Characters = characterModule,
		Deferred = deferred,
		Waits = waits,
		MakePlayer = makePlayer,
		Add = function(player)
			table.insert(players, player)
			playerAdded:Fire(player)
		end,
		Remove = function(player)
			local index = table.find(players, player)
			if index ~= nil then table.remove(players, index) end
			playerRemoving:Fire(player)
		end,
		DeliverCharacterAdded = function(player)
			local character = player.PendingCharacter
			assert(character ~= nil, "expected a pending platform character")
			player.PendingCharacter = nil
			player.Character = character
			player.CharacterAdded:Fire(character)
			return character
		end,
	}
end

function Runner.runAll()
	local tests = {}
	local function test(name: string, callback: (any) -> ())
		table.insert(tests, { Name = name, Callback = callback })
	end

	test("AUTO-SLICE-001-INITIALIZATION-ORDER", function(scope)
		local fixture = makeServerFixture(scope)
		local observed, observationError = pcall(function()
			fixture.PlayersModule:ObservePlayers(function() end)
		end)
		assertTrue(not observed and string.find(tostring(observationError), "PlayersModuleObservationNotStarted", 1, true) ~= nil,
			"observation must not start from PlayersModule.Initialize")
		fixture.Characters:Initialize()
		assertEqual(fixture.PlayersModule:StartPlatformObservation(), false, "only the first observation start may have effects")
		assertEqual(fixture.PlayersService.CharacterAutoLoads, false, "CharacterModule must own the autoload policy")
	end)

	test("AUTO-SLICE-001-CHARACTER-LIFECYCLE", function(scope)
		local fixture = makeServerFixture(scope)
		fixture.Characters:Initialize()
		local root = scope:Track(Instance.new("Folder"))
		local early = Instance.new("Model")
		early.Parent = root
		local player = fixture.MakePlayer(9101)
		player.Character = early
		fixture.Add(player)
		waitUntil(function() return early.Parent == nil end)

		local added = 0
		local removed = 0
		fixture.Characters.CharacterAdded:Connect(function(observedPlayer, character)
			assertEqual(observedPlayer, player)
			assertTrue(character ~= early, "early character must not be published")
			added += 1
		end)
		fixture.Characters.CharacterRemoving:Connect(function(observedPlayer)
			assertEqual(observedPlayer, player)
			removed += 1
		end)
		local prepared = fixture.PlayersModule:PrepareApproval(player)
		assertTrue(prepared.Ok and prepared.Operation ~= nil, "approval preparation failed")
		assertTrue(fixture.PlayersModule:CommitApproval(prepared.Operation), "approval commit failed")
		assertTrue(fixture.PlayersModule:EmitConnectionApproved(prepared.Operation), "approval publication failed")
		waitUntil(function() return #fixture.Deferred == 1 end)
		table.remove(fixture.Deferred, 1)()
		assertEqual(player.Loads, 1, "a void LoadCharacterAsync result must still be one successful creation request")
		assertEqual(#player.Kicks, 0, "a void LoadCharacterAsync result must not be retried or disconnected before CharacterAdded")
		assertEqual(added, 0, "the character must be published only from the later CharacterAdded model")
		local first = fixture.DeliverCharacterAdded(player)
		waitUntil(function() return added == 1 end)
		waitUntil(function() return #fixture.Deferred == 1 end)
		table.remove(fixture.Deferred, 1)()

		player.Character = nil
		player.CharacterRemoving:Fire(first)
		waitUntil(function() return removed == 1 and #fixture.Deferred == 1 end)
		table.remove(fixture.Deferred, 1)()
		assertEqual(player.Loads, 2, "respawn must issue one void-return character request")
		assertEqual(added, 1, "respawn must wait for the later CharacterAdded model")
		fixture.DeliverCharacterAdded(player)
		waitUntil(function() return added == 2 end)
		assertEqual(fixture.Waits[1], 2.5, "respawn must use the captured place configuration")
	end)

	test("AUTO-SLICE-001-RETRIES-AND-GENERATIONS", function(scope)
		local fixture = makeServerFixture(scope)
		fixture.Characters:Initialize()
		local failing = fixture.MakePlayer(9102, 3)
		fixture.Add(failing)
		task.wait()
		task.wait()
		local prepared = fixture.PlayersModule:PrepareApproval(failing)
		assertTrue(prepared.Ok and prepared.Operation ~= nil)
		assertTrue(fixture.PlayersModule:CommitApproval(prepared.Operation))
		assertTrue(fixture.PlayersModule:EmitConnectionApproved(prepared.Operation))
		waitUntil(function() return #fixture.Deferred == 1 end)
		table.remove(fixture.Deferred, 1)()
		assertEqual(failing.Loads, 3, "one creation sequence must make no more than three attempts")
		assertEqual(#failing.Kicks, 1, "third creation failure must disconnect the player")

		local departing = fixture.MakePlayer(9103)
		fixture.Add(departing)
		task.wait()
		task.wait()
		local nextPrepared = fixture.PlayersModule:PrepareApproval(departing)
		assertTrue(nextPrepared.Ok and nextPrepared.Operation ~= nil)
		assertTrue(fixture.PlayersModule:CommitApproval(nextPrepared.Operation))
		assertTrue(fixture.PlayersModule:EmitConnectionApproved(nextPrepared.Operation))
		waitUntil(function() return #fixture.Deferred == 1 end)
		fixture.Remove(departing)
		table.remove(fixture.Deferred, 1)()
		assertEqual(departing.Loads, 0, "removed connection must invalidate the deferred creation")
	end)

	test("spawn remains singular while asynchronous lifecycle delivery settles", function(scope)
		local fixture = makeServerFixture(scope)
		fixture.Characters:Initialize()
		local player = fixture.MakePlayer(9104)
		fixture.Add(player)
		task.wait()
		task.wait()
		player.LoadHook = function(currentPlayer)
			local transient = Instance.new("Model")
			local transientHumanoid = Instance.new("Humanoid")
			transientHumanoid.Parent = transient
			currentPlayer.Character = transient
			currentPlayer.CharacterAdded:Fire(transient)
			task.wait()
			currentPlayer.Character = nil
			currentPlayer.CharacterRemoving:Fire(transient)
			local final = Instance.new("Model")
			local finalHumanoid = Instance.new("Humanoid")
			finalHumanoid.Parent = final
			currentPlayer.Character = final
			currentPlayer.CharacterAdded:Fire(final)
		end
		local prepared = fixture.PlayersModule:PrepareApproval(player)
		assertTrue(prepared.Ok and prepared.Operation ~= nil)
		assertTrue(fixture.PlayersModule:CommitApproval(prepared.Operation))
		assertTrue(fixture.PlayersModule:EmitConnectionApproved(prepared.Operation))
		waitUntil(function() return #fixture.Deferred == 1 end)
		table.remove(fixture.Deferred, 1)()
		waitUntil(function() return #fixture.Deferred == 1 end)
		table.remove(fixture.Deferred, 1)()
		task.wait()
		task.wait()
		assertEqual(player.Loads, 1, "one platform load must not schedule a second creation while its events settle")
		assertEqual(#fixture.Deferred, 0, "settled lifecycle delivery must not leave another respawn queued")
		assertTrue(player.Character ~= nil, "the final platform character must remain current")
	end)

	test("explicit respawn replaces one character and completes exactly once without a duplicate request", function(scope)
		local fixture = makeServerFixture(scope)
		fixture.Characters:Initialize()
		local player = fixture.MakePlayer(9105)
		fixture.Add(player)
		task.wait()
		task.wait()
		local prepared = fixture.PlayersModule:PrepareApproval(player)
		assertTrue(prepared.Ok and fixture.PlayersModule:CommitApproval(prepared.Operation))
		assertTrue(fixture.PlayersModule:EmitConnectionApproved(prepared.Operation))
		waitUntil(function() return #fixture.Deferred == 1 end)
		table.remove(fixture.Deferred, 1)()
		local first = fixture.DeliverCharacterAdded(player)
		waitUntil(function() return #fixture.Deferred == 1 end)
		table.remove(fixture.Deferred, 1)()

		local removed = 0
		fixture.Characters.CharacterRemoving:Connect(function() removed += 1 end)
		player.LoadHook = function(currentPlayer)
			currentPlayer.Character = nil
			currentPlayer.CharacterRemoving:Fire(first)
			local replacement = Instance.new("Model")
			Instance.new("Humanoid").Parent = replacement
			currentPlayer.Character = replacement
			currentPlayer.CharacterAdded:Fire(replacement)
		end
		local completions = {}
		assertTrue(fixture.Characters:RequestRespawn(player, function(ok, errorCode)
			table.insert(completions, { Ok = ok, Error = errorCode })
		end), "explicit respawn was rejected")
		assertTrue(not fixture.Characters:RequestRespawn(player, function() error("duplicate callback") end), "concurrent respawn was accepted")
		waitUntil(function() return #fixture.Deferred == 1 end)
		table.remove(fixture.Deferred, 1)()
		waitUntil(function() return #fixture.Deferred == 1 end)
		table.remove(fixture.Deferred, 1)()
		assertEqual(player.Loads, 2, "explicit respawn requested more than one platform load")
		assertEqual(removed, 1, "replacement published duplicate CharacterRemoving")
		assertEqual(#completions, 1, "explicit respawn callback count")
		assertEqual(completions[1].Ok, true)
		assertEqual(completions[1].Error, nil)
	end)

	test("explicit respawn failure reports once without disconnecting and departure cancels pending work", function(scope)
		local fixture = makeServerFixture(scope)
		fixture.Characters:Initialize()
		local player = fixture.MakePlayer(9106)
		fixture.Add(player)
		task.wait()
		task.wait()
		local prepared = fixture.PlayersModule:PrepareApproval(player)
		assertTrue(prepared.Ok and fixture.PlayersModule:CommitApproval(prepared.Operation))
		assertTrue(fixture.PlayersModule:EmitConnectionApproved(prepared.Operation))
		waitUntil(function() return #fixture.Deferred == 1 end)
		table.remove(fixture.Deferred, 1)()
		fixture.DeliverCharacterAdded(player)
		waitUntil(function() return #fixture.Deferred == 1 end)
		table.remove(fixture.Deferred, 1)()

		player.LoadHook = function(currentPlayer)
			local current = currentPlayer.Character
			if current ~= nil then
				currentPlayer.Character = nil
				currentPlayer.CharacterRemoving:Fire(current)
			end
			error("planned explicit respawn failure")
		end
		local failed = {}
		assertTrue(fixture.Characters:RequestRespawn(player, function(ok, errorCode)
			table.insert(failed, { Ok = ok, Error = errorCode })
		end))
		waitUntil(function() return #fixture.Deferred == 1 end)
		table.remove(fixture.Deferred, 1)()
		assertEqual(#failed, 1)
		assertEqual(failed[1].Ok, false)
		assertEqual(failed[1].Error, "RespawnFailed")
		assertEqual(#player.Kicks, 0, "explicit respawn failure disconnected the player")

		player.LoadHook = nil
		waitUntil(function() return #fixture.Deferred == 1 end)
		table.remove(fixture.Deferred, 1)()
		fixture.DeliverCharacterAdded(player)
		waitUntil(function() return #fixture.Deferred == 1 end)
		table.remove(fixture.Deferred, 1)()
		assertEqual(#player.Kicks, 0, "old-slot recovery disconnected the player")
		local cancelled = {}
		assertTrue(fixture.Characters:RequestRespawn(player, function(ok, errorCode)
			table.insert(cancelled, { Ok = ok, Error = errorCode })
		end))
		fixture.Remove(player)
		waitUntil(function() return #cancelled == 1 end)
		assertEqual(#cancelled, 1)
		assertEqual(cancelled[1].Ok, false)
		assertEqual(cancelled[1].Error, "PlayerGone")
		table.remove(fixture.Deferred, 1)()
		assertEqual(#cancelled, 1, "late spawn called cancellation twice")
	end)

	test("explicit respawn cancellation aborts a deferred platform load and preserves the current character", function(scope)
		local fixture = makeServerFixture(scope)
		fixture.Characters:Initialize()
		local player = fixture.MakePlayer(9107)
		fixture.Add(player)
		task.wait()
		task.wait()
		local prepared = fixture.PlayersModule:PrepareApproval(player)
		assertTrue(prepared.Ok and fixture.PlayersModule:CommitApproval(prepared.Operation))
		assertTrue(fixture.PlayersModule:EmitConnectionApproved(prepared.Operation))
		waitUntil(function() return #fixture.Deferred == 1 end)
		table.remove(fixture.Deferred, 1)()
		local existing = fixture.DeliverCharacterAdded(player)
		waitUntil(function() return #fixture.Deferred == 1 end)
		table.remove(fixture.Deferred, 1)()
		local loadsBefore = player.Loads
		local completions = {}
		assertTrue(fixture.Characters:RequestRespawn(player, function(ok, errorCode)
			table.insert(completions, { Ok = ok, Error = errorCode })
		end), "cancellable respawn was rejected")
		assertTrue(fixture.Characters:CancelRespawn(player), "pending explicit respawn was not cancelled")
		assertTrue(not fixture.Characters:CancelRespawn(player), "same explicit respawn cancelled twice")
		assertEqual(#completions, 1)
		assertEqual(completions[1].Ok, false)
		assertEqual(completions[1].Error, "Cancelled")
		table.remove(fixture.Deferred, 1)()
		assertEqual(player.Loads, loadsBefore, "cancelled deferred respawn called LoadCharacterAsync")
		assertEqual(player.Character, existing, "cancelled deferred respawn replaced the current character")
		assertEqual(#completions, 1, "cancelled deferred work completed twice")
	end)

	test("failed transfer recovery stops after one bounded sequence and permits a later explicit retry", function(scope)
		local fixture = makeServerFixture(scope)
		fixture.Characters:Initialize()
		local player = fixture.MakePlayer(9108)
		fixture.Add(player)
		task.wait(); task.wait()
		assertTrue(fixture.PlayersModule:AdmitPlayer(player), "initial admission failed")
		waitUntil(function() return #fixture.Deferred == 1 end)
		table.remove(fixture.Deferred, 1)()
		fixture.DeliverCharacterAdded(player)
		waitUntil(function() return #fixture.Deferred == 1 end)
		table.remove(fixture.Deferred, 1)()
		player.LoadHook = function(currentPlayer)
			local previous = currentPlayer.Character
			if previous ~= nil then
				currentPlayer.Character = nil
				currentPlayer.CharacterRemoving:Fire(previous)
			end
			error("persistent transfer spawn failure")
		end
		local completions = 0
		assertTrue(fixture.Characters:RequestRespawn(player, function(ok, errorCode)
			completions += 1
			assertEqual(ok, false)
			assertEqual(errorCode, "RespawnFailed")
		end), "explicit respawn rejected")
		table.remove(fixture.Deferred, 1)()
		waitUntil(function() return #fixture.Deferred == 1 end)
		table.remove(fixture.Deferred, 1)()
		task.wait(); task.wait()
		assertEqual(player.Loads, 7, "initial load, three transfer attempts and three recovery attempts expected")
		assertEqual(#fixture.Deferred, 0, "persistent failure scheduled unbounded recovery")
		assertEqual(#player.Kicks, 0, "transfer recovery must not disconnect the player")
		assertEqual(completions, 1, "transfer failure must be reported once")
		player.LoadHook = nil
		assertTrue(fixture.Characters:RequestRespawn(player, function() end), "bounded failure blocked a later explicit retry")
	end)

	test("cancellation before deferred spawn completion removes the tentative character", function(scope)
		local fixture = makeServerFixture(scope)
		fixture.Characters:Initialize()
		local player = fixture.MakePlayer(9109)
		fixture.Add(player)
		task.wait(); task.wait()
		assertTrue(fixture.PlayersModule:AdmitPlayer(player), "initial admission failed")
		waitUntil(function() return #fixture.Deferred == 1 end)
		table.remove(fixture.Deferred, 1)()
		fixture.DeliverCharacterAdded(player)
		waitUntil(function() return #fixture.Deferred == 1 end)
		table.remove(fixture.Deferred, 1)()
		local completions = {}
		assertTrue(fixture.Characters:RequestRespawn(player, function(ok, errorCode)
			table.insert(completions, { Ok = ok, Error = errorCode })
		end), "explicit respawn rejected")
		table.remove(fixture.Deferred, 1)()
		local tentative = fixture.DeliverCharacterAdded(player)
		waitUntil(function() return #fixture.Deferred == 1 end)
		assertTrue(fixture.Characters:CancelRespawn(player), "settling spawn was not cancellable")
		table.remove(fixture.Deferred, 1)()
		assertEqual(#completions, 1)
		assertEqual(completions[1].Error, "Cancelled")
		assertEqual(completions[1].Ok, false)
		assertEqual(tentative:FindFirstChildOfClass("Humanoid"), nil, "cancelled transfer retained its tentative character")
		assertEqual(#fixture.Deferred, 1, "cancellation must schedule bounded recovery in the restored slot")
	end)

	test("AUTO-SLICE-001-CLIENT-CHARACTER-API", function(scope)
		local added = Signal.new()
		local removing = Signal.new()
		local player = { Character = nil, CharacterAdded = added, CharacterRemoving = removing } :: any
		local players = ClientPlayersModule.new({ LocalPlayer = player })
		local characters = CharacterClient.new(players)
		scope:Defer(function()
			characters:Stop()
			players:Stop()
			added:Destroy()
			removing:Destroy()
		end)
		players:Initialize()
		characters:Initialize()
		local appeared = 0
		characters.CharacterAdded:Connect(function() appeared += 1 end)
		local character = Instance.new("Model")
		player.Character = character
		added:Fire(character)
		waitUntil(function() return appeared == 1 end)
		assertEqual(characters:GetCharacter(), character)
		player.Character = nil
		removing:Fire(character)
		waitUntil(function() return characters:GetCharacter() == nil end)
		character:Destroy()
	end)

	return TestHarness.runAll("CharacterModuleTestRunner", tests, 10)
end

return Runner
