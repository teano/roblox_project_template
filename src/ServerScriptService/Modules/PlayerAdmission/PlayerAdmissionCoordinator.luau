--!strict

local Coordinator = {}
Coordinator.__index = Coordinator

local MAX_LAUNCH_DATA_LENGTH = 200
local MAX_JOB_ID_LENGTH = 128
local MAX_REDIRECT_ATTEMPTS = 3

local function finiteNonzeroInteger(value: any): boolean
	return typeof(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge and value == math.floor(value) and value ~= 0
end

local function finitePositiveInteger(value: any): boolean return finiteNonzeroInteger(value) and value > 0 end

local function finiteInteger(value: any): boolean
	return typeof(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge and value == math.floor(value)
end

local function nonemptyIdentifier(value: any): boolean
	return typeof(value) == "string" and #value > 0 and #value <= MAX_JOB_ID_LENGTH and string.find(value, "[%c]") == nil
end

local function hasOnlyKeys(value: any, allowed: { [string]: boolean }): boolean
	if typeof(value) ~= "table" or getmetatable(value) ~= nil then return false end
	for key in value do
		if typeof(key) ~= "string" or allowed[key] ~= true then return false end
	end
	return true
end

function Coordinator.new(deps: any)
	assert(typeof(deps) == "table", "PlayerAdmissionCoordinator dependencies required")
	assert(deps.PlayersModule ~= nil and deps.FriendsModule ~= nil and deps.PlayerSlots ~= nil and deps.TeleportModule ~= nil
		and deps.CharacterModule ~= nil,
		"PlayerAdmissionCoordinator dependencies missing")
	assert(finitePositiveInteger(deps.PlaceId), "PlayerAdmissionCoordinator PlaceId required")
	return setmetatable({
		_players = deps.PlayersModule, _friends = deps.FriendsModule, _slots = deps.PlayerSlots, _teleport = deps.TeleportModule,
		_characters = deps.CharacterModule,
		_placeId = deps.PlaceId, _spawn = deps.Spawn or function(callback: () -> ()) task.spawn(callback) end,
		_wait = deps.Wait or function(seconds: number) task.wait(seconds) end,
		_decodeJson = deps.DecodeJson,
		_jobId = deps.JobId or game.JobId,
		_state = "fresh", _controller = nil, _started = {}, _redirects = {}, _admissions = {},
		_generations = {},
		_friendAdmissionsByInviter = {}, _departures = {}, _departuresWaitingFor = {}, _disconnectRequested = {},
		_localTransfersByTarget = {}, _localTransfersByPlayer = {}, _nextLocalTransferGeneration = 0,
		_playerLoadedConnection = nil, _playerRemovingConnection = nil, _attemptFailedConnection = nil,
	}, Coordinator)
end

function Coordinator:_decodeLaunchData(value: any): (any?, string?)
	if typeof(value) ~= "string" or #value == 0 or #value > MAX_LAUNCH_DATA_LENGTH or self._decodeJson == nil then
		return nil, "InvalidLaunchData"
	end
	local decodedOk, decoded = pcall(self._decodeJson, value)
	if not decodedOk or not hasOnlyKeys(decoded, { Version = true, Token = true, TargetJobId = true }) then
		return nil, "InvalidLaunchData"
	end
	if decoded.Version ~= 1 or not nonemptyIdentifier(decoded.Token) or not nonemptyIdentifier(decoded.TargetJobId) then
		return nil, "InvalidLaunchData"
	end
	return table.freeze({ Version = 1, Token = decoded.Token, TargetJobId = decoded.TargetJobId, Attempt = 1 }), nil
end

function Coordinator:_readLaunchData(player: Player): (any?, boolean, string?)
	local readOk, joinData = pcall(function() return player:GetJoinData() end)
	if not readOk or typeof(joinData) ~= "table" then
		return nil, false, nil
	end
	local launchData = joinData.LaunchData
	if launchData ~= nil and (typeof(launchData) ~= "string" or launchData ~= "") then
		local continuation, errorCode = self:_decodeLaunchData(launchData)
		return continuation, false, errorCode
	end
	return nil, finiteInteger(joinData.ReferredByPlayerId) and joinData.ReferredByPlayerId ~= 0, nil
end

function Coordinator:_isFriendsContinuation(value: any): boolean
	return hasOnlyKeys(value, { Version = true, Token = true, TargetJobId = true, Attempt = true })
		and value.Version == 1
		and nonemptyIdentifier(value.Token)
		and nonemptyIdentifier(value.TargetJobId)
		and (value.Attempt == 1 or value.Attempt == 2 or value.Attempt == 3)
end

function Coordinator:_presentAndLoaded(player: Player): boolean
	return self._state == "active" and self._players:GetPlayerByUserId(player.UserId) == player and self._controller:IsLoaded(player)
end

function Coordinator:_reject(player: Player, reason: string)
	if self._disconnectRequested[player] or self._players:GetPlayerByUserId(player.UserId) ~= player then return end
	self._disconnectRequested[player] = true
	self._players:DisconnectPlayer(player, reason)
end

function Coordinator:_removeAdmission(admission: any)
	if self._admissions[admission.Player] == admission then self._admissions[admission.Player] = nil end
	if admission.InviterUserId ~= nil then
		local byInviter = self._friendAdmissionsByInviter[admission.InviterUserId]
		if byInviter ~= nil then
			byInviter[admission.Player] = nil
			if next(byInviter) == nil then self._friendAdmissionsByInviter[admission.InviterUserId] = nil end
		end
	end
end

function Coordinator:_cancelAdmission(admission: any, disconnectReason: string?)
	if admission == nil or admission.Cancelled or admission.Committed then return end
	admission.Cancelled = true
	if admission.PlayersOperation ~= nil then self._players:CancelApproval(admission.PlayersOperation) end
	if admission.SlotsOperation ~= nil then self._slots:CancelAdmission(admission.SlotsOperation) end
	if admission.FriendsOperation ~= nil then self._friends:CancelAdmission(admission.FriendsOperation) end
	self:_removeAdmission(admission)
	if disconnectReason ~= nil then self:_reject(admission.Player, disconnectReason) end
end

function Coordinator:_recordPublicRedirectFailure(player: Player, redirect: any, attemptId: string)
	if self._state ~= "active" or self._redirects[player] ~= redirect or redirect.Counted[attemptId] then return end
	redirect.Counted[attemptId] = true
	redirect.Signaled[attemptId] = nil
	if redirect.CurrentAttemptId == attemptId then redirect.CurrentAttemptId = nil end
	redirect.Failures += 1
	if redirect.Kind == "Friend" and redirect.Attempt >= MAX_REDIRECT_ATTEMPTS then
		self._redirects[player] = nil
		self:_reject(player, "Не удалось перенаправить приглашённого игрока после трёх попыток.")
		return
	end
	if redirect.Failures >= MAX_REDIRECT_ATTEMPTS then
		self._redirects[player] = nil
		self:_reject(player, if redirect.Kind == "Friend" then "Не удалось перенаправить приглашённого игрока после трёх попыток." else "Не удалось перенаправить игрока после трёх попыток.")
		return
	end
	if redirect.Kind == "Friend" then redirect.Attempt += 1 end
	self._spawn(function()
		self._wait(1)
		if self._state ~= "active" or self._redirects[player] ~= redirect then return end
		if redirect.Kind == "Friend" then self:_attemptPublicRedirect(player, redirect)
		else self:_admit(player, table.freeze({ Kind = "Ordinary" }), redirect) end
	end)
end

function Coordinator:_handleAttemptFailed(player: Player, attempt: any)
	local redirect = self._redirects[player]
	if self._state ~= "active" or redirect == nil or typeof(attempt) ~= "table" or typeof(attempt.AttemptId) ~= "string" then return end
	local attemptId = attempt.AttemptId
	if redirect.CurrentAttemptId == attemptId then self:_recordPublicRedirectFailure(player, redirect, attemptId)
	elseif redirect.CurrentAttemptId == nil then redirect.Signaled[attemptId] = true end
end

function Coordinator:_attemptPublicRedirect(player: Player, redirect: any)
	if self._state ~= "active" or self._redirects[player] ~= redirect or redirect.CurrentAttemptId ~= nil then return end
	local destination: any = { Kind = "Public", PlaceId = self._placeId }
	local continuation: any = nil
	if redirect.Kind == "Friend" then
		local attempt = redirect.Attempt
		if attempt > MAX_REDIRECT_ATTEMPTS then
			self._redirects[player] = nil
			self:_reject(player, "Не удалось перенаправить приглашённого игрока после трёх попыток.")
			return
		end
		destination = { Kind = "ServerInstance", PlaceId = self._placeId, ServerInstanceId = redirect.TargetJobId }
		continuation = table.freeze({ Version = 1, Token = redirect.Token, TargetJobId = redirect.TargetJobId, Attempt = attempt })
	end
	local callOk, result = pcall(function() return self._teleport:Teleport({ player }, destination, continuation) end)
	if self._state ~= "active" or self._redirects[player] ~= redirect then return end
	local attemptId = if callOk and typeof(result) == "table" and typeof(result.AttemptId) == "string" then result.AttemptId else `local-{redirect.Failures + 1}`
	redirect.CurrentAttemptId = attemptId
	if not callOk or typeof(result) ~= "table" or result.Ok ~= true or redirect.Signaled[attemptId] then self:_recordPublicRedirectFailure(player, redirect, attemptId) end
end

function Coordinator:_beginPublicRedirect(player: Player)
	local redirect = { Kind = "Public", Generation = self._generations[player], Failures = 0, CurrentAttemptId = nil, Counted = {}, Signaled = {} }
	self._redirects[player] = redirect
	self:_attemptPublicRedirect(player, redirect)
end

function Coordinator:_beginFriendRedirect(player: Player, continuation: any)
	local redirect = {
		Kind = "Friend",
		Generation = self._generations[player],
		Token = continuation.Token,
		TargetJobId = continuation.TargetJobId,
		Attempt = continuation.Attempt,
		Failures = 0,
		CurrentAttemptId = nil,
		Counted = {},
		Signaled = {},
	}
	self._redirects[player] = redirect
	self:_attemptPublicRedirect(player, redirect)
end

function Coordinator:_routeFriendsContinuation(player: Player, continuation: any, arrivedAfterRedirect: boolean?)
	if not self:_isFriendsContinuation(continuation) then
		self:_reject(player, "Получено недопустимое продолжение приглашения.")
		return
	end
	if continuation.TargetJobId == self._jobId then
		self:_admit(player, table.freeze({ Kind = "Invitation", Token = continuation.Token, TargetJobId = continuation.TargetJobId }), nil)
	else
		if arrivedAfterRedirect then
			if continuation.Attempt >= MAX_REDIRECT_ATTEMPTS then
				self:_reject(player, "Приглашение прибыло не в целевой сервер после трёх попыток.")
				return
			end
			continuation = table.freeze({
				Version = 1,
				Token = continuation.Token,
				TargetJobId = continuation.TargetJobId,
				Attempt = continuation.Attempt + 1,
			})
		end
		self:_beginFriendRedirect(player, continuation)
	end
end

function Coordinator:_classifyLaunchData(player: Player, waitedSeconds: number)
	if not self:_presentAndLoaded(player) then return end
	local continuation, shouldWait, errorCode = self:_readLaunchData(player)
	if errorCode ~= nil then
		self:_reject(player, "Получены недопустимые данные запуска приглашения.")
		return
	end
	if continuation ~= nil then
		self:_routeFriendsContinuation(player, continuation)
		return
	end
	if shouldWait and waitedSeconds < 10 then
		local generation = self._generations[player]
		self._spawn(function()
			self._wait(1)
			if self._state == "active" and self._generations[player] == generation then
				self:_classifyLaunchData(player, waitedSeconds + 1)
			end
		end)
		return
	end
	self:_admit(player, table.freeze({ Kind = "Ordinary" }), nil)
end

function Coordinator:_classifyAndAdmit(player: Player)
	if not self:_presentAndLoaded(player) then return end
	local result = self._teleport:GetFriendsContinuation(player)
	if typeof(result) ~= "table" or result.Status == "Invalid" then
		self:_reject(player, "Получено недопустимое продолжение телепортации.")
		return
	end
	if result.Status == "Valid" then
		self:_routeFriendsContinuation(player, result.Continuation, true)
		return
	end
	if result.Status ~= "Absent" then
		self:_reject(player, "Получено недопустимое продолжение телепортации.")
		return
	end
	self:_classifyLaunchData(player, 0)
end

function Coordinator:_admit(player: Player, friendsInput: any, redirect: any?)
	if not self:_presentAndLoaded(player) or self._admissions[player] ~= nil then return end
	if not finiteNonzeroInteger(player.UserId) then self._redirects[player] = nil; self:_reject(player, "Недопустимый идентификатор подключения."); return end
	local friendsResult = self._friends:PrepareAdmission(player, friendsInput)
	if friendsResult.Ok ~= true or friendsResult.Operation == nil or friendsResult.SlotContext == nil then
		self._redirects[player] = nil
		self:_reject(player, "Не удалось подготовить допуск игрока.")
		return
	end
	local slotContext = friendsResult.SlotContext
	local inviterUserId = nil
	if slotContext.Kind == "Friend" then inviterUserId = slotContext.InviterUserId end
	if slotContext.Kind ~= "Ordinary" and (slotContext.Kind ~= "Friend" or not finiteNonzeroInteger(inviterUserId)) then
		self._friends:CancelAdmission(friendsResult.Operation)
		self._reject(player, "Недопустимый контекст допуска.")
		return
	end
	local admission = { Player = player, FriendsOperation = friendsResult.Operation, SlotsOperation = nil, PlayersOperation = nil, InviterUserId = inviterUserId }
	self._admissions[player] = admission
	if inviterUserId ~= nil then
		local byInviter = self._friendAdmissionsByInviter[inviterUserId] or {}
		self._friendAdmissionsByInviter[inviterUserId] = byInviter
		byInviter[player] = admission
	end
	local slotsResult = self._slots:PrepareAdmission(player, slotContext)
	if slotsResult.Ok ~= true or slotsResult.Operation == nil then
		self:_cancelAdmission(admission, if slotsResult.Error == "NoSlot" then nil else "Не удалось подготовить слот игрока.")
		if slotsResult.Error == "NoSlot" and slotContext.Kind == "Ordinary" then
			if redirect == nil then self:_beginPublicRedirect(player) else self:_attemptPublicRedirect(player, redirect) end
		else
			self._redirects[player] = nil
			if slotsResult.Error == "NoSlot" then self:_reject(player, "Нет доступного слота для подключения друга.") end
		end
		return
	end
	admission.SlotsOperation = slotsResult.Operation
	local playersResult = self._players:PrepareApproval(player)
	if playersResult.Ok ~= true or playersResult.Operation == nil then
		self:_cancelAdmission(admission, "Не удалось подготовить одобрение подключения.")
		self._redirects[player] = nil
		return
	end
	admission.PlayersOperation = playersResult.Operation
	-- После этих трёх подготовок вызовы Commit не уступают и не имеют ветви ошибки.
	self._slots:CommitAdmission(admission.SlotsOperation)
	self._friends:CommitAdmission(admission.FriendsOperation)
	self._players:CommitApproval(admission.PlayersOperation)
	admission.Committed = true
	self:_removeAdmission(admission)
	self._redirects[player] = nil
	self._slots:EmitAdmissionEvents(admission.SlotsOperation)
	self._friends:EmitAdmissionEvents(admission.FriendsOperation)
	self._players:EmitConnectionApproved(admission.PlayersOperation)
end

function Coordinator:AdmitFriend(player: Player, input: any)
	if self._state ~= "active" then return end
	self:_admit(player, input, nil)
end

function Coordinator:_start(player: Player)
	if self._state ~= "active" or self._started[player] then return end
	self._started[player] = true
	self._generations[player] = (self._generations[player] or 0) + 1
	self:_classifyAndAdmit(player)
end

function Coordinator:_completeDeparture(process: any)
	if process.Completed or next(process.Waiting) ~= nil then return end
	process.Completed = true
	self._departures[process.Player] = nil
	self._friends:CompleteDeparture(process.FriendsOperation)
	if process.SlotOperation ~= nil then self._slots:CompleteDeparture(process.SlotOperation) end
end

function Coordinator:_finishWaitFor(player: Player)
	local waiting = self._departuresWaitingFor[player]
	if waiting == nil then return end
	self._departuresWaitingFor[player] = nil
	for process in waiting do
		process.Waiting[player] = nil
		self:_completeDeparture(process)
	end
end

function Coordinator:_removeLocalTransfer(process: any)
	if process.Done then return end
	process.Done = true
	if self._localTransfersByTarget[process.Target] == process then self._localTransfersByTarget[process.Target] = nil end
	for _, player in { process.Inviter, process.Target } do
		local set = self._localTransfersByPlayer[player]
		if set ~= nil then
			set[process] = nil
			if next(set) == nil then self._localTransfersByPlayer[player] = nil end
		end
	end
end

function Coordinator:_localTransferCurrent(process: any): boolean
	return self._state == "active" and not process.Done
		and self._localTransfersByTarget[process.Target] == process
		and self._generations[process.Inviter] == process.InviterGeneration
		and self._generations[process.Target] == process.TargetGeneration
		and self:_presentAndLoaded(process.Inviter) and self:_presentAndLoaded(process.Target)
end

function Coordinator:_rollbackLocalTransfer(process: any, category: string)
	if process.Done then return end
	self:_removeLocalTransfer(process)
	if process.SlotsOperation ~= nil then
		self._slots:RollbackTransfer(process.SlotsOperation)
	end
	self._characters:CancelRespawn(process.Target)
	if process.FriendsOperation ~= nil then
		self._friends:RollbackLocalTransfer(process.FriendsOperation, category)
	end
end

function Coordinator:_handleLocalRespawnResult(process: any, ok: boolean)
	if process.Done then return end
	if not ok or not self:_localTransferCurrent(process) then
		self:_rollbackLocalTransfer(process, if ok then "TargetIneligible" else "RespawnFailed")
		return
	end
	local slotsCompleted = self._slots:CompleteTransfer(process.SlotsOperation)
	local friendsCompleted = self._friends:CompleteLocalTransfer(process.FriendsOperation)
	if slotsCompleted ~= true or friendsCompleted ~= true then
		-- Complete methods are non-yielding final publication boundaries for already committed operations.
		self:_removeLocalTransfer(process)
		return
	end
	self:_removeLocalTransfer(process)
end

function Coordinator:_localTransferFailure(errorCode: any): any
	local category = if errorCode == "NoCapacity" then "NoCapacity"
		else if errorCode == "NotFriends" then "NotFriends"
		else if errorCode == "TargetBusy" then "TargetBusy"
		else if errorCode == "TargetIneligible" or errorCode == "TargetHasDependents" then "TargetIneligible"
		else "TransferFailed"
	return table.freeze({ Ok = false, Error = category })
end

function Coordinator:CanCreateLocalOffer(inviter: Player, target: Player): (boolean, string?)
	if self._state ~= "active" or inviter == target or self._localTransfersByPlayer[target] ~= nil
		or self._localTransfersByPlayer[inviter] ~= nil or self._admissions[target] ~= nil
		or self._departures[target] ~= nil or self._departures[inviter] ~= nil
		or not self:_presentAndLoaded(inviter) or not self:_presentAndLoaded(target)
	then
		return false, "TargetBusy"
	end
	local result = self._slots:CanTransferOwner(target, inviter.UserId)
	return result == "Allowed", if result == "Allowed" then nil else result
end

function Coordinator:_handleLocalTransfer(inviter: Player, target: Player, offerId: string): any
	if self._state ~= "active" or typeof(offerId) ~= "string" or offerId == ""
		or self._localTransfersByTarget[target] ~= nil or self._localTransfersByPlayer[target] ~= nil
		or self._localTransfersByPlayer[inviter] ~= nil or self._admissions[target] ~= nil
		or self._departures[target] ~= nil or self._departures[inviter] ~= nil
		or not self:_presentAndLoaded(inviter) or not self:_presentAndLoaded(target)
	then
		return table.freeze({ Ok = false, Error = "TargetBusy" })
	end
	self._nextLocalTransferGeneration += 1
	local process = {
		Generation = self._nextLocalTransferGeneration,
		Inviter = inviter,
		Target = target,
		InviterGeneration = self._generations[inviter],
		TargetGeneration = self._generations[target],
		FriendsOperation = nil,
		SlotsOperation = nil,
		Done = false,
	}
	local friendsResult = self._friends:PrepareLocalTransfer(inviter, target, offerId)
	if typeof(friendsResult) ~= "table" or friendsResult.Ok ~= true or friendsResult.Operation == nil then
		return self:_localTransferFailure(if typeof(friendsResult) == "table" then friendsResult.Error else nil)
	end
	process.FriendsOperation = friendsResult.Operation
	local slotsResult = self._slots:PrepareTransfer(target, inviter.UserId)
	if typeof(slotsResult) ~= "table" or slotsResult.Ok ~= true or slotsResult.Operation == nil then
		self._friends:RollbackLocalTransfer(process.FriendsOperation,
			self:_localTransferFailure(if typeof(slotsResult) == "table" then slotsResult.Error else nil).Error)
		return self:_localTransferFailure(if typeof(slotsResult) == "table" then slotsResult.Error else nil)
	end
	process.SlotsOperation = slotsResult.Operation
	if self._slots:CommitTransfer(process.SlotsOperation) ~= true then
		self._friends:RollbackLocalTransfer(process.FriendsOperation, "TransferFailed")
		return table.freeze({ Ok = false, Error = "TransferFailed" })
	end
	if self._friends:CommitLocalTransfer(process.FriendsOperation) ~= true then
		self._slots:RollbackTransfer(process.SlotsOperation)
		self._friends:RollbackLocalTransfer(process.FriendsOperation, "TransferFailed")
		return table.freeze({ Ok = false, Error = "TransferFailed" })
	end
	self._localTransfersByTarget[target] = process
	for _, player in { inviter, target } do
		local set = self._localTransfersByPlayer[player]
		if set == nil then set = {}; self._localTransfersByPlayer[player] = set end
		set[process] = true
	end
	local accepted = self._characters:RequestRespawn(target, function(respawnOk: boolean)
		self:_handleLocalRespawnResult(process, respawnOk)
	end)
	if not accepted and not process.Done then
		self:_rollbackLocalTransfer(process, "TargetBusy")
		return table.freeze({ Ok = false, Error = "TargetBusy" })
	end
	return table.freeze({
		Ok = true,
		Cancel = function(category: string)
			self:_rollbackLocalTransfer(process, if typeof(category) == "string" then category else "TransferFailed")
		end,
	})
end

function Coordinator:_cancelLocalTransfersFor(player: Player, category: string)
	local set = self._localTransfersByPlayer[player]
	if set == nil then return end
	local pending = {}
	for process in set do table.insert(pending, process) end
	for _, process in pending do self:_rollbackLocalTransfer(process, category) end
end

function Coordinator:_handleDeparture(player: Player)
	self._started[player] = nil
	self._generations[player] = nil
	self._redirects[player] = nil
	self:_cancelLocalTransfersFor(player, "TargetIneligible")
	self:_finishWaitFor(player)
	if self._state ~= "active" or self._departures[player] ~= nil then return end
	local slotDeparture = self._slots:BeginDeparture(player)
	local current = self._admissions[player]
	if current ~= nil then self:_cancelAdmission(current, "Допуск отменён из-за выхода игрока.") end
	local dependents = self._friendAdmissionsByInviter[player.UserId]
	if dependents ~= nil then
		local pending = {}; for _, admission in dependents do table.insert(pending, admission) end
		for _, admission in pending do self:_cancelAdmission(admission, "Допуск отменён из-за выхода пригласившего игрока.") end
	end
	local mode = if slotDeparture.Kind == "Owner" then "DisconnectPublishedFriends" else "KeepPublishedFriends"
	local friendsDeparture = self._friends:BeginDeparture(player, mode)
	local process = { Player = player, SlotOperation = slotDeparture.Operation, FriendsOperation = friendsDeparture.Operation, Waiting = {}, Completed = false }
	self._departures[player] = process
	for _, friend in friendsDeparture.FriendsToDisconnect do
		if self._players:GetPlayerByUserId(friend.UserId) == friend then
			process.Waiting[friend] = true
			local waiting = self._departuresWaitingFor[friend] or {}
			self._departuresWaitingFor[friend] = waiting
			waiting[process] = true
			self:_reject(friend, "Слот владельца закрыт.")
		end
	end
	self:_completeDeparture(process)
end

function Coordinator:Initialize(globalSaveController: any)
	if self._state == "active" then return end
	if self._state == "stopped" then error("PlayerAdmissionCoordinatorStopped", 2) end
	assert(globalSaveController ~= nil, "GlobalSaveController required")
	self._controller = globalSaveController
	self._state = "active"
	self._friends:BindLocalTransferHandler(function(inviter: Player, target: Player, offerId: string)
		return self:_handleLocalTransfer(inviter, target, offerId)
	end)
	self._attemptFailedConnection = self._teleport.AttemptFailed:Connect(function(player: Player, attempt: any) self:_handleAttemptFailed(player, attempt) end)
	self._playerRemovingConnection = self._players.PlayerRemoving:Connect(function(player: Player) self:_handleDeparture(player) end)
	self._playerLoadedConnection = globalSaveController.PlayerLoaded:Connect(function(player: Player) self:_start(player) end)
	for _, player in self._players:GetPlayers() do if globalSaveController:IsLoaded(player) then self:_start(player) end end
end

function Coordinator:Stop()
	if self._state == "stopped" then return end
	self._state = "stopped"
	local transfers = {}
	for _, process in self._localTransfersByTarget do table.insert(transfers, process) end
	for _, process in transfers do self:_rollbackLocalTransfer(process, "TransferFailed") end
	if self._playerLoadedConnection ~= nil then self._playerLoadedConnection:Disconnect(); self._playerLoadedConnection = nil end
	if self._playerRemovingConnection ~= nil then self._playerRemovingConnection:Disconnect(); self._playerRemovingConnection = nil end
	if self._attemptFailedConnection ~= nil then self._attemptFailedConnection:Disconnect(); self._attemptFailedConnection = nil end
	local admissions = {}; for _, admission in self._admissions do table.insert(admissions, admission) end
	for _, admission in admissions do self:_cancelAdmission(admission, "Допуск отменён из-за остановки сервера.") end
	table.clear(self._started); table.clear(self._generations); table.clear(self._redirects); table.clear(self._admissions); table.clear(self._friendAdmissionsByInviter)
	table.clear(self._departures); table.clear(self._departuresWaitingFor); table.clear(self._disconnectRequested)
	table.clear(self._localTransfersByTarget); table.clear(self._localTransfersByPlayer)
end

return Coordinator
