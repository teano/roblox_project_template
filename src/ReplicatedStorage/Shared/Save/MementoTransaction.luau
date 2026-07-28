--!strict

--[[
	Applies an already validated set of provider mementos as one runtime transaction.
	Provider Stop must be idempotent and safe after SetMemento even when Run did not finish.
]]

export type TransactionResult = {
	Ok: boolean,
	RolledBack: boolean,
	MutationStarted: boolean,
	Error: string?,
	RollbackError: string?,
}

local MementoTransaction = {}

local function callAllReverse(providers: { any }, callback: (any) -> ())
	local errors = {}
	for index = #providers, 1, -1 do
		local ok, callbackError = xpcall(function()
			callback(providers[index])
		end, debug.traceback)
		if not ok then
			table.insert(errors, tostring(callbackError))
		end
	end
	if #errors > 0 then
		error(table.concat(errors, "\n---\n"))
	end
end

local function install(
	providers: { any },
	values: { [any]: any },
	setMemento: (any, any) -> (),
	run: (any) -> ()
)
	for _, provider in providers do
		setMemento(provider, values[provider])
	end
	for _, provider in providers do
		run(provider)
	end
end

function MementoTransaction.apply(config: {
	Providers: { any },
	TargetValues: { [any]: any },
	PreviousValues: { [any]: any }?,
	WasRunning: boolean,
	Capture: (any) -> any,
	Stop: (any) -> (),
	SetMemento: (any, any) -> (),
	Run: (any) -> (),
}): TransactionResult
	local previousValues = config.PreviousValues or {}
	if config.WasRunning then
		if config.PreviousValues == nil then
			local captured, captureError = xpcall(function()
				for _, provider in config.Providers do
					previousValues[provider] = config.Capture(provider)
				end
			end, debug.traceback)
			if not captured then
				return {
					Ok = false,
					RolledBack = false,
					MutationStarted = false,
					Error = `Could not capture current runtime before apply:\n{tostring(captureError)}`,
				}
			end
		end
	end

	local applied, applyError = xpcall(function()
		if config.WasRunning then
			callAllReverse(config.Providers, config.Stop)
		end
		install(config.Providers, config.TargetValues, config.SetMemento, config.Run)
	end, debug.traceback)
	if applied then
		return {
			Ok = true,
			RolledBack = false,
			MutationStarted = true,
		}
	end

	-- Clean partially installed target state before trying to restore the old snapshot.
	local cleanupOk, cleanupError = xpcall(function()
		callAllReverse(config.Providers, config.Stop)
	end, debug.traceback)

	if not config.WasRunning then
		return {
			Ok = false,
			RolledBack = false,
			MutationStarted = true,
			Error = tostring(applyError),
			RollbackError = if cleanupOk then nil else tostring(cleanupError),
		}
	end

	local restored, restoreError = xpcall(function()
		install(config.Providers, previousValues, config.SetMemento, config.Run)
	end, debug.traceback)
	if restored and cleanupOk then
		return {
			Ok = false,
			RolledBack = true,
			MutationStarted = true,
			Error = tostring(applyError),
		}
	end

	return {
		Ok = false,
		RolledBack = false,
		MutationStarted = true,
		Error = tostring(applyError),
		RollbackError = `{if cleanupOk then "" else tostring(cleanupError)}`
			.. (if not cleanupOk and not restored then "\n---\n" else "")
			.. (if restored then "" else tostring(restoreError)),
	}
end

return MementoTransaction
