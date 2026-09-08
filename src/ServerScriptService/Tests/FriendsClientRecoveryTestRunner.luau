--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local FriendsClient = require(ReplicatedStorage.Client.Friends.FriendsClient)
local FriendsSnapshotClientProvider = require(ReplicatedStorage.Client.Friends.FriendsSnapshotClientProvider)
local FriendsProtocol = require(ReplicatedStorage.Shared.Friends.FriendsProtocol)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local TestHarness = require(script.Parent.TestHarness)

local Runner = {}
local function equal(actual: any, expected: any, message: string?)
	assert(actual == expected, `{message or "value"}: expected={tostring(expected)} actual={tostring(actual)}`)
end
local function snapshot(withReserve: boolean): any
	return {
		Min = 1, Max = 3, Current = 3, ConnectedCount = 0, CanCreateReserve = true,
		IsSlotOwner = true, ConnectedUserIds = {},
		Reserves = if withReserve then { { TargetUserId = 77, ExpiresAtServerTime = 1000, Kind = "Native" } } else {},
	}
end
local function fixture(scope: any): any
	local ready = scope:Track(Signal.new())
	local closed = scope:Track(Signal.new())
	local provider = scope:Track(FriendsSnapshotClientProvider.new())
	local f: any = {
		Handlers = {}, Queued = {}, Timers = {}, Workers = {}, Completions = {},
		Paused = false, Requests = 0, NativeCalls = 0, Now = 0,
		CanSend = function() return true end, Prompt = function() end, Player = {} :: any,
	}
	local prepare: any = nil
	local communication = {}
	function communication:RegisterHandler(kind: string, callback: any) f.Handlers[kind] = callback end
	function communication:RegisterResyncPreparation(callback: any)
		prepare = callback
		return function() prepare = nil end
	end
	function communication:Queue(kind: string, payload: any, requestId: string?, options: any): boolean
		if f.Paused then return false end
		table.insert(f.Queued, { Type = kind, Payload = payload, RequestId = requestId, Options = options })
		return true
	end
	function communication:RequestResync(_reason: string)
		if f.Paused then return end
		f.Paused = true
		f.Completions = if prepare ~= nil then prepare("test") else {}
		table.clear(f.Queued)
	end
	local client = scope:Track(FriendsClient.new(provider, {
		Communication = communication, LocalPlayer = f.Player,
		GenerateRequestId = function() f.Requests += 1; return `request-{f.Requests}` end,
		Clock = function() return f.Now end,
		Delay = function(seconds: number, callback: () -> ())
			table.insert(f.Timers, { At = f.Now + seconds, Callback = callback })
		end,
		Spawn = function(callback: () -> ())
			local worker = coroutine.create(callback)
			table.insert(f.Workers, worker)
			scope:Defer(function() if coroutine.status(worker) ~= "dead" then coroutine.close(worker) end end)
			assert(coroutine.resume(worker))
		end,
		SocialService = {
			GameInvitePromptClosed = closed,
			CanSendGameInviteAsync = function() return f.CanSend() end,
			PromptGameInvite = function(_self: any, player: Player, options: any)
				equal(player, f.Player)
				equal(options.InviteUser, 77)
				f.NativeCalls += 1
				f.Prompt()
			end,
		},
	}))
	f.Client = client; f.Provider = provider; f.Ready = ready; f.Closed = closed
	function f:Advance(now: number)
		self.Now = now
		local calls = 0
		while true do
			local due = nil
			for index, timer in self.Timers do if timer.At <= now then due = index; break end end
			if due == nil then break end
			local timer = table.remove(self.Timers, due)
			timer.Callback()
			calls += 1; assert(calls < 100, "timer callbacks did not settle")
		end
	end
	function f:ApplyFull(value: any)
		provider:Stop(); provider:SetMemento(value); provider:Run(); ready:Fire()
	end
	function f:Delta(value: any)
		self.Handlers[FriendsProtocol.MessageTypes.SnapshotChanged]({ Previous = provider:GetSnapshot(), Current = value })
	end
	function f:Open(requestId: string?)
		local id = requestId or `request-{self.Requests}`
		self.Handlers[FriendsProtocol.MessageTypes.OpenPrompt]({
			Generation = `generation-{id}`, TargetUserId = 77, LaunchData = "{}",
		}, id)
	end
	function f:Result(category: string, requestId: string?)
		local id = requestId or `request-{self.Requests}`
		self.Handlers[FriendsProtocol.MessageTypes.InviteResult]({ Category = category, Generation = `generation-{id}` }, id)
	end
	function f:Recover() communication:RequestResync("test") end
	function f:CompleteCancelled()
		local callbacks = self.Completions; self.Completions = {}
		for _, callback in callbacks do callback() end
	end
	function f:Resume() self.Paused = false end
	function f:Messages(kind: string): { any }
		local found = {}; for _, message in self.Queued do if message.Type == kind then table.insert(found, message) end end
		return found
	end
	client:Initialize({ Ready = ready }); f:ApplyFull(snapshot(false))
	return f
end

function Runner.runAll()
	local tests = {}
	local function test(name: string, callback: (any) -> ()) table.insert(tests, { Name = name, Callback = callback }) end

	test("a request with no server answer releases its pending state at ten seconds", function(scope)
		local f = fixture(scope); local results = {}; local phases = {}
		f.Client.PromptStateChanged:Connect(function(event) table.insert(phases, event.Current.Phase) end)
		assert(f.Client:RequestInvite(77, function(value) table.insert(results, value) end).Ok)
		f:Advance(9.99); equal(f.Client:GetPromptState().IsBusy, true)
		f:Advance(10); equal(phases[#phases], "Idle", "deadline must publish independently of a read")
		equal(results[1], "TemporaryError"); equal(#results, 1)
		f:Open("request-1"); equal(f.NativeCalls, 0)
		equal(#f:Messages(FriendsProtocol.MessageTypes.PlatformResult), 0, "an unknown late generation must not be reported")
		assert(f.Client:RequestInvite(77).Ok)
		f:Result("PromptRequested", "request-1")
		equal(f.Client:GetPromptState().Phase, "Requesting", "late old result must not finish the new attempt")
	end)

	test("eligibility and prompt waits share the deadline measured from RequestInvite", function(scope)
		for _, boundary in { "CanSend", "Prompt" } do
			local f = fixture(scope); local results = {}
			if boundary == "CanSend" then f.CanSend = function() coroutine.yield(); return true end
			else f.Prompt = function() coroutine.yield() end end
			assert(f.Client:RequestInvite(77, function(value) table.insert(results, value) end).Ok)
			f:Advance(7); f:Delta(snapshot(true)); f:Open()
			equal(coroutine.status(f.Workers[1]), "suspended")
			f:Advance(10); equal(f.Client:GetPromptState().IsBusy, false)
			equal(results[1], "TemporaryError"); equal(#results, 1)
			assert(f.Client:RequestInvite(77).Ok)
			assert(coroutine.resume(f.Workers[1]))
			equal(f.NativeCalls, if boundary == "CanSend" then 0 else 1)
			equal(#f:Messages(FriendsProtocol.MessageTypes.PlatformResult), 0, "late platform return must not report the old attempt")
			equal(f.Client:GetPromptState().Phase, "Requesting")
		end
	end)

	test("successful API return does not claim visibility and permits retry at ten seconds", function(scope)
		local f = fixture(scope); local results = {}
		assert(f.Client:RequestInvite(77, function(value) table.insert(results, value) end).Ok)
		f:Advance(7); f:Delta(snapshot(true)); f:Open()
		equal(f.Client:GetPromptState().Phase, "PromptRequested")
		equal(f.Client:GetPromptState().IsOpen, nil, "Roblox provides no opened acknowledgement")
		local sent = f:Messages(FriendsProtocol.MessageTypes.PlatformResult)
		equal(#sent, 1); equal(sent[1].Payload.Result, "PromptRequested")
		f:Result("PromptRequested")
		f.Closed:Fire(f.Player, { 77 }); equal(f.Client:GetPromptState().IsBusy, true)
		f:Advance(9.99); equal(f.Client:GetPromptState().IsBusy, true)
		f:Advance(10); equal(f.Client:GetPromptState().IsBusy, false)
		equal(#results, 1); equal(results[1], "PromptRequested")
		equal(#f.Client:GetSnapshot().Snapshot.Reserves, 1, "client deadline must not delete a server reserve")
		assert(f.Client:RequestInvite(77).Ok); f:Open()
		equal(f.NativeCalls, 2)
		f.Closed:Fire(f.Player, {}); equal(f.Client:GetPromptState().IsBusy, true, "late closure cannot release the new attempt")
		equal(#f:Messages(FriendsProtocol.MessageTypes.PromptClosed), 0)
		f:Advance(20); equal(f.Client:GetPromptState().IsBusy, false)
	end)

	test("pre-prompt platform errors release early and report exactly once", function(scope)
		for _, mode in { "Unavailable", "Error" } do
			local f = fixture(scope); local results = {}
			f.CanSend = function() if mode == "Error" then error("ExpectedCapabilityError") end; return false end
			assert(f.Client:RequestInvite(77, function(value) table.insert(results, value) end).Ok)
			f:Open(); equal(f.Client:GetPromptState().IsBusy, false); equal(f.NativeCalls, 0)
			local expected = if mode == "Error" then "TemporaryError" else "InviteUnavailable"
			equal(results[1], expected); equal(#f:Messages(FriendsProtocol.MessageTypes.PlatformResult), 1)
			f:Result(expected); f:Advance(10); equal(#results, 1)
		end
	end)

	test("duplicate open instructions cannot start a second worker for one attempt", function(scope)
		local f = fixture(scope)
		f.CanSend = function() coroutine.yield(); return true end
		assert(f.Client:RequestInvite(77).Ok); f:Open(); f:Open()
		equal(#f.Workers, 1)
		f:Advance(10); assert(coroutine.resume(f.Workers[1])); equal(f.NativeCalls, 0)
	end)

	test("resync cancels called and uncalled attempts without replaying native events", function(scope)
		for _, boundary in { "CanSend", "Prompt", "Returned" } do
			local f = fixture(scope); local results = {}; local offerResults = {}
			if boundary == "CanSend" then f.CanSend = function() coroutine.yield(); return true end
			elseif boundary == "Prompt" then f.Prompt = function() coroutine.yield() end end
			assert(f.Client:RequestInvite(77, function(value) table.insert(results, value) end).Ok)
			assert(f.Client:RespondToLocalOffer("offer-1", "Accept", function(value) table.insert(offerResults, value) end).Ok)
			f:Delta(snapshot(true)); f:Open("request-1")
			equal(#f.Workers, 1, "native OpenPrompt must correlate to the invitation, not the separate offer response")
			equal(coroutine.status(f.Workers[1]), if boundary == "Returned" then "dead" else "suspended")
			f:Recover(); f:CompleteCancelled()
			equal(f.Client:GetPromptState().IsBusy, false); equal(results[1], "Cancelled"); equal(offerResults[1], "Cancelled")
			f:ApplyFull(snapshot(true)); f:Resume(); f.Closed:Fire(f.Player, {})
			if coroutine.status(f.Workers[1]) ~= "dead" then assert(coroutine.resume(f.Workers[1])) end
			equal(#f.Queued, 0); equal(#results, 1)
			assert(f.Client:RequestInvite(77).Ok)
		end
	end)

	test("reserve retirement and ownership loss invalidate pending native work", function(scope)
		for _, boundary in { "Reserve", "Owner" } do
			local f = fixture(scope); local results = {}
			f.CanSend = function() coroutine.yield(); return true end
			assert(f.Client:RequestInvite(77, function(value) table.insert(results, value) end).Ok)
			f:Delta(snapshot(true)); f:Open()
			local nextSnapshot = snapshot(false)
			if boundary == "Owner" then nextSnapshot.IsSlotOwner = false; nextSnapshot.CanCreateReserve = false end
			f:Delta(nextSnapshot); equal(f.Client:GetPromptState().IsBusy, false); equal(results[1], "Cancelled")
			assert(coroutine.resume(f.Workers[1])); equal(f.NativeCalls, 0)
			f:Advance(10); equal(#results, 1)
		end
	end)

	test("stop retires the deadline and late platform continuations", function(scope)
		local f = fixture(scope); local results = {}
		f.Prompt = function() coroutine.yield() end
		assert(f.Client:RequestInvite(77, function(value) table.insert(results, value) end).Ok)
		f:Open(); f.Client:Stop(); equal(results[1], "Cancelled")
		assert(coroutine.resume(f.Workers[1])); f:Advance(10); f.Closed:Fire(f.Player, {})
		equal(#f:Messages(FriendsProtocol.MessageTypes.PlatformResult), 0); equal(#results, 1)
		equal(f.Client:GetPromptState().IsBusy, false)
	end)

	test("late cancellation callbacks cannot clear the next attempt after recovery", function(scope)
		local f = fixture(scope)
		assert(f.Client:RequestInvite(77).Ok); f:Recover(); f:ApplyFull(snapshot(false)); f:Resume()
		assert(f.Client:RequestInvite(77).Ok); f:CompleteCancelled(); f:Open("request-1")
		equal(f.NativeCalls, 0); equal(f.Client:GetPromptState().Phase, "Requesting")
		f:Advance(10); equal(f.Client:GetPromptState().IsBusy, false)
	end)

	test("local offer state survives the native preparation deadline", function(scope)
		local f = fixture(scope)
		assert(f.Client:RequestInvite(77).Ok)
		local localOffer = snapshot(true); localOffer.Reserves[1].Kind = "SameServer"; localOffer.CanCreateReserve = false
		f:Delta(localOffer); f:Result("LocalOfferPresented")
		equal(f.Client:GetPromptState().IsBusy, false)
		f:Advance(10); equal(f.Client:GetSnapshot().Snapshot.Reserves[1].Kind, "SameServer")
	end)

	return TestHarness.runAll("FriendsClientRecoveryTestRunner", tests, 10)
end
return Runner
