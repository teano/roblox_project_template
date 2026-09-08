--!strict

--[[
	require(game.ServerScriptService.Tests.PlayerAdmissionCoordinatorTestRunner).runAll()
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local PlayerAdmissionCoordinator = require(ServerScriptService.Modules.PlayerAdmission.PlayerAdmissionCoordinator)
local TestHarness = require(script.Parent.TestHarness)

local Runner = {}

local function equal(actual: any, expected: any, message: string?)
	if actual ~= expected then error(`{message or "assertEqual"}: expected={tostring(expected)} actual={tostring(actual)}`, 2) end
end

local function truthy(value: any, message: string)
	if not value then error(message, 2) end
end

function Runner.runAll()
	local tests = {}
	local function test(name: string, callback: (any) -> ()) table.insert(tests, { Name = name, Callback = callback }) end

	test("loaded ordinary Studio player is committed atomically once", function(scope)
		local playerLoaded = Signal.new()
		local playerRemoving = Signal.new()
		local attemptFailed = Signal.new()
		scope:Defer(function() playerLoaded:Destroy(); playerRemoving:Destroy(); attemptFailed:Destroy() end)
		local player = { UserId = -91 } :: any
		local calls = {}
		local players = {
			GetPlayers = function() return { player } end,
			GetPlayerByUserId = function(_self: any, userId: number) return if userId == player.UserId then player else nil end,
			PrepareApproval = function(_self: any, candidate: Player)
				table.insert(calls, "players.prepare")
				return table.freeze({ Ok = candidate == player, Operation = { Name = "players" } })
			end,
			CommitApproval = function(_self: any, _operation: any) table.insert(calls, "players.commit"); return true end,
			CancelApproval = function(_self: any, _operation: any) table.insert(calls, "players.cancel") end,
			EmitConnectionApproved = function(_self: any, _operation: any) table.insert(calls, "players.emit"); return true end,
			DisconnectPlayer = function(_self: any, _candidate: Player, reason: string) table.insert(calls, `disconnect:{reason}`); return true end,
			PlayerRemoving = playerRemoving,
		}
		local friends = {
			BindLocalTransferHandler = function() end,
			PrepareAdmission = function(_self: any, candidate: Player, input: any)
				table.insert(calls, "friends.prepare")
				equal(candidate, player); equal(input.Kind, "Ordinary")
				return table.freeze({ Ok = true, Operation = { Name = "friends" }, SlotContext = table.freeze({ Kind = "Ordinary" }) })
			end,
			CommitAdmission = function(_self: any, _operation: any) table.insert(calls, "friends.commit"); return true end,
			CancelAdmission = function(_self: any, _operation: any) table.insert(calls, "friends.cancel") end,
			EmitAdmissionEvents = function(_self: any, _operation: any) table.insert(calls, "friends.emit") end,
			BeginDeparture = function() return table.freeze({ Operation = {} }) end,
			CompleteDeparture = function() end,
		}
		local slots = {
			PrepareAdmission = function(_self: any, candidate: Player, context: any)
				table.insert(calls, "slots.prepare")
				equal(candidate, player); equal(context.Kind, "Ordinary")
				return table.freeze({ Ok = true, Operation = { Name = "slots" }, Result = "AssignedWithSlot" })
			end,
			CommitAdmission = function(_self: any, _operation: any) table.insert(calls, "slots.commit"); return true end,
			CancelAdmission = function(_self: any, _operation: any) table.insert(calls, "slots.cancel") end,
			EmitAdmissionEvents = function(_self: any, _operation: any) table.insert(calls, "slots.emit") end,
			BeginDeparture = function() return table.freeze({ Kind = "None" }) end,
			CompleteDeparture = function() end,
		}
		local controller = { PlayerLoaded = playerLoaded, IsLoaded = function(_self: any, candidate: Player) return candidate == player end }
		local coordinator = PlayerAdmissionCoordinator.new({
			PlayersModule = players,
			FriendsModule = friends,
			PlayerSlots = slots,
			CharacterModule = { RequestRespawn = function() return false end },
			TeleportModule = { AttemptFailed = attemptFailed, GetFriendsContinuation = function() return table.freeze({ Status = "Absent" }) end },
			PlaceId = 1,
		})
		scope:Defer(function() coordinator:Stop() end)
		coordinator:Initialize(controller)
		playerLoaded:Fire(player)
		equal(table.concat(calls, ","), "friends.prepare,slots.prepare,players.prepare,slots.commit,friends.commit,players.commit,slots.emit,friends.emit,players.emit")
	end)

	test("NoSlot cancels Friends preparation and starts a public teleport without disconnecting", function(scope)
		local loaded = Signal.new()
		local removing = Signal.new()
		local attemptFailed = Signal.new()
		scope:Defer(function() loaded:Destroy(); removing:Destroy(); attemptFailed:Destroy() end)
		local player = { UserId = 92 } :: any
		local calls = {}
		local players = {
			GetPlayers = function() return { player } end,
			GetPlayerByUserId = function() return player end,
			PlayerRemoving = removing,
			DisconnectPlayer = function(_self: any, _player: Player, _reason: string) table.insert(calls, "disconnect") end,
		}
		local friends = {
			BindLocalTransferHandler = function() end,
			PrepareAdmission = function() return table.freeze({ Ok = true, Operation = {} , SlotContext = table.freeze({ Kind = "Ordinary" }) }) end,
			CancelAdmission = function() table.insert(calls, "friends.cancel") end,
			BeginDeparture = function() return table.freeze({ Operation = {} }) end,
			CompleteDeparture = function() end,
		}
		local slots = {
			PrepareAdmission = function() return table.freeze({ Ok = false, Error = "NoSlot" }) end,
			BeginDeparture = function() return table.freeze({ Kind = "None" }) end,
			CompleteDeparture = function() end,
		}
		local teleport = {
			AttemptFailed = attemptFailed,
			GetFriendsContinuation = function() return table.freeze({ Status = "Absent" }) end,
			Teleport = function(_self: any, participants: any, destination: any)
				table.insert(calls, "teleport")
				equal(participants[1], player)
				equal(destination.Kind, "Public")
				equal(destination.PlaceId, 1)
				return { Ok = true, AttemptId = "accepted" }
			end,
		}
		local coordinator = PlayerAdmissionCoordinator.new({
			PlayersModule = players,
			FriendsModule = friends,
			PlayerSlots = slots,
			CharacterModule = { RequestRespawn = function() return false end },
			TeleportModule = teleport,
			PlaceId = 1,
		})
		scope:Defer(function() coordinator:Stop() end)
		coordinator:Initialize({ PlayerLoaded = loaded, IsLoaded = function() return true end })
		equal(table.concat(calls, ","), "friends.cancel,teleport")
	end)

	test("NoSlot retries public teleports before the third failure disconnects", function(scope)
		local loaded = Signal.new()
		local removing = Signal.new()
		local attemptFailed = Signal.new()
		scope:Defer(function() loaded:Destroy(); removing:Destroy(); attemptFailed:Destroy() end)
		local player = { UserId = 93 } :: any
		local calls = {}
		local waits = {}
		local players = {
			GetPlayers = function() return { player } end,
			GetPlayerByUserId = function() return player end,
			PlayerRemoving = removing,
			DisconnectPlayer = function(_self: any, _player: Player, _reason: string) table.insert(calls, "disconnect") end,
		}
		local friends = {
			BindLocalTransferHandler = function() end,
			PrepareAdmission = function() return table.freeze({ Ok = true, Operation = {}, SlotContext = table.freeze({ Kind = "Ordinary" }) }) end,
			CancelAdmission = function() table.insert(calls, "friends.cancel") end,
			BeginDeparture = function() return table.freeze({ Operation = {} }) end,
			CompleteDeparture = function() end,
		}
		local slots = {
			PrepareAdmission = function() return table.freeze({ Ok = false, Error = "NoSlot" }) end,
			BeginDeparture = function() return table.freeze({ Kind = "None" }) end,
			CompleteDeparture = function() end,
		}
		local teleport = {
			AttemptFailed = attemptFailed,
			GetFriendsContinuation = function() return table.freeze({ Status = "Absent" }) end,
			Teleport = function(_self: any, _participants: any, _destination: any)
				local attempt = #waits + 1
				table.insert(calls, `teleport:{attempt}`)
				return { Ok = false, AttemptId = `attempt-{attempt}` }
			end,
		}
		local coordinator = PlayerAdmissionCoordinator.new({
			PlayersModule = players,
			FriendsModule = friends,
			PlayerSlots = slots,
			CharacterModule = { RequestRespawn = function() return false end },
			TeleportModule = teleport,
			PlaceId = 1,
			Spawn = function(callback) callback() end,
			Wait = function(seconds) table.insert(waits, seconds) end,
		})
		scope:Defer(function() coordinator:Stop() end)
		coordinator:Initialize({ PlayerLoaded = loaded, IsLoaded = function() return true end })
		equal(table.concat(calls, ","), "friends.cancel,teleport:1,friends.cancel,teleport:2,friends.cancel,teleport:3,disconnect")
		equal(#waits, 2)
		equal(waits[1], 1)
		equal(waits[2], 1)
	end)

	test("LaunchData for another JobId uses only the typed targeted teleport continuation", function(scope)
		local loaded = Signal.new()
		local removing = Signal.new()
		local attemptFailed = Signal.new()
		scope:Defer(function() loaded:Destroy(); removing:Destroy(); attemptFailed:Destroy() end)
		local player = { UserId = 94, GetJoinData = function()
			return { LaunchData = "launch-data", ReferredByPlayerId = 0 }
		end } :: any
		local calls = {}
		local players = {
			GetPlayers = function() return { player } end,
			GetPlayerByUserId = function() return player end,
			PlayerRemoving = removing,
			DisconnectPlayer = function(_self: any, _player: Player, reason: string) table.insert(calls, `disconnect:{reason}`) end,
		}
		local friends = {
			BindLocalTransferHandler = function() end,
			PrepareAdmission = function() error("the intermediate server must not prepare a reserve") end,
			BeginDeparture = function() return table.freeze({ Operation = {}, FriendsToDisconnect = {} }) end,
			CompleteDeparture = function() end,
		}
		local slots = {
			BeginDeparture = function() return table.freeze({ Kind = "None" }) end,
			CompleteDeparture = function() end,
		}
		local teleport = {
			AttemptFailed = attemptFailed,
			GetFriendsContinuation = function() return table.freeze({ Status = "Absent" }) end,
			Teleport = function(_self: any, participants: any, destination: any, continuation: any)
				equal(participants[1], player)
				equal(destination.Kind, "ServerInstance")
				equal(destination.PlaceId, 1)
				equal(destination.ServerInstanceId, "target-job")
				equal(continuation.Version, 1)
				equal(continuation.Token, "reserve-token")
				equal(continuation.TargetJobId, "target-job")
				equal(continuation.Attempt, 1)
				table.insert(calls, "redirect")
				return { Ok = true, AttemptId = "redirect-one" }
			end,
		}
		local coordinator = PlayerAdmissionCoordinator.new({
			PlayersModule = players,
			FriendsModule = friends,
			PlayerSlots = slots,
			CharacterModule = { RequestRespawn = function() return false end },
			TeleportModule = teleport,
			PlaceId = 1,
			JobId = "local-job",
			DecodeJson = function(value: string)
				equal(value, "launch-data")
				return { Version = 1, Token = "reserve-token", TargetJobId = "target-job" }
			end,
		})
		scope:Defer(function() coordinator:Stop() end)
		coordinator:Initialize({ PlayerLoaded = loaded, IsLoaded = function() return true end })
		equal(table.concat(calls, ","), "redirect")
	end)

	test("invalid typed teleport continuation disconnects without reading LaunchData", function(scope)
		local loaded = Signal.new()
		local removing = Signal.new()
		local attemptFailed = Signal.new()
		scope:Defer(function() loaded:Destroy(); removing:Destroy(); attemptFailed:Destroy() end)
		local player = { UserId = 95, GetJoinData = function() error("LaunchData must stay unread") end } :: any
		local calls = {}
		local players = {
			GetPlayers = function() return { player } end,
			GetPlayerByUserId = function() return player end,
			PlayerRemoving = removing,
			DisconnectPlayer = function(_self: any, _player: Player, reason: string) table.insert(calls, reason) end,
		}
		local coordinator = PlayerAdmissionCoordinator.new({
			PlayersModule = players,
			FriendsModule = { BindLocalTransferHandler = function() end },
			PlayerSlots = {},
			CharacterModule = { RequestRespawn = function() return false end },
			TeleportModule = { AttemptFailed = attemptFailed, GetFriendsContinuation = function() return table.freeze({ Status = "Invalid", Code = "InvalidFriendsContinuationShape" }) end },
			PlaceId = 1,
			JobId = "local-job",
		})
		scope:Defer(function() coordinator:Stop() end)
		coordinator:Initialize({ PlayerLoaded = loaded, IsLoaded = function() return true end })
		equal(#calls, 1)
	end)

	test("friend redirect counts each early failure once and never starts a fourth attempt", function(scope)
		local loaded = Signal.new()
		local removing = Signal.new()
		local attemptFailed = Signal.new()
		scope:Defer(function() loaded:Destroy(); removing:Destroy(); attemptFailed:Destroy() end)
		local player = { UserId = 96 } :: any
		local calls = {}
		local waits = {}
		local players = {
			GetPlayers = function() return { player } end,
			GetPlayerByUserId = function() return player end,
			PlayerRemoving = removing,
			DisconnectPlayer = function(_self: any, _player: Player, _reason: string) table.insert(calls, "disconnect") end,
		}
		local friends = {
			BindLocalTransferHandler = function() end,
			PrepareAdmission = function() error("a non-target server must not prepare a reserve") end,
			BeginDeparture = function() return table.freeze({ Operation = {}, FriendsToDisconnect = {} }) end,
			CompleteDeparture = function() end,
		}
		local slots = {
			BeginDeparture = function() return table.freeze({ Kind = "None" }) end,
			CompleteDeparture = function() end,
		}
		local teleport = {
			AttemptFailed = attemptFailed,
			GetFriendsContinuation = function()
				return table.freeze({ Status = "Valid", Continuation = table.freeze({ Version = 1, Token = "reserve-token", TargetJobId = "target-job", Attempt = 1 }) })
			end,
			Teleport = function(_self: any, _participants: any, _destination: any, continuation: any)
				local attemptId = `redirect-{continuation.Attempt}`
				table.insert(calls, attemptId)
				attemptFailed:Fire(player, { AttemptId = attemptId })
				return { Ok = false, AttemptId = attemptId }
			end,
		}
		local coordinator = PlayerAdmissionCoordinator.new({
			PlayersModule = players,
			FriendsModule = friends,
			PlayerSlots = slots,
			CharacterModule = { RequestRespawn = function() return false end },
			TeleportModule = teleport,
			PlaceId = 1,
			JobId = "local-job",
			Spawn = function(callback) callback() end,
			Wait = function(seconds) table.insert(waits, seconds) end,
		})
		scope:Defer(function() coordinator:Stop() end)
		coordinator:Initialize({ PlayerLoaded = loaded, IsLoaded = function() return true end })
		equal(table.concat(calls, ","), "redirect-2,redirect-3,disconnect")
		equal(#waits, 1)
		equal(waits[1], 1)
	end)

	test("same-server transfer completes after one respawn and rolls back failures or departure without disconnect", function(scope)
		local loaded = Signal.new()
		local removing = Signal.new()
		local attemptFailed = Signal.new()
		scope:Defer(function() loaded:Destroy(); removing:Destroy(); attemptFailed:Destroy() end)
		local inviter = { UserId = 301 } :: any
		local target = { UserId = 302 } :: any
		local present = { [inviter.UserId] = inviter, [target.UserId] = target }
		local calls = {}
		local slotRolledBack = false
		local slotRollbackResult = true
		local boundHandler = nil :: any
		local respawnCallback = nil :: any
		local players = {
			GetPlayers = function() return {} end,
			GetPlayerByUserId = function(_self: any, userId: number) return present[userId] end,
			PlayerRemoving = removing,
			DisconnectPlayer = function() table.insert(calls, "disconnect") end,
		}
		local friends = {
			BindLocalTransferHandler = function(_self: any, handler: any) boundHandler = handler end,
			PrepareLocalTransfer = function(_self: any, observedInviter: Player, observedTarget: Player, offerId: string)
				equal(observedInviter, inviter); equal(observedTarget, target); truthy(offerId ~= "", "offer id missing")
				table.insert(calls, "friends.prepare")
				return { Ok = true, Operation = { Stage = "Prepared" } }
			end,
			CommitLocalTransfer = function() table.insert(calls, "friends.commit"); return true end,
			RollbackLocalTransfer = function(_self: any, _operation: any, category: string)
				truthy(slotRolledBack, "Friends terminal snapshot was published before slot-role rollback")
				table.insert(calls, `friends.rollback:{category}`)
				return true
			end,
			CompleteLocalTransfer = function() table.insert(calls, "friends.complete"); return true end,
			BeginDeparture = function() return table.freeze({ Operation = {}, FriendsToDisconnect = {} }) end,
			CompleteDeparture = function() end,
		}
		local slots = {
			PrepareTransfer = function(_self: any, observedTarget: Player, inviterUserId: number)
				equal(observedTarget, target); equal(inviterUserId, inviter.UserId)
				table.insert(calls, "slots.prepare")
				return { Ok = true, Operation = { Stage = "Prepared" } }
			end,
			CommitTransfer = function() table.insert(calls, "slots.commit"); return true end,
			RollbackTransfer = function()
				slotRolledBack = true
				table.insert(calls, "slots.rollback")
				return slotRollbackResult
			end,
			CompleteTransfer = function() table.insert(calls, "slots.complete"); return true end,
			BeginDeparture = function() return table.freeze({ Kind = "None" }) end,
			CompleteDeparture = function() end,
		}
		local characters = {
			RequestRespawn = function(_self: any, observedTarget: Player, callback: any)
				equal(observedTarget, target)
				table.insert(calls, "characters.respawn")
				respawnCallback = callback
				return true
			end,
			CancelRespawn = function() return true end,
		}
		local coordinator = PlayerAdmissionCoordinator.new({
			PlayersModule = players,
			FriendsModule = friends,
			PlayerSlots = slots,
			CharacterModule = characters,
			TeleportModule = { AttemptFailed = attemptFailed },
			PlaceId = 1,
		})
		scope:Defer(function() coordinator:Stop() end)
		coordinator:Initialize({ PlayerLoaded = loaded, IsLoaded = function() return true end })
		truthy(boundHandler ~= nil, "local transfer handler was not bound")
		local accepted = boundHandler(inviter, target, "offer-success")
		truthy(accepted.Ok, `local transfer rejected: {tostring(accepted.Error)}`)
		equal(table.concat(calls, ","), "friends.prepare,slots.prepare,slots.commit,friends.commit,characters.respawn")
		respawnCallback(true)
		equal(table.concat(calls, ","), "friends.prepare,slots.prepare,slots.commit,friends.commit,characters.respawn,slots.complete,friends.complete")

		table.clear(calls)
		slotRolledBack = false
		slotRollbackResult = false
		respawnCallback = nil
		local second = boundHandler(inviter, target, "offer-failure")
		truthy(second.Ok, "second sequential transfer did not start")
		respawnCallback(false)
		equal(table.concat(calls, ","), "friends.prepare,slots.prepare,slots.commit,friends.commit,characters.respawn,slots.rollback,friends.rollback:RespawnFailed")
		equal(table.find(calls, "disconnect"), nil, "respawn failure disconnected target")

		table.clear(calls)
		slotRolledBack = false
		slotRollbackResult = true
		respawnCallback = nil
		local watchdog = boundHandler(inviter, target, "offer-watchdog")
		truthy(watchdog.Ok and typeof(watchdog.Cancel) == "function", "handler did not return the watchdog cancellation callback")
		watchdog.Cancel("TransferFailed")
		truthy(table.find(calls, "slots.rollback") ~= nil, "watchdog did not roll back slots")
		truthy(table.find(calls, "friends.rollback:TransferFailed") ~= nil, "watchdog did not terminalize Friends")
		local watchdogCallCount = #calls
		respawnCallback(true)
		equal(#calls, watchdogCallCount, "late successful respawn completed a watchdog-cancelled transfer")

		table.clear(calls)
		slotRolledBack = false
		respawnCallback = nil
		local departure = boundHandler(inviter, target, "offer-departure")
		truthy(departure.Ok, "departure transfer did not start")
		present[target.UserId] = nil
		removing:Fire(target)
		truthy(table.find(calls, "friends.rollback:TargetIneligible") ~= nil, "departure did not roll back Friends")
		truthy(table.find(calls, "slots.rollback") ~= nil, "departure did not roll back slots")
		local callCount = #calls
		respawnCallback(false)
		equal(#calls, callCount, "late respawn result mutated completed departure")
		equal(table.find(calls, "disconnect"), nil, "departure transfer disconnected target")

		present[target.UserId] = target
		table.clear(calls)
		slotRolledBack = false
		respawnCallback = nil
		local inviterDeparture = boundHandler(inviter, target, "offer-inviter-departure")
		truthy(inviterDeparture.Ok, "inviter departure transfer did not start")
		present[inviter.UserId] = nil
		removing:Fire(inviter)
		truthy(table.find(calls, "slots.rollback") ~= nil, "inviter departure did not roll back slots")
		truthy(table.find(calls, "friends.rollback:TargetIneligible") ~= nil, "inviter departure did not terminalize Friends")
		local inviterDepartureCount = #calls
		respawnCallback(true)
		equal(#calls, inviterDepartureCount, "late respawn completed an inviter-departure transfer")
	end)

	return TestHarness.runAll("PlayerAdmissionCoordinatorTestRunner", tests)
end

return Runner
