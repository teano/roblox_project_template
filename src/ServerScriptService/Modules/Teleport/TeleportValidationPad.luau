--!strict

local MAX_SCENE_INSTANCES_INSPECTED = 512
local MAX_CHARACTER_ANCESTORS_INSPECTED = 6
local PAD_SIZE = Vector3.new(12, 1, 12)
local FALLBACK_CFRAME = CFrame.new(0, 4, 16)
local EMPTY_AUTHORIZED_USER_IDS = table.freeze({})

type ValidationConfig = {
	Enabled: boolean,
	GameId: number,
	RoutesBySourcePlaceId: { [number]: number },
	AuthorizedUserIds: { [number]: boolean },
}

type PadHandle = {
	ConnectTouched: (self: PadHandle, callback: (BasePart) -> ()) -> (),
	Destroy: (self: PadHandle) -> (),
}

export type TeleportValidationPad = {
	Initialize: (self: TeleportValidationPad) -> (),
	Stop: (self: TeleportValidationPad) -> (),
}

local TeleportValidationPad = {}
TeleportValidationPad.__index = TeleportValidationPad

local function isPositiveInteger(value: any): boolean
	return typeof(value) == "number"
		and value == value
		and value ~= math.huge
		and value % 1 == 0
		and value > 0
end

local function hasOnlyKeys(value: any, allowed: { [string]: boolean }): boolean
	if typeof(value) ~= "table" or getmetatable(value) ~= nil then
		return false
	end
	for key in value do
		if typeof(key) ~= "string" or not allowed[key] then
			return false
		end
	end
	return true
end

local function resolveConfiguration(
	config: any,
	currentPlaceId: number,
	currentGameId: number
): (number?, { [number]: boolean })
	if typeof(config) ~= "table" or getmetatable(config) ~= nil or config.Enabled ~= true then
		return nil, EMPTY_AUTHORIZED_USER_IDS
	end
	if not hasOnlyKeys(config, {
		Enabled = true,
		GameId = true,
		RoutesBySourcePlaceId = true,
		AuthorizedUserIds = true,
	}) then
		return nil, EMPTY_AUTHORIZED_USER_IDS
	end
	if not isPositiveInteger(config.GameId) or config.GameId ~= currentGameId then
		return nil, EMPTY_AUTHORIZED_USER_IDS
	end
	if
		typeof(config.RoutesBySourcePlaceId) ~= "table"
		or getmetatable(config.RoutesBySourcePlaceId) ~= nil
		or typeof(config.AuthorizedUserIds) ~= "table"
		or getmetatable(config.AuthorizedUserIds) ~= nil
	then
		return nil, EMPTY_AUTHORIZED_USER_IDS
	end

	local routes: { [number]: number } = {}
	for sourcePlaceId, destinationPlaceId in config.RoutesBySourcePlaceId do
		if
			not isPositiveInteger(sourcePlaceId)
			or not isPositiveInteger(destinationPlaceId)
			or sourcePlaceId == destinationPlaceId
		then
			return nil, EMPTY_AUTHORIZED_USER_IDS
		end
		routes[sourcePlaceId] = destinationPlaceId
	end

	local destinationPlaceId = routes[currentPlaceId]
	if destinationPlaceId == nil then
		return nil, EMPTY_AUTHORIZED_USER_IDS
	end

	local authorizedUserIds: { [number]: boolean } = {}
	for userId, enabled in config.AuthorizedUserIds do
		if not isPositiveInteger(userId) or enabled ~= true then
			return nil, EMPTY_AUTHORIZED_USER_IDS
		end
		authorizedUserIds[userId] = true
	end
	if next(authorizedUserIds) == nil then
		return nil, EMPTY_AUTHORIZED_USER_IDS
	end

	return destinationPlaceId, table.freeze(authorizedUserIds)
end

local function sortedChildren(parent: Instance): { Instance }
	local children = parent:GetChildren()
	table.sort(children, function(left, right)
		if left.Name == right.Name then
			return left.ClassName < right.ClassName
		end
		return left.Name < right.Name
	end)
	return children
end

local function findSpawnCFrame(workspaceRoot: Instance): CFrame
	local queue = { workspaceRoot }
	local queueIndex = 1
	local inspected = 0

	while queueIndex <= #queue and inspected < MAX_SCENE_INSTANCES_INSPECTED do
		local parent = queue[queueIndex]
		queueIndex += 1
		for _, child in sortedChildren(parent) do
			inspected += 1
			if child:IsA("SpawnLocation") then
				local spawn = child :: SpawnLocation
				local xOffset = (spawn.Size.X + PAD_SIZE.X) * 0.5 + 4
				local yOffset = (PAD_SIZE.Y - spawn.Size.Y) * 0.5
				return spawn.CFrame * CFrame.new(xOffset, yOffset, 0)
			end
			if inspected >= MAX_SCENE_INSTANCES_INSPECTED then
				break
			end
			table.insert(queue, child)
		end
	end

	return FALLBACK_CFRAME
end

local function createDefaultPad(workspaceRoot: Instance, destinationPlaceId: number): PadHandle
	local part = Instance.new("Part")
	part.Name = `TeleportValidationPad_To_{destinationPlaceId}`
	part.Anchored = true
	part.CanCollide = true
	part.CanTouch = true
	part.CastShadow = true
	part.Material = Enum.Material.Neon
	part.Color = Color3.fromRGB(0, 170, 255)
	part.Size = PAD_SIZE
	part.CFrame = findSpawnCFrame(workspaceRoot)

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "DestinationLabel"
	billboard.AlwaysOnTop = true
	billboard.Size = UDim2.fromOffset(440, 104)
	billboard.StudsOffset = Vector3.new(0, 5, 0)
	billboard.Parent = part

	local label = Instance.new("TextLabel")
	label.Name = "Text"
	label.BackgroundColor3 = Color3.fromRGB(9, 21, 35)
	label.BackgroundTransparency = 0.15
	label.BorderSizePixel = 0
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.GothamBold
	label.Text = `VALIDATION TELEPORT\n→ Place {destinationPlaceId}`
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.TextScaled = true
	label.TextWrapped = true
	label.Parent = billboard

	part.Parent = workspaceRoot

	local touchedConnection: RBXScriptConnection? = nil
	local destroyed = false
	local handle = {} :: any

	function handle:ConnectTouched(callback: (BasePart) -> ())
		assert(not destroyed, "Cannot connect a destroyed validation pad")
		assert(touchedConnection == nil, "Validation pad touch is already connected")
		touchedConnection = part.Touched:Connect(callback)
	end

	function handle:Destroy()
		if destroyed then
			return
		end
		destroyed = true
		if touchedConnection then
			touchedConnection:Disconnect()
			touchedConnection = nil
		end
		part:Destroy()
	end

	return handle :: PadHandle
end

local function playerFromTouchedPart(playersModule: any, touchedPart: BasePart): Player?
	local current: Instance? = touchedPart.Parent
	local inspected = 0
	while current ~= nil and inspected < MAX_CHARACTER_ANCESTORS_INSPECTED do
		inspected += 1
		if current:IsA("Model") then
			local player = playersModule:GetPlayerFromCharacter(current)
			if player ~= nil then
				return player
			end
		end
		current = current.Parent
	end
	return nil
end

function TeleportValidationPad.new(dependencies: {
	PlayersModule: any,
	Teleport: any,
	Workspace: Instance,
	CurrentPlaceId: number,
	CurrentGameId: number,
	Config: ValidationConfig,
	PadFactory: ((Instance, number) -> PadHandle)?,
}): TeleportValidationPad
	assert(typeof(dependencies) == "table", "dependencies required")
	assert(dependencies.PlayersModule ~= nil, "PlayersModule required")
	assert(dependencies.Teleport ~= nil, "Teleport required")
	assert(typeof(dependencies.Workspace) == "Instance", "Workspace required")

	local destinationPlaceId, authorizedUserIds = resolveConfiguration(
		dependencies.Config,
		dependencies.CurrentPlaceId,
		dependencies.CurrentGameId
	)

	return setmetatable({
		_players = dependencies.PlayersModule,
		_teleport = dependencies.Teleport,
		_workspace = dependencies.Workspace,
		_destinationPlaceId = destinationPlaceId,
		_authorizedUserIds = authorizedUserIds,
		_padFactory = dependencies.PadFactory or createDefaultPad,
		_initialized = false,
		_stopped = false,
		_collectingInitialPlayers = false,
		_observerDisconnect = nil,
		_authorizedPlayer = nil,
		_presentAuthorizedPlayers = {} :: { [Player]: boolean },
		_attempted = {} :: { [Player]: boolean },
		_pad = nil,
	}, TeleportValidationPad) :: any
end

function TeleportValidationPad:_destroyPad()
	local pad = self._pad
	self._pad = nil
	if pad ~= nil then
		pad:Destroy()
	end
end

function TeleportValidationPad:_onTouched(pad: PadHandle, touchedPart: BasePart)
	if self._stopped or self._pad ~= pad then
		return
	end

	local player = playerFromTouchedPart(self._players, touchedPart)
	if player == nil
		or player ~= self._authorizedPlayer
		or self._authorizedUserIds[player.UserId] ~= true
		or self._attempted[player]
	then
		return
	end

	self._attempted[player] = true
	local destinationPlaceId = self._destinationPlaceId
	if destinationPlaceId == nil then
		return
	end

	self._teleport:Teleport({ player }, {
		Kind = "Public",
		PlaceId = destinationPlaceId,
	})
end

function TeleportValidationPad:_activatePlayer(player: Player)
	self._authorizedPlayer = player

	local destinationPlaceId = self._destinationPlaceId
	if destinationPlaceId == nil then
		return
	end
	local pad = self._padFactory(self._workspace, destinationPlaceId)
	self._pad = pad
	pad:ConnectTouched(function(touchedPart)
		self:_onTouched(pad, touchedPart)
	end)
end

function TeleportValidationPad:_reconcileAuthorizedPlayer()
	if self._stopped then
		return
	end

	local candidate: Player? = nil
	for player in self._presentAuthorizedPlayers do
		if
			candidate == nil
			or player.UserId < candidate.UserId
		then
			candidate = player
		end
	end

	local current = self._authorizedPlayer
	if current == candidate then
		return
	end
	if current ~= nil then
		self._attempted[current] = nil
	end
	self._authorizedPlayer = nil
	self:_destroyPad()
	if candidate ~= nil then
		self:_activatePlayer(candidate)
	end
end

function TeleportValidationPad:_addPlayer(player: Player)
	if self._authorizedUserIds[player.UserId] ~= true then
		return
	end
	self._presentAuthorizedPlayers[player] = true
	if not self._collectingInitialPlayers then
		self:_reconcileAuthorizedPlayer()
	end
end

function TeleportValidationPad:_removePlayer(player: Player)
	self._presentAuthorizedPlayers[player] = nil
	self._attempted[player] = nil
	self:_reconcileAuthorizedPlayer()
end

function TeleportValidationPad:Initialize()
	if self._initialized or self._stopped then
		return
	end
	self._initialized = true
	if self._destinationPlaceId == nil then
		return
	end

	self._collectingInitialPlayers = true
	self._observerDisconnect = self._players:ObservePlayers(function(player)
		self:_addPlayer(player)
	end, function(player)
		self:_removePlayer(player)
	end)
	self._collectingInitialPlayers = false
	self:_reconcileAuthorizedPlayer()
end

function TeleportValidationPad:Stop()
	if self._stopped then
		return
	end
	self._stopped = true
	if self._observerDisconnect ~= nil then
		self._observerDisconnect()
		self._observerDisconnect = nil
	end
	self._authorizedPlayer = nil
	self._collectingInitialPlayers = false
	table.clear(self._presentAuthorizedPlayers)
	table.clear(self._attempted)
	self:_destroyPad()
end

return TeleportValidationPad
