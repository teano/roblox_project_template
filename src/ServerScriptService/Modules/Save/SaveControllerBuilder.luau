--!strict

local ServerSaveController = require(script.Parent.ServerSaveController)

local SaveControllerBuilder = {}
SaveControllerBuilder.__index = SaveControllerBuilder

function SaveControllerBuilder.new(id: string, buildCallback: (any) -> ())
	return setmetatable({
		_id = id,
		_buildCallback = buildCallback,
		_providers = {},
		_storage = nil,
		_keyResolver = nil,
		_softLimit = nil,
		_logger = nil,
		_built = false,
	}, SaveControllerBuilder)
end

function SaveControllerBuilder:WithSaveProvider(provider: any)
	assert(not self._built, "Builder already used")
	for _, current in self._providers do
		assert(current ~= provider and current.Id ~= provider.Id, `Duplicate provider '{provider.Id}'`)
	end
	table.insert(self._providers, provider)
	return self
end

function SaveControllerBuilder:WithStorage(storage: any)
	assert(not self._built, "Builder already used")
	self._storage = storage
	return self
end

function SaveControllerBuilder:WithKeyResolver(keyResolver: (Player) -> string)
	assert(not self._built, "Builder already used")
	self._keyResolver = keyResolver
	return self
end

function SaveControllerBuilder:WithSoftSerializedBytesLimit(limit: number)
	assert(not self._built, "Builder already used")
	self._softLimit = limit
	return self
end

function SaveControllerBuilder:WithLogger(logger: any)
	assert(not self._built, "Builder already used")
	self._logger = logger
	return self
end

function SaveControllerBuilder:Build()
	assert(not self._built, "Builder already used")
	assert(self._storage ~= nil, "SaveController storage is required")
	assert(self._keyResolver ~= nil, "SaveController key resolver is required")
	self._built = true

	local controller = ServerSaveController.new({
		Id = self._id,
		Providers = self._providers,
		Storage = self._storage,
		KeyResolver = self._keyResolver,
		SoftSerializedBytesLimit = self._softLimit,
		Logger = self._logger,
	})
	self._buildCallback(controller)
	return controller
end

return SaveControllerBuilder
