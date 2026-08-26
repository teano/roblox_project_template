--!strict

local Blocker = {}
Blocker.__index = Blocker

local function setSink(sink: GuiObject?, enabled: boolean)
	if sink == nil then
		return
	end
	pcall(function()
		(sink :: any).InputSink = if enabled then Enum.InputSink.All else Enum.InputSink.None
	end)
end

local function makeInertHandle()
	return table.freeze({ Release = function() end })
end

function Blocker.new(root: GuiObject, onChanged: ((boolean) -> ())?)
	return setmetatable({
		_root = root,
		_onChanged = onChanged,
		_generation = 0,
		_tokens = {} :: { [any]: boolean },
		_handles = {} :: { [any]: boolean },
		_connections = {} :: { any },
		_sinkConnection = nil,
		_ref = nil :: ObjectValue?,
		_sink = nil :: GuiObject?,
		_effective = false,
		_active = false,
	}, Blocker)
end

function Blocker:_disconnect()
	if self._sinkConnection ~= nil then
		self._sinkConnection:Disconnect()
		self._sinkConnection = nil
	end
	for _, connection in self._connections do
		pcall(function()
			connection:Disconnect()
		end)
	end
	table.clear(self._connections)
end

function Blocker:_setEffective(value: boolean)
	if self._effective == value then
		return
	end
	self._effective = value
	if self._onChanged ~= nil then
		pcall(self._onChanged, value)
	end
end

function Blocker:_apply()
	local nextEffective = self._active and self._sink ~= nil and next(self._tokens) ~= nil
	setSink(self._sink, nextEffective)
	self:_setEffective(nextEffective)
end

function Blocker:_bindSink()
	local oldSink = self._sink
	local value = if self._ref ~= nil then self._ref.Value else nil
	local sink = if value ~= nil
		and value:IsA("GuiObject")
		and value:IsDescendantOf(self._root)
	then value :: GuiObject else nil
	if oldSink ~= sink then
		if self._sinkConnection ~= nil then
			self._sinkConnection:Disconnect()
			self._sinkConnection = nil
		end
		setSink(oldSink, false)
		self._sink = sink
		if sink ~= nil then
			self._sinkConnection = sink.AncestryChanged:Connect(function()
				self:_bindSink()
			end)
		end
	end
	self:_apply()
end

function Blocker:_bindReference()
	self:_disconnect()
	setSink(self._sink, false)
	self._sink = nil
	local found = self._root:FindFirstChild("BlockObjectRef")
	self._ref = if found ~= nil and found:IsA("ObjectValue") and found.Parent == self._root
		then found :: ObjectValue
		else nil
	if self._ref ~= nil then
		table.insert(self._connections, self._ref:GetPropertyChangedSignal("Value"):Connect(function()
			self:_bindSink()
		end))
	end
	table.insert(self._connections, self._root.ChildAdded:Connect(function(child)
		if child.Name == "BlockObjectRef" then
			self:_bindReference()
		end
	end))
	table.insert(self._connections, self._root.ChildRemoved:Connect(function(child)
		if child == self._ref or child.Name == "BlockObjectRef" then
			self:_bindReference()
		end
	end))
	self:_bindSink()
end

function Blocker:Initialize()
	self:Clear()
	self._generation += 1
	self._active = true
	self:_bindReference()
	return { Kind = "Success" }
end

function Blocker:Acquire()
	if not self._active or self._sink == nil then
		return makeInertHandle()
	end
	local token = {}
	local generation = self._generation
	self._tokens[token] = true
	local owner = self
	local released = false
	local handle: any = {}
	function handle:Release()
		if released then
			return
		end
		released = true
		owner._handles[handle] = nil
		if owner._active and owner._generation == generation and owner._tokens[token] then
			owner._tokens[token] = nil
			owner:_apply()
		end
	end
	self._handles[handle] = true
	self:_apply()
	return table.freeze(handle)
end

function Blocker:IsEffective(): boolean
	return self._effective
end

function Blocker:Clear()
	setSink(self._sink, false)
	self:_disconnect()
	self._active = false
	self._ref = nil
	self._sink = nil
	table.clear(self._tokens)
	table.clear(self._handles)
	self:_setEffective(false)
	return { Kind = "Success" }
end

return Blocker
