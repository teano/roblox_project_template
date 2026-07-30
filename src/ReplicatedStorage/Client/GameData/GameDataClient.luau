--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local TableUtil = require(ReplicatedStorage.Shared.Util.TableUtil)

local GameDataClient = {}
GameDataClient.__index = GameDataClient

local singleton: any = nil

function GameDataClient.new(saveController: any, providers: { any }, runtime: {
	Clock: (() -> number)?,
	Wait: ((number?) -> number?)?,
}?)
	local byId = {}
	local self = setmetatable({
		_controller = saveController,
		_providers = byId,
		_connections = {},
		_clock = if runtime and runtime.Clock then runtime.Clock else os.clock,
		_wait = if runtime and runtime.Wait then runtime.Wait else task.wait,
		Ready = Signal.new(),
		ItemChanged = Signal.new(),
	}, GameDataClient)

	for _, provider in providers do
		assert(typeof(provider.Id) == "string" and provider.Id ~= "", "GameData provider Id required")
		assert(byId[provider.Id] == nil, `Duplicate GameData provider '{provider.Id}'`)
		byId[provider.Id] = provider
		if provider.Changed then
			table.insert(self._connections, provider.Changed:Connect(function(change)
				local record = TableUtil.deepCopy(change)
				record.ItemId = record.ProviderId
				record.ProfileRevision = saveController:GetRevision()
				self.ItemChanged:Fire(record)
			end))
		end
	end
	table.insert(self._connections, saveController.Ready:Connect(function(revision)
		self.Ready:Fire(revision)
	end))
	return self
end

function GameDataClient:IsReady(): boolean
	return self._controller:IsReady()
end

function GameDataClient:WaitUntilReady(timeout: number?): boolean
	local deadline = self._clock() + (timeout or 15)
	while self._clock() < deadline do
		if self:IsReady() then
			return true
		end
		self._wait(0.05)
	end
	return self:IsReady()
end

function GameDataClient:GetItem(providerId: string): any
	local provider = self._providers[providerId]
	return if provider then provider:GetMemento() else nil
end

function GameDataClient:GetValue(providerId: string, path: { any }): any
	return TableUtil.getPath(self:GetItem(providerId), path)
end

function GameDataClient.set(instance: any)
	singleton = instance
end

function GameDataClient.get()
	return assert(singleton, "GameDataClient is not initialized")
end

function GameDataClient:Destroy()
	for _, connection in self._connections do
		connection:Disconnect()
	end
	table.clear(self._connections)
	self.Ready:Destroy()
	self.ItemChanged:Destroy()
	if singleton == self then
		singleton = nil
	end
end

return GameDataClient
