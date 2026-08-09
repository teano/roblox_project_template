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
local TestHarness = require(script.Parent.TestHarness)

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

local function waitUntil(predicate: () -> boolean)
	while not predicate() do
		task.wait()
	end
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
		assertEqual(command.DependsOn[1], "AudioStartup")
		command:Initialize({ Services = { AudioStartup = { Enabled = false } } })

		assertEqual(receivedQuery.Tags[1], "Preload")
		assertEqual(receivedQuery.Attributes, nil)
		assertEqual(receivedOptions.RequestId, "Startup")
		assertEqual(receivedOptions.FailurePolicy, "Warn")
	end)

	test("AudioCatalog/StartupPreloadSet", function()
		withRegistry(function(registry, _sharedRoot, _clientRoot)
			registry:Initialize()
			local calls = 0
			local receivedTargets = nil
			local preloader = ContentPreloader.new({
				Assets = registry,
				ContentProvider = {
					PreloadAsync = function(_self, targets, callback)
						calls += 1
						receivedTargets = table.clone(targets)
						callback("rbxassetid://200", Enum.AssetFetchStatus.Failure)
						callback("rbxassetid://100", Enum.AssetFetchStatus.Success)
					end,
				},
				Logger = makeLogger(),
			})
			local preloadContentIds = table.freeze({ "rbxassetid://100", "rbxassetid://200" })
			local command = StartupContentPreloadCommand.new(preloader)
			local context = {
				Services = {
					AudioStartup = {
						Enabled = true,
						Catalog = {
							GetSnapshot = function()
								return { PreloadContentIds = preloadContentIds }
							end,
						},
					},
				},
			}

			command:Initialize(context)
			command:Initialize(context)
			assertEqual(calls, 1, "the production audio preload request must be sticky across command reuse")
			assertEqual(#receivedTargets, 2)
			assertEqual(receivedTargets[1], "rbxassetid://100", "catalog preload IDs must retain exact sorted order")
			assertEqual(receivedTargets[2], "rbxassetid://200", "catalog preload IDs must remain unique")
			local result = preloader:GetRequestResult("AudioCatalog.Preload.v1")
			assertTrue(result ~= nil, "the exact production request id must publish its sticky result")
			assertEqual(result.Failed, 1, "Warn policy must continue after a backend failure")
			assertEqual(result.Loaded, 1)
		end)
	end)

	test("concurrent named requests share one in-flight operation and result", function()
		withRegistry(function(registry, sharedRoot, _clientRoot)
			local sound = Instance.new("Sound")
			sound.Name = "Concurrent"
			sound.Parent = sharedRoot
			registry:Initialize()

			local preloadStarted = false
			local releasePreload = false
			local calls = 0
			local preloader = ContentPreloader.new({
				Assets = registry,
				ContentProvider = {
					PreloadAsync = function(_self, _targets, callback)
						calls += 1
						preloadStarted = true
						while not releasePreload do
							task.wait()
						end
						callback("rbxassetid://concurrent", Enum.AssetFetchStatus.Success)
					end,
				},
				Logger = makeLogger(),
			})
			local first: any = nil
			local second: any = nil
			task.spawn(function()
				first = preloader:Preload({ sound }, {
					RequestId = "Concurrent",
					FailurePolicy = "Warn",
				})
			end)
			waitUntil(function()
				return preloadStarted
			end)
			task.spawn(function()
				second = preloader:Preload({ sound }, {
					RequestId = "Concurrent",
					FailurePolicy = "Warn",
				})
			end)
			task.wait()
			assertEqual(second, nil, "second request returned before the shared operation completed")
			releasePreload = true
			waitUntil(function()
				return first ~= nil and second ~= nil
			end)
			assertEqual(calls, 1)
			assertEqual(first, second)
		end)
	end)

	test("zero targets and duplicate content callbacks produce exact deterministic counts", function()
		withRegistry(function(registry, _sharedRoot, _clientRoot)
			registry:Initialize()
			local calls = 0
			local preloader = ContentPreloader.new({
				Assets = registry,
				ContentProvider = {
					PreloadAsync = function(_self, _targets, callback)
						calls += 1
						callback("rbxassetid://one", Enum.AssetFetchStatus.Success)
						callback("rbxassetid://one", Enum.AssetFetchStatus.Success)
						callback("rbxassetid://two", Enum.AssetFetchStatus.Failure)
					end,
				},
				Logger = makeLogger(),
			})
			local empty = preloader:Preload({}, {
				RequestId = "Empty",
			})
			assertEqual(calls, 0)
			assertEqual(empty.RequestedTargets, 0)
			assertEqual(empty.ResolvedContent, 0)
			assertEqual(empty.Loaded, 0)
			assertEqual(empty.Failed, 0)

			local counted = preloader:Preload({ "rbxassetid://container" })
			assertEqual(calls, 1)
			assertEqual(counted.RequestedTargets, 1)
			assertEqual(counted.ResolvedContent, 2)
			assertEqual(counted.Loaded, 1)
			assertEqual(counted.Failed, 1)
		end)
	end)

	test("invalid targets, request IDs, policies, and keys fail before calling the backend", function()
		withRegistry(function(registry, _sharedRoot, _clientRoot)
			registry:Initialize()
			local calls = 0
			local preloader = ContentPreloader.new({
				Assets = registry,
				ContentProvider = {
					PreloadAsync = function()
						calls += 1
					end,
				},
				Logger = makeLogger(),
			})
			assertErrorContains(function()
				preloader:Preload({ "" })
			end, "non-empty content ID")
			assertErrorContains(function()
				preloader:Preload({ 10 :: any })
			end, "must be an Instance")
			assertErrorContains(function()
				preloader:Preload({}, { RequestId = "" })
			end, "non-empty string")
			assertErrorContains(function()
				preloader:Preload({}, { FailurePolicy = "Retry" :: any })
			end, "must be 'Warn' or 'Fail'")
			assertErrorContains(function()
				preloader:PreloadByKeys({ "missing" })
			end, "Unknown AssetKey")
			assertEqual(calls, 0)
		end)
	end)

	return TestHarness.runAll("ContentPreloaderTestRunner", tests)
end

return ContentPreloaderTestRunner
