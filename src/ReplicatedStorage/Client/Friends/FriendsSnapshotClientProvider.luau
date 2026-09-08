--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local FriendsSnapshot = require(ReplicatedStorage.Shared.Friends.FriendsSnapshot)

local Provider = {}
Provider.__index = Provider

function Provider.new()
	return setmetatable({ Id = "Friends", Version = 1, Authority = "Server", _snapshot = nil, _running = false }, Provider)
end

function Provider:ValidateMemento(value: any): (boolean, any?, string?)
	return FriendsSnapshot.validate(value)
end

function Provider:SetMemento(value: any)
	local valid, snapshot, reason = FriendsSnapshot.validate(value)
	assert(valid, reason)
	self._snapshot = snapshot
end

function Provider:GetMemento(): any
	return assert(self._snapshot, "Friends snapshot is not set")
end

function Provider:Run()
	assert(self._snapshot ~= nil, "Friends snapshot is not set")
	self._running = true
end

function Provider:Stop()
	self._running = false
	self._snapshot = nil
end

function Provider:GetSnapshot(): any?
	return self._snapshot
end

function Provider:IsRunning(): boolean
	return self._running
end

function Provider:TryApply(previous: any, current: any): boolean
	if not self._running or self._snapshot == nil then return false end
	local previousValid, checkedPrevious = FriendsSnapshot.validate(previous)
	local currentValid, checkedCurrent = FriendsSnapshot.validate(current)
	if not previousValid or not currentValid or not FriendsSnapshot.equal(self._snapshot, checkedPrevious) then return false end
	self._snapshot = checkedCurrent
	return true
end

return Provider
