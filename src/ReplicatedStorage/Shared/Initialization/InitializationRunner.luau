--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local Logger = require(ReplicatedStorage.Shared.Util.Logger)

export type InitializationRunner = {
	Initialize: (self: InitializationRunner, context: any) -> any,
	IsInitialized: (self: InitializationRunner) -> boolean,
	GetState: (self: InitializationRunner) -> string,
	Initialized: any,
}

local InitializationRunner = {}
InitializationRunner.__index = InitializationRunner

local DEFAULT_WATCHDOG_SECONDS = 30

local function validateManifest(commands: { any })
	local indexes: { [string]: number } = {}

	for index, command in commands do
		assert(typeof(command) == "table", `Initialization command at index {index} must be a table`)
		assert(typeof(command.Id) == "string" and command.Id ~= "", `Initialization command at index {index} has no Id`)
		assert(typeof(command.Initialize) == "function", `Initialization command '{command.Id}' has no Initialize method`)
		assert(indexes[command.Id] == nil, `Duplicate initialization command '{command.Id}'`)
		indexes[command.Id] = index
	end

	for index, command in commands do
		local dependencies = command.DependsOn or {}
		assert(typeof(dependencies) == "table", `DependsOn of '{command.Id}' must be a table`)
		for _, dependencyId in dependencies do
			assert(typeof(dependencyId) == "string", `Dependency of '{command.Id}' must be a string`)
			local dependencyIndex = indexes[dependencyId]
			assert(dependencyIndex ~= nil, `Initialization command '{command.Id}' depends on missing '{dependencyId}'`)
			assert(
				(dependencyIndex :: number) < index,
				`Initialization command '{command.Id}' must be placed after dependency '{dependencyId}'`
			)
		end
	end
end

function InitializationRunner.new(commands: { any }, options: {
	Logger: any?,
	WatchdogSeconds: number?,
}?): InitializationRunner
	validateManifest(commands)

	local self = setmetatable({
		_commands = table.clone(commands),
		_logger = if options and options.Logger then options.Logger else Logger.new("Initialization", "info"),
		_watchdogSeconds = if options and options.WatchdogSeconds
			then options.WatchdogSeconds
			else DEFAULT_WATCHDOG_SECONDS,
		_state = "Idle",
		_result = nil :: any,
		_completion = Signal.new(),
		Initialized = Signal.new(),
	}, InitializationRunner)

	return self :: any
end

function InitializationRunner:GetState(): string
	return self._state
end

function InitializationRunner:IsInitialized(): boolean
	return self._state == "Initialized"
end

function InitializationRunner:_waitForResult()
	if self._state ~= "Running" then
		return self._result
	end
	self._completion:Wait()
	return self._result
end

function InitializationRunner:Initialize(context: any)
	if self._state == "Running" then
		return self:_waitForResult()
	end
	if self._state == "Initialized" or self._state == "Failed" then
		return self._result
	end

	self._state = "Running"

	for _, command in self._commands do
		local completed = false
		local startedAt = os.clock()

		task.delay(self._watchdogSeconds, function()
			if completed then
				return
			end
			self._logger:Error("command_watchdog_timeout", {
				CommandId = command.Id,
				ElapsedSeconds = self._watchdogSeconds,
			})
		end)

		self._logger:Info("command_started", {
			CommandId = command.Id,
		})

		local ok, err = xpcall(function()
			command:Initialize(context)
		end, debug.traceback)
		completed = true

		if not ok then
			self._state = "Failed"
			self._result = {
				Ok = false,
				CommandId = command.Id,
				Error = tostring(err),
			}
			self._logger:Error("command_failed", {
				CommandId = command.Id,
				Error = tostring(err),
			})
			self._completion:Fire(self._result)
			return self._result
		end

		self._logger:Info("command_completed", {
			CommandId = command.Id,
			ElapsedSeconds = os.clock() - startedAt,
		})
	end

	self._state = "Initialized"
	self._result = { Ok = true }
	self._completion:Fire(self._result)
	self.Initialized:Fire()
	return self._result
end

return InitializationRunner
