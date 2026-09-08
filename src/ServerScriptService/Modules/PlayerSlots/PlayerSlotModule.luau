--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local EnabledPlayerSlotStrategy = require(script.Parent.EnabledPlayerSlotStrategy)
local DisabledPlayerSlotStrategy = require(script.Parent.DisabledPlayerSlotStrategy)

local Module = {}
Module.__index = Module

local function finiteNonzeroInteger(value: any): boolean
	return typeof(value) == "number"
		and value == value
		and value ~= math.huge
		and value ~= -math.huge
		and value == math.floor(value)
		and value ~= 0
end

local function exactAdmissionContext(value: any): boolean
	if typeof(value) ~= "table" or getmetatable(value) ~= nil or not table.isfrozen(value) then
		return false
	end
	if value.Kind == "Ordinary" then
		for key in value do
			if key ~= "Kind" then return false end
		end
		return true
	end
	if value.Kind ~= "Friend" or not finiteNonzeroInteger(value.InviterUserId)
		or typeof(value.ClaimId) ~= "string" or value.ClaimId == "" then
		return false
	end
	for key in value do
		if key ~= "Kind" and key ~= "InviterUserId" and key ~= "ClaimId" then return false end
	end
	return true
end

function Module.new(deps: any)
	assert(typeof(deps) == "table", "PlayerSlotModule dependencies required")
	assert(deps.PlayersModule ~= nil and deps.Config ~= nil, "PlayerSlotModule requires PlayersModule and Config")
	return setmetatable({
		_deps = deps,
		_initialized = false,
		_stopped = false,
		_strategy = nil,
		PlayerAssigned = Signal.new(),
		PlayerUnassigned = Signal.new(),
	}, Module)
end

function Module:_requireActive()
	if self._stopped then error("PlayerSlotModuleStopped", 3) end
	if not self._initialized then error("PlayerSlotModuleNotInitialized", 3) end
end

function Module:Initialize()
	if self._stopped then error("PlayerSlotModuleStopped", 2) end
	if self._initialized then return end
	local playerSlotsConfig = self._deps.Config:GetRequired("PlayerSlots")
	local friendsConfig = self._deps.Config:GetRequired("Friends")
	local strategyDeps = {
		PlayersModule = self._deps.PlayersModule,
		CollectionService = self._deps.CollectionService,
		Workspace = self._deps.Workspace,
		Teams = self._deps.Teams,
		MaxPlayers = self._deps.MaxPlayers,
		MaxInviteCapacity = friendsConfig.MaxInviteCapacity,
		PlayerAssigned = self.PlayerAssigned,
		PlayerUnassigned = self.PlayerUnassigned,
	}
	if playerSlotsConfig.Strategy == "Enabled" then
		self._strategy = EnabledPlayerSlotStrategy.new(strategyDeps)
	elseif playerSlotsConfig.Strategy == "Disabled" then
		self._strategy = DisabledPlayerSlotStrategy.new(strategyDeps)
	else
		error("Unknown player-slots strategy", 2)
	end
	self._strategy:Initialize()
	self._initialized = true
end

function Module:PrepareAdmission(player: Player, context: any): any
	self:_requireActive()
	if not exactAdmissionContext(context) then
		return table.freeze({ Ok = false, Error = "Rejected" })
	end
	return self._strategy:PrepareAdmission(player, context)
end

function Module:CommitAdmission(operation: any): boolean
	self:_requireActive()
	return self._strategy:CommitAdmission(operation)
end

function Module:CancelAdmission(operation: any)
	if self._stopped or not self._initialized then return end
	self._strategy:CancelAdmission(operation)
end

function Module:EmitAdmissionEvents(operation: any)
	self:_requireActive()
	self._strategy:EmitAdmissionEvents(operation)
end

function Module:PrepareTransfer(player: Player, inviterUserId: number): any
	self:_requireActive()
	if not finiteNonzeroInteger(inviterUserId) then
		return table.freeze({ Ok = false, Error = "Rejected" })
	end
	return self._strategy:PrepareTransfer(player, inviterUserId)
end

function Module:CanTransferOwner(player: Player, inviterUserId: number): string
	if self._stopped or not self._initialized then return "NotReady" end
	if not finiteNonzeroInteger(inviterUserId) then return "TargetIneligible" end
	return self._strategy:CanTransferOwner(player, inviterUserId)
end

function Module:CommitTransfer(operation: any): boolean
	self:_requireActive()
	return self._strategy:CommitTransfer(operation)
end

function Module:RollbackTransfer(operation: any): boolean
	if self._stopped or not self._initialized then return false end
	return self._strategy:RollbackTransfer(operation)
end

function Module:CompleteTransfer(operation: any): boolean
	self:_requireActive()
	return self._strategy:CompleteTransfer(operation)
end

function Module:GetPlayerSlot(player: Player): any?
	self:_requireActive()
	return self._strategy:GetPlayerSlot(player)
end

function Module:GetUserSlot(userId: number): any?
	self:_requireActive()
	return self._strategy:GetUserSlot(userId)
end

function Module:GetSlot(slotId: number): any?
	self:_requireActive()
	return self._strategy:GetSlot(slotId)
end

function Module:GetSlots(): { any }
	self:_requireActive()
	return self._strategy:GetSlots()
end

function Module:CanCreateInvitation(player: Player): string
	if self._stopped or not self._initialized then return "NotReady" end
	return self._strategy:CanCreateInvitation(player)
end

function Module:BeginDeparture(player: Player): any
	if self._stopped or not self._initialized then return table.freeze({ Kind = "None" }) end
	return self._strategy:BeginDeparture(player)
end

function Module:CompleteDeparture(operation: any)
	if self._stopped or not self._initialized then return end
	self._strategy:CompleteDeparture(operation)
end

function Module:Stop()
	if self._stopped then return end
	self._stopped = true
	if self._strategy ~= nil then self._strategy:Stop() end
	self.PlayerAssigned:Destroy()
	self.PlayerUnassigned:Destroy()
end

return Module
