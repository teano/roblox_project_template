--!strict

--[[
	require(game.ServerScriptService.Tests.PlayerSlotModuleTestRunner).runAll()
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local PlayerSlotModule = require(ServerScriptService.Modules.PlayerSlots.PlayerSlotModule)
local TestHarness = require(script.Parent.TestHarness)

local Runner = {}

local function equal(actual: any, expected: any, message: string?)
	if actual ~= expected then error(`{message or "assertEqual"}: expected={tostring(expected)} actual={tostring(actual)}`, 2) end
end

local function truthy(value: any, message: string)
	if not value then error(message, 2) end
end

local function makeScene(slotIds: { number }): (Folder, Folder, any, () -> ())
	local workspaceRoot = Instance.new("Folder")
	workspaceRoot.Name = "WorkspaceBoundary"
	local slotsFolder = Instance.new("Folder")
	slotsFolder.Name = "PlayerSlots"
	slotsFolder.Parent = workspaceRoot
	local teams = Instance.new("Folder")
	local tagged = {}
	local colors = { BrickColor.new("Bright red"), BrickColor.new("Bright blue"), BrickColor.new("Bright green") }
	for index, slotId in slotIds do
		local model = Instance.new("Model")
		model.Name = `Slot_{slotId}`
		model:SetAttribute("SlotId", slotId)
		model.Parent = slotsFolder
		table.insert(tagged, model)
		local spawn = Instance.new("SpawnLocation")
		spawn.Name = "PlayerSpawn"
		spawn.Enabled = true
		spawn.Neutral = false
		spawn.AllowTeamChangeOnTouch = false
		spawn.TeamColor = colors[index]
		spawn.Parent = model
		local team = Instance.new("Team")
		team.Name = model.Name
		team:SetAttribute("SlotId", slotId)
		team.AutoAssignable = false
		team.TeamColor = colors[index]
		team.Parent = teams
	end
	return workspaceRoot, teams, {
		GetTagged = function(_self: any, tag: string)
			return if tag == "PlayerSlot" then table.clone(tagged) else {}
		end,
	}, function()
		workspaceRoot:Destroy()
		teams:Destroy()
	end
end

local function makePlayers()
	local present = {}
	return {
		GetPlayerByUserId = function(_self: any, userId: number)
			for _, player in present do
				if player.UserId == userId then return player end
			end
			return nil
		end,
		Add = function(_self: any, player: any)
			table.insert(present, player)
		end,
	}
end

local function makeModule(scope: any, strategy: string, slotIds: { number }, maxPlayers: number?): (any, any)
	local workspaceRoot, teams, collection, destroy = makeScene(slotIds)
	scope:Defer(destroy)
	local players = makePlayers()
	local module = PlayerSlotModule.new({
		PlayersModule = players,
		Config = {
			GetRequired = function(_self: any, id: string)
				if id == "PlayerSlots" then return table.freeze({ Strategy = strategy }) end
				if id == "Friends" then return table.freeze({ MaxInviteCapacity = 3 }) end
				error(`unexpected config '{id}'`)
			end,
		},
		CollectionService = collection,
		Workspace = workspaceRoot,
		Teams = teams,
		MaxPlayers = maxPlayers or #slotIds * 4,
	})
	scope:Defer(function() module:Stop() end)
	module:Initialize()
	return module, players
end

function Runner.runAll()
	local tests = {}
	local function test(name: string, callback: (any) -> ()) table.insert(tests, { Name = name, Callback = callback }) end

	test("enabled strategy prepares the lowest slot and publishes only on commit", function(scope)
		local module, players = makeModule(scope, "Enabled", { 3, 1 })
		local player = { UserId = 101, Team = nil, RespawnLocation = nil } :: any
		players:Add(player)
		local events = 0
		module.PlayerAssigned:Connect(function(eventPlayer, relation)
			equal(eventPlayer, player)
			equal(relation.SlotId, 1)
			events += 1
		end)
		local prepared = module:PrepareAdmission(player, table.freeze({ Kind = "Ordinary" }))
		truthy(prepared.Ok, "enabled strategy rejected ordinary admission")
		equal(player.Team, module:GetSlot(1).Team, "Team was not prepared")
		equal(player.RespawnLocation, module:GetSlot(1).PlayerSpawn, "RespawnLocation was not prepared")
		equal(module:GetPlayerSlot(player), nil, "prepared relation became visible")
		equal(module:GetSlot(1).Owner, nil, "prepared owner became visible")
		truthy(module:CommitAdmission(prepared.Operation), "commit failed")
		equal(module:GetPlayerSlot(player).SlotId, 1)
		equal(events, 0, "commit emitted domain event")
		module:EmitAdmissionEvents(prepared.Operation)
		equal(events, 1)
		truthy(table.isfrozen(module:GetSlots()), "slot sequence must be frozen")
		truthy(not pcall(function() module:GetPlayerSlot(player).Role = "Friend" end), "relation snapshot must be frozen")
	end)

	test("disabled strategy approves without physical slot or scene validation", function(scope)
		local module, players = makeModule(scope, "Disabled", { 1 }, 1)
		local player = { UserId = 102, Team = nil, RespawnLocation = nil } :: any
		players:Add(player)
		local prepared = module:PrepareAdmission(player, table.freeze({ Kind = "Ordinary" }))
		truthy(prepared.Ok, "disabled strategy rejected ordinary admission")
		equal(prepared.Result, "ApprovedWithoutSlot")
		truthy(module:CommitAdmission(prepared.Operation), "disabled commit failed")
		module:EmitAdmissionEvents(prepared.Operation)
		equal(module:GetPlayerSlot(player), nil)
		equal(#module:GetSlots(), 0)
		equal(player.Team, nil)
		equal(module:CanCreateInvitation(player), "Allowed")
	end)

	test("invalid scene keeps enabled strategy unavailable without leaking slots", function(scope)
		local module, players = makeModule(scope, "Enabled", { 1 }, 3)
		local player = { UserId = 103, Team = nil, RespawnLocation = nil } :: any
		players:Add(player)
		local prepared = module:PrepareAdmission(player, table.freeze({ Kind = "Ordinary" }))
		equal(prepared.Ok, false)
		equal(prepared.Error, "NotReady")
		equal(#module:GetSlots(), 0)
		equal(module:CanCreateInvitation(player), "NotReady")
	end)

	test("cancel releases the hidden reservation for the next ordinary admission", function(scope)
		local module, players = makeModule(scope, "Enabled", { 1 })
		local first = { UserId = 104, Team = nil, RespawnLocation = nil } :: any
		local second = { UserId = 105, Team = nil, RespawnLocation = nil } :: any
		players:Add(first)
		players:Add(second)
		local firstPrepared = module:PrepareAdmission(first, table.freeze({ Kind = "Ordinary" }))
		truthy(firstPrepared.Ok, "first admission was not prepared")
		module:CancelAdmission(firstPrepared.Operation)
		equal(first.Team, nil, "cancel did not restore Team")
		equal(first.RespawnLocation, nil, "cancel did not restore RespawnLocation")
		local secondPrepared = module:PrepareAdmission(second, table.freeze({ Kind = "Ordinary" }))
		truthy(secondPrepared.Ok, "cancelled reservation was not released")
	end)

	test("failed physical preparation restores the player without publishing a slot", function(scope)
		local module, players = makeModule(scope, "Enabled", { 1 })
		local values = { UserId = 106, Team = nil, RespawnLocation = nil } :: { [string]: any }
		local player = setmetatable({}, {
			__index = function(_self, key)
				return values[key]
			end,
			__newindex = function(_self, key, value)
				if key == "RespawnLocation" then
					error("RespawnLocation assignment failed")
				end
				values[key] = value
			end,
		}) :: any
		players:Add(player)
		local assigned = 0
		module.PlayerAssigned:Connect(function()
			assigned += 1
		end)
		local prepared = module:PrepareAdmission(player, table.freeze({ Kind = "Ordinary" }))
		equal(prepared.Ok, false)
		equal(prepared.Error, "Rejected")
		equal(values.Team, nil, "failed preparation retained Team")
		equal(values.RespawnLocation, nil, "failed preparation retained RespawnLocation")
		equal(module:GetSlot(1).Owner, nil, "failed preparation published owner")
		equal(module:GetPlayerSlot(player), nil, "failed preparation published relation")
		equal(assigned, 0, "failed preparation emitted PlayerAssigned")
	end)

	test("same-server transfer atomically frees the source slot and assigns the target as a friend", function(scope)
		local module, players = makeModule(scope, "Enabled", { 1, 2 })
		local inviter = { UserId = 201, Team = nil, RespawnLocation = nil } :: any
		local target = { UserId = 202, Team = nil, RespawnLocation = nil } :: any
		players:Add(inviter)
		players:Add(target)
		local inviterAdmission = module:PrepareAdmission(inviter, table.freeze({ Kind = "Ordinary" }))
		truthy(inviterAdmission.Ok and module:CommitAdmission(inviterAdmission.Operation), "inviter admission failed")
		local targetAdmission = module:PrepareAdmission(target, table.freeze({ Kind = "Ordinary" }))
		truthy(targetAdmission.Ok and module:CommitAdmission(targetAdmission.Operation), "target admission failed")
		local events = {}
		module.PlayerUnassigned:Connect(function(player, relation)
			table.insert(events, `unassigned:{player.UserId}:{relation.SlotId}:{relation.Role}`)
		end)
		module.PlayerAssigned:Connect(function(player, relation)
			table.insert(events, `assigned:{player.UserId}:{relation.SlotId}:{relation.Role}`)
		end)
		local prepared = module:PrepareTransfer(target, inviter.UserId)
		truthy(prepared.Ok, `transfer prepare failed: {tostring(prepared.Error)}`)
		equal(module:GetPlayerSlot(target).SlotId, 2, "prepare published transfer")
		truthy(module:CommitTransfer(prepared.Operation), "transfer commit failed")
		equal(module:GetPlayerSlot(target).SlotId, 1)
		equal(module:GetPlayerSlot(target).Role, "Friend")
		equal(module:GetSlot(2).Owner, nil)
		equal(target.Team, module:GetSlot(1).Team)
		equal(target.RespawnLocation, module:GetSlot(1).PlayerSpawn)
		equal(#events, 0, "commit emitted intermediate events")
		truthy(module:CompleteTransfer(prepared.Operation), "transfer completion failed")
		equal(events[1], "unassigned:202:2:Owner")
		equal(events[2], "assigned:202:1:Friend")
	end)

	test("same-server transfer rollback restores relation and physical spawn properties", function(scope)
		local module, players = makeModule(scope, "Enabled", { 1, 2 })
		local inviter = { UserId = 203, Team = nil, RespawnLocation = nil } :: any
		local target = { UserId = 204, Team = nil, RespawnLocation = nil } :: any
		players:Add(inviter)
		players:Add(target)
		local first = module:PrepareAdmission(inviter, table.freeze({ Kind = "Ordinary" }))
		local second = module:PrepareAdmission(target, table.freeze({ Kind = "Ordinary" }))
		truthy(first.Ok and module:CommitAdmission(first.Operation), "inviter admission failed")
		truthy(second.Ok and module:CommitAdmission(second.Operation), "target admission failed")
		local oldTeam = target.Team
		local oldSpawn = target.RespawnLocation
		local prepared = module:PrepareTransfer(target, inviter.UserId)
		truthy(prepared.Ok and module:CommitTransfer(prepared.Operation), "transfer did not commit")
		truthy(module:RollbackTransfer(prepared.Operation), "committed transfer did not roll back")
		equal(module:GetPlayerSlot(target).SlotId, 2)
		equal(module:GetPlayerSlot(target).Role, "Owner")
		equal(module:GetSlot(2).Owner, target)
		equal(#module:GetSlot(1).Friends, 0)
		equal(target.Team, oldTeam)
		equal(target.RespawnLocation, oldSpawn)
		truthy(not module:CompleteTransfer(prepared.Operation), "rolled-back transfer completed")
	end)

	test("same-server transfer rejects dependent owners, full targets, duplicates, and disabled slots", function(scope)
		local module, players = makeModule(scope, "Enabled", { 1, 2 })
		local inviter = { UserId = 205, Team = nil, RespawnLocation = nil } :: any
		local target = { UserId = 206, Team = nil, RespawnLocation = nil } :: any
		local dependent = { UserId = 207, Team = nil, RespawnLocation = nil } :: any
		players:Add(inviter); players:Add(target); players:Add(dependent)
		local first = module:PrepareAdmission(inviter, table.freeze({ Kind = "Ordinary" }))
		local second = module:PrepareAdmission(target, table.freeze({ Kind = "Ordinary" }))
		truthy(first.Ok and module:CommitAdmission(first.Operation), "inviter admission failed")
		truthy(second.Ok and module:CommitAdmission(second.Operation), "target admission failed")
		local friendAdmission = module:PrepareAdmission(dependent, table.freeze({ Kind = "Friend", InviterUserId = target.UserId, ClaimId = "claim" }))
		truthy(friendAdmission.Ok and module:CommitAdmission(friendAdmission.Operation), "dependent admission failed")
		equal(module:PrepareTransfer(target, inviter.UserId).Error, "TargetHasDependents")
		equal(module:PrepareTransfer(dependent, inviter.UserId).Error, "TargetIneligible")

		local disabled, disabledPlayers = makeModule(scope, "Disabled", { 1 }, 1)
		local disabledTarget = { UserId = 208, Team = nil, RespawnLocation = nil } :: any
		disabledPlayers:Add(disabledTarget)
		equal(disabled:PrepareTransfer(disabledTarget, inviter.UserId).Error, "TargetIneligible")
	end)

	test("same-server transfer rejects full targets and restores partial property assignment", function(scope)
		local module, players = makeModule(scope, "Enabled", { 1, 2 })
		local inviter = { UserId = 209, Team = nil, RespawnLocation = nil } :: any
		local values = { UserId = 210, Team = nil, RespawnLocation = nil } :: { [string]: any }
		local failRespawn = false
		local target = setmetatable({}, {
			__index = function(_self, key) return values[key] end,
			__newindex = function(_self, key, value)
				if key == "RespawnLocation" and failRespawn then error("planned transfer property failure") end
				values[key] = value
			end,
		}) :: any
		players:Add(inviter); players:Add(target)
		local inviterAdmission = module:PrepareAdmission(inviter, table.freeze({ Kind = "Ordinary" }))
		local targetAdmission = module:PrepareAdmission(target, table.freeze({ Kind = "Ordinary" }))
		truthy(inviterAdmission.Ok and module:CommitAdmission(inviterAdmission.Operation), "inviter admission failed")
		truthy(targetAdmission.Ok and module:CommitAdmission(targetAdmission.Operation), "target admission failed")
		local oldTeam, oldSpawn = target.Team, target.RespawnLocation
		local prepared = module:PrepareTransfer(target, inviter.UserId)
		truthy(prepared.Ok, "transfer prepare failed")
		failRespawn = true
		truthy(not module:CommitTransfer(prepared.Operation), "partial property failure committed transfer")
		equal(target.Team, oldTeam, "partial property failure retained target Team")
		equal(target.RespawnLocation, oldSpawn, "partial property failure retained target RespawnLocation")
		equal(module:GetPlayerSlot(target).SlotId, 2)
		equal(module:GetPlayerSlot(target).Role, "Owner")
		failRespawn = false

		for index = 1, 3 do
			local friend = { UserId = 210 + index, Team = nil, RespawnLocation = nil } :: any
			players:Add(friend)
			local friendAdmission = module:PrepareAdmission(friend, table.freeze({ Kind = "Friend", InviterUserId = inviter.UserId, ClaimId = `claim-{index}` }))
			truthy(friendAdmission.Ok and module:CommitAdmission(friendAdmission.Operation), "friend admission failed")
		end
		equal(module:CanTransferOwner(target, inviter.UserId), "NoCapacity")
		equal(module:PrepareTransfer(target, inviter.UserId).Error, "NoCapacity")
	end)

	test("committed transfer rollback preserves an unrelated friend departure and releases both locks", function(scope)
		local module, players = makeModule(scope, "Enabled", { 1, 2 })
		local inviter = { UserId = 220, Team = nil, RespawnLocation = nil } :: any
		local target = { UserId = 221, Team = nil, RespawnLocation = nil } :: any
		local departingFriend = { UserId = 222, Team = nil, RespawnLocation = nil } :: any
		players:Add(inviter); players:Add(target); players:Add(departingFriend)
		local inviterAdmission = module:PrepareAdmission(inviter, table.freeze({ Kind = "Ordinary" }))
		local targetAdmission = module:PrepareAdmission(target, table.freeze({ Kind = "Ordinary" }))
		truthy(inviterAdmission.Ok and module:CommitAdmission(inviterAdmission.Operation), "inviter admission failed")
		truthy(targetAdmission.Ok and module:CommitAdmission(targetAdmission.Operation), "target admission failed")
		local friendAdmission = module:PrepareAdmission(departingFriend, table.freeze({
			Kind = "Friend", InviterUserId = inviter.UserId, ClaimId = "third-friend",
		}))
		truthy(friendAdmission.Ok and module:CommitAdmission(friendAdmission.Operation), "third friend admission failed")
		local transfer = module:PrepareTransfer(target, inviter.UserId)
		truthy(transfer.Ok and module:CommitTransfer(transfer.Operation), "transfer did not reach committed stage")
		local departure = module:BeginDeparture(departingFriend)
		equal(departure.Kind, "Friend")
		module:CompleteDeparture(departure.Operation)
		equal(module:GetPlayerSlot(departingFriend), nil, "third friend departure did not complete")
		truthy(module:RollbackTransfer(transfer.Operation), "target revision delta prevented transfer rollback")
		equal(module:GetPlayerSlot(target).SlotId, 2)
		equal(module:GetPlayerSlot(target).Role, "Owner")
		equal(module:GetPlayerSlot(departingFriend), nil, "rollback resurrected the departed third friend")
		equal(#module:GetSlot(1).Friends, 0)
		equal(module:CanCreateInvitation(inviter), "Allowed", "rollback retained the target-slot lock")
		local retry = module:PrepareTransfer(target, inviter.UserId)
		truthy(retry.Ok, "rollback retained the source-slot lock")
		truthy(module:RollbackTransfer(retry.Operation), "prepared retry cleanup failed")
	end)

	test("committed rollback releases structural locks when previous spawn restoration fails", function(scope)
		local module, players = makeModule(scope, "Enabled", { 1, 2 })
		local inviter = { UserId = 223, Team = nil, RespawnLocation = nil } :: any
		local values = { UserId = 224, Team = nil, RespawnLocation = nil } :: { [string]: any }
		local failPreviousSpawn = false
		local previousSpawn: any = nil
		local target = setmetatable({}, {
			__index = function(_self, key) return values[key] end,
			__newindex = function(_self, key, value)
				if key == "RespawnLocation" and failPreviousSpawn and value == previousSpawn then
					error("planned previous spawn restore failure")
				end
				values[key] = value
			end,
		}) :: any
		local departingFriend = { UserId = 225, Team = nil, RespawnLocation = nil } :: any
		players:Add(inviter); players:Add(target); players:Add(departingFriend)
		local inviterAdmission = module:PrepareAdmission(inviter, table.freeze({ Kind = "Ordinary" }))
		local targetAdmission = module:PrepareAdmission(target, table.freeze({ Kind = "Ordinary" }))
		truthy(inviterAdmission.Ok and module:CommitAdmission(inviterAdmission.Operation), "inviter admission failed")
		truthy(targetAdmission.Ok and module:CommitAdmission(targetAdmission.Operation), "target admission failed")
		previousSpawn = target.RespawnLocation
		local friendAdmission = module:PrepareAdmission(departingFriend, table.freeze({
			Kind = "Friend", InviterUserId = inviter.UserId, ClaimId = "depart-before-degraded-rollback",
		}))
		truthy(friendAdmission.Ok and module:CommitAdmission(friendAdmission.Operation), "third friend admission failed")
		local transfer = module:PrepareTransfer(target, inviter.UserId)
		truthy(transfer.Ok and module:CommitTransfer(transfer.Operation), "transfer did not commit")
		local departure = module:BeginDeparture(departingFriend)
		module:CompleteDeparture(departure.Operation)
		failPreviousSpawn = true
		truthy(not module:RollbackTransfer(transfer.Operation), "property failure was not reported")
		equal(module:GetPlayerSlot(target).SlotId, 2, "structural source relation was not restored")
		equal(module:GetPlayerSlot(target).Role, "Owner")
		equal(module:GetSlot(2).Owner, target)
		equal(module:GetPlayerSlot(departingFriend), nil, "degraded rollback resurrected departed friend")
		equal(#module:GetSlot(1).Friends, 0)
		equal(module:CanCreateInvitation(inviter), "Allowed", "degraded rollback retained target lock")
		local retry = module:PrepareTransfer(target, inviter.UserId)
		truthy(retry.Ok, "degraded rollback retained source lock")
		truthy(module:RollbackTransfer(retry.Operation), "prepared retry cleanup failed")

		local targetDeparture = module:BeginDeparture(target)
		module:CompleteDeparture(targetDeparture.Operation)
		local newcomer = { UserId = 226, Team = nil, RespawnLocation = nil } :: any
		players:Add(newcomer)
		local newcomerAdmission = module:PrepareAdmission(newcomer, table.freeze({ Kind = "Ordinary" }))
		truthy(newcomerAdmission.Ok, "degraded rollback prevented later ordinary admission")
	end)

	return TestHarness.runAll("PlayerSlotModuleTestRunner", tests)
end

return Runner
