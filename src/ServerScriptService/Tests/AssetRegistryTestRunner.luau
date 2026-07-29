--!strict

--[[
	Manual Studio harness for the static asset catalog contract.

	require(game.ServerScriptService.Tests.AssetRegistryTestRunner).runAll()
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AssetRegistry = require(ReplicatedStorage.Shared.Assets.AssetRegistry)

local AssetRegistryTestRunner = {}

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

local function withRoots(callback: (Folder, Folder) -> ())
	local sharedRoot = Instance.new("Folder")
	sharedRoot.Name = "SharedAssetsTestRoot"
	local clientRoot = Instance.new("Folder")
	clientRoot.Name = "ClientAssetsTestRoot"

	local ok, testError = xpcall(function()
		callback(sharedRoot, clientRoot)
	end, debug.traceback)

	sharedRoot:Destroy()
	clientRoot:Destroy()
	if not ok then
		error(testError, 0)
	end
end

function AssetRegistryTestRunner.runAll()
	local tests = {}

	local function test(name: string, callback: () -> ())
		table.insert(tests, { Name = name, Callback = callback })
	end

	test("indexes paths, keys, folders, names, classes, tags and attributes", function()
		withRoots(function(sharedRoot, clientRoot)
			local audio = Instance.new("Folder")
			audio.Name = "Audio"
			audio.Parent = sharedRoot

			local alert = Instance.new("Sound")
			alert.Name = "Alert"
			alert.Parent = audio

			local click = Instance.new("Sound")
			click.Name = "Click"
			click:SetAttribute("AssetKey", "ui.click")
			click:SetAttribute("Category", "UI")
			click:AddTag("Preload")
			click.Parent = audio

			local screen = Instance.new("ScreenGui")
			screen.Name = "Inventory"
			screen:SetAttribute("AssetKey", "ui.inventory")
			screen.Parent = clientRoot

			local registry = AssetRegistry.new({
				{ Namespace = "Shared", Root = sharedRoot },
				{ Namespace = "Client", Root = clientRoot },
			})
			registry:Initialize()
			registry:Initialize()

			assertTrue(registry:IsInitialized(), "registry must initialize idempotently")
			assertEqual(registry:Get("Shared"), sharedRoot)
			assertEqual(registry:Get("Shared/Audio/Click"), click)
			assertEqual(registry:GetByKey("ui.click"), click)
			assertEqual(registry:RequireByKey("ui.inventory", "LayerCollector"), screen)
			assertEqual(registry:GetPath(click), "Shared/Audio/Click")

			local children = registry:GetChildren("Shared/Audio")
			assertTrue(table.isfrozen(children), "folder results must be immutable")
			assertEqual(#children, 2)
			assertEqual(children[1], alert, "children must be sorted by canonical path")
			assertEqual(children[2], click, "children must be sorted by canonical path")

			local descendants = registry:GetDescendants("Shared")
			assertEqual(#descendants, 3)
			assertEqual(#registry:FindByName("Click"), 1)
			assertEqual(#registry:FindByClassName("Sound"), 2)

			local matches = registry:FindAll({
				Under = "Shared/Audio",
				IsA = "Sound",
				Tags = { "Preload" },
				Attributes = {
					Category = "UI",
				},
			})
			assertEqual(#matches, 1)
			assertEqual(matches[1], click)

			local clone = registry:Clone("Shared/Audio/Click", "Sound")
			assertTrue(clone ~= click and clone:IsA("Sound"), "Clone must return a separate typed instance")
			clone:Destroy()

			local lateAsset = Instance.new("Sound")
			lateAsset.Name = "Late"
			lateAsset.Parent = audio
			assertEqual(registry:Get("Shared/Audio/Late"), nil, "catalog must remain a startup snapshot")
		end)
	end)

	test("rejects duplicate logical paths", function()
		withRoots(function(sharedRoot, _clientRoot)
			local first = Instance.new("Folder")
			first.Name = "Duplicate"
			first.Parent = sharedRoot
			local second = Instance.new("Folder")
			second.Name = "Duplicate"
			second.Parent = sharedRoot

			local registry = AssetRegistry.new({
				{ Namespace = "Shared", Root = sharedRoot },
			})
			assertErrorContains(function()
				registry:Initialize()
			end, "Duplicate asset path")
			assertEqual(registry:GetState(), "Failed")
		end)
	end)

	test("rejects duplicate and malformed public keys", function()
		withRoots(function(sharedRoot, clientRoot)
			local sharedAsset = Instance.new("Folder")
			sharedAsset.Name = "SharedAsset"
			sharedAsset:SetAttribute("AssetKey", "duplicate.key")
			sharedAsset.Parent = sharedRoot

			local clientAsset = Instance.new("Folder")
			clientAsset.Name = "ClientAsset"
			clientAsset:SetAttribute("AssetKey", "duplicate.key")
			clientAsset.Parent = clientRoot

			local duplicateRegistry = AssetRegistry.new({
				{ Namespace = "Shared", Root = sharedRoot },
				{ Namespace = "Client", Root = clientRoot },
			})
			assertErrorContains(function()
				duplicateRegistry:Initialize()
			end, "Duplicate AssetKey")

			clientAsset:SetAttribute("AssetKey", "contains spaces")
			local malformedRegistry = AssetRegistry.new({
				{ Namespace = "Client", Root = clientRoot },
			})
			assertErrorContains(function()
				malformedRegistry:Initialize()
			end, "must contain only")
		end)
	end)

	test("rejects overlapping roots and unknown query scopes", function()
		withRoots(function(sharedRoot, _clientRoot)
			local nestedRoot = Instance.new("Folder")
			nestedRoot.Name = "Nested"
			nestedRoot.Parent = sharedRoot

			local overlappingRegistry = AssetRegistry.new({
				{ Namespace = "Shared", Root = sharedRoot },
				{ Namespace = "Nested", Root = nestedRoot },
			})
			assertErrorContains(function()
				overlappingRegistry:Initialize()
			end, "must not overlap")

			local registry = AssetRegistry.new({
				{ Namespace = "Shared", Root = sharedRoot },
			})
			registry:Initialize()
			assertErrorContains(function()
				registry:FindAll({
					Under = "Shared/Missing",
				})
			end, "Unknown asset query scope")
		end)
	end)

	local passed = 0
	local failures = {}
	for _, entry in tests do
		local ok, testError = xpcall(entry.Callback, debug.traceback)
		if ok then
			passed += 1
		else
			table.insert(failures, `{entry.Name}: {tostring(testError)}`)
			warn(`[AssetRegistryTestRunner] FAIL {entry.Name}: {tostring(testError)}`)
		end
	end

	print(`[AssetRegistryTestRunner] passed={passed} failed={#failures} total={#tests}`)
	return {
		passed = passed,
		failed = #failures,
		failures = failures,
	}
end

return AssetRegistryTestRunner
