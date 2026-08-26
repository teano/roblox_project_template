--!strict

export type UiVoidResult = { Kind: "Success" } | { Kind: "Error", Error: { Code: string } }

local RootController = {}
RootController.__index = RootController

local HOSTS = {
	{ Name = "HudHost", ZIndex = 10 },
	{ Name = "ToastHost", ZIndex = 20 },
	{ Name = "WindowHost", ZIndex = 30 },
}

local function success(): UiVoidResult
	return { Kind = "Success" }
end

local function failure(): UiVoidResult
	return { Kind = "Error", Error = { Code = "UiRootMalformed" } }
end

local function configureHost(host: Frame, name: string, zIndex: number)
	host.Name = name
	host.BackgroundTransparency = 1
	host.BorderSizePixel = 0
	host.Position = UDim2.fromScale(0, 0)
	host.Size = UDim2.fromScale(1, 1)
	host.ZIndex = zIndex
	host.ClipsDescendants = false
end

local function validateRoot(root: Instance): ({ [string]: Frame }?, boolean)
	if not root:IsA("ScreenGui")
		or root.ResetOnSpawn ~= false
		or root.ScreenInsets ~= Enum.ScreenInsets.CoreUISafeInsets
		or root.ClipToDeviceSafeArea ~= true
		or root.ZIndexBehavior ~= Enum.ZIndexBehavior.Sibling
		or #root:GetChildren() ~= #HOSTS
	then
		return nil, false
	end
	local hosts = {}
	for _, expected in HOSTS do
		local found = nil
		for _, child in root:GetChildren() do
			if child.Name == expected.Name then
				if found ~= nil or not child:IsA("Frame") then
					return nil, false
				end
				found = child
			end
		end
		if found == nil
			or found.ZIndex ~= expected.ZIndex
			or found.BackgroundTransparency ~= 1
			or found.BorderSizePixel ~= 0
			or found.AnchorPoint ~= Vector2.zero
			or found.Position ~= UDim2.fromScale(0, 0)
			or found.Size ~= UDim2.fromScale(1, 1)
			or found.ClipsDescendants ~= false
			or found.Visible ~= true
		then
			return nil, false
		end
		hosts[expected.Name] = found
	end
	if #hosts.WindowHost:GetChildren() ~= 0 then
		return nil, false
	end
	return hosts, true
end

function RootController.new(playersModule: any)
	return setmetatable({
		_playersModule = playersModule,
		_root = nil,
		_hosts = nil,
		_destroyed = false,
	}, RootController)
end

function RootController:Initialize(): UiVoidResult
	if self._destroyed then
		return failure()
	elseif self._root ~= nil then
		return success()
	end

	local ok, result = xpcall(function()
		local localPlayer = self._playersModule:GetLocalPlayer()
		local playerGui = localPlayer:FindFirstChildOfClass("PlayerGui")
		if playerGui == nil then
			error("PlayerGuiMissing")
		end
		local existingRoots = {}
		for _, child in playerGui:GetChildren() do
			if child.Name == "UiRoot" then
				table.insert(existingRoots, child)
			end
		end
		if #existingRoots > 1 then
			error("DuplicateUiRoot")
		elseif #existingRoots == 1 then
			local hosts, valid = validateRoot(existingRoots[1])
			if not valid then
				error("MalformedUiRoot")
			end
			return { Root = existingRoots[1], Hosts = hosts }
		end

		local candidate = Instance.new("ScreenGui")
		candidate.Name = "UiRoot"
		candidate.ResetOnSpawn = false
		candidate.ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets
		candidate.ClipToDeviceSafeArea = true
		candidate.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		candidate.DisplayOrder = 0
		local hosts = {}
		for _, definition in HOSTS do
			local host = Instance.new("Frame")
			configureHost(host, definition.Name, definition.ZIndex)
			host.Parent = candidate
			hosts[definition.Name] = host
		end
		local validatedHosts, valid = validateRoot(candidate)
		if not valid then
			candidate:Destroy()
			error("CandidateUiRootInvalid")
		end
		candidate.Parent = playerGui
		return { Root = candidate, Hosts = validatedHosts }
	end, debug.traceback)
	if not ok then
		return failure()
	end
	self._root = result.Root
	self._hosts = result.Hosts
	return success()
end

function RootController:GetRoot(): ScreenGui
	return assert(self._root)
end

function RootController:GetHudHost(): Frame
	return assert(self._hosts).HudHost
end

function RootController:GetToastHost(): Frame
	return assert(self._hosts).ToastHost
end

function RootController:GetWindowHost(): Frame
	return assert(self._hosts).WindowHost
end

function RootController:Destroy()
	if self._destroyed then
		return
	end
	self._destroyed = true
	if self._root ~= nil then
		self._root:Destroy()
	end
	self._root = nil
	self._hosts = nil
end

return RootController
