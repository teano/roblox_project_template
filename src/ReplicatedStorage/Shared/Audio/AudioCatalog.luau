--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DeepFreeze = require(ReplicatedStorage.Shared.Util.DeepFreeze)
local AudioSafetyLimits = require(script.Parent.AudioSafetyLimits)

local AudioCatalog = {}
AudioCatalog.__index = AudioCatalog

local PLAYER_TYPES = { UI = true, SFX = true, World = true, Music = true }
local REF_FIELDS = { CueId = true, AssetId = true, AssetKey = true, ResourcePath = true, FolderPath = true }

local function identifier(value: any): boolean
	return typeof(value) == "string"
		and #value > 0
		and #value <= AudioSafetyLimits.MaxIdentifierBytes
		and value:match("^[A-Za-z0-9][A-Za-z0-9._%-]*$") ~= nil
end

local function finite(value: any): boolean
	return typeof(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function normalizeAssetId(value: any): string?
	if typeof(value) ~= "string" or value == "" then
		return nil
	end
	local result = value:match("^rbxassetid://(%d+)$") or value:match("^(%d+)$")
	if result == nil or #result > 32 or result:sub(1, 1) == "0" then
		return nil
	end
	return result
end

local function normalizePath(value: any): string?
	if typeof(value) ~= "string" or value == "" then
		return nil
	end
	local path = value:gsub("\\", "/")
	if path:sub(1, 1) == "/" or path:sub(-1) == "/" or path:find("//", 1, true) then
		return nil
	end
	for segment in path:gmatch("[^/]+") do
		if segment == "." or segment == ".." then return nil end
	end
	if path:sub(1, 25) == "ReplicatedStorage/Assets/" then
		path = path:sub(26)
	elseif path:sub(1, 5) == "game/" then
		if path:sub(6, 30) ~= "ReplicatedStorage/Assets/" then return nil end
		path = path:sub(31)
	elseif path:sub(1, 30) == "game.ReplicatedStorage.Assets." then
		path = path:sub(31):gsub("%.", "/")
	end
	if path:find("Assets/Shared/Sounds", 1, true) then return nil end
	if path == "Sounds" then
		path = "Shared/Sounds"
	elseif path:sub(1, 7) == "Sounds/" then
		path = "Shared/" .. path
	elseif path ~= "Sounds" and path ~= "Shared/Sounds" and path:sub(1, 14) ~= "Shared/Sounds/" then
		if path:sub(1, 7) == "Shared/" or path:sub(1, 18) == "ReplicatedStorage/" then return nil end
		path = "Shared/Sounds/" .. path
	end
	if path ~= "Shared/Sounds" and path:sub(1, 14) ~= "Shared/Sounds/" then
		return nil
	end
	if #path > AudioSafetyLimits.MaxPathBytes then return nil end
	return path
end

local function normalizeRegion(startValue: any, endValue: any): any?
	if startValue == nil and endValue == nil then
		return nil
	end
	if not finite(startValue) or not finite(endValue) or startValue < 0 or endValue <= startValue then
		return false
	end
	return { Start = startValue, End = endValue }
end

local function warn(logger: any, event: string, data: any)
	if logger ~= nil then
		logger:Warn(event, data)
	end
end

local function frozenEmpty(): any
	return table.freeze({})
end

function AudioCatalog.new(rows: any, config: any, assetRegistry: any, logger: any, sample: (() -> number)?)
	local variants = {}
	local byCue = {}
	local byCueVariant = {}
	local seenCueVariants = {}
	local byAssetId = {}
	local byAssetKey = {}
	local byResourcePath = {}
	local byFolderPath = {}
	local preloadSet = {}
	local cuePolicy = {}
	local physicalPathsByVariant = {}

	assert(typeof(rows) == "table" and getmetatable(rows) == nil, "SoundCatalogNotTable")

	for rowIndex, row in rows do
		if typeof(rowIndex) ~= "number"
			or rowIndex ~= rowIndex
			or rowIndex == math.huge
			or rowIndex == -math.huge
			or rowIndex ~= math.floor(rowIndex)
			or rowIndex < 1
			or typeof(row) ~= "table"
		then
			warn(logger, "CatalogRowSkipped", { RowIndex = tostring(rowIndex), ReasonCode = "InvalidRow" })
			continue
		end
		local cueId = row.CueId
		local variantId = row.VariantId
		local playerType = row.PlayerType
		local pairKey = if typeof(cueId) == "string" and typeof(variantId) == "string" then cueId .. "\0" .. variantId else ""
		if not identifier(cueId) or not identifier(variantId) or not PLAYER_TYPES[playerType] or seenCueVariants[pairKey] then
			warn(logger, "CatalogRowSkipped", { RowIndex = rowIndex, ReasonCode = "InvalidCueVariant" })
			continue
		end

		local requestedAssetId = normalizeAssetId(row.AssetId)
		local assetKey = if identifier(row.AssetKey) then row.AssetKey else nil
		local resourcePath = if row.ResourcePath ~= nil and row.ResourcePath ~= "" then normalizePath(row.ResourcePath) else nil
		if (row.AssetId ~= nil and row.AssetId ~= "" and requestedAssetId == nil)
			or (row.AssetKey ~= nil and row.AssetKey ~= "" and assetKey == nil)
			or (row.ResourcePath ~= nil and row.ResourcePath ~= "" and resourcePath == nil)
		then
			warn(logger, "CatalogRowSkipped", { RowIndex = rowIndex, ReasonCode = "InvalidAssetIdentity" })
			continue
		end
		local resolvedSound: Sound? = nil
		local assetId = requestedAssetId

		if assetKey ~= nil then
			local instance = assetRegistry:GetByKey(assetKey)
			if instance == nil or not instance:IsA("Sound") then
				warn(logger, "CatalogRowSkipped", { RowIndex = rowIndex, ReasonCode = "UnknownAssetKey" })
				continue
			end
			resolvedSound = instance
		end
		if resourcePath ~= nil then
			local instance = assetRegistry:Get(resourcePath)
			if instance == nil or not instance:IsA("Sound") or (resolvedSound ~= nil and resolvedSound ~= instance) then
				warn(logger, "CatalogRowSkipped", { RowIndex = rowIndex, ReasonCode = "ResourceIdentityConflict" })
				continue
			end
			resolvedSound = instance
		end
		if resolvedSound ~= nil then
			local physicalAssetId = normalizeAssetId(resolvedSound.SoundId)
			if physicalAssetId == nil or (assetId ~= nil and assetId ~= physicalAssetId) then
				warn(logger, "CatalogRowSkipped", { RowIndex = rowIndex, ReasonCode = "PhysicalIdentityConflict" })
				continue
			end
			assetId = physicalAssetId
			resourcePath = resourcePath or assetRegistry:GetPath(resolvedSound)
		end
		if assetId == nil then
			warn(logger, "CatalogRowSkipped", { RowIndex = rowIndex, ReasonCode = "MissingAssetIdentity" })
			continue
		end

		if (row.PlaybackSpeed ~= nil and not finite(row.PlaybackSpeed))
			or (row.Looping ~= nil and typeof(row.Looping) ~= "boolean")
			or (row.Preload ~= nil and typeof(row.Preload) ~= "boolean")
			or (row.AllowClientHybrid ~= nil and typeof(row.AllowClientHybrid) ~= "boolean")
		then
			warn(logger, "CatalogRowSkipped", { RowIndex = rowIndex, ReasonCode = "InvalidOptionalField" })
			continue
		end
		local volume = if row.Volume01 == nil then 1 else row.Volume01
		local speed = if row.PlaybackSpeed == nil then 1 else row.PlaybackSpeed
		local weight = if finite(row.Weight) and row.Weight > 0 then row.Weight else 1
		if row.Weight ~= nil and weight ~= row.Weight then
			warn(logger, "CatalogRowDefaulted", { RowIndex = rowIndex, Field = "Weight" })
		end
		local typeConfig = config.PlayerTypes[playerType]
		if typeConfig == nil or not finite(volume) or volume < 0 or volume > 1
			or speed < typeConfig.PlaybackSpeedMin or speed > typeConfig.PlaybackSpeedMax
		then
			warn(logger, "CatalogRowSkipped", { RowIndex = rowIndex, ReasonCode = "PlaybackBounds" })
			continue
		end
		local playbackRegion = normalizeRegion(row.PlaybackRegionStart, row.PlaybackRegionEnd)
		local loopRegion = normalizeRegion(row.LoopRegionStart, row.LoopRegionEnd)
		if playbackRegion == false then
			warn(logger, "CatalogRowSkipped", { RowIndex = rowIndex, ReasonCode = "InvalidRegion" })
			continue
		end
		if loopRegion == false then
			warn(logger, "CatalogRowDefaulted", { RowIndex = rowIndex, Field = "LoopRegion" })
			loopRegion = nil
		end
		local spatialProfileId = nil
		if playerType == "World" then
			if row.SpatialProfile ~= nil and row.SpatialProfile ~= "" and not identifier(row.SpatialProfile) then
				warn(logger, "CatalogRowSkipped", { RowIndex = rowIndex, ReasonCode = "InvalidSpatialProfile" })
				continue
			end
			spatialProfileId = if row.SpatialProfile == nil or row.SpatialProfile == ""
				then config.DefaultWorldProfileId
				else row.SpatialProfile
			if spatialProfileId == nil or config.SpatialProfilesById[spatialProfileId] == nil then
				warn(logger, "CatalogRowSkipped", { RowIndex = rowIndex, ReasonCode = "InvalidSpatialProfile" })
				continue
			end
		elseif row.SpatialProfile ~= nil and row.SpatialProfile ~= "" then
			warn(logger, "CatalogRowDefaulted", { RowIndex = rowIndex, Field = "SpatialProfile" })
		end
		local hybrid = row.AllowClientHybrid == true and playerType ~= "Music"
		if row.AllowClientHybrid == true and playerType == "Music" then
			warn(logger, "CatalogRowDefaulted", { RowIndex = rowIndex, Field = "AllowClientHybrid" })
		end

		local variant = {
			RowIndex = rowIndex,
			CueId = cueId,
			VariantId = variantId,
			AssetId = assetId,
			ContentId = "rbxassetid://" .. assetId,
			AssetKey = assetKey,
			ResourcePath = resourcePath,
			PlayerType = playerType,
			AllowClientHybrid = hybrid,
			Weight = weight,
			Volume01 = volume,
			SourceVolume = typeConfig.SourceVolumeMin + (typeConfig.SourceVolumeMax - typeConfig.SourceVolumeMin) * volume,
			PlaybackSpeed = speed,
			Looping = row.Looping == true,
			Preload = row.Preload == true,
			PlaybackRegion = playbackRegion,
			LoopRegion = loopRegion,
			SpatialProfileId = spatialProfileId,
		}
		table.insert(variants, variant)
		seenCueVariants[pairKey] = true

		local policy = cuePolicy[cueId]
		if policy == nil then
			policy = { PlayerType = playerType, AllowClientHybrid = hybrid }
			cuePolicy[cueId] = policy
			byCue[cueId] = {}
		end
		if policy.PlayerType == playerType and policy.AllowClientHybrid == hybrid then
			table.insert(byCue[cueId], variant)
			byCueVariant[pairKey] = variant
		else
			warn(logger, "CatalogConflictFirstWins", { RowIndex = rowIndex, Index = "CueId", Key = cueId })
		end

		for key, index in { AssetId = byAssetId, AssetKey = byAssetKey, ResourcePath = byResourcePath } do
			local value = variant[key]
			if value ~= nil then
				if index[value] == nil then
					index[value] = variant
				else
					warn(logger, "CatalogConflictFirstWins", { RowIndex = rowIndex, Index = key, Key = value })
				end
			end
		end
		if variant.Preload then
			preloadSet[variant.ContentId] = true
		end
	end

	local physicalSounds = table.clone(assetRegistry:FindAll({ Under = "Shared/Sounds", Recursive = true, IsA = "Sound" }))
	do
		table.sort(physicalSounds, function(a, b)
			return (assetRegistry:GetPath(a) or "") < (assetRegistry:GetPath(b) or "")
		end)
		for _, sound in physicalSounds do
			local path = assetRegistry:GetPath(sound)
			local assetId = normalizeAssetId(sound.SoundId)
			local key = sound:GetAttribute("AssetKey")
			local candidates = {}
			if assetId ~= nil and byAssetId[assetId] ~= nil then candidates[byAssetId[assetId]] = true end
			if typeof(key) == "string" and byAssetKey[key] ~= nil then candidates[byAssetKey[key]] = true end
			if path ~= nil and byResourcePath[path] ~= nil then candidates[byResourcePath[path]] = true end
			local variant = nil
			local conflict = false
			for candidate in candidates do
				if variant == nil then variant = candidate elseif variant ~= candidate then conflict = true end
			end
			if conflict then
				warn(logger, "PhysicalIdentityConflict", { ResourcePath = path or "" })
			elseif variant ~= nil then
				if assetId == nil or assetId ~= variant.AssetId
					or (typeof(key) == "string" and variant.AssetKey ~= nil and key ~= variant.AssetKey)
					or (path ~= nil and variant.ResourcePath ~= nil and path ~= variant.ResourcePath)
				then
					warn(logger, "PhysicalIdentityConflict", { ResourcePath = path or "" })
				else
					if typeof(key) == "string" and byAssetKey[key] == nil then byAssetKey[key] = variant end
					if path ~= nil and byResourcePath[path] == nil then byResourcePath[path] = variant end
					if path ~= nil then
						if variant.ResourcePath == nil then variant.ResourcePath = path end
						local paths = physicalPathsByVariant[variant]
						if paths == nil then paths = {}; physicalPathsByVariant[variant] = paths end
						paths[path] = true
					end
					if sound:GetAttribute("Preload") == true then preloadSet[variant.ContentId] = true end
				end
			end
		end
	end

	for _, variant in variants do
		local paths = physicalPathsByVariant[variant] or {}
		for path in paths do
			local folder = path:match("^(.*)/[^/]+$")
			while folder ~= nil and folder:sub(1, 13) == "Shared/Sounds" do
				local collection = byFolderPath[folder]
				if collection == nil then
					collection = {}
					byFolderPath[folder] = collection
				end
				local present = false
				for _, existing in collection do if existing == variant then present = true; break end end
				if not present then table.insert(collection, variant) end
				folder = folder:match("^(.*)/[^/]+$")
			end
		end
	end
	local preload = {}
	for contentId in preloadSet do
		table.insert(preload, contentId)
	end
	table.sort(preload)

	local snapshot = DeepFreeze({
		Version = 1,
		Variants = variants,
		Indexes = {
			ByCueId = byCue,
			ByAssetId = byAssetId,
			ByAssetKey = byAssetKey,
			ByResourcePath = byResourcePath,
			ByFolderPath = byFolderPath,
		},
		PreloadContentIds = preload,
	})
	return setmetatable({
		Snapshot = snapshot,
		_named = table.freeze(byCueVariant),
		_history = {},
		_sample = sample or math.random,
		_logger = logger,
	}, AudioCatalog)
end

function AudioCatalog:GetSnapshot(): any
	return self.Snapshot
end

function AudioCatalog:GetNamedVariant(cueId: string, variantId: string): any?
	return self._named[cueId .. "\0" .. variantId]
end

function AudioCatalog:_select(ownerKey: string, collection: any): any?
	if collection == nil or #collection == 0 then
		return nil
	end
	local previous = self._history[ownerKey]
	local excludePrevious = #collection > 1 and previous ~= nil
	local maximumWeight = 0
	for _, variant in collection do
		if not excludePrevious or variant.RowIndex ~= previous then
			maximumWeight = math.max(maximumWeight, variant.Weight)
		end
	end
	local total = 0
	local totalCompensation = 0
	for _, variant in collection do
		if excludePrevious and variant.RowIndex == previous then continue end
		local scaled = variant.Weight / maximumWeight
		local corrected = scaled - totalCompensation
		local nextTotal = total + corrected
		totalCompensation = (nextTotal - total) - corrected
		total = nextTotal
	end
	local sample = self._sample()
	if sample ~= sample or sample <= 0 then
		sample = 0
	elseif sample >= 1 then
		sample = 1 - 2 ^ -53
	end
	local selected = nil
	local accumulated = 0
	local accumulatedCompensation = 0
	for _, variant in collection do
		if excludePrevious and variant.RowIndex == previous then continue end
		selected = variant
		if sample == 0 then
			break
		end
		local scaled = variant.Weight / maximumWeight
		local corrected = scaled - accumulatedCompensation
		local nextAccumulated = accumulated + corrected
		accumulatedCompensation = (nextAccumulated - accumulated) - corrected
		accumulated = nextAccumulated
		-- Strict comparison preserves the half-open interval boundary: a sample
		-- exactly on a tie belongs to the following catalog-order variant.
		if sample < accumulated / total then
			selected = variant
			break
		end
	end
	assert(selected ~= nil, "Weighted audio collection has no selectable variant")
	self._history[ownerKey] = selected.RowIndex
	return selected
end

function AudioCatalog:Resolve(soundRef: any): (any?, string?)
	if typeof(soundRef) ~= "table" or getmetatable(soundRef) ~= nil then
		return nil, "UnknownRef"
	end
	local selectedField = nil
	for key, value in soundRef do
		if not REF_FIELDS[key] or typeof(value) ~= "string" or value == "" or selectedField ~= nil then
			return nil, "UnknownRef"
		end
		selectedField = key
	end
	if selectedField == nil then
		return nil, "UnknownRef"
	end
	local value = soundRef[selectedField]
	local variant
	if selectedField == "CueId" then
		variant = self:_select("Cue:" .. value, self.Snapshot.Indexes.ByCueId[value])
	elseif selectedField == "FolderPath" then
		local path = normalizePath(value .. "/placeholder")
		local folder = if path then path:match("^(.*)/[^/]+$") else nil
		variant = if folder then self:_select("Folder:" .. folder, self.Snapshot.Indexes.ByFolderPath[folder]) else nil
	elseif selectedField == "AssetId" then
		local id = normalizeAssetId(value)
		variant = if id then self.Snapshot.Indexes.ByAssetId[id] else nil
	elseif selectedField == "ResourcePath" then
		local path = normalizePath(value)
		variant = if path then self.Snapshot.Indexes.ByResourcePath[path] else nil
	else
		variant = self.Snapshot.Indexes.ByAssetKey[value]
	end
	if variant == nil then
		warn(self._logger, "UnknownRef", { Field = selectedField })
		return nil, "UnknownRef"
	end
	return variant, nil
end

return AudioCatalog
