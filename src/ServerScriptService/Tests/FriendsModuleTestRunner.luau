--!strict

--[[
	require(game.ServerScriptService.Tests.FriendsModuleTestRunner).runAll()
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local FriendsModule = require(ServerScriptService.Modules.Friends.FriendsModule)
local FriendsSnapshotClientProvider = require(ReplicatedStorage.Client.Friends.FriendsSnapshotClientProvider)
local FriendsClient = require(ReplicatedStorage.Client.Friends.FriendsClient)
local FriendsSnapshot = require(ReplicatedStorage.Shared.Friends.FriendsSnapshot)
local FriendsProtocol = require(ReplicatedStorage.Shared.Friends.FriendsProtocol)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local TestHarness = require(script.Parent.TestHarness)

local Runner = {}

local function equal(actual: any, expected: any, message: string?)
	if actual ~= expected then error(`{message or "assertEqual"}: expected={tostring(expected)} actual={tostring(actual)}`, 2) end
end

local function truthy(value: any, message: string)
	if not value then error(message, 2) end
end

local function makeModule(scope: any, minimumCapacity: number?): (any, any)
	local invitationState = "NotOwner"
	local owner: Player? = nil
	local now = 1000
	local queued = {}
	local delayed = {}
	local playersById = {}
	local friendshipResult = true
	local localEligibility: any = true
	local generated = 0
	local encodedLaunchData = {}
	local spawnCallbacks = {}
	local deferSpawn = false
	local acceptOpenPrompt = true
	local rolesByPlayer = {}
	local module = FriendsModule.new({
		Config = {
			GetRequired = function(_self: any, id: string)
				equal(id, "Friends")
				return table.freeze({ MinInviteCapacity = minimumCapacity or 1, MaxInviteCapacity = 3, ReserveLifetimeSeconds = 120 })
			end,
		},
		PlayerSlots = {
			CanCreateInvitation = function(_self: any, player: Player)
				playersById[player.UserId] = playersById[player.UserId] or player
				if invitationState == "Allowed" and owner == nil then owner = player end
				return invitationState
			end,
			GetPlayerSlot = function(_self: any, player: Player)
				if rolesByPlayer[player] ~= nil then return table.freeze({ Role = rolesByPlayer[player] }) end
				if invitationState == "Allowed" and owner == player then
					return table.freeze({ Role = "Owner" })
				end
				return nil
			end,
		},
		PlayersModule = {
			GetPlayerByUserId = function(_self: any, userId: number) return playersById[userId] end,
		},
		CheckFriendship = function(inviter: Player, targetUserId: number)
			if typeof(friendshipResult) == "function" then return friendshipResult(inviter, targetUserId) end
			return friendshipResult
		end,
		CanCreateLocalOffer = function(_inviter: Player, _target: Player)
			if localEligibility == true then return true end
			return false, localEligibility
		end,
		Spawn = function(callback: () -> ())
			if deferSpawn then table.insert(spawnCallbacks, callback) else callback() end
		end,
		Clock = function() return now end,
		Delay = function(seconds: number, callback: () -> ())
			table.insert(delayed, { Seconds = seconds, DueAt = now + seconds, Callback = callback })
		end,
		JobId = "test-job",
		EncodeJson = function(value: any)
			table.insert(encodedLaunchData, value)
			return "{}"
		end,
		GenerateId = function()
			generated += 1
			return `friends-test-{generated}`
		end,
		Communication = {
			RegisterHandler = function(_self: any, _messageType: string, _validator: any, _handler: any) end,
			Queue = function(_self: any, player: Player, messageType: string, payload: any, requestId: string?, _options: any)
				table.insert(queued, { Player = player, MessageType = messageType, Payload = payload, RequestId = requestId })
				return messageType ~= FriendsProtocol.MessageTypes.OpenPrompt or acceptOpenPrompt
			end,
		},
	})
	scope:Defer(function() module:Stop() end)
	module:Initialize()
	return module, {
		SetInvitationState = function(value: string) invitationState = value end,
		SetOpenPromptAccepted = function(value: boolean) acceptOpenPrompt = value end,
		SetRole = function(player: Player, role: string) rolesByPlayer[player] = role end,
		SetNow = function(value: number) now = value end,
		Queued = queued,
		Delayed = delayed,
		RunDueTimers = function()
			for _, timer in table.clone(delayed) do
				if not timer.Ran and timer.DueAt <= now then timer.Ran = true; timer.Callback() end
			end
		end,
		AddPresentPlayer = function(player: Player) playersById[player.UserId] = player end,
		RemovePresentPlayer = function(userId: number) playersById[userId] = nil end,
		SetFriendship = function(value: any) friendshipResult = value end,
		SetLocalEligibility = function(value: any) localEligibility = value end,
		EncodedLaunchData = encodedLaunchData,
		DeferSpawn = function(value: boolean) deferSpawn = value end,
		RunNextSpawn = function()
			local callback = table.remove(spawnCallbacks, 1)
			if callback ~= nil then callback() end
		end,
		SpawnCallbacks = spawnCallbacks,
	}
end

function Runner.runAll()
	local tests = {}
	local function test(name: string, callback: (any) -> ()) table.insert(tests, { Name = name, Callback = callback }) end

	test("Friends v1 persists only Current and returns an immutable presentation snapshot", function(scope)
		local module, controls = makeModule(scope)
		local player = { UserId = -42 } :: any
		module:SetMemento(player, module:CreateDefault(player))
		module:Run(player)
		controls.SetInvitationState("Allowed")
		local read = module:GetSnapshot(player)
		truthy(read.Ok, "loaded Friends snapshot was unavailable")
		equal(read.Snapshot.Min, 1)
		equal(read.Snapshot.Max, 3)
		equal(read.Snapshot.Current, 1)
		equal(read.Snapshot.ConnectedCount, 0)
		equal(read.Snapshot.CanCreateReserve, true)
		equal(read.Snapshot.IsSlotOwner, true)
		equal(#read.Snapshot.ConnectedUserIds, 0)
		equal(#read.Snapshot.Reserves, 0)
		truthy(not pcall(function() read.Snapshot.Current = 2 end), "Friends snapshot must be frozen")
		local memento = module:GetMemento(player)
		equal(memento.Current, 1)
		equal(memento.ConnectedCount, nil)
		equal(module:ToClientMemento(player, memento).Current, 1)
	end)

	test("SetCurrent changes only a valid persisted capacity", function(scope)
		local module = makeModule(scope)
		local player = { UserId = 55 } :: any
		module:SetMemento(player, { Current = 1 })
		module:Run(player)
		local dirty = 0
		local changed = 0
		module.MementoChanged:Connect(function() dirty += 1 end)
		module.SnapshotChanged:Connect(function(_player, payload)
			changed += 1
			equal(payload.Previous.Current, 1)
			equal(payload.Current.Current, 2)
		end)
		equal(module:SetCurrent(player, 0).Error, "OutOfRange")
		equal(module:SetCurrent(player, 1).Changed, false)
		equal(module:SetCurrent(player, 1.5).Error, "InvalidValue")
		equal(module:SetCurrent(player, 2).Changed, true)
		equal(module:GetMemento(player).Current, 2)
		equal(dirty, 1)
		equal(changed, 1)
	end)

	test("ordinary admission does not create a friend relation and publishes only final availability", function(scope)
		local module, controls = makeModule(scope)
		local player = { UserId = 56 } :: any
		module:SetMemento(player, { Current = 1 })
		module:Run(player)
		local events = 0
		module.SnapshotChanged:Connect(function(_player, payload)
			events += 1
			equal(payload.Previous.CanCreateReserve, false)
			equal(payload.Current.CanCreateReserve, true)
		end)
		local prepared = module:PrepareAdmission(player, table.freeze({ Kind = "Ordinary" }))
		truthy(prepared.Ok, "ordinary Friends admission was rejected")
		controls.SetInvitationState("Allowed")
		truthy(module:CommitAdmission(prepared.Operation), "Friends commit failed")
		equal(events, 0, "Friends commit emitted before coordinator event phase")
		module:EmitAdmissionEvents(prepared.Operation)
		equal(events, 1)
		equal(module:GetSnapshot(player).Snapshot.ConnectedCount, 0)
	end)

	test("invalid Friends mementos fail closed and missing Current reconciles to minimum", function(scope)
		local module = makeModule(scope)
		local player = { UserId = 57 } :: any
		equal(module:ValidateMemento(player, { Current = 1.5 }), false)
		equal(module:ValidateMemento(player, { Current = 4 }), false)
		equal(module:ReconcileMemento(player, {}, 1).Current, 1)
	end)

	test("expanded Friends snapshot rejects malformed occupancy and freezes ordered presentation", function(_scope)
		local valid, snapshot = FriendsSnapshot.validate({
			Min = 1,
			Max = 3,
			Current = 3,
			ConnectedCount = 1,
			CanCreateReserve = true,
			IsSlotOwner = true,
			ConnectedUserIds = { 12 },
			Reserves = {
				{ TargetUserId = 25, ExpiresAtServerTime = 1000.5, Kind = "Native" },
			},
		})
		truthy(valid, "expanded Friends snapshot was rejected")
		equal(snapshot.ConnectedUserIds[1], 12)
		equal(snapshot.Reserves[1].TargetUserId, 25)
		equal(snapshot.Reserves[1].Kind, "Native")
		truthy(not pcall(function() snapshot.Reserves[1].TargetUserId = 26 end), "reserve entries must be frozen")
		equal(FriendsSnapshot.validate({
			Min = 1,
			Max = 3,
			Current = 1,
			ConnectedCount = 1,
			CanCreateReserve = false,
			IsSlotOwner = false,
			ConnectedUserIds = { 12 },
			Reserves = { { TargetUserId = 12, ExpiresAtServerTime = 1000, Kind = "Native" } },
		}), false)
		local incomingValid, incoming = FriendsSnapshot.validate({
			Min = 1, Max = 3, Current = 1, ConnectedCount = 0, CanCreateReserve = false,
			IsSlotOwner = true, ConnectedUserIds = {}, Reserves = {},
			IncomingOffer = {
				OfferId = "offer", InviterUserId = 44, InviterUsername = "owner",
				InviterDisplayName = "Owner", ExpiresAtServerTime = 1100, Status = "Processing",
			},
		})
		truthy(incomingValid, "incoming offer snapshot was rejected")
		equal(incoming.IncomingOffer.Status, "Processing")
	end)

	test("reserve and connection projection use server time and publish the remaining owner after departure", function(scope)
		local module, controls = makeModule(scope)
		local owner = { UserId = 61 } :: any
		local friend = { UserId = 62 } :: any
		module:SetMemento(owner, { Current = 2 })
		module:SetMemento(friend, { Current = 1 })
		module:Run(owner)
		module:Run(friend)
		controls.SetInvitationState("Allowed")
		module:RequestInvite(owner, { TargetUserId = friend.UserId }, "request-1")
		local reserved = module:GetSnapshot(owner).Snapshot
		equal(reserved.Reserves[1].TargetUserId, friend.UserId)
		equal(reserved.Reserves[1].ExpiresAtServerTime, 1010, "new native reserve must be provisional before API success")
		local openPrompt: any = nil
		for _, queued in controls.Queued do
			if queued.MessageType == FriendsProtocol.MessageTypes.OpenPrompt then
				openPrompt = queued
				break
			end
		end
		truthy(openPrompt ~= nil, "Friends.OpenPrompt was not queued")
		equal(openPrompt.Player, owner, "Friends.OpenPrompt was queued for the wrong player")
		equal(openPrompt.MessageType, FriendsProtocol.MessageTypes.OpenPrompt)
		equal(openPrompt.RequestId, "request-1")
		local launchEnvelope = controls.EncodedLaunchData[1]
		equal(launchEnvelope.Version, 1)
		equal(launchEnvelope.TargetJobId, "test-job")
		truthy(typeof(launchEnvelope.Token) == "string" and launchEnvelope.Token ~= "", "LaunchData token was not opaque")
		equal(launchEnvelope.ReservedServerAccessCode, nil, "reserved-server access code leaked into LaunchData")
		module:HandlePlatformResult(owner, { Generation = openPrompt.Payload.Generation, Result = "PromptRequested" }, "request-1")
		equal(module:GetSnapshot(owner).Snapshot.Reserves[1].ExpiresAtServerTime, 1120, "API success must establish the full reserve")
		module:HandlePromptClosed(owner, { Generation = openPrompt.Payload.Generation }, "request-1")
		local prepared = module:PrepareAdmission(friend, {
			Kind = "Invitation",
			Token = controls.EncodedLaunchData[1].Token,
			TargetJobId = "test-job",
		})
		truthy(prepared.Ok, "friend admission was rejected")
		truthy(module:CommitAdmission(prepared.Operation), "friend admission did not commit")
		module:EmitAdmissionEvents(prepared.Operation)
		local connected = module:GetSnapshot(owner).Snapshot
		equal(connected.ConnectedUserIds[1], friend.UserId)
		equal(#connected.Reserves, 0)
		local departureEvents = 0
		local projection = FriendsSnapshotClientProvider.new()
		projection:SetMemento(connected); projection:Run()
		scope:Defer(function() projection:Stop() end)
		module.SnapshotChanged:Connect(function(player, payload)
			if player == owner then
				truthy(projection:TryApply(payload.Previous, payload.Current), "departure broke the published snapshot chain")
				if payload.Previous.ConnectedCount == 1 and payload.Current.ConnectedCount == 0 then departureEvents += 1 end
			end
		end)
		module:BeginDeparture(friend, "KeepPublishedFriends")
		equal(module:GetSnapshot(owner).Snapshot.ConnectedCount, 0)
		equal(departureEvents, 1)
		truthy(FriendsSnapshot.equal(projection:GetSnapshot(), module:GetSnapshot(owner).Snapshot), "client did not apply final departure availability")
		equal(projection:GetSnapshot().CanCreateReserve, true, "departed target kept the old attempt busy")
	end)

	test("duplicate invite is rejected and an early expiry wake reschedules and publishes removal", function(scope)
		local module, controls = makeModule(scope)
		local owner = { UserId = 63 } :: any
		local target = { UserId = 64 } :: any
		module:SetMemento(owner, { Current = 2 })
		module:Run(owner)
		controls.SetInvitationState("Allowed")
		local removals = 0
		module.SnapshotChanged:Connect(function(player: Player, payload: any)
			if player == owner and #payload.Previous.Reserves == 1 and #payload.Current.Reserves == 0 then
				removals += 1
			end
		end)

		module:RequestInvite(owner, { TargetUserId = target.UserId }, "request-1")
		equal(#controls.Delayed, 2)
		equal(controls.Delayed[2].Seconds, 10)
		local initialPrompt = controls.Queued[#controls.Queued]
		equal(initialPrompt.MessageType, FriendsProtocol.MessageTypes.OpenPrompt)
		module:HandlePlatformResult(owner, { Generation = initialPrompt.Payload.Generation, Result = "PromptRequested" }, "request-1")
		local fullReserveTimer = controls.Delayed[#controls.Delayed]
		equal(fullReserveTimer.Seconds, 120)
		module:RequestInvite(owner, { TargetUserId = target.UserId }, "request-2")
		local duplicateResult = controls.Queued[#controls.Queued]
		equal(duplicateResult.MessageType, FriendsProtocol.MessageTypes.InviteResult)
		equal(duplicateResult.Payload.Category, "AnotherPromptActive")
		local openPrompts = 0
		for _, message in controls.Queued do
			if message.MessageType == FriendsProtocol.MessageTypes.OpenPrompt then openPrompts += 1 end
		end
		equal(openPrompts, 1, "duplicate request must not queue a second platform prompt")

		controls.SetNow(1119.75)
		local timerCount = #controls.Delayed
		fullReserveTimer.Callback()
		equal(#controls.Delayed, timerCount + 1, "early timer wake must schedule the remaining interval")
		equal(controls.Delayed[#controls.Delayed].Seconds, 0.25)
		equal(#module:GetSnapshot(owner).Snapshot.Reserves, 1)
		controls.SetNow(1120)
		controls.Delayed[#controls.Delayed].Callback()
		equal(#module:GetSnapshot(owner).Snapshot.Reserves, 0)
		equal(removals, 1, "deadline removal must publish one authoritative snapshot")
	end)

	test("native retry renews one full-capacity hold and ignores the old deadline and close", function(scope)
		local module, controls = makeModule(scope)
		local owner = { UserId = 601 } :: any
		module:SetMemento(owner, { Current = 1 })
		module:Run(owner)
		controls.SetInvitationState("Allowed")
		local function promptFor(id: string): any
			for _, message in controls.Queued do
				if message.MessageType == FriendsProtocol.MessageTypes.OpenPrompt and message.RequestId == id then return message end
			end
			return nil
		end
		module:RequestInvite(owner, { TargetUserId = 602 }, "first")
		local first = promptFor("first")
		truthy(first ~= nil, "first prompt missing")
		module:HandlePlatformResult(owner, { Generation = first.Payload.Generation, Result = "PromptRequested" }, "first")
		module:HandlePromptClosed(owner, { Generation = first.Payload.Generation }, "first")
		controls.SetNow(1050)
		module:RequestInvite(owner, { TargetUserId = 602 }, "retry")
		local retry = promptFor("retry")
		truthy(retry ~= nil, "existing full-capacity reserve blocked repeat prompt")
		local renewed = module:GetSnapshot(owner).Snapshot
		equal(#renewed.Reserves, 1)
		equal(renewed.Reserves[1].ExpiresAtServerTime, 1120, "retry preparation must preserve the previous full reserve")
		equal(controls.EncodedLaunchData[1].Token, controls.EncodedLaunchData[2].Token)
		truthy(first.Payload.Generation ~= retry.Payload.Generation, "retry reused prompt generation")
		module:HandlePromptClosed(owner, { Generation = first.Payload.Generation }, "first")
		module:RequestInvite(owner, { TargetUserId = 602 }, "busy")
		equal(promptFor("busy"), nil, "old close released new prompt ownership")
		module:HandlePlatformResult(owner, { Generation = retry.Payload.Generation, Result = "PromptRequested" }, "retry")
		equal(module:GetSnapshot(owner).Snapshot.Reserves[1].ExpiresAtServerTime, 1170, "only API success may renew the full reserve")
		module:HandlePromptClosed(owner, { Generation = retry.Payload.Generation }, "retry")
		controls.SetNow(1120)
		for _, delayed in table.clone(controls.Delayed) do delayed.Callback() end
		equal(#module:GetSnapshot(owner).Snapshot.Reserves, 1, "old expiry removed renewed hold")
		controls.SetNow(1170)
		equal(#module:GetSnapshot(owner).Snapshot.Reserves, 0)
	end)

	test("native attempt deadline releases global ownership while prompt closure remains inert", function(scope)
		local module, controls = makeModule(scope)
		local owner = { UserId = 65 } :: any
		module:SetMemento(owner, { Current = 2 })
		module:Run(owner)
		controls.SetInvitationState("Allowed")
		module:RequestInvite(owner, { TargetUserId = 66 }, "request-1")
		local firstPrompt: any = nil
		for _, message in controls.Queued do
			if message.MessageType == FriendsProtocol.MessageTypes.OpenPrompt then firstPrompt = message end
		end
		truthy(firstPrompt ~= nil, "first platform prompt was not queued")
		module:HandlePlatformResult(owner, {
			Generation = firstPrompt.Payload.Generation, Result = "PromptRequested",
		}, "request-1")
		module:HandlePromptClosed(owner, { Generation = firstPrompt.Payload.Generation }, "request-1")
		equal(#module:GetSnapshot(owner).Snapshot.Reserves, 1,
			"empty recipientIds must not be interpreted as cancellation")

		module:RequestInvite(owner, { TargetUserId = 66 }, "premature-repeat")
		equal(controls.Queued[#controls.Queued].Payload.Category, "AnotherPromptActive", "closure must not release attempt ownership")
		controls.SetNow(1010)
		controls.RunDueTimers()
		equal(module:GetSnapshot(owner).Snapshot.CanCreateReserve, true, "ten-second timer did not release global ownership")
		module:RequestInvite(owner, { TargetUserId = 66 }, "request-2")
		local repeatedPrompt = controls.Queued[#controls.Queued]
		equal(repeatedPrompt.MessageType, FriendsProtocol.MessageTypes.OpenPrompt, "same target must permit repeat")
		module:HandlePlatformResult(owner, {
			Generation = repeatedPrompt.Payload.Generation, Result = "PromptRequested",
		}, "request-2")
		module:HandlePromptClosed(owner, { Generation = repeatedPrompt.Payload.Generation }, "request-2")
		controls.SetNow(1020)
		controls.RunDueTimers()
		module:RequestInvite(owner, { TargetUserId = 67 }, "request-3")
		local prompts = 0
		for _, message in controls.Queued do
			if message.MessageType == FriendsProtocol.MessageTypes.OpenPrompt then prompts += 1 end
		end
		equal(prompts, 3, "attempt deadline must release global ownership for another available target")
	end)

	test("native preparation shares the ten-second deadline with friendship and ignores every late generation", function(scope)
		local module, controls = makeModule(scope)
		local owner = { UserId = 701 } :: any
		module:SetMemento(owner, { Current = 2 }); module:Run(owner)
		controls.SetInvitationState("Allowed")
		controls.DeferSpawn(true)
		local function promptFor(id: string): any
			for _, message in controls.Queued do
				if message.MessageType == FriendsProtocol.MessageTypes.OpenPrompt and message.RequestId == id then return message end
			end
			return nil
		end
		module:RequestInvite(owner, { TargetUserId = 702 }, "slow-check")
		equal(controls.Delayed[1].Seconds, 10, "friendship deadline must not use reserve lifetime")
		controls.SetNow(1008); controls.RunNextSpawn()
		local old = promptFor("slow-check")
		truthy(old ~= nil, "valid friendship did not continue to native preparation")
		equal(module:GetSnapshot(owner).Snapshot.Reserves[1].ExpiresAtServerTime, 1010, "native preparation restarted the deadline")
		equal(controls.Delayed[#controls.Delayed].Seconds, 2, "native stage must get only the remaining attempt time")
		controls.SetNow(1010); controls.RunDueTimers()
		local expired = module:GetSnapshot(owner).Snapshot
		equal(#expired.Reserves, 0, "missing API result retained provisional capacity")
		equal(expired.CanCreateReserve, true, "missing API result retained global ownership")
		controls.DeferSpawn(false)
		module:RequestInvite(owner, { TargetUserId = 702 }, "fresh-attempt")
		local fresh = promptFor("fresh-attempt")
		truthy(fresh ~= nil, "attempt timeout blocked a later request")
		module:HandlePlatformResult(owner, { Generation = old.Payload.Generation, Result = "PromptRequested" }, "slow-check")
		module:HandlePlatformResult(owner, { Generation = old.Payload.Generation, Result = "TemporaryError" }, "slow-check")
		module:HandlePlatformResult(owner, { Generation = old.Payload.Generation, Result = "PromptRequested" }, "fresh-attempt")
		equal(module:GetSnapshot(owner).Snapshot.Reserves[1].ExpiresAtServerTime, 1020, "late result renewed or removed a newer provisional hold")
		controls.SetNow(1011)
		module:HandlePlatformResult(owner, { Generation = fresh.Payload.Generation, Result = "PromptRequested" }, "fresh-attempt")
		equal(module:GetSnapshot(owner).Snapshot.Reserves[1].ExpiresAtServerTime, 1131, "full reserve must start at the accepted API result")
		controls.SetNow(1020); controls.RunDueTimers()
		equal(module:GetSnapshot(owner).Snapshot.Reserves[1].ExpiresAtServerTime, 1131, "attempt timeout removed a full reserve")
		equal(module:GetSnapshot(owner).Snapshot.CanCreateReserve, true)
	end)

	test("failed native retry preserves the previous full reserve and releases only its attempt", function(scope)
		for _, outcome in { "InviteUnavailable", "TemporaryError", "Timeout", "QueueFailure" } do
			local module, controls = makeModule(scope)
			local owner = { UserId = 703 } :: any
			module:SetMemento(owner, { Current = 1 }); module:Run(owner)
			controls.SetInvitationState("Allowed")
			local function promptFor(id: string): any
				for _, message in controls.Queued do
					if message.MessageType == FriendsProtocol.MessageTypes.OpenPrompt and message.RequestId == id then return message end
				end
				return nil
			end
			module:RequestInvite(owner, { TargetUserId = 704 }, "establish")
			local established = promptFor("establish")
			module:HandlePlatformResult(owner, { Generation = established.Payload.Generation, Result = "PromptRequested" }, "establish")
			controls.SetNow(1010); controls.RunDueTimers()
			if outcome == "QueueFailure" then controls.SetOpenPromptAccepted(false) end
			module:RequestInvite(owner, { TargetUserId = 704 }, "retry-failure")
			local retry = promptFor("retry-failure")
			truthy(retry ~= nil, "full capacity rejected the existing target retry")
			equal(module:GetSnapshot(owner).Snapshot.Reserves[1].ExpiresAtServerTime, 1120, "preparation extended an old reserve")
			if outcome == "Timeout" then
				controls.SetNow(1020); controls.RunDueTimers()
			elseif outcome ~= "QueueFailure" then
				module:HandlePlatformResult(owner, { Generation = retry.Payload.Generation, Result = outcome }, "retry-failure")
			end
			local kept = module:GetSnapshot(owner).Snapshot
			equal(#kept.Reserves, 1, `retry outcome {outcome} destroyed the prior full reserve`)
			equal(kept.Reserves[1].ExpiresAtServerTime, 1120)
			module:HandlePlatformResult(owner, { Generation = retry.Payload.Generation, Result = "PromptRequested" }, "retry-failure")
			equal(module:GetSnapshot(owner).Snapshot.Reserves[1].ExpiresAtServerTime, 1120, "late success resurrected a failed retry")
			controls.SetOpenPromptAccepted(true)
			module:RequestInvite(owner, { TargetUserId = 704 }, "after-failure")
			truthy(promptFor("after-failure") ~= nil, "failed retry retained global attempt ownership")
		end
	end)

	test("an old full reserve becomes provisional while its retry is checking friendship or awaiting the API", function(scope)
		for _, boundary in { "Friendship", "Platform" } do
			for _, outcome in { "Success", "Failure", "Timeout" } do
				local module, controls = makeModule(scope)
				local owner = { UserId = 707 } :: any
				module:SetMemento(owner, { Current = 2 }); module:Run(owner)
				controls.SetInvitationState("Allowed")
				local function promptFor(id: string): any
					for _, message in controls.Queued do
						if message.MessageType == FriendsProtocol.MessageTypes.OpenPrompt and message.RequestId == id then return message end
					end
					return nil
				end
				module:RequestInvite(owner, { TargetUserId = 708 }, "old-full")
				local first = promptFor("old-full")
				module:HandlePlatformResult(owner, { Generation = first.Payload.Generation, Result = "PromptRequested" }, "old-full")
				controls.SetNow(1119); controls.RunDueTimers()
				local provider = FriendsSnapshotClientProvider.new()
				provider:SetMemento(module:GetSnapshot(owner).Snapshot); provider:Run()
				scope:Defer(function() provider:Stop() end)
				local nextMessage = #controls.Queued + 1
				local function applyQueued(requireHold: boolean)
					for index = nextMessage, #controls.Queued do
						local message = controls.Queued[index]
						if message.Player == owner and message.MessageType == FriendsProtocol.MessageTypes.SnapshotChanged then
							truthy(provider:TryApply(message.Payload.Previous, message.Payload.Current), "retry expiry broke its snapshot baseline")
							if requireHold then
								equal(#provider:GetSnapshot().Reserves, 1, "old expiry retired the current retry target")
								equal(provider:GetSnapshot().Reserves[1].TargetUserId, 708)
							end
						end
					end
					nextMessage = #controls.Queued + 1
				end
				controls.DeferSpawn(boundary == "Friendship")
				controls.SetFriendship(outcome ~= "Failure" or boundary == "Platform")
				module:RequestInvite(owner, { TargetUserId = 708 }, "retry-expiring")
				applyQueued(true)
				controls.SetNow(1120); controls.RunDueTimers()
				applyQueued(true)
				equal(provider:GetSnapshot().Reserves[1].ExpiresAtServerTime, 1129, "expired full reserve must retain only the current attempt deadline")
				if outcome == "Timeout" then
					controls.SetNow(1129); controls.RunDueTimers()
					if boundary == "Friendship" then controls.RunNextSpawn() end
				else
					controls.SetNow(1121)
					if boundary == "Friendship" then controls.RunNextSpawn() end
				end
				local retry = promptFor("retry-expiring")
				if boundary == "Platform" or outcome == "Success" then
					truthy(retry ~= nil, "active retry did not reach native preparation")
					module:HandlePlatformResult(owner, {
						Generation = retry.Payload.Generation,
						Result = if outcome == "Failure" then "TemporaryError" else "PromptRequested",
					}, "retry-expiring")
				end
				applyQueued(outcome == "Success")
				if outcome == "Success" then
					equal(provider:GetSnapshot().Reserves[1].ExpiresAtServerTime, 1241, "valid retry did not establish its new full reserve")
					controls.SetNow(1129); controls.RunDueTimers(); applyQueued(true)
					equal(provider:GetSnapshot().Reserves[1].ExpiresAtServerTime, 1241, "attempt expiry removed the renewed full reserve")
				else
					equal(#provider:GetSnapshot().Reserves, 0, "failed retry retained a provisional reserve after the old full reserve expired")
				end
				equal(provider:GetSnapshot().CanCreateReserve, true)
				truthy(FriendsSnapshot.equal(provider:GetSnapshot(), module:GetSnapshot(owner).Snapshot), "retry expiry left the client behind the server")
			end
		end
	end)

	test("local offer and processing keep their own lifetimes beyond native attempt deadlines", function(scope)
		local module, controls = makeModule(scope)
		local owner = { UserId = 705, Name = "Owner", DisplayName = "Owner" } :: any
		local target = { UserId = 706, Name = "Target", DisplayName = "Target" } :: any
		for _, player in { owner, target } do
			module:SetMemento(player, { Current = 2 }); module:Run(player); controls.AddPresentPlayer(player)
		end
		controls.SetInvitationState("Allowed")
		module:BindLocalTransferHandler(function() return { Ok = true, Cancel = function() end } end)
		module:RequestInvite(owner, { TargetUserId = target.UserId }, "local-lifetime")
		local offer = module:GetSnapshot(target).Snapshot.IncomingOffer
		equal(offer.ExpiresAtServerTime, 1120)
		controls.SetNow(1010); controls.RunDueTimers()
		equal(module:GetSnapshot(target).Snapshot.IncomingOffer.Status, "Open", "native deadline shortened local offer lifetime")
		module:RespondLocalOffer(target, { OfferId = offer.OfferId, Decision = "Accept" }, "local-response")
		equal(module:GetSnapshot(target).Snapshot.IncomingOffer.ExpiresAtServerTime, 1040)
		controls.SetNow(1020); controls.RunDueTimers()
		equal(module:GetSnapshot(target).Snapshot.IncomingOffer.Status, "Processing", "native deadline shortened local transfer lifetime")
		controls.RemovePresentPlayer(target.UserId)
		module:BeginDeparture(target, "KeepPublishedFriends")
		equal(module:GetSnapshot(target).Snapshot.IncomingOffer, nil)
		equal(#module:GetSnapshot(owner).Snapshot.Reserves, 0, "departed local participant retained its hold")
	end)

	test("client Friends facade follows only the transactional snapshot provider", function(scope)
		local provider = FriendsSnapshotClientProvider.new()
		local client = FriendsClient.new(provider)
		local ready = Signal.new()
		scope:Defer(function() ready:Destroy(); client:Stop() end)
		client:Initialize({ Ready = ready })
		equal(client:GetSnapshot().Error, "NotReady")
		provider:SetMemento({
			Min = 1, Max = 3, Current = 1, ConnectedCount = 0, CanCreateReserve = false,
			IsSlotOwner = false, ConnectedUserIds = {}, Reserves = {},
		})
		provider:Run()
		ready:Fire(1)
		local read = client:GetSnapshot()
		truthy(read.Ok, "client did not publish the completed provider snapshot")
		equal(read.Snapshot.Current, 1)
		local events = 0
		client.SnapshotChanged:Connect(function(payload)
			events += 1
			equal(payload.Previous.Current, 1)
			equal(payload.Current.Current, 2)
		end)
		provider:Stop()
		provider:SetMemento({
			Min = 1, Max = 3, Current = 2, ConnectedCount = 0, CanCreateReserve = true,
			IsSlotOwner = true, ConnectedUserIds = {}, Reserves = {},
		})
		provider:Run()
		ready:Fire(2)
		equal(events, 1)
	end)

	test("client attempt reports API phases and releases by deadline or recovery rather than platform closure", function(scope)
		local provider = FriendsSnapshotClientProvider.new()
		local ready = Signal.new()
		local promptClosed = Signal.new()
		local handlers = {}
		local prepare: any = nil
		local requests = 0
		local communication = {
			RegisterHandler = function(_self: any, messageType: string, callback: any)
				handlers[messageType] = callback
			end,
			Queue = function(_self: any, _messageType: string, _payload: any, _requestId: string?, _options: any)
				return true
			end,
			RegisterResyncPreparation = function(_self: any, callback: any)
				prepare = callback
				return function() prepare = nil end
			end,
		}
		local localPlayer = {} :: any
		local now = 0
		local timers = {}
		local client = FriendsClient.new(provider, {
			Communication = communication,
			LocalPlayer = localPlayer,
			Clock = function() return now end,
			Delay = function(_seconds, callback) table.insert(timers, callback) end,
			Spawn = function(callback) callback() end,
			SocialService = {
				GameInvitePromptClosed = promptClosed,
				CanSendGameInviteAsync = function(_self: any, _player: Player, _targetUserId: number) return true end,
				PromptGameInvite = function(_self: any, _player: Player, _options: any) end,
			},
			GenerateRequestId = function()
				requests += 1
				return `request-{requests}`
			end,
		})
		scope:Defer(function()
			client:Stop()
			promptClosed:Destroy()
			ready:Destroy()
		end)
		provider:SetMemento({
			Min = 1, Max = 3, Current = 1, ConnectedCount = 0, CanCreateReserve = true,
			IsSlotOwner = true, ConnectedUserIds = {}, Reserves = {},
		})
		provider:Run()
		client:Initialize({ Ready = ready })
		ready:Fire()
		local transitions = 0
		client.PromptStateChanged:Connect(function(payload)
			transitions += 1
			if transitions == 1 then
				equal(payload.Previous.IsOpen, nil)
				equal(payload.Current.IsOpen, nil)
				equal(payload.Current.Phase, "Requesting")
				equal(payload.Current.TargetUserId, 77)
			end
		end)
		truthy(client:RequestInvite(77).Ok, "invite request was not queued")
		equal(client:RequestInvite(78).Error, "AnotherPromptActive", "pending request must block duplicate prompt admission")
		handlers[FriendsProtocol.MessageTypes.OpenPrompt]({
			Generation = "generation-1",
			TargetUserId = 77,
			LaunchData = "{}",
		}, "request-1")
		equal(client:GetPromptState().Phase, "PromptRequested")
		equal(client:GetPromptState().IsOpen, nil, "API return must not claim observed platform visibility")
		handlers[FriendsProtocol.MessageTypes.InviteResult]({ Category = "PromptRequested", Generation = "generation-1" }, "request-1")
		promptClosed:Fire({} :: any, { 77 })
		equal(client:GetPromptState().IsBusy, true, "another player's close signal must be ignored")
		promptClosed:Fire(localPlayer, { 77 })
		equal(client:GetPromptState().IsBusy, true, "platform closure must not own the attempt")
		equal(transitions, 3)
		now = 10
		for _, callback in table.clone(timers) do callback() end
		equal(client:GetPromptState().IsBusy, false)
		truthy(client:RequestInvite(78).Ok, "second invite request was not queued")
		handlers[FriendsProtocol.MessageTypes.OpenPrompt]({
			Generation = "generation-2",
			TargetUserId = 78,
			LaunchData = "{}",
		}, "request-2")
		equal(client:GetPromptState().Phase, "PromptRequested")
		handlers[FriendsProtocol.MessageTypes.InviteResult]({ Category = "PromptRequested", Generation = "generation-2" }, "request-2")
		truthy(prepare ~= nil, "resync preparation was not registered")
		prepare("test")
		equal(client:GetPromptState().IsBusy, false, "recovery must retire the old attempt")
		promptClosed:Fire(localPlayer, { 78 })
		equal(client:GetPromptState().IsBusy, false)
	end)

	test("authoritative reserve expiry retires its client attempt and permits exactly one new API call", function(scope)
		local ready = Signal.new()
		local handlers = {}
		local promptClosed = Signal.new()
		local queued = 0
		local promptCalls = 0
		local initial = {
			Min = 1, Max = 3, Current = 2, ConnectedCount = 0, CanCreateReserve = true,
			IsSlotOwner = true, ConnectedUserIds = {}, Reserves = {},
		}
		local client = FriendsClient.new({
			GetSnapshot = function() return initial end,
			TryApply = function() return true end,
		}, {
			Communication = {
				RegisterHandler = function(_self: any, messageType: string, callback: any) handlers[messageType] = callback end,
				RegisterResyncPreparation = function() return function() end end,
				Queue = function()
					queued += 1
					return true
				end,
				RequestResync = function() end,
			},
			LocalPlayer = {} :: any,
			Clock = function() return 1000 end,
			Delay = function() end,
			Spawn = function(callback) callback() end,
			SocialService = {
				GameInvitePromptClosed = promptClosed,
				CanSendGameInviteAsync = function() return true end,
				PromptGameInvite = function() promptCalls += 1 end,
			},
			GenerateRequestId = (function()
				local id = 0
				return function()
					id += 1
					return `request-{id}`
				end
			end)(),
		})
		scope:Defer(function()
			client:Stop()
			promptClosed:Destroy()
			ready:Destroy()
		end)
		client:Initialize({ Ready = ready })
		ready:Fire()
		truthy(client:RequestInvite(77).Ok, "first request was rejected")
		handlers[FriendsProtocol.MessageTypes.OpenPrompt]({
			Generation = "generation-1", TargetUserId = 77, LaunchData = "{}",
		}, "request-1")
		equal(promptCalls, 1)
		handlers[FriendsProtocol.MessageTypes.InviteResult]({ Category = "PromptRequested", Generation = "generation-1" }, "request-1")
		local reserved = {
			Min = 1, Max = 3, Current = 2, ConnectedCount = 0, CanCreateReserve = true,
			IsSlotOwner = true, ConnectedUserIds = {}, Reserves = { { TargetUserId = 77, ExpiresAtServerTime = 1120, Kind = "Native" } },
		}
		handlers[FriendsProtocol.MessageTypes.SnapshotChanged]({ Previous = initial, Current = reserved })
		equal(client:GetPromptState().IsBusy, true)
		handlers[FriendsProtocol.MessageTypes.SnapshotChanged]({ Previous = reserved, Current = initial })
		equal(client:GetPromptState().IsBusy, false, "expiry snapshot must retire the attempt")
		truthy(client:RequestInvite(77).Ok, "target did not unlock after authoritative expiry")
		equal(client:RequestInvite(78).Error, "AnotherPromptActive", "second pending request must remain blocked")
		handlers[FriendsProtocol.MessageTypes.OpenPrompt]({
			Generation = "generation-2", TargetUserId = 77, LaunchData = "{}",
		}, "request-2")
		equal(promptCalls, 2, "new eligible attempt must call PromptGameInvite exactly once")
		truthy(queued > 0, "client fixture did not exercise the communication path")
	end)

	test("expiry while CanSendGameInviteAsync yields retires the request before any platform side effect", function(scope)
		local ready = Signal.new()
		local promptClosed = Signal.new()
		local handlers = {}
		local promptCalls = 0
		local capabilityThread: thread? = nil
		local initial = {
			Min = 1, Max = 3, Current = 2, ConnectedCount = 0, CanCreateReserve = true,
			IsSlotOwner = true, ConnectedUserIds = {}, Reserves = {},
		}
		local reserved = {
			Min = 1, Max = 3, Current = 2, ConnectedCount = 0, CanCreateReserve = true,
			IsSlotOwner = true, ConnectedUserIds = {}, Reserves = { { TargetUserId = 77, ExpiresAtServerTime = 1120, Kind = "Native" } },
		}
		local client = FriendsClient.new({
			GetSnapshot = function() return initial end,
			TryApply = function() return true end,
		}, {
			Communication = {
				RegisterHandler = function(_self: any, messageType: string, callback: any) handlers[messageType] = callback end,
				RegisterResyncPreparation = function() return function() end end,
				Queue = function() return true end,
				RequestResync = function() end,
			},
			LocalPlayer = {} :: any,
			Clock = function() return 1000 end,
			Delay = function() end,
			Spawn = function(callback)
				capabilityThread = coroutine.create(callback)
				truthy(coroutine.resume(assert(capabilityThread)), "capability work did not start")
			end,
			SocialService = {
				GameInvitePromptClosed = promptClosed,
				CanSendGameInviteAsync = function() coroutine.yield() return true end,
				PromptGameInvite = function() promptCalls += 1 end,
			},
			GenerateRequestId = function() return "request-1" end,
		})
		scope:Defer(function()
			client:Stop()
			promptClosed:Destroy()
			ready:Destroy()
		end)
		client:Initialize({ Ready = ready })
		ready:Fire()
		truthy(client:RequestInvite(77).Ok, "initial request was rejected")
		handlers[FriendsProtocol.MessageTypes.SnapshotChanged]({ Previous = initial, Current = reserved })
		local openThread = coroutine.create(function()
			handlers[FriendsProtocol.MessageTypes.OpenPrompt]({
				Generation = "generation-1", TargetUserId = 77, LaunchData = "{}",
			}, "request-1")
		end)
		truthy(coroutine.resume(openThread), "OpenPrompt handler did not reach yielding platform capability check")
		equal(coroutine.status(openThread), "dead", "transport handler must not yield with the platform capability check")
		equal(coroutine.status(assert(capabilityThread)), "suspended")
		equal(client:GetPromptState().IsBusy, true)
		handlers[FriendsProtocol.MessageTypes.SnapshotChanged]({ Previous = reserved, Current = initial })
		equal(client:GetPromptState().IsBusy, false)
		truthy(coroutine.resume(assert(capabilityThread)), "retired capability check could not unwind")
		equal(coroutine.status(assert(capabilityThread)), "dead")
		equal(promptCalls, 0, "retired request must never call PromptGameInvite")
		truthy(client:RequestInvite(77).Ok, "retired pending request kept the target locked")
	end)

	test("native capability survives hold expiry and is consumed only by successful admission", function(scope)
		local module, controls = makeModule(scope)
		local owner = { UserId = 81 } :: any
		local firstTarget = { UserId = 82 } :: any
		module:SetMemento(owner, { Current = 2 })
		module:Run(owner)
		controls.SetInvitationState("Allowed")
		module:RequestInvite(owner, { TargetUserId = firstTarget.UserId }, "native-1")
		local firstToken = controls.EncodedLaunchData[1].Token
		local firstGeneration: string? = nil
		for _, message in controls.Queued do
			if message.MessageType == FriendsProtocol.MessageTypes.OpenPrompt then firstGeneration = message.Payload.Generation end
		end
		controls.SetNow(1120)
		controls.Delayed[2].Callback()
		equal(#module:GetSnapshot(owner).Snapshot.Reserves, 0)
		module:RequestInvite(owner, { TargetUserId = firstTarget.UserId }, "native-2")
		equal(controls.EncodedLaunchData[2].Token, firstToken, "new attempt must reuse the stable admission capability")
		local secondGeneration: string? = nil
		for _, message in controls.Queued do
			if message.MessageType == FriendsProtocol.MessageTypes.OpenPrompt and message.RequestId == "native-2" then
				secondGeneration = message.Payload.Generation
			end
		end
		truthy(secondGeneration ~= firstGeneration, "each platform attempt needs a fresh hold generation")
		controls.SetNow(1240)
		controls.Delayed[#controls.Delayed].Callback()
		controls.SetNow(5000)
		module:SetMemento(firstTarget, { Current = 1 })
		module:Run(firstTarget)
		local prepared = module:PrepareAdmission(firstTarget, {
			Kind = "Invitation", Token = firstToken, TargetJobId = "test-job",
		})
		truthy(prepared.Ok, "expired presentation hold must not revoke LaunchData capability")
		module:CancelAdmission(prepared.Operation)
		local retry = module:PrepareAdmission(firstTarget, {
			Kind = "Invitation", Token = firstToken, TargetJobId = "test-job",
		})
		truthy(retry.Ok, "cancelled admission must restore the capability")
		truthy(module:CommitAdmission(retry.Operation), "capability claim did not commit")
		module:EmitAdmissionEvents(retry.Operation)
		equal(module:PrepareAdmission(firstTarget, {
			Kind = "Invitation", Token = firstToken, TargetJobId = "test-job",
		}).Error, "Rejected", "successful admission must consume capability")
	end)

	test("friendship check publishes availability across replacement capacity change and terminal outcomes", function(scope)
		for _, outcome in { "NotFriends", "Failure", "Timeout", "TargetDeparture", "LateSuccess" } do
			local module, controls = makeModule(scope)
			local owner = { UserId = 905 } :: any
			local target = { UserId = 906 } :: any
			module:SetMemento(owner, { Current = 1 })
			module:Run(owner)
			controls.SetInvitationState("Allowed")
			controls.SetRole(owner, "Owner")
			controls.AddPresentPlayer(owner)
			controls.AddPresentPlayer(target)
			controls.DeferSpawn(true)
			controls.SetFriendship(if outcome == "Failure" then function() error("friendship unavailable") end else outcome == "LateSuccess")
			if outcome == "LateSuccess" then controls.RemovePresentPlayer(target.UserId) end
			local provider = FriendsSnapshotClientProvider.new()
			scope:Defer(function() provider:Stop() end)
			provider:SetMemento(module:GetSnapshot(owner).Snapshot)
			provider:Run()
			local nextMessage = 1
			local function applyQueued()
				for index = nextMessage, #controls.Queued do
					local message = controls.Queued[index]
					if message.Player == owner and message.MessageType == FriendsProtocol.MessageTypes.SnapshotChanged then
						truthy(provider:TryApply(message.Payload.Previous, message.Payload.Current), "friendship check changed an unpublished snapshot baseline")
					end
				end
				nextMessage = #controls.Queued + 1
			end
			module:RequestInvite(owner, { TargetUserId = target.UserId }, `check-{outcome}`)
			applyQueued()
			equal(provider:GetSnapshot().CanCreateReserve, false, "check did not publish its busy state")
			provider:SetMemento(module:ToClientMemento(owner, module:GetMemento(owner)))
			truthy(module:SetCurrent(owner, 2).Ok, "capacity update during check failed")
			applyQueued()
			if outcome == "Timeout" then
				controls.SetNow(1010)
				controls.Delayed[1].Callback()
			elseif outcome == "TargetDeparture" then
				controls.RemovePresentPlayer(target.UserId)
				module:BeginDeparture(target, "KeepPublishedFriends")
			elseif outcome == "LateSuccess" then
				controls.SetNow(1011)
			end
			controls.RunNextSpawn()
			if outcome == "LateSuccess" then
				local expiredResult = false
				for _, message in controls.Queued do
					if message.MessageType == FriendsProtocol.MessageTypes.InviteResult and message.RequestId == "check-LateSuccess" then
						expiredResult = message.Payload.Category == "TemporaryError"
					end
					equal(message.MessageType == FriendsProtocol.MessageTypes.OpenPrompt, false, "late friendship success opened a platform prompt")
				end
				truthy(expiredResult, "late friendship success did not report expiry")
				equal(#module:GetSnapshot(owner).Snapshot.Reserves, 0, "late friendship success created a reserve")
				controls.Delayed[1].Callback()
			end
			applyQueued()
			equal(provider:GetSnapshot().CanCreateReserve, true, `check outcome {outcome} left the client unavailable`)
			truthy(FriendsSnapshot.equal(provider:GetSnapshot(), module:GetSnapshot(owner).Snapshot), "friendship completion left a stale client snapshot")
		end
	end)

	test("incoming native membership preserves zero personal invitation capacity", function(scope)
		local module, controls = makeModule(scope, 0)
		local owner = { UserId = 901 } :: any
		local target = { UserId = 902 } :: any
		for _, player in { owner, target } do
			module:SetMemento(player, module:CreateDefault(player))
			module:Run(player)
		end
		controls.SetInvitationState("Allowed")
		controls.SetRole(owner, "Owner")
		controls.SetRole(target, "Friend")
		truthy(module:SetCurrent(owner, 1).Ok, "owner capacity was not granted")
		module:RequestInvite(owner, { TargetUserId = target.UserId }, "zero-native")
		local token = controls.EncodedLaunchData[1].Token
		local prepared = module:PrepareAdmission(target, { Kind = "Invitation", Token = token, TargetJobId = "test-job" })
		truthy(prepared.Ok, "zero-capacity guest admission rejected")
		truthy(module:CommitAdmission(prepared.Operation), "zero-capacity guest commit failed")
		module:EmitAdmissionEvents(prepared.Operation)
		local snapshot = module:GetSnapshot(target).Snapshot
		equal(snapshot.Current, 0)
		equal(snapshot.ConnectedCount, 1)
		equal(snapshot.ConnectedUserIds[1], owner.UserId)
		local extraConnection = table.clone(snapshot)
		extraConnection.ConnectedCount = 2
		extraConnection.ConnectedUserIds = { owner.UserId, 999 }
		equal(FriendsSnapshot.validate(extraConnection), false, "guest exception allowed a second connection above personal capacity")
		local extraReserve = table.clone(snapshot)
		extraReserve.Reserves = { { TargetUserId = 999, ExpiresAtServerTime = 1200, Kind = "Native" } }
		equal(FriendsSnapshot.validate(extraReserve), false, "guest exception allowed an outgoing reserve above personal capacity")
		local fakeOwner = table.clone(snapshot)
		fakeOwner.IsSlotOwner = true
		equal(FriendsSnapshot.validate(fakeOwner), false, "owner received the guest capacity exception")
		truthy(module:SetCurrent(target, 1).Ok, "guest capacity increase failed")
		truthy(module:SetCurrent(target, 0).Ok, "incoming membership incorrectly consumed personal capacity")
		equal(module:GetMemento(target).Current, 0)
		equal(module:SetCurrent(owner, 0).Error, "InsufficientCapacity", "outgoing membership stopped consuming owner capacity")
	end)

	test("transfer retains its published role through snapshot replacement and capacity changes", function(scope)
		for _, finalCapacity in { 0, 2 } do
			local module, controls = makeModule(scope, 0)
			local owner = { UserId = 903, Name = "Owner", DisplayName = "Owner" } :: any
			local target = { UserId = 904, Name = "Target", DisplayName = "Target" } :: any
			for _, player in { owner, target } do
				module:SetMemento(player, { Current = 1 })
				module:Run(player)
				controls.AddPresentPlayer(player)
				controls.SetRole(player, "Owner")
			end
			controls.SetInvitationState("Allowed")
			local operation: any = nil
			module:BindLocalTransferHandler(function(inviter, respondingTarget, offerId)
				local result = module:PrepareLocalTransfer(inviter, respondingTarget, offerId)
				truthy(result.Ok, "transfer preparation failed")
				operation = result.Operation
				controls.SetRole(target, "Friend")
				truthy(module:CommitLocalTransfer(operation), "transfer staging failed")
				return { Ok = true, Cancel = function() end }
			end)
			module:RequestInvite(owner, { TargetUserId = target.UserId }, "role-invite")
			local offerId = module:GetSnapshot(target).Snapshot.IncomingOffer.OfferId
			module:RespondLocalOffer(target, { OfferId = offerId, Decision = "Accept" }, "role-accept")
			truthy(operation ~= nil, "transfer handler not reached")
			local replacement = module:ToClientMemento(target, module:GetMemento(target))
			equal(replacement.IsSlotOwner, true, "full snapshot exposed tentative physical role")
			equal(module:GetSnapshot(target).Snapshot.IsSlotOwner, true, "getter exposed tentative physical role")
			local provider = FriendsSnapshotClientProvider.new()
			provider:SetMemento(replacement)
			provider:Run()
			scope:Defer(function() provider:Stop() end)
			local firstMessage = #controls.Queued + 1
			truthy(module:SetCurrent(target, finalCapacity).Ok, "capacity change during transfer failed")
			truthy(module:CompleteLocalTransfer(operation), "transfer completion failed")
			for index = firstMessage, #controls.Queued do
				local message = controls.Queued[index]
				if message.Player == target and message.MessageType == FriendsProtocol.MessageTypes.SnapshotChanged then
					truthy(provider:TryApply(message.Payload.Previous, message.Payload.Current), "transfer delta mismatched replacement snapshot")
				end
			end
			local final = provider:GetSnapshot()
			equal(final.IsSlotOwner, false)
			equal(final.Current, finalCapacity)
			equal(final.ConnectedCount, 1)
			equal(final.IncomingOffer, nil)
			truthy(FriendsSnapshot.equal(final, module:GetSnapshot(target).Snapshot), "client final membership differs from server")
		end
	end)

	test("same-server offer branches without native prompt and decline is exact-target authoritative", function(scope)
		local module, controls = makeModule(scope)
		local owner = { UserId = 91, Name = "OwnerName", DisplayName = "Owner Display" } :: any
		local target = { UserId = 92, Name = "TargetName", DisplayName = "Target Display" } :: any
		local outsider = { UserId = 93, Name = "Other", DisplayName = "Other" } :: any
		for _, player in { owner, target, outsider } do
			module:SetMemento(player, { Current = if player == owner then 2 else 1 })
			module:Run(player)
			controls.AddPresentPlayer(player)
		end
		controls.SetInvitationState("Allowed")
		module:RequestInvite(owner, { TargetUserId = target.UserId }, "local-1")
		equal(#controls.EncodedLaunchData, 0, "same-server offer must not create LaunchData")
		local ownerSnapshot = module:GetSnapshot(owner).Snapshot
		equal(ownerSnapshot.Reserves[1].Kind, "SameServer")
		local targetSnapshot = module:GetSnapshot(target).Snapshot
		truthy(targetSnapshot.IncomingOffer ~= nil, "target did not receive incoming offer")
		equal(targetSnapshot.IncomingOffer.InviterUsername, "OwnerName")
		local offerId = targetSnapshot.IncomingOffer.OfferId
		module:RespondLocalOffer(outsider, { OfferId = offerId, Decision = "Decline" }, "spoof")
		truthy(module:GetSnapshot(target).Snapshot.IncomingOffer ~= nil, "spoofed response mutated target offer")
		module:RespondLocalOffer(target, { OfferId = offerId, Decision = "Decline" }, "decline")
		equal(module:GetSnapshot(target).Snapshot.IncomingOffer, nil)
		equal(#module:GetSnapshot(owner).Snapshot.Reserves, 0)
		local result = controls.Queued[#controls.Queued - 2]
		local foundDecline = false
		for _, message in controls.Queued do
			if message.MessageType == FriendsProtocol.MessageTypes.LocalOfferResult
				and message.RequestId == "decline" and message.Payload.Category == "Declined" then foundDecline = true end
		end
		truthy(foundDecline, "decline result was not correlated to the target request")
		truthy(result ~= nil, "local offer path emitted no messages")
	end)

	test("same-server accept uses prepare commit complete hooks and rejects duplicate response", function(scope)
		local module, controls = makeModule(scope)
		local owner = { UserId = 101, Name = "Owner", DisplayName = "Owner" } :: any
		local target = { UserId = 102, Name = "Target", DisplayName = "Target" } :: any
		for _, player in { owner, target } do
			module:SetMemento(player, { Current = if player == owner then 2 else 1 })
			module:Run(player)
			controls.AddPresentPlayer(player)
		end
		controls.SetInvitationState("Allowed")
		local transferOperation: any = nil
		module:BindLocalTransferHandler(function(inviter: Player, respondingTarget: Player, offerId: string)
			equal(inviter, owner)
			equal(respondingTarget, target)
			local prepared = module:PrepareLocalTransfer(inviter, respondingTarget, offerId)
			truthy(prepared.Ok, "Friends local transfer preparation failed")
			transferOperation = prepared.Operation
			return table.freeze({ Ok = true, Cancel = function() end })
		end)
		module:RequestInvite(owner, { TargetUserId = target.UserId }, "local-accept")
		local offerId = module:GetSnapshot(target).Snapshot.IncomingOffer.OfferId
		module:RespondLocalOffer(target, { OfferId = offerId, Decision = "Accept" }, "accept-1")
		truthy(transferOperation ~= nil, "accept did not dispatch the bound transfer handler")
		equal(module:GetSnapshot(target).Snapshot.IncomingOffer.Status, "Processing")
		module:RespondLocalOffer(target, { OfferId = offerId, Decision = "Accept" }, "accept-duplicate")
		truthy(module:CommitLocalTransfer(transferOperation), "Friends local transfer commit failed")
		equal(module:GetSnapshot(owner).Snapshot.ConnectedCount, 0,
			"tentative transfer relation must remain unpublished until Complete")
		truthy(module:CompleteLocalTransfer(transferOperation), "Friends local transfer completion failed")
		equal(module:GetSnapshot(target).Snapshot.IncomingOffer, nil)
		equal(module:GetSnapshot(owner).Snapshot.ConnectedUserIds[1], target.UserId)
		equal(module:GetSnapshot(target).Snapshot.ConnectedUserIds[1], owner.UserId)
		local duplicateCancelled = false
		local accepted = false
		for _, message in controls.Queued do
			if message.MessageType == FriendsProtocol.MessageTypes.LocalOfferResult then
				if message.RequestId == "accept-duplicate" and message.Payload.Category == "Cancelled" then duplicateCancelled = true end
				if message.RequestId == "accept-1" and message.Payload.Category == "Accepted" then accepted = true end
			end
		end
		truthy(duplicateCancelled, "duplicate response was not rejected")
		truthy(accepted, "successful transfer result was not published")
	end)

	test("accept rechecks friendship and denies a relationship removed after offer creation", function(scope)
		local module, controls = makeModule(scope)
		local owner = { UserId = 106, Name = "Owner", DisplayName = "Owner" } :: any
		local target = { UserId = 107, Name = "Target", DisplayName = "Target" } :: any
		for _, player in { owner, target } do
			module:SetMemento(player, { Current = if player == owner then 2 else 1 })
			module:Run(player)
			controls.AddPresentPlayer(player)
		end
		controls.SetInvitationState("Allowed")
		local handlerCalls = 0
		module:BindLocalTransferHandler(function()
			handlerCalls += 1
			return table.freeze({ Ok = true, Cancel = function() end })
		end)
		module:RequestInvite(owner, { TargetUserId = target.UserId }, "friend-removed-offer")
		local offerId = module:GetSnapshot(target).Snapshot.IncomingOffer.OfferId
		controls.SetFriendship(false)
		module:RespondLocalOffer(target, { OfferId = offerId, Decision = "Accept" }, "friend-removed-accept")
		equal(handlerCalls, 0, "removed friendship reached transfer handler")
		equal(module:GetSnapshot(target).Snapshot.IncomingOffer, nil)
		equal(#module:GetSnapshot(owner).Snapshot.Reserves, 0)
		local denied = false
		for _, message in controls.Queued do
			if message.MessageType == FriendsProtocol.MessageTypes.LocalOfferResult
				and message.RequestId == "friend-removed-accept" and message.Payload.Category == "NotFriends" then denied = true end
		end
		truthy(denied, "friendship recheck denial was not correlated")
	end)

	test("late accept friendship result after watchdog expiry is inert", function(scope)
		local module, controls = makeModule(scope)
		local owner = { UserId = 108, Name = "Owner", DisplayName = "Owner" } :: any
		local target = { UserId = 109, Name = "Target", DisplayName = "Target" } :: any
		for _, player in { owner, target } do
			module:SetMemento(player, { Current = if player == owner then 2 else 1 })
			module:Run(player)
			controls.AddPresentPlayer(player)
		end
		controls.SetInvitationState("Allowed")
		local handlerCalls = 0
		module:BindLocalTransferHandler(function()
			handlerCalls += 1
			return table.freeze({ Ok = true, Cancel = function() end })
		end)
		module:RequestInvite(owner, { TargetUserId = target.UserId }, "late-accept-offer")
		local offerId = module:GetSnapshot(target).Snapshot.IncomingOffer.OfferId
		controls.DeferSpawn(true)
		module:RespondLocalOffer(target, { OfferId = offerId, Decision = "Accept" }, "late-accept")
		controls.SetNow(1030)
		controls.Delayed[#controls.Delayed].Callback()
		equal(module:GetSnapshot(target).Snapshot.IncomingOffer, nil)
		controls.RunNextSpawn()
		equal(handlerCalls, 0, "late friendship result reached transfer handler")
		local timedOut = false
		for _, message in controls.Queued do
			if message.MessageType == FriendsProtocol.MessageTypes.LocalOfferResult
				and message.RequestId == "late-accept" and message.Payload.Category == "TransferFailed" then timedOut = true end
		end
		truthy(timedOut, "processing timeout was not correlated")
	end)

	test("late accept friendship result after either participant departure is inert", function(scope)
		local function runCase(offset: number, departingInviter: boolean, expectedCategory: string)
			local module, controls = makeModule(scope)
			local owner = { UserId = 1100 + offset, Name = "Owner", DisplayName = "Owner" } :: any
			local target = { UserId = 1200 + offset, Name = "Target", DisplayName = "Target" } :: any
			for _, player in { owner, target } do
				module:SetMemento(player, { Current = if player == owner then 2 else 1 })
				module:Run(player)
				controls.AddPresentPlayer(player)
			end
			controls.SetInvitationState("Allowed")
			local handlerCalls = 0
			module:BindLocalTransferHandler(function()
				handlerCalls += 1
				return table.freeze({ Ok = true, Cancel = function() end })
			end)
			module:RequestInvite(owner, { TargetUserId = target.UserId }, `departure-offer-{offset}`)
			local offerId = module:GetSnapshot(target).Snapshot.IncomingOffer.OfferId
			controls.DeferSpawn(true)
			module:RespondLocalOffer(target, { OfferId = offerId, Decision = "Accept" }, `departure-accept-{offset}`)
			local departing = if departingInviter then owner else target
			module:BeginDeparture(departing, "KeepPublishedFriends")
			controls.RemovePresentPlayer(departing.UserId)
			controls.RunNextSpawn()
			equal(handlerCalls, 0, "departure-stale friendship result reached transfer handler")
			equal(module:GetSnapshot(if departingInviter then target else owner).Snapshot.IncomingOffer, nil)
			local completed = false
			for _, message in controls.Queued do
				if message.MessageType == FriendsProtocol.MessageTypes.LocalOfferResult
					and message.RequestId == `departure-accept-{offset}` and message.Payload.Category == expectedCategory then completed = true end
			end
			truthy(completed, "departure result was not correlated")
		end
		runCase(1, true, "InviterUnavailable")
		runCase(2, false, "Cancelled")
	end)

	test("absent nonfriend is rejected before capability or native prompt creation", function(scope)
		local module, controls = makeModule(scope)
		local owner = { UserId = 111 } :: any
		module:SetMemento(owner, { Current = 2 })
		module:Run(owner)
		controls.AddPresentPlayer(owner)
		controls.SetInvitationState("Allowed")
		controls.SetFriendship(false)
		module:RequestInvite(owner, { TargetUserId = 112 }, "nonfriend")
		equal(#controls.EncodedLaunchData, 0, "nonfriend received a server admission capability")
		local prompts = 0
		local denied = 0
		for _, message in controls.Queued do
			if message.MessageType == FriendsProtocol.MessageTypes.OpenPrompt then prompts += 1 end
			if message.MessageType == FriendsProtocol.MessageTypes.InviteResult
				and message.RequestId == "nonfriend" and message.Payload.Category == "NotFriends" then denied += 1 end
		end
		equal(prompts, 0, "nonfriend reached the native prompt")
		equal(denied, 1, "nonfriend rejection was not returned")
	end)

	test("late friendship result after inviter departure cannot issue a capability", function(scope)
		local module, controls = makeModule(scope)
		local owner = { UserId = 121 } :: any
		module:SetMemento(owner, { Current = 2 })
		module:Run(owner)
		controls.AddPresentPlayer(owner)
		controls.SetInvitationState("Allowed")
		controls.DeferSpawn(true)
		module:RequestInvite(owner, { TargetUserId = 122 }, "late-check")
		equal(#controls.SpawnCallbacks, 1, "friendship continuation was not deferred")
		module:BeginDeparture(owner, "KeepPublishedFriends")
		controls.RemovePresentPlayer(owner.UserId)
		controls.RunNextSpawn()
		equal(#controls.EncodedLaunchData, 0, "stale friendship continuation created LaunchData")
		local prompts = 0
		for _, message in controls.Queued do if message.MessageType == FriendsProtocol.MessageTypes.OpenPrompt then prompts += 1 end end
		equal(prompts, 0, "stale friendship continuation opened native prompt")
	end)

	test("processing watchdog invokes transfer cancellation and releases both snapshots", function(scope)
		local module, controls = makeModule(scope)
		local owner = { UserId = 131, Name = "Owner", DisplayName = "Owner" } :: any
		local target = { UserId = 132, Name = "Target", DisplayName = "Target" } :: any
		for _, player in { owner, target } do
			module:SetMemento(player, { Current = if player == owner then 2 else 1 })
			module:Run(player)
			controls.AddPresentPlayer(player)
		end
		controls.SetInvitationState("Allowed")
		local cancelled = 0
		module:BindLocalTransferHandler(function(inviter: Player, respondingTarget: Player, offerId: string)
			local prepared = module:PrepareLocalTransfer(inviter, respondingTarget, offerId)
			truthy(prepared.Ok, "watchdog transfer did not prepare")
			truthy(module:CommitLocalTransfer(prepared.Operation), "watchdog transfer did not stage")
			return table.freeze({
				Ok = true,
				Cancel = function(category: string)
					cancelled += 1
					module:RollbackLocalTransfer(prepared.Operation, category)
				end,
			})
		end)
		module:RequestInvite(owner, { TargetUserId = target.UserId }, "watchdog-offer")
		local offerId = module:GetSnapshot(target).Snapshot.IncomingOffer.OfferId
		module:RespondLocalOffer(target, { OfferId = offerId, Decision = "Accept" }, "watchdog-accept")
		controls.SetNow(1030)
		controls.Delayed[#controls.Delayed].Callback()
		equal(cancelled, 1, "processing watchdog did not invoke coordinator cancellation")
		equal(module:GetSnapshot(target).Snapshot.IncomingOffer, nil)
		equal(#module:GetSnapshot(owner).Snapshot.Reserves, 0)
	end)

	test("completion applies a current relation delta and never resurrects a departed friend", function(scope)
		local module, controls = makeModule(scope)
		local owner = { UserId = 136, Name = "Owner", DisplayName = "Owner" } :: any
		local target = { UserId = 137, Name = "Target", DisplayName = "Target" } :: any
		local third = { UserId = 138, Name = "Third", DisplayName = "Third" } :: any
		module:SetMemento(target, { Current = 2 })
		module:SetMemento(third, { Current = 1 })
		module:Run(target)
		module:Run(third)
		controls.SetInvitationState("Allowed")
		module:RequestInvite(target, { TargetUserId = third.UserId }, "seed-relation")
		local token = controls.EncodedLaunchData[1].Token
		local admission = module:PrepareAdmission(third, {
			Kind = "Invitation", Token = token, TargetJobId = "test-job",
		})
		truthy(admission.Ok, "seed relation admission failed")
		truthy(module:CommitAdmission(admission.Operation), "seed relation commit failed")
		module:EmitAdmissionEvents(admission.Operation)
		equal(module:GetSnapshot(target).Snapshot.ConnectedUserIds[1], third.UserId)

		module:SetMemento(owner, { Current = 2 })
		module:Run(owner)
		controls.AddPresentPlayer(owner)
		controls.AddPresentPlayer(target)
		controls.AddPresentPlayer(third)
		local transferOperation: any = nil
		module:BindLocalTransferHandler(function(inviter: Player, respondingTarget: Player, offerId: string)
			local prepared = module:PrepareLocalTransfer(inviter, respondingTarget, offerId)
			truthy(prepared.Ok, "delta transfer preparation failed")
			transferOperation = prepared.Operation
			truthy(module:CommitLocalTransfer(transferOperation), "delta transfer staging failed")
			return table.freeze({ Ok = true, Cancel = function() end })
		end)
		module:RequestInvite(owner, { TargetUserId = target.UserId }, "delta-offer")
		local offerId = module:GetSnapshot(target).Snapshot.IncomingOffer.OfferId
		module:RespondLocalOffer(target, { OfferId = offerId, Decision = "Accept" }, "delta-accept")
		module:BeginDeparture(third, "KeepPublishedFriends")
		equal(module:GetSnapshot(target).Snapshot.ConnectedCount, 0, "third friend departure was not applied")
		truthy(module:CompleteLocalTransfer(transferOperation), "delta transfer completion failed")
		local final = module:GetSnapshot(target).Snapshot
		equal(final.ConnectedCount, 1)
		equal(final.ConnectedUserIds[1], owner.UserId)
	end)

	test("request replay and native capability memory are bounded", function(scope)
		local module, controls = makeModule(scope)
		local owner = { UserId = 141 } :: any
		module:SetMemento(owner, { Current = 3 })
		module:Run(owner)
		controls.AddPresentPlayer(owner)
		controls.SetInvitationState("Allowed")
		local firstToken: string? = nil
		for offset = 1, 33 do
			local requestId = `bounded-{offset}`
			module:RequestInvite(owner, { TargetUserId = 200 + offset }, requestId)
			local prompt: any = nil
			for index = #controls.Queued, 1, -1 do
				local message = controls.Queued[index]
				if message.MessageType == FriendsProtocol.MessageTypes.OpenPrompt and message.RequestId == requestId then prompt = message; break end
			end
			truthy(prompt ~= nil, "bounded capability request did not reach native prompt")
			if offset == 1 then firstToken = controls.EncodedLaunchData[#controls.EncodedLaunchData].Token end
			module:HandlePlatformResult(owner, {
				Generation = prompt.Payload.Generation, Result = "InviteUnavailable",
			}, requestId)
		end
		local firstTarget = { UserId = 201 } :: any
		module:SetMemento(firstTarget, { Current = 1 })
		module:Run(firstTarget)
		equal(module:PrepareAdmission(firstTarget, {
			Kind = "Invitation", Token = firstToken, TargetJobId = "test-job",
		}).Error, "Rejected", "oldest capability was not evicted at the bounded limit")
		local beforeReplay = #controls.EncodedLaunchData
		module:RequestInvite(owner, { TargetUserId = 999 }, "bounded-33")
		equal(#controls.EncodedLaunchData, beforeReplay, "recent request replay was processed twice")
		controls.SetNow(1301)
		module:RequestInvite(owner, { TargetUserId = 999 }, "bounded-33")
		equal(#controls.EncodedLaunchData, beforeReplay + 1, "expired replay record remained permanently resident")
	end)

	test("protocol ignores recipientIds and validates only the native prompt generation", function(_scope)
		truthy(FriendsProtocol.validatePromptClosed({ Generation = "generation" }), "generation-only close was rejected")
		equal(FriendsProtocol.validatePromptClosed({ Generation = "generation", RecipientUserIds = {} }), false)
	end)

	test("client queue rejection requests recovery and successful refresh has an explicit hook", function(scope)
		local provider = FriendsSnapshotClientProvider.new()
		local ready = Signal.new()
		local handlers = {}
		local recoveries = 0
		local client = FriendsClient.new(provider, {
			Communication = {
				RegisterHandler = function(_self: any, messageType: string, callback: any) handlers[messageType] = callback end,
				RegisterResyncPreparation = function() return function() end end,
				Queue = function() return false end,
				RequestResync = function() recoveries += 1 end,
			},
			GenerateRequestId = function() return "request" end,
		})
		scope:Defer(function() client:Stop(); ready:Destroy() end)
		provider:SetMemento({
			Min = 1, Max = 3, Current = 2, ConnectedCount = 0, CanCreateReserve = true,
			IsSlotOwner = true, ConnectedUserIds = {}, Reserves = {},
		})
		provider:Run()
		client:Initialize({ Ready = ready })
		ready:Fire()
		equal(client:RequestInvite(77).Error, "CommunicationUnavailable")
		equal(recoveries, 1, "invite queue rejection must request snapshot recovery")
		local refreshed = 0
		client.RefreshSucceeded:Connect(function() refreshed += 1 end)
		client:NotifyRefreshSucceeded()
		equal(refreshed, 1, "successful refresh hook was not published")
		truthy(handlers[FriendsProtocol.MessageTypes.LocalOfferResult] ~= nil, "local result handler was not registered")
	end)

	return TestHarness.runAll("FriendsModuleTestRunner", tests)
end

return Runner
