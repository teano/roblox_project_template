--!strict

local Owner = {}
Owner.__index = Owner

function Owner.new(pooling: any)
	local poolParent = Instance.new("Folder")
	poolParent.Name = "UiWindowPool"
	return setmetatable({
		_pooling = pooling,
		_poolParent = poolParent,
		_pools = {} :: { [string]: any },
		_destroyed = false,
	}, Owner)
end

function Owner:_getPool(definition: any, template: GuiObject, constructionContext: any)
	local existing = self._pools[definition.WindowId]
	if existing ~= nil then
		return existing
	end
	local poolParent = self._poolParent
	local adapter = {
		Create = function()
			local root = template:Clone()
			root.Parent = nil
			local view = definition.CreateView(root, constructionContext)
			assert(view ~= nil and view.Root == root, "Window CreateView must own the cloned root")
			return {
				View = view,
				Root = root,
				ReuseState = "clean",
				CurrentUseToken = nil,
			}
		end,
		Acquire = function(record: any, _context: any)
			assert(record.ReuseState == "clean" and record.CurrentUseToken == nil, "Pooled window is contaminated")
			record.Root.Parent = nil
			record.CurrentUseToken = {}
			record.ReuseState = "dirty"
		end,
		Release = function(record: any)
			assert(record.ReuseState == "clean" and record.CurrentUseToken == nil, "Pooled window cleanup is incomplete")
			record.Root.Parent = poolParent
		end,
		Destroy = function(record: any)
			pcall(function()
				if typeof(record.View.Destroy) == "function" then
					record.View:Destroy()
				end
			end)
			record.Root:Destroy()
		end,
		IsValid = function(record: any)
			return typeof(record) == "table" and typeof(record.Root) == "Instance" and pcall(function()
				local parent = record.Root.Parent
				record.Root.Parent = parent
			end)
		end,
	}
	local pool = self._pooling:CreatePool(`Ui.Window/{definition.WindowId}`, adapter, definition.PoolOptions)
	self._pools[definition.WindowId] = pool
	return pool
end

function Owner:CreateCandidate(definition: any, template: GuiObject, constructionContext: any)
	if self._destroyed then
		return nil, { Code = "UiSystemDestroyed", WindowId = definition.WindowId }
	end
	if definition.LifecyclePolicy == "Destroy" then
		local root = template:Clone()
		root.Parent = nil
		local ok, view = xpcall(function()
			return definition.CreateView(root, constructionContext)
		end, debug.traceback)
		if not ok or view == nil or view.Root ~= root then
			root:Destroy()
			return nil, { Code = "ViewFactoryFailed", WindowId = definition.WindowId }
		end
		return {
			Definition = definition,
			View = view,
			Root = root,
			Pool = nil,
			Lease = nil,
			UseToken = nil,
		}, nil
	end

	local ok, poolOrError = xpcall(function()
		return self:_getPool(definition, template, constructionContext)
	end, debug.traceback)
	if not ok then
		return nil, { Code = "ViewFactoryFailed", WindowId = definition.WindowId }
	end
	local pool = poolOrError
	local acquired, leaseOrError = xpcall(function()
		return pool:Acquire({})
	end, debug.traceback)
	if not acquired then
		return nil, { Code = "ViewFactoryFailed", WindowId = definition.WindowId }
	end
	local lease = leaseOrError
	return {
		Definition = definition,
		View = lease.Object.View,
		Root = lease.Object.Root,
		Pool = pool,
		Lease = lease,
		UseToken = lease.Object.CurrentUseToken,
	}, nil
end

function Owner:ReleaseCandidate(candidate: any, cleanupSucceeded: boolean)
	if candidate.Pool == nil then
		candidate.Root:Destroy()
		return cleanupSucceeded
	end
	local record = candidate.Lease.Object
	if record.CurrentUseToken == candidate.UseToken then
		record.CurrentUseToken = nil
		record.ReuseState = if cleanupSucceeded then "clean" else "failed"
	end
	local released = candidate.Pool:TryReleaseToPool(candidate.Lease)
	return released
end

function Owner:Destroy()
	if self._destroyed then
		return
	end
	self._destroyed = true
	for windowId in self._pools do
		self._pooling:RemovePool(`Ui.Window/{windowId}`)
	end
	table.clear(self._pools)
	self._poolParent:Destroy()
end

return Owner
