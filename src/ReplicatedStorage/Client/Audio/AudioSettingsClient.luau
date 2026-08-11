--!strict

local Signal = require(script.Parent.Parent.Parent.Shared.Util.Signal)
local TableUtil = require(script.Parent.Parent.Parent.Shared.Util.TableUtil)
local Schema = require(script.Parent.Parent.Parent.Shared.Audio.AudioSettingsSchema)
local AudioConfigValidator = require(script.Parent.Parent.Parent.Shared.Audio.AudioConfigValidator)

local AudioSettingsClient = {}
AudioSettingsClient.__index = AudioSettingsClient

function AudioSettingsClient.new(graphOwner: any)
	return setmetatable({ Id = "AudioSettings", Version = 1, Authority = "Client", _graphOwner = graphOwner, _data = nil, _running = false, MementoChanged = Signal.new(), Changed = Signal.new() }, AudioSettingsClient)
end

function AudioSettingsClient:Initialize() end
function AudioSettingsClient:_defaults()
	local graph = self._graphOwner._result
	return Schema.defaults(if graph and graph.Enabled then graph.Config.FaderProfiles else nil)
end
function AudioSettingsClient:ValidateEnvelope(envelope: any): (boolean, string?) local ok = Schema.validateEnvelope(envelope); return ok, if ok then nil else "InvalidSettings" end
function AudioSettingsClient:ReconcileSnapshotEnvelope(envelope: any?): (boolean, any?, string?)
	if envelope == nil then return true, { Version = 1, Data = self:_defaults() }, nil end
	if not Schema.validateEnvelope(envelope) then return false, nil, "InvalidSettings" end
	local ok, data = Schema.reconcileData(envelope.Data, self:_defaults())
	if not ok then return false, nil, "InvalidSettings" end
	return true, { Version = 1, Data = data }, nil
end
function AudioSettingsClient:ValidateMemento(value: any): (boolean, any?, string?) return Schema.validateData(value) end
function AudioSettingsClient:SetMemento(value: any) self._data = TableUtil.deepCopy(value) end
function AudioSettingsClient:GetMemento() return TableUtil.deepCopy(self._data) end
function AudioSettingsClient:BeforeMementoGet() end
function AudioSettingsClient:_apply()
	local graph = self._graphOwner._result
	if graph == nil or not graph.Enabled or self._data == nil then return end
	for _, id in Schema.LevelCategories do
		local profile = graph.Config.FaderProfiles[id]
		local enabled = if id == "Master" then true else self._data.Enabled[id]
		graph.Faders[id].Volume = AudioConfigValidator.levelToGain(profile, if enabled then self._data.Levels[id] else 0)
	end
end
function AudioSettingsClient:_restoreDefaults()
	local graph = self._graphOwner._result
	if graph == nil or not graph.Enabled then return end
	for _, id in Schema.LevelCategories do
		local profile = graph.Config.FaderProfiles[id]
		graph.Faders[id].Volume = AudioConfigValidator.levelToGain(profile, profile.DefaultLevel01)
	end
end
function AudioSettingsClient:Run()
	self._running = true
	self:_apply()
	local graph = self._graphOwner._result
	if graph == nil or not graph.Enabled then return end
	if not self._graphOwner:BindOutput() then
		self._running = false
		self:_restoreDefaults()
		error("Audio output binding failed", 2)
	end
end
function AudioSettingsClient:Stop()
	self._running = false
	self._graphOwner:UnbindOutput()
	self:_restoreDefaults()
	self._data = nil
end
function AudioSettingsClient:GetLevel(category: string): number return assert(self._data, "AudioSettings not loaded").Levels[category] end
function AudioSettingsClient:SetLevel(category: string, level01: number): boolean
	if self._data == nil or typeof(level01) ~= "number" or level01 ~= level01 or level01 < 0 or level01 > 1 or self._data.Levels[category] == nil then return false end
	local oldValue = self._data.Levels[category]
	if oldValue == level01 then return true end
	self._data.Levels[category] = level01
	self:_apply()
	self.MementoChanged:Fire()
	self.Changed:Fire({
		ProviderId = self.Id,
		Path = { "Levels", category },
		OldValue = oldValue,
		NewValue = level01,
	})
	return true
end
function AudioSettingsClient:IsEnabled(category: string): boolean return assert(self._data, "AudioSettings not loaded").Enabled[category] end
function AudioSettingsClient:SetEnabled(category: string, enabled: boolean): boolean
	if self._data == nil or typeof(enabled) ~= "boolean" or self._data.Enabled[category] == nil then return false end
	local oldValue = self._data.Enabled[category]
	if oldValue == enabled then return true end
	self._data.Enabled[category] = enabled
	self:_apply()
	self.MementoChanged:Fire()
	self.Changed:Fire({
		ProviderId = self.Id,
		Path = { "Enabled", category },
		OldValue = oldValue,
		NewValue = enabled,
	})
	return true
end

return AudioSettingsClient
