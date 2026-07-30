--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local TableUtil = require(ReplicatedStorage.Shared.Util.TableUtil)
local WalletConfig = require(ReplicatedStorage.Shared.Wallet.WalletConfig)

local WalletClient = {}
WalletClient.__index = WalletClient

local function isFiniteInteger(value: any): boolean
	return typeof(value) == "number"
		and value == value
		and value ~= math.huge
		and value ~= -math.huge
		and value == math.floor(value)
end

function WalletClient.new(communication: any)
	local self = setmetatable({
		Id = WalletConfig.ProviderId,
		Version = WalletConfig.ProviderVersion,
		Authority = "Server",
		_communication = communication,
		_data = nil :: any,
		_running = false,
		Changed = Signal.new(),
	}, WalletClient)
	communication:RegisterHandler(WalletConfig.MessageTypes.Changed, function(payload)
		self:_handleChanged(payload)
	end)
	return self
end

function WalletClient:Initialize()
end

function WalletClient:ValidateMemento(value: any): (boolean, any?, string?)
	if typeof(value) ~= "table" then
		return false, nil, "Wallet must be a table"
	end
	local result = {}
	for currencyId in WalletConfig.CurrencyIds do
		local amount = value[currencyId]
		if not isFiniteInteger(amount) or amount < 0 then
			return false, nil, `Invalid currency '{currencyId}'`
		end
		result[currencyId] = amount
	end
	return true, result, nil
end

function WalletClient:SetMemento(value: any)
	self._data = TableUtil.deepCopy(value)
end

function WalletClient:GetMemento()
	return TableUtil.deepCopy(self._data)
end

function WalletClient:Run()
	assert(self._data ~= nil, "Wallet memento is not set")
	self._running = true
end

function WalletClient:Stop()
	self._running = false
	self._data = nil
end

function WalletClient:GetBalance(currencyId: string): number?
	assert(WalletConfig.CurrencyIds[currencyId] == true, `Unknown currency '{currencyId}'`)
	return if self._data then self._data[currencyId] else nil
end

function WalletClient:_handleChanged(change: any)
	if not self._running or typeof(change) ~= "table" or typeof(change.Path) ~= "table" then
		return
	end
	local currencyId = change.Path[1]
	if typeof(currencyId) ~= "string"
		or WalletConfig.CurrencyIds[currencyId] ~= true
		or not isFiniteInteger(change.NewValue)
	then
		error("Invalid Wallet.Changed payload")
	end
	if self._data[currencyId] ~= change.OldValue then
		error("Wallet client state mismatch")
	end
	self._data[currencyId] = change.NewValue
	self.Changed:Fire(TableUtil.deepCopy(change))
end

return WalletClient
