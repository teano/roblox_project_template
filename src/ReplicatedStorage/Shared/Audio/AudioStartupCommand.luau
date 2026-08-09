--!strict

local AudioConfigValidator = require(script.Parent.AudioConfigValidator)
local AudioCatalog = require(script.Parent.AudioCatalog)

local Command = {}
Command.__index = Command

local REQUIRED_MODULES = { "AudioRuntimeConfig", "RoutingConfig", "SpatialProfiles", "SoundCatalog" }

local function disabled(logger: any, reasonCode: string): any
	logger:Warn("InvalidConfig", { ReasonCode = reasonCode })
	return table.freeze({ Enabled = false, ReasonCode = reasonCode })
end

function Command.new(configRoot: Instance?, assetRegistry: any, side: string, logger: any, sharedAssetsRoot: Instance?)
	return setmetatable({
		Id = "AudioStartup",
		DependsOn = { "Assets" },
		_configRoot = configRoot,
		_assetRegistry = assetRegistry,
		_side = side,
		_logger = logger,
		_sharedAssetsRoot = sharedAssetsRoot,
		_state = nil,
	}, Command)
end

function Command:Initialize(context: any)
	if self._state ~= nil then
		context.Services.AudioStartup = self._state
		return
	end
	local values = {}
	local sharedAssetsRoot = self._sharedAssetsRoot
	local soundsRoot = if sharedAssetsRoot ~= nil then sharedAssetsRoot:FindFirstChild("Sounds") else nil
	if soundsRoot == nil then
		self._state = disabled(self._logger, "MissingPhysicalSoundsRoot")
		context.Services.AudioStartup = self._state
		return
	end
	if not soundsRoot:IsA("Folder") then
		self._state = disabled(self._logger, "InvalidPhysicalSoundsRoot")
		context.Services.AudioStartup = self._state
		return
	end
	local root = self._configRoot
	if root == nil or not root:IsA("Folder") then
		self._state = disabled(self._logger, "MissingAudioConfigRoot")
		context.Services.AudioStartup = self._state
		return
	end
	for _, name in REQUIRED_MODULES do
		local module = root:FindFirstChild(name)
		if module == nil or not module:IsA("ModuleScript") then
			self._state = disabled(self._logger, "MissingModule:" .. name)
			context.Services.AudioStartup = self._state
			return
		end
		local ok, value = pcall(require, module)
		if not ok then
			self._state = disabled(self._logger, "RequireFailed:" .. name)
			context.Services.AudioStartup = self._state
			return
		end
		values[name] = value
	end
	local validation = AudioConfigValidator.validate(
		values.AudioRuntimeConfig,
		values.RoutingConfig,
		values.SpatialProfiles,
		self._side,
		self._logger
	)
	if not validation.Enabled then
		self._state = validation
		context.Services.AudioStartup = self._state
		return
	end
	local ok, catalog = xpcall(function()
		return AudioCatalog.new(values.SoundCatalog, validation.Config, self._assetRegistry, self._logger)
	end, debug.traceback)
	if not ok then
		self._state = disabled(self._logger, "CatalogBuildFailed")
	else
		self._state = table.freeze({ Enabled = true, Config = validation.Config, Catalog = catalog })
	end
	context.Services.AudioStartup = self._state
end

return Command
