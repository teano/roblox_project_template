--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ConfigProtocol = require(ReplicatedStorage.Shared.Config.ConfigProtocol)
local DeepFreeze = require(ReplicatedStorage.Shared.Util.DeepFreeze)
local Logger = require(ReplicatedStorage.Shared.Util.Logger)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)

export type ClientConfigDefinition = {
	Id: string,
	Required: boolean?,
	Decode: (value: any) -> (boolean, any?, string?),
}

local ClientConfigCatalog = {}
ClientConfigCatalog.__index = ClientConfigCatalog

local function validateDefinitions(definitions: { ClientConfigDefinition })
	local seen: { [string]: boolean } = {}
	for _, definition in definitions do
		assert(typeof(definition) == "table", "Client config definition must be a table")
		assert(
			typeof(definition.Id) == "string"
				and definition.Id ~= ""
				and #definition.Id <= ConfigProtocol.MaxIdentifierLength,
			"Client config definition Id is invalid"
		)
		assert(typeof(definition.Decode) == "function", `Client config '{definition.Id}' Decode required`)
		assert(not seen[definition.Id], `Duplicate client config Id '{definition.Id}'`)
		seen[definition.Id] = true
	end
end

function ClientConfigCatalog.new(deps: {
	Communication: any,
	BundleId: string,
	Definitions: { ClientConfigDefinition },
	Logger: any?,
})
	validateDefinitions(deps.Definitions)
	assert(
		typeof(deps.BundleId) == "string"
			and deps.BundleId ~= ""
			and #deps.BundleId <= ConfigProtocol.MaxIdentifierLength,
		"Client config BundleId is invalid"
	)
	return setmetatable({
		_communication = deps.Communication,
		_bundleId = deps.BundleId,
		_definitions = table.freeze(table.clone(deps.Definitions)),
		_logger = deps.Logger or Logger.new("Config.Client", "info"),
		_entries = table.freeze({}),
		_generation = 0,
		_initialized = false,
		Changed = Signal.new(),
	}, ClientConfigCatalog)
end

function ClientConfigCatalog:_decodeBundle(bundle: any)
	if typeof(bundle) ~= "table"
		or bundle.BundleId ~= self._bundleId
		or typeof(bundle.Generation) ~= "number"
		or bundle.Generation < 1
		or bundle.Generation ~= math.floor(bundle.Generation)
		or typeof(bundle.Configs) ~= "table"
	then
		return false, nil, nil, "invalid_bundle_envelope"
	end

	local entries: { [string]: any } = {}
	for _, definition in self._definitions do
		local rawValue = bundle.Configs[definition.Id]
		if rawValue == nil then
			if definition.Required == false then
				continue
			end
			return false, nil, nil, `required client config '{definition.Id}' is missing`
		end

		local callOk, accepted, decoded, decodeError = pcall(definition.Decode, rawValue)
		if not callOk then
			return false, nil, nil, `client decoder '{definition.Id}' threw: {tostring(accepted)}`
		end
		if not accepted or decoded == nil then
			return false, nil, nil, `client config '{definition.Id}' is invalid: {
				if typeof(decodeError) == "string" then decodeError else "decoder rejected value"
			}`
		end
		entries[definition.Id] = DeepFreeze(decoded)
	end
	DeepFreeze(entries)
	return true, entries, bundle.Generation, nil
end

function ClientConfigCatalog:_requestBundle()
	return self._communication:Request(ConfigProtocol.RequestTypes.GetClientBundle, {
		BundleId = self._bundleId,
	})
end

function ClientConfigCatalog:Initialize()
	if self._initialized then
		return
	end

	local bundle = nil
	local lastCode = "Unavailable"
	for _attempt = 1, ConfigProtocol.StartupRequestAttempts do
		local ok, payload, code = self:_requestBundle()
		if ok then
			bundle = payload
			break
		end
		lastCode = code or "Unavailable"
		if lastCode ~= "NotReady" and lastCode ~= "RateLimited" and lastCode ~= "TransportError" then
			break
		end
		task.wait(ConfigProtocol.StartupRetryDelaySeconds)
	end
	assert(bundle ~= nil, `Client config bundle '{self._bundleId}' could not be loaded: {lastCode}`)

	local decodedOk, entries, generation, decodeError = self:_decodeBundle(bundle)
	assert(decodedOk, `Client config bundle '{self._bundleId}' is invalid: {decodeError}`)
	self._entries = entries
	self._generation = generation
	self._initialized = true
	self.Changed:Fire(self._generation)
	self._logger:Info("initialized", {
		BundleId = self._bundleId,
		Generation = self._generation,
		ConfigCount = #self._definitions,
	})
end

function ClientConfigCatalog:Refresh()
	assert(self._initialized, "ClientConfigCatalog is not initialized")
	local requestOk, bundle, requestCode = self:_requestBundle()
	if not requestOk then
		return {
			Ok = false,
			Code = requestCode,
			Generation = self._generation,
		}
	end
	local decodedOk, entries, generation, decodeError = self:_decodeBundle(bundle)
	if not decodedOk then
		return {
			Ok = false,
			Code = "InvalidConfig",
			Error = decodeError,
			Generation = self._generation,
		}
	end
	if generation < self._generation then
		return {
			Ok = false,
			Code = "StaleGeneration",
			Generation = self._generation,
		}
	end
	if generation == self._generation then
		return {
			Ok = true,
			Changed = false,
			Generation = self._generation,
		}
	end

	self._entries = entries
	self._generation = generation
	self.Changed:Fire(generation)
	return {
		Ok = true,
		Changed = true,
		Generation = generation,
	}
end

function ClientConfigCatalog:Get(id: string): any?
	assert(self._initialized, "ClientConfigCatalog is not initialized")
	return self._entries[id]
end

function ClientConfigCatalog:GetRequired(id: string): any
	local value = self:Get(id)
	assert(value ~= nil, `Required client config '{id}' is unavailable`)
	return value
end

function ClientConfigCatalog:GetGeneration(): number
	return self._generation
end

function ClientConfigCatalog:IsInitialized(): boolean
	return self._initialized
end

function ClientConfigCatalog:Destroy()
	self.Changed:Destroy()
end

return ClientConfigCatalog
