--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ConfigProtocol = require(ReplicatedStorage.Shared.Config.ConfigProtocol)
local CommunicationSerialize = require(ReplicatedStorage.Shared.Communication.CommunicationSerialize)
local DeepFreeze = require(ReplicatedStorage.Shared.Util.DeepFreeze)
local Logger = require(ReplicatedStorage.Shared.Util.Logger)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)

export type ConfigDefinition = {
	Id: string,
	Key: string,
	Required: boolean?,
	Decode: (value: any) -> (boolean, any?, string?),
	ToClient: ((value: any) -> (boolean, any?, string?))?,
}

local ExperienceConfigCatalog = {}
ExperienceConfigCatalog.__index = ExperienceConfigCatalog

local function isIdentifier(value: any): boolean
	return typeof(value) == "string"
		and value ~= ""
		and #value <= ConfigProtocol.MaxIdentifierLength
end

local function validateBundleRequest(payload: any): (boolean, any?, string?)
	if typeof(payload) ~= "table" or not isIdentifier(payload.BundleId) then
		return false, nil, "invalid_bundle_request"
	end
	return true, {
		BundleId = payload.BundleId,
	}, nil
end

local function validateManifest(
	definitions: { ConfigDefinition },
	clientBundles: { [string]: { string } }
): ({ [string]: ConfigDefinition }, { [string]: { string } })
	local definitionsById: { [string]: ConfigDefinition } = {}
	local keys: { [string]: boolean } = {}
	for _, definition in definitions do
		assert(typeof(definition) == "table", "Config definition must be a table")
		assert(isIdentifier(definition.Id), "Config definition Id is invalid")
		assert(isIdentifier(definition.Key), `Config definition '{definition.Id}' Key is invalid`)
		assert(typeof(definition.Decode) == "function", `Config definition '{definition.Id}' Decode required`)
		assert(definitionsById[definition.Id] == nil, `Duplicate config Id '{definition.Id}'`)
		assert(keys[definition.Key] == nil, `Duplicate Experience Config key '{definition.Key}'`)
		definitionsById[definition.Id] = definition
		keys[definition.Key] = true
	end

	local normalizedBundles: { [string]: { string } } = {}
	for bundleId, configIds in clientBundles do
		assert(isIdentifier(bundleId), "Client config bundle Id is invalid")
		assert(typeof(configIds) == "table", `Client config bundle '{bundleId}' must be an array`)
		local seen: { [string]: boolean } = {}
		local normalizedIds = {}
		for _, configId in configIds do
			assert(isIdentifier(configId), `Client config bundle '{bundleId}' contains an invalid config Id`)
			assert(not seen[configId], `Client config bundle '{bundleId}' repeats '{configId}'`)
			local definition = definitionsById[configId]
			assert(definition ~= nil, `Client config bundle '{bundleId}' references unknown '{configId}'`)
			assert(
				typeof(definition.ToClient) == "function",
				`Client config '{configId}' requires an explicit ToClient projection`
			)
			seen[configId] = true
			table.insert(normalizedIds, configId)
		end
		normalizedBundles[bundleId] = table.freeze(normalizedIds)
	end

	return table.freeze(definitionsById), table.freeze(normalizedBundles)
end

function ExperienceConfigCatalog.new(deps: {
	ConfigService: any,
	Communication: any,
	Definitions: { ConfigDefinition },
	ClientBundles: { [string]: { string } },
	Logger: any?,
})
	local definitionsById, clientBundles = validateManifest(deps.Definitions, deps.ClientBundles)
	local self = setmetatable({
		_configService = deps.ConfigService,
		_communication = deps.Communication,
		_definitions = table.freeze(table.clone(deps.Definitions)),
		_definitionsById = definitionsById,
		_clientBundleDefinitions = clientBundles,
		_logger = deps.Logger or Logger.new("Config.Server", "info"),
		_entries = table.freeze({}),
		_clientBundles = table.freeze({}),
		_sourceSnapshot = nil,
		_sourceConnection = nil,
		_generation = 0,
		_initialized = false,
		UpdateAvailable = Signal.new(),
		Changed = Signal.new(),
	}, ExperienceConfigCatalog)

	deps.Communication:RegisterRequestHandler(
		ConfigProtocol.RequestTypes.GetClientBundle,
		validateBundleRequest,
		function(_player, payload)
			return self:_handleClientBundleRequest(payload.BundleId)
		end
	)
	return self
end

function ExperienceConfigCatalog:_decodeDefinition(definition: ConfigDefinition, rawValue: any)
	if rawValue == nil then
		if definition.Required == false then
			return true, nil, nil
		end
		return false, nil, `required Experience Config key '{definition.Key}' is missing`
	end

	local callOk, accepted, decoded, decodeError = pcall(definition.Decode, rawValue)
	if not callOk then
		return false, nil, `decoder threw: {tostring(accepted)}`
	end
	if not accepted or decoded == nil then
		return false, nil, if typeof(decodeError) == "string" then decodeError else "decoder rejected value"
	end
	return true, DeepFreeze(decoded), nil
end

function ExperienceConfigCatalog:_buildCandidate(sourceSnapshot: any, generation: number)
	local entries: { [string]: any } = {}
	for _, definition in self._definitions do
		local readOk, rawValue = pcall(function()
			return sourceSnapshot:GetValue(definition.Key)
		end)
		if not readOk then
			return false, nil, nil, `Config '{definition.Id}' read failed: {tostring(rawValue)}`
		end
		local decodedOk, decoded, decodeError = self:_decodeDefinition(definition, rawValue)
		if not decodedOk then
			return false, nil, nil, `Config '{definition.Id}' is invalid: {decodeError}`
		end
		if decoded ~= nil then
			entries[definition.Id] = decoded
		end
	end
	DeepFreeze(entries)

	local clientBundles: { [string]: any } = {}
	for bundleId, configIds in self._clientBundleDefinitions do
		local projectedConfigs: { [string]: any } = {}
		for _, configId in configIds do
			local decoded = entries[configId]
			if decoded == nil then
				continue
			end
			local definition = self._definitionsById[configId]
			local toClient = assert(definition.ToClient)
			local callOk, accepted, projected, projectionError = pcall(toClient, decoded)
			if not callOk then
				return false, nil, nil, `Client projection '{configId}' threw: {tostring(accepted)}`
			end
			if not accepted or projected == nil then
				return false, nil, nil, `Client projection '{configId}' failed: {
					if typeof(projectionError) == "string" then projectionError else "projection rejected value"
				}`
			end
			projectedConfigs[configId] = DeepFreeze(projected)
		end

		local bundle = DeepFreeze({
			BundleId = bundleId,
			Generation = generation,
			Configs = projectedConfigs,
		})
		local serializable, issues, estimatedBytes = CommunicationSerialize.inspect(bundle)
		if not serializable or estimatedBytes > ConfigProtocol.MaxClientBundleEstimatedBytes then
			return false, nil, nil, `Client bundle '{bundleId}' is invalid: {
				if issues[1] then issues[1].Reason else "bundle_too_large"
			}`
		end
		clientBundles[bundleId] = bundle
	end
	DeepFreeze(clientBundles)

	return true, entries, clientBundles, nil
end

function ExperienceConfigCatalog:_attachSourceSnapshot(sourceSnapshot: any)
	if self._sourceConnection ~= nil then
		self._sourceConnection:Disconnect()
		self._sourceConnection = nil
	end
	self._sourceSnapshot = sourceSnapshot
	if sourceSnapshot ~= nil and sourceSnapshot.UpdateAvailable ~= nil then
		self._sourceConnection = sourceSnapshot.UpdateAvailable:Connect(function()
			self.UpdateAvailable:Fire()
		end)
	end
end

function ExperienceConfigCatalog:_publish(sourceSnapshot: any, entries: any, clientBundles: any)
	self._generation += 1
	self._entries = entries
	self._clientBundles = clientBundles
	self:_attachSourceSnapshot(sourceSnapshot)
	self._initialized = true
	self.Changed:Fire(self._generation)
end

function ExperienceConfigCatalog:Initialize()
	if self._initialized then
		return
	end

	if #self._definitions == 0 then
		local candidateOk, entries, clientBundles, candidateError =
			self:_buildCandidate({
				GetValue = function()
					return nil
				end,
			}, 1)
		assert(candidateOk, candidateError)
		self:_publish(nil, entries, clientBundles)
		return
	end

	local fetchOk, sourceSnapshot = pcall(function()
		return self._configService:GetConfigAsync()
	end)
	assert(fetchOk, `Experience Config snapshot load failed: {tostring(sourceSnapshot)}`)
	local candidateOk, entries, clientBundles, candidateError =
		self:_buildCandidate(sourceSnapshot, self._generation + 1)
	assert(candidateOk, candidateError)
	self:_publish(sourceSnapshot, entries, clientBundles)
	self._logger:Info("initialized", {
		Generation = self._generation,
		ConfigCount = #self._definitions,
	})
end

function ExperienceConfigCatalog:Refresh()
	assert(self._initialized, "ExperienceConfigCatalog is not initialized")
	if self._sourceSnapshot == nil then
		return {
			Ok = true,
			Changed = false,
			Generation = self._generation,
		}
	end

	local refreshOk, refreshError = pcall(function()
		self._sourceSnapshot:Refresh()
	end)
	if not refreshOk then
		return {
			Ok = false,
			Code = "RefreshFailed",
			Error = tostring(refreshError),
			Generation = self._generation,
		}
	end

	local candidateOk, entries, clientBundles, candidateError =
		self:_buildCandidate(self._sourceSnapshot, self._generation + 1)
	if not candidateOk then
		return {
			Ok = false,
			Code = "InvalidConfig",
			Error = candidateError,
			Generation = self._generation,
		}
	end
	self:_publish(self._sourceSnapshot, entries, clientBundles)
	return {
		Ok = true,
		Changed = true,
		Generation = self._generation,
	}
end

function ExperienceConfigCatalog:_handleClientBundleRequest(bundleId: string)
	if not self._initialized then
		return false, nil, "NotReady"
	end
	local bundle = self._clientBundles[bundleId]
	if bundle == nil then
		return false, nil, "Unavailable"
	end
	return true, bundle, nil
end

function ExperienceConfigCatalog:Get(id: string): any?
	assert(self._initialized, "ExperienceConfigCatalog is not initialized")
	return self._entries[id]
end

function ExperienceConfigCatalog:GetRequired(id: string): any
	local value = self:Get(id)
	assert(value ~= nil, `Required config '{id}' is unavailable`)
	return value
end

function ExperienceConfigCatalog:GetGeneration(): number
	return self._generation
end

function ExperienceConfigCatalog:IsInitialized(): boolean
	return self._initialized
end

function ExperienceConfigCatalog:GetClientBundle(bundleId: string): any?
	assert(self._initialized, "ExperienceConfigCatalog is not initialized")
	return self._clientBundles[bundleId]
end

function ExperienceConfigCatalog:Destroy()
	if self._sourceConnection ~= nil then
		self._sourceConnection:Disconnect()
		self._sourceConnection = nil
	end
	self.UpdateAvailable:Destroy()
	self.Changed:Destroy()
end

return ExperienceConfigCatalog
