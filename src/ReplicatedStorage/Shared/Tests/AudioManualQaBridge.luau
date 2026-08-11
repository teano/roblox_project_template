--!strict

--[[
	Studio-only, VM-local invocation bridge for the collaborative Audio QA
	drivers. The bridge never transports data across the server/client boundary:
	each side installs its own BindableFunction from its production bootstrap VM.
]]

local RunService = game:GetService("RunService")

local Bridge = {}

local MAX_DEPTH = 10
local MAX_NODES = 4096
local MAX_STRING_BYTES = 4096
local MAX_COMMAND_BYTES = 64
local SCHEMA_VERSION = 1

local NAMES = table.freeze({
	Server = "AudioManualQaServerBridge",
	Client = "AudioManualQaClientBridge",
})

local WHITELISTS = table.freeze({
	Server = table.freeze({ "Start", "Execute", "Snapshot", "RecordScenario", "Export", "Cleanup" }),
	Client = table.freeze({ "Start", "Execute", "Snapshot", "Cleanup" }),
})

local function whitelistSet(side: string): { [string]: boolean }
	local result = {}
	for _, command in WHITELISTS[side] do result[command] = true end
	return result
end

local function copySerializable(value: any, seen: { [any]: boolean }, state: any, depth: number): any
	assert(depth <= MAX_DEPTH, "Audio QA bridge payload exceeds maximum depth")
	state.Nodes += 1
	assert(state.Nodes <= MAX_NODES, "Audio QA bridge payload exceeds maximum nodes")

	local kind = typeof(value)
	if value == nil or kind == "boolean" then return value end
	if kind == "number" then
		assert(value == value and value ~= math.huge and value ~= -math.huge,
			"Audio QA bridge payload contains a non-finite number")
		return value
	end
	if kind == "string" then
		assert(#value <= MAX_STRING_BYTES, "Audio QA bridge payload contains an oversized string")
		return value
	end
	assert(kind == "table", `Audio QA bridge payload contains unsupported type '{kind}'`)
	assert(getmetatable(value) == nil, "Audio QA bridge payload tables must not have metatables")
	assert(not seen[value], "Audio QA bridge payload contains a cycle")
	seen[value] = true

	local result = {}
	local arrayCount = 0
	local dictionaryCount = 0
	local maximumIndex = 0
	local key, child = next(value)
	while key ~= nil do
		local keyKind = typeof(key)
		if keyKind == "string" then
			assert(#key <= MAX_STRING_BYTES, "Audio QA bridge payload contains an oversized key")
			dictionaryCount += 1
		elseif keyKind == "number" then
			assert(key == math.floor(key) and key >= 1, "Audio QA bridge array keys must be positive integers")
			arrayCount += 1
			maximumIndex = math.max(maximumIndex, key)
		else
			error(`Audio QA bridge payload contains unsupported key type '{keyKind}'`)
		end
		result[key] = copySerializable(child, seen, state, depth + 1)
		key, child = next(value, key)
	end
	assert(arrayCount == 0 or dictionaryCount == 0, "Audio QA bridge payload cannot mix array and dictionary keys")
	assert(arrayCount == 0 or arrayCount == maximumIndex, "Audio QA bridge arrays must be dense")
	seen[value] = nil
	return result
end

local function sanitize(value: any): any
	return copySerializable(value, {}, { Nodes = 0 }, 0)
end

local function failure(errorCode: string, message: string?): any
	return {
		Ok = false,
		ErrorCode = errorCode,
		Message = if message == nil then nil else string.sub(message, 1, 512),
	}
end

function Bridge.ShouldInstall(isStudio: boolean): boolean
	return isStudio == true
end

function Bridge.Install(options: any): any?
	assert(typeof(options) == "table", "Audio QA bridge options must be a table")
	-- The optional gate only narrows the real engine gate for deterministic tests.
	-- It can never turn a non-Studio runtime into an allowed runtime.
	if not Bridge.ShouldInstall(RunService:IsStudio()) or options.Enabled == false then return nil end

	local parent = options.Parent
	local side = options.Side
	local commands = options.Commands
	assert(typeof(parent) == "Instance", "Audio QA bridge Parent must be an Instance")
	assert(side == "Server" or side == "Client", "Audio QA bridge Side must be Server or Client")
	local name = NAMES[side]
	local expectedParentClass = if side == "Server" then "Script" else "LocalScript"
	assert(parent.Name == "Bootstrap" and parent.ClassName == expectedParentClass,
		`Audio QA {side} bridge must be parented to the existing {expectedParentClass} named Bootstrap`)
	assert(typeof(commands) == "table", "Audio QA bridge Commands must be a table")
	assert(parent:FindFirstChild(name) == nil, `Audio QA bridge '{name}' already exists`)

	local dispatchers = {}
	local commandCount = 0
	local expectedCommands = whitelistSet(side)
	local command, callback = next(commands)
	while command ~= nil do
		assert(typeof(command) == "string" and command ~= "" and #command <= MAX_COMMAND_BYTES,
			"Audio QA bridge command names must be bounded non-empty strings")
		assert(expectedCommands[command] == true, `Audio QA {side} bridge command '{command}' is not whitelisted`)
		assert(typeof(callback) == "function", `Audio QA bridge command '{command}' must be a function`)
		dispatchers[command] = callback
		commandCount += 1
		command, callback = next(commands, command)
	end
	assert(commandCount == #WHITELISTS[side], `Audio QA {side} bridge command whitelist is incomplete`)
	local expectedCommand = next(expectedCommands)
	while expectedCommand ~= nil do
		assert(dispatchers[expectedCommand] ~= nil,
			`Audio QA {side} bridge is missing command '{expectedCommand}'`)
		expectedCommand = next(expectedCommands, expectedCommand)
	end

	local bindable = Instance.new("BindableFunction")
	bindable.Name = name
	bindable.Archivable = false
	bindable:SetAttribute("AudioManualQaBridgeSchema", SCHEMA_VERSION)
	bindable.OnInvoke = function(command: any, arguments: any): any
		if typeof(command) ~= "string" or command == "" or #command > MAX_COMMAND_BYTES then
			return failure("InvalidCommand", "Command must be a bounded non-empty string")
		end
		local dispatcher = dispatchers[command]
		if dispatcher == nil then return failure("UnknownCommand", `Unknown command '{command}'`) end
		local argumentsOk, safeArguments = pcall(sanitize, arguments)
		if not argumentsOk then return failure("InvalidArguments", tostring(safeArguments)) end
		local dispatchOk, result = xpcall(function()
			return dispatcher(safeArguments)
		end, debug.traceback)
		if not dispatchOk then return failure("CommandFailed", tostring(result)) end
		local resultOk, safeResult = pcall(sanitize, result)
		if not resultOk then return failure("InvalidResult", tostring(safeResult)) end
		return { Ok = true, Result = safeResult }
	end
	bindable.Parent = parent

	local destroyed = false
	local owner = {}
	function owner:Destroy()
		if destroyed then return end
		destroyed = true
		bindable.OnInvoke = nil
		table.clear(dispatchers)
		bindable:Destroy()
	end
	return table.freeze(owner)
end

function Bridge.Invoke(parent: Instance, side: string, command: string, arguments: any): any
	assert(RunService:IsStudio(), "Audio QA bridge invocation is Studio-only")
	assert(side == "Server" or side == "Client", "Audio QA bridge Side must be Server or Client")
	local name = NAMES[side]
	assert(whitelistSet(side)[command] == true, `Unknown Audio QA {side} command '{command}'`)
	local bindable = parent:FindFirstChild(name)
	assert(bindable ~= nil and bindable:IsA("BindableFunction"), `Audio QA bridge '{name}' is unavailable`)
	assert(bindable:GetAttribute("AudioManualQaBridgeSchema") == SCHEMA_VERSION,
		`Audio QA bridge '{name}' has an incompatible schema`)
	local response = bindable:Invoke(command, sanitize(arguments))
	assert(typeof(response) == "table" and typeof(response.Ok) == "boolean",
		`Audio QA bridge '{name}' returned a malformed response`)
	assert(response.Ok,
		`Audio QA bridge command '{command}' failed: {tostring(response.ErrorCode)}: {tostring(response.Message)}`)
	return response.Result
end

Bridge.Names = NAMES
Bridge.Whitelists = WHITELISTS
Bridge.SchemaVersion = SCHEMA_VERSION

return table.freeze(Bridge)
