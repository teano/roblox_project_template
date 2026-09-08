--!strict

type Attempt = {
	Generation: number,
	Deadline: number,
	Completion: BindableEvent,
	Settled: boolean,
	Abandoned: boolean,
	ErrorCode: string?,
}

local Loader = {}
Loader.__index = Loader

local function destroy(instance: Instance?)
	if instance ~= nil then
		pcall(function()
			instance:Destroy()
		end)
	end
end

local function validateLoaded(value: any): (GuiObject?, Instance?, string?)
	if typeof(value) ~= "Instance" then
		return nil, nil, "PrefabMalformed"
	end
	local carrier = value :: Instance
	local root: GuiObject? = nil
	if carrier:IsA("GuiObject") then
		root = carrier :: GuiObject
	else
		local children = carrier:GetChildren()
		if #children == 1 and children[1]:IsA("GuiObject") then
			root = children[1] :: GuiObject
		end
	end
	if root == nil then
		return nil, carrier, "PrefabMalformed"
	end
	if root:IsA("LuaSourceContainer") then
		return nil, carrier, "ForbiddenExecutableDescendant"
	end
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("LuaSourceContainer") then
			return nil, carrier, "ForbiddenExecutableDescendant"
		end
	end
	return root, carrier, nil
end

local function hasMethod(value: any, methodName: string): boolean
	if value == nil then
		return false
	end
	local ok, member = pcall(function()
		return value[methodName]
	end)
	return ok and typeof(member) == "function"
end

function Loader.new(dependencies: {
	AssetBackend: any?,
	AssetRegistry: any?,
	ContentPreloader: any,
	Clock: (() -> number)?,
	Spawn: (((() -> ()) -> ()))?,
	Delay: (((number, () -> ()) -> ()))?,
	Logger: any?,
})
	local hasAssetBackend = hasMethod(dependencies.AssetBackend, "LoadAssetAsync")
	local hasAssetRegistry = hasMethod(dependencies.AssetRegistry, "RequireByKey")
	assert(dependencies.AssetBackend == nil or hasAssetBackend,
		"WindowAssetLoader AssetBackend must expose LoadAssetAsync")
	assert(dependencies.AssetRegistry == nil or hasAssetRegistry,
		"WindowAssetLoader AssetRegistry must expose RequireByKey")
	assert(hasAssetBackend or hasAssetRegistry, "WindowAssetLoader requires an asset source")
	assert(dependencies.ContentPreloader ~= nil)
	return setmetatable({
		_backend = dependencies.AssetBackend,
		_assetRegistry = dependencies.AssetRegistry,
		_preloader = dependencies.ContentPreloader,
		_clock = dependencies.Clock or os.clock,
		_spawn = dependencies.Spawn or task.spawn,
		_delay = dependencies.Delay or task.delay,
		_logger = dependencies.Logger,
		_cache = {} :: { [string]: GuiObject },
		_attempts = {} :: { [string]: Attempt },
		_nextGeneration = {} :: { [string]: number },
		_destroyed = false,
	}, Loader)
end

function Loader:_diagnose(eventName: string, windowId: string, code: string)
	local logger = self._logger
	if logger ~= nil and typeof(logger.Warn) == "function" then
		pcall(function()
			logger:Warn(eventName, { WindowId = windowId, Code = code })
		end)
	end
end

function Loader:_start(definition: any, deadline: number): Attempt
	local windowId = definition.WindowId
	local generation = (self._nextGeneration[windowId] or 0) + 1
	self._nextGeneration[windowId] = generation
	local attempt: Attempt = {
		Generation = generation,
		Deadline = deadline,
		Completion = Instance.new("BindableEvent"),
		Settled = false,
		Abandoned = false,
		ErrorCode = nil,
	}
	self._attempts[windowId] = attempt

	self._spawn(function()
		local carrier: Instance? = nil
		local acceptedRoot: GuiObject? = nil
		local ok, errorCode = xpcall(function()
			local loaded: any
			if definition.AssetKey ~= nil then
				assert(self._assetRegistry ~= nil, "AssetRegistryUnavailable")
				local original = self._assetRegistry:RequireByKey(definition.AssetKey, "GuiObject")
				loaded = original:Clone()
			else
				assert(self._backend ~= nil, "AssetBackendUnavailable")
				loaded = self._backend:LoadAssetAsync(definition.AssetId)
			end
			local root, loadedCarrier, validationError = validateLoaded(loaded)
			carrier = loadedCarrier
			if validationError ~= nil or root == nil then
				error(validationError or "PrefabMalformed", 0)
			end
			self._preloader:Preload({ root }, { FailurePolicy = "Fail" })
			if carrier ~= root then
				root.Parent = nil
				destroy(carrier)
				carrier = nil
			end
			root.Parent = nil
			acceptedRoot = root
		end, function(problem)
			local rendered = tostring(problem)
			for _, known in { "PrefabMalformed", "ForbiddenExecutableDescendant" } do
				if string.find(rendered, known, 1, true) ~= nil then
					return known
				end
			end
			if string.find(rendered, "preload", 1, false) ~= nil then
				return "ContentPreloadFailed"
			end
			return "AssetLoadFailed"
		end)

		if not ok then
			attempt.ErrorCode = errorCode
			destroy(carrier)
		elseif self._destroyed
			or attempt.Abandoned
			or self._clock() >= attempt.Deadline
			or self._attempts[windowId] ~= attempt
		then
			destroy(acceptedRoot)
			attempt.ErrorCode = if self._destroyed then "UiSystemDestroyed" else "Timeout"
			self:_diagnose("ui_asset_attempt_abandoned", windowId, attempt.ErrorCode)
		else
			self._cache[windowId] = acceptedRoot :: GuiObject
		end

		attempt.Settled = true
		if self._attempts[windowId] == attempt then
			self._attempts[windowId] = nil
		end
		attempt.Completion:Fire()
		self._delay(0, function()
			destroy(attempt.Completion)
		end)
	end)
	return attempt
end

function Loader:_wait(attempt: Attempt, deadline: number): boolean
	if attempt.Settled then
		return true
	end
	local remaining = deadline - self._clock()
	if remaining <= 0 then
		return false
	end
	local wake = Instance.new("BindableEvent")
	local settledConnection = attempt.Completion.Event:Connect(function()
		wake:Fire(true)
	end)
	self._delay(remaining, function()
		wake:Fire(false)
	end)
	local settled = wake.Event:Wait()
	settledConnection:Disconnect()
	wake:Destroy()
	return settled == true and attempt.Settled
end

function Loader:GetTemplate(definition: any, deadline: number)
	if self._destroyed then
		return nil, { Code = "UiSystemDestroyed", WindowId = definition.WindowId }
	end
	local cached = self._cache[definition.WindowId]
	if cached ~= nil then
		return cached, nil
	end

	while self._clock() < deadline do
		local attempt = self._attempts[definition.WindowId]
		if attempt == nil then
			attempt = self:_start(definition, deadline)
		end
		if not self:_wait(attempt, deadline) then
			attempt.Abandoned = true
			return nil, { Code = "Timeout", WindowId = definition.WindowId, Phase = "AssetLoad" }
		end
		cached = self._cache[definition.WindowId]
		if cached ~= nil then
			return cached, nil
		end
		if attempt.ErrorCode ~= "Timeout" then
			return nil, { Code = attempt.ErrorCode or "AssetLoadFailed", WindowId = definition.WindowId }
		end
	end
	return nil, { Code = "Timeout", WindowId = definition.WindowId, Phase = "AssetLoad" }
end

function Loader:BeginEager(definitions: { any }, deadline: number)
	local attempts = {}
	for _, definition in definitions do
		if definition.Preload == true and self._cache[definition.WindowId] == nil then
			table.insert(attempts, {
				Definition = definition,
				Attempt = self._attempts[definition.WindowId] or self:_start(definition, deadline),
			})
		end
	end
	for _, item in attempts do
		if not self:_wait(item.Attempt, deadline) then
			item.Attempt.Abandoned = true
			self:_diagnose("ui_eager_preload_failed", item.Definition.WindowId, "Timeout")
		elseif self._cache[item.Definition.WindowId] == nil then
			self:_diagnose("ui_eager_preload_failed", item.Definition.WindowId, item.Attempt.ErrorCode or "AssetLoadFailed")
		end
	end
end

function Loader:Destroy()
	if self._destroyed then
		return
	end
	self._destroyed = true
	for _, attempt in self._attempts do
		attempt.Abandoned = true
	end
	for _, root in self._cache do
		destroy(root)
	end
	table.clear(self._cache)
end

return Loader
