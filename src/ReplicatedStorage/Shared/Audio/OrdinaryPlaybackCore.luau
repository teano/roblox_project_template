--!strict

local AudioPlaybackWrapper = require(script.Parent.AudioPlaybackWrapper)

local Core = {}
Core.__index = Core

local ORDINARY_TYPES = { UI = true, SFX = true, World = true }

local function finite(value: any): boolean
	return typeof(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function inertHandle(): any
	return table.freeze({ IsActive = function() return false end, Stop = function() end })
end

local function validOptions(options: any): boolean
	if options == nil then
		return true
	end
	if typeof(options) ~= "table" or getmetatable(options) ~= nil then
		return false
	end
	for key, value in options do
		if key ~= "VolumeMultiplier" and key ~= "PlaybackSpeedMultiplier" and key ~= "TimePosition" then
			return false
		end
		if not finite(value) then
			return false
		end
	end
	return (options.VolumeMultiplier == nil or (options.VolumeMultiplier >= 0 and options.VolumeMultiplier <= 2))
		and (options.PlaybackSpeedMultiplier == nil or (options.PlaybackSpeedMultiplier >= 0.5 and options.PlaybackSpeedMultiplier <= 2))
		and (options.TimePosition == nil or options.TimePosition >= 0)
end

function Core.new(side: string, poolModule: any, logger: any, dependencies: any?)
	return setmetatable({
		_side = side,
		_poolModule = poolModule,
		_logger = logger,
		_initialized = false,
		_enabled = false,
		_catalog = nil,
		_graph = nil,
		_pools = {},
		_active = {},
		_runtime = dependencies or {},
	}, Core)
end

function Core:Initialize(startup: any, graph: any)
	if self._initialized then return end
	self._initialized = true
	if not startup.Enabled or not graph.Enabled then
		return
	end
	local pools = {}
	local active = {}
	local createdIds = {}
	local ok = xpcall(function()
		for _, playerType in { "UI", "SFX", "World" } do
			local record = startup.Config.PlayerTypes[playerType]
			local maxActive = if self._side == "Server" then record.ServerMaxActive else record.ClientMaxActive
			local maxRetained = if self._side == "Server" then record.ServerMaxRetained else record.ClientMaxRetained
			if maxActive > 0 then
				local poolId = "Audio." .. self._side .. "." .. playerType
				pools[playerType] = self._poolModule:CreatePoolablePool(
					poolId,
					function()
						if self._runtime.WrapperFactory then return self._runtime.WrapperFactory(playerType) end
						return AudioPlaybackWrapper.new(playerType, self._runtime)
					end,
					{ MaxActive = maxActive, MaxRetained = maxRetained }
				)
				table.insert(createdIds, poolId)
				active[playerType] = {}
			end
		end
	end, debug.traceback)
	if not ok then
		for index = #createdIds, 1, -1 do pcall(function() self._poolModule:RemovePool(createdIds[index]) end) end
		self._logger:Warn("AudioDisabled", { ReasonCode = "PoolConstructionFailed", Side = self._side })
		return
	end
	self._catalog = startup.Catalog
	self._graph = graph
	self._pools = pools
	self._active = active
	self._enabled = true
end

function Core:_release(playerType: string, lease: any)
	local pool = self._pools[playerType]
	if pool == nil or not pool:IsLeaseActive(lease) then
		return
	end
	pool:TryReleaseToPool(lease)
	local queue = self._active[playerType]
	for index, value in queue do
		if value == lease then
			table.remove(queue, index)
			break
		end
	end
end

function Core:ValidateVariant(variant: any, source: any, options: any): (boolean, string?)
	if not self._enabled then
		return false, "AudioDisabled"
	end
	if variant == nil or not ORDINARY_TYPES[variant.PlayerType] or not validOptions(options) then
		return false, "InvalidRequest"
	end
	if variant.PlayerType == "World" then
		if source == nil or (source.Kind ~= "Point" and source.Kind ~= "Attached") then
			return false, "SpatialSourceRequired"
		end
		if source.Kind == "Point" and (typeof(source.Position) ~= "Vector3"
			or not finite(source.Position.X) or not finite(source.Position.Y) or not finite(source.Position.Z)) then
			return false, "InvalidSpatialSource"
		end
		local profile = self._graph.Config.SpatialProfilesById[variant.SpatialProfileId]
		if profile == nil then return false, "InvalidSpatialProfile" end
		if source.Kind == "Point" and profile.AngleCurve ~= nil then return false, "DirectionalPointUnsupported" end
		if source.Kind == "Attached" and (typeof(source.Instance) ~= "Instance"
			or not (source.Instance:IsA("PVInstance") or source.Instance:IsA("Attachment") or source.Instance:IsA("Camera")))
		then
			return false, "InvalidSpatialSource"
		end
		if source.Kind == "Attached" and source.Instance.Parent == nil then return false, "InvalidSpatialSource" end
	elseif source ~= nil then
		return false, "UnexpectedSpatialSource"
	end
	local pool = self._pools[variant.PlayerType]
	if pool == nil then
		return false, "TypeDisabled"
	end
	local typeConfig = self._graph.Config.PlayerTypes[variant.PlayerType]
	local effectiveVolume = variant.SourceVolume * (if options and options.VolumeMultiplier then options.VolumeMultiplier else 1)
	local effectiveSpeed = variant.PlaybackSpeed * (if options and options.PlaybackSpeedMultiplier then options.PlaybackSpeedMultiplier else 1)
	if effectiveVolume < typeConfig.SourceVolumeMin or effectiveVolume > typeConfig.SourceVolumeMax
		or effectiveSpeed < typeConfig.PlaybackSpeedMin or effectiveSpeed > typeConfig.PlaybackSpeedMax then return false, "PlaybackBounds" end
	if options ~= nil and options.TimePosition ~= nil and variant.PlaybackRegion ~= nil
		and (options.TimePosition < variant.PlaybackRegion.Start or options.TimePosition >= variant.PlaybackRegion.End)
	then return false, "InvalidRegion" end
	return true, nil
end

function Core:PlayVariant(variant: any, source: any, options: any): (any?, string?)
	local valid, validationReason = self:ValidateVariant(variant, source, options)
	if not valid then return nil, validationReason end
	local pool = self._pools[variant.PlayerType]
	local typeConfig = self._graph.Config.PlayerTypes[variant.PlayerType]
	local queue = self._active[variant.PlayerType]
	local maximum = if self._side == "Server"
		then typeConfig.ServerMaxActive
		else typeConfig.ClientMaxActive
	local lease
	local endedQueued = false
	local acquireContext = {
		Variant = variant,
		Parent = if self._side == "Server" then self._graph.ServerPlayback else self._graph.LocalRoot,
		Fader = self._graph.Faders[variant.PlayerType],
		InteractionGroupId = self._graph.Config.InteractionGroupId,
		SpatialProfile = if variant.SpatialProfileId then self._graph.Config.SpatialProfilesById[variant.SpatialProfileId] else nil,
		Source = source,
		VolumeMultiplier = if options then options.VolumeMultiplier else nil,
		PlaybackSpeedMultiplier = if options then options.PlaybackSpeedMultiplier else nil,
		TimePosition = if options then options.TimePosition else nil,
		LoadTimeoutSeconds = typeConfig.LoadTimeoutSeconds,
		Clock = self._runtime.Clock,
		ReadinessWait = self._runtime.ReadinessWait,
		Spawn = self._runtime.Spawn,
		Logger = self._logger,
		OnEnded = function()
			if lease == nil then endedQueued = true else self:_release(variant.PlayerType, lease) end
		end,
	}
	local replaced = if #queue >= maximum then queue[1] else nil
	if replaced ~= nil then
		-- Hard capacity is observable inside adapter acquisition, so release the
		-- exact FIFO oldest lease completely before requesting its replacement.
		self:_release(variant.PlayerType, replaced)
	end
	local ok, result = xpcall(function()
		lease = pool:Acquire(acquireContext)
		return lease
	end, debug.traceback)
	if not ok then
		self._logger:Warn("PlaybackRejected", { ReasonCode = "AcquireFailed", PlayerType = variant.PlayerType })
		return nil, "AcquireFailed"
	end
	table.insert(queue, result)
	if endedQueued then self:_release(variant.PlayerType, result) end
	local active = true
	local handle = {
		IsActive = function(): boolean
			return active and pool:IsLeaseActive(result)
		end,
		Stop = function()
			if active then
				active = false
				self:_release(variant.PlayerType, result)
			end
		end,
	}
	return table.freeze(handle), nil
end

function Core:ResolveAndPlay(ref: any, source: any, options: any): (any?, string?)
	if self._catalog == nil then
		return nil, "AudioDisabled"
	end
	local variant, reason = self._catalog:Resolve(ref)
	if variant == nil then
		return nil, reason
	end
	return self:PlayVariant(variant, source, options)
end

Core.InertHandle = inertHandle

return Core
