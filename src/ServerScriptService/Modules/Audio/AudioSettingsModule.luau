--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local TableUtil = require(ReplicatedStorage.Shared.Util.TableUtil)
local Schema = require(ReplicatedStorage.Shared.Audio.AudioSettingsSchema)

local AudioSettingsModule = {}
AudioSettingsModule.__index = AudioSettingsModule

function AudioSettingsModule.new()
	return setmetatable({ Id = "AudioSettings", Version = 1, Authority = "Client", ClientSnapshotPolicy = "Include", _data = {}, _faderProfiles = nil, MementoChanged = Signal.new() }, AudioSettingsModule)
end

function AudioSettingsModule:Initialize(startup: any) self._faderProfiles = if startup and startup.Enabled then startup.Config.FaderProfiles else nil end
function AudioSettingsModule:CreateDefault(_player: Player) return Schema.defaults(self._faderProfiles) end
function AudioSettingsModule:ReconcileMemento(_player: Player, value: any, _fromVersion: number)
	local ok, result = Schema.reconcileData(value, Schema.defaults(self._faderProfiles)); if not ok then return value end; return result
end
function AudioSettingsModule:ValidateEnvelope(_player: Player, envelope: any): (boolean, string?) return Schema.validateEnvelope(envelope), if Schema.validateEnvelope(envelope) then nil else "InvalidSettings" end
function AudioSettingsModule:ValidateMemento(_player: Player, value: any): (boolean, any?, string?) return Schema.validateData(value) end
function AudioSettingsModule:SetMemento(player: Player, value: any) self._data[player] = TableUtil.deepCopy(value) end
function AudioSettingsModule:ApplyClientMemento(player: Player, value: any) self:SetMemento(player, value) end
function AudioSettingsModule:GetMemento(player: Player) return TableUtil.deepCopy(self._data[player]) end
function AudioSettingsModule:BeforeMementoGet(_player: Player) end
function AudioSettingsModule:Run(_player: Player) end
function AudioSettingsModule:Stop(player: Player) self._data[player] = nil end
function AudioSettingsModule:ToClientMemento(_player: Player, value: any) return TableUtil.deepCopy(value) end

return AudioSettingsModule
