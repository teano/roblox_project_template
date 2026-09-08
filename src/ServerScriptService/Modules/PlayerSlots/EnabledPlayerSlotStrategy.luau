--!strict

local Strategy = {}
Strategy.__index = Strategy

local function positiveInteger(value: any): boolean
	return typeof(value) == "number"
		and value == value
		and value ~= math.huge
		and value ~= -math.huge
		and value == math.floor(value)
		and value > 0
end

local function finiteNonzeroInteger(value: any): boolean
	return typeof(value) == "number"
		and value == value
		and value ~= math.huge
		and value ~= -math.huge
		and value == math.floor(value)
		and value ~= 0
end

local function exactContext(value: any): boolean
	if typeof(value) ~= "table" or getmetatable(value) ~= nil or not table.isfrozen(value) then return false end
	if value.Kind == "Ordinary" then
		for key in value do if key ~= "Kind" then return false end end
		return true
	end
	if value.Kind ~= "Friend" or not finiteNonzeroInteger(value.InviterUserId)
		or typeof(value.ClaimId) ~= "string" or value.ClaimId == "" then return false end
	for key in value do
		if key ~= "Kind" and key ~= "InviterUserId" and key ~= "ClaimId" then return false end
	end
	return true
end

local function frozenRelation(slot: any, player: Player): any
	local relation = slot.Relations[player]
	assert(relation ~= nil, "Published slot relation is missing")
	return table.freeze({
		SlotId = slot.SlotId,
		SlotModel = slot.SlotModel,
		Role = relation.Role,
		Owner = relation.Owner,
	})
end

local function frozenSlot(slot: any): any
	local friends = {}
	for friend in slot.Friends do table.insert(friends, friend) end
	table.sort(friends, function(left, right) return left.UserId < right.UserId end)
	return table.freeze({
		SlotId = slot.SlotId,
		SlotModel = slot.SlotModel,
		Team = slot.Team,
		PlayerSpawn = slot.PlayerSpawn,
		Owner = slot.Owner,
		Friends = table.freeze(friends),
	})
end

local function restorePlayer(player: Player, team: any, spawn: any)
	pcall(function() player.Team = team end)
	pcall(function() player.RespawnLocation = spawn end)
end

local function assignPlayer(player: Player, team: any, spawn: any): boolean
	return pcall(function()
		player.Team = team
		player.RespawnLocation = spawn
	end)
end

function Strategy.new(deps: any)
	assert(typeof(deps) == "table", "EnabledPlayerSlotStrategy dependencies required")
	return setmetatable({
		_players = assert(deps.PlayersModule, "PlayersModule required"),
		_collection = assert(deps.CollectionService, "CollectionService required"),
		_workspace = assert(deps.Workspace, "Workspace required"),
		_teams = assert(deps.Teams, "Teams required"),
		_maxPlayers = assert(deps.MaxPlayers, "MaxPlayers required"),
		_maxInviteCapacity = assert(deps.MaxInviteCapacity, "MaxInviteCapacity required"),
		_assigned = assert(deps.PlayerAssigned, "PlayerAssigned required"),
		_unassigned = assert(deps.PlayerUnassigned, "PlayerUnassigned required"),
		_ready = false,
		_reason = nil,
		_slots = {},
		_slotsById = {},
		_relationsByPlayer = {},
		_relationsByUserId = {},
		_stopped = false,
	}, Strategy)
end

function Strategy:_configurationFailure(message: string): (nil, string)
	return nil, `Ошибка настройки пользовательских слотов: {message}`
end

function Strategy:_buildConfiguration(): ({ any }?, string?)
	if not positiveInteger(self._maxPlayers) then
		return self:_configurationFailure("Players.MaxPlayers должен быть положительным целым числом")
	end
	if not (typeof(self._maxInviteCapacity) == "number" and self._maxInviteCapacity == math.floor(self._maxInviteCapacity)
		and self._maxInviteCapacity >= 0) then
		return self:_configurationFailure("максимальная вместимость приглашений должна быть неотрицательным целым числом")
	end

	local folder = self._workspace:FindFirstChild("PlayerSlots")
	if folder == nil or not folder:IsA("Folder") then
		return self:_configurationFailure("Workspace.PlayerSlots отсутствует")
	end
	local children = folder:GetChildren()
	if #children == 0 then
		return self:_configurationFailure("не настроено ни одного слота")
	end

	local taggedSet = {}
	for _, instance in self._collection:GetTagged("PlayerSlot") do
		taggedSet[instance] = true
	end
	local directSet = {}
	for _, instance in children do
		directSet[instance] = true
	end
	for instance in taggedSet do
		if not directSet[instance] then
			return self:_configurationFailure("тег PlayerSlot находится вне Workspace.PlayerSlots")
		end
	end

	local raw = {}
	local ids = {}
	for _, instance in children do
		if not instance:IsA("Model") or taggedSet[instance] ~= true then
			return self:_configurationFailure("каждый непосредственный объект должен быть моделью с тегом PlayerSlot")
		end
		local slotId = instance:GetAttribute("SlotId")
		if not positiveInteger(slotId) or ids[slotId] then
			return self:_configurationFailure("SlotId должен быть положительным уникальным целым числом")
		end
		if instance.Name ~= `Slot_{slotId}` then
			return self:_configurationFailure("имя модели не соответствует SlotId")
		end
		local spawn: SpawnLocation? = nil
		local spawnCount = 0
		for _, descendant in instance:GetDescendants() do
			if descendant:IsA("SpawnLocation") then
				spawnCount += 1
				if descendant.Parent == instance and descendant.Name == "PlayerSpawn" then
					spawn = descendant
				end
			end
		end
		if spawnCount ~= 1 or spawn == nil then
			return self:_configurationFailure("модель слота должна содержать ровно один непосредственный PlayerSpawn")
		end
		ids[slotId] = true
		table.insert(raw, { SlotId = slotId, SlotModel = instance, PlayerSpawn = spawn })
	end
	table.sort(raw, function(left, right)
		return left.SlotId < right.SlotId
	end)

	local byName = {}
	local byId = {}
	for _, entry in raw do
		byName[entry.SlotModel.Name] = entry
		byId[entry.SlotId] = entry
	end
	local teamsById = {}
	local colors = {}
	for _, team in self._teams:GetChildren() do
		if team:IsA("Team") then
			local slotId = team:GetAttribute("SlotId")
			local expectedByName = byName[team.Name]
			local expectedById = if positiveInteger(slotId) then byId[slotId] else nil
			if expectedByName ~= nil or expectedById ~= nil then
				if expectedByName == nil or expectedByName ~= expectedById or teamsById[slotId] ~= nil then
					return self:_configurationFailure("команда конфликтует с именем или SlotId слота")
				end
				teamsById[slotId] = team
			end
		end
	end

	local slots = {}
	for _, entry in raw do
		local team = teamsById[entry.SlotId]
		if team == nil or team.AutoAssignable then
			return self:_configurationFailure("соответствующая команда отсутствует или назначается автоматически")
		end
		if colors[team.TeamColor.Number] then
			return self:_configurationFailure("TeamColor команд слотов должен быть уникальным")
		end
		colors[team.TeamColor.Number] = true
		local spawn = entry.PlayerSpawn
		if not spawn.Enabled or spawn.Neutral or spawn.AllowTeamChangeOnTouch or spawn.TeamColor ~= team.TeamColor then
			return self:_configurationFailure("PlayerSpawn настроен неверно")
		end
		table.insert(slots, {
			SlotId = entry.SlotId,
			SlotModel = entry.SlotModel,
			Team = team,
			PlayerSpawn = spawn,
			Owner = nil,
			Reservations = {},
			Relations = {},
			Friends = {},
			Closing = false,
			Revision = 0,
		})
	end
	if self._maxPlayers < #slots * (1 + self._maxInviteCapacity) then
		return self:_configurationFailure("Players.MaxPlayers меньше требуемой вместимости слотов")
	end
	return slots, nil
end

function Strategy:Initialize()
	if self._stopped then
		error("PlayerSlotStrategyStopped", 2)
	end
	if self._ready or self._reason ~= nil then
		return
	end
	local ok, slots, reason = xpcall(function()
		return self:_buildConfiguration()
	end, debug.traceback)
	if ok and slots ~= nil then
		self._slots = slots
		for _, slot in slots do
			self._slotsById[slot.SlotId] = slot
		end
		self._ready = true
	else
		self._reason = if ok then reason else tostring(slots)
	end
end

function Strategy:_present(player: Player): boolean
	local ok, current = pcall(function()
		return self._players:GetPlayerByUserId(player.UserId)
	end)
	return ok and current == player
end

function Strategy:_findFreeSlot(): any?
	for _, slot in self._slots do
		if slot.Owner == nil and next(slot.Reservations) == nil and not slot.Closing then
			return slot
		end
	end
	return nil
end

function Strategy:GetAvailableSlotIds(): { number }
	local result = {}
	if self._stopped or not self._ready then return result end
	for _, slot in self._slots do
		if slot.Owner == nil and next(slot.Reservations) == nil and not slot.Closing then table.insert(result, slot.SlotId) end
	end
	return table.freeze(result)
end

function Strategy:PrepareAdmission(player: Player, context: any, selectedSlotId: number?): any
	if self._stopped or not self._ready then
		return table.freeze({ Ok = false, Error = "NotReady" })
	end
	if not exactContext(context) then
		return table.freeze({ Ok = false, Error = "Rejected" })
	end
	if not self:_present(player) then
		return table.freeze({ Ok = false, Error = "PlayerGone" })
	end
	if self._relationsByPlayer[player] ~= nil then
		return table.freeze({ Ok = false, Error = "Rejected" })
	end
	local slot: any
	local role = context.Kind
	local owner: Player
	if context.Kind == "Ordinary" then
		slot = if selectedSlotId ~= nil then self._slotsById[selectedSlotId] else self:_findFreeSlot()
		if slot ~= nil and (slot.Owner ~= nil or next(slot.Reservations) ~= nil or slot.Closing) then slot = nil end
		if slot == nil then return table.freeze({ Ok = false, Error = "NoSlot" }) end
		owner = player
	else
		local inviter = self._relationsByUserId[context.InviterUserId]
		if inviter == nil or inviter.Role ~= "Owner" or inviter.Player ~= inviter.Owner
			or not self:_present(inviter.Player) or inviter.Slot.Closing then
			return table.freeze({ Ok = false, Error = "Rejected" })
		end
		slot = inviter.Slot
		owner = inviter.Player
		if next(slot.Reservations) ~= nil then
			return table.freeze({ Ok = false, Error = "Rejected" })
		end
		local friendCount = 0
		for _ in slot.Friends do friendCount += 1 end
		if friendCount >= self._maxInviteCapacity then
			return table.freeze({ Ok = false, Error = "NoSlot" })
		end
	end
	local previousOk, previousTeam, previousSpawn = pcall(function()
		return player.Team, player.RespawnLocation
	end)
	if not previousOk then
		return table.freeze({ Ok = false, Error = "Rejected" })
	end
	local assigned = pcall(function()
		player.Team = slot.Team
		player.RespawnLocation = slot.PlayerSpawn
	end)
	if not assigned then
		restorePlayer(player, previousTeam, previousSpawn)
		return table.freeze({ Ok = false, Error = "Rejected" })
	end
	local operation = {
		Player = player,
		Slot = slot,
		Role = if role == "Ordinary" then "Owner" else "Friend",
		Owner = owner,
		Context = context,
		PreviousTeam = previousTeam,
		PreviousSpawn = previousSpawn,
		Stage = "Prepared",
	}
	slot.Reservations[operation] = true
	return table.freeze({ Ok = true, Operation = operation, Result = "AssignedWithSlot", SlotId = slot.SlotId })
end

function Strategy:CommitAdmission(operation: any): boolean
	if self._stopped or typeof(operation) ~= "table" or operation.Stage ~= "Prepared" then
		return false
	end
	local slot = operation.Slot
	if slot == nil or slot.Reservations[operation] ~= true or not self:_present(operation.Player) then
		self:CancelAdmission(operation)
		return false
	end
	slot.Reservations[operation] = nil
	if operation.Role == "Owner" then slot.Owner = operation.Player else slot.Friends[operation.Player] = true end
	local relation = { Slot = slot, Player = operation.Player, Role = operation.Role, Owner = operation.Owner }
	slot.Relations[operation.Player] = relation
	self._relationsByPlayer[operation.Player] = relation
	self._relationsByUserId[operation.Player.UserId] = relation
	slot.Revision += 1
	operation.Stage = "Committed"
	return true
end

function Strategy:CancelAdmission(operation: any)
	if typeof(operation) ~= "table" or operation.Stage ~= "Prepared" then
		return
	end
	if operation.Slot ~= nil and operation.Slot.Reservations[operation] == true then
		operation.Slot.Reservations[operation] = nil
	end
	restorePlayer(operation.Player, operation.PreviousTeam, operation.PreviousSpawn)
	operation.Stage = "Cancelled"
end

function Strategy:EmitAdmissionEvents(operation: any)
	if typeof(operation) ~= "table" or operation.Stage ~= "Committed" or operation.Emitted then
		return
	end
	operation.Emitted = true
	self._assigned:Fire(operation.Player, frozenRelation(operation.Slot, operation.Player))
end

function Strategy:PrepareTransfer(player: Player, inviterUserId: number): any
	if self._stopped or not self._ready then
		return table.freeze({ Ok = false, Error = "NotReady" })
	end
	if not finiteNonzeroInteger(inviterUserId) or not self:_present(player) then
		return table.freeze({ Ok = false, Error = "TargetIneligible" })
	end
	local sourceRelation = self._relationsByPlayer[player]
	local inviterRelation = self._relationsByUserId[inviterUserId]
	if sourceRelation == nil or sourceRelation.Role ~= "Owner" or sourceRelation.Owner ~= player
		or sourceRelation.Slot.Owner ~= player
	then
		return table.freeze({ Ok = false, Error = "TargetIneligible" })
	end
	if inviterRelation == nil or inviterRelation.Role ~= "Owner" or inviterRelation.Owner ~= inviterRelation.Player
		or inviterRelation.Slot.Owner ~= inviterRelation.Player or not self:_present(inviterRelation.Player)
	then
		return table.freeze({ Ok = false, Error = "TargetIneligible" })
	end
	local sourceSlot = sourceRelation.Slot
	local targetSlot = inviterRelation.Slot
	if sourceSlot == targetSlot then
		return table.freeze({ Ok = false, Error = "TargetIneligible" })
	end
	if sourceSlot.Closing or targetSlot.Closing or next(sourceSlot.Reservations) ~= nil or next(targetSlot.Reservations) ~= nil then
		return table.freeze({ Ok = false, Error = "TargetBusy" })
	end
	if next(sourceSlot.Friends) ~= nil then
		return table.freeze({ Ok = false, Error = "TargetHasDependents" })
	end
	for relatedPlayer in sourceSlot.Relations do
		if relatedPlayer ~= player then
			return table.freeze({ Ok = false, Error = "TargetHasDependents" })
		end
	end
	local friendCount = 0
	for _ in targetSlot.Friends do friendCount += 1 end
	if friendCount >= self._maxInviteCapacity then
		return table.freeze({ Ok = false, Error = "NoCapacity" })
	end
	local previousOk, previousTeam, previousSpawn = pcall(function()
		return player.Team, player.RespawnLocation
	end)
	if not previousOk then
		return table.freeze({ Ok = false, Error = "TransferFailed" })
	end
	local operation = {
		Kind = "Transfer",
		Player = player,
		Inviter = inviterRelation.Player,
		SourceSlot = sourceSlot,
		TargetSlot = targetSlot,
		SourceRelation = sourceRelation,
		PreviousRelation = table.freeze({
			SlotId = sourceSlot.SlotId,
			SlotModel = sourceSlot.SlotModel,
			Role = "Owner",
			Owner = player,
		}),
		PreviousTeam = previousTeam,
		PreviousSpawn = previousSpawn,
		SourceRevision = sourceSlot.Revision,
		TargetRevision = targetSlot.Revision,
		Stage = "Prepared",
	}
	sourceSlot.Reservations[operation] = true
	targetSlot.Reservations[operation] = true
	return table.freeze({ Ok = true, Operation = operation })
end

function Strategy:CanTransferOwner(player: Player, inviterUserId: number): string
	if self._stopped or not self._ready then return "NotReady" end
	if not finiteNonzeroInteger(inviterUserId) or not self:_present(player) then return "TargetIneligible" end
	local sourceRelation = self._relationsByPlayer[player]
	local inviterRelation = self._relationsByUserId[inviterUserId]
	if sourceRelation == nil or sourceRelation.Role ~= "Owner" or sourceRelation.Owner ~= player
		or sourceRelation.Slot.Owner ~= player or inviterRelation == nil or inviterRelation.Role ~= "Owner"
		or inviterRelation.Owner ~= inviterRelation.Player or inviterRelation.Slot.Owner ~= inviterRelation.Player
		or not self:_present(inviterRelation.Player) or sourceRelation.Slot == inviterRelation.Slot
	then
		return "TargetIneligible"
	end
	local sourceSlot = sourceRelation.Slot
	local targetSlot = inviterRelation.Slot
	if sourceSlot.Closing or targetSlot.Closing or next(sourceSlot.Reservations) ~= nil or next(targetSlot.Reservations) ~= nil then
		return "TargetBusy"
	end
	if next(sourceSlot.Friends) ~= nil then return "TargetIneligible" end
	for relatedPlayer in sourceSlot.Relations do
		if relatedPlayer ~= player then return "TargetIneligible" end
	end
	local friendCount = 0
	for _ in targetSlot.Friends do friendCount += 1 end
	return if friendCount >= self._maxInviteCapacity then "NoCapacity" else "Allowed"
end

function Strategy:CommitTransfer(operation: any): boolean
	if self._stopped or typeof(operation) ~= "table" or operation.Kind ~= "Transfer" or operation.Stage ~= "Prepared" then
		return false
	end
	local sourceSlot = operation.SourceSlot
	local targetSlot = operation.TargetSlot
	local player = operation.Player
	local currentRelation = self._relationsByPlayer[player]
	local inviterRelation = self._relationsByPlayer[operation.Inviter]
	if sourceSlot == nil or targetSlot == nil or sourceSlot.Reservations[operation] ~= true
		or targetSlot.Reservations[operation] ~= true or sourceSlot.Revision ~= operation.SourceRevision
		or targetSlot.Revision ~= operation.TargetRevision or sourceSlot.Closing or targetSlot.Closing
		or currentRelation ~= operation.SourceRelation or sourceSlot.Owner ~= player
		or inviterRelation == nil or inviterRelation.Slot ~= targetSlot or inviterRelation.Role ~= "Owner"
		or targetSlot.Owner ~= operation.Inviter or not self:_present(player) or not self:_present(operation.Inviter)
	then
		self:RollbackTransfer(operation)
		return false
	end
	local friendCount = 0
	for _ in targetSlot.Friends do friendCount += 1 end
	if next(sourceSlot.Friends) ~= nil or friendCount >= self._maxInviteCapacity then
		self:RollbackTransfer(operation)
		return false
	end
	if not assignPlayer(player, targetSlot.Team, targetSlot.PlayerSpawn) then
		restorePlayer(player, operation.PreviousTeam, operation.PreviousSpawn)
		self:RollbackTransfer(operation)
		return false
	end
	sourceSlot.Owner = nil
	sourceSlot.Relations[player] = nil
	local relation = { Slot = targetSlot, Player = player, Role = "Friend", Owner = operation.Inviter }
	targetSlot.Friends[player] = true
	targetSlot.Relations[player] = relation
	self._relationsByPlayer[player] = relation
	self._relationsByUserId[player.UserId] = relation
	sourceSlot.Revision += 1
	targetSlot.Revision += 1
	operation.CommittedSourceRevision = sourceSlot.Revision
	operation.CommittedTargetRevision = targetSlot.Revision
	operation.Stage = "Committed"
	return true
end

function Strategy:RollbackTransfer(operation: any): boolean
	if typeof(operation) ~= "table" or operation.Kind ~= "Transfer" then return false end
	local sourceSlot = operation.SourceSlot
	local targetSlot = operation.TargetSlot
	if operation.Stage == "Prepared" then
		if sourceSlot ~= nil then sourceSlot.Reservations[operation] = nil end
		if targetSlot ~= nil then targetSlot.Reservations[operation] = nil end
		operation.Stage = "RolledBack"
		return true
	end
	if operation.Stage ~= "Committed" or sourceSlot == nil or targetSlot == nil
		or sourceSlot.Reservations[operation] ~= true or targetSlot.Reservations[operation] ~= true
		or sourceSlot.Revision ~= operation.CommittedSourceRevision
		or sourceSlot.Owner ~= nil or next(sourceSlot.Friends) ~= nil
		or targetSlot.Owner ~= operation.Inviter
	then
		return false
	end
	for _ in sourceSlot.Relations do return false end
	local relation = self._relationsByPlayer[operation.Player]
	if relation == nil or relation.Slot ~= targetSlot or relation.Role ~= "Friend" or relation.Owner ~= operation.Inviter then
		return false
	end
	local propertiesRestored = assignPlayer(operation.Player, operation.PreviousTeam, operation.PreviousSpawn)
	if not propertiesRestored then restorePlayer(operation.Player, operation.PreviousTeam, operation.PreviousSpawn) end
	targetSlot.Friends[operation.Player] = nil
	targetSlot.Relations[operation.Player] = nil
	sourceSlot.Owner = operation.Player
	sourceSlot.Relations[operation.Player] = operation.SourceRelation
	self._relationsByPlayer[operation.Player] = operation.SourceRelation
	self._relationsByUserId[operation.Player.UserId] = operation.SourceRelation
	sourceSlot.Reservations[operation] = nil
	targetSlot.Reservations[operation] = nil
	sourceSlot.Revision += 1
	targetSlot.Revision += 1
	operation.Stage = "RolledBack"
	return propertiesRestored
end

function Strategy:CompleteTransfer(operation: any): boolean
	if self._stopped or typeof(operation) ~= "table" or operation.Kind ~= "Transfer" or operation.Stage ~= "Committed" then
		return false
	end
	local sourceSlot = operation.SourceSlot
	local targetSlot = operation.TargetSlot
	if sourceSlot.Reservations[operation] ~= true or targetSlot.Reservations[operation] ~= true then return false end
	sourceSlot.Reservations[operation] = nil
	targetSlot.Reservations[operation] = nil
	operation.Stage = "Completed"
	self._unassigned:Fire(operation.Player, operation.PreviousRelation)
	self._assigned:Fire(operation.Player, frozenRelation(targetSlot, operation.Player))
	return true
end

function Strategy:GetPlayerSlot(player: Player): any?
	local relation = self._relationsByPlayer[player]
	return if relation == nil then nil else frozenRelation(relation.Slot, player)
end

function Strategy:GetUserSlot(userId: number): any?
	local relation = self._relationsByUserId[userId]
	return if relation == nil then nil else frozenRelation(relation.Slot, relation.Player)
end

function Strategy:GetSlot(slotId: number): any?
	local slot = self._slotsById[slotId]
	return if slot == nil then nil else frozenSlot(slot)
end

function Strategy:GetSlots(): { any }
	local result = {}
	for _, slot in self._slots do
		table.insert(result, frozenSlot(slot))
	end
	return table.freeze(result)
end

function Strategy:CanCreateInvitation(player: Player): string
	if self._stopped or not self._ready then
		return "NotReady"
	end
	local relation = self._relationsByPlayer[player]
	return if relation ~= nil and relation.Role == "Owner" and relation.Slot.Owner == player
		and not relation.Slot.Closing and next(relation.Slot.Reservations) == nil
		then "Allowed" else "NotOwner"
end

function Strategy:BeginDeparture(player: Player): any
	local relation = self._relationsByPlayer[player]
	if relation == nil then
		return table.freeze({ Kind = "None" })
	end
	local slot = relation.Slot
	if relation.Role == "Owner" then
		slot.Closing = true
		return table.freeze({ Kind = "Owner", Operation = { Player = player, Slot = slot, Role = "Owner", Stage = "Prepared" } })
	end
	return table.freeze({ Kind = "Friend", Operation = { Player = player, Slot = slot, Role = "Friend", Stage = "Prepared" } })
end

function Strategy:CompleteDeparture(operation: any)
	if typeof(operation) ~= "table" or operation.Stage ~= "Prepared" then
		return
	end
	local relation = self._relationsByPlayer[operation.Player]
	if relation ~= nil and relation.Slot == operation.Slot and relation.Role == operation.Role then
		local snapshot = frozenRelation(operation.Slot, operation.Player)
		self._relationsByPlayer[operation.Player] = nil
		self._relationsByUserId[operation.Player.UserId] = nil
		operation.Slot.Relations[operation.Player] = nil
		if operation.Role == "Owner" then
			operation.Slot.Owner = nil
			operation.Slot.Closing = false
		else
			operation.Slot.Friends[operation.Player] = nil
		end
		operation.Slot.Revision += 1
		self._unassigned:Fire(operation.Player, snapshot)
	end
	operation.Stage = "Completed"
end

function Strategy:Stop()
	if self._stopped then
		return
	end
	self._stopped = true
	local pending = {}
	for _, slot in self._slots do
		for operation in slot.Reservations do pending[operation] = true end
	end
	for operation in pending do
		if operation.Kind == "Transfer" then self:RollbackTransfer(operation) else self:CancelAdmission(operation) end
	end
	table.clear(self._relationsByPlayer)
	table.clear(self._relationsByUserId)
end

return Strategy
