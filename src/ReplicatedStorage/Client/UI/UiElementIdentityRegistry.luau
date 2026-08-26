--!strict

export type UiError = { Code: string }
export type UiVoidResult = { Kind: "Success" } | { Kind: "Error", Error: UiError }
export type Claim = { UIElementId: string, Owner: any }
export type Context = {
	ClaimSubtree: (self: Context, claims: { Claim }) -> UiVoidResult,
	ReleaseSubtree: (self: Context, claims: { Claim }) -> UiVoidResult,
	DeliverToRoot: (self: Context, event: any) -> UiVoidResult,
}

local MAX_COMPONENT_BYTES = 256
local MAX_ID_BYTES = 544
local Registry = {}
Registry.__index = Registry

local function success(): UiVoidResult
	return { Kind = "Success" }
end

local function failure(code: string): UiVoidResult
	return { Kind = "Error", Error = { Code = code } }
end

local function validId(value: any): boolean
	return typeof(value) == "string" and value ~= "" and #value <= MAX_ID_BYTES
end

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

function Registry.MakeRuntimeId(stableHierarchyPath: string, stableEntityKey: string): (string?, UiError?)
	if typeof(stableHierarchyPath) ~= "string"
		or typeof(stableEntityKey) ~= "string"
		or stableHierarchyPath == ""
		or stableEntityKey == ""
		or #stableHierarchyPath > MAX_COMPONENT_BYTES
		or #stableEntityKey > MAX_COMPONENT_BYTES
	then
		return nil, { Code = "InvalidUIElementId" }
	end
	local id = `ui.runtime/{#stableHierarchyPath}:{stableHierarchyPath}/{#stableEntityKey}:{stableEntityKey}`
	if #id > MAX_ID_BYTES then
		return nil, { Code = "InvalidUIElementId" }
	end
	return id, nil
end

function Registry.new(deliverToRoot: (event: any) -> UiVoidResult)
	local self = setmetatable({
		_owners = {} :: { [string]: any },
		_destroyed = false,
	}, Registry)
	local registry = self
	local context: any = {}

	function context:ClaimSubtree(claims: { Claim }): UiVoidResult
		if registry._destroyed or not isDenseSequence(claims) then
			return failure("InvalidUIElementId")
		end
		local staged = {}
		for _, claim in claims do
			if typeof(claim) ~= "table" or not validId(claim.UIElementId) or claim.Owner == nil then
				return failure("InvalidUIElementId")
			end
			if staged[claim.UIElementId] ~= nil then
				return failure("DuplicateUIElementId")
			end
			local existing = registry._owners[claim.UIElementId]
			if existing ~= nil and existing ~= claim.Owner then
				return failure("DuplicateUIElementId")
			end
			staged[claim.UIElementId] = claim.Owner
		end
		for id, owner in staged do
			registry._owners[id] = owner
		end
		return success()
	end

	function context:ReleaseSubtree(claims: { Claim }): UiVoidResult
		if not isDenseSequence(claims) then
			return failure("InvalidUIElementId")
		end
		for _, claim in claims do
			if typeof(claim) ~= "table" or not validId(claim.UIElementId) or claim.Owner == nil then
				return failure("InvalidUIElementId")
			end
		end
		for _, claim in claims do
			if registry._owners[claim.UIElementId] == claim.Owner then
				registry._owners[claim.UIElementId] = nil
			end
		end
		return success()
	end

	function context:DeliverToRoot(event: any): UiVoidResult
		if registry._destroyed then
			return failure("CleanupFailed")
		end
		if typeof(event) ~= "table"
			or typeof(event.UIElementId) ~= "string"
			or registry._owners[event.UIElementId] == nil
		then
			return failure("InvalidUIElementId")
		end
		return deliverToRoot(event)
	end

	self._context = table.freeze(context)
	return self
end

function Registry:GetContext(): Context
	return self._context
end

function Registry:IsOwnedBy(id: string, owner: any): boolean
	return self._owners[id] == owner
end

function Registry:Destroy()
	if self._destroyed then
		return
	end
	self._destroyed = true
	table.clear(self._owners)
end

return Registry
