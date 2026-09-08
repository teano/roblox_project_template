--!strict

local UiActionIds = require(script.Parent.Actions.UiActionIds)
local UiSyncHookGuard = require(script.Parent.Internal.UiSyncHookGuard)
local WindowHandle = require(script.Parent.WindowHandle)
local BaseWindowView = require(script.Parent.Windows.BaseWindowView)

local Navigator = {}
Navigator.__index = Navigator

local DEADLINE_SECONDS = 3

local function failure(code: string, windowId: string?, generation: number?, phase: string?)
	return { Kind = "Error", Error = { Code = code, WindowId = windowId, OperationGeneration = generation, Phase = phase } }
end

local function runHook(self: any, callback: () -> (), deadline: number, late: (() -> ())?): string
	local wake = Instance.new("BindableEvent")
	local settled = false
	local hookFailed = false
	local timedOut = false
	self._spawn(function()
		hookFailed = not xpcall(callback, debug.traceback)
		settled = true
		pcall(function() wake:Fire() end)
		if timedOut and late then late() end
	end)
	if not settled then
		local remaining = deadline - self._clock()
		if remaining > 0 then
			self._delay(remaining, function() pcall(function() wake:Fire() end) end)
			self._wait(wake.Event, function() return settled end)
		end
	end
	if not settled then
		timedOut = true
		wake:Destroy()
		return "Timeout"
	end
	wake:Destroy()
	return if hookFailed then "Error" else "Success"
end

function Navigator.new(dependencies: any)
	local quarantine = Instance.new("Folder")
	quarantine.Name = "UiWindowQuarantine"
	return setmetatable({
		_config = dependencies.Config,
		_loader = dependencies.Loader,
		_poolOwner = dependencies.PoolOwner,
		_windowHost = dependencies.WindowHost,
		_elements = dependencies.Elements,
		_guiService = dependencies.GuiService,
		_clock = dependencies.Clock or os.clock,
		_spawn = dependencies.Spawn or task.spawn,
		_delay = dependencies.Delay or task.delay,
		_wait = dependencies.Wait or function(signal: RBXScriptSignal, _done: () -> boolean) signal:Wait() end,
		_logger = dependencies.Logger,
		_stack = {},
		_operation = nil,
		_nextGeneration = 0,
		_registrations = {} :: { [any]: any },
		_quarantined = {} :: { [any]: boolean },
		_quarantine = quarantine,
		_port = nil,
		_destroyed = false,
	}, Navigator)
end

function Navigator:_top()
	return self._stack[#self._stack]
end

function Navigator:_getPort()
	if self._port then return self._port end
	local owner = self
	self._port = table.freeze({
		AddWindowAsync = function(_p: any, caller: any, id: string, model: unknown) return owner:AddWindowAsync(caller, id, model) end,
		AddWindowTypedAsync = function(_p: any, caller: any, definition: any, model: any) return owner:AddWindowTypedAsync(caller, definition, model) end,
		CloseWindowAsync = function(_p: any, caller: any, id: string?, model: unknown?) return owner:CloseWindowAsync(caller, id, model) end,
		CloseWindowTypedAsync = function(_p: any, caller: any, definition: any, model: any) return owner:CloseWindowTypedAsync(caller, definition, model) end,
	})
	return self._port
end

function Navigator:_diagnose(name: string, fields: any)
	if self._logger and typeof(self._logger.Warn) == "function" then pcall(function() self._logger:Warn(name, fields) end) end
end

function Navigator:_reserve(id: string, phase: string)
	self._nextGeneration += 1
	local operation = { Generation = self._nextGeneration, WindowId = id, Phase = phase, Deadline = self._clock() + DEADLINE_SECONDS }
	self._operation = operation
	return operation
end

function Navigator:_release(operation: any)
	if self._operation == operation then self._operation = nil end
end

function Navigator:_ownsOperation(operation: any): boolean
	local current = self._operation
	return not self._destroyed
		and current == operation
		and current.Generation == operation.Generation
end

function Navigator:_ownsTransition(operation: any, transition: any): boolean
	return self:_ownsOperation(operation)
		and operation.Transition == transition
		and transition.Active
end

function Navigator:_cleanup(candidate: any): boolean
	local result = UiSyncHookGuard.call("Clear", function() return candidate.View:Clear() end)
	local clean = result.Kind == "Success" and typeof(result.Value) == "table" and result.Value.Kind == "Success"
	candidate.Root.Parent = nil
	local released = self._poolOwner:ReleaseCandidate(candidate, clean)
	if not clean or not released then self:_diagnose("ui_window_cleanup_failed", { WindowId = candidate.Definition.WindowId }) end
	return clean and released
end

function Navigator:_emit(entry: any, actionId: string)
	local result = entry.View:_EmitLifecycle(actionId)
	if result.Kind == "Error" then
		self:_diagnose("UiLifecycleIdentityInvariant", { WindowId = entry.Definition.WindowId, OperationGeneration = entry.Generation, Phase = actionId, Code = "InvalidUIElementId", LifecyclePolicy = entry.Definition.LifecyclePolicy, Quarantined = false })
	end
end

function Navigator:_finishQuarantine(entry: any)
	if entry.State ~= "Quarantined" or self._destroyed then return end
	self._quarantined[entry] = nil
	self:_cleanup(entry.Candidate)
	entry.State = "Disposed"
end

function Navigator:_dispose(entry: any, hookState: string): boolean
	if hookState == "Timeout" and entry.Candidate.Pool ~= nil then
		entry.State = "Quarantined"
		entry.View:_SetNavigationActive(false)
		entry.Candidate.Root.Parent = self._quarantine
		self._quarantined[entry] = true
		if entry.HookCompleted then self:_finishQuarantine(entry) end
		return true
	end
	entry.State = "Disposed"
	return self:_cleanup(entry.Candidate)
end

function Navigator:_binding(key: any)
	local owner = self
	return table.freeze({
		CanEmitAction = function()
			local record = owner._registrations[key]
			return record ~= nil and record.Entry == owner:_top() and record.Entry.State == "Active" and not record.Entry.View._inputBlocker:IsEffective()
		end,
		GetGuiService = function() return owner._guiService end,
	})
end

function Navigator:_prepare(definition: any, model: unknown, operation: any, typedDefinition: any?)
	local template, loadError = self._loader:GetTemplate(definition, operation.Deadline)
	if template == nil then return nil, { Kind = "Error", Error = loadError } end
	if self._operation ~= operation or self._clock() >= operation.Deadline then return nil, failure("Timeout", definition.WindowId, operation.Generation, "Prepare") end
	local candidate, createError = self._poolOwner:CreateCandidate(definition, template, table.freeze({ Navigator = self:_getPort(), Elements = self._elements }))
	if candidate == nil then return nil, { Kind = "Error", Error = createError } end
	if typedDefinition and typedDefinition ~= definition then
		local clean = self:_cleanup(candidate)
		return nil, if clean
			then failure("TypedDefinitionMismatch", definition.WindowId, operation.Generation, "Cast")
			else failure("CleanupFailed", definition.WindowId, operation.Generation, "Cleanup")
	end
	local cast = UiSyncHookGuard.call("TryCastView", function() return definition.TryCastView(candidate.View) end)
	if cast.Kind ~= "Success" or cast.Value == nil then
		local clean = self:_cleanup(candidate)
		return nil, if clean
			then failure("TypedDefinitionMismatch", definition.WindowId, operation.Generation, "Cast")
			else failure("CleanupFailed", definition.WindowId, operation.Generation, "Cleanup")
	end
	local key = {}
	local entry = { Definition = definition, View = candidate.View, Candidate = candidate, Registration = key, Generation = operation.Generation, State = "Preparing", Visible = false, PauseHandle = nil }
	entry.View:_SetNavigatorBinding(self, self:_binding(key))
	local initialized = UiSyncHookGuard.call("Initialize", function() return definition.InitializeView(cast.Value, model) end)
	if initialized.Kind ~= "Success" or typeof(initialized.Value) ~= "table" or initialized.Value.Kind ~= "Success" then
		local code = if initialized.Kind == "Success" and typeof(initialized.Value) == "table" and initialized.Value.Kind == "Error" and typeof(initialized.Value.Error) == "table" then initialized.Value.Error.Code else "InitializeFailed"
		local clean = self:_cleanup(candidate)
		return nil, if clean
			then failure(code, definition.WindowId, operation.Generation, "Initialize")
			else failure("CleanupFailed", definition.WindowId, operation.Generation, "Cleanup")
	end
	local configured = entry.View:_ConfigureForDefinition(definition)
	if configured.Kind == "Error" then
		local clean = self:_cleanup(candidate)
		return nil, if clean
			then failure(configured.Error.Code, definition.WindowId, operation.Generation, "Background")
			else failure("CleanupFailed", definition.WindowId, operation.Generation, "Cleanup")
	end
	return entry, nil
end

function Navigator:_has(id: string): boolean
	for _, entry in self._stack do if entry.Definition.WindowId == id then return true end end
	return false
end

function Navigator:_admit(caller: any?, id: string)
	local top = self:_top()
	if self._operation then
		if top and top.Definition.WindowId == id and self._operation.WindowId == id then return { Kind = "NoOp" } end
		return failure("Busy", id, self._operation.Generation)
	end
	if caller == nil then
		if top then
			return if self:_has(id) then failure("DuplicateWindowId", id) else failure("NotActiveWindow", id)
		end
	elseif top == nil or top.View ~= caller or top.State ~= "Active" then
		return failure("NotActiveWindow", id)
	end
	if self:_has(id) then return failure("DuplicateWindowId", id) end
	return nil
end

function Navigator:_pause(entry: any)
	entry.State = "Paused"
	entry.PauseHandle = entry.View:_AcquireSystemInputBlock()
	entry.View:_SetNavigationActive(false)
	local guarded = UiSyncHookGuard.call("Pause", function() entry.View:Pause() end)
	if guarded.Kind ~= "Success" then
		self:_diagnose("ui_window_hook_failed", {
			WindowId = entry.Definition.WindowId,
			Phase = "Pause",
			Reason = guarded.Kind,
		})
	end
	self:_emit(entry, UiActionIds.WindowPaused)
end

function Navigator:_resume(entry: any)
	entry.State = "Active"
	local guarded = UiSyncHookGuard.call("Resume", function() entry.View:Resume() end)
	if guarded.Kind ~= "Success" then
		self:_diagnose("ui_window_hook_failed", {
			WindowId = entry.Definition.WindowId,
			Phase = "Resume",
			Reason = guarded.Kind,
		})
	end
	self:_emit(entry, UiActionIds.WindowResumed)
	self:_recompute()
	if entry.PauseHandle then entry.PauseHandle:Release(); entry.PauseHandle = nil end
	entry.View:_SetNavigationActive(true)
end

function Navigator:_recompute()
	local first = 1
	for index = #self._stack, 1, -1 do if self._stack[index].Definition.VisibilityPolicy == "HideBelow" then first = index; break end end
	for index, entry in self._stack do
		local visible = index >= first
		if entry.Visible ~= visible then
			entry.Visible = visible
			entry.Candidate.Root.Visible = visible
			self:_emit(entry, if visible then UiActionIds.WindowShown else UiActionIds.WindowHidden)
		end
	end
end

function Navigator:_commit(entry: any)
	entry.State = "Opening"
	entry.Candidate.Root.Parent = self._windowHost
	table.insert(self._stack, entry)
	self._registrations[entry.Registration] = { Entry = entry, Generation = entry.Generation }
end

function Navigator:_invalidate(entry: any)
	self._registrations[entry.Registration] = nil
	entry.View:_SetNavigationActive(false)
	if entry.PauseHandle then entry.PauseHandle:Release(); entry.PauseHandle = nil end
end

function Navigator:_transition(entry: any, operation: any, phase: string): (string, any)
	local token = entry.View:_AcquireSystemInputBlock()
	local method = entry.View[phase]
	local base = BaseWindowView[phase]
	local state = "Success"
	local transition = {
		Active = true,
		Entry = entry,
		Generation = operation.Generation,
		Phase = phase,
		AllowLateCleanup = false,
	}
	operation.Transition = transition
	if method ~= base then
		state = runHook(self, function() method(entry.View) end, operation.Deadline, function()
			if self._destroyed or not transition.AllowLateCleanup then return end
			entry.HookCompleted = true
			if entry.State == "Quarantined" then self:_finishQuarantine(entry) end
		end)
	end
	local ownsTransition = self:_ownsTransition(operation, transition)
	local expired = self._clock() >= operation.Deadline
	if not ownsTransition then
		return "Stale", token
	end
	operation.Transition = nil
	transition.Active = false
	if state == "Timeout" then
		transition.AllowLateCleanup = true
	elseif expired then
		entry.HookCompleted = true
		state = "Timeout"
	end
	return state, token
end

function Navigator:_add(caller: any?, definition: any, model: unknown, typedDefinition: any?)
	local rejected = self:_admit(caller, definition.WindowId)
	if rejected then return rejected end
	local operation = self:_reserve(definition.WindowId, "Open")
	local entry, prepareError = self:_prepare(definition, model, operation, typedDefinition)
	if not entry then self:_release(operation); return prepareError end
	local previous = self:_top()
	if previous then self:_pause(previous) end
	self:_commit(entry)
	local openState, transitionHandle = self:_transition(entry, operation, "Open")
	if openState == "Stale" then
		transitionHandle:Release()
		return failure("Timeout", definition.WindowId, operation.Generation, "Open")
	end
	if openState ~= "Success" then
		transitionHandle:Release()
		table.remove(self._stack); self:_invalidate(entry)
		local clean = self:_dispose(entry, openState)
		if previous then self:_resume(previous) else self:_recompute() end
		self:_release(operation)
		if not clean then
			return failure("CleanupFailed", definition.WindowId, operation.Generation, "Cleanup")
		end
		return failure(if openState == "Timeout" then "Timeout" else "OpenFailed", definition.WindowId, operation.Generation, "Open")
	end
	entry.State = "Active"
	self:_emit(entry, UiActionIds.WindowOpened)
	self:_recompute()
	transitionHandle:Release()
	entry.View:_SetNavigationActive(true)
	self:_release(operation)
	return { Kind = "Success", Value = WindowHandle.new(self, entry.Registration, definition.WindowId, entry.Generation, definition.TryCastView) }
end

function Navigator:AddExternal(id: string, model: unknown)
	local definition = self._config.ByWindowId[id]
	if not definition then return failure("UnknownWindowId", id) end
	return self:_add(nil, definition, model, nil)
end

function Navigator:AddExternalTyped(definition: any, model: any)
	local canonical = if typeof(definition) == "table" then self._config.ByWindowId[definition.WindowId] else nil
	if not canonical or canonical ~= definition then return failure("TypedDefinitionMismatch", if typeof(definition) == "table" then definition.WindowId else nil) end
	return self:_add(nil, canonical, model, definition)
end

function Navigator:AddWindowAsync(caller: any, id: string, model: unknown)
	local definition = self._config.ByWindowId[id]
	if not definition then return failure("UnknownWindowId", id) end
	return self:_add(caller, definition, model, nil)
end

function Navigator:AddWindowTypedAsync(caller: any, definition: any, model: any)
	local canonical = if typeof(definition) == "table" then self._config.ByWindowId[definition.WindowId] else nil
	if not canonical or canonical ~= definition then return failure("TypedDefinitionMismatch", if typeof(definition) == "table" then definition.WindowId else nil) end
	return self:_add(caller, canonical, model, definition)
end

function Navigator:_removeTop(entry: any, transitionState: string): boolean
	table.remove(self._stack)
	self:_invalidate(entry)
	self:_emit(entry, UiActionIds.WindowClosed)
	return self:_dispose(entry, transitionState)
end

function Navigator:_close(caller: any)
	local top = self:_top()
	if self._operation then return if top and top.View == caller then { Kind = "NoOp" } else failure("Busy", if top then top.Definition.WindowId else nil, self._operation.Generation) end
	if not top or top.View ~= caller then return failure("NotActiveWindow", if top then top.Definition.WindowId else nil) end
	local operation = self:_reserve(top.Definition.WindowId, "Close")
	local state, transitionHandle = self:_transition(top, operation, "Close")
	if state == "Stale" then
		transitionHandle:Release()
		return failure("Timeout", top.Definition.WindowId, operation.Generation, "Close")
	end
	transitionHandle:Release()
	local clean = self:_removeTop(top, state)
	local lower = self:_top(); if lower then self:_resume(lower) else self:_recompute() end
	self:_release(operation)
	if state == "Success" and clean then return { Kind = "Success" } end
	if not clean then
		return failure("CleanupFailed", top.Definition.WindowId, operation.Generation, "Cleanup")
	end
	return failure(if state == "Timeout" then "Timeout" elseif state == "Error" then "CloseFailed" else "CleanupFailed", top.Definition.WindowId, operation.Generation, "Close")
end

function Navigator:_replace(caller: any, definition: any, model: unknown, typedDefinition: any?)
	local rejected = self:_admit(caller, definition.WindowId)
	if rejected then return rejected end
	local old = self:_top()
	local operation = self:_reserve(definition.WindowId, "Replace")
	local candidate, prepareError = self:_prepare(definition, model, operation, typedDefinition)
	if not candidate then self:_release(operation); return prepareError end
	operation.Prepared = candidate
	local closeState, closeHandle = self:_transition(old, operation, "Close")
	if closeState == "Stale" then
		closeHandle:Release()
		return failure("Timeout", old.Definition.WindowId, operation.Generation, "Close")
	end
	closeHandle:Release()
	local oldClean = self:_removeTop(old, closeState)
	if closeState ~= "Success" or not oldClean then
		operation.Prepared = nil
		local candidateClean = self:_cleanup(candidate.Candidate)
		local lower = self:_top(); if lower then self:_resume(lower) else self:_recompute() end
		self:_release(operation)
		if not candidateClean then
			return failure("CleanupFailed", definition.WindowId, operation.Generation, "Cleanup")
		end
		if not oldClean then
			return failure("CleanupFailed", old.Definition.WindowId, operation.Generation, "Cleanup")
		end
		return failure(
			if closeState == "Timeout" then "Timeout" elseif closeState == "Error" then "CloseFailed" else "CleanupFailed",
			old.Definition.WindowId,
			operation.Generation,
			"Close"
		)
	end
	operation.Prepared = nil
	self:_commit(candidate)
	local openState, openHandle = self:_transition(candidate, operation, "Open")
	if openState == "Stale" then
		openHandle:Release()
		return failure("Timeout", definition.WindowId, operation.Generation, "Open")
	end
	if openState ~= "Success" then
		openHandle:Release()
		table.remove(self._stack); self:_invalidate(candidate)
		local clean = self:_dispose(candidate, openState)
		local lower = self:_top(); if lower then self:_resume(lower) else self:_recompute() end
		self:_release(operation)
		if not clean then
			return failure("CleanupFailed", definition.WindowId, operation.Generation, "Cleanup")
		end
		return failure(if openState == "Timeout" then "Timeout" else "OpenFailed", definition.WindowId, operation.Generation, "Open")
	end
	candidate.State = "Active"
	self:_emit(candidate, UiActionIds.WindowOpened)
	self:_recompute()
	openHandle:Release()
	candidate.View:_SetNavigationActive(true)
	self:_release(operation)
	return { Kind = "Success", Value = WindowHandle.new(self, candidate.Registration, definition.WindowId, candidate.Generation, definition.TryCastView) }
end

function Navigator:CloseWindowAsync(caller: any, nextId: string?, model: unknown?)
	if nextId == nil then return self:_close(caller) end
	local definition = self._config.ByWindowId[nextId]
	if not definition then return failure("UnknownWindowId", nextId) end
	return self:_replace(caller, definition, model, nil)
end

function Navigator:CloseWindowTypedAsync(caller: any, definition: any, model: any)
	local canonical = if typeof(definition) == "table" then self._config.ByWindowId[definition.WindowId] else nil
	if not canonical or canonical ~= definition then return failure("TypedDefinitionMismatch", if typeof(definition) == "table" then definition.WindowId else nil) end
	return self:_replace(caller, canonical, model, definition)
end

function Navigator:_IsHandleValid(key: any, generation: number): boolean
	local record = self._registrations[key]
	return record ~= nil and record.Generation == generation
end

function Navigator:_IsHandleActive(key: any, generation: number): boolean
	local record = self._registrations[key]
	return record ~= nil and record.Generation == generation and record.Entry == self:_top() and record.Entry.State == "Active"
end

function Navigator:_GetHandleView(key: any, generation: number)
	local record = self._registrations[key]
	return if record ~= nil and record.Generation == generation then record.Entry.View else nil
end

function Navigator:Destroy()
	if self._destroyed then return end
	self._destroyed = true
	local operation = self._operation
	self._operation = nil
	for index = #self._stack, 1, -1 do local entry = self._stack[index]; self:_invalidate(entry); self:_cleanup(entry.Candidate) end
	table.clear(self._stack)
	if operation ~= nil and operation.Prepared ~= nil then
		self:_cleanup(operation.Prepared.Candidate)
		operation.Prepared = nil
	end
	for entry in self._quarantined do entry.State = "Disposed" end
	table.clear(self._quarantined)
	table.clear(self._registrations)
	self._quarantine:Destroy()
	self._port = nil
end

return Navigator
