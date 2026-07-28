--!strict

export type LogLevel = "debug" | "info" | "warn" | "error"

export type LogFields = { [string]: any }

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

local Logger = {}
Logger.__index = Logger

local function serializeFields(fields: LogFields?): string
	if fields == nil then
		return ""
	end

	local parts = {}
	for key, value in fields do
		local rendered = if typeof(value) == "string" then value else tostring(value)
		table.insert(parts, `{key}={rendered}`)
	end
	table.sort(parts)
	if #parts == 0 then
		return ""
	end
	return " " .. table.concat(parts, " ")
end

function Logger.new(scope: string, minLevel: LogLevel?): Logger
	local self = setmetatable({
		_scope = scope,
		_minLevel = minLevel or "info",
	}, Logger)
	return self :: any
end

function Logger:Child(scope: string): Logger
	return Logger.new(`{self._scope}.{scope}`, self._minLevel)
end

function Logger:_emit(level: LogLevel, message: string, fields: LogFields?)
	if LEVEL_RANK[level] < LEVEL_RANK[self._minLevel] then
		return
	end

	local line = `[{level}] [{self._scope}] {message}{serializeFields(fields)}`
	if level == "error" then
		error(line, 0)
	elseif level == "warn" then
		warn(line)
	else
		print(line)
	end
end

function Logger:Debug(message: string, fields: LogFields?)
	self:_emit("debug", message, fields)
end

function Logger:Info(message: string, fields: LogFields?)
	self:_emit("info", message, fields)
end

function Logger:Warn(message: string, fields: LogFields?)
	-- Avoid throwing; use warn channel.
	if LEVEL_RANK.warn < LEVEL_RANK[self._minLevel] then
		return
	end
	warn(`[{self._scope}] {message}{serializeFields(fields)}`)
end

function Logger:Error(message: string, fields: LogFields?)
	-- Log without throwing so callers can decide policy.
	warn(`[{self._scope}] ERROR {message}{serializeFields(fields)}`)
end

return Logger
