--!strict

local SaveControllerBuilder = require(script.Parent.SaveControllerBuilder)

local SaveModule = {}
SaveModule.__index = SaveModule

function SaveModule.new(options: { OnControllerRemoving: ((any) -> ())? }?)
	assert(
		options == nil or options.OnControllerRemoving == nil or typeof(options.OnControllerRemoving) == "function",
		"OnControllerRemoving must be a function"
	)
	return setmetatable({
		_controllers = {} :: { [string]: any },
		_onControllerRemoving = if options then options.OnControllerRemoving else nil,
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
	local removingById = typeof(controllerOrId) == "string"
	local id = if removingById then controllerOrId else controllerOrId.Id
	local controller = self._controllers[id]
	if controller == nil or (not removingById and controller ~= controllerOrId) then
		return false
	end
	local cleanup = controller:Destroy(saveBeforeClose)
	if typeof(cleanup) ~= "table" or cleanup.Ok ~= true then
		return false, cleanup
	end
	if self._onControllerRemoving ~= nil then
		self._onControllerRemoving(controller)
	end
	self._controllers[id] = nil
	return true
end

function SaveModule:RemoveAllSaveControllers(saveBeforeClose: boolean?)
	local ids = {}
	for id in self._controllers do
		table.insert(ids, id)
	end
	table.sort(ids)
	local failures = {}
	for _, id in ids do
		local removed, cleanup = self:RemoveSaveController(id, saveBeforeClose)
		if not removed and self._controllers[id] ~= nil then
			failures[id] = cleanup
		end
	end
	return next(failures) == nil, failures
end

return SaveModule
