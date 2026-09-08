--!strict

local Strategy = {}
Strategy.__index = Strategy

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

function Strategy.new(deps: any)
	assert(typeof(deps) == "table" and deps.PlayersModule ~= nil, "DisabledPlayerSlotStrategy dependencies required")
	return setmetatable({ _players = deps.PlayersModule, _ready = false, _stopped = false }, Strategy)
end

function Strategy:Initialize()
	if self._stopped then error("PlayerSlotStrategyStopped", 2) end
	self._ready = true
end

function Strategy:GetAvailableSlotIds(): { number } return table.freeze({}) end

function Strategy:PrepareAdmission(player: Player, context: any, _selectedSlotId: number?): any
	if self._stopped or not self._ready then return table.freeze({ Ok = false, Error = "NotReady" }) end
	if not exactContext(context) then return table.freeze({ Ok = false, Error = "Rejected" }) end
	if self._players:GetPlayerByUserId(player.UserId) ~= player then return table.freeze({ Ok = false, Error = "PlayerGone" }) end
	return table.freeze({ Ok = true, Operation = { Player = player, Context = context, Stage = "Prepared" }, Result = "ApprovedWithoutSlot" })
end

function Strategy:CommitAdmission(operation: any): boolean
	if self._stopped or typeof(operation) ~= "table" or operation.Stage ~= "Prepared" then return false end
	if self._players:GetPlayerByUserId(operation.Player.UserId) ~= operation.Player then operation.Stage = "Cancelled"; return false end
	operation.Stage = "Committed"
	return true
end

function Strategy:CancelAdmission(operation: any)
	if typeof(operation) == "table" and operation.Stage == "Prepared" then operation.Stage = "Cancelled" end
end

function Strategy:EmitAdmissionEvents(_operation: any) end
function Strategy:PrepareTransfer(_player: Player, _inviterUserId: number): any
	return table.freeze({ Ok = false, Error = if self._stopped or not self._ready then "NotReady" else "TargetIneligible" })
end
function Strategy:CanTransferOwner(_player: Player, _inviterUserId: number): string
	return if self._stopped or not self._ready then "NotReady" else "TargetIneligible"
end
function Strategy:CommitTransfer(_operation: any): boolean return false end
function Strategy:RollbackTransfer(_operation: any): boolean return false end
function Strategy:CompleteTransfer(_operation: any): boolean return false end
function Strategy:GetPlayerSlot(_player: Player): any? return nil end
function Strategy:GetUserSlot(_userId: number): any? return nil end
function Strategy:GetSlot(_slotId: number): any? return nil end
function Strategy:GetSlots(): { any } return table.freeze({}) end
function Strategy:CanCreateInvitation(_player: Player): string return if self._stopped or not self._ready then "NotReady" else "Allowed" end
function Strategy:BeginDeparture(_player: Player): any return table.freeze({ Kind = "None" }) end
function Strategy:CompleteDeparture(_operation: any) end
function Strategy:Stop() self._stopped = true end

return Strategy
