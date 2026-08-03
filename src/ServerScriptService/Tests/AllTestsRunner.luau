--!strict

--[[
	Deterministic production-readiness gate for the isolated Studio test suites.

	The opt-in RealDataStoreSmokeTestRunner is intentionally excluded because it
	requires a dedicated published test place with API access enabled.
]]

local Tests = script.Parent

local suites = {
	{ Name = "LoggerTestRunner", Runner = require(Tests.LoggerTestRunner) },
	{ Name = "ResourceManagementTestRunner", Runner = require(Tests.ResourceManagementTestRunner) },
	{ Name = "AssetRegistryTestRunner", Runner = require(Tests.AssetRegistryTestRunner) },
	{ Name = "ContentPreloaderTestRunner", Runner = require(Tests.ContentPreloaderTestRunner) },
	{ Name = "ConfigCatalogTestRunner", Runner = require(Tests.ConfigCatalogTestRunner) },
	{ Name = "TeleportModuleTestRunner", Runner = require(Tests.TeleportModuleTestRunner) },
	{ Name = "SystemTestRunner", Runner = require(Tests.SystemTestRunner) },
	{ Name = "ProductionIntegrationTestRunner", Runner = require(Tests.ProductionIntegrationTestRunner) },
	{ Name = "ProductionReadinessTestRunner", Runner = require(Tests.ProductionReadinessTestRunner) },
}

local AllTestsRunner = {}

function AllTestsRunner.runAll()
	local passed = 0
	local failed = 0
	local failures = {}

	for _, suite in suites do
		local callOk, result = xpcall(function()
			return suite.Runner.runAll()
		end, debug.traceback)
		if not callOk then
			failed += 1
			table.insert(failures, `{suite.Name}: runner failed: {result}`)
			warn(`[AllTestsRunner] FAIL {suite.Name}: {result}`)
		elseif typeof(result) ~= "table"
			or typeof(result.passed) ~= "number"
			or typeof(result.failed) ~= "number"
		then
			failed += 1
			table.insert(failures, `{suite.Name}: invalid result`)
			warn(`[AllTestsRunner] FAIL {suite.Name}: invalid result`)
		else
			passed += result.passed
			failed += result.failed
			for _, failure in result.failures or {} do
				table.insert(failures, `{suite.Name}: {failure}`)
			end
		end
	end

	print(`[AllTestsRunner] passed={passed} failed={failed} suites={#suites}`)
	return {
		passed = passed,
		failed = failed,
		failures = failures,
		suites = #suites,
	}
end

return AllTestsRunner
