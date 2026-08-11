--!strict

local Contracts = {}

local AUDIO_PRELOAD_REQUEST_ID = "AudioCatalog.Preload.v1"

function Contracts.IsFixedSpatialPlaybackRecord(value: any): boolean
	return typeof(value) == "table"
		and value.Root == "SpatialAnchor"
		and value.RootClass == "Part"
		and value.Anchored == true
		and value.CanCollide == false
		and value.CanQuery == false
		and value.CanTouch == false
		and value.Transparency == 1
		and value.DirectAudioPlayer == true
		and value.DirectAudioEmitter == true
		and value.DirectWire == true
		and value.DirectChildCount == 3
		and value.WireSource == "Player"
		and value.WireTarget == "Emitter"
		and typeof(value.AnchorTransform) == "table"
end

function Contracts.MakeCueRef(liveAsset: any): any
	assert(typeof(liveAsset) == "table" and typeof(liveAsset.CueId) == "string" and liveAsset.CueId ~= "",
		"Live Audio asset must provide CueId")
	return table.freeze({ CueId = liveAsset.CueId })
end

function Contracts.StoreAcceptedServerPlayback(
	current: any,
	label: any,
	playback: any,
	kind: string,
	liveAssetKey: string
): any
	assert(playback.Accepted == true, `Production {kind} request for '{liveAssetKey}' was rejected`)
	current.ActionSequence += 1
	local resolved = if typeof(label) == "string" and label ~= "" then label else `{kind}-{current.ActionSequence}`
	local prior = current.Handles[resolved]
	if prior ~= nil then pcall(function() prior.Handle:Stop() end) end
	current.Handles[resolved] = nil
	current.AcceptedOneShots[resolved] = nil

	if playback.Handle == nil then
		current.AcceptedOneShots[resolved] = {
			Kind = kind,
			LiveAssetKey = liveAssetKey,
			Sequence = current.ActionSequence,
		}
		return table.freeze({ Label = resolved, HasHandle = false })
	end

	assert(playback.Handle:IsActive(), `Production {kind} handle for '{liveAssetKey}' is inactive`)
	current.Handles[resolved] = {
		Handle = playback.Handle,
		Kind = kind,
		LiveAssetKey = liveAssetKey,
	}
	return table.freeze({ Label = resolved, HasHandle = true })
end

function Contracts.IsOperatorEvidence(value: any): boolean
	if typeof(value) ~= "table" then return false end
	local count = 0
	for key in value do
		if key ~= "Source" and key ~= "Confirmed" and key ~= "Observation" then return false end
		count += 1
	end
	return count == 3
		and value.Source == "OperatorStatement"
		and typeof(value.Confirmed) == "boolean"
		and typeof(value.Observation) == "string"
		and value.Observation ~= ""
		and #value.Observation <= 2048
end

function Contracts.CopyOperatorEvidence(value: any): any
	assert(Contracts.IsOperatorEvidence(value),
		"Human evidence must be an explicit bounded OperatorStatement with Confirmed and Observation")
	return table.freeze({
		Source = "OperatorStatement",
		Confirmed = value.Confirmed,
		Observation = value.Observation,
	})
end

function Contracts.GetAudioPreloadSnapshot(contentPreloader: any?): any
	if contentPreloader == nil or typeof(contentPreloader.GetRequestResult) ~= "function" then
		return {
			Available = false,
			RequestId = AUDIO_PRELOAD_REQUEST_ID,
			ReasonCode = "ServiceNotBound",
		}
	end
	local ok, requestResult = pcall(function()
		return contentPreloader:GetRequestResult(AUDIO_PRELOAD_REQUEST_ID)
	end)
	if not ok then
		return {
			Available = true,
			Completed = false,
			RequestId = AUDIO_PRELOAD_REQUEST_ID,
			ReasonCode = "InspectionFailed",
		}
	end
	if requestResult == nil then
		return {
			Available = true,
			Completed = false,
			RequestId = AUDIO_PRELOAD_REQUEST_ID,
			ReasonCode = "RequestUnavailable",
		}
	end
	if typeof(requestResult) ~= "table" or getmetatable(requestResult) ~= nil
		or typeof(requestResult.Failures) ~= "table" or getmetatable(requestResult.Failures) ~= nil
	then
		return {
			Available = true,
			Completed = true,
			RequestId = AUDIO_PRELOAD_REQUEST_ID,
			ReasonCode = "InvalidResult",
		}
	end
	local failures = {}
	local failureCount = 0
	local maximumIndex = 0
	local index, failure = next(requestResult.Failures)
	while index ~= nil do
		if typeof(index) ~= "number" or index ~= math.floor(index) or index < 1
			or typeof(failure) ~= "table"
			or getmetatable(failure) ~= nil
			or typeof(failure.ContentId) ~= "string"
			or typeof(failure.Status) ~= "string"
		then
			return {
				Available = true,
				Completed = true,
				RequestId = AUDIO_PRELOAD_REQUEST_ID,
				ReasonCode = "InvalidResult",
			}
		end
		failures[index] = {
			ContentId = failure.ContentId,
			Status = failure.Status,
		}
		failureCount += 1
		maximumIndex = math.max(maximumIndex, index)
		index, failure = next(requestResult.Failures, index)
	end
	if failureCount ~= maximumIndex then
		return {
			Available = true,
			Completed = true,
			RequestId = AUDIO_PRELOAD_REQUEST_ID,
			ReasonCode = "InvalidResult",
		}
	end
	return {
		Available = true,
		Completed = true,
		RequestId = AUDIO_PRELOAD_REQUEST_ID,
		RequestedTargets = requestResult.RequestedTargets,
		ResolvedContent = requestResult.ResolvedContent,
		Loaded = requestResult.Loaded,
		Failed = requestResult.Failed,
		Failures = failures,
	}
end

Contracts.AudioPreloadRequestId = AUDIO_PRELOAD_REQUEST_ID

return table.freeze(Contracts)
