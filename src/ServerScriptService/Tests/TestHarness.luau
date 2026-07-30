--!strict

--[[
	Shared deterministic harness for manual Studio Play test runners.

	Each test receives a Scope as its optional first argument. Cleanup callbacks
	run in reverse registration order after pass, failure, or timeout.
]]

export type Scope = {
	Defer: (self: Scope, callback: () -> ()) -> (),
	Track: (self: Scope, value: any) -> any,
}

type TestEntry = {
	Name: string,
	Callback: (Scope) -> (),
}

local DEFAULT_TIMEOUT_SECONDS = 5

local TestHarness = {}

local function makeScope(): (Scope, { () -> () })
	local cleanups: { () -> () } = {}
	local scope = {} :: any

	function scope:Defer(callback: () -> ())
		assert(typeof(callback) == "function", "Cleanup callback must be a function")
		table.insert(cleanups, callback)
	end

	function scope:Track(value: any): any
		assert(value ~= nil, "Cannot track nil")
		local cleanup = if typeof(value) == "Instance"
			then function()
				value:Destroy()
			end
			elseif typeof(value) == "RBXScriptConnection"
			then function()
				value:Disconnect()
			end
			elseif typeof(value) == "table" and typeof(value.Destroy) == "function"
			then function()
				value:Destroy()
			end
			elseif typeof(value) == "table" and typeof(value.Stop) == "function"
			then function()
				value:Stop()
			end
			else nil
		assert(cleanup ~= nil, "Tracked value must be an Instance, connection, or expose Destroy/Stop")
		table.insert(cleanups, cleanup :: () -> ())
		return value
	end

	return scope, cleanups
end

local function runCleanups(cleanups: { () -> () }): { string }
	local failures = {}
	for index = #cleanups, 1, -1 do
		local ok, cleanupError = xpcall(cleanups[index], debug.traceback)
		if not ok then
			table.insert(failures, tostring(cleanupError))
		end
	end
	return failures
end

local function runOne(entry: TestEntry, timeoutSeconds: number): (boolean, string?)
	local scope, cleanups = makeScope()
	local completed = false
	local callbackOk = false
	local callbackError: any = nil
	local callbackThread = task.spawn(function()
		callbackOk, callbackError = xpcall(function()
			entry.Callback(scope)
		end, debug.traceback)
		completed = true
	end)

	local deadline = os.clock() + timeoutSeconds
	while not completed and os.clock() < deadline do
		task.wait()
	end

	local testError: string? = nil
	if not completed then
		task.cancel(callbackThread)
		testError = `timed out after {timeoutSeconds} second(s)`
	elseif not callbackOk then
		testError = tostring(callbackError)
	end

	local cleanupFailures = runCleanups(cleanups)
	if #cleanupFailures > 0 then
		local cleanupSummary = `cleanup failed:\n{table.concat(cleanupFailures, "\n")}`
		testError = if testError then `{testError}\n{cleanupSummary}` else cleanupSummary
	end

	return testError == nil, testError
end

function TestHarness.runAll(suiteName: string, tests: { TestEntry }, timeoutSeconds: number?)
	assert(typeof(suiteName) == "string" and suiteName ~= "", "Suite name required")
	local timeout = timeoutSeconds or DEFAULT_TIMEOUT_SECONDS
	assert(timeout > 0, "Test timeout must be positive")

	local passed = 0
	local failures = {}
	for _, entry in tests do
		local ok, testError = runOne(entry, timeout)
		if ok then
			passed += 1
		else
			table.insert(failures, `{entry.Name}: {testError}`)
			warn(`[{suiteName}] FAIL {entry.Name}: {testError}`)
		end
	end

	print(`[{suiteName}] passed={passed} failed={#failures} total={#tests}`)
	return {
		passed = passed,
		failed = #failures,
		failures = failures,
	}
end

return TestHarness
