--!strict

export type LogLevel = "debug" | "info" | "warn" | "error"

export type LogFields = { [string]: any }

export type LogSink = {
	Print: (line: string) -> (),
	Warn: (line: string) -> (),
}

export type Logger = {
	Debug: (self: Logger, message: string, fields: LogFields?) -> (),
	Info: (self: Logger, message: string, fields: LogFields?) -> (),
	Warn: (self: Logger, message: string, fields: LogFields?) -> (),
	Error: (self: Logger, message: string, fields: LogFields?) -> (),
	Child: (self: Logger, scope: string) -> Logger,
}

local LEVEL_RANK: { [LogLevel]: number } = {
	debug = 10,
	info = 20,
	warn = 30,
	error = 40,
}

local MAX_SCOPE_LENGTH = 128
local MAX_MESSAGE_LENGTH = 1_024
local MAX_FIELD_KEY_LENGTH = 64
local MAX_FIELD_VALUE_LENGTH = 512
local MAX_LINE_LENGTH = 4_096
local TRUNCATED_SUFFIX = "<truncated>"

local DEFAULT_SINK: LogSink = {
	Print = function(line: string)
		print(line)
	end,
	Warn = function(line: string)
		warn(line)
	end,
}

local Logger = {}
Logger.__index = Logger

local function truncate(value: string, maxLength: number): string
	if #value <= maxLength then
		return value
	end

	local prefixLength = math.max(0, maxLength - #TRUNCATED_SUFFIX)
	return string.sub(value, 1, prefixLength) .. string.sub(TRUNCATED_SUFFIX, 1, maxLength)
end

local function escape(value: string): string
	local escaped = string.gsub(value, "\\", "\\\\")
	escaped = string.gsub(escaped, '"', '\\"')
	escaped = string.gsub(escaped, "\n", "\\n")
	escaped = string.gsub(escaped, "\r", "\\r")
	escaped = string.gsub(escaped, "\t", "\\t")
	escaped = string.gsub(escaped, "%c", function(character: string): string
		return string.format("\\x%02X", string.byte(character))
	end)
	return escaped
end

local function safeToString(value: any): string
	if typeof(value) == "string" then
		return value
	end

	local ok, rendered = pcall(function()
		return tostring(value)
	end)
	if ok then
		return rendered
	end
	return `<unprintable:{typeof(value)}>`
end

local function normalize(value: any, maxLength: number): string
	return truncate(escape(safeToString(value)), maxLength)
end

local function serializeFields(fields: LogFields?): string
	if fields == nil then
		return ""
	end

	local parts: { string } = {}
	for key, value in fields do
		local renderedKey = normalize(key, MAX_FIELD_KEY_LENGTH)
		local renderedValue = normalize(value, MAX_FIELD_VALUE_LENGTH)
		table.insert(parts, `{renderedKey}="{renderedValue}"`)
	end
	table.sort(parts)
	if #parts == 0 then
		return ""
	end
	return " " .. table.concat(parts, " ")
end

function Logger.new(scope: string, minLevel: LogLevel?, sink: LogSink?): Logger
	local resolvedMinLevel = minLevel or "info"
	assert(LEVEL_RANK[resolvedMinLevel] ~= nil, `Unknown log level: {tostring(resolvedMinLevel)}`)

	local resolvedSink = sink or DEFAULT_SINK
	assert(
		typeof(resolvedSink.Print) == "function" and typeof(resolvedSink.Warn) == "function",
		"Logger sink must define Print and Warn"
	)

	local self = setmetatable({
		_scope = scope,
		_minLevel = resolvedMinLevel,
		_sink = resolvedSink,
	}, Logger)
	return self :: any
end

function Logger:Child(scope: string): Logger
	return Logger.new(`{self._scope}.{scope}`, self._minLevel, self._sink)
end

function Logger:_emit(level: LogLevel, message: string, fields: LogFields?)
	if LEVEL_RANK[level] < LEVEL_RANK[self._minLevel] then
		return
	end

	local formatted, line = pcall(function()
		local scope = normalize(self._scope, MAX_SCOPE_LENGTH)
		local normalizedMessage = normalize(message, MAX_MESSAGE_LENGTH)
		return truncate(`[{level}] [{scope}] {normalizedMessage}{serializeFields(fields)}`, MAX_LINE_LENGTH)
	end)
	if not formatted then
		line = `[{level}] [Logger] log_format_failed`
	end

	local writer = if level == "warn" or level == "error" then self._sink.Warn else self._sink.Print
	local written = pcall(writer, line)
	if not written and self._sink ~= DEFAULT_SINK then
		pcall(DEFAULT_SINK.Warn, "[error] [Logger] sink_write_failed")
	end
end

function Logger:Debug(message: string, fields: LogFields?)
	self:_emit("debug", message, fields)
end

function Logger:Info(message: string, fields: LogFields?)
	self:_emit("info", message, fields)
end

function Logger:Warn(message: string, fields: LogFields?)
	self:_emit("warn", message, fields)
end

function Logger:Error(message: string, fields: LogFields?)
	self:_emit("error", message, fields)
end

return Logger
