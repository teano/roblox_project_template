--!strict

local Players = game:GetService("Players")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

ReplicatedFirst:RemoveDefaultLoadingScreen()

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local screen = Instance.new("ScreenGui")
screen.Name = "InitializationLoadingScreen"
screen.IgnoreGuiInset = true
screen.ResetOnSpawn = false
screen.DisplayOrder = 10_000

local background = Instance.new("Frame")
background.Name = "Background"
background.Size = UDim2.fromScale(1, 1)
background.BackgroundColor3 = Color3.fromRGB(12, 15, 24)
background.BorderSizePixel = 0
background.Parent = screen

local title = Instance.new("TextLabel")
title.Name = "Title"
title.AnchorPoint = Vector2.new(0.5, 0.5)
title.Position = UDim2.fromScale(0.5, 0.44)
title.Size = UDim2.fromScale(0.75, 0.1)
title.BackgroundTransparency = 1
title.Font = Enum.Font.GothamBold
title.Text = "LOADING"
title.TextColor3 = Color3.fromRGB(242, 246, 255)
title.TextScaled = true
title.Parent = background
local titleConstraint = Instance.new("UISizeConstraint")
titleConstraint.MinSize = Vector2.new(220, 48)
titleConstraint.MaxSize = Vector2.new(480, 80)
titleConstraint.Parent = title

local status = Instance.new("TextLabel")
status.Name = "Status"
status.AnchorPoint = Vector2.new(0.5, 0.5)
status.Position = UDim2.fromScale(0.5, 0.54)
status.Size = UDim2.fromScale(0.8, 0.06)
status.BackgroundTransparency = 1
status.Font = Enum.Font.Gotham
status.Text = "Initializing game systems…"
status.TextColor3 = Color3.fromRGB(147, 162, 196)
status.TextSize = 20
status.TextWrapped = true
status.Parent = background
local statusConstraint = Instance.new("UISizeConstraint")
statusConstraint.MinSize = Vector2.new(240, 36)
statusConstraint.MaxSize = Vector2.new(520, 56)
statusConstraint.Parent = status

local bar = Instance.new("Frame")
bar.Name = "ProgressTrack"
bar.AnchorPoint = Vector2.new(0.5, 0.5)
bar.Position = UDim2.fromScale(0.5, 0.62)
bar.Size = UDim2.new(0.7, 0, 0, 6)
bar.BackgroundColor3 = Color3.fromRGB(34, 41, 60)
bar.BorderSizePixel = 0
bar.Parent = background
local barConstraint = Instance.new("UISizeConstraint")
barConstraint.MinSize = Vector2.new(220, 6)
barConstraint.MaxSize = Vector2.new(360, 6)
barConstraint.Parent = bar

local fill = Instance.new("Frame")
fill.Name = "Progress"
fill.Size = UDim2.fromScale(0.25, 1)
fill.BackgroundColor3 = Color3.fromRGB(90, 156, 255)
fill.BorderSizePixel = 0
fill.Parent = bar

local cornerTrack = Instance.new("UICorner")
cornerTrack.CornerRadius = UDim.new(1, 0)
cornerTrack.Parent = bar
local cornerFill = Instance.new("UICorner")
cornerFill.CornerRadius = UDim.new(1, 0)
cornerFill.Parent = fill

screen.Parent = playerGui

local pulse = TweenService:Create(
	fill,
	TweenInfo.new(0.9, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
	{ Size = UDim2.fromScale(1, 1) }
)
pulse:Play()

while ReplicatedStorage:GetAttribute("ClientInitialized") ~= true do
	if ReplicatedStorage:GetAttribute("ClientInitializationFailed") == true then
		status.Text = "Initialization failed. Please rejoin."
		status.TextColor3 = Color3.fromRGB(255, 110, 110)
		pulse:Cancel()
		return
	end
	task.wait(0.05)
end

pulse:Cancel()
status.Text = "Ready"
fill.Size = UDim2.fromScale(1, 1)

local fade = TweenService:Create(background, TweenInfo.new(0.25), {
	BackgroundTransparency = 1,
})
fade:Play()
for _, descendant in background:GetDescendants() do
	if descendant:IsA("TextLabel") then
		TweenService:Create(descendant, TweenInfo.new(0.2), {
			TextTransparency = 1,
		}):Play()
	elseif descendant:IsA("Frame") then
		TweenService:Create(descendant, TweenInfo.new(0.2), {
			BackgroundTransparency = 1,
		}):Play()
	end
end
fade.Completed:Wait()
screen:Destroy()
