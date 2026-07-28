--!strict

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
	local id = if typeof(idOrController) == "string" then idOrController else idOrController.Id
	local controller = self._controllers[id]
	if controller == nil then
		return false
	end
	controller:Destroy()
	self._controllers[id] = nil
	return true
end

return SaveModule
