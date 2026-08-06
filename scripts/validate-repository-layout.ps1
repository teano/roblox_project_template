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
