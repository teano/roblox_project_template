[CmdletBinding()]
param(
	[string]$TargetRepositoryRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "FeatureWorkflow.psm1") -Force -DisableNameChecking

$repositoryRoot = if ([string]::IsNullOrWhiteSpace($TargetRepositoryRoot)) {
	(Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
} else {
	(Resolve-Path -LiteralPath $TargetRepositoryRoot).Path
}
$failures = [System.Collections.Generic.List[string]]::new()

function Add-Failure {
	param([string]$Message)
	$failures.Add($Message)
}

function Get-LuauLongBracketEqualsCount {
	param(
		[string]$Content,
		[int]$StartIndex
	)

	if ($StartIndex -ge $Content.Length -or $Content[$StartIndex] -cne '[') {
		return -1
	}
	$cursor = $StartIndex + 1
	$equalsCount = 0
	while ($cursor -lt $Content.Length -and $Content[$cursor] -ceq '=') {
		$equalsCount += 1
		$cursor += 1
	}
	if ($cursor -lt $Content.Length -and $Content[$cursor] -ceq '[') {
		return $equalsCount
	}
	return -1
}

function Get-LuauExecutableSkeletonText {
	param([string]$Content)

	$builder = [System.Text.StringBuilder]::new()
	$index = 0
	while ($index -lt $Content.Length) {
		$character = $Content[$index]
		if (
			$character -ceq '-' -and
			$index + 1 -lt $Content.Length -and
			$Content[$index + 1] -ceq '-'
		) {
			$longEqualsCount = Get-LuauLongBracketEqualsCount $Content ($index + 2)
			if ($longEqualsCount -ge 0) {
				$openLength = $longEqualsCount + 2
				$bodyStart = $index + 2 + $openLength
				$closeDelimiter = ']' + ('=' * $longEqualsCount) + ']'
				$closeIndex = $Content.IndexOf(
					$closeDelimiter,
					$bodyStart,
					[System.StringComparison]::Ordinal
				)
				if ($closeIndex -lt 0) {
					return $null
				}
				$segmentEnd = $closeIndex + $closeDelimiter.Length
				$null = $builder.Append(' ')
				for ($commentIndex = $index; $commentIndex -lt $segmentEnd; $commentIndex += 1) {
					if ($Content[$commentIndex] -ceq "`r" -or $Content[$commentIndex] -ceq "`n") {
						$null = $builder.Append($Content[$commentIndex])
					}
				}
				$null = $builder.Append(' ')
				$index = $segmentEnd
				continue
			}

			$null = $builder.Append(' ')
			$index += 2
			while (
				$index -lt $Content.Length -and
				$Content[$index] -cne "`r" -and
				$Content[$index] -cne "`n"
			) {
				$index += 1
			}
			continue
		}

		if ($character -ceq '"' -or $character -ceq "'" -or $character -ceq '`') {
			return $null
		}
		if (
			$character -ceq '[' -and
			(Get-LuauLongBracketEqualsCount $Content $index) -ge 0
		) {
			return $null
		}

		$null = $builder.Append($character)
		$index += 1
	}
	return $builder.ToString()
}

function Read-LuauReviewedCodeSegment {
	param(
		[string]$Content,
		[ref]$Index,
		[string[]]$PreservedStrings,
		[bool]$StopAtClosingBrace
	)

	$builder = [System.Text.StringBuilder]::new()
	$braceDepth = if ($StopAtClosingBrace) { 1 } else { 0 }
	while ($Index.Value -lt $Content.Length) {
		$character = $Content[$Index.Value]
		if (
			$character -ceq '-' -and
			$Index.Value + 1 -lt $Content.Length -and
			$Content[$Index.Value + 1] -ceq '-'
		) {
			$longEqualsCount = Get-LuauLongBracketEqualsCount $Content ($Index.Value + 2)
			if ($longEqualsCount -ge 0) {
				$bodyStart = $Index.Value + $longEqualsCount + 4
				$closeDelimiter = ']' + ('=' * $longEqualsCount) + ']'
				$closeIndex = $Content.IndexOf(
					$closeDelimiter,
					$bodyStart,
					[System.StringComparison]::Ordinal
				)
				if ($closeIndex -lt 0) {
					throw "Unterminated Luau long comment."
				}
				$null = $builder.Append(' ')
				$Index.Value = $closeIndex + $closeDelimiter.Length
				continue
			}

			$null = $builder.Append(' ')
			$Index.Value += 2
			while (
				$Index.Value -lt $Content.Length -and
				$Content[$Index.Value] -cne "`r" -and
				$Content[$Index.Value] -cne "`n"
			) {
				$Index.Value += 1
			}
			continue
		}

		if ($character -ceq '"' -or $character -ceq "'") {
			$quote = $character
			$stringStart = $Index.Value + 1
			$cursor = $stringStart
			while ($cursor -lt $Content.Length -and $Content[$cursor] -cne $quote) {
				if ([int]$Content[$cursor] -eq 92) {
					$cursor += 2
				} else {
					$cursor += 1
				}
			}
			if ($cursor -ge $Content.Length) {
				throw "Unterminated Luau quoted string."
			}
			$rawString = $Content.Substring($stringStart, $cursor - $stringStart)
			if ($PreservedStrings -ccontains $rawString -and -not $rawString.Contains('\')) {
				$null = $builder.Append('"' + $rawString + '"')
			} else {
				$null = $builder.Append('""')
			}
			$Index.Value = $cursor + 1
			continue
		}

		if (
			$character -ceq '[' -and
			(Get-LuauLongBracketEqualsCount $Content $Index.Value) -ge 0
		) {
			$longEqualsCount = Get-LuauLongBracketEqualsCount $Content $Index.Value
			$bodyStart = $Index.Value + $longEqualsCount + 2
			$closeDelimiter = ']' + ('=' * $longEqualsCount) + ']'
			$closeIndex = $Content.IndexOf(
				$closeDelimiter,
				$bodyStart,
				[System.StringComparison]::Ordinal
			)
			if ($closeIndex -lt 0) {
				throw "Unterminated Luau long string."
			}
			$null = $builder.Append('""')
			$Index.Value = $closeIndex + $closeDelimiter.Length
			continue
		}

		if ([int]$character -eq 96) {
			$null = $builder.Append('""')
			$Index.Value += 1
			$closed = $false
			while ($Index.Value -lt $Content.Length) {
				$interpolatedCharacter = $Content[$Index.Value]
				if ([int]$interpolatedCharacter -eq 92) {
					$Index.Value += 2
					continue
				}
				if ([int]$interpolatedCharacter -eq 96) {
					$Index.Value += 1
					$closed = $true
					break
				}
				if ($interpolatedCharacter -ceq '{') {
					$Index.Value += 1
					$nested = Read-LuauReviewedCodeSegment `
						-Content $Content `
						-Index $Index `
						-PreservedStrings $PreservedStrings `
						-StopAtClosingBrace $true
					$null = $builder.Append(' ' + $nested + ' ')
					continue
				}
				$Index.Value += 1
			}
			if (-not $closed) {
				throw "Unterminated Luau interpolated string."
			}
			continue
		}

		if ($StopAtClosingBrace) {
			if ($character -ceq '{') {
				$braceDepth += 1
			} elseif ($character -ceq '}') {
				$braceDepth -= 1
				if ($braceDepth -eq 0) {
					$Index.Value += 1
					return $builder.ToString()
				}
			}
		}

		$null = $builder.Append($character)
		$Index.Value += 1
	}
	if ($StopAtClosingBrace) {
		throw "Unterminated Luau interpolation expression."
	}
	return $builder.ToString()
}

function Get-LuauReviewedCodeText {
	param(
		[string]$Content,
		[string[]]$PreservedStrings = @()
	)

	try {
		$index = 0
		return Read-LuauReviewedCodeSegment `
			-Content $Content `
			-Index ([ref]$index) `
			-PreservedStrings $PreservedStrings `
			-StopAtClosingBrace $false
	} catch {
		return $null
	}
}

function Test-AudioManualQaRemoteFreeSource {
	param([string]$Content)

	$code = Get-LuauReviewedCodeText $Content @(
		"RemoteEvent",
		"RemoteFunction",
		"BindableFunction"
	)
	if ($null -eq $code) {
		return $false
	}
	if ([regex]::IsMatch(
		$code,
		'\bInstance\s*\.\s*new\s*\(\s*["'']Remote(?:Event|Function)["'']\s*\)'
	)) {
		return $false
	}
	return -not [regex]::IsMatch(
		$code,
		'(?:\:|\.)\s*(?:FireClient|FireAllClients|FireServer|InvokeClient|InvokeServer)\s*\('
	)
}

function Test-IsTestsOrQaExecutableSource {
	param([string]$RelativePath)

	$normalized = $RelativePath.Replace("\", "/")
	return (
		$normalized -match '(?i)/(?:Tests?|QA)/' -and
		$normalized -match '(?i)\.(?:server|client)\.(?:lua|luau)$'
	)
}

function Test-TeleportValidationConfigSafeDefault {
	param([string]$Content)

	if (-not [regex]::IsMatch($Content, '\A--!strict\r?\n')) {
		return $false
	}
	$code = Get-LuauExecutableSkeletonText $Content
	if ($null -eq $code) {
		return $false
	}
	$actualLines = @(
		$code -split '\r?\n' |
			ForEach-Object { ($_ -replace '[\t ]+', ' ').Trim() } |
			Where-Object { $_.Length -gt 0 }
	)
	$expectedLines = @(
		'export type TeleportValidationConfig = {',
		'Enabled: boolean,',
		'GameId: number,',
		'RoutesBySourcePlaceId: { [number]: number },',
		'AuthorizedUserIds: { [number]: boolean },',
		'}',
		'local ENABLED = false',
		'local GAME_ID = 0',
		'local ROUTES_BY_SOURCE_PLACE_ID: { [number]: number } = {}',
		'local AUTHORIZED_USER_IDS: { [number]: boolean } = {}',
		'return table.freeze({',
		'Enabled = ENABLED,',
		'GameId = GAME_ID,',
		'RoutesBySourcePlaceId = table.freeze(table.clone(ROUTES_BY_SOURCE_PLACE_ID)),',
		'AuthorizedUserIds = table.freeze(table.clone(AUTHORIZED_USER_IDS)),',
		'}) :: TeleportValidationConfig'
	)
	if ($actualLines.Count -ne $expectedLines.Count) {
		return $false
	}
	for ($index = 0; $index -lt $expectedLines.Count; $index += 1) {
		if ($actualLines[$index] -cne $expectedLines[$index]) {
			return $false
		}
	}
	return $true
}

function Test-PositiveJsonInteger {
	param([object]$Value)

	if ($null -eq $Value) {
		return $false
	}

	$typeName = $Value.GetType().FullName
	# ConvertFrom-Json emits Int32/Int64 for bare decimal integer tokens in
	# Windows PowerShell 5.1 and Int64 in PowerShell 7. Decimal, Double,
	# BigInteger, and the other CLR numeric types either came from a non-integer
	# JSON representation or fall outside this parser contract, so reject them
	# instead of normalizing or rounding them before validation.
	if ($typeName -ne "System.Int32" -and $typeName -ne "System.Int64") {
		return $false
	}

	$number = [long]$Value
	return $number -gt 0 -and $number -le 9007199254740991
}

function Test-DerivedCloudIdentitySafe {
	param(
		[object]$ProjectConfiguration,
		[long[]]$TemplatePlaceIds,
		[long]$TemplateGameId
	)

	$placeIdProperty = $ProjectConfiguration.PSObject.Properties["placeId"]
	$gameIdProperty = $ProjectConfiguration.PSObject.Properties["gameId"]
	$servePlaceIdsProperty = $ProjectConfiguration.PSObject.Properties["servePlaceIds"]
	$identityProperties = @(
		@(
			$placeIdProperty,
			$gameIdProperty,
			$servePlaceIdsProperty
		) | Where-Object { $null -ne $_ }
	)
	if ($identityProperties.Count -eq 0) {
		return $true
	}
	if ($identityProperties.Count -ne 3) {
		return $false
	}

	if ($servePlaceIdsProperty.Value -isnot [System.Array]) {
		return $false
	}
	$rawServePlaceIds = @($servePlaceIdsProperty.Value)
	foreach ($identityValue in @(
		$placeIdProperty.Value,
		$gameIdProperty.Value
	) + $rawServePlaceIds) {
		if (-not (Test-PositiveJsonInteger $identityValue)) {
			return $false
		}
	}
	try {
		$placeId = [long]$placeIdProperty.Value
		$gameId = [long]$gameIdProperty.Value
		$servePlaceIds = @($rawServePlaceIds | ForEach-Object { [long]$_ })
	} catch {
		return $false
	}
	$uniqueServePlaceIds = [System.Collections.Generic.HashSet[long]]::new()
	foreach ($servePlaceId in $servePlaceIds) {
		if (-not $uniqueServePlaceIds.Add($servePlaceId)) {
			return $false
		}
	}
	if (
		$placeId -le 0 -or
		$gameId -le 0 -or
		$servePlaceIds.Count -eq 0 -or
		$placeId -notin $servePlaceIds -or
		$placeId -in $TemplatePlaceIds -or
		$gameId -eq $TemplateGameId -or
		@($servePlaceIds | Where-Object { $_ -in $TemplatePlaceIds }).Count -gt 0
	) {
		return $false
	}
	return $true
}

function Test-AudioManualQaBootstrapSource {
	param(
		[string]$Content,
		[string]$Side
	)

	$driverName = "AudioManualQa$Side"
	$requirePattern = if ($Side -ceq "Server") {
		'script\s*\.\s*Parent\s*\.\s*Tests\s*\.\s*AudioManualQaServer'
	} elseif ($Side -ceq "Client") {
		'ReplicatedStorage\s*\.\s*Shared\s*\.\s*Tests\s*\.\s*AudioManualQaClient'
	} else {
		return $false
	}
	$code = Get-LuauReviewedCodeText $Content @("RunService")
	if ($null -eq $code) {
		return $false
	}
	$escapedDriverName = [regex]::Escape($driverName)
	$hookPattern = (
		'(?s)\bif\s+RunService\s*:\s*IsStudio\s*\(\s*\)\s+then\s+' +
		'local\s+' + $escapedDriverName + '\s*=\s*require\s*\(\s*' +
		$requirePattern + '\s*\)\s*;?\s*' +
		$escapedDriverName + '\s*\.\s*InstallBridge\s*\(\s*' +
		'manifest\s*\.\s*Services\s*,\s*script\s*\)\s*;?\s*end\s*\z'
	)
	$hookMatches = [regex]::Matches($code, $hookPattern)
	if ($hookMatches.Count -ne 1) {
		return $false
	}
	$hook = $hookMatches[0]
	$initializationMatches = [regex]::Matches(
		$code,
		'\blocal\s+result\s*=\s*runner\s*:\s*Initialize\s*\('
	)
	$failureGateMatches = [regex]::Matches(
		$code,
		'(?s)\bif\s+not\s+result\s*\.\s*Ok\s+then\b.*?\bend\b'
	)
	if (
		$initializationMatches.Count -ne 1 -or
		$failureGateMatches.Count -ne 1 -or
		$initializationMatches[0].Index -ge $failureGateMatches[0].Index -or
		$hook.Index -le ($failureGateMatches[0].Index + $failureGateMatches[0].Length)
	) {
		return $false
	}
	if (-not [regex]::IsMatch(
		$code,
		'\blocal\s+RunService\s*=\s*game\s*:\s*GetService\s*\(\s*"RunService"\s*\)'
	)) {
		return $false
	}
	if ([regex]::Matches(
		$code,
		'\bRunService\s*:\s*IsStudio\s*\(\s*\)'
	).Count -ne 1) {
		return $false
	}
	$outsideHook = $code.Remove($hook.Index, $hook.Length)
	return -not [regex]::IsMatch($outsideHook, '\bAudioManualQa[A-Za-z0-9_]*\b')
}

$safeValidationConfigFixture = @'
--!strict
export type TeleportValidationConfig = {
    Enabled: boolean,
    GameId: number,
    RoutesBySourcePlaceId: { [number]: number },
    AuthorizedUserIds: { [number]: boolean },
}
local ENABLED = false
local GAME_ID = 0
local ROUTES_BY_SOURCE_PLACE_ID: { [number]: number } = {}
local AUTHORIZED_USER_IDS: { [number]: boolean } = {}
return table.freeze({
    Enabled = ENABLED,
    GameId = GAME_ID,
    RoutesBySourcePlaceId = table.freeze(table.clone(ROUTES_BY_SOURCE_PLACE_ID)),
    AuthorizedUserIds = table.freeze(table.clone(AUTHORIZED_USER_IDS)),
}) :: TeleportValidationConfig
'@
if (-not (Test-TeleportValidationConfigSafeDefault $safeValidationConfigFixture)) {
	Add-Failure "Internal validation-config safe-default fixture was rejected."
}
if (-not (Test-TeleportValidationConfigSafeDefault $safeValidationConfigFixture.Replace(
	'local ENABLED = false',
	"-- harmless line comment`n--[=[ harmless long comment ]=]`nlocal ENABLED = false"
))) {
	Add-Failure "Internal commented safe validation-config fixture was rejected."
}
foreach ($unsafeFixture in @(
	$safeValidationConfigFixture.Replace(
		'local GAME_ID = 0',
		"--[[`nlocal GAME_ID = 0`n]]`nlocal GAME_ID = 10596427617"
	),
	$safeValidationConfigFixture.Replace(
		'local GAME_ID = 0',
		"[=[`nlocal GAME_ID = 0`n]=]`nlocal GAME_ID = 10596427617"
	),
	$safeValidationConfigFixture.Replace(
		'return table.freeze({',
		"if true then ENABLED = true end`nreturn table.freeze({"
	),
	$safeValidationConfigFixture.Replace(
		'Enabled = ENABLED,',
		'Enabled = true,'
	),
	$safeValidationConfigFixture.Replace(
		'local GAME_ID = 0',
		'local GAME--[[ hidden token boundary ]]_ID = 0'
	),
	$safeValidationConfigFixture.Replace(
		'local GAME_ID = 0',
		'local GAME[=[ hidden executable long string ]=]_ID = 0'
	),
	$safeValidationConfigFixture.Replace(
		'local GAME_ID = 0',
		'local GAME_ID = "0"'
	)
)) {
	if (Test-TeleportValidationConfigSafeDefault $unsafeFixture) {
		Add-Failure "Internal validation-config anti-spoof fixture was accepted."
	}
}

$templateIdentityFixturePlaces = @([long]91045933836846, [long]101736951773632)
$safeDerivedIdentityFixtures = @(
	'{"name":"derived"}',
	'{"name":"derived","placeId":1,"gameId":2,"servePlaceIds":[1]}',
	'{"name":"derived","placeId":7001,"gameId":8001,"servePlaceIds":[7001]}',
	'{"name":"derived","placeId":7001,"gameId":8001,"servePlaceIds":[7001,7002]}',
	'{"name":"derived","placeId":9007199254740991,"gameId":9007199254740990,"servePlaceIds":[9007199254740991]}'
)
foreach ($fixtureJson in $safeDerivedIdentityFixtures) {
	$fixture = $fixtureJson | ConvertFrom-Json
	if (-not (Test-DerivedCloudIdentitySafe $fixture $templateIdentityFixturePlaces 10596427617)) {
		Add-Failure "Internal safe derived-identity fixture was rejected."
	}
}
$unsafeDerivedIdentityFixtures = @(
	'{"name":"derived","placeId":7001}',
	'{"name":"derived","gameId":8001}',
	'{"name":"derived","servePlaceIds":[7001]}',
	'{"name":"derived","placeId":7001,"gameId":8001,"servePlaceIds":7001}',
	'{"name":"derived","placeId":7001,"gameId":8001,"servePlaceIds":[]}',
	'{"name":"derived","placeId":7001,"gameId":8001,"servePlaceIds":[7001,7001]}',
	'{"name":"derived","placeId":0,"gameId":8001,"servePlaceIds":[0]}',
	'{"name":"derived","placeId":7001,"gameId":-1,"servePlaceIds":[7001]}',
	'{"name":"derived","placeId":true,"gameId":8001,"servePlaceIds":[7001]}',
	'{"name":"derived","placeId":null,"gameId":8001,"servePlaceIds":[7001]}',
	'{"name":"derived","placeId":7001,"gameId":"8001","servePlaceIds":[7001]}',
	'{"name":"derived","placeId":7001.0,"gameId":8001,"servePlaceIds":[7001]}',
	'{"name":"derived","placeId":7001,"gameId":8e3,"servePlaceIds":[7001]}',
	'{"name":"derived","placeId":7001,"gameId":8001,"servePlaceIds":[7001.0]}',
	'{"name":"derived","placeId":7001,"gameId":8001,"servePlaceIds":[7001.5]}',
	'{"name":"derived","placeId":9007199254740992.1,"gameId":8001,"servePlaceIds":[9007199254740992.1]}',
	'{"name":"derived","placeId":9007199254740992,"gameId":8001,"servePlaceIds":[9007199254740992]}',
	'{"name":"derived","placeId":9223372036854775808,"gameId":8001,"servePlaceIds":[9223372036854775808]}',
	'{"name":"derived","placeId":91045933836846,"gameId":8001,"servePlaceIds":[91045933836846]}',
	'{"name":"derived","placeId":101736951773632,"gameId":8001,"servePlaceIds":[101736951773632]}',
	'{"name":"derived","placeId":7001,"gameId":10596427617,"servePlaceIds":[7001]}',
	'{"name":"derived","placeId":7001,"gameId":8001,"servePlaceIds":[7001,101736951773632]}'
)
foreach ($fixtureJson in $unsafeDerivedIdentityFixtures) {
	$fixture = $fixtureJson | ConvertFrom-Json
	if (Test-DerivedCloudIdentitySafe $fixture $templateIdentityFixturePlaces 10596427617) {
		Add-Failure "Internal unsafe derived-identity fixture was accepted."
	}
}

foreach ($wrongClrNumericType in @(
	[byte]1,
	[int16]1,
	[uint32]1,
	[uint64]1,
	[decimal]1,
	[single]1,
	[double]1,
	[System.Numerics.BigInteger]::One
)) {
	if (Test-PositiveJsonInteger $wrongClrNumericType) {
		Add-Failure (
			"Internal derived-identity fixture accepted unsupported CLR numeric " +
			"type '$($wrongClrNumericType.GetType().FullName)'."
		)
	}
}

$safeAudioQaServerBootstrapFixture = @'
--!strict
local RunService = game:GetService("RunService")
local result = runner:Initialize({})
if not result.Ok then
	error("failed")
end
if RunService:IsStudio() then
	local AudioManualQaServer = require(script.Parent.Tests.AudioManualQaServer)
	AudioManualQaServer.InstallBridge(manifest.Services, script)
end
'@
$safeAudioQaClientBootstrapFixture = @'
--!strict
local RunService = game:GetService("RunService")
local result = runner:Initialize({})
if not result.Ok then
	error("failed")
end
if RunService:IsStudio() then
	local AudioManualQaClient = require(ReplicatedStorage.Shared.Tests.AudioManualQaClient)
	AudioManualQaClient.InstallBridge(manifest.Services, script)
end
'@
if (-not (Test-AudioManualQaBootstrapSource $safeAudioQaServerBootstrapFixture "Server")) {
	Add-Failure "Internal safe server Audio QA bootstrap fixture was rejected."
}
if (-not (Test-AudioManualQaBootstrapSource $safeAudioQaClientBootstrapFixture "Client")) {
	Add-Failure "Internal safe client Audio QA bootstrap fixture was rejected."
}
$formatTolerantAudioQaBootstrapFixture = @'
--!strict
local RunService = game : GetService ( "RunService" )
local decoy = "AudioManualQaServer InstallBridge RunService:IsStudio()"
local result = runner : Initialize ( { } )
if not result . Ok then
	error("failed")
end
-- RunService:IsStudio() and AudioManualQaServer in a comment are inert.
if RunService -- formatting comment
	: IsStudio ( ) then
	local AudioManualQaServer = require(
		script . Parent . Tests . AudioManualQaServer -- path comment
	)
	AudioManualQaServer . InstallBridge ( manifest . Services , script )
end
'@
if (-not (Test-AudioManualQaBootstrapSource $formatTolerantAudioQaBootstrapFixture "Server")) {
	Add-Failure "Internal whitespace/comment/string-tolerant Audio QA bootstrap fixture was rejected."
}
foreach ($unsafeAudioQaBootstrapFixture in @(
	$safeAudioQaServerBootstrapFixture.Replace(
		'if RunService:IsStudio() then',
		'if true then'
	),
	$safeAudioQaServerBootstrapFixture.Replace(
		'local AudioManualQaServer = require(script.Parent.Tests.AudioManualQaServer)',
		"local AudioManualQaServer = require(script.Parent.Tests.AudioManualQaServer)`nend`nif RunService:IsStudio() then"
	),
	$safeAudioQaServerBootstrapFixture.Replace(
		'if not result.Ok then',
		"if RunService:IsStudio() then`n`tlocal AudioManualQaServer = require(script.Parent.Tests.AudioManualQaServer)`n`tAudioManualQaServer.InstallBridge(manifest.Services, script)`nend`nif not result.Ok then"
	),
	$safeAudioQaClientBootstrapFixture.Replace(
		'ReplicatedStorage.Shared.Tests.AudioManualQaClient',
		'ReplicatedStorage.Shared.Tests.UnreviewedQaDriver'
	)
)) {
	if (
		(Test-AudioManualQaBootstrapSource $unsafeAudioQaBootstrapFixture "Server") -or
		(Test-AudioManualQaBootstrapSource $unsafeAudioQaBootstrapFixture "Client")
	) {
		Add-Failure "Internal unsafe Audio QA bootstrap fixture was accepted."
	}
}

$safeAudioQaRemoteFixture = @'
-- Instance.new("RemoteEvent"):FireClient()
--[=[ Instance.new("RemoteFunction"):InvokeServer() ]=]
local first = "Instance.new('RemoteEvent')"
local second = [[remote:FireServer()]]
local bridge = Instance.new("BindableFunction")
'@
if (-not (Test-AudioManualQaRemoteFreeSource $safeAudioQaRemoteFixture)) {
	Add-Failure "Internal comment/string-only Audio QA remote fixture was rejected."
}
$safeInterpolatedRemoteLiteralFixture = (
	'local message = ' +
	[char]96 +
	'literal remote:FireAllClients()' +
	[char]96
)
if (-not (Test-AudioManualQaRemoteFreeSource $safeInterpolatedRemoteLiteralFixture)) {
	Add-Failure "Internal interpolated-string literal Audio QA remote fixture was rejected."
}
$interpolatedRemoteFixture = (
	'local message = ' +
	[char]96 +
	'{remote:InvokeServer()}' +
	[char]96
)
foreach ($unsafeAudioQaRemoteFixture in @(
	'local remote = Instance.new("RemoteEvent")',
	'local remote = Instance.new ( ''RemoteFunction'' )',
	'remote : FireServer ( )',
	'remote:InvokeClient(player)',
	'remote . FireServer ( remote, payload )',
	'remote.InvokeServer(remote)',
	'remote . FireClient ( remote, player )',
	'remote.FireAllClients(remote)',
	'remote . InvokeClient ( remote, player )',
	$interpolatedRemoteFixture
)) {
	if (Test-AudioManualQaRemoteFreeSource $unsafeAudioQaRemoteFixture) {
		Add-Failure "Internal executable Audio QA remote fixture was accepted."
	}
}
foreach ($safeTestOrQaSourcePath in @(
	"src/ServerScriptService/Tests/RenamedHarness.luau",
	"src/ReplicatedStorage/QA/ReviewedModule.lua",
	"src/ServerScriptService/Runtime/RenamedHarness.server.luau"
)) {
	if (Test-IsTestsOrQaExecutableSource $safeTestOrQaSourcePath) {
		Add-Failure "Internal safe Tests/QA source-path fixture was rejected."
	}
}
foreach ($unsafeTestOrQaSourcePath in @(
	"src/ServerScriptService/Tests/RenamedHarness.server.lua",
	"src/ReplicatedStorage/QA/UnrelatedName.client.luau",
	"src/ReplicatedStorage/Test/Stealth.CLIENT.LUA"
)) {
	if (-not (Test-IsTestsOrQaExecutableSource $unsafeTestOrQaSourcePath)) {
		Add-Failure "Internal executable Tests/QA source-path fixture was accepted."
	}
}

function Test-AdrIndex {
	param(
		[string]$ScopeName,
		[string]$Directory,
		[string]$IndexPath,
		[bool]$IndexRequired
	)

	if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
		if ($IndexRequired) {
			Add-Failure "$ScopeName ADR directory is missing: $Directory"
		}
		return
	}

	$decisionFiles = @(
		Get-ChildItem -LiteralPath $Directory -File |
			Where-Object { $_.Name -match '^\d{4}-.+\.md$' }
	)
	$indexExists = Test-Path -LiteralPath $IndexPath -PathType Leaf

	if ($IndexRequired -and -not $indexExists) {
		Add-Failure "$ScopeName ADR index is missing: $IndexPath"
		return
	}

	if (-not $indexExists) {
		if ($decisionFiles.Count -gt 0) {
			Add-Failure "$ScopeName ADR files exist without their own README.md index."
		}
		return
	}

	$indexContent = Get-Content -LiteralPath $IndexPath -Raw
	foreach ($decisionFile in $decisionFiles) {
		$link = "($($decisionFile.Name))"
		if (-not $indexContent.Contains($link)) {
			Add-Failure "$ScopeName ADR index does not reference $($decisionFile.Name)."
		}
	}

	$linkMatches = [regex]::Matches(
		$indexContent,
		'\]\((\d{4}-[^)]+\.md)\)'
	)
	foreach ($linkMatch in $linkMatches) {
		$linkedPath = Join-Path $Directory $linkMatch.Groups[1].Value
		if (-not (Test-Path -LiteralPath $linkedPath -PathType Leaf)) {
			Add-Failure "$ScopeName ADR index references a missing file: $linkedPath"
		}
	}
}

function Test-TemplateDivergenceDocumentation {
	param(
		[string]$RepositoryRoot,
		[string]$ProjectAdrDirectory
	)

	$upstreamRefs = @(
		& git -C $RepositoryRoot for-each-ref `
			--format="%(refname)" refs/remotes/upstream/main
	)
	if ($upstreamRefs.Count -eq 0) {
		Add-Failure (
			"Derived repository has no upstream/main ref. Fetch upstream before " +
			"validating template divergence."
		)
		return
	}

	$mergeBaseOutput = @(
		& git -C $RepositoryRoot merge-base HEAD refs/remotes/upstream/main
	)
	if ($LASTEXITCODE -ne 0 -or $mergeBaseOutput.Count -eq 0) {
		$gitDirectory = (
			& git -C $RepositoryRoot rev-parse --absolute-git-dir
		).Trim()
		$mergeHeadPath = Join-Path $gitDirectory "MERGE_HEAD"
		if (Test-Path -LiteralPath $mergeHeadPath -PathType Leaf) {
			$mergeBase = "refs/remotes/upstream/main"
		} else {
			Add-Failure (
				"Derived repository does not share history with upstream/main. " +
				"Start the reviewed initial merge before validating."
			)
			return
		}
	} else {
		$mergeBase = $mergeBaseOutput[0].Trim()
	}

	$templatePaths = @{}
	$baselinePaths = @(
		& git -C $RepositoryRoot ls-tree -r --name-only $mergeBase
	)
	$upstreamPaths = @(
		& git -C $RepositoryRoot ls-tree -r --name-only refs/remotes/upstream/main
	)
	foreach ($path in @($baselinePaths) + @($upstreamPaths)) {
		$templatePaths[$path] = $true
	}

	$projectAdrFiles = @(
		Get-ChildItem -LiteralPath $ProjectAdrDirectory -File |
			Where-Object { $_.Name -match '^\d{4}-.+\.md$' }
	)
	$projectAdrDocuments = @(
		foreach ($adrFile in $projectAdrFiles) {
			$content = Get-Content -LiteralPath $adrFile.FullName -Raw
			[PSCustomObject]@{
				Path = $adrFile.FullName
				Name = $adrFile.Name
				Content = $content
				IsActiveAccepted = [regex]::IsMatch(
					$content,
					'(?m)^- Status:\s*Accepted\s*$'
				) -and [regex]::IsMatch(
					$content,
					'(?m)^- Superseded by:\s*None\s*$'
				)
			}
		}
	)

	$activePathOwners = @{}
	foreach ($document in $projectAdrDocuments | Where-Object {
		$_.IsActiveAccepted
	}) {
		$divergenceSection = [regex]::Match(
			$document.Content,
			'(?ms)^## Template divergence\s*\r?\n(?<Body>.*?)(?=^## |\z)'
		)
		if (-not $divergenceSection.Success) {
			continue
		}

		$pathsBlock = [regex]::Match(
			$divergenceSection.Groups["Body"].Value,
			'(?m)^- Paths:[ \t]*\r?\n' +
				'(?<Paths>(?:[ \t]+- `[^`\r\n]+`[ \t]*\r?\n?)+)'
		)
		if (-not $pathsBlock.Success) {
			continue
		}

		foreach ($pathMatch in [regex]::Matches(
			$pathsBlock.Groups["Paths"].Value,
			'`([^`]+)`'
		)) {
			$ownedPath = $pathMatch.Groups[1].Value
			if (-not $activePathOwners.ContainsKey($ownedPath)) {
				$activePathOwners[$ownedPath] = [System.Collections.Generic.List[string]]::new()
			}
			$activePathOwners[$ownedPath].Add($document.Name)
		}
	}

	foreach ($ownedPath in $activePathOwners.Keys) {
		$owners = $activePathOwners[$ownedPath]
		if ($owners.Count -gt 1) {
			Add-Failure (
				"Template divergence path has multiple active Accepted project " +
				"ADR owners: $ownedPath ($($owners -join ', '))"
			)
		}
	}

	$placeOwnershipAdr = @($activePathOwners["place.rbxl"])
	if (@($placeOwnershipAdr).Count -eq 0) {
		Add-Failure (
			"An active Accepted project ADR must document place.rbxl ownership " +
			"and upstream merge policy in a Template divergence section."
		)
	}

	$localChangedPaths = @(
		& git -C $RepositoryRoot diff --name-only $mergeBase --
	)
	foreach ($path in $localChangedPaths | Sort-Object -Unique) {
		if (
			$path.StartsWith("docs/adr/project/") -or
			$path.StartsWith("docs/Features/project/")
		) {
			continue
		}
		if (-not $templatePaths.ContainsKey($path)) {
			continue
		}

		if (-not $activePathOwners.ContainsKey($path)) {
			Add-Failure (
				"Locally changed template path is not documented in a project " +
				"ADR active Accepted Template divergence Paths list: $path"
			)
		}
	}
}

$canonicalPlace = Join-Path $repositoryRoot "place.rbxl"
$legacyPlace = Join-Path $repositoryRoot "template_place.rbxl"
if (-not (Test-Path -LiteralPath $canonicalPlace -PathType Leaf)) {
	Add-Failure "Canonical place.rbxl is missing."
}
if (Test-Path -LiteralPath $legacyPlace) {
	Add-Failure "Legacy template_place.rbxl must not exist."
}

$gitignorePath = Join-Path $repositoryRoot ".gitignore"
$gitignore = Get-Content -LiteralPath $gitignorePath -Raw
if (-not $gitignore.Contains("!/place.rbxl")) {
	Add-Failure ".gitignore must explicitly track /place.rbxl."
}

$routerPath = Join-Path $repositoryRoot "docs\adr\README.md"
$routerContent = Get-Content -LiteralPath $routerPath -Raw
if ([regex]::IsMatch($routerContent, '\]\((?:template/|project/)?\d{4}-')) {
	Add-Failure "The ADR router must not index individual decisions."
}

$adrRoot = Join-Path $repositoryRoot "docs\adr"
$rootDecisionFiles = @(
	Get-ChildItem -LiteralPath $adrRoot -File |
		Where-Object { $_.Name -match '^\d{4}-.+\.md$' }
)
if ($rootDecisionFiles.Count -gt 0) {
	Add-Failure "Numbered ADRs must live in the template or project namespace."
}

$templateDirectory = Join-Path $repositoryRoot "docs\adr\template"
$projectDirectory = Join-Path $repositoryRoot "docs\adr\project"
Test-AdrIndex `
	-ScopeName "Template" `
	-Directory $templateDirectory `
	-IndexPath (Join-Path $templateDirectory "README.md") `
	-IndexRequired $true

$isDerivedRepository = $false
try {
	$isDerivedRepository = (Get-RepositoryRole -RepositoryRoot $repositoryRoot) -eq "project"
} catch {
	Add-Failure $_.Exception.Message
}
if ($isDerivedRepository) {
	Test-AdrIndex `
		-ScopeName "Project" `
		-Directory $projectDirectory `
		-IndexPath (Join-Path $projectDirectory "README.md") `
		-IndexRequired $true
	if (Test-Path -LiteralPath $projectDirectory -PathType Container) {
		Test-TemplateDivergenceDocumentation `
			-RepositoryRoot $repositoryRoot `
			-ProjectAdrDirectory $projectDirectory
	}
} elseif (Test-Path -LiteralPath $projectDirectory) {
	Add-Failure "The template repository must not contain docs/adr/project."
}

$featureRouterPath = Join-Path $repositoryRoot "docs\Features\README.md"
$templateFeatureDirectory = Join-Path $repositoryRoot "docs\Features\template"
$projectFeatureDirectory = Join-Path $repositoryRoot "docs\Features\project"
if (-not (Test-Path -LiteralPath $featureRouterPath -PathType Leaf)) {
	Add-Failure "The template-owned feature namespace router is missing."
} else {
	$featureRouterContent = Get-Content -LiteralPath $featureRouterPath -Raw
	if ($featureRouterContent.Contains("<!-- feature-index:begin -->")) {
		Add-Failure "docs/Features/README.md must route namespaces, not contain a generated feature index."
	}
}
if (-not (Test-Path -LiteralPath (Join-Path $templateFeatureDirectory "README.md") -PathType Leaf)) {
	Add-Failure "The template feature namespace dashboard is missing."
}
if ($isDerivedRepository) {
	if (-not (Test-Path -LiteralPath (Join-Path $projectFeatureDirectory "README.md") -PathType Leaf)) {
		Add-Failure "Derived repositories must initialize a project feature namespace dashboard."
	}
} elseif (Test-Path -LiteralPath $projectFeatureDirectory) {
	Add-Failure "The template repository must not contain docs/Features/project."
}

$projectConfigurationPath = Join-Path $repositoryRoot "default.project.json"
$projectConfiguration = Get-Content -LiteralPath $projectConfigurationPath -Raw |
	ConvertFrom-Json
$expectedRojoConnectionName = Split-Path -Leaf $repositoryRoot
if ($projectConfiguration.name -cne $expectedRojoConnectionName) {
	Add-Failure (
		"default.project.json name must match the repository directory: " +
		"'$expectedRojoConnectionName'."
	)
}

$servePortProperty = $projectConfiguration.PSObject.Properties["servePort"]
if ($null -ne $servePortProperty) {
	Add-Failure (
		"default.project.json must not define servePort; projects share Rojo's " +
		"default endpoint and switch the active server through the preflight."
	)
}

$templateValidationPlaces = @([int64]91045933836846, [int64]101736951773632)
$templateValidationRepositories = @(
	"roblox_project_template",
	"roblox_project_template_second_place"
)
if ($isDerivedRepository) {
	if (-not (Test-DerivedCloudIdentitySafe `
		$projectConfiguration `
		$templateValidationPlaces `
		10596427617
	)) {
		Add-Failure (
			"Derived repository cloud identity must be absent or a complete, " +
			"exact positive safe-integer placeId/gameId/servePlaceIds set that " +
			"does not reuse template validation PlaceIds or GameId in the " +
			"corresponding identity fields."
		)
	}
}
if (
	-not $isDerivedRepository -and
	$templateValidationRepositories -contains $expectedRojoConnectionName
) {
	$expectedPlaceId = if ($expectedRojoConnectionName -eq "roblox_project_template") {
		[int64]91045933836846
	} else {
		[int64]101736951773632
	}
	$rawTemplateIdentityValues = @(
		$projectConfiguration.placeId,
		$projectConfiguration.gameId
	) + @($projectConfiguration.servePlaceIds)
	$templateIdentityTypesAreSafe = $true
	foreach ($identityValue in $rawTemplateIdentityValues) {
		if (-not (Test-PositiveJsonInteger $identityValue)) {
			$templateIdentityTypesAreSafe = $false
			break
		}
	}
	if (-not $templateIdentityTypesAreSafe) {
		Add-Failure (
			"Template validation identity values must be bare positive JSON " +
			"integers in the exact Roblox-safe range."
		)
	} elseif ([int64]$projectConfiguration.placeId -ne $expectedPlaceId) {
		Add-Failure "Template validation repository has the wrong top-level placeId."
	}
	if (
		$templateIdentityTypesAreSafe -and
		[int64]$projectConfiguration.gameId -ne [int64]10596427617
	) {
		Add-Failure "Template validation repository has the wrong top-level gameId."
	}
	$actualServePlaceIds = if ($templateIdentityTypesAreSafe) {
		@($projectConfiguration.servePlaceIds | ForEach-Object { [int64]$_ })
	} else {
		@()
	}
	if (
		$actualServePlaceIds.Count -ne 2 -or
		@($templateValidationPlaces | Where-Object { $_ -notin $actualServePlaceIds }).Count -ne 0 -or
		@($actualServePlaceIds | Where-Object { $_ -notin $templateValidationPlaces }).Count -ne 0
	) {
		Add-Failure "Template validation servePlaceIds must contain exactly both approved places."
	}

	$teleportPolicyPath = Join-Path $repositoryRoot "src\ServerScriptService\Modules\Teleport\TeleportPolicy.luau"
	$teleportPolicyContent = Get-Content -LiteralPath $teleportPolicyPath -Raw
	foreach ($requiredToken in @("10596427617", "91045933836846", "101736951773632")) {
		if (-not $teleportPolicyContent.Contains($requiredToken)) {
			Add-Failure "TeleportPolicy is missing approved template identity token '$requiredToken'."
		}
	}
	$serverManifestPath = Join-Path $repositoryRoot "src\ServerScriptService\Initialization\ServerManifest.luau"
	$serverManifestContent = Get-Content -LiteralPath $serverManifestPath -Raw
	if (-not $serverManifestContent.Contains("TeleportPolicy.Template(game.PlaceId, game.GameId)")) {
		Add-Failure "ServerManifest must gate the template Teleport policy with both PlaceId and GameId."
	}
	foreach ($requiredToken in @(
		"TeleportValidationPad.new",
		"TeleportValidationPadInitializationCommand.new",
		"TeleportValidationConfig",
		"Config = TeleportValidationConfig",
		"PlayersModule = playersModule",
		"Teleport = teleportModule"
	)) {
		if (-not $serverManifestContent.Contains($requiredToken)) {
			Add-Failure "ServerManifest is missing Teleport validation-pad composition token '$requiredToken'."
		}
	}

	$validationConfigPath = Join-Path $repositoryRoot "src\ServerScriptService\Modules\Teleport\TeleportValidationConfig.luau"
	if (-not (Test-Path -LiteralPath $validationConfigPath -PathType Leaf)) {
		Add-Failure "Teleport validation config module is missing."
	} else {
		$validationConfigContent = Get-Content -LiteralPath $validationConfigPath -Raw
		if (-not (Test-TeleportValidationConfigSafeDefault $validationConfigContent)) {
			Add-Failure (
				"Teleport validation config must match the exact closed, frozen, " +
				"default-disabled template implementation."
			)
		}
	}

	$validationPadPath = Join-Path $repositoryRoot "src\ServerScriptService\Modules\Teleport\TeleportValidationPad.luau"
	if (-not (Test-Path -LiteralPath $validationPadPath -PathType Leaf)) {
		Add-Failure "Runtime Teleport validation-pad module is missing."
	} else {
		$validationPadContent = Get-Content -LiteralPath $validationPadPath -Raw
		foreach ($requiredToken in @(
			"RoutesBySourcePlaceId",
			"AuthorizedUserIds",
			"GetPlayerFromCharacter",
			"Kind = `"Public`""
		)) {
			if (-not $validationPadContent.Contains($requiredToken)) {
				Add-Failure "Teleport validation pad is missing exact gate/routing token '$requiredToken'."
			}
		}
		foreach ($forbiddenIdentityToken in @(
			"10596427617",
			"91045933836846",
			"101736951773632",
			"11330628810"
		)) {
			if ($validationPadContent.Contains($forbiddenIdentityToken)) {
				Add-Failure "Reusable Teleport validation pad hardcodes identity '$forbiddenIdentityToken'."
			}
		}
	}
}

$rojoPreflightPath = Join-Path $repositoryRoot "scripts\ensure-rojo-server.ps1"
if (-not (Test-Path -LiteralPath $rojoPreflightPath -PathType Leaf)) {
	Add-Failure "scripts/ensure-rojo-server.ps1 is missing."
}

$agentsPath = Join-Path $repositoryRoot "AGENTS.md"
$agentsContent = Get-Content -LiteralPath $agentsPath -Raw
$rojoPreflightCommand = (
	"powershell -NoProfile -ExecutionPolicy Bypass -File " +
	"scripts/ensure-rojo-server.ps1"
)
if (-not $agentsContent.Contains($rojoPreflightCommand)) {
	Add-Failure "AGENTS.md must require the Rojo server preflight command."
}

$audioQaBootstrapFiles = @{
	Server = Join-Path $repositoryRoot "src\ServerScriptService\Bootstrap.server.luau"
	Client = Join-Path $repositoryRoot "src\StarterPlayerScripts\Bootstrap.client.luau"
}
foreach ($side in @("Server", "Client")) {
	$bootstrapPath = $audioQaBootstrapFiles[$side]
	if (-not (Test-Path -LiteralPath $bootstrapPath -PathType Leaf)) {
		Add-Failure "$side bootstrap required for the Audio QA boundary is missing."
		continue
	}
	$bootstrapContent = Get-Content -LiteralPath $bootstrapPath -Raw
	if (-not (Test-AudioManualQaBootstrapSource $bootstrapContent $side)) {
		Add-Failure (
			"$side bootstrap must install the exact Audio QA driver only in one " +
			"post-success RunService:IsStudio() block at the end of the existing bootstrap."
		)
	}
}

$approvedAudioQaRelativePaths = @(
	"src/ReplicatedStorage/Shared/Tests/AudioManualQaBridge.luau",
	"src/ReplicatedStorage/Shared/Tests/AudioManualQaClient.luau",
	"src/ReplicatedStorage/Shared/Tests/AudioManualQaContracts.luau",
	"src/ReplicatedStorage/Shared/Tests/AudioManualQaPlan.luau",
	"src/ServerScriptService/Tests/AudioManualQaServer.luau",
	"src/ServerScriptService/Tests/AudioManualQaTestRunner.luau"
)
$approvedAudioQaPathSet = [System.Collections.Generic.HashSet[string]]::new(
	[System.StringComparer]::Ordinal
)
$audioQaSourceFiles = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
foreach ($approvedAudioQaRelativePath in $approvedAudioQaRelativePaths) {
	$null = $approvedAudioQaPathSet.Add($approvedAudioQaRelativePath)
	$approvedAudioQaPath = Join-Path $repositoryRoot $approvedAudioQaRelativePath
	if (-not (Test-Path -LiteralPath $approvedAudioQaPath -PathType Leaf)) {
		Add-Failure "Approved Audio manual QA source is missing: '$approvedAudioQaRelativePath'."
		continue
	}
	$audioQaSourceFiles.Add((Get-Item -LiteralPath $approvedAudioQaPath))
}
$namedAudioQaSourceFiles = @(
	Get-ChildItem -LiteralPath (Join-Path $repositoryRoot "src") -Recurse -File |
		Where-Object {
			($_.Extension -ieq ".lua" -or $_.Extension -ieq ".luau") -and
			$_.Name -match 'AudioManualQa'
		}
)
foreach ($namedAudioQaSourceFile in $namedAudioQaSourceFiles) {
	$relativePath = $namedAudioQaSourceFile.FullName.Substring(
		$repositoryRoot.Length + 1
	).Replace("\", "/")
	if (-not $approvedAudioQaPathSet.Contains($relativePath)) {
		Add-Failure "Unreviewed Audio manual QA source is outside the exact inventory: '$relativePath'."
	}
}

$testAndQaSourceFiles = @(
	Get-ChildItem -LiteralPath (Join-Path $repositoryRoot "src") -Recurse -File |
		Where-Object {
			if ($_.Extension -ine ".lua" -and $_.Extension -ine ".luau") {
				return $false
			}
			$relativePath = $_.FullName.Substring($repositoryRoot.Length + 1).Replace("\", "/")
			return $relativePath -match '(?i)/(?:Tests?|QA)/'
		}
)
foreach ($testAndQaSourceFile in $testAndQaSourceFiles) {
	$relativePath = $testAndQaSourceFile.FullName.Substring(
		$repositoryRoot.Length + 1
	).Replace("\", "/")
	if (Test-IsTestsOrQaExecutableSource $relativePath) {
		Add-Failure "Tests/QA roots must not add executable Script/LocalScript source: '$relativePath'."
	}
}

$bridgeImplementationCount = 0
foreach ($audioQaSourceFile in $audioQaSourceFiles) {
	$relativePath = $audioQaSourceFile.FullName.Substring($repositoryRoot.Length + 1).Replace("\", "/")
	$content = Get-Content -LiteralPath $audioQaSourceFile.FullName -Raw
	if (-not (Test-AudioManualQaRemoteFreeSource $content)) {
		Add-Failure "Audio manual QA must remain side-local and contain no executable remote transport: '$relativePath'."
	}
	$code = Get-LuauReviewedCodeText $content @("BindableFunction")
	if ($null -eq $code) {
		Add-Failure "Audio manual QA source could not be lexically validated: '$relativePath'."
		continue
	}
	$bindableCreations = [regex]::Matches(
		$code,
		'Instance\s*\.\s*new\s*\(\s*["'']BindableFunction["'']\s*\)'
	).Count
	if ($bindableCreations -gt 0) {
		if ($relativePath -cne "src/ReplicatedStorage/Shared/Tests/AudioManualQaBridge.luau") {
			Add-Failure "Only AudioManualQaBridge may create the side-local BindableFunction: '$relativePath'."
		}
		$bridgeImplementationCount += $bindableCreations
	}
}
if ($bridgeImplementationCount -ne 1) {
	Add-Failure "Audio manual QA must contain exactly one reviewed BindableFunction creation site."
}

$spatialWrapperPath = Join-Path $repositoryRoot "src\ReplicatedStorage\Shared\Audio\AudioPlaybackWrapper.luau"
$spatialRegistryPath = Join-Path $repositoryRoot "src\ReplicatedStorage\Shared\Audio\SpatialAnchorBindingRegistry.luau"
if (-not (Test-Path -LiteralPath $spatialWrapperPath -PathType Leaf)) {
	Add-Failure "Fixed spatial AudioPlaybackWrapper implementation is missing."
} elseif (-not (Test-Path -LiteralPath $spatialRegistryPath -PathType Leaf)) {
	Add-Failure "Side-owned SpatialAnchorBindingRegistry implementation is missing."
} else {
	$spatialWrapperContent = Get-Content -LiteralPath $spatialWrapperPath -Raw
	$spatialRegistryContent = Get-Content -LiteralPath $spatialRegistryPath -Raw
	foreach ($requiredSpatialToken in @(
		'create(if playerType == "World" then "Part" else "Folder")',
		'root.Name = "SpatialAnchor"',
		'root.Anchored = true',
		'emitter.Parent = root',
		'self.Root.CFrame = CFrame.new(context.Source.Position)',
		'bindingRegistry:Register(',
		'self.Root.Parent = context.Parent'
	)) {
		if (-not $spatialWrapperContent.Contains($requiredSpatialToken)) {
			Add-Failure "Fixed spatial wrapper is missing reviewed composition token '$requiredSpatialToken'."
		}
	}
	foreach ($forbiddenSpatialToken in @(
		'.PositionType',
		'.PositionInstance',
		'EmitterPositionType',
		'AncestryChanged:Connect',
		'TargetConnection'
	)) {
		if ($spatialWrapperContent.Contains($forbiddenSpatialToken)) {
			Add-Failure "Fixed spatial wrapper contains forbidden positioning/follow token '$forbiddenSpatialToken'."
		}
	}
	if ([regex]::Matches($spatialRegistryContent, ':Connect\s*\(').Count -ne 1) {
		Add-Failure "SpatialAnchorBindingRegistry must own exactly one side frame subscription."
	}
	$releaseStart = $spatialWrapperContent.IndexOf('function AudioPlaybackWrapper:OnRelease()')
	$unregisterIndex = $spatialWrapperContent.IndexOf(':Unregister(self, generation)', $releaseStart)
	$generationIndex = $spatialWrapperContent.IndexOf('self.Generation += 1', $releaseStart)
	if ($releaseStart -lt 0 -or $unregisterIndex -lt $releaseStart -or $generationIndex -lt 0 -or $unregisterIndex -gt $generationIndex) {
		Add-Failure "World wrapper release must unregister its current spatial generation before invalidation/reset."
	}
}

$spatialManifestRequirements = @{
	"src/ReplicatedStorage/Client/Initialization/ClientManifest.luau" = "SpatialFrameDriver = RunService.RenderStepped"
	"src/ServerScriptService/Initialization/ServerManifest.luau" = "SpatialFrameDriver = RunService.Heartbeat"
}
foreach ($relativeManifestPath in $spatialManifestRequirements.Keys) {
	$manifestPath = Join-Path $repositoryRoot $relativeManifestPath
	if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
		Add-Failure "Spatial composition manifest is missing: '$relativeManifestPath'."
		continue
	}
	$manifestContent = Get-Content -LiteralPath $manifestPath -Raw
	if (-not $manifestContent.Contains("Workspace = Workspace") -or
		-not $manifestContent.Contains($spatialManifestRequirements[$relativeManifestPath])) {
		Add-Failure "Spatial composition dependencies are incomplete in '$relativeManifestPath'."
	}
}

$contentPreloaderImplementation = (
	"src/ReplicatedStorage/Shared/ContentPreloading/ContentPreloader.luau"
)
$directPreloadCalls = @(
	Get-ChildItem -LiteralPath (Join-Path $repositoryRoot "src") -Recurse -File -Filter "*.luau" |
		ForEach-Object {
			$relativePath = $_.FullName.Substring($repositoryRoot.Length + 1)
			$relativePath = $relativePath.Replace("\", "/")
			if (
				$relativePath -eq $contentPreloaderImplementation -or
				$relativePath.StartsWith("src/ServerScriptService/Tests/")
			) {
				return
			}
			$content = Get-Content -LiteralPath $_.FullName -Raw
			if ([regex]::IsMatch($content, ':PreloadAsync\s*\(')) {
				$relativePath
			}
		}
)
foreach ($directPreloadCall in $directPreloadCalls) {
	Add-Failure (
		"Production content preloading must route through ContentPreloader; " +
		"direct PreloadAsync call found in '$directPreloadCall'."
	)
}

$teleportProductionFiles = @(
	Get-ChildItem -LiteralPath (Join-Path $repositoryRoot "src") -Recurse -File -Filter "*.luau" |
		Where-Object {
			$relativePath = $_.FullName.Substring($repositoryRoot.Length + 1).Replace("\", "/")
			$relativePath.Contains("/Teleport/") -and
				-not $relativePath.StartsWith("src/ServerScriptService/Tests/")
		}
)
foreach ($teleportFile in $teleportProductionFiles) {
	$relativePath = $teleportFile.FullName.Substring($repositoryRoot.Length + 1).Replace("\", "/")
	$content = Get-Content -LiteralPath $teleportFile.FullName -Raw
	if ([regex]::IsMatch($content, '\.PlayerAdded\s*:\s*Connect|\.PlayerRemoving\s*:\s*Connect')) {
		Add-Failure (
			"Teleport production code must consume PlayersModule instead of direct " +
			"Players lifecycle subscriptions: '$relativePath'."
		)
	}
	if ([regex]::IsMatch($content, 'Instance\.new\s*\(\s*["'']Remote(?:Event|Function)["'']|:(?:FireClient|FireAllClients|FireServer)\s*\(')) {
		Add-Failure (
			"Teleport production code must use the Communication boundary instead " +
			"of direct remotes: '$relativePath'."
		)
	}
}

# TF-0005 recovery evidence is intentionally derived from the approved rev12
# acceptance matrix. A stale AC-number map or a label that is not bound to a
# real runner/static assertion must fail this validator.
$audioEvidenceRecords = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
function Add-AudioEvidenceRecord {
	param([string]$Identity)
	if (-not $audioEvidenceRecords.Add($Identity)) {
		Add-Failure "Duplicate TF-0005 static evidence record '$Identity'."
	}
}

$audioCsvPath = Join-Path $repositoryRoot "configs/audio/Sounds.csv"
if (-not (Test-Path -LiteralPath $audioCsvPath -PathType Leaf)) {
	Add-Failure "Audio CSV source is missing: 'configs/audio/Sounds.csv'."
} else {
	$audioCsvHeader = (Get-Content -LiteralPath $audioCsvPath -TotalCount 1).Split(',')
	if (-not ($audioCsvHeader -ccontains "CueId") -or -not ($audioCsvHeader -ccontains "VariantId")) {
		Add-Failure "Audio CSV must declare exact CueId and VariantId columns."
	} else {
		$audioCsvRows = @(Import-Csv -LiteralPath $audioCsvPath)
		$invalidStablePair = @($audioCsvRows | Where-Object {
			[string]::IsNullOrWhiteSpace($_.CueId) -or [string]::IsNullOrWhiteSpace($_.VariantId)
		})
		if ($audioCsvRows.Count -eq 0 -or $invalidStablePair.Count -gt 0) {
			Add-Failure "Every shipped audio CSV row must have a non-empty CueId/VariantId pair."
		} else {
			Add-AudioEvidenceRecord "AudioCsv/RequiredCueVariantColumns"
		}
	}
}

$csvConverter = Join-Path $repositoryRoot ".agents/skills/csv-to-luau/scripts/csv_to_luau.py"
if (-not (Test-Path -LiteralPath $csvConverter -PathType Leaf)) {
	Add-Failure "The reviewed CSV-to-Luau converter is missing."
} else {
	$csvEvidenceRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
		"tf0005-audio-csv-" + [guid]::NewGuid().ToString("N")
	)
	try {
		$null = New-Item -ItemType Directory -Path (Join-Path $csvEvidenceRoot "configs") -Force
		$null = New-Item -ItemType Directory -Path (Join-Path $csvEvidenceRoot "src") -Force
		& git -C $csvEvidenceRoot init --quiet
		if ($LASTEXITCODE -ne 0) { throw "temporary Git worktree initialization failed" }
		$fixtureSource = Join-Path $csvEvidenceRoot "configs/two.csv"
		$fixtureTarget = Join-Path $csvEvidenceRoot "src/Generated.luau"
		[System.IO.File]::WriteAllText((Join-Path $csvEvidenceRoot "default.project.json"), '{"name":"TF0005AudioCsvEvidence","tree":{"$path":"src"}}', [System.Text.UTF8Encoding]::new($false))
		[System.IO.File]::WriteAllText($fixtureSource, "CueId,VariantId`nEvidence.Cue,One`nEvidence.Cue,Two", [System.Text.UTF8Encoding]::new($false))
		$previewRaw = & python $csvConverter preview --repo-root $csvEvidenceRoot --source $fixtureSource --target $fixtureTarget --mode array --type CueId=string --type VariantId=string
		if ($LASTEXITCODE -ne 0) { throw "preview failed with exit $LASTEXITCODE`: $($previewRaw -join ' ')" }
		$preview = $previewRaw | ConvertFrom-Json
		if ($preview.status -ne "ok" -or $preview.shape.records -ne 2) { throw "preview did not accept the exact two-row fixture" }
		$applyRaw = & python $csvConverter apply --repo-root $csvEvidenceRoot --source $fixtureSource --target $fixtureTarget --mode array --type CueId=string --type VariantId=string --expect-source-sha256 $preview.source.sha256 --expect-target-sha256 absent --expect-output-sha256 $preview.output.sha256
		if ($LASTEXITCODE -ne 0) { throw "apply failed with exit $LASTEXITCODE" }
		$apply = $applyRaw | ConvertFrom-Json
		$secondRaw = & python $csvConverter preview --repo-root $csvEvidenceRoot --source $fixtureSource --target $fixtureTarget --mode array --type CueId=string --type VariantId=string
		if ($LASTEXITCODE -ne 0) { throw "post-apply preview failed with exit $LASTEXITCODE" }
		$second = $secondRaw | ConvertFrom-Json
		$generated = Get-Content -LiteralPath $fixtureTarget -Raw
		if ($apply.status -notin @("written", "unchanged") -or $second.output.sha256 -ne $preview.output.sha256 -or
			$second.diff.added -ne 0 -or $second.diff.changed -ne 0 -or $second.diff.removed -ne 0) {
			throw "preview/apply/preview freshness contract changed"
		}
		if (-not $generated.Contains('CueId = "Evidence.Cue"') -or -not $generated.Contains('VariantId = "One"') -or
			-not $generated.Contains('VariantId = "Two"')) {
			throw "generated output did not preserve both stable CueId/VariantId identities"
		}
		Add-AudioEvidenceRecord "AudioCsv/TwoVariantRoundTrip"
		Add-AudioEvidenceRecord "AudioCsv/PreviewApplyPreviewFreshness"
	} catch {
		Add-Failure "Audio CSV recovery evidence failed: $($_.Exception.Message)"
	} finally {
		if (Test-Path -LiteralPath $csvEvidenceRoot) {
			[System.IO.Directory]::Delete($csvEvidenceRoot, $true)
		}
	}
}

$audioSystemDoc = Join-Path $repositoryRoot "docs/AudioSystem.md"
$audioRule = Join-Path $repositoryRoot ".agents/rules/audio.md"
$testCoverageDoc = Join-Path $repositoryRoot "docs/TestCoverage.md"
$manualQaDoc = Join-Path $repositoryRoot "docs/AudioManualQA.md"
$audioAuthorityFiles = @($audioSystemDoc, $audioRule, $testCoverageDoc, $manualQaDoc)
if (@($audioAuthorityFiles | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) }).Count -eq 0) {
	$audioDocContent = Get-Content -LiteralPath $audioSystemDoc -Raw
	if ($audioDocContent.Contains(".agents/rules/audio.md") -and $audioDocContent.Contains("0043-fixed-spatial-anchor-composition.md")) {
		Add-AudioEvidenceRecord "AudioStatic/AudioRuleAndDocumentationCascade"
	} else { Add-Failure "Audio documentation cascade is missing its rule or ADR-0043 authority link." }
}

$requiredAudioAdrs = @(
	"0039-allow-deterministic-audio-only-asset-key-first-wins.md",
	"0040-own-audio-graph-and-acoustic-policy-at-bootstrap.md",
	"0041-protect-audio-startup-and-keep-disabled-transport-handlers.md",
	"0042-bind-studio-audio-qa-through-existing-bootstraps.md",
	"0043-fixed-spatial-anchor-composition.md"
)
$adrIndexContent = Get-Content -LiteralPath (Join-Path $repositoryRoot "docs/adr/template/README.md") -Raw
$allAudioAdrsAccepted = $true
foreach ($adrName in $requiredAudioAdrs) {
	$adrPath = Join-Path $repositoryRoot "docs/adr/template/$adrName"
	if (-not (Test-Path -LiteralPath $adrPath -PathType Leaf) -or
		-not (Get-Content -LiteralPath $adrPath -Raw).Contains("- Status: Accepted") -or
		-not $adrIndexContent.Contains($adrName)) { $allAudioAdrsAccepted = $false }
}
if ($allAudioAdrsAccepted) { Add-AudioEvidenceRecord "AudioStatic/RequiredAcceptedAdrs" }
else { Add-Failure "Required Accepted Audio ADRs 0039..0043 are incomplete or unindexed." }

$audioProductionFiles = @(Get-ChildItem -LiteralPath (Join-Path $repositoryRoot "src") -Recurse -File -Filter "*.luau" | Where-Object {
	$relative = $_.FullName.Substring($repositoryRoot.Length + 1).Replace("\", "/")
	$relative.Contains("/Audio/") -and -not $relative.Contains("/Tests/")
})
$acousticWrites = @($audioProductionFiles | Where-Object {
	[regex]::IsMatch((Get-Content -LiteralPath $_.FullName -Raw),
		'SoundService[^\r\n]*AcousticSimulationEnabled\s*=|AcousticSimulationEnabled\s*=\s*[^\r\n]*SoundService')
})
if ($acousticWrites.Count -eq 0) { Add-AudioEvidenceRecord "AudioStatic/CanonicalAcousticOwnership" }
else { Add-Failure "Runtime Audio source must not assign SoundService.AcousticSimulationEnabled." }

$wrapperEvidenceContent = Get-Content -LiteralPath (Join-Path $repositoryRoot "src/ReplicatedStorage/Shared/Audio/AudioPlaybackWrapper.luau") -Raw
if ($wrapperEvidenceContent.Contains('root.Name = "SpatialAnchor"') -and
	$wrapperEvidenceContent.Contains('self.Root.CFrame = CFrame.new(context.Source.Position)') -and
	-not $wrapperEvidenceContent.Contains('.PositionType') -and -not $wrapperEvidenceContent.Contains('.PositionInstance')) {
	Add-AudioEvidenceRecord "AudioStatic/FixedSpatialCompositionOnly"
} else { Add-Failure "The exact fixed SpatialAnchor composition static contract is not satisfied." }

$allTestsContent = Get-Content -LiteralPath (Join-Path $repositoryRoot "src/ServerScriptService/Tests/AllTestsRunner.luau") -Raw
$focusedRunnerOrder = @("AudioCatalogTestRunner", "AudioPlaybackTestRunner", "AudioIntegrationTestRunner", "AudioManualQaTestRunner")
$lastFocusedIndex = -1; $focusedOrderValid = $true
foreach ($runnerName in $focusedRunnerOrder) {
	$runnerIndex = $allTestsContent.IndexOf($runnerName, $lastFocusedIndex + 1, [System.StringComparison]::Ordinal)
	if ($runnerIndex -lt 0 -or $runnerIndex -le $lastFocusedIndex) { $focusedOrderValid = $false; break }
	$lastFocusedIndex = $runnerIndex
}
if ($focusedOrderValid) { Add-AudioEvidenceRecord "AudioStatic/FocusedRunnersRegistered" }
else { Add-Failure "Focused Audio runners are not registered in their required aggregate order." }

$audioConfigFiles = @(Get-ChildItem -LiteralPath (Join-Path $repositoryRoot "src/ReplicatedStorage/Shared/Configs/Audio") -File -Filter "*.luau")
$audioConfigNames = @($audioConfigFiles.Name | Sort-Object)
$expectedAudioConfigNames = @("AudioRuntimeConfig.luau", "RoutingConfig.luau", "SoundCatalog.luau", "SpatialProfiles.luau")
$configText = ($audioConfigFiles | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"
if (@(Compare-Object $audioConfigNames $expectedAudioConfigNames).Count -eq 0 -and
	-not $configText.Contains("PositionType") -and -not $configText.Contains("PositionInstance") -and
	-not $configText.Contains("ExperienceConfig")) {
	Add-AudioEvidenceRecord "AudioStatic/LocalConfigBuildBoundary"
} else { Add-Failure "Audio local config boundary contains an unexpected file or runtime/topology surface." }

$audioProductionText = ($audioProductionFiles | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"
$playbackPositionPaths = @(
	"src/ReplicatedStorage/Shared/Audio/AudioPlaybackWrapper.luau",
	"src/ReplicatedStorage/Shared/Audio/OrdinaryPlaybackCore.luau",
	"src/ReplicatedStorage/Client/Audio/OrdinarySoundClient.luau",
	"src/ServerScriptService/Modules/Audio/OrdinarySoundServer.luau"
)
$playbackPositionText = ($playbackPositionPaths | ForEach-Object {
	Get-Content -LiteralPath (Join-Path $repositoryRoot $_) -Raw
}) -join "`n"
if (-not [regex]::IsMatch($audioProductionText, 'Instance\.new\s*\(\s*["'']Remote(?:Event|Function)["'']') -and
	-not [regex]::IsMatch($audioProductionText, ':(?:FireClient|FireAllClients|FireServer)\s*\(') -and
	-not $playbackPositionText.Contains("PositionType") -and -not $playbackPositionText.Contains("PositionInstance")) {
	Add-AudioEvidenceRecord "AudioStatic/NoForbiddenRuntimeOrTransportSurface"
} else { Add-Failure "Audio production code contains a forbidden runtime positioning or direct transport surface." }

$ordinaryPublicPaths = @(
	"src/ReplicatedStorage/Shared/Audio/OrdinaryPlaybackCore.luau",
	"src/ReplicatedStorage/Client/Audio/OrdinarySoundClient.luau",
	"src/ServerScriptService/Modules/Audio/OrdinarySoundServer.luau"
)
$ordinaryText = ($ordinaryPublicPaths | ForEach-Object { Get-Content -LiteralPath (Join-Path $repositoryRoot $_) -Raw }) -join "`n"
if (-not [regex]::IsMatch($ordinaryText, '(?i)StopAll|StopBy(?:Cue|Type|Bus|Category)')) {
	Add-AudioEvidenceRecord "AudioStatic/NoOrdinaryMassStop"
} else { Add-Failure "Ordinary Audio exposes a forbidden mass-stop surface." }

$audioSpecPath = Join-Path $repositoryRoot "docs/Features/template/sfx-system/technical-specification.md"
$recoveryCoveragePath = Join-Path $repositoryRoot "tests/sfx-system/verification/rem-tf0005-support-evidence-01/coverage-manifest.json"
if (-not (Test-Path -LiteralPath $recoveryCoveragePath -PathType Leaf)) {
	Add-Failure "TF-0005 recovery coverage manifest is missing."
} else {
	$specText = Get-Content -LiteralPath $audioSpecPath -Raw
	$specMatches = [regex]::Matches($specText, '(?m)^\|\s*`(?<ac>PRD-AC-\d{3})`\s*\|\s*(?<cell>.*?)\s*\|')
	$expectedCoverage = @{}
	foreach ($match in $specMatches) {
		$identitySet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
		foreach ($identityMatch in [regex]::Matches($match.Groups['cell'].Value, '`(?<identity>(?:Audio|AssetRegistry|Studio-E2E-AUDIO)[^`]+)`')) {
			$null = $identitySet.Add($identityMatch.Groups['identity'].Value)
		}
		$expectedCoverage[$match.Groups['ac'].Value] = @($identitySet | Sort-Object)
	}
	$coverage = Get-Content -LiteralPath $recoveryCoveragePath -Raw | ConvertFrom-Json
	$coverageEntries = @($coverage.entries)
	$coverageById = @{}; foreach ($entry in $coverageEntries) { $coverageById[$entry.id] = $entry }
	if ($expectedCoverage.Count -ne 79 -or $coverageEntries.Count -ne 79 -or $coverageById.Count -ne 79) {
		Add-Failure "TF-0005 exact coverage must contain one unique entry for every PRD-AC-001..079."
	} else {
		$coverageExact = $true
		foreach ($ac in $expectedCoverage.Keys) {
			$entry = $coverageById[$ac]
			if ($null -eq $entry) { $coverageExact = $false; Add-Failure "Recovery coverage is missing '$ac'."; continue }
			$actualSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
			foreach ($testRecord in @($entry.tests)) {
				foreach ($symbol in ($testRecord.symbol -split '\s+\+\s+')) { if (-not [string]::IsNullOrWhiteSpace($symbol)) { $null = $actualSet.Add($symbol.Trim()) } }
			}
			$actual = @($actualSet | Sort-Object)
			if (@(Compare-Object $expectedCoverage[$ac] $actual).Count -ne 0) {
				$coverageExact = $false
				Add-Failure "Recovery coverage identities for '$ac' do not exactly match approved specification rev12 section 9.11."
			}
		}
		if ($coverageExact) { Add-AudioEvidenceRecord "AudioStatic/AllAcceptanceEvidenceMapped" }
	}
}

$runnerRegistered = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
foreach ($runnerFile in Get-ChildItem -LiteralPath (Join-Path $repositoryRoot "src") -Recurse -File -Filter "*TestRunner.luau") {
	$runnerText = Get-Content -LiteralPath $runnerFile.FullName -Raw
	foreach ($match in [regex]::Matches($runnerText, 'test\s*\(\s*["''](?<identity>(?:Audio|AssetRegistry)[^"'']+)["'']')) {
		$null = $runnerRegistered.Add($match.Groups['identity'].Value)
	}
	foreach ($tableMatch in [regex]::Matches($runnerText, '(?s)local\s+(?<name>[A-Za-z][A-Za-z0-9_]*)\s*=\s*\{(?<body>.*?)\}\s*\r?\n\s*for\s+_,\s*identity\s+in\s+\k<name>\s+do\s*\r?\n\s*test\s*\(\s*identity\s*,')) {
		foreach ($identityMatch in [regex]::Matches($tableMatch.Groups['body'].Value, '["''](?<identity>(?:Audio|AssetRegistry)[^"'']+)["'']')) {
			$null = $runnerRegistered.Add($identityMatch.Groups['identity'].Value)
		}
	}
}
foreach ($identity in $audioEvidenceRecords) { $null = $runnerRegistered.Add($identity) }
if (Test-Path -LiteralPath $recoveryCoveragePath -PathType Leaf) {
	$requiredNonStudio = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
	foreach ($match in [regex]::Matches((Get-Content -LiteralPath $audioSpecPath -Raw), '`(?<identity>(?:Audio|AssetRegistry)[A-Za-z0-9-]*/[A-Za-z0-9-]+)`')) {
		$null = $requiredNonStudio.Add($match.Groups['identity'].Value)
	}
	foreach ($identity in $requiredNonStudio) {
		if (-not $runnerRegistered.Contains($identity)) { Add-Failure "Required non-Studio Audio evidence identity is not bound to a registered test/static assertion: '$identity'." }
	}
}

$featureWorkflowValidator = Join-Path $repositoryRoot "scripts\validate-feature-workflow.ps1"
if (-not (Test-Path -LiteralPath $featureWorkflowValidator -PathType Leaf)) {
	Add-Failure "scripts/validate-feature-workflow.ps1 is missing."
} else {
	& $featureWorkflowValidator
	if ($LASTEXITCODE -ne 0) {
		Add-Failure "Feature manifests or the generated feature dashboard are invalid."
	}
}

if ($failures.Count -gt 0) {
	foreach ($failure in $failures) {
		Write-Error -Message $failure -ErrorAction Continue
	}
	exit 1
}

Write-Output "Repository layout validation passed."
