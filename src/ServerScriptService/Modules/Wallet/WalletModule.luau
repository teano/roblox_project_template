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

local function createEmptyMemento(isInitialized: boolean)
	local result: { [string]: any } = {
		IsInitialized = isInitialized,
	}
	for currencyId in WalletConfig.CurrencyIds do
		result[currencyId] = 0
	end
	return result
end

function WalletModule.new(communication: any, configCatalog: any)
	return setmetatable({
		Id = WalletConfig.ProviderId,
		Version = WalletConfig.ProviderVersion,
		Authority = "Server",
		_communication = communication,
		_configCatalog = configCatalog,
		_config = nil,
		_data = {} :: { [Player]: { [string]: any } },
		_running = {} :: { [Player]: boolean },
		MementoChanged = Signal.new(),
		Changed = Signal.new(),
	}, WalletModule)
end

function WalletModule:Initialize()
	self._config = self._configCatalog:GetRequired("Wallet")
end

function WalletModule:CreateDefault(_player: Player)
	assert(self._config ~= nil, "WalletModule is not initialized")
	return createEmptyMemento(false)
end

function WalletModule:ReconcileMemento(_player: Player, value: any, fromVersion: number)
	if fromVersion >= WalletConfig.ProviderVersion then
		return TableUtil.deepCopy(value)
	end

	-- Version 1 stored only flat currency balances. Treat every such wallet as
	-- already initialized so an existing player never receives the startup
	-- grant again after upgrading to the version 2 memento.
	local result = createEmptyMemento(true)
	if typeof(value) ~= "table" then
		return result
	end
	for currencyId in WalletConfig.CurrencyIds do
		local amount = value[currencyId]
		if isFiniteInteger(amount) then
			result[currencyId] = math.max(0, amount)
		end
	end
	return result
end

function WalletModule:ValidateMemento(_player: Player, value: any): (boolean, any?, string?)
	if typeof(value) ~= "table" or typeof(value.IsInitialized) ~= "boolean" then
		return false, nil, "Wallet IsInitialized must be a boolean"
	end
	for key in value do
		if key ~= "IsInitialized" and WalletConfig.CurrencyIds[key] ~= true then
			return false, nil, `Unknown Wallet field '{tostring(key)}'`
		end
	end

	local data = createEmptyMemento(value.IsInitialized)
	for currencyId in WalletConfig.CurrencyIds do
		local amount = value[currencyId]
		if not isFiniteInteger(amount) or amount < 0 then
			return false, nil, `Invalid amount for '{currencyId}'`
		end
		data[currencyId] = amount
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
	local data = assert(self._data[player], "Wallet memento is not set")
	if not data.IsInitialized then
		local config = assert(self._config, "WalletModule is not initialized")
		for currencyId in WalletConfig.CurrencyIds do
			data[currencyId] = config.StartingBalances[currencyId]
		end
		data.IsInitialized = true
		self.MementoChanged:Fire(player)
	end
	self._running[player] = true
end

function WalletModule:Stop(player: Player)
	self._running[player] = nil
	self._data[player] = nil
end

function WalletModule:ToClientMemento(_player: Player, value: any)
	local result = {}
	for currencyId in WalletConfig.CurrencyIds do
		result[currencyId] = value[currencyId]
	end
	return result
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
