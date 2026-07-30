--!strict

--[[
	Manual Studio harness for the shared Logger contract.

	require(game.ServerScriptService.Tests.LoggerTestRunner).runAll()
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Logger = require(ReplicatedStorage.Shared.Util.Logger)
local TestHarness = require(script.Parent.TestHarness)

local LoggerTestRunner = {}

local function assertEqual(actual: any, expected: any, message: string?)
	if actual ~= expected then
		error(`{message or "assertEqual"}: expected={tostring(expected)} actual={tostring(actual)}`, 2)
	end
end

local function assertTrue(value: any, message: string)
	if not value then
		error(message, 2)
	end
end

local function makeSink()
	local printed: { string } = {}
	local warned: { string } = {}
	return {
		Print = function(line: string)
			table.insert(printed, line)
		end,
		Warn = function(line: string)
			table.insert(warned, line)
		end,
	}, printed, warned
end

function LoggerTestRunner.runAll()
	local tests = {}

	local function test(name: string, callback: () -> ())
		table.insert(tests, { Name = name, Callback = callback })
	end

	test("filters levels and uses stable severity channels", function()
		local sink, printed, warned = makeSink()
		local logger = Logger.new("Root", "info", sink)

		logger:Debug("debug_event")
		logger:Info("info_event", {
			B = "two",
			A = 1,
		})
		logger:Warn("warn_event")
		logger:Error("error_event")

		assertEqual(#printed, 1)
		assertEqual(printed[1], '[info] [Root] info_event A="1" B="two"')
		assertEqual(#warned, 2)
		assertEqual(warned[1], "[warn] [Root] warn_event")
		assertEqual(warned[2], "[error] [Root] error_event")
	end)

	test("child logger preserves level and sink", function()
		local sink, printed, warned = makeSink()
		local child = Logger.new("Root", "warn", sink):Child("Child")

		child:Info("suppressed")
		child:Warn("visible")

		assertEqual(#printed, 0)
		assertEqual(#warned, 1)
		assertEqual(warned[1], "[warn] [Root.Child] visible")
	end)

	test("escapes control characters into one line", function()
		local sink, _printed, warned = makeSink()
		local logger = Logger.new("Root\nInjected", "info", sink)

		logger:Warn("first\nsecond", {
			["Bad\nKey"] = "quote\" slash\\ return\r tab\t",
		})

		assertEqual(#warned, 1)
		assertTrue(string.find(warned[1], "\n", 1, true) == nil, "log output must remain on one line")
		assertTrue(
			string.find(warned[1], "[Root\\nInjected] first\\nsecond", 1, true) ~= nil,
			"scope and message were not escaped"
		)
		assertTrue(
			string.find(warned[1], 'Bad\\nKey="quote\\" slash\\\\ return\\r tab\\t"', 1, true) ~= nil,
			"field key or value was not escaped"
		)
	end)

	test("hostile values and sinks cannot make logging throw", function()
		local sink, _printed, warned = makeSink()
		local hostile = setmetatable({}, {
			__tostring = function()
				error("hostile tostring")
			end,
		})
		local logger = Logger.new("Root", "info", sink)

		local renderOk = pcall(function()
			logger:Error("failed_operation", {
				Value = hostile,
			})
		end)

		assertTrue(renderOk, "hostile field rendering must not escape Logger")
		assertEqual(#warned, 1)
		assertTrue(
			string.find(warned[1], '<unprintable:table>', 1, true) ~= nil,
			"hostile field must use a safe fallback"
		)

		assertTrue(pcall(function()
			logger:Error("malformed_fields", "not-a-table" :: any)
		end), "malformed fields must not escape Logger")
		assertEqual(warned[2], "[error] [Logger] log_format_failed")

		local failingLogger = Logger.new("Root", "info", {
			Print = function()
				error("sink failure")
			end,
			Warn = function()
				error("sink failure")
			end,
		})
		assertTrue(pcall(function()
			failingLogger:Info("still_safe")
			failingLogger:Error("still_safe")
		end), "sink failures must not escape Logger")
	end)

	test("bounds fields and complete log lines", function()
		local sink, _printed, warned = makeSink()
		local logger = Logger.new("Root", "info", sink)

		logger:Error(string.rep("m", 5_000), {
			Large = string.rep("v", 5_000),
		})

		assertEqual(#warned, 1)
		assertTrue(#warned[1] <= 4_096, "log line exceeded its byte limit")
		assertTrue(
			string.find(warned[1], "<truncated>", 1, true) ~= nil,
			"truncated log must include an explicit marker"
		)
	end)

	test("rejects invalid runtime configuration", function()
		assertTrue(not pcall(function()
			Logger.new("Root", "verbose" :: any)
		end), "unknown min level must fail at construction")

		assertTrue(not pcall(function()
			Logger.new("Root", "info", {} :: any)
		end), "incomplete sink must fail at construction")
	end)

	return TestHarness.runAll("LoggerTestRunner", tests)
end

return LoggerTestRunner
