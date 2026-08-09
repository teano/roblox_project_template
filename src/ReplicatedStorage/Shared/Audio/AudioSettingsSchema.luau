--!strict

local Schema = {}

Schema.LevelCategories = table.freeze({ "Master", "UI", "SFX", "World", "Music" })
Schema.EnabledCategories = table.freeze({ "UI", "SFX", "World", "Music" })

function Schema.defaults(faderProfiles: any?): any
	local levels = {}
	for _, id in Schema.LevelCategories do levels[id] = if faderProfiles and faderProfiles[id] then faderProfiles[id].DefaultLevel01 else 1 end
	return { Levels = levels, Enabled = { UI = true, SFX = true, World = true, Music = true } }
end

local function exactKeys(value: any, keys: any): boolean
	if typeof(value) ~= "table" or getmetatable(value) ~= nil then return false end
	local expected = {}
	for _, key in keys do expected[key] = true end
	for key in value do if not expected[key] then return false end end
	for key in expected do if value[key] == nil then return false end end
	return true
end

function Schema.validateEnvelope(envelope: any): boolean
	if typeof(envelope) ~= "table" or getmetatable(envelope) ~= nil then return false end
	for key in envelope do if key ~= "Version" and key ~= "Data" then return false end end
	return envelope.Version == 1 and typeof(envelope.Data) == "table" and envelope.Data ~= nil
end

function Schema.validateData(value: any): (boolean, any?, string?)
	if typeof(value) ~= "table" or getmetatable(value) ~= nil then return false, nil, "InvalidSettings" end
	for key in value do if key ~= "Levels" and key ~= "Enabled" then return false, nil, "InvalidSettings" end end
	if not exactKeys(value.Levels, Schema.LevelCategories) or not exactKeys(value.Enabled, Schema.EnabledCategories) then return false, nil, "InvalidSettings" end
	local result = { Levels = {}, Enabled = {} }
	for _, id in Schema.LevelCategories do
		local level = value.Levels[id]
		if typeof(level) ~= "number" or level ~= level or level < 0 or level > 1 then return false, nil, "InvalidSettings" end
		result.Levels[id] = level
	end
	for _, id in Schema.EnabledCategories do
		if typeof(value.Enabled[id]) ~= "boolean" then return false, nil, "InvalidSettings" end
		result.Enabled[id] = value.Enabled[id]
	end
	return true, result, nil
end

function Schema.reconcileData(value: any, defaults: any): (boolean, any?, string?)
	if typeof(value) ~= "table" or getmetatable(value) ~= nil then return false, nil, "InvalidSettings" end
	for key in value do if key ~= "Levels" and key ~= "Enabled" then return false, nil, "InvalidSettings" end end
	local result = { Levels = {}, Enabled = {} }
	for field, categories in { Levels = Schema.LevelCategories, Enabled = Schema.EnabledCategories } do
		local source = value[field]
		if source ~= nil and (typeof(source) ~= "table" or getmetatable(source) ~= nil) then return false, nil, "InvalidSettings" end
		for key in source or {} do
			local known = false
			for _, id in categories do if key == id then known = true; break end end
			if not known then return false, nil, "InvalidSettings" end
		end
		for _, id in categories do result[field][id] = if source and source[id] ~= nil then source[id] else defaults[field][id] end
	end
	return Schema.validateData(result)
end

return table.freeze(Schema)
