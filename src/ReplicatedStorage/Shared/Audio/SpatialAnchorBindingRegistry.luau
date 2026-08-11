--!strict

local SpatialAnchorBindingRegistry = {}
SpatialAnchorBindingRegistry.__index = SpatialAnchorBindingRegistry

export type Binding = {
	Generation: number,
	Anchor: BasePart,
	Target: Instance,
	IsCurrent: () -> boolean,
	OnInvalid: (string) -> (),
}

export type Registry = typeof(setmetatable({} :: {
	_frameDriver: RBXScriptSignal,
	_logger: any,
	_connection: RBXScriptConnection?,
	_bindings: { [any]: Binding },
}, SpatialAnchorBindingRegistry))

local function readTargetCFrame(target: Instance): (CFrame?, string?)
	if target.Parent == nil then
		return nil, "TargetRemoved"
	end

	if target:IsA("Attachment") then
		return target.WorldCFrame, nil
	end

	if target:IsA("Camera") then
		return target.CFrame, nil
	end

	if target:IsA("PVInstance") then
		local ok, value = pcall(function()
			return target:GetPivot()
		end)
		if ok then
			return value, nil
		end
	end

	return nil, "SpatialTransformFailed"
end

function SpatialAnchorBindingRegistry.new(frameDriver: RBXScriptSignal, logger: any): Registry
	assert(frameDriver ~= nil and typeof(frameDriver.Connect) == "function", "SpatialFrameDriver must provide Connect")

	return setmetatable({
		_frameDriver = frameDriver,
		_logger = logger,
		_connection = nil,
		_bindings = {},
	}, SpatialAnchorBindingRegistry)
end

function SpatialAnchorBindingRegistry.Initialize(self: Registry)
	if self._connection ~= nil then
		return
	end

	self._connection = self._frameDriver:Connect(function()
		for owner, binding in pairs(self._bindings) do
			if not binding.IsCurrent() then
				self._bindings[owner] = nil
				continue
			end

			local targetCFrame, reason = readTargetCFrame(binding.Target)
			if targetCFrame == nil then
				self._bindings[owner] = nil
				binding.OnInvalid(reason or "SpatialTransformFailed")
				continue
			end

			binding.Anchor.CFrame = targetCFrame
		end
	end)
end

function SpatialAnchorBindingRegistry.Register(
	self: Registry,
	owner: any,
	generation: number,
	anchor: BasePart,
	target: Instance,
	isCurrent: () -> boolean,
	onInvalid: (string) -> ()
): (boolean, string?)
	local targetCFrame, reason = readTargetCFrame(target)
	if targetCFrame == nil then
		return false, reason
	end

	anchor.CFrame = targetCFrame
	self._bindings[owner] = {
		Generation = generation,
		Anchor = anchor,
		Target = target,
		IsCurrent = isCurrent,
		OnInvalid = onInvalid,
	}
	return true, nil
end

function SpatialAnchorBindingRegistry.Unregister(self: Registry, owner: any, generation: number)
	local binding = self._bindings[owner]
	if binding ~= nil and binding.Generation == generation then
		self._bindings[owner] = nil
	end
end

function SpatialAnchorBindingRegistry.GetActiveCount(self: Registry): number
	local count = 0
	for _ in pairs(self._bindings) do
		count += 1
	end
	return count
end

function SpatialAnchorBindingRegistry.Destroy(self: Registry)
	local connection = self._connection
	self._connection = nil
	if connection ~= nil then
		connection:Disconnect()
	end
	table.clear(self._bindings)
end

return SpatialAnchorBindingRegistry
