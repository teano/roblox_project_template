--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local TableUtil = require(ReplicatedStorage.Shared.Util.TableUtil)

local GameDataClient = {}
GameDataClient.__index = GameDataClient

local singleton: any = nil

function GameDataClient.new(saveController: any, providers: { any })
	local byId = {}
	local self = setmetatable({
		_controller = saveController,
		_providers = byId,
		_connections = {},
		Ready = Signal.new(),
		ItemChanged = Signal.new(),
	}, GameDataClient)

	for _, provider in providers do
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
	local deadline = os.clock() + (timeout or 15)
	while os.clock() < deadline do
		if self:IsReady() then
			return true
		end
		task.wait(0.05)
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

return GameDataClient
