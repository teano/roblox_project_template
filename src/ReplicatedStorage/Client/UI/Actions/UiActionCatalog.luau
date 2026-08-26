--!strict

export type ActionEntry = { Name: string, Id: string }
export type Catalog = {
	Definitions: { ActionEntry },
	ByName: { [string]: ActionEntry },
	ById: { [string]: ActionEntry },
}

local UiActionCatalog = {}

local function isDenseSequence(value: any): boolean
	if typeof(value) ~= "table" then
		return false
	end
	local count = 0
	local maximum = 0
	for key in value do
		if typeof(key) ~= "number" or key < 1 or key ~= math.floor(key) then
			return false
		end
		count += 1
		maximum = math.max(maximum, key)
	end
	return count == maximum
end

local function validId(id: any, namespace: string): boolean
	return typeof(id) == "string"
		and #id > #namespace + 1
		and #id <= 256
		and string.match(id, "^" .. namespace .. "%.[a-z0-9]+[a-z0-9%.]*$") ~= nil
		and string.match(id, "[a-z0-9]$") ~= nil
		and string.find(id, "%.%.", 1, false) == nil
end

function UiActionCatalog.compile(templateEntries: { ActionEntry }, derivedEntries: { ActionEntry }?): (Catalog?, string?)
	local sources = {
		{ Entries = templateEntries, Namespace = "ui" },
		{ Entries = derivedEntries or {}, Namespace = "game" },
	}
	local definitions = {}
	local byName = {}
	local byId = {}

	for _, source in sources do
		if not isDenseSequence(source.Entries) then
			return nil, "ActionCatalogMalformed"
		end
		for _, entry in source.Entries do
			if typeof(entry) ~= "table"
				or typeof(entry.Name) ~= "string"
				or entry.Name == ""
				or not validId(entry.Id, source.Namespace)
				or byName[entry.Name] ~= nil
				or byId[entry.Id] ~= nil
			then
				return nil, "ActionCatalogMalformed"
			end
			local frozen = if table.isfrozen(entry) then entry else table.freeze(table.clone(entry))
			byName[entry.Name] = frozen
			byId[entry.Id] = frozen
			table.insert(definitions, frozen)
		end
	end

	return table.freeze({
		Definitions = table.freeze(definitions),
		ByName = table.freeze(byName),
		ById = table.freeze(byId),
	}), nil
end

return table.freeze(UiActionCatalog)
