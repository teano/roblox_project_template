--!strict

local ClientSaveController = require(script.Parent.ClientSaveController)

local SaveControllerBuilder = {}
SaveControllerBuilder.__index = SaveControllerBuilder

function SaveControllerBuilder.new(id: string, communication: any, callback: (any) -> ())
	return setmetatable({
		_id = id,
		_communication = communication,
		_callback = callback,
		_providers = {},
		_built = false,
	}, SaveControllerBuilder)
end

function SaveControllerBuilder:WithSaveProvider(provider: any)
	assert(not self._built, "Builder already used")
	for _, current in self._providers do
		assert(current.Id ~= provider.Id, `Duplicate provider '{provider.Id}'`)
	end
	table.insert(self._providers, provider)
	return self
end

function SaveControllerBuilder:Build()
	assert(not self._built, "Builder already used")
	self._built = true
	local controller = ClientSaveController.new({
		Id = self._id,
		Providers = self._providers,
		Communication = self._communication,
	})
	self._callback(controller)
	return controller
end

return SaveControllerBuilder
