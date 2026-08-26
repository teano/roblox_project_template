--!strict

local Guard = {}

export type Outcome = {
	Kind: "Success" | "Error" | "Yielded",
	Value: any?,
	Trace: string?,
}

local function bounded(value: any): string
	local rendered = tostring(value)
	if #rendered > 1024 then
		return string.sub(rendered, 1, 1024)
	end
	return rendered
end

function Guard.call(phase: string, callback: () -> any): Outcome
	local value: any = nil
	local trace: string? = nil
	local thread = coroutine.create(function()
		local ok, result = xpcall(callback, debug.traceback)
		if ok then
			value = result
		else
			trace = bounded(`{phase}: {result}`)
		end
	end)
	local resumed, resumeError = coroutine.resume(thread)
	if not resumed then
		return { Kind = "Error", Trace = bounded(`{phase}: {resumeError}`) }
	end
	if coroutine.status(thread) ~= "dead" then
		local closed, closeError = coroutine.close(thread)
		return {
			Kind = "Yielded",
			Trace = bounded(if closed then `{phase}: Yielded` else `{phase}: Yielded; close failed: {closeError}`),
		}
	end
	if trace ~= nil then
		return { Kind = "Error", Trace = trace }
	end
	return { Kind = "Success", Value = value }
end

return table.freeze(Guard)
