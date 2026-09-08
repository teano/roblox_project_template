--!strict

-- Shared slot leases are authoritative for both local owners and routed arrivals.
-- Access codes never leave this server-only module or TeleportModule.
local Routing = {}
Routing.__index = Routing

local function copy(value: any): any
	if typeof(value) ~= "table" then return value end
	local result = {}
	for key, item in value do result[key] = copy(item) end
	return result
end

local function failure(code: string): any return { Ok = false, Error = code } end

function Routing.new(deps: any)
	assert(deps.Store and deps.TeleportModule and deps.GenerateId, "AdmissionRouting dependencies required")
	local privateId = deps.PrivateServerId or ""
	return setmetatable({
		_store = deps.Store, _teleport = deps.TeleportModule, _id = deps.GenerateId,
		_clock = deps.Clock or os.time, _monotonic = deps.MonotonicClock or os.clock,
		_spawn = deps.Spawn or task.spawn, _wait = deps.Wait or task.wait,
		_placeId = deps.PlaceId, _jobId = deps.JobId, _privateId = privateId,
		_partition = deps.MatchmakingType or "Default",
		_key = if privateId ~= "" then "reserved:" .. privateId .. ":" .. (deps.MatchmakingType or "Default") else "public:" .. deps.JobId,
		_ttl = deps.RecordLifetimeSeconds or 60, _interval = deps.RefreshIntervalSeconds or 20,
		_reserveTtl = deps.ReservationLifetimeSeconds or 60,
		_timeout = deps.OperationTimeoutSeconds or 10, _routeTimeout = deps.RouteTimeoutSeconds or 30,
		_maxCandidates = deps.MaxCandidates or 32, _autoRefresh = deps.AutoRefresh ~= false,
		_enabled = false, _initialized = false, _stopped = false, _ready = false,
		_generation = nil, _slots = {}, _occupied = {}, _aliveUntil = 0,
	}, Routing)
end

-- Waiting is bounded even if Roblox never returns. Mutating callbacks also check
-- the same deadline; a write accepted before timeout has conditional cleanup.
function Routing:_call(callback: any, late: any?, budget: number?): (boolean, any)
	local deadline = self._monotonic() + (budget or self._timeout)
	local done, abandoned, ok, value = false, false, false, nil
	local function active(): boolean
		return not self._stopped and not abandoned and self._monotonic() < deadline
	end
	self._spawn(function()
		ok, value = pcall(callback, active)
		done = true
		if abandoned and ok and late then late(value) end
	end)
	while not done and active() do self._wait(0.03) end
	if not done or self._stopped or self._monotonic() >= deadline then
		abandoned = true
		if done and ok and late then self._spawn(function() late(value) end) end
		return false, "Unavailable"
	end
	return ok, value
end

function Routing:_live(record: any): boolean
	return typeof(record) == "table" and record.Version == 1 and record.Kind == "Server"
		and record.PlaceId == self._placeId and record.Partition == self._partition
		and typeof(record.Generation) == "string" and typeof(record.Slots) == "table"
		and typeof(record.AliveUntil) == "number" and record.AliveUntil > self._clock()
end

function Routing:_newRecord(generation: string, jobId: string, accessCode: string?): any
	local slots = {}
	for _, slotId in self._slots do slots[tostring(slotId)] = false end
	return {
		Version = 1, Kind = "Server", PlaceId = self._placeId, Partition = self._partition,
		Generation = generation, JobId = jobId, AccessCode = accessCode,
		AliveUntil = self._clock() + self._ttl, Slots = slots,
	}
end

function Routing:Initialize(enabled: boolean, slotIds: { number })
	if self._initialized or self._stopped then return end
	self._initialized = true
	self._enabled = enabled
	if not enabled then return end
	self._slots = table.clone(slotIds)
	assert(#self._slots > 0, "AdmissionRouting enabled without slots")
	self:Refresh()
	if self._autoRefresh then
		self._spawn(function()
			while not self._stopped do
				self._wait(self._interval)
				if not self._stopped then self:Refresh() end
			end
		end)
	end
end

function Routing:IsEnabled(): boolean return self._enabled end

function Routing:Refresh(): boolean
	if not self._enabled or self._stopped then return false end
	local proposed = self._id()
	local ok, record = self:_call(function(active: any)
		return self._store:UpdateAsync(self._key, function(old: any)
			if not active() then return nil end
			local current
			if typeof(old) == "table" and old.AliveUntil and old.AliveUntil > self._clock()
				and (old.Partition ~= self._partition or old.PlaceId ~= self._placeId) then return nil end
			if self:_live(old) then
				if old.JobId ~= self._jobId and old.JobId ~= "" then return nil end
				current = copy(old)
			else
				-- Reserved access codes are not reconstructible after loss. Retain one
				-- already learned by this instance; never invent an access route.
				current = self:_newRecord(proposed, self._jobId, self._accessCode)
			end
			current.JobId = self._jobId
			current.AliveUntil = self._clock() + self._ttl
			for slot, claim in self._occupied do
				current.Slots[slot] = { Token = claim.Token, UserId = claim.UserId,
					State = "Occupied", ExpiresAt = current.AliveUntil + self._ttl }
			end
			return current, current.AliveUntil
		end, self._ttl)
	end, function(lateRecord: any)
		if self._stopped and typeof(lateRecord) == "table" then self:_retireRecord(lateRecord.Generation) end
	end)
	if not ok or not self:_live(record) or record.JobId ~= self._jobId then
		self._ready = false
		return false
	end
	self._generation = record.Generation
	self._accessCode = record.AccessCode
	self._aliveUntil = record.AliveUntil
	for _, claim in self._occupied do claim.Generation = record.Generation end
	if self._privateId ~= "" then
		local generation = self._generation
		local addressOk, address = self:_call(function(active: any)
			return self._store:UpdateAsync("job:" .. self._jobId, function()
				if not active() then return nil end
				return { Kind = "Address", ServerKey = self._key, Generation = generation, AliveUntil = self._aliveUntil }, 0
			end, self._ttl)
		end)
		if not addressOk or typeof(address) ~= "table" or address.Kind ~= "Address"
			or address.ServerKey ~= self._key or address.Generation ~= generation
			or typeof(address.AliveUntil) ~= "number" or address.AliveUntil <= self._clock() then
			self._ready = false
			return false
		end
	end
	self._ready = true
	return true
end

function Routing:_claim(key: string, record: any, slotId: number, token: string, userId: number): any
	return { ServerKey = key, Generation = record.Generation, SlotId = slotId,
		Token = token, UserId = userId }
end

function Routing:_releaseStored(claim: any)
	-- Cleanup deliberately works after Stop; it can only remove this exact token.
	pcall(function()
		self._store:UpdateAsync(claim.ServerKey, function(old: any)
			if typeof(old) ~= "table" or old.Generation ~= claim.Generation then return nil end
			local slot = tostring(claim.SlotId)
			local lease = old.Slots[slot]
			if typeof(lease) ~= "table" or lease.Token ~= claim.Token or lease.UserId ~= claim.UserId then return nil end
			local current = copy(old)
			current.Slots[slot] = false
			return current, current.AliveUntil
		end, self._ttl)
	end)
end

function Routing:Release(claim: any)
	if typeof(claim) ~= "table" then return end
	local slot = tostring(claim.SlotId)
	if self._occupied[slot] == claim then self._occupied[slot] = nil end
	self._spawn(function() self:_releaseStored(claim) end)
end

function Routing:IsClaimCurrent(claim: any): boolean
	return not self._stopped and self._ready and self._aliveUntil > self._clock()
		and claim.Generation == self._generation and self._occupied[tostring(claim.SlotId)] == claim
end

function Routing:AcquireLocal(userId: number, slotId: number, arrival: any?): any
	if not self._enabled or self._stopped then return failure("Unavailable") end
	if not self._ready or self._aliveUntil <= self._clock() then
		if not self:Refresh() then return failure("Unavailable") end
	end
	if arrival and (arrival.ServerKey ~= self._key or arrival.Generation ~= self._generation or arrival.SlotId ~= slotId) then
		return failure("InvalidReservation")
	end
	-- Arrival consumes the routing token. A late source cancellation must not
	-- release the occupied target slot after the player has already arrived.
	local token = self._id()
	local generation = self._generation
	local slot = tostring(slotId)
	local claim = { ServerKey = self._key, Generation = generation, SlotId = slotId, Token = token, UserId = userId }
	local ok, record = self:_call(function(active: any)
		return self._store:UpdateAsync(self._key, function(old: any)
			if not active() or not self:_live(old) or old.Generation ~= generation or old.JobId ~= self._jobId then return nil end
			if old.Slots[slot] == nil then return nil end
			local lease = old.Slots[slot]
			if arrival then
				if typeof(lease) ~= "table" or lease.State ~= "Reserved" or lease.Token ~= arrival.Token
					or lease.UserId ~= userId or lease.ExpiresAt <= self._clock() then return nil end
			elseif typeof(lease) == "table" and lease.ExpiresAt > self._clock() then return nil end
			local current = copy(old)
			current.Slots[slot] = { Token = token, UserId = userId, State = "Occupied", ExpiresAt = old.AliveUntil + self._ttl }
			return current, current.AliveUntil
		end, self._ttl)
	end, function() self:_releaseStored(claim) end)
	if not ok then return failure("Unavailable") end
	if not self:_live(record) or record.Generation ~= generation or self._generation ~= generation then
		self:Release(claim)
		return failure(if arrival then "InvalidReservation" else "NoSlot")
	end
	local lease = record.Slots[slot]
	if typeof(lease) ~= "table" or lease.Token ~= token or lease.State ~= "Occupied" then
		return failure(if arrival then "InvalidReservation" else "NoSlot")
	end
	self._occupied[slot] = claim
	return { Ok = true, Claim = claim }
end

function Routing:_destination(key: string, record: any): any?
	if string.sub(key, 1, 9) == "reserved:" then
		if typeof(record.AccessCode) ~= "string" or record.AccessCode == "" then return nil end
		return { Kind = "ReservedServer", PlaceId = self._placeId, ReservedServerAccessCode = record.AccessCode }
	end
	if typeof(record.JobId) ~= "string" or record.JobId == "" then return nil end
	return { Kind = "ServerInstance", PlaceId = self._placeId, ServerInstanceId = record.JobId }
end

function Routing:_reserve(key: string, userId: number, hop: number, budget: number?): any
	local token, claim = self._id(), nil
	local ok, record = self:_call(function(active: any)
		return self._store:UpdateAsync(key, function(old: any)
			claim = nil
			if not active() or key == self._key or not self:_live(old) or not self:_destination(key, old) then return nil end
			local selected = nil
			for slot, lease in old.Slots do
				if lease == false or (typeof(lease) == "table" and lease.ExpiresAt <= self._clock()) then
					local number = tonumber(slot)
					if number and (selected == nil or number < selected) then selected = number end
				end
			end
			if not selected then return nil end
			local current = copy(old)
			current.Slots[tostring(selected)] = { Token = token, UserId = userId, State = "Reserved", ExpiresAt = self._clock() + self._reserveTtl }
			claim = self:_claim(key, current, selected, token, userId)
			return current, current.AliveUntil
		end, self._ttl)
	end, function() if claim then self:_releaseStored(claim) end end, budget)
	if not ok then return failure("Unavailable") end
	if not claim or not self:_live(record) then return failure("NoSlot") end
	local lease = record.Slots[tostring(claim.SlotId)]
	if typeof(lease) ~= "table" or lease.Token ~= token then return failure("NoSlot") end
	return { Ok = true, Claim = claim, Destination = self:_destination(key, record), Continuation = {
		Version = 1, ServerKey = key, Generation = record.Generation, SlotId = claim.SlotId, Token = token, Hop = hop,
	} }
end

function Routing:ReserveDestination(userId: number, previous: any?): any
	if not self._enabled or self._stopped then return failure("Unavailable") end
	local hop = if previous then previous.Hop + 1 else 1
	if hop > 3 then return failure("HopLimit") end
	local deadline = self._monotonic() + self._routeTimeout
	local function budget(): number return math.max(0, math.min(self._timeout, deadline - self._monotonic())) end
	local ok, entries = self:_call(function() return self._store:GetRangeAsync(Enum.SortDirection.Descending, self._maxCandidates) end, nil, budget())
	if not ok then return failure("Unavailable") end
	for _, entry in entries do
		if self._monotonic() >= deadline then return failure("Unavailable") end
		if entry.key ~= self._key and (not previous or entry.key ~= previous.ServerKey) and self:_live(entry.value) then
			local result = self:_reserve(entry.key, userId, hop, budget())
			if result.Ok or result.Error == "Unavailable" then return result end
		end
	end
	-- One short creation lease per platform partition. It points to the pending
	-- server so concurrent callers can reserve its remaining slots before startup.
	local launchKey = "launch:" .. self._partition
	local ticket = self._id()
	while not self._stopped and self._monotonic() < deadline do
		local lockOk, launch = self:_call(function(active: any)
			return self._store:UpdateAsync(launchKey, function(old: any)
				if not active() then return nil end
				if typeof(old) == "table" and old.Until > self._clock() then return old, old.Until end
				return { Kind = "Launch", Ticket = ticket, Until = self._clock() + self._timeout + 5 }, self._clock() + self._timeout + 5
			end, self._ttl)
		end, nil, budget())
		if not lockOk or typeof(launch) ~= "table" then return failure("Unavailable") end
		if launch.ServerKey then
			local result = self:_reserve(launch.ServerKey, userId, hop, budget())
			if result.Ok or result.Error == "Unavailable" then return result end
			-- The launched server is full/stale; clear only this exact pointer.
			self:_call(function(active: any)
				return self._store:UpdateAsync(launchKey, function(old: any)
					if not active() or not old or old.Ticket ~= launch.Ticket then return nil end
					return { Kind = "Launch", Ticket = "", Until = 0 }, 0
				end, self._ttl)
			end, nil, budget())
		elseif launch.Ticket == ticket then
			local reserveOk, reserved = self:_call(function() return self._teleport:ReserveServer(self._placeId) end, nil, budget())
			if not reserveOk or not reserved.Ok then return failure("Unavailable") end
			local key = "reserved:" .. reserved.PrivateServerId .. ":" .. self._partition
			local pending = self:_newRecord(self._id(), "", reserved.AccessCode)
			local writeOk, written = self:_call(function(active: any)
				return self._store:UpdateAsync(key, function(old: any)
					if not active() or old ~= nil then return nil end
					return pending, pending.AliveUntil
				end, self._ttl)
			end, nil, budget())
			if not writeOk or not written then return failure("Unavailable") end
			local publishOk, published = self:_call(function(active: any)
				return self._store:UpdateAsync(launchKey, function(old: any)
					if not active() or not old or old.Ticket ~= ticket or old.Until <= self._clock() then return nil end
					return { Kind = "Launch", Ticket = ticket, Until = pending.AliveUntil, ServerKey = key }, pending.AliveUntil
				end, self._ttl)
			end, nil, budget())
			if not publishOk or not published or published.ServerKey ~= key then return failure("Unavailable") end
			local result = self:_reserve(key, userId, hop, budget())
			if result.Ok or result.Error == "Unavailable" then return result end
		else
			self._wait(math.min(0.2, math.max(0, deadline - self._monotonic())))
		end
	end
	return failure("Unavailable")
end

function Routing:ResolveFriendDestination(targetJobId: string): any
	if not self._enabled then
		return { Ok = true, Destination = { Kind = "ServerInstance", PlaceId = self._placeId, ServerInstanceId = targetJobId } }
	end
	local ok, address = self:_call(function() return self._store:GetAsync("job:" .. targetJobId) end)
	if not ok then return failure("Unavailable") end
	if typeof(address) == "table" and address.Kind == "Address" and address.AliveUntil > self._clock() then
		local readOk, record = self:_call(function() return self._store:GetAsync(address.ServerKey) end)
		if not readOk then return failure("Unavailable") end
		if self:_live(record) and record.Generation == address.Generation and record.JobId == targetJobId then
			local destination = self:_destination(address.ServerKey, record)
			if destination then return { Ok = true, Destination = destination } end
		end
		return failure("Unavailable")
	end
	-- A public job can predate this module; exact job teleport is safe and bounded.
	return { Ok = true, Destination = { Kind = "ServerInstance", PlaceId = self._placeId, ServerInstanceId = targetJobId } }
end

function Routing:_retireRecord(generation: string?)
	pcall(function()
		self._store:UpdateAsync(self._key, function(old: any)
			if not old or old.JobId ~= self._jobId or (generation and old.Generation ~= generation) then return nil end
			local current = copy(old)
			current.AliveUntil = 0
			return current, 0
		end, 1)
	end)
end

function Routing:Stop()
	if self._stopped then return end
	self._stopped = true
	self._ready = false
	if not self._enabled then return end
	local generation = self._generation
	self._spawn(function()
		self:_retireRecord(generation)
	end)
end

return Routing
