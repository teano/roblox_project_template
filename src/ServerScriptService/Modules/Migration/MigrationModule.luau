--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SaveSerialize = require(ReplicatedStorage.Shared.Save.SaveSerialize)
local TableUtil = require(ReplicatedStorage.Shared.Util.TableUtil)
local VersionConfig = require(ReplicatedStorage.Shared.Version.VersionConfig)

export type MigrationContext = {
	Player: Player?,
	ControllerId: string?,
	IsNewProfile: boolean,
	SourceVersion: string,
	TargetVersion: string,
	CurrentVersion: string,
	MigrationId: string,
}

export type MigrationRequestContext = {
	Player: Player?,
	ControllerId: string?,
	IsNewProfile: boolean?,
}

export type MigrationController = {
	Id: string,
	TargetVersion: string,
	Order: number,
	Migrate: (self: MigrationController, document: any, context: MigrationContext) -> any?,
}

type Config = {
	CurrentVersion: string?,
	VersionProviderId: string?,
	LegacyBaselineVersion: string?,
	MaxSerializedBytes: number?,
}

type RegisteredMigration = {
	Id: string,
	TargetVersion: string,
	Order: number,
	Implementation: MigrationController,
	Execute: (self: MigrationController, document: any, context: MigrationContext) -> any?,
}

local MigrationModule = {}
MigrationModule.__index = MigrationModule

local MAX_SAFE_INTEGER = 9_007_199_254_740_991

local function parseVersion(value: any): { number }?
	if typeof(value) ~= "string" then
		return nil
	end

	local major, minor, patch = string.match(value, "^(%d+)%.(%d+)%.(%d+)$")
	if major == nil or minor == nil or patch == nil then
		return nil
	end

	local parts = {}
	for _, part in { major, minor, patch } do
		if #part > 1 and string.sub(part, 1, 1) == "0" then
			return nil
		end
		local component = tonumber(part)
		if component == nil
			or component ~= component
			or component == math.huge
			or component > MAX_SAFE_INTEGER
		then
			return nil
		end
		table.insert(parts, component)
	end
	return parts
end

local function assertVersion(value: any, label: string): string
	assert(
		parseVersion(value) ~= nil,
		`{label} must use canonical MAJOR.MINOR.PATCH non-negative safe integers`
	)
	return value :: string
end

local function compareVersions(a: string, b: string): number
	local left = parseVersion(a)
	local right = parseVersion(b)
	assert(left ~= nil, `Invalid semantic version '{a}'`)
	assert(right ~= nil, `Invalid semantic version '{b}'`)

	for index = 1, 3 do
		local lv = left[index]
		local rv = right[index]
		if lv < rv then
			return -1
		elseif lv > rv then
			return 1
		end
	end
	return 0
end

local function validateController(controller: any)
	assert(typeof(controller) == "table", "Migration controller must be a table")
	assert(typeof(controller.Id) == "string" and controller.Id ~= "", "Migration Id required")
	assertVersion(controller.TargetVersion, `Migration '{controller.Id}' TargetVersion`)
	assert(
		typeof(controller.Order) == "number"
			and controller.Order == controller.Order
			and controller.Order ~= math.huge
			and controller.Order ~= -math.huge
			and controller.Order >= 0
			and controller.Order == math.floor(controller.Order)
			and controller.Order <= MAX_SAFE_INTEGER,
		`Migration '{controller.Id}' Order must be a non-negative safe integer`
	)
	assert(typeof(controller.Migrate) == "function", `Migration '{controller.Id}' Migrate function required`)
end

local function controllerComesBefore(a: RegisteredMigration, b: RegisteredMigration): boolean
	local versionComparison = compareVersions(a.TargetVersion, b.TargetVersion)
	if versionComparison ~= 0 then
		return versionComparison < 0
	end
	if a.Order ~= b.Order then
		return a.Order < b.Order
	end
	return a.Id < b.Id
end

local function getStoredVersion(
	document: any,
	providerId: string,
	currentVersion: string,
	legacyBaselineVersion: string?,
	isNewProfile: boolean
): (string, boolean)
	assert(typeof(document) == "table", "Migration source document root must be a table")

	local providers = document.Providers
	if isNewProfile then
		assert(
			typeof(providers) == "table" and next(providers) == nil,
			"A newly created migration source must contain an empty Providers dictionary"
		)
		return currentVersion, false
	end

	if typeof(providers) ~= "table" then
		assert(
			legacyBaselineVersion ~= nil,
			"Non-empty migration source is missing a usable Providers/Version checkpoint; "
				.. "configure LegacyBaselineVersion explicitly to migrate pre-checkpoint data"
		)
		return legacyBaselineVersion :: string, false
	end

	local envelope = providers[providerId]
	if envelope == nil then
		assert(
			legacyBaselineVersion ~= nil,
			"Non-empty migration source is missing the Version provider; "
				.. "configure LegacyBaselineVersion explicitly to migrate pre-checkpoint data"
		)
		return legacyBaselineVersion :: string, false
	end
	assert(typeof(envelope) == "table", "Migration Version provider envelope must be a table")
	assert(typeof(envelope.Data) == "table", "Migration Version provider data must be a table")
	return assertVersion(envelope.Data.PreviousVersion, "Stored PreviousVersion"), true
end

local function assertProviderDictionary(providers: any)
	assert(
		typeof(providers) == "table",
		"Migration result Providers must be a string-keyed dictionary before provider application"
	)
	for providerId in providers do
		assert(
			typeof(providerId) == "string",
			"Migration result Providers must be a string-keyed dictionary before provider application"
		)
	end
end

local function assertOwnedStateUnchanged(
	document: any,
	providerId: string,
	checkpointWasPresent: boolean,
	expectedCheckpoint: string,
	expectedSession: any
)
	assert(typeof(document) == "table", "Migration replacement document root must be a table")
	assert(
		TableUtil.deepEqual(document.Session, expectedSession),
		"Migration controllers must not modify the storage-owned Session lock"
	)

	if not checkpointWasPresent then
		local providers = document.Providers
		if typeof(providers) == "table" then
			assert(
				providers[providerId] == nil,
				"Migration controllers must not create the Version PreviousVersion checkpoint"
			)
		end
		return
	end

	local providers = document.Providers
	assert(typeof(providers) == "table", "Migration removed or invalidated Providers")
	local envelope = assert(providers[providerId], "Migration removed the Version provider")
	local data = assert(envelope.Data, "Migration removed the Version provider data")
	assert(
		data.PreviousVersion == expectedCheckpoint,
		"Migration controllers must not modify the Version PreviousVersion checkpoint"
	)
end

function MigrationModule.new(controllers: { MigrationController }?, config: Config?)
	local options = config or {}
	local currentVersion = assertVersion(options.CurrentVersion or VersionConfig.CurrentVersion, "CurrentVersion")
	local legacyBaselineVersion = if options.LegacyBaselineVersion ~= nil
		then assertVersion(options.LegacyBaselineVersion, "LegacyBaselineVersion")
		else nil
	if legacyBaselineVersion ~= nil then
		assert(
			compareVersions(legacyBaselineVersion, currentVersion) <= 0,
			"LegacyBaselineVersion must not be newer than CurrentVersion"
		)
	end
	if options.MaxSerializedBytes ~= nil then
		assert(
			typeof(options.MaxSerializedBytes) == "number"
				and options.MaxSerializedBytes == options.MaxSerializedBytes
				and options.MaxSerializedBytes ~= math.huge
				and options.MaxSerializedBytes ~= -math.huge
				and options.MaxSerializedBytes >= 1
				and options.MaxSerializedBytes == math.floor(options.MaxSerializedBytes),
			"MaxSerializedBytes must be a positive integer"
		)
	end
	local versionProviderId = options.VersionProviderId or VersionConfig.ProviderId
	assert(typeof(versionProviderId) == "string" and versionProviderId ~= "", "VersionProviderId required")

	local self = setmetatable({
		_controllers = {} :: { RegisteredMigration },
		_controllersById = {} :: { [string]: RegisteredMigration },
		_currentVersion = currentVersion,
		_versionProviderId = versionProviderId,
		_legacyBaselineVersion = legacyBaselineVersion,
		_maxSerializedBytes = options.MaxSerializedBytes,
		_initialized = false,
	}, MigrationModule)

	for _, controller in controllers or {} do
		self:Register(controller)
	end
	return self
end

function MigrationModule:Initialize()
	if self._initialized then
		return
	end
	table.sort(self._controllers, controllerComesBefore)
	self._initialized = true
end

function MigrationModule:Register(controller: MigrationController)
	assert(not self._initialized, "Migration controllers must be registered before Initialize")
	validateController(controller)
	assert(self._controllersById[controller.Id] == nil, `Duplicate migration Id '{controller.Id}'`)

	-- Scheduling metadata and the callable are snapshotted at registration.
	-- Dependencies referenced by the implementation remain shared, so concrete
	-- controllers must still be stateless and reentrant across concurrent players.
	local registered: RegisteredMigration = table.freeze({
		Id = controller.Id,
		TargetVersion = controller.TargetVersion,
		Order = controller.Order,
		Implementation = controller,
		Execute = controller.Migrate,
	})
	self._controllersById[registered.Id] = registered
	table.insert(self._controllers, registered)
end

function MigrationModule:GetPlan(previousVersion: string): { RegisteredMigration }
	assert(self._initialized, "MigrationModule is not initialized")
	assertVersion(previousVersion, "PreviousVersion")
	assert(
		compareVersions(previousVersion, self._currentVersion) <= 0,
		`Stored version '{previousVersion}' is newer than server version '{self._currentVersion}'`
	)

	local selected = {}
	for _, controller in self._controllers do
		if compareVersions(controller.TargetVersion, previousVersion) > 0
			and compareVersions(controller.TargetVersion, self._currentVersion) <= 0
		then
			table.insert(selected, controller)
		end
	end
	return selected
end

function MigrationModule:Migrate(document: any, requestContext: MigrationRequestContext?): (any, boolean)
	assert(self._initialized, "MigrationModule is not initialized")
	local result = TableUtil.deepCopy(document)
	local isNewProfile = requestContext ~= nil and requestContext.IsNewProfile == true
	local previousVersion, checkpointWasPresent = getStoredVersion(
		result,
		self._versionProviderId,
		self._currentVersion,
		self._legacyBaselineVersion,
		isNewProfile
	)
	local plan = self:GetPlan(previousVersion)
	local checkpointCommitRequired = compareVersions(previousVersion, self._currentVersion) < 0
	local sourceVersion = previousVersion
	local expectedSession = TableUtil.deepCopy(result.Session)

	for index, controller in plan do
		local context: MigrationContext = {
			Player = if requestContext then requestContext.Player else nil,
			ControllerId = if requestContext then requestContext.ControllerId else nil,
			IsNewProfile = isNewProfile,
			SourceVersion = sourceVersion,
			TargetVersion = controller.TargetVersion,
			CurrentVersion = self._currentVersion,
			MigrationId = controller.Id,
		}
		local ok, migratedOrError = xpcall(function()
			return controller.Execute(controller.Implementation, result, context)
		end, debug.traceback)
		if not ok then
			error(`Migration '{controller.Id}' failed:\n{tostring(migratedOrError)}`, 0)
		end
		if migratedOrError ~= nil then
			assert(
				typeof(migratedOrError) == "table",
				`Migration '{controller.Id}' must return a document table or nil`
			)
			if migratedOrError ~= result then
				local replacementSafe, replacementIssues = SaveSerialize.validate(migratedOrError)
				if not replacementSafe then
					local first = replacementIssues[1]
					error(
						`Migration '{controller.Id}' returned an unsafe replacement document at `
							.. `'{if first then first.Path else ""}': `
							.. (if first then first.Reason else "unknown"),
						0
					)
				end
				result = TableUtil.deepCopy(migratedOrError)
			end
		end
		local ownedStateOk, ownedStateError = xpcall(function()
			assertOwnedStateUnchanged(
				result,
				self._versionProviderId,
				checkpointWasPresent,
				previousVersion,
				expectedSession
			)
		end, debug.traceback)
		if not ownedStateOk then
			error(
				`Migration '{controller.Id}' violated an owned-state boundary:\n`
					.. tostring(ownedStateError),
				0
			)
		end

		local nextController = plan[index + 1]
		if nextController == nil
			or compareVersions(nextController.TargetVersion, controller.TargetVersion) ~= 0
		then
			sourceVersion = controller.TargetVersion
		end
	end

	assertProviderDictionary(result.Providers)
	assertOwnedStateUnchanged(
		result,
		self._versionProviderId,
		checkpointWasPresent,
		previousVersion,
		expectedSession
	)

	local serializable, issues = SaveSerialize.validate(result)
	if not serializable then
		local first = issues[1]
		error(
			`Migration result is not DataStore-safe at '{if first then first.Path else ""}': `
				.. (if first then first.Reason else "unknown"),
			0
		)
	end
	-- An older checkpoint is itself a persistent transition even when that
	-- release has no raw controllers. Reject an unsaveable result before
	-- provider runtime starts instead of discovering the size failure only
	-- after Version advances its in-memory checkpoint.
	if checkpointCommitRequired and self._maxSerializedBytes ~= nil then
		local measured, encodedSize, measurementError = SaveSerialize.measureEncodedSize(result)
		if not measured then
			error(`Migration result could not be JSON encoded: {measurementError or "unknown"}`, 0)
		end
		if (encodedSize :: number) > self._maxSerializedBytes then
			error(
				`Migration result is {encodedSize} encoded bytes and exceeds the `
					.. `{self._maxSerializedBytes}-byte save limit`,
				0
			)
		end
	end
	return result, checkpointCommitRequired
end

MigrationModule.compareVersions = compareVersions

return MigrationModule
