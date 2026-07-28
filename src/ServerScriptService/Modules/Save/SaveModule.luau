--!strict

local SaveControllerBuilder = require(script.Parent.SaveControllerBuilder)

local SaveModule = {}
SaveModule.__index = SaveModule

function SaveModule.new()
	return setmetatable({
		_controllers = {} :: { [string]: any },
		_initialized = false,
	}, SaveModule)
end

function SaveModule:Initialize()
	self._initialized = true
end

function SaveModule:BuildSaveController(id: string)
	assert(self._initialized, "SaveModule must be initialized")
	assert(typeof(id) == "string" and id ~= "", "Controller id required")
	assert(self._controllers[id] == nil, `SaveController '{id}' already exists`)
	return SaveControllerBuilder.new(id, function(controller)
		self._controllers[id] = controller
	end)
end

function SaveModule:GetSaveController(id: string)
	return self._controllers[id]
end

function SaveModule:RemoveSaveController(controllerOrId: any, saveBeforeClose: boolean?)
	local id = if typeof(controllerOrId) == "string" then controllerOrId else controllerOrId.Id
	local controller = self._controllers[id]
	if controller == nil then
		return false
	end
	controller:Destroy(saveBeforeClose)
	self._controllers[id] = nil
	return true
end

function SaveModule:RemoveAllSaveControllers(saveBeforeClose: boolean?)
	for id, controller in self._controllers do
		controller:Destroy(saveBeforeClose)
		self._controllers[id] = nil
	end
end

return SaveModule
