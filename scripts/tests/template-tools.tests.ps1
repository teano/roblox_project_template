[CmdletBinding()]
param([switch]$Extended)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$sourceRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$templateTool = Join-Path $sourceRoot "scripts\template-project.ps1"
$featureTool = Join-Path $sourceRoot "scripts\feature.ps1"
$layoutWrapper = Join-Path $sourceRoot "scripts\validate-repository-layout.ps1"
$rojoEnsure = Join-Path $sourceRoot "scripts\ensure-rojo-server.ps1"
$hostExe = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("template-tools-tests-{0}" -f [Guid]::NewGuid().ToString("N"))
$originalPath = $env:PATH
$script:Passed = 0

function Assert-True {
	param([bool]$Condition, [string]$Message)
	if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
	$script:Passed++
}

function Write-Utf8NoBom {
	param([string]$Path, [string]$Content)
	$parent = Split-Path -Parent $Path
	if (-not [string]::IsNullOrWhiteSpace($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
	$encoding = New-Object Text.UTF8Encoding($false)
	[IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Invoke-TestGit {
	param([string]$Root, [string[]]$Arguments, [switch]$AllowFailure)
	$priorErrorAction = $ErrorActionPreference
	$ErrorActionPreference = "Continue"
	try {
		$output = @(& git -C $Root @Arguments 2>&1 | ForEach-Object { [string]$_ })
		$exitCode = $LASTEXITCODE
	} finally {
		$ErrorActionPreference = $priorErrorAction
	}
	if ($exitCode -ne 0 -and -not $AllowFailure) { throw "git $($Arguments -join ' ') failed: $($output -join ' ')" }
	return [PSCustomObject]@{ ExitCode = $exitCode; Output = @($output) }
}

function Invoke-Tool {
	param([string]$Tool, [string[]]$Arguments, [int]$ExpectedExitCode = 0)
	$priorErrorAction = $ErrorActionPreference
	$ErrorActionPreference = "Continue"
	try {
		$output = @(& $hostExe -NoProfile -ExecutionPolicy Bypass -File $Tool @Arguments 2>&1 | ForEach-Object { [string]$_ })
		$exitCode = $LASTEXITCODE
	} finally {
		$ErrorActionPreference = $priorErrorAction
	}
	if ($exitCode -ne $ExpectedExitCode) {
		throw "Tool '$Tool' exit $exitCode, expected $ExpectedExitCode. Arguments: $($Arguments -join ' '). Output: $($output -join [Environment]::NewLine)"
	}
	return [PSCustomObject]@{ ExitCode = $exitCode; Output = @($output); Text = ($output -join "`n") }
}

function Commit-All {
	param([string]$Root, [string]$Message)
	Invoke-TestGit -Root $Root -Arguments @("add", "-A") | Out-Null
	Invoke-TestGit -Root $Root -Arguments @("commit", "-m", $Message) | Out-Null
	return ([string](Invoke-TestGit -Root $Root -Arguments @("rev-parse", "HEAD")).Output[0]).Trim()
}

function Configure-Repository {
	param([string]$Root)
	Invoke-TestGit -Root $Root -Arguments @("config", "user.name", "Template Tools Test") | Out-Null
	Invoke-TestGit -Root $Root -Arguments @("config", "user.email", "template-tools@example.invalid") | Out-Null
	Invoke-TestGit -Root $Root -Arguments @("config", "core.autocrlf", "false") | Out-Null
}

function Get-StatusText {
	param([string]$Root)
	return (@((Invoke-TestGit -Root $Root -Arguments @("status", "--porcelain", "--untracked-files=all")).Output) -join "`n")
}

function Get-Hash {
	param([string]$Path)
	return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Test-BytesEqual {
	param([byte[]]$Left, [byte[]]$Right)
	if ($Left.Length -ne $Right.Length) { return $false }
	for ($index = 0; $index -lt $Left.Length; $index += 1) { if ($Left[$index] -ne $Right[$index]) { return $false } }
	return $true
}

function Read-Json {
	param([string]$Path)
	return [IO.File]::ReadAllText($Path) | ConvertFrom-Json
}

function New-TemplateRepository {
	param([string]$Root)
	[IO.Directory]::CreateDirectory($Root) | Out-Null
	Invoke-TestGit -Root $Root -Arguments @("init") | Out-Null
	Invoke-TestGit -Root $Root -Arguments @("branch", "-M", "main") | Out-Null
	Configure-Repository -Root $Root
	Invoke-TestGit -Root $Root -Arguments @("remote", "add", "origin", "https://github.com/teano/roblox_project_template.git") | Out-Null
	Write-Utf8NoBom -Path (Join-Path $Root ".gitignore") -Content "/tests/`n/*.rbxlx`nsourcemap.json`n"
	Write-Utf8NoBom -Path (Join-Path $Root "README.md") -Content "# Roblox project template`n"
	Write-Utf8NoBom -Path (Join-Path $Root "default.project.json") -Content @"
{
  "name": "roblox_project_template",
  "placeId": 91045933836846,
  "gameId": 10596427617,
  "servePlaceIds": [91045933836846, 101736951773632],
  "tree": {
    "`$className": "DataModel",
    "ReplicatedStorage": { "`$path": "src/ReplicatedStorage" }
  }
}
"@
	[IO.File]::WriteAllBytes((Join-Path $Root "place.rbxl"), [Text.Encoding]::UTF8.GetBytes("PLACE-V1`0BINARY"))
	Write-Utf8NoBom -Path (Join-Path $Root "shared.txt") -Content "base`n"
	Write-Utf8NoBom -Path (Join-Path $Root "docs/Features/template/README.md") -Content "# Template features`n"
	Write-Utf8NoBom -Path (Join-Path $Root "scripts/ensure-rojo-server.ps1") -Content "# template structural fixture`n"
	Write-Utf8NoBom -Path (Join-Path $Root "src/ServerScriptService/Bootstrap.server.luau") -Content "--!strict`n"
	Write-Utf8NoBom -Path (Join-Path $Root "src/StarterPlayerScripts/Bootstrap.client.luau") -Content "--!strict`n"
	Write-Utf8NoBom -Path (Join-Path $Root "docs/Features/template/tracked-only-repository-validation/feature.json") -Content @"
{"schemaVersion":2,"id":"TF-0011","slug":"tracked-only-repository-validation","title":"Tracked-Only Repository Validation","status":"in_progress","activity":"active","branch":"template-feature/tf-0011","baseCommit":"0000000000000000000000000000000000000000","startedAt":"2026-01-01T00:00:00Z","completedAt":null,"updatedAt":"2026-01-01T00:00:00Z","blockers":[],"artifacts":[],"verification":null,"recoveryLog":[]}
"@
	Write-Utf8NoBom -Path (Join-Path $Root "src/ReplicatedStorage/Shared/ContentPreloading/ContentPreloader.luau") -Content "--!strict`nreturn { Preload = function(provider, items) provider:PreloadAsync(items) end }`n"
	return Commit-All -Root $Root -Message "template baseline"
}

function New-DerivedClone {
	param([string]$TemplateRoot, [string]$Destination)
	$parent = Split-Path -Parent $Destination
	[IO.Directory]::CreateDirectory($parent) | Out-Null
	$output = @(& git -c core.autocrlf=false clone --quiet $TemplateRoot $Destination 2>&1 | ForEach-Object { [string]$_ })
	if ($LASTEXITCODE -ne 0) { throw "clone failed: $($output -join ' ')" }
	Configure-Repository -Root $Destination
	Invoke-TestGit -Root $Destination -Arguments @("remote", "rename", "origin", "upstream") | Out-Null
	Invoke-TestGit -Root $Destination -Arguments @("remote", "add", "origin", (Join-Path $testRoot "game-origin.git")) | Out-Null
	return $Destination
}

function Assert-CommandFails {
	param([string]$Tool, [string[]]$Arguments, [string]$Contains)
	$result = Invoke-Tool -Tool $Tool -Arguments $Arguments -ExpectedExitCode 1
	Assert-True ($result.Text.IndexOf($Contains, [StringComparison]::OrdinalIgnoreCase) -ge 0) "failure must mention '$Contains'; output: $($result.Text)"
	return $result
}

[IO.Directory]::CreateDirectory($testRoot) | Out-Null
try {
	$successfulRojoBin = Join-Path $testRoot "successful-rojo-bin"
	Write-Utf8NoBom -Path (Join-Path $successfulRojoBin "rojo.cmd") -Content "@echo fixture-rojo-build>`"%4`"`r`n@exit /b 0`r`n"
	$env:PATH = "$successfulRojoBin;$originalPath"
	# The implementation is parseable and has no dependency on the legacy module/skills.
	foreach ($tool in @($templateTool, $featureTool, $layoutWrapper, $rojoEnsure)) {
		[void][ScriptBlock]::Create([IO.File]::ReadAllText($tool))
		$text = [IO.File]::ReadAllText($tool)
		Assert-True ($text -notmatch '(?im)^\s*Import-Module\b.*FeatureWorkflow') "$tool must not import the old feature module"
		Assert-True ($text -notmatch '(?im)^\s*[.&]\s+.*\.agents[/\\]skills') "$tool must not execute skills"
	}
	foreach ($removedLegacyTool in @(
		"scripts/FeatureWorkflow.psm1",
		"scripts/feature-workflow.ps1",
		"scripts/sync-feature-index.ps1",
		"scripts/validate-feature-workflow.ps1",
		"scripts/tests/feature-workflow.tests.ps1"
	)) { Assert-True (-not (Test-Path -LiteralPath (Join-Path $sourceRoot $removedLegacyTool))) "$removedLegacyTool must be removed after cutover" }
	$userSkillContracts = [ordered]@{
		"feature-start" = "feature.ps1 new"
		"feature-pause" = "feature.ps1 status"
		"feature-continue" = "feature.ps1 status"
		"feature-finish" = "feature.ps1 close"
	}
	foreach ($skillName in $userSkillContracts.Keys) {
		$skillRoot = Join-Path $sourceRoot ".agents/skills/$skillName"
		$skillPath = Join-Path $skillRoot "SKILL.md"
		$metadataPath = Join-Path $skillRoot "agents/openai.yaml"
		Assert-True (Test-Path -LiteralPath $skillPath -PathType Leaf) "$skillName must expose a SKILL.md user interface"
		Assert-True (Test-Path -LiteralPath $metadataPath -PathType Leaf) "$skillName must expose UI metadata"
		$skillText = [IO.File]::ReadAllText($skillPath)
		$metadataText = [IO.File]::ReadAllText($metadataPath)
		Assert-True ($skillText.Contains([string]$userSkillContracts[$skillName])) "$skillName must route through the current feature backend"
		Assert-True ($skillText -notmatch 'feature-workflow\.ps1|FeatureWorkflow\.psm1|\.agentic-pipeline') "$skillName must not restore the retired lifecycle engine"
		Assert-True ($metadataText -match '(?m)^\s*allow_implicit_invocation:\s*true\s*$') "$skillName must support natural-language routing"
		Assert-True ($metadataText.Contains("`$$skillName")) "$skillName metadata must provide an explicit invocation example"
	}
	$rojoEnsureText = [IO.File]::ReadAllText($rojoEnsure)
	Assert-True ($rojoEnsureText.Contains("Get-CimInstance Win32_Process") -and $rojoEnsureText.Contains('IndexOf($projectPath') -and $rojoEnsureText.Contains('@("serve", $quotedProjectPath)')) "Rojo reuse/start must bind the listener process to the exact quoted absolute project path"

	$templateRoot = Join-Path $testRoot "roblox_project_template"
	$baseline = New-TemplateRepository -Root $templateRoot
	$directTemplateValidate = Invoke-Tool -Tool $templateTool -Arguments @("validate", "-RepositoryPath", $templateRoot)
	Assert-True ($directTemplateValidate.Text.Contains("role=template")) "validate must work directly in the origin-only template without TargetRef"
	$wrapperValidate = Invoke-Tool -Tool $layoutWrapper -Arguments @("-RepositoryPath", $templateRoot)
	Assert-True ($wrapperValidate.Text.Contains("VALID") -and $wrapperValidate.Text.Contains("role=template")) "legacy validator entrypoint must delegate to template-project validate"
	$defaultEndpoint = Invoke-Tool -Tool $rojoEnsure -Arguments @("-RepositoryPath", $templateRoot, "-ResolveOnly")
	Assert-True ($defaultEndpoint.Text.Contains("port=34872")) "Rojo helper must resolve the default port when servePort is absent"
	$templateEndpointConfig = Read-Json (Join-Path $templateRoot "default.project.json")
	$templateEndpointConfig | Add-Member -NotePropertyName servePort -NotePropertyValue 4567
	$templateEndpointConfig.name = "CustomServerIdentity"
	Write-Utf8NoBom -Path (Join-Path $templateRoot "default.project.json") -Content (($templateEndpointConfig | ConvertTo-Json -Depth 20) + "`n")
	$customEndpoint = Invoke-Tool -Tool $rojoEnsure -Arguments @("-RepositoryPath", $templateRoot, "-ResolveOnly")
	Assert-True ($customEndpoint.Text.Contains("port=4567") -and $customEndpoint.Text.Contains("name=CustomServerIdentity")) "Rojo helper must resolve custom name/port without directory-name equality"
	$templateEndpointConfig.servePort = "4567"
	Write-Utf8NoBom -Path (Join-Path $templateRoot "default.project.json") -Content (($templateEndpointConfig | ConvertTo-Json -Depth 20) + "`n")
	Assert-CommandFails -Tool $rojoEnsure -Arguments @("-RepositoryPath", $templateRoot, "-ResolveOnly") -Contains "exact integer" | Out-Null
	Invoke-TestGit -Root $templateRoot -Arguments @("restore", "--", "default.project.json") | Out-Null
	$spacedTemplate = Join-Path $testRoot "Path With Spaces/roblox_project_template"
	New-TemplateRepository -Root $spacedTemplate | Out-Null
	$spacedEndpoint = Invoke-Tool -Tool $rojoEnsure -Arguments @("-RepositoryPath", $spacedTemplate, "-ResolveOnly")
	Assert-True ($spacedEndpoint.Text.Contains("Path With Spaces") -and $spacedEndpoint.Text.Contains("port=34872")) "Rojo endpoint resolution must preserve an absolute repository path containing spaces"
	Write-Utf8NoBom -Path (Join-Path $spacedTemplate ".agentic-pipeline/state.json") -Content "{}`n"
	Commit-All -Root $spacedTemplate -Message "legacy tracked runtime artifact" | Out-Null
	Remove-Item -LiteralPath (Join-Path $spacedTemplate ".agentic-pipeline/state.json") -Force
	Invoke-Tool -Tool $templateTool -Arguments @("validate", "-RepositoryPath", $spacedTemplate) | Out-Null
	Assert-True ($true) "validator must treat an unstaged tracked deletion as absent from the current working-tree candidate"

	# Directory names are not role evidence; explicit role is the fail-closed escape hatch for verified offline template fixtures.
	$ambiguousTemplate = Join-Path $testRoot "ambiguous/roblox_project_template"
	New-TemplateRepository -Root $ambiguousTemplate | Out-Null
	Invoke-TestGit -Root $ambiguousTemplate -Arguments @("remote", "remove", "origin") | Out-Null
	Assert-CommandFails -Tool $templateTool -Arguments @("validate", "-RepositoryPath", $ambiguousTemplate) -Contains "ownership is ambiguous" | Out-Null
	Invoke-Tool -Tool $templateTool -Arguments @("validate", "-RepositoryPath", $ambiguousTemplate, "-RepositoryRole", "Template") | Out-Null

	# Template identity is exact, not merely a complete positive tuple.
	$wrongTemplateIdentity = Read-Json (Join-Path $ambiguousTemplate "default.project.json")
	$wrongTemplateIdentity.placeId = [Int64]7001
	$wrongTemplateIdentity.servePlaceIds = @([Int64]7001, [Int64]101736951773632)
	Write-Utf8NoBom -Path (Join-Path $ambiguousTemplate "default.project.json") -Content (($wrongTemplateIdentity | ConvertTo-Json -Depth 20) + "`n")
	Assert-CommandFails -Tool $templateTool -Arguments @("validate", "-RepositoryPath", $ambiguousTemplate, "-RepositoryRole", "Template") -Contains "canonical template placeId/gameId" | Out-Null

	# Primary path: one command bootstraps an explicit destination from an empty origin.
	$emptyOrigin = Join-Path $testRoot "bootstrap-origin.git"
	[IO.Directory]::CreateDirectory($emptyOrigin) | Out-Null
	Invoke-TestGit -Root $emptyOrigin -Arguments @("init", "--bare") | Out-Null
	$bootstrapDestination = Join-Path $testRoot "BootstrapGame"
	Invoke-Tool -Tool $templateTool -Arguments @("init", "-Check", "-OriginUrl", $emptyOrigin, "-TemplateUrl", $templateRoot, "-Destination", $bootstrapDestination) | Out-Null
	Assert-True (-not (Test-Path -LiteralPath $bootstrapDestination)) "bootstrap check must not create destination"
	Invoke-Tool -Tool $templateTool -Arguments @("init", "-Apply", "-OriginUrl", $emptyOrigin, "-TemplateUrl", $templateRoot, "-Destination", $bootstrapDestination) | Out-Null
	Assert-True (([string](Invoke-TestGit -Root $bootstrapDestination -Arguments @("remote", "get-url", "upstream")).Output[0]).Trim() -eq $templateRoot) "bootstrap must configure template upstream"
	Assert-True (([string](Invoke-TestGit -Root $bootstrapDestination -Arguments @("remote", "get-url", "origin")).Output[0]).Trim() -eq $emptyOrigin) "bootstrap must configure target origin"
	Assert-True ((Invoke-TestGit -Root $emptyOrigin -Arguments @("show-ref", "--verify", "refs/heads/main") -AllowFailure).ExitCode -ne 0) "bootstrap must not push implicitly"
	Configure-Repository -Root $bootstrapDestination
	Commit-All -Root $bootstrapDestination -Message "local bootstrap checkpoint" | Out-Null
	$bootstrapHead = ([string](Invoke-TestGit -Root $bootstrapDestination -Arguments @("rev-parse", "HEAD")).Output[0]).Trim()
	Assert-CommandFails -Tool $templateTool -Arguments @("init", "-Apply", "-OriginUrl", $emptyOrigin, "-TemplateUrl", $templateRoot, "-Destination", $bootstrapDestination) -Contains "already has derived identity" | Out-Null
	Assert-True (([string](Invoke-TestGit -Root $bootstrapDestination -Arguments @("rev-parse", "HEAD")).Output[0]).Trim() -eq $bootstrapHead) "repeated bootstrap must not overwrite initialized checkout"

	$pushOrigin = Join-Path $testRoot "push-origin.git"
	[IO.Directory]::CreateDirectory($pushOrigin) | Out-Null
	Invoke-TestGit -Root $pushOrigin -Arguments @("init", "--bare") | Out-Null
	$pushDestination = Join-Path $testRoot "PushGame"
	Invoke-Tool -Tool $templateTool -Arguments @("init", "-Apply", "-Push", "-OriginUrl", $pushOrigin, "-TemplateUrl", $templateRoot, "-Destination", $pushDestination) | Out-Null
	Assert-True (@((Invoke-TestGit -Root $pushOrigin -Arguments @("show-ref", "refs/heads/main")).Output).Count -eq 1) "explicit -Push must publish exactly origin/main"

	$unsafeDestination = Join-Path $testRoot "ExistingDirectory"
	Write-Utf8NoBom -Path (Join-Path $unsafeDestination "keep.txt") -Content "keep`n"
	$unsafeHash = Get-Hash (Join-Path $unsafeDestination "keep.txt")
	Assert-CommandFails -Tool $templateTool -Arguments @("init", "-Check", "-OriginUrl", $emptyOrigin, "-TemplateUrl", $templateRoot, "-Destination", $unsafeDestination) -Contains "non-empty" | Out-Null
	Assert-True ((Get-Hash (Join-Path $unsafeDestination "keep.txt")) -eq $unsafeHash) "bootstrap must not overwrite a non-empty unrelated destination"

	# Originless init exports one exact tracked snapshot without creating a repository.
	Write-Utf8NoBom -Path (Join-Path $templateRoot "tests/plain-ignored.txt") -Content "ignored source state`n"
	Write-Utf8NoBom -Path (Join-Path $templateRoot "working-tree-only.txt") -Content "untracked source state`n"
	$plainSourceStatus = Get-StatusText $templateRoot
	$plainCheckDestination = Join-Path $testRoot "PlainCheckGame"
	Invoke-Tool -Tool $templateTool -Arguments @("init", "-Check", "-TemplateUrl", $templateRoot, "-Destination", $plainCheckDestination, "-TargetRef", $baseline) | Out-Null
	Assert-True (-not (Test-Path -LiteralPath $plainCheckDestination)) "originless Check must not create an absent destination"
	Assert-True ((Get-StatusText $templateRoot) -eq $plainSourceStatus) "originless Check must not mutate the template checkout"
	$plainEmptyCheck = Join-Path $testRoot "PlainEmptyCheck"
	[IO.Directory]::CreateDirectory($plainEmptyCheck) | Out-Null
	Invoke-Tool -Tool $templateTool -Arguments @("init", "-Check", "-TemplateUrl", $templateRoot, "-Destination", $plainEmptyCheck, "-TargetRef", $baseline) | Out-Null
	Assert-True ((Test-Path -LiteralPath $plainEmptyCheck -PathType Container) -and @(Get-ChildItem -LiteralPath $plainEmptyCheck -Force).Count -eq 0) "originless Check must preserve an existing empty destination"

	$invalidPlainDestination = Join-Path $testRoot "InvalidPlainGame"
	Assert-CommandFails -Tool $templateTool -Arguments @("init", "-Check", "-TemplateUrl", $templateRoot, "-Destination", $invalidPlainDestination, "-TargetRef", "not-a-full-commit") -Contains "full 40-character" | Out-Null
	Assert-True (-not (Test-Path -LiteralPath $invalidPlainDestination)) "invalid originless TargetRef must not create destination state"
	$nonEmptyPlainDestination = Join-Path $testRoot "NonEmptyPlainGame"
	Write-Utf8NoBom -Path (Join-Path $nonEmptyPlainDestination "keep.txt") -Content "keep`n"
	$nonEmptyPlainHash = Get-Hash (Join-Path $nonEmptyPlainDestination "keep.txt")
	Assert-CommandFails -Tool $templateTool -Arguments @("init", "-Apply", "-TemplateUrl", $templateRoot, "-Destination", $nonEmptyPlainDestination, "-TargetRef", $baseline) -Contains "absent or empty" | Out-Null
	Assert-True ((Get-Hash (Join-Path $nonEmptyPlainDestination "keep.txt")) -eq $nonEmptyPlainHash) "originless init must not alter a non-empty destination"

	$failedPlainDestination = Join-Path $testRoot "FailedPlainGame"
	[IO.Directory]::CreateDirectory($failedPlainDestination) | Out-Null
	$plainFailingRojoBin = Join-Path $testRoot "plain-failing-rojo-bin"
	Write-Utf8NoBom -Path (Join-Path $plainFailingRojoBin "rojo.cmd") -Content "@echo forced originless rojo failure 1>&2`r`n@exit /b 23`r`n"
	$plainPriorPath = $env:PATH
	try {
		$env:PATH = "$plainFailingRojoBin;$plainPriorPath"
		Assert-CommandFails -Tool $templateTool -Arguments @("init", "-Apply", "-TemplateUrl", $templateRoot, "-Destination", $failedPlainDestination, "-TargetRef", $baseline) -Contains "destination was restored exactly" | Out-Null
	} finally {
		$env:PATH = $plainPriorPath
	}
	Assert-True ((Test-Path -LiteralPath $failedPlainDestination -PathType Container) -and @(Get-ChildItem -LiteralPath $failedPlainDestination -Force).Count -eq 0) "failed originless build must restore the exact existing-empty destination"
	Assert-True (@(Get-ChildItem -LiteralPath $testRoot -Force -Filter ".FailedPlainGame.template-init-*").Count -eq 0) "failed originless init must clean guarded sibling scratch paths"

	$plainDestination = Join-Path $testRoot "PlainGame"
	$targetPlaceHash = Get-Hash (Join-Path $templateRoot "place.rbxl")
	$plainInit = Invoke-Tool -Tool $templateTool -Arguments @("init", "-Apply", "-TemplateUrl", $templateRoot, "-Destination", $plainDestination, "-TargetRef", $baseline)
	$plainConfig = Read-Json (Join-Path $plainDestination "default.project.json")
	$plainRojoReceipts = @($plainInit.Output | Where-Object { $_ -like "ROJO BUILD VALID repository=*" })
	Assert-True ($plainRojoReceipts.Count -eq 1) "successful Rojo validation must emit exactly one concise receipt after the non-empty build"
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $plainDestination ".git"))) "originless Apply must not create .git"
	Assert-True ((Invoke-TestGit -Root $plainDestination -Arguments @("rev-parse", "--show-toplevel") -AllowFailure).ExitCode -ne 0) "originless client must not be a Git repository"
	Assert-True ($plainConfig.name -eq "PlainGame") "originless Apply must derive the Rojo name from the destination leaf"
	Assert-True ($null -eq $plainConfig.PSObject.Properties["placeId"] -and $null -eq $plainConfig.PSObject.Properties["gameId"] -and $null -eq $plainConfig.PSObject.Properties["servePlaceIds"] -and $null -eq $plainConfig.PSObject.Properties["servePort"]) "originless Apply must strip inherited cloud identity and servePort"
	Assert-True ((Get-Hash (Join-Path $plainDestination "place.rbxl")) -eq $targetPlaceHash) "originless Apply must preserve target place bytes"
	$expectedPlainReadme = (@(
		"# PlainGame",
		"",
		'Roblox project derived from `roblox_project_template`.',
		"",
		"## Local development",
		"",
		'```powershell',
		"powershell -NoProfile -ExecutionPolicy Bypass -File scripts/ensure-rojo-server.ps1",
		'```',
		"",
		'The canonical Studio scene is `place.rbxl`. Update the project from the',
		'already-fetched template ref with `scripts/template-project.ps1 update`.',
		"",
		('Template baseline: `{0}`.' -f $baseline)
	) -join "`n") + "`n"
	$actualPlainReadme = [IO.File]::ReadAllText((Join-Path $plainDestination "README.md")).Replace("`r`n", "`n")
	Assert-True ($actualPlainReadme -ceq $expectedPlainReadme) "originless Apply must generate the exact README text with intact Markdown and no stray carriage returns"
	Assert-True ([IO.File]::ReadAllText((Join-Path $plainDestination "src/ReplicatedStorage/Project/Client/UI/DerivedWindowConfig.luau")).Replace("`r`n", "`n") -eq "--!strict`n`nreturn table.freeze({})`n") "originless Apply must create the exact project UI config"
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $plainDestination "tests/plain-ignored.txt")) -and -not (Test-Path -LiteralPath (Join-Path $plainDestination "working-tree-only.txt"))) "originless Apply must exclude ignored and untracked source files"

	$plainFeature = Invoke-Tool -Tool $featureTool -Arguments @("new", "-RepositoryPath", $plainDestination, "-Title", "Plain Client Work")
	Assert-True ($plainFeature.Text.Contains("CREATED F-0001")) "plain derived client must allocate F-0001 without Git"
	$plainFeatureStatus = Invoke-Tool -Tool $featureTool -Arguments @("status", "-RepositoryPath", $plainDestination)
	Assert-True ($plainFeatureStatus.Text.Contains("TF-0011") -and $plainFeatureStatus.Text.Contains("namespace=template access=read-only") -and $plainFeatureStatus.Text.Contains("F-0001 state=open")) "plain derived status must expose inherited template history as read-only"
	Assert-CommandFails -Tool $featureTool -Arguments @("close", "-RepositoryPath", $plainDestination, "-Feature", "TF-0011") -Contains "read-only" | Out-Null
	Invoke-Tool -Tool $featureTool -Arguments @("close", "-RepositoryPath", $plainDestination, "-Feature", "F-0001") | Out-Null
	Assert-True ((Read-Json (Join-Path $plainDestination "docs/Features/project/plain-client-work/feature.json")).state -eq "done") "plain derived close must persist F-0001 as done"
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $plainDestination ".git"))) "plain feature bookkeeping must not create Git metadata"

	$brokenPlainRoot = Join-Path $testRoot "BrokenPlainRoot"
	Write-Utf8NoBom -Path (Join-Path $brokenPlainRoot ".git") -Content "gitdir: missing`n"
	Assert-CommandFails -Tool $featureTool -Arguments @("new", "-RepositoryPath", $brokenPlainRoot, "-Title", "Must Fail") -Contains "broken .git" | Out-Null
	$nestedPlainRoot = Join-Path $templateRoot "NestedPlainRoot"
	[IO.Directory]::CreateDirectory($nestedPlainRoot) | Out-Null
	Assert-CommandFails -Tool $featureTool -Arguments @("new", "-RepositoryPath", $nestedPlainRoot, "-Title", "Must Fail") -Contains "repository root exactly" | Out-Null
	Remove-Item -LiteralPath $nestedPlainRoot -Recurse -Force
	Remove-Item -LiteralPath (Join-Path $templateRoot "tests") -Recurse -Force
	Remove-Item -LiteralPath (Join-Path $templateRoot "working-tree-only.txt") -Force

	$derived = New-DerivedClone -TemplateRoot $templateRoot -Destination (Join-Path $testRoot "SampleGame")
	$placeBefore = Get-Hash (Join-Path $derived "place.rbxl")
	$statusBefore = Get-StatusText $derived
	$headBefore = ([string](Invoke-TestGit -Root $derived -Arguments @("rev-parse", "HEAD")).Output[0]).Trim()

	$check = Invoke-Tool -Tool $templateTool -Arguments @("init", "-Check", "-RepositoryPath", $derived)
	Assert-True ($check.Text.Contains("INIT PLAN")) "init check must report a plan"
	Assert-True ((Get-StatusText $derived) -eq $statusBefore) "init check must be read-only"
	Assert-True (([string](Invoke-TestGit -Root $derived -Arguments @("rev-parse", "HEAD")).Output[0]).Trim() -eq $headBefore) "init check must preserve HEAD"

	Invoke-Tool -Tool $templateTool -Arguments @("init", "-Apply", "-RepositoryPath", $derived) | Out-Null
	$config = Read-Json (Join-Path $derived "default.project.json")
	Assert-True ($config.name -eq "SampleGame") "init must set the repository directory name"
	Assert-True ($null -eq $config.PSObject.Properties["placeId"] -and $null -eq $config.PSObject.Properties["gameId"] -and $null -eq $config.PSObject.Properties["servePlaceIds"]) "init must remove the inherited identity tuple"
	Assert-True ($null -eq $config.PSObject.Properties["servePort"]) "init must remove inherited servePort"
	Assert-True ((Get-Hash (Join-Path $derived "place.rbxl")) -eq $placeBefore) "init must preserve place bytes"
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $derived "docs/adr/project"))) "init must keep project ADR namespace optional"
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $derived "docs/Features/project"))) "init must keep project feature namespace optional"
	Assert-True ([IO.File]::ReadAllText((Join-Path $derived "src/ReplicatedStorage/Project/Client/UI/DerivedWindowConfig.luau")).Replace("`r`n", "`n") -eq "--!strict`n`nreturn table.freeze({})`n") "init must create the exact minimal project UI config"

	# Validation must have identical structural meaning before staging, while staged, and after commit.
	Invoke-Tool -Tool $templateTool -Arguments @("validate", "-RepositoryPath", $derived) | Out-Null
	Invoke-TestGit -Root $derived -Arguments @("add", "README.md", "default.project.json") | Out-Null
	Invoke-Tool -Tool $templateTool -Arguments @("validate", "-RepositoryPath", $derived) | Out-Null
	Commit-All -Root $derived -Message "initialize project" | Out-Null
	Invoke-Tool -Tool $templateTool -Arguments @("validate", "-RepositoryPath", $derived) | Out-Null
	$localOnlyTarget = ([string](Invoke-TestGit -Root $derived -Arguments @("rev-parse", "HEAD")).Output[0]).Trim()
	Assert-CommandFails -Tool $templateTool -Arguments @("update", "-Check", "-RepositoryPath", $derived, "-TargetRef", $localOnlyTarget) -Contains "not reachable from any fetched refs/remotes/upstream" | Out-Null

	if (-not $Extended) {
		# Compatibility repair also supports unpublished derived projects with no cloud tuple.
		$unpublishedRepair = New-DerivedClone -TemplateRoot $templateRoot -Destination (Join-Path $testRoot "UnpublishedRepair")
		$unpublishedConfigPath = Join-Path $unpublishedRepair "default.project.json"
		$unpublishedConfig = Read-Json $unpublishedConfigPath
		$unpublishedConfig.name = "UnpublishedStableRojoName"
		foreach ($identityName in @("placeId", "gameId", "servePlaceIds")) { $unpublishedConfig.PSObject.Properties.Remove($identityName) }
		Write-Utf8NoBom -Path $unpublishedConfigPath -Content (($unpublishedConfig | ConvertTo-Json -Depth 20) + "`n")
		Commit-All -Root $unpublishedRepair -Message "legacy unpublished derived project" | Out-Null
		Invoke-Tool -Tool $templateTool -Arguments @("repair", "-Apply", "-RepositoryPath", $unpublishedRepair) | Out-Null
		$repairedUnpublishedConfig = Read-Json $unpublishedConfigPath
		Assert-True (Test-Path -LiteralPath (Join-Path $unpublishedRepair "src/ReplicatedStorage/Project/Client/UI/DerivedWindowConfig.luau")) "unpublished repair must create the missing project UI config"
		Assert-True ($null -eq $repairedUnpublishedConfig.PSObject.Properties["placeId"] -and $null -eq $repairedUnpublishedConfig.PSObject.Properties["gameId"] -and $null -eq $repairedUnpublishedConfig.PSObject.Properties["servePlaceIds"]) "unpublished repair must preserve complete cloud identity absence"
		Commit-All -Root $unpublishedRepair -Message "repair unpublished project" | Out-Null

		$partialRepair = New-DerivedClone -TemplateRoot $templateRoot -Destination (Join-Path $testRoot "PartialRepair")
		$partialConfigPath = Join-Path $partialRepair "default.project.json"
		$partialConfig = Read-Json $partialConfigPath
		$partialConfig.name = "PartialIdentity"
		$partialConfig.PSObject.Properties.Remove("gameId")
		$partialConfig.PSObject.Properties.Remove("servePlaceIds")
		Write-Utf8NoBom -Path $partialConfigPath -Content (($partialConfig | ConvertTo-Json -Depth 20) + "`n")
		Commit-All -Root $partialRepair -Message "invalid partial identity" | Out-Null
		Assert-CommandFails -Tool $templateTool -Arguments @("repair", "-Check", "-RepositoryPath", $partialRepair) -Contains "either all of placeId, gameId, and servePlaceIds or none" | Out-Null

		$templateTupleRepair = New-DerivedClone -TemplateRoot $templateRoot -Destination (Join-Path $testRoot "TemplateTupleRepair")
		$templateTupleConfigPath = Join-Path $templateTupleRepair "default.project.json"
		$templateTupleConfig = Read-Json $templateTupleConfigPath
		$templateTupleConfig.name = "TemplateTupleIdentity"
		Write-Utf8NoBom -Path $templateTupleConfigPath -Content (($templateTupleConfig | ConvertTo-Json -Depth 20) + "`n")
		Commit-All -Root $templateTupleRepair -Message "invalid inherited template identity" | Out-Null
		Assert-CommandFails -Tool $templateTool -Arguments @("repair", "-Check", "-RepositoryPath", $templateTupleRepair) -Contains "non-inheritable template validation PlaceId" | Out-Null

		# Update preserves raw protected bytes even when autocrlf would rewrite a checkout.
		Invoke-TestGit -Root $derived -Arguments @("config", "core.autocrlf", "true") | Out-Null
		$focusedReadmeBytes = [Text.Encoding]::UTF8.GetBytes("# SampleGame`nLF README PREIMAGE`n")
		$focusedPlaceBytes = [Text.Encoding]::UTF8.GetBytes("PLACE-PROJECT-LF`n`0BINARY")
		[IO.File]::WriteAllBytes((Join-Path $derived "README.md"), $focusedReadmeBytes)
		[IO.File]::WriteAllBytes((Join-Path $derived "place.rbxl"), $focusedPlaceBytes)
		Commit-All -Root $derived -Message "project LF protected preimage" | Out-Null
		Assert-True (Test-BytesEqual -Left ([IO.File]::ReadAllBytes((Join-Path $derived "README.md"))) -Right $focusedReadmeBytes) "test precondition must keep LF README bytes with autocrlf=true"
		Assert-True (Test-BytesEqual -Left ([IO.File]::ReadAllBytes((Join-Path $derived "place.rbxl"))) -Right $focusedPlaceBytes) "test precondition must keep LF place bytes with autocrlf=true"

		$focusedTemplateConfig = Read-Json (Join-Path $templateRoot "default.project.json")
		$focusedTemplateConfig.tree | Add-Member -NotePropertyName ServerStorage -NotePropertyValue ([PSCustomObject]@{ '$className' = 'Folder' })
		Write-Utf8NoBom -Path (Join-Path $templateRoot "default.project.json") -Content (($focusedTemplateConfig | ConvertTo-Json -Depth 20) + "`n")
		Write-Utf8NoBom -Path (Join-Path $templateRoot "README.md") -Content "# Incoming template README`n"
		[IO.File]::WriteAllBytes((Join-Path $templateRoot "place.rbxl"), [Text.Encoding]::UTF8.GetBytes("PLACE-INCOMING`n`0BINARY"))
		Write-Utf8NoBom -Path (Join-Path $templateRoot "focused-update.txt") -Content "focused`n"
		Commit-All -Root $templateRoot -Message "focused template update" | Out-Null
		Invoke-TestGit -Root $derived -Arguments @("fetch", "upstream") | Out-Null
		$focusedApply = Invoke-Tool -Tool $templateTool -Arguments @("update", "-Apply", "-RepositoryPath", $derived)
		Assert-True ($focusedApply.Text.Contains("UPDATE APPLIED") -and -not $focusedApply.Text.Contains("unresolved non-protected conflicts")) "successful Git stderr must remain diagnostic and never become machine-readable unresolved-path output"
		$focusedUpdatedConfig = Read-Json (Join-Path $derived "default.project.json")
		Assert-True (Test-Path -LiteralPath (Join-Path $derived "focused-update.txt")) "focused update must apply an ordinary incoming template file"
		Assert-True ($focusedUpdatedConfig.name -eq "SampleGame" -and $focusedUpdatedConfig.tree.ServerStorage.'$className' -eq "Folder") "focused update must structurally merge incoming config while preserving project identity"
		Assert-True (Test-BytesEqual -Left ([IO.File]::ReadAllBytes((Join-Path $derived "README.md"))) -Right $focusedReadmeBytes) "autocrlf=true update must preserve raw README bytes"
		Assert-True (Test-BytesEqual -Left ([IO.File]::ReadAllBytes((Join-Path $derived "place.rbxl"))) -Right $focusedPlaceBytes) "autocrlf=true update must preserve raw place bytes"
		$focusedUpdateHead = ([string](Invoke-TestGit -Root $derived -Arguments @("rev-parse", "HEAD")).Output[0]).Trim()
		$focusedNoOp = Invoke-Tool -Tool $templateTool -Arguments @("update", "-Check", "-RepositoryPath", $derived)
		Assert-True ($focusedNoOp.Text.Contains("UPDATE CURRENT") -and ([string](Invoke-TestGit -Root $derived -Arguments @("rev-parse", "HEAD")).Output[0]).Trim() -eq $focusedUpdateHead) "second update check must be a read-only no-op"
		Invoke-TestGit -Root $unpublishedRepair -Arguments @("fetch", "upstream") | Out-Null
		Invoke-Tool -Tool $templateTool -Arguments @("update", "-Apply", "-RepositoryPath", $unpublishedRepair) | Out-Null
		$updatedUnpublishedConfig = Read-Json $unpublishedConfigPath
		Assert-True ($null -eq $updatedUnpublishedConfig.PSObject.Properties["placeId"] -and $null -eq $updatedUnpublishedConfig.PSObject.Properties["gameId"] -and $null -eq $updatedUnpublishedConfig.PSObject.Properties["servePlaceIds"]) "subsequent template update must preserve cloud identity absence"

		# A post-merge validation failure restores every target-delta path byte-exactly before claiming rollback.
		Write-Utf8NoBom -Path (Join-Path $templateRoot "shared.txt") -Content "incoming rollback mutation`n"
		Invoke-TestGit -Root $templateRoot -Arguments @("rm", "focused-update.txt") | Out-Null
		Write-Utf8NoBom -Path (Join-Path $templateRoot "rollback-added.txt") -Content "must disappear on rollback`n"
		$rollbackViolation = "src/ReplicatedStorage/Shared/Audio/RollbackViolation.luau"
		Write-Utf8NoBom -Path (Join-Path $templateRoot $rollbackViolation) -Content "--!strict`nreturn function(remote) remote:FireAllClients({}) end`n"
		Commit-All -Root $templateRoot -Message "forced post-merge update failure" | Out-Null
		Invoke-TestGit -Root $derived -Arguments @("fetch", "upstream") | Out-Null
		$rollbackExistingPaths = @("README.md", "place.rbxl", "default.project.json", "shared.txt", "focused-update.txt")
		$rollbackBytes = @{}
		foreach ($relative in $rollbackExistingPaths) { $rollbackBytes[$relative] = [IO.File]::ReadAllBytes((Join-Path $derived $relative)) }
		$rollbackHead = ([string](Invoke-TestGit -Root $derived -Arguments @("rev-parse", "HEAD")).Output[0]).Trim()
		$rollbackIndex = ([string](Invoke-TestGit -Root $derived -Arguments @("write-tree")).Output[0]).Trim()
		$rollbackFailure = Assert-CommandFails -Tool $templateTool -Arguments @("update", "-Apply", "-RepositoryPath", $derived) -Contains "exact pre-state was restored"
		Assert-True (-not $rollbackFailure.Text.Contains("rollback verification failed")) "update must claim exact rollback only after all byte and repository receipts pass"
		foreach ($relative in $rollbackExistingPaths) {
			Assert-True (Test-BytesEqual -Left ([IO.File]::ReadAllBytes((Join-Path $derived $relative))) -Right ([byte[]]$rollbackBytes[$relative])) "failed update must restore raw bytes for target-delta path $relative"
		}
		Assert-True (-not (Test-Path -LiteralPath (Join-Path $derived "rollback-added.txt")) -and -not (Test-Path -LiteralPath (Join-Path $derived $rollbackViolation))) "failed update must delete target-added paths that were absent before merge"
		Assert-True (([string](Invoke-TestGit -Root $derived -Arguments @("rev-parse", "HEAD")).Output[0]).Trim() -eq $rollbackHead -and ([string](Invoke-TestGit -Root $derived -Arguments @("write-tree")).Output[0]).Trim() -eq $rollbackIndex -and (Get-StatusText $derived) -eq "") "failed update must restore exact HEAD, index, and status"
		$focusedFeature = Invoke-Tool -Tool $featureTool -Arguments @("new", "-RepositoryPath", $derived, "-Title", "Focused Bookkeeping")
		Assert-True ($focusedFeature.Text.Contains("CREATED F-0001")) "focused feature new must allocate the owning namespace"
		Invoke-Tool -Tool $featureTool -Arguments @("close", "-RepositoryPath", $derived, "-Feature", "F-0001") | Out-Null
		Assert-True ((Read-Json (Join-Path $derived "docs/Features/project/focused-bookkeeping/feature.json")).state -eq "done") "focused feature close must persist done"
		Write-Output "PASS template-tools.tests.ps1 mode=focused host=$hostExe assertions=$script:Passed"
		return
	}

	# A legacy bootstrap README is project-owned and remains byte-exact during init.
	$legacy = New-DerivedClone -TemplateRoot $templateRoot -Destination (Join-Path $testRoot "LegacyGame")
	Write-Utf8NoBom -Path (Join-Path $legacy "README.md") -Content "# Existing target README`nCUSTOM`n"
	Commit-All -Root $legacy -Message "legacy target bootstrap" | Out-Null
	$legacyReadmeHash = Get-Hash (Join-Path $legacy "README.md")
	Invoke-Tool -Tool $templateTool -Arguments @("init", "-Apply", "-RepositoryPath", $legacy, "-TargetRef", "refs/remotes/upstream/main") | Out-Null
	Assert-True ((Get-Hash (Join-Path $legacy "README.md")) -eq $legacyReadmeHash) "explicit TargetRef init must preserve a custom bootstrap README"
	Assert-CommandFails -Tool $templateTool -Arguments @("validate", "-RepositoryPath", $legacy, "-TargetRef", "refs/remotes/upstream/missing") -Contains "does not resolve" | Out-Null

	# Prepared init preserves an authored UI config, and any post-write failure restores every touched byte.
	$transactionProject = New-DerivedClone -TemplateRoot $templateRoot -Destination (Join-Path $testRoot "TransactionalGame")
	$authoredUiPath = Join-Path $transactionProject "src/ReplicatedStorage/Project/Client/UI/DerivedWindowConfig.luau"
	$authoredUi = "--!strict`n`nlocal Example = require(script.Parent.Definitions.Example)`nreturn table.freeze({ Example })`n"
	Write-Utf8NoBom -Path $authoredUiPath -Content $authoredUi
	Commit-All -Root $transactionProject -Message "legacy authored UI boundary" | Out-Null
	$transactionConfigHash = Get-Hash (Join-Path $transactionProject "default.project.json")
	$transactionReadmeHash = Get-Hash (Join-Path $transactionProject "README.md")
	$transactionUiHash = Get-Hash $authoredUiPath
	$fakeBin = Join-Path $testRoot "failing-rojo-bin"
	Write-Utf8NoBom -Path (Join-Path $fakeBin "rojo.cmd") -Content "@echo forced rojo failure 1>&2`r`n@exit /b 23`r`n"
	$priorPath = $env:PATH
	try {
		$env:PATH = "$fakeBin;$priorPath"
		Assert-CommandFails -Tool $templateTool -Arguments @("init", "-Apply", "-RepositoryPath", $transactionProject) -Contains "exact pre-state was restored" | Out-Null
	} finally {
		$env:PATH = $priorPath
	}
	Assert-True ((Get-Hash (Join-Path $transactionProject "default.project.json")) -eq $transactionConfigHash -and (Get-Hash (Join-Path $transactionProject "README.md")) -eq $transactionReadmeHash -and (Get-Hash $authoredUiPath) -eq $transactionUiHash) "failed init must restore config, README, and authored UI bytes exactly"
	Assert-True ((Get-StatusText $transactionProject) -eq "") "failed init rollback must restore a clean index and worktree"

	# A pre-UI-boundary derived project has an explicit compatibility repair path and retains all owned identity/content.
	$preTfProject = New-DerivedClone -TemplateRoot $templateRoot -Destination (Join-Path $testRoot "PreTfProject")
	$preTfConfig = Read-Json (Join-Path $preTfProject "default.project.json")
	$preTfConfig.name = "LegacyStableRojoName"
	$preTfConfig.placeId = [Int64]7101
	$preTfConfig.gameId = [Int64]8101
	$preTfConfig.servePlaceIds = @([Int64]7101)
	$preTfConfig | Add-Member -NotePropertyName servePort -NotePropertyValue 4777
	Write-Utf8NoBom -Path (Join-Path $preTfProject "default.project.json") -Content (($preTfConfig | ConvertTo-Json -Depth 20) + "`n")
	Write-Utf8NoBom -Path (Join-Path $preTfProject "README.md") -Content "# Preserved legacy README`n"
	Write-Utf8NoBom -Path (Join-Path $preTfProject "docs/Features/project/legacy-note.txt") -Content "preserve`n"
	Commit-All -Root $preTfProject -Message "legacy derived project before UI boundary" | Out-Null
	$preTfConfigHash = Get-Hash (Join-Path $preTfProject "default.project.json")
	$preTfReadmeHash = Get-Hash (Join-Path $preTfProject "README.md")
	$preTfPlaceHash = Get-Hash (Join-Path $preTfProject "place.rbxl")
	Assert-CommandFails -Tool $templateTool -Arguments @("update", "-Check", "-RepositoryPath", $preTfProject) -Contains "DerivedWindowConfig" | Out-Null
	Invoke-Tool -Tool $templateTool -Arguments @("repair", "-Check", "-RepositoryPath", $preTfProject) | Out-Null
	Invoke-Tool -Tool $templateTool -Arguments @("repair", "-Apply", "-RepositoryPath", $preTfProject) | Out-Null
	Assert-True ((Get-Hash (Join-Path $preTfProject "default.project.json")) -eq $preTfConfigHash -and (Get-Hash (Join-Path $preTfProject "README.md")) -eq $preTfReadmeHash -and (Get-Hash (Join-Path $preTfProject "place.rbxl")) -eq $preTfPlaceHash) "repair must preserve identity/config, README, and place bytes"
	Assert-True (Test-Path -LiteralPath (Join-Path $preTfProject "docs/Features/project/legacy-note.txt")) "repair must preserve existing project namespaces"
	Commit-All -Root $preTfProject -Message "compatibility repair" | Out-Null

	# Prepare a normal upstream update. Incoming IDs/servePort are never inherited.
	$normalBase = ([string](Invoke-TestGit -Root $templateRoot -Arguments @("rev-parse", "HEAD")).Output[0]).Trim()
	$templateConfig = Read-Json (Join-Path $templateRoot "default.project.json")
	$templateConfig.tree | Add-Member -NotePropertyName ServerStorage -NotePropertyValue ([PSCustomObject]@{ '$className' = 'Folder' })
	$templateConfig | Add-Member -NotePropertyName servePort -NotePropertyValue 39999
	Write-Utf8NoBom -Path (Join-Path $templateRoot "default.project.json") -Content (($templateConfig | ConvertTo-Json -Depth 20) + "`n")
	Write-Utf8NoBom -Path (Join-Path $templateRoot "README.md") -Content "# Template changed`n"
	[IO.File]::WriteAllBytes((Join-Path $templateRoot "place.rbxl"), [Text.Encoding]::UTF8.GetBytes("PLACE-V2`0BINARY"))
	Write-Utf8NoBom -Path (Join-Path $templateRoot "incoming.txt") -Content "incoming`n"
	$normalTarget = Commit-All -Root $templateRoot -Message "normal template update"
	Invoke-TestGit -Root $preTfProject -Arguments @("fetch", "upstream") | Out-Null
	Invoke-Tool -Tool $templateTool -Arguments @("update", "-Apply", "-RepositoryPath", $preTfProject) | Out-Null
	$preTfUpdated = Read-Json (Join-Path $preTfProject "default.project.json")
	Assert-True ($preTfUpdated.name -eq "LegacyStableRojoName" -and $preTfUpdated.placeId -eq 7101 -and $preTfUpdated.servePort -eq 4777) "repaired legacy project must update while preserving project-owned identity and port"
	Invoke-TestGit -Root $derived -Arguments @("fetch", "upstream") | Out-Null
	[IO.Directory]::CreateDirectory((Join-Path $derived "tests")) | Out-Null
	Write-Utf8NoBom -Path (Join-Path $derived "tests/legacy-evidence.json") -Content "ignored legacy`n"
	$readmeBeforeUpdate = Get-Hash (Join-Path $derived "README.md")
	$placeBeforeUpdate = Get-Hash (Join-Path $derived "place.rbxl")
	$updateHead = ([string](Invoke-TestGit -Root $derived -Arguments @("rev-parse", "HEAD")).Output[0]).Trim()
	$updateCheck = Invoke-Tool -Tool $templateTool -Arguments @("update", "-Check", "-RepositoryPath", $derived)
	Assert-True ($updateCheck.Text.Contains("UPDATE PLAN")) "update check must report plan"
	Assert-True (([string](Invoke-TestGit -Root $derived -Arguments @("rev-parse", "HEAD")).Output[0]).Trim() -eq $updateHead) "update check must preserve HEAD"
	Invoke-Tool -Tool $templateTool -Arguments @("update", "-Apply", "-RepositoryPath", $derived) | Out-Null
	$updated = Read-Json (Join-Path $derived "default.project.json")
	Assert-True ($updated.name -eq "SampleGame" -and $updated.tree.ServerStorage.'$className' -eq "Folder") "update must preserve name and accept compatible incoming JSON"
	Assert-True ($null -eq $updated.PSObject.Properties["placeId"] -and $null -eq $updated.PSObject.Properties["servePort"]) "incoming identity and servePort must remain absent when local values were absent"
	Assert-True ((Get-Hash (Join-Path $derived "README.md")) -eq $readmeBeforeUpdate) "update must preserve README exactly"
	Assert-True ((Get-Hash (Join-Path $derived "place.rbxl")) -eq $placeBeforeUpdate) "update must preserve place exactly"
	Assert-True (Test-Path -LiteralPath (Join-Path $derived "tests/legacy-evidence.json")) "known ignored legacy content must remain untouched"
	Assert-True ((Get-StatusText $derived) -eq "") "successful update must leave tracked/index clean; ignored legacy files are not status dirt"

	# Complete local identity and an existing custom servePort are preserved as one tuple/policy.
	$identityProject = New-DerivedClone -TemplateRoot $templateRoot -Destination (Join-Path $testRoot "IdentityGame")
	# Use the old exact target ref to model a project initialized before the normal update.
	Invoke-TestGit -Root $identityProject -Arguments @("update-ref", "refs/remotes/upstream/old", $normalBase) | Out-Null
	Invoke-TestGit -Root $identityProject -Arguments @("reset", "--hard", $normalBase) | Out-Null
	Invoke-Tool -Tool $templateTool -Arguments @("init", "-Apply", "-RepositoryPath", $identityProject, "-TargetRef", "refs/remotes/upstream/old") | Out-Null
	$identityConfig = Read-Json (Join-Path $identityProject "default.project.json")
	$identityConfig | Add-Member -NotePropertyName placeId -NotePropertyValue ([Int64]7001)
	$identityConfig | Add-Member -NotePropertyName gameId -NotePropertyValue ([Int64]8001)
	$identityConfig | Add-Member -NotePropertyName servePlaceIds -NotePropertyValue @([Int64]7001, [Int64]7002)
	$identityConfig | Add-Member -NotePropertyName servePort -NotePropertyValue 4567
	$identityConfig.name = "StableCustomRojoIdentity"
	Write-Utf8NoBom -Path (Join-Path $identityProject "default.project.json") -Content (($identityConfig | ConvertTo-Json -Depth 20) + "`n")
	Write-Utf8NoBom -Path (Join-Path $identityProject "src/ReplicatedStorage/Shared/Audio/LegacyDirectRemote.luau") -Content "--!strict`nreturn function(remote) remote:FireServer({}) end`n"
	Commit-All -Root $identityProject -Message "project identity" | Out-Null
	Invoke-Tool -Tool $templateTool -Arguments @("update", "-Apply", "-RepositoryPath", $identityProject, "-TargetRef", "refs/remotes/upstream/main") | Out-Null
	$identityUpdated = Read-Json (Join-Path $identityProject "default.project.json")
	Assert-True ($identityUpdated.name -eq "StableCustomRojoIdentity") "update must preserve an arbitrary non-empty project-owned Rojo name"
	Assert-True ($identityUpdated.placeId -eq 7001 -and $identityUpdated.gameId -eq 8001 -and @($identityUpdated.servePlaceIds).Count -eq 2) "complete project identity tuple must survive update"
	Assert-True ($identityUpdated.servePort -eq 4567) "only an existing local custom servePort may survive update"
	Assert-True (Test-Path -LiteralPath (Join-Path $identityProject "src/ReplicatedStorage/Shared/Audio/LegacyDirectRemote.luau")) "unmodified historical project divergence must not be rescanned during an unrelated update"

	# Clean tracked/index preconditions are independent and actionable.
	Write-Utf8NoBom -Path (Join-Path $derived "shared.txt") -Content "dirty`n"
	Assert-CommandFails -Tool $templateTool -Arguments @("update", "-Check", "-RepositoryPath", $derived, "-TargetRef", $normalBase) -Contains "Tracked working-tree changes" | Out-Null
	Invoke-TestGit -Root $derived -Arguments @("restore", "--", "shared.txt") | Out-Null
	Write-Utf8NoBom -Path (Join-Path $derived "shared.txt") -Content "staged`n"
	Invoke-TestGit -Root $derived -Arguments @("add", "shared.txt") | Out-Null
	Assert-CommandFails -Tool $templateTool -Arguments @("update", "-Check", "-RepositoryPath", $derived, "-TargetRef", $normalBase) -Contains "index contains staged" | Out-Null
	Invoke-TestGit -Root $derived -Arguments @("restore", "--staged", "shared.txt") | Out-Null
	Invoke-TestGit -Root $derived -Arguments @("restore", "--", "shared.txt") | Out-Null

	# Independent target refs exercise fail-closed reserved and ignored collisions.
	Invoke-TestGit -Root $templateRoot -Arguments @("switch", "-c", "reserved-case", $normalTarget) | Out-Null
	Write-Utf8NoBom -Path (Join-Path $templateRoot "Docs/Features/PROJECT/collision.txt") -Content "forbidden`n"
	$reservedTarget = Commit-All -Root $templateRoot -Message "reserved collision"
	Invoke-TestGit -Root $templateRoot -Arguments @("switch", "-c", "ignored-case", $normalTarget) | Out-Null
	Write-Utf8NoBom -Path (Join-Path $templateRoot "Tests/Legacy-Evidence.json") -Content "incoming collision`n"
	Invoke-TestGit -Root $templateRoot -Arguments @("add", "-f", "Tests/Legacy-Evidence.json") | Out-Null
	$ignoredTarget = Commit-All -Root $templateRoot -Message "ignored collision"
	Invoke-TestGit -Root $derived -Arguments @("fetch", "upstream", "+refs/heads/*:refs/remotes/upstream/*") | Out-Null
	Assert-CommandFails -Tool $templateTool -Arguments @("update", "-Check", "-RepositoryPath", $derived, "-TargetRef", "refs/remotes/upstream/reserved-case") -Contains "reserved project-owned" | Out-Null
	Assert-CommandFails -Tool $templateTool -Arguments @("update", "-Check", "-RepositoryPath", $derived, "-TargetRef", "refs/remotes/upstream/ignored-case") -Contains "Ignored local content collides" | Out-Null

	# A non-protected textual conflict is aborted with exact HEAD/index/tree receipts.
	Invoke-TestGit -Root $templateRoot -Arguments @("switch", "-c", "conflict-case", $normalTarget) | Out-Null
	Write-Utf8NoBom -Path (Join-Path $templateRoot "shared.txt") -Content "incoming conflict`n"
	$conflictTarget = Commit-All -Root $templateRoot -Message "incoming conflict"
	Invoke-TestGit -Root $derived -Arguments @("fetch", "upstream", "+refs/heads/*:refs/remotes/upstream/*") | Out-Null
	Write-Utf8NoBom -Path (Join-Path $derived "shared.txt") -Content "local conflict`n"
	Commit-All -Root $derived -Message "local conflict" | Out-Null
	$preConflictHead = ([string](Invoke-TestGit -Root $derived -Arguments @("rev-parse", "HEAD")).Output[0]).Trim()
	$preConflictIndex = ([string](Invoke-TestGit -Root $derived -Arguments @("write-tree")).Output[0]).Trim()
	$conflictFailure = Assert-CommandFails -Tool $templateTool -Arguments @("update", "-Apply", "-RepositoryPath", $derived, "-TargetRef", "refs/remotes/upstream/conflict-case") -Contains "exact pre-state was restored"
	Assert-True ($conflictFailure.Text.Contains("preHead=") -and $conflictFailure.Text.Contains("preIndex=")) "abort diagnostic must include receipts"
	Assert-True (([string](Invoke-TestGit -Root $derived -Arguments @("rev-parse", "HEAD")).Output[0]).Trim() -eq $preConflictHead) "failed merge must restore HEAD"
	Assert-True (([string](Invoke-TestGit -Root $derived -Arguments @("write-tree")).Output[0]).Trim() -eq $preConflictIndex) "failed merge must restore index/tree"
	Assert-True ((Get-StatusText $derived) -eq "") "failed merge must restore clean tracked state"

	# Update validation owns only the new candidate delta and rejects structural/source regressions before commit.
	Invoke-TestGit -Root $templateRoot -Arguments @("switch", "-c", "candidate-violation", $normalTarget) | Out-Null
	Write-Utf8NoBom -Path (Join-Path $templateRoot "src/ReplicatedStorage/Shared/Audio/IncomingBroadcast.luau") -Content "--!strict`nreturn function(remote) remote:FireAllClients({}) end`n"
	$candidateViolationTarget = Commit-All -Root $templateRoot -Message "candidate source violation"
	Invoke-TestGit -Root $templateRoot -Arguments @("switch", "-c", "candidate-delete", $normalTarget) | Out-Null
	Invoke-TestGit -Root $templateRoot -Arguments @("rm", "src/StarterPlayerScripts/Bootstrap.client.luau") | Out-Null
	$candidateDeleteTarget = Commit-All -Root $templateRoot -Message "candidate deletes bootstrap"
	Invoke-TestGit -Root $templateRoot -Arguments @("switch", "-c", "reserved-base", $normalTarget) | Out-Null
	Write-Utf8NoBom -Path (Join-Path $templateRoot "docs/Features/project/hidden.txt") -Content "reserved`n"
	$reservedBaseTarget = Commit-All -Root $templateRoot -Message "reserved base"
	Invoke-TestGit -Root $templateRoot -Arguments @("switch", "-c", "reserved-hidden", $reservedBaseTarget) | Out-Null
	Write-Utf8NoBom -Path (Join-Path $templateRoot "after-reserved.txt") -Content "target`n"
	$reservedHiddenTarget = Commit-All -Root $templateRoot -Message "target after reserved base"

	$candidate = New-DerivedClone -TemplateRoot $templateRoot -Destination (Join-Path $testRoot "CandidateGame")
	Invoke-TestGit -Root $candidate -Arguments @("reset", "--hard", $normalTarget) | Out-Null
	foreach ($refPair in @(
		@("normal", $normalTarget),
		@("candidate-violation", $candidateViolationTarget),
		@("candidate-delete", $candidateDeleteTarget),
		@("reserved-hidden", $reservedHiddenTarget)
	)) { Invoke-TestGit -Root $candidate -Arguments @("update-ref", "refs/remotes/upstream/$($refPair[0])", $refPair[1]) | Out-Null }
	Invoke-Tool -Tool $templateTool -Arguments @("init", "-Apply", "-RepositoryPath", $candidate, "-TargetRef", "refs/remotes/upstream/normal") | Out-Null
	Commit-All -Root $candidate -Message "candidate initialized" | Out-Null
	$candidateHead = ([string](Invoke-TestGit -Root $candidate -Arguments @("rev-parse", "HEAD")).Output[0]).Trim()
	Assert-CommandFails -Tool $templateTool -Arguments @("update", "-Apply", "-RepositoryPath", $candidate, "-TargetRef", "refs/remotes/upstream/candidate-violation") -Contains "direct remote" | Out-Null
	Assert-True (([string](Invoke-TestGit -Root $candidate -Arguments @("rev-parse", "HEAD")).Output[0]).Trim() -eq $candidateHead -and (Get-StatusText $candidate) -eq "") "candidate source rejection must abort exactly"
	Assert-CommandFails -Tool $templateTool -Arguments @("update", "-Apply", "-RepositoryPath", $candidate, "-TargetRef", "refs/remotes/upstream/candidate-delete") -Contains "missing 'src/StarterPlayerScripts/Bootstrap.client.luau'" | Out-Null
	Assert-True (([string](Invoke-TestGit -Root $candidate -Arguments @("rev-parse", "HEAD")).Output[0]).Trim() -eq $candidateHead -and (Get-StatusText $candidate) -eq "") "bootstrap deletion rejection must abort exactly"

	# Reserved namespace detection inspects the full target tree even when the reserved path predates merge-base.
	Invoke-TestGit -Root $candidate -Arguments @("merge", "--no-edit", $reservedBaseTarget) | Out-Null
	Invoke-TestGit -Root $candidate -Arguments @("rm", "docs/Features/project/hidden.txt") | Out-Null
	Commit-All -Root $candidate -Message "project removes inherited reserved collision" | Out-Null
	Assert-CommandFails -Tool $templateTool -Arguments @("update", "-Check", "-RepositoryPath", $candidate, "-TargetRef", "refs/remotes/upstream/reserved-hidden") -Contains "TargetRef contains reserved project-owned paths" | Out-Null

	# Cheap source-boundary mutations: one owner-positive and representative negatives.
	$boundary = New-DerivedClone -TemplateRoot $templateRoot -Destination (Join-Path $testRoot "BoundaryGame")
	Invoke-TestGit -Root $boundary -Arguments @("reset", "--hard", $normalTarget) | Out-Null
	Invoke-TestGit -Root $boundary -Arguments @("update-ref", "refs/remotes/upstream/normal", $normalTarget) | Out-Null
	Invoke-Tool -Tool $templateTool -Arguments @("init", "-Apply", "-RepositoryPath", $boundary, "-TargetRef", "refs/remotes/upstream/normal") | Out-Null
	Commit-All -Root $boundary -Message "boundary initialized" | Out-Null
	Write-Utf8NoBom -Path (Join-Path $boundary "src/ReplicatedStorage/Project/Client/UI/DerivedWindowConfig.luau") -Content "--!strict`n`nlocal Example = require(script.Parent.Definitions.Example)`nreturn table.freeze({ Example })`n"
	Commit-All -Root $boundary -Message "author project window config" | Out-Null
	Invoke-Tool -Tool $templateTool -Arguments @("validate", "-RepositoryPath", $boundary, "-TargetRef", "refs/remotes/upstream/normal") | Out-Null
	Assert-True ($true) "derived validation must allow the existing authored frozen-sequence shape after exact empty initialization"
	$mutations = @(
		@("src/ServerScriptService/Tests/Auto.server.luau", "--!strict`n", "executable"),
		@("src/ReplicatedStorage/Shared/Other.luau", "--!strict`nreturn function(p) p:PreloadAsync({}) end`n", "outside ContentPreloader"),
		@("src/ReplicatedStorage/Shared/Teleport/Bad.luau", "--!strict`nlocal P=game:GetService(`"Players`")`nreturn P`n", "direct Players"),
		@("src/ReplicatedStorage/Shared/Teleport/Lifecycle.luau", "--!strict`nreturn function(players) players.PlayerAdded:Connect(function() end) end`n", "direct Players/remotes"),
		@("src/ReplicatedStorage/Shared/Audio/Bad.luau", "--!strict`nreturn function(r) r:FireServer({}) end`n", "direct remote"),
		@("src/ReplicatedStorage/Shared/Audio/Broadcast.luau", "--!strict`nreturn function(r) r:FireAllClients({}) end`n", "direct remote"),
		@("src/ReplicatedStorage/Shared/Audio/Writer.luau", "--!strict`nreturn function(x) x.AcousticSimulationEnabled = true end`n", "two property owners")
	)
	foreach ($mutation in $mutations) {
		$relative = $mutation[0]
		Write-Utf8NoBom -Path (Join-Path $boundary $relative) -Content $mutation[1]
		Invoke-TestGit -Root $boundary -Arguments @("add", "-f", "--", $relative) | Out-Null
		Assert-CommandFails -Tool $templateTool -Arguments @("validate", "-RepositoryPath", $boundary, "-TargetRef", "refs/remotes/upstream/normal") -Contains $mutation[2] | Out-Null
		Invoke-TestGit -Root $boundary -Arguments @("reset", "--", $relative) | Out-Null
		Remove-Item -LiteralPath (Join-Path $boundary $relative) -Force
	}
	Write-Utf8NoBom -Path (Join-Path $boundary ".agentic-pipeline-state/runtime.json") -Content "{}`n"
	Invoke-TestGit -Root $boundary -Arguments @("add", "-f", "--", ".agentic-pipeline-state/runtime.json") | Out-Null
	Assert-CommandFails -Tool $templateTool -Arguments @("validate", "-RepositoryPath", $boundary, "-TargetRef", "refs/remotes/upstream/normal") -Contains "Generated validation/runtime files" | Out-Null
	Invoke-TestGit -Root $boundary -Arguments @("reset", "--", ".agentic-pipeline-state/runtime.json") | Out-Null
	Remove-Item -LiteralPath (Join-Path $boundary ".agentic-pipeline-state/runtime.json") -Force

	# Feature v3 is deliberately smaller than the legacy lifecycle.
	$templateFeature = Invoke-Tool -Tool $featureTool -Arguments @("new", "-RepositoryPath", $templateRoot, "-Title", "Fast Template Work")
	Assert-True ($templateFeature.Text.Contains("CREATED TF-")) "template new must allocate TF"
	$projectFeature = Invoke-Tool -Tool $featureTool -Arguments @("new", "-RepositoryPath", $identityProject, "-Title", "Fast Project Work")
	Assert-True ($projectFeature.Text.Contains("CREATED F-0001")) "derived new must allocate F"
	$projectManifestPath = Join-Path $identityProject "docs/Features/project/fast-project-work/feature.json"
	$projectManifest = Read-Json $projectManifestPath
	Assert-True (@($projectManifest.PSObject.Properties.Name).Count -eq 7 -and $projectManifest.state -eq "open") "new must write only the seven-field schema-v3 contract"
	$status = Invoke-Tool -Tool $featureTool -Arguments @("status", "-RepositoryPath", $identityProject)
	Assert-True ($status.Text.Contains("namespace=template access=read-only") -and $status.Text.Contains("F-0001 state=open")) "derived status must read foreign history and owning state"
	Assert-CommandFails -Tool $featureTool -Arguments @("close", "-RepositoryPath", $identityProject, "-Feature", "TF-0011") -Contains "read-only" | Out-Null
	Invoke-Tool -Tool $featureTool -Arguments @("close", "-RepositoryPath", $identityProject, "-Feature", "F-0001") | Out-Null
	Invoke-Tool -Tool $featureTool -Arguments @("close", "-RepositoryPath", $identityProject, "-Feature", "F-0001") | Out-Null
	Assert-True ((Read-Json $projectManifestPath).state -eq "done") "close must be idempotent after done"

	# Owning legacy schema-v2 close preserves exact bytes once and migrates without contradictory activity.
	$legacyDir = Join-Path $identityProject "docs/Features/project/legacy-work"
	$legacyText = @"
{"schemaVersion":2,"id":"F-0002","slug":"legacy-work","title":"Legacy Work","status":"in_progress","activity":"paused","branch":"feature/legacy","baseCommit":"$baseline","startedAt":"2026-01-02T03:04:05Z","completedAt":null,"updatedAt":"2026-01-02T03:04:05Z","blockers":[],"artifacts":[],"verification":null,"recoveryLog":[]}
"@
	Write-Utf8NoBom -Path (Join-Path $legacyDir "feature.json") -Content $legacyText
	$legacyHandoffText = "# Legacy active handoff`n`nStill in progress.`n"
	Write-Utf8NoBom -Path (Join-Path $legacyDir "handoff.md") -Content $legacyHandoffText
	$legacyBytes = [IO.File]::ReadAllBytes((Join-Path $legacyDir "feature.json"))
	$legacyHandoffBytes = [IO.File]::ReadAllBytes((Join-Path $legacyDir "handoff.md"))
	Invoke-Tool -Tool $featureTool -Arguments @("close", "-RepositoryPath", $identityProject, "-Feature", "F-0002") | Out-Null
	$sidecar = [IO.File]::ReadAllBytes((Join-Path $legacyDir "feature.legacy.json"))
	Assert-True ([Convert]::ToBase64String($sidecar) -eq [Convert]::ToBase64String($legacyBytes)) "legacy sidecar must preserve exact bytes"
	$migrated = Read-Json (Join-Path $legacyDir "feature.json")
	Assert-True ($migrated.schemaVersion -eq 3 -and $migrated.state -eq "done" -and $null -eq $migrated.PSObject.Properties["activity"]) "legacy close must map to minimal done state"
	Assert-True (Test-BytesEqual -Left ([IO.File]::ReadAllBytes((Join-Path $legacyDir "handoff.legacy.md"))) -Right $legacyHandoffBytes) "close must preserve the exact historical handoff in a sidecar"
	Assert-True ([IO.File]::ReadAllText((Join-Path $legacyDir "handoff.md")).Contains("State: done.")) "current handoff must not contradict a done manifest"

	# A byte-equal pre-existing legacy sidecar models interruption after sidecar publication and must resume safely.
	$resumeDir = Join-Path $identityProject "docs/Features/project/resume-legacy"
	$resumeText = @"
{"schemaVersion":2,"id":"F-0005","slug":"resume-legacy","title":"Resume Legacy","status":"in_progress","activity":"active","startedAt":"2026-01-05T03:04:05Z"}
"@
	Write-Utf8NoBom -Path (Join-Path $resumeDir "feature.json") -Content $resumeText
	[IO.File]::WriteAllBytes((Join-Path $resumeDir "feature.legacy.json"), [IO.File]::ReadAllBytes((Join-Path $resumeDir "feature.json")))
	Invoke-Tool -Tool $featureTool -Arguments @("close", "-RepositoryPath", $identityProject, "-Feature", "F-0005") | Out-Null
	Assert-True ((Read-Json (Join-Path $resumeDir "feature.json")).state -eq "done") "byte-equal interrupted legacy migration must complete on retry"

	# Both possible close half-states are reconciled idempotently on retry.
	$manifestFirstDir = Join-Path $identityProject "docs/Features/project/manifest-first"
	Write-Utf8NoBom -Path (Join-Path $manifestFirstDir "feature.json") -Content '{"schemaVersion":3,"id":"F-0006","slug":"manifest-first","title":"Manifest First","state":"done","createdAt":"2026-01-06T03:04:05Z","updatedAt":"2026-01-06T03:04:05Z"}'
	$manifestFirstHandoff = "# Still active`n"
	Write-Utf8NoBom -Path (Join-Path $manifestFirstDir "handoff.md") -Content $manifestFirstHandoff
	$manifestFirstBytes = [IO.File]::ReadAllBytes((Join-Path $manifestFirstDir "handoff.md"))
	Invoke-Tool -Tool $featureTool -Arguments @("close", "-RepositoryPath", $identityProject, "-Feature", "F-0006") | Out-Null
	Assert-True (Test-BytesEqual -Left ([IO.File]::ReadAllBytes((Join-Path $manifestFirstDir "handoff.legacy.md"))) -Right $manifestFirstBytes) "manifest-first close retry must archive and replace the stale handoff"

	$handoffFirstDir = Join-Path $identityProject "docs/Features/project/handoff-first"
	Write-Utf8NoBom -Path (Join-Path $handoffFirstDir "feature.json") -Content '{"schemaVersion":3,"id":"F-0007","slug":"handoff-first","title":"Handoff First","state":"open","createdAt":"2026-01-07T03:04:05Z","updatedAt":"2026-01-07T03:04:05Z"}'
	Write-Utf8NoBom -Path (Join-Path $handoffFirstDir "handoff.md") -Content "# F-0007 closed`n`nState: done.`n"
	Invoke-Tool -Tool $featureTool -Arguments @("close", "-RepositoryPath", $identityProject, "-Feature", "F-0007") | Out-Null
	Assert-True ((Read-Json (Join-Path $handoffFirstDir "feature.json")).state -eq "done") "handoff-first close retry must complete the manifest transition"

	$readyLegacyDir = Join-Path $identityProject "docs/Features/project/ready-legacy"
	Write-Utf8NoBom -Path (Join-Path $readyLegacyDir "feature.json") -Content @"
{"schemaVersion":2,"id":"F-0003","slug":"ready-legacy","title":"Ready Legacy","status":"ready","activity":"none","branch":"feature/ready","baseCommit":"$baseline","startedAt":"2026-01-03T03:04:05Z","completedAt":"2026-01-04T03:04:05Z","updatedAt":"2026-01-04T03:04:05Z","blockers":[],"artifacts":[],"verification":null,"recoveryLog":[]}
"@
	Invoke-Tool -Tool $featureTool -Arguments @("close", "-RepositoryPath", $identityProject, "-Feature", "F-0003") | Out-Null
	Assert-True ((Read-Json (Join-Path $readyLegacyDir "feature.json")).schemaVersion -eq 3) "already-ready legacy close must still replace feature.json with schema v3"

	$invalidLegacyDir = Join-Path $identityProject "docs/Features/project/invalid-legacy"
	Write-Utf8NoBom -Path (Join-Path $invalidLegacyDir "feature.json") -Content '{"schemaVersion":2,"id":"F-0004","slug":"invalid-legacy","title":"Invalid Legacy","status":"in_progress","activity":"active","startedAt":"invalid"}'
	Assert-CommandFails -Tool $featureTool -Arguments @("close", "-RepositoryPath", $identityProject, "-Feature", "F-0004") -Contains "no sidecar" | Out-Null
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $invalidLegacyDir "feature.legacy.json"))) "invalid legacy metadata must fail before sidecar mutation"

	Write-Output "PASS template-tools.tests.ps1 mode=extended host=$hostExe assertions=$script:Passed"
} finally {
	$env:PATH = $originalPath
	$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
	$resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
	if ($resolvedTestRoot.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolvedTestRoot).StartsWith("template-tools-tests-", [StringComparison]::Ordinal)) {
		if (Test-Path -LiteralPath $resolvedTestRoot) { Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force }
	} else {
		throw "Refusing unsafe test cleanup path: $resolvedTestRoot"
	}
}
