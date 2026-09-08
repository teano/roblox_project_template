--!strict

-- Ручная проверка двух настоящих клиентов Studio. Подмена затрагивает только
-- платформенную дружбу выбранной пары и копию отрицательного номера резерва.
-- Вызов RequestInvite из клиента и настоящая дружба Roblox этим не проверяются.
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local Qa = {}
local bridgeName = "FriendInvitationsStudioQaBridge"
local bound: any = nil

local function requireStudio()
	assert(RunService:IsStudio() and RunService:IsServer() and RunService:IsRunning(), "Проверка доступна только на работающем сервере Studio")
end

local function invoke(command: string, inviterId: number?, targetId: number?): any
	requireStudio()
	local bootstrap = assert(game.ServerScriptService:FindFirstChild("Bootstrap"), "Не найдена точка запуска сервера")
	local bridge = assert(bootstrap:FindFirstChild(bridgeName), "Проверочный мост не установлен") :: BindableFunction
	return bridge:Invoke(command, inviterId, targetId)
end

function Qa.Read(): any
	if bound == nil then return invoke("Read") end
	requireStudio()
	local records = {}
	for _, player in bound.Services.Players:GetPlayers() do
		local relation = bound.Services.PlayerSlots:GetPlayerSlot(player)
		local read = bound.Services.Friends:GetSnapshot(player)
		local character = player.Character
		local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
		local position = if root and root:IsA("BasePart") then root.Position else nil
		local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
		local session = bound.Session
		table.insert(records, {
			UserId = player.UserId, Name = player.Name,
			Loaded = bound.Services.GlobalSaveController:IsLoaded(player),
			SlotId = if relation then relation.SlotId else nil,
			Role = if relation then relation.Role else nil,
			OwnerUserId = if relation and relation.Owner then relation.Owner.UserId else nil,
			Team = if player.Team then player.Team.Name else nil,
			RespawnLocation = if player.RespawnLocation then player.RespawnLocation:GetFullName() else nil,
			Character = if character then character:GetFullName() else nil,
			Position = if position then { X = position.X, Y = position.Y, Z = position.Z } else nil,
			Alive = humanoid ~= nil and humanoid.Health > 0,
			WalkSpeed = if humanoid then humanoid.WalkSpeed else nil,
			CharacterAddedCount = if session then session.Appearances[player] or 0 else 0,
			Friends = if read.Ok then read.Snapshot else nil,
		})
	end
	return { Active = bound.Session ~= nil, PlaceId = game.PlaceId, GameId = game.GameId, Players = records,
		Evidence = "Два клиента Studio; дружба и номер исходящего резерва заменены проверочными значениями" }
end

function Qa.Cleanup(): any
	if bound == nil then return invoke("Cleanup") end
	local session = bound.Session
	if session == nil then return { Cleaned = true } end
	if session.Cleaning then return { Cleaned = false, Error = "Очистка уже выполняется" } end
	session.Cleaning = true
	local friends = bound.Services.Friends
	local ok, reason = pcall(function()
		local check = friends._activeChecks[session.Inviter]
		if check ~= nil and check.Request.RequestId == session.RequestId then
			friends:_finishFriendshipCheck(session.Inviter, check)
			friends:_finishRequest(session.Inviter, check.Request, "Cancelled", nil)
		end
		local offer = friends._incomingOffers[session.Target]
		if offer ~= nil and offer.Inviter == session.Inviter then
			if offer.State == "Open" then
				friends:RespondLocalOffer(session.Target, { OfferId = offer.OfferId, Decision = "Decline" }, HttpService:GenerateGUID(false))
			elseif offer.State == "Processing" and typeof(offer.CancelTransfer) == "function" then
				offer.CancelTransfer("Cancelled")
			end
			if offer.State ~= "Terminal" then friends:_terminalizeLocalOffer(offer, "Cancelled", nil) end
		end
	end)
	friends._checkFriendship = session.PreviousFriendship
	friends._holdSnapshotEntries = session.PreviousOwnReader
	session.CharacterConnection:Disconnect()
	bound.Session = nil
	return { Cleaned = ok, Error = if ok then nil else tostring(reason) }
end

function Qa.Prepare(inviterId: number, targetId: number): any
	if bound == nil then return invoke("Prepare", inviterId, targetId) end
	requireStudio()
	assert(bound.Session == nil, "Сначала завершите предыдущую проверку")
	assert(typeof(inviterId) == "number" and inviterId < 0 and inviterId == math.floor(inviterId)
		and typeof(targetId) == "number" and targetId < 0 and targetId == math.floor(targetId)
		and inviterId ~= targetId, "Нужны разные отрицательные номера игроков Studio")
	local services = bound.Services
	local players = services.Players:GetPlayers()
	assert(#players == 2, "Нужны ровно два присутствующих игрока")
	local inviter = assert(services.Players:GetPlayerByUserId(inviterId), "Приглашающий отсутствует")
	local target = assert(services.Players:GetPlayerByUserId(targetId), "Цель отсутствует")
	for _, player in { inviter, target } do
		assert(services.GlobalSaveController:IsLoaded(player), "Игрок ещё не загружен")
		local read = services.Friends:GetSnapshot(player)
		assert(read.Ok and read.Snapshot.IsSlotOwner and read.Snapshot.CanCreateReserve
			and read.Snapshot.ConnectedCount == 0 and #read.Snapshot.Reserves == 0
			and read.Snapshot.IncomingOffer == nil, "Требуются свободные владельцы без друзей, резервов и ожидающих операций")
	end
	assert(services.PlayerAdmission:CanCreateLocalOffer(inviter, target), "Перенос этой пары сейчас недопустим")
	local friends = services.Friends
	local reader = friends._holdSnapshotEntries
	local session = {
		Inviter = inviter, Target = target, Appearances = {},
		RequestId = HttpService:GenerateGUID(false),
		PreviousFriendship = friends._checkFriendship,
		PreviousOwnReader = rawget(friends, "_holdSnapshotEntries"),
		CharacterConnection = services.Characters.CharacterAdded:Connect(function(player)
			local current = bound.Session
			if current ~= nil then current.Appearances[player] = (current.Appearances[player] or 0) + 1 end
		end),
	}
	bound.Session = session
	friends._checkFriendship = function(player: Player, userId: number): boolean
		if bound.Session == session and player == inviter and userId == target.UserId
			and services.Players:GetPlayerByUserId(inviterId) == inviter
			and services.Players:GetPlayerByUserId(targetId) == target
		then return true end
		return session.PreviousFriendship(player, userId)
	end
	friends._holdSnapshotEntries = function(self: any, player: Player): any
		local entries = table.clone(reader(self, player))
		if bound.Session == session and player == inviter then
			for index, entry in entries do
				if entry.TargetUserId == targetId then
					local copy = table.clone(entry)
					copy.TargetUserId = -targetId
					entries[index] = copy
				end
			end
		end
		return entries
	end
	local ok, result = pcall(function()
		friends:RequestInvite(inviter, { TargetUserId = targetId }, session.RequestId)
		local deadline = os.clock() + 5
		while bound.Session == session and friends._incomingOffers[target] == nil and os.clock() < deadline do task.wait() end
		assert(bound.Session == session and friends._incomingOffers[target] ~= nil, "Локальное предложение не появилось за пять секунд")
		return Qa.Read()
	end)
	if not ok then Qa.Cleanup(); error(result, 0) end
	return result
end

function Qa.InstallBridge(services: any, parent: Instance)
	if not RunService:IsStudio() then return end
	requireStudio()
	assert(bound == nil and parent:IsA("Script") and parent.Name == "Bootstrap", "Проверочный мост уже установлен или выбрана неверная точка запуска")
	assert(parent:FindFirstChild(bridgeName) == nil, "Проверочный мост уже существует")
	assert(services.Friends and services.Players and services.Characters and services.PlayerAdmission
		and services.PlayerSlots and services.GlobalSaveController, "Не найдены работающие службы")
	local bridge = Instance.new("BindableFunction")
	bridge.Name = bridgeName
	bound = { Services = services, Session = nil }
	bridge.OnInvoke = function(command: any, inviterId: any, targetId: any)
		requireStudio()
		if command == "Prepare" then return Qa.Prepare(inviterId, targetId) end
		assert(inviterId == nil and targetId == nil, "Лишние аргументы проверочной команды")
		if command == "Read" then return Qa.Read() end
		if command == "Cleanup" then return Qa.Cleanup() end
		error("Неизвестная проверочная команда")
	end
	local removing = services.Players.PlayerRemoving:Connect(function(player)
		local session = bound.Session
		if session ~= nil and (session.Inviter == player or session.Target == player) then Qa.Cleanup() end
	end)
	bridge.Destroying:Connect(function() Qa.Cleanup(); removing:Disconnect() end)
	game:BindToClose(function() Qa.Cleanup() end)
	bridge.Parent = parent
end

return table.freeze(Qa)
