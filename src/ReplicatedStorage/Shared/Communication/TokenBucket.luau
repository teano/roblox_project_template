--!strict

local TokenBucket = {}
TokenBucket.__index = TokenBucket

local function isFiniteNonNegative(value: number): boolean
	return value == value and value ~= math.huge and value ~= -math.huge and value >= 0
end

function TokenBucket.new(refillPerSecond: number, capacity: number, clock: (() -> number)?)
	assert(isFiniteNonNegative(refillPerSecond), "refillPerSecond must be finite and non-negative")
	assert(isFiniteNonNegative(capacity) and capacity > 0, "capacity must be finite and positive")

	local resolvedClock = clock or os.clock
	return setmetatable({
		_refillPerSecond = refillPerSecond,
		_capacity = capacity,
		_clock = resolvedClock,
		_tokens = capacity,
		_updatedAt = resolvedClock(),
	}, TokenBucket)
end

function TokenBucket:_refill()
	local now = self._clock()
	if now <= self._updatedAt then
		return
	end

	local elapsed = now - self._updatedAt
	self._updatedAt = now
	self._tokens = math.min(self._capacity, self._tokens + elapsed * self._refillPerSecond)
end

function TokenBucket:CanConsume(amount: number): boolean
	assert(isFiniteNonNegative(amount), "token amount must be finite and non-negative")
	self:_refill()
	return amount <= self._tokens
end

function TokenBucket:TryConsume(amount: number): boolean
	if not self:CanConsume(amount) then
		return false
	end
	self._tokens -= amount
	return true
end

function TokenBucket.tryConsumeAll(reservations: { { Bucket: any, Amount: number } }): boolean
	for _, reservation in reservations do
		if not reservation.Bucket:CanConsume(reservation.Amount) then
			return false
		end
	end
	for _, reservation in reservations do
		assert(reservation.Bucket:TryConsume(reservation.Amount), "token reservation changed unexpectedly")
	end
	return true
end

return TokenBucket
