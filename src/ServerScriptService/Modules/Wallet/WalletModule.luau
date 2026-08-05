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
		LastTransactionSequence = 0,
	}
	for currencyId in WalletConfig.CurrencyIds do
		result[currencyId] = 0
	end
	return result
end

local function isSafeBalance(value: any): boolean
	return isFiniteInteger(value) and value >= 0 and value <= WalletConfig.MaxBalance
end

local function copyCommittedValue(value: any, seen: { [any]: any }?): any
	if typeof(value) ~= "table" then
		return value
	end

	local visited = seen or {}
	local existing = visited[value]
	if existing ~= nil then
		return existing
	end

	local copy: { [any]: any } = {}
	visited[value] = copy
	for key, child in value do
		copy[copyCommittedValue(key, visited)] = copyCommittedValue(child, visited)
	end
	return copy
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
		_committedHandlers = {} :: { any },
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
	if fromVersion >= 2 and typeof(value) == "table" then
		local result = TableUtil.deepCopy(value)
		result.LastTransactionSequence = 0
		return result
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
			result[currencyId] = math.min(WalletConfig.MaxBalance, math.max(0, amount))
		end
	end
	return result
end

function WalletModule:ValidateMemento(_player: Player, value: any): (boolean, any?, string?)
	if typeof(value) ~= "table"
		or typeof(value.IsInitialized) ~= "boolean"
		or not isFiniteInteger(value.LastTransactionSequence)
		or value.LastTransactionSequence < 0
		or value.LastTransactionSequence > WalletConfig.MaxBalance
	then
		return false, nil, "Wallet IsInitialized must be a boolean"
	end
	for key in value do
		if key ~= "IsInitialized"
			and key ~= "LastTransactionSequence"
			and WalletConfig.CurrencyIds[key] ~= true
		then
			return false, nil, `Unknown Wallet field '{tostring(key)}'`
		end
	end

	local data = createEmptyMemento(value.IsInitialized)
	data.LastTransactionSequence = value.LastTransactionSequence
	for currencyId in WalletConfig.CurrencyIds do
		local amount = value[currencyId]
		if not isSafeBalance(amount) then
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

function WalletModule:RegisterCommittedChangeHandler(handler: (Player, any) -> any)
	assert(typeof(handler) == "function", "Committed Wallet handler required")
	assert(next(self._running) == nil, "Committed Wallet handlers must register before player runtime starts")
	assert(#self._committedHandlers < 32, "Too many committed Wallet handlers")
	local record = { Callback = handler, Connected = true }
	table.insert(self._committedHandlers, record)
	local connection = {}
	function connection:Disconnect()
		if not record.Connected then return end
		record.Connected = false
		record.Callback = nil
	end
	return setmetatable(connection, {
		__index = function(_self, key)
			if key == "Connected" then return record.Connected end
			return nil
		end,
		__newindex = function()
			error("Wallet committed connection is read-only", 2)
		end,
	})
end

function WalletModule:_deliverCommitted(player: Player, change: any): { any }
	local failures = {}
	local handlers = table.clone(self._committedHandlers)
	for index, record in handlers do
		if not record.Connected or record.Callback == nil then continue end
		local ok, result = xpcall(function()
			return record.Callback(player, copyCommittedValue(change, nil))
		end, debug.traceback)
		if not ok or (typeof(result) == "table" and result.Ok == false) then
			table.insert(failures, {
				HandlerIndex = index,
				Code = if ok and typeof(result) == "table" then result.Code else "HandlerFailed",
			})
		end
	end
	return failures
end

function WalletModule:GetBalance(player: Player, currencyId: string): number?
	assert(WalletConfig.CurrencyIds[currencyId] == true, `Unknown currency '{currencyId}'`)
	local data = self._data[player]
	return if data then data[currencyId] else nil
end

function WalletModule:_set(player: Player, currencyId: string, newValue: number, reason: string, metadata: any?)
	assert(isSafeBalance(newValue), "new wallet balance must be a safe non-negative integer")
	local data = assert(self._data[player], "Wallet is not loaded")
	assert(self._running[player], "Wallet is not running")
	local oldValue = data[currencyId]
	if oldValue == newValue then
		return {
			Ok = true,
			OldValue = oldValue,
			NewValue = newValue,
			TransactionId = nil,
			TransactionSequence = data.LastTransactionSequence,
		}
	end
	if data.LastTransactionSequence >= WalletConfig.MaxBalance then
		return {
			Ok = false,
			Code = "TransactionSequenceExhausted",
			Error = "Wallet transaction sequence is exhausted",
		}
	end

	local transactionId = HttpService:GenerateGUID(false)
	local transactionSequence = data.LastTransactionSequence + 1
	data[currencyId] = newValue
	data.LastTransactionSequence = transactionSequence
	local change = {
		ProviderId = self.Id,
		Path = { currencyId },
		OldValue = oldValue,
		NewValue = newValue,
		Delta = newValue - oldValue,
		Reason = reason,
		Metadata = metadata,
		TransactionId = transactionId,
		TransactionSequence = transactionSequence,
	}
	local integrationFailures = self:_deliverCommitted(player, change)
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
		TransactionSequence = transactionSequence,
		IntegrationFailures = integrationFailures,
	}
end

function WalletModule:Add(player: Player, currencyId: string, amount: number, reason: string, metadata: any?)
	assert(WalletConfig.CurrencyIds[currencyId] == true, `Unknown currency '{currencyId}'`)
	assert(isSafeBalance(amount), "amount must be a safe non-negative integer")
	local balance = assert(self:GetBalance(player, currencyId), "Wallet is not loaded")
	if amount > WalletConfig.MaxBalance - balance then
		return {
			Ok = false,
			Code = "BalanceLimitExceeded",
			Error = "Wallet balance would exceed the safe integer limit",
		}
	end
	return self:_set(player, currencyId, balance + amount, reason, metadata)
end

function WalletModule:TrySpend(player: Player, currencyId: string, amount: number, reason: string, metadata: any?)
	assert(WalletConfig.CurrencyIds[currencyId] == true, `Unknown currency '{currencyId}'`)
	assert(isSafeBalance(amount), "amount must be a safe non-negative integer")
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
