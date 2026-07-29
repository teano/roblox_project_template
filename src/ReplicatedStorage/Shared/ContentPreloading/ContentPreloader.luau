--!strict

local Signal = require(script.Parent.Parent.Util.Signal)
local Logger = require(script.Parent.Parent.Util.Logger)
local AssetTypes = require(script.Parent.Parent.Assets.AssetTypes)
local ContentPreloadTypes = require(script.Parent.ContentPreloadTypes)

type AssetQuery = AssetTypes.AssetQuery
type AssetRegistry = AssetTypes.AssetRegistry
type PreloadTarget = ContentPreloadTypes.PreloadTarget
type PreloadOptions = ContentPreloadTypes.PreloadOptions
type PreloadFailure = ContentPreloadTypes.PreloadFailure
type PreloadProgress = ContentPreloadTypes.PreloadProgress
type PreloadResult = ContentPreloadTypes.PreloadResult
type FailurePolicy = ContentPreloadTypes.FailurePolicy

type RequestRecord = {
	State: "Loading" | "Completed",
	Targets: { PreloadTarget },
	FailurePolicy: FailurePolicy,
	Completion: any,
	Result: PreloadResult?,
	Error: string?,
}

local ContentPreloader = {}
ContentPreloader.__index = ContentPreloader

local function getStatusName(status: any): string
	if typeof(status) == "EnumItem" then
		return status.Name
	end
	return tostring(status)
end

local function normalizeTargets(targets: { PreloadTarget }): { PreloadTarget }
	assert(typeof(targets) == "table", "Content preload targets must be a table")

	local result: { PreloadTarget } = {}
	local seen: { [any]: boolean } = {}
	for index, target in targets do
		local targetType = typeof(target)
		assert(
			targetType == "Instance" or (targetType == "string" and target ~= ""),
			`Content preload target at index {index} must be an Instance or non-empty content ID`
		)
		if not seen[target] then
			seen[target] = true
			table.insert(result, target)
		end
	end
	return result
end

local function targetsMatch(first: { PreloadTarget }, second: { PreloadTarget }): boolean
	if #first ~= #second then
		return false
	end
	for index, target in first do
		if second[index] ~= target then
			return false
		end
	end
	return true
end

local function getFailurePolicy(options: PreloadOptions?): FailurePolicy
	local failurePolicy = if options and options.FailurePolicy then options.FailurePolicy else "Warn"
	assert(
		failurePolicy == "Warn" or failurePolicy == "Fail",
		"Content preload FailurePolicy must be 'Warn' or 'Fail'"
	)
	return failurePolicy
end

local function getRequestId(options: PreloadOptions?): string?
	local requestId = if options then options.RequestId else nil
	if requestId ~= nil then
		assert(typeof(requestId) == "string" and requestId ~= "", "Content preload RequestId must be a non-empty string")
	end
	return requestId
end

function ContentPreloader.new(deps: {
	Assets: AssetRegistry,
	ContentProvider: any,
	Logger: any?,
})
	assert(typeof(deps) == "table", "ContentPreloader dependencies must be a table")
	assert(deps.Assets ~= nil, "ContentPreloader requires Assets")
	assert(deps.ContentProvider ~= nil, "ContentPreloader requires ContentProvider")
	assert(typeof(deps.ContentProvider.PreloadAsync) == "function", "ContentProvider must expose PreloadAsync")

	return setmetatable({
		_assets = deps.Assets,
		_contentProvider = deps.ContentProvider,
		_logger = deps.Logger or Logger.new("ContentPreloader", "info"),
		_requests = {} :: { [string]: RequestRecord },
		Progress = Signal.new(),
		RequestCompleted = Signal.new(),
	}, ContentPreloader)
end

function ContentPreloader:_getCatalogPaths(targets: { PreloadTarget }): { string }
	local paths = {}
	for _, target in targets do
		if typeof(target) == "Instance" then
			local path = self._assets:GetPath(target)
			if path ~= nil then
				table.insert(paths, path)
			end
		end
	end
	table.sort(paths)
	return table.freeze(paths)
end

function ContentPreloader:_reuseRequest(
	requestId: string,
	targets: { PreloadTarget },
	failurePolicy: FailurePolicy
): PreloadResult?
	local existing = self._requests[requestId]
	if existing == nil then
		return nil
	end

	assert(
		targetsMatch(existing.Targets, targets),
		`Content preload request '{requestId}' was reused with different targets`
	)
	assert(
		existing.FailurePolicy == failurePolicy,
		`Content preload request '{requestId}' was reused with a different FailurePolicy`
	)

	if existing.State == "Loading" then
		existing.Completion:Wait()
	end
	if existing.Error ~= nil then
		error(existing.Error, 3)
	end
	return existing.Result :: PreloadResult
end

function ContentPreloader:Preload(targets: { PreloadTarget }, options: PreloadOptions?): PreloadResult
	local normalizedTargets = normalizeTargets(targets)
	local failurePolicy = getFailurePolicy(options)
	local requestId = getRequestId(options)

	if requestId ~= nil then
		local existingResult = self:_reuseRequest(requestId, normalizedTargets, failurePolicy)
		if existingResult ~= nil then
			return existingResult
		end
	end

	local record: RequestRecord? = nil
	if requestId ~= nil then
		record = {
			State = "Loading",
			Targets = table.freeze(table.clone(normalizedTargets)),
			FailurePolicy = failurePolicy,
			Completion = Signal.new(),
			Result = nil,
			Error = nil,
		}
		self._requests[requestId] = record
	end

	local startedAt = os.clock()
	local loaded = 0
	local failed = 0
	local failures: { PreloadFailure } = {}
	local resolvedContentIds: { [string]: boolean } = {}

	local function onAssetResolved(contentId: any, assetFetchStatus: any)
		local renderedContentId = tostring(contentId)
		if resolvedContentIds[renderedContentId] then
			return
		end
		resolvedContentIds[renderedContentId] = true

		local status = getStatusName(assetFetchStatus)
		if assetFetchStatus == Enum.AssetFetchStatus.Success then
			loaded += 1
		else
			failed += 1
			table.insert(failures, table.freeze({
				ContentId = renderedContentId,
				Status = status,
				Error = nil,
			}))
		end

		local progress: PreloadProgress = table.freeze({
			RequestId = requestId,
			RequestedTargets = #normalizedTargets,
			ResolvedContent = loaded + failed,
			Loaded = loaded,
			Failed = failed,
			ContentId = renderedContentId,
			Status = status,
		})
		self.Progress:Fire(progress)
	end

	local preloadOk = true
	local preloadError: string? = nil
	if #normalizedTargets > 0 then
		local ok, err = xpcall(function()
			self._contentProvider:PreloadAsync(normalizedTargets, onAssetResolved)
		end, debug.traceback)
		if not ok then
			preloadOk = false
			preloadError = tostring(err)
			failed += 1
			table.insert(failures, table.freeze({
				ContentId = "<request>",
				Status = "Exception",
				Error = preloadError,
			}))
		end
	end

	table.sort(failures, function(first, second)
		if first.ContentId == second.ContentId then
			return first.Status < second.Status
		end
		return first.ContentId < second.ContentId
	end)

	local result: PreloadResult = table.freeze({
		RequestId = requestId,
		RequestedTargets = #normalizedTargets,
		RequestedCatalogPaths = self:_getCatalogPaths(normalizedTargets),
		ResolvedContent = loaded + failed,
		Loaded = loaded,
		Failed = failed,
		Failures = table.freeze(failures),
		DurationSeconds = os.clock() - startedAt,
	})

	local terminalError: string? = nil
	if failurePolicy == "Fail" and failed > 0 then
		terminalError = if preloadOk
			then `Content preload request '{requestId or "<anonymous>"}' failed for {failed} content item(s)`
			else `Content preload request '{requestId or "<anonymous>"}' raised:\n{preloadError}`
	end

	if record ~= nil then
		record.State = "Completed"
		record.Result = result
		record.Error = terminalError
		record.Completion:Fire()
		record.Completion:Destroy()
	end

	self.RequestCompleted:Fire(result)
	if failed > 0 then
		self._logger:Warn("content_preload_completed_with_failures", {
			RequestId = requestId or "<anonymous>",
			RequestedTargets = #normalizedTargets,
			Loaded = loaded,
			Failed = failed,
		})
	else
		self._logger:Info("content_preload_completed", {
			RequestId = requestId or "<anonymous>",
			RequestedTargets = #normalizedTargets,
			Loaded = loaded,
		})
	end

	if terminalError ~= nil then
		error(terminalError, 2)
	end
	return result
end

function ContentPreloader:PreloadQuery(query: AssetQuery?, options: PreloadOptions?): PreloadResult
	local targets: { PreloadTarget } = {}
	for _, instance in self._assets:FindAll(query) do
		table.insert(targets, instance)
	end
	return self:Preload(targets, options)
end

function ContentPreloader:PreloadByKeys(keys: { string }, options: PreloadOptions?): PreloadResult
	assert(typeof(keys) == "table", "Content preload keys must be a table")

	local targets: { PreloadTarget } = {}
	for index, key in keys do
		assert(typeof(key) == "string" and key ~= "", `Content preload key at index {index} must be non-empty`)
		table.insert(targets, self._assets:RequireByKey(key))
	end
	table.sort(targets, function(first, second)
		return (self._assets:GetPath(first :: Instance) or "") < (self._assets:GetPath(second :: Instance) or "")
	end)
	return self:Preload(targets, options)
end

function ContentPreloader:GetRequestResult(requestId: string): PreloadResult?
	assert(typeof(requestId) == "string" and requestId ~= "", "Content preload RequestId must be a non-empty string")
	local request = self._requests[requestId]
	if request == nil or request.State ~= "Completed" then
		return nil
	end
	return request.Result
end

return ContentPreloader
