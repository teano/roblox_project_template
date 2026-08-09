--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CommunicationProtocol = require(ReplicatedStorage.Shared.Communication.CommunicationProtocol)
local SaveControllerBuilder = require(script.Parent.SaveControllerBuilder)

local SaveModule = {}
SaveModule.__index = SaveModule

function SaveModule.new(communication: any)
	return setmetatable({
		_communication = communication,
		_controllers = {},
		_initialized = false,
	}, SaveModule)
end

function SaveModule:Initialize()
	if self._initialized then
		return
	end
	self._communication:RegisterHandler(
		CommunicationProtocol.SystemMessages.SaveClientPatchResult,
		function(payload, requestId)
			if typeof(payload) ~= "table" or typeof(payload.ControllerId) ~= "string" then
				return
			end
			local controller = self._controllers[payload.ControllerId]
			if controller ~= nil then
				controller:HandlePatchResult(payload, requestId)
			end
		end
	)
	self._initialized = true
end

function SaveModule:BuildSaveController(id: string)
	assert(self._initialized, "SaveModule is not initialized")
	assert(self._controllers[id] == nil, `SaveController '{id}' already exists`)
	return SaveControllerBuilder.new(id, self._communication, function(controller)
		self._controllers[id] = controller
	end)
end

function SaveModule:GetSaveController(id: string)
	return self._controllers[id]
end

function SaveModule:RemoveSaveController(idOrController: any)
	local removingById = typeof(idOrController) == "string"
	local id = if removingById then idOrController else idOrController.Id
	local controller = self._controllers[id]
	if controller == nil or (not removingById and controller ~= idOrController) then
		return false
	end
	local cleanup = controller:Destroy()
	if typeof(cleanup) ~= "table" or cleanup.Ok ~= true then
		return false, cleanup
	end
	self._controllers[id] = nil
	return true
end

function SaveModule:RemoveAllSaveControllers()
	local ids = {}
	for id in self._controllers do
		table.insert(ids, id)
	end
	table.sort(ids)
	local failures = {}
	for _, id in ids do
		local removed, cleanup = self:RemoveSaveController(id)
		if not removed and self._controllers[id] ~= nil then
			failures[id] = cleanup
		end
	end
	return next(failures) == nil, failures
end

return SaveModule
