--!strict

local Logger = require(game:GetService("ReplicatedStorage").Shared.Util.Logger)

local StatisticsClientFactController = {}
StatisticsClientFactController.__index = StatisticsClientFactController

local DIAGNOSTIC_COOLDOWN_SECONDS = 1

function StatisticsClientFactController.new(deps: {
	Statistics: any,
	Communication: any,
	Definitions: { any },
	Logger: any?,
	Clock: (() -> number)?,
})
	local seen: { [string]: boolean } = {}
	local definitions = table.clone(deps.Definitions)
	for _, definition in definitions do
		assert(typeof(definition) == "table", "Statistics client fact definition must be a table")
		assert(typeof(definition.MessageType) == "string" and definition.MessageType ~= "", "MessageType required")
		assert(typeof(definition.Validate) == "function", "Fact validator required")
		assert(typeof(definition.Map) == "function", "Fact mapper required")
		assert(definition.IsEligible == nil or typeof(definition.IsEligible) == "function", "IsEligible must be a function")
		assert(not seen[definition.MessageType], `Duplicate fact message '{definition.MessageType}'`)
		seen[definition.MessageType] = true
	end
	return setmetatable({
		_statistics = deps.Statistics,
		_communication = deps.Communication,
		_definitions = definitions,
		_logger = deps.Logger or Logger.new("Statistics.ClientFacts", "info"),
		_clock = deps.Clock or os.clock,
		_diagnosticAt = setmetatable({}, { __mode = "k" }),
		_initialized = false,
	}, StatisticsClientFactController)
end

function StatisticsClientFactController:_diagnose(player: Player, messageType: string, code: string)
	local now = self._clock()
	local playerDiagnostics = self._diagnosticAt[player]
	if playerDiagnostics == nil then
		playerDiagnostics = {}
		self._diagnosticAt[player] = playerDiagnostics
	end
	local key = `{messageType}:{code}`
	local lastAt = playerDiagnostics[key]
	if lastAt ~= nil and now - lastAt < DIAGNOSTIC_COOLDOWN_SECONDS then return end
	playerDiagnostics[key] = now
	self._logger:Warn("client_fact_rejected", {
		UserId = player.UserId,
		MessageType = messageType,
		Code = code,
	})
end

function StatisticsClientFactController:Initialize()
	if self._initialized then return end
	self._initialized = true
	for _, definition in self._definitions do
		self._communication:RegisterHandler(
			definition.MessageType,
			definition.Validate,
			function(player, payload)
				if definition.IsEligible ~= nil and not definition.IsEligible(player, payload) then
					self:_diagnose(player, definition.MessageType, "Ineligible")
					return
				end
				local operation = definition.Map(player, payload)
				local result = self._statistics:ApplyOperation(player, operation)
				if not result.Ok then
					self:_diagnose(player, definition.MessageType, result.Code)
				end
			end
		)
	end
end

return StatisticsClientFactController
