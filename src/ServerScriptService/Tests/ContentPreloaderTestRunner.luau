--!strict

--[[
	Manual Studio harness for the project content-preloading contract.

	require(game.ServerScriptService.Tests.ContentPreloaderTestRunner).runAll()
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AssetRegistry = require(ReplicatedStorage.Shared.Assets.AssetRegistry)
local ContentPreloader = require(ReplicatedStorage.Shared.ContentPreloading.ContentPreloader)
local StartupContentPreloadCommand =
	require(ReplicatedStorage.Client.Initialization.Commands.StartupContentPreloadCommand)

local ContentPreloaderTestRunner = {}

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

local function assertErrorContains(callback: () -> (), expected: string)
	local ok, testError = pcall(callback)
	assertEqual(ok, false, `Expected error containing '{expected}'`)
	assertTrue(string.find(tostring(testError), expected, 1, true) ~= nil, `Error did not contain '{expected}'`)
end

local function makeLogger()
	return {
		Info = function() end,
		Warn = function() end,
	}
end

local function withRegistry(callback: (any, Folder, Folder) -> ())
	local sharedRoot = Instance.new("Folder")
	sharedRoot.Name = "SharedContentPreloaderTestRoot"
	local clientRoot = Instance.new("Folder")
	clientRoot.Name = "ClientContentPreloaderTestRoot"

	local registry = AssetRegistry.new({
		{ Namespace = "Shared", Root = sharedRoot },
		{ Namespace = "Client", Root = clientRoot },
	})

	local ok, testError = xpcall(function()
		callback(registry, sharedRoot, clientRoot)
	end, debug.traceback)

	sharedRoot:Destroy()
	clientRoot:Destroy()
	if not ok then
		error(testError, 0)
	end
end

function ContentPreloaderTestRunner.runAll()
	local tests = {}

	local function test(name: string, callback: () -> ())
		table.insert(tests, { Name = name, Callback = callback })
	end

	test("preloads catalog queries and caches named results", function()
		withRegistry(function(registry, sharedRoot, _clientRoot)
			local startupSound = Instance.new("Sound")
			startupSound.Name = "StartupSound"
			startupSound:SetAttribute("AssetKey", "startup.sound")
			startupSound:AddTag("Preload")
			startupSound.Parent = sharedRoot

			local deferredSound = Instance.new("Sound")
			deferredSound.Name = "DeferredSound"
			deferredSound:SetAttribute("PreloadGroup", "Deferred")
			deferredSound.Parent = sharedRoot
			registry:Initialize()

			local calls = 0
			local receivedTargets = nil
			local provider = {
				PreloadAsync = function(_self, targets, callback)
					calls += 1
					receivedTargets = table.clone(targets)
					callback("rbxassetid://startup", Enum.AssetFetchStatus.Success)
				end,
			}
			local preloader = ContentPreloader.new({
				Assets = registry,
				ContentProvider = provider,
				Logger = makeLogger(),
			})

			local progressEvents = 0
			preloader.Progress:Connect(function(progress)
				progressEvents += 1
				assertEqual(progress.RequestId, "Startup")
			end)

			local options = {
				RequestId = "Startup",
				FailurePolicy = "Warn",
			}
			local first = preloader:PreloadQuery({
				Tags = { "Preload" },
			}, options)
			local second = preloader:PreloadQuery({
				Tags = { "Preload" },
			}, options)

			assertEqual(first, second, "named preload requests must reuse their immutable result")
			assertEqual(calls, 1, "cached request must not call ContentProvider again")
			assertEqual(#receivedTargets, 1)
			assertEqual(receivedTargets[1], startupSound)
			assertEqual(first.RequestedTargets, 1)
			assertEqual(first.Loaded, 1)
			assertEqual(first.Failed, 0)
			assertEqual(first.RequestedCatalogPaths[1], "Shared/StartupSound")
			assertTrue(table.isfrozen(first), "preload result must be immutable")
			assertTrue(table.isfrozen(first.RequestedCatalogPaths), "catalog paths must be immutable")
			assertTrue(table.isfrozen(first.Failures), "failures must be immutable")
			assertEqual(progressEvents, 1)
			assertEqual(preloader:GetRequestResult("Startup"), first)
		end)
	end)

	test("supports keys, raw content IDs and duplicate normalization", function()
		withRegistry(function(registry, _sharedRoot, clientRoot)
			local image = Instance.new("ImageLabel")
			image.Name = "Menu"
			image:SetAttribute("AssetKey", "ui.menu")
			image.Parent = clientRoot
			registry:Initialize()

			local calls = {}
			local provider = {
				PreloadAsync = function(_self, targets, callback)
					table.insert(calls, table.clone(targets))
					for index, _target in targets do
						callback(`rbxassetid://{index}`, Enum.AssetFetchStatus.Success)
					end
				end,
			}
			local preloader = ContentPreloader.new({
				Assets = registry,
				ContentProvider = provider,
				Logger = makeLogger(),
			})

			local keyed = preloader:PreloadByKeys({ "ui.menu" })
			assertEqual(keyed.RequestedCatalogPaths[1], "Client/Menu")

			local raw = preloader:Preload({
				"rbxassetid://100",
				"rbxassetid://100",
				"rbxassetid://200",
			})
			assertEqual(raw.RequestedTargets, 2, "duplicate raw targets must be removed")
			assertEqual(#calls, 2)
			assertEqual(#calls[2], 2)
		end)
	end)

	test("reports failures and enforces named request identity", function()
		withRegistry(function(registry, sharedRoot, _clientRoot)
			local firstSound = Instance.new("Sound")
			firstSound.Name = "First"
			firstSound.Parent = sharedRoot
			local secondSound = Instance.new("Sound")
			secondSound.Name = "Second"
			secondSound.Parent = sharedRoot
			registry:Initialize()

			local calls = 0
			local provider = {
				PreloadAsync = function(_self, _targets, callback)
					calls += 1
					callback("rbxassetid://failed", Enum.AssetFetchStatus.Failure)
				end,
			}
			local preloader = ContentPreloader.new({
				Assets = registry,
				ContentProvider = provider,
				Logger = makeLogger(),
			})

			local warned = preloader:Preload({ firstSound }, {
				RequestId = "Warned",
				FailurePolicy = "Warn",
			})
			assertEqual(warned.Failed, 1)
			assertEqual(warned.Failures[1].Status, "Failure")

			assertErrorContains(function()
				preloader:Preload({ firstSound }, {
					RequestId = "Strict",
					FailurePolicy = "Fail",
				})
			end, "failed for 1 content item")
			assertErrorContains(function()
				preloader:Preload({ firstSound }, {
					RequestId = "Strict",
					FailurePolicy = "Fail",
				})
			end, "failed for 1 content item")
			assertEqual(calls, 2, "a sticky strict failure must not retry implicitly")

			assertErrorContains(function()
				preloader:Preload({ secondSound }, {
					RequestId = "Warned",
					FailurePolicy = "Warn",
				})
			end, "different targets")
		end)
	end)

	test("startup command owns the catalog selector and best-effort policy", function()
		local receivedQuery = nil
		local receivedOptions = nil
		local fakePreloader = {
			PreloadQuery = function(_self, query, options)
				receivedQuery = query
				receivedOptions = options
			end,
		}

		local command = StartupContentPreloadCommand.new(fakePreloader)
		assertEqual(command.Id, "StartupContentPreload")
		assertEqual(command.DependsOn[1], "Assets")
		command:Initialize({})

		assertEqual(receivedQuery.Tags[1], "Preload")
		assertEqual(receivedQuery.Attributes, nil)
		assertEqual(receivedOptions.RequestId, "Startup")
		assertEqual(receivedOptions.FailurePolicy, "Warn")
	end)

	local passed = 0
	local failures = {}
	for _, entry in tests do
		local ok, testError = xpcall(entry.Callback, debug.traceback)
		if ok then
			passed += 1
		else
			table.insert(failures, `{entry.Name}: {tostring(testError)}`)
			warn(`[ContentPreloaderTestRunner] FAIL {entry.Name}: {tostring(testError)}`)
		end
	end

	print(`[ContentPreloaderTestRunner] passed={passed} failed={#failures} total={#tests}`)
	return {
		passed = passed,
		failed = #failures,
		failures = failures,
	}
end

return ContentPreloaderTestRunner
