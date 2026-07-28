--!strict

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local TableUtil = require(ReplicatedStorage.Shared.Util.TableUtil)
local WalletConfig = require(ReplicatedStorage.Shared.Wallet.WalletConfig)
local CommunicationProtocol = require(ReplicatedStorage.Shared.Communication.CommunicationProtocol)

local WalletModule = {}
WalletModule.__index = WalletModule

local function isFiniteInteger(value: any): boolean
	return typeof(value) == "number"
		and value == value
		and value ~= math.huge
		and value ~= -math.huge
		and value == math.floor(value)
end

function WalletModule.new(communication: any)
	return setmetatable({
		Id = WalletConfig.ProviderId,
		Version = WalletConfig.ProviderVersion,
		Authority = "Server",
		_communication = communication,
		_data = {} :: { [Player]: { [string]: number } },
		_running = {} :: { [Player]: boolean },
		MementoChanged = Signal.new(),
		Changed = Signal.new(),
	}, WalletModule)
end

function WalletModule:Initialize()
end

function WalletModule:CreateDefault(_player: Player)
	return TableUtil.deepCopy(WalletConfig.Defaults)
end

function WalletModule:ReconcileMemento(player: Player, value: any, _fromVersion: number)
	local result = self:CreateDefault(player)
	if typeof(value) == "table" then
		for currencyId in WalletConfig.CurrencyIds do
			local amount = value[currencyId]
			if isFiniteInteger(amount) then
				result[currencyId] = math.max(0, amount)
			end
		end
	end
	return result
end

function WalletModule:ValidateMemento(player: Player, value: any): (boolean, any?, string?)
	local data = self:ReconcileMemento(player, value, self.Version)
	for key, amount in data do
		if WalletConfig.CurrencyIds[key] ~= true then
			return false, nil, `Unknown currency '{tostring(key)}'`
		end
		if not isFiniteInteger(amount) or amount < 0 then
			return false, nil, `Invalid amount for '{key}'`
		end
	end
	return true, data, nil
end

function WalletModule:SetMemento(player: Player, value: any)
	self._data[player] = TableUtil.deepCopy(value)
end

function WalletModule:GetMemento(player: Player)
	return TableUtil.deepCopy(assert(self._data[player], "Wallet memento is not set"))
end

function WalletModule:BeforeMementoGet(_player: Player)
end

function WalletModule:Run(player: Player)
	assert(self._data[player] ~= nil, "Wallet memento is not set")
	self._running[player] = true
end

function WalletModule:Stop(player: Player)
	self._running[player] = nil
	self._data[player] = nil
end

function WalletModule:ToClientMemento(_player: Player, value: any)
	return TableUtil.deepCopy(value)
end

function WalletModule:GetBalance(player: Player, currencyId: string): number?
	assert(WalletConfig.CurrencyIds[currencyId] == true, `Unknown currency '{currencyId}'`)
	local data = self._data[player]
	return if data then data[currencyId] else nil
end

function WalletModule:_set(player: Player, currencyId: string, newValue: number, reason: string, metadata: any?)
	local data = assert(self._data[player], "Wallet is not loaded")
	assert(self._running[player], "Wallet is not running")
	local oldValue = data[currencyId]
	if oldValue == newValue then
		return {
			Ok = true,
			OldValue = oldValue,
			NewValue = newValue,
			TransactionId = HttpService:GenerateGUID(false),
		}
	end

	data[currencyId] = newValue
	local transactionId = HttpService:GenerateGUID(false)
	local change = {
		ProviderId = self.Id,
		Path = { currencyId },
		OldValue = oldValue,
		NewValue = newValue,
		Delta = newValue - oldValue,
		Reason = reason,
		Metadata = metadata,
		TransactionId = transactionId,
	}
	self.MementoChanged:Fire(player)
	self.Changed:Fire(player, change)
	self._communication:Queue(player, WalletConfig.MessageTypes.Changed, change, nil, {
		Priority = CommunicationProtocol.Priorities.State,
	})
	return {
		Ok = true,
		OldValue = oldValue,
		NewValue = newValue,
		TransactionId = transactionId,
	}
end

function WalletModule:Add(player: Player, currencyId: string, amount: number, reason: string, metadata: any?)
	assert(WalletConfig.CurrencyIds[currencyId] == true, `Unknown currency '{currencyId}'`)
	assert(isFiniteInteger(amount) and amount >= 0, "amount must be a non-negative integer")
	local balance = assert(self:GetBalance(player, currencyId), "Wallet is not loaded")
	return self:_set(player, currencyId, balance + amount, reason, metadata)
end

function WalletModule:TrySpend(player: Player, currencyId: string, amount: number, reason: string, metadata: any?)
	assert(WalletConfig.CurrencyIds[currencyId] == true, `Unknown currency '{currencyId}'`)
	assert(isFiniteInteger(amount) and amount >= 0, "amount must be a non-negative integer")
	local balance = assert(self:GetBalance(player, currencyId), "Wallet is not loaded")
	if balance < amount then
		return {
			Ok = false,
			Code = "InsufficientFunds",
			Error = "Insufficient funds",
		}
	end
	return self:_set(player, currencyId, balance - amount, reason, metadata)
end

return WalletModule
