Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$sourceRoot = (& git -C $PSScriptRoot rev-parse --show-toplevel).Trim()
if ($LASTEXITCODE -ne 0) { throw "Source repository root is unavailable." }
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("feature-workflow-tests-{0}" -f [Guid]::NewGuid().ToString("N"))
$powershell = (Get-Command powershell -ErrorAction Stop).Source
$sessionA = "00000000-0000-4000-8000-00000000000a"
$sessionB = "00000000-0000-4000-8000-00000000000b"
$sessionC = "00000000-0000-4000-8000-00000000000c"
$sessionX = "00000000-0000-4000-8000-00000000000d"
$projectSession = "00000000-0000-4000-8000-00000000000e"
$foreignSession = "00000000-0000-4000-8000-00000000000f"

function Assert-True {
	param([Parameter(Mandatory = $true)][bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
	if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Invoke-TestGit {
	param([Parameter(Mandatory = $true)][string[]]$Arguments)
	$output = @(& git -C $testRoot @Arguments 2>&1)
	if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)" }
	return $output
}

function Invoke-Workflow {
	param(
		[Parameter(Mandatory = $true)][string[]]$Arguments,
		[Parameter(Mandatory = $true)][int]$ExpectedExitCode,
		[Parameter(Mandatory = $true)][AllowEmptyString()][string]$ThreadId
	)
	$previousPreference = $ErrorActionPreference
	$hadThreadId = Test-Path Env:CODEX_THREAD_ID
	$previousThreadId = $env:CODEX_THREAD_ID
	try {
		if ([string]::IsNullOrWhiteSpace($ThreadId)) {
			Remove-Item Env:CODEX_THREAD_ID -ErrorAction SilentlyContinue
		} else {
			$env:CODEX_THREAD_ID = $ThreadId
		}
		$ErrorActionPreference = "Continue"
		$output = @(& $powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $testRoot "scripts\feature-workflow.ps1") @Arguments 2>&1)
		$exitCode = $LASTEXITCODE
	} finally {
		if ($hadThreadId) {
			$env:CODEX_THREAD_ID = $previousThreadId
		} else {
			Remove-Item Env:CODEX_THREAD_ID -ErrorAction SilentlyContinue
		}
		$ErrorActionPreference = $previousPreference
	}
	if ($exitCode -ne $ExpectedExitCode) {
		throw "Workflow exit $exitCode, expected $ExpectedExitCode.`n$($output -join [Environment]::NewLine)"
	}
	return $output
}

function Invoke-FeatureValidator {
	param(
		[Parameter(Mandatory = $true)][int]$ExpectedExitCode,
		[Parameter(Mandatory = $true)][string]$TestName
	)
	$previousPreference = $ErrorActionPreference
	try {
		$ErrorActionPreference = "Continue"
		$output = @(& $powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $testRoot "scripts\validate-feature-workflow.ps1") 2>&1)
		$exitCode = $LASTEXITCODE
	} finally {
		$ErrorActionPreference = $previousPreference
	}
	if ($exitCode -ne $ExpectedExitCode) {
		throw "$TestName validator exit $exitCode, expected $ExpectedExitCode.`n$($output -join [Environment]::NewLine)"
	}
	return $output
}

function Invoke-IndexSync {
	param(
		[Parameter(Mandatory = $true)][string[]]$Arguments,
		[Parameter(Mandatory = $true)][int]$ExpectedExitCode,
		[Parameter(Mandatory = $true)][string]$TestName
	)
	$previousPreference = $ErrorActionPreference
	try {
		$ErrorActionPreference = "Continue"
		$output = @(& $powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $testRoot "scripts\sync-feature-index.ps1") @Arguments 2>&1)
		$exitCode = $LASTEXITCODE
	} finally {
		$ErrorActionPreference = $previousPreference
	}
	if ($exitCode -ne $ExpectedExitCode) {
		throw "$TestName sync exit $exitCode, expected $ExpectedExitCode.`n$($output -join [Environment]::NewLine)"
	}
	return $output
}

try {
	New-Item -ItemType Directory -Path (Join-Path $testRoot "scripts") -Force | Out-Null
	New-Item -ItemType Directory -Path (Join-Path $testRoot "docs\Features\template\existing-folder") -Force | Out-Null
	foreach ($name in @(
		"FeatureWorkflow.psm1",
		"feature-workflow.ps1",
		"sync-feature-index.ps1",
		"validate-feature-workflow.ps1"
	)) {
		Copy-Item -LiteralPath (Join-Path $sourceRoot "scripts\$name") -Destination (Join-Path $testRoot "scripts\$name")
	}
	[IO.File]::WriteAllText(
		(Join-Path $testRoot "docs\Features\template\existing-folder\product-requirements.md"),
		"# Existing requirements`n",
		[Text.UTF8Encoding]::new($false)
	)
	[IO.File]::WriteAllText(
		(Join-Path $testRoot "docs\Features\README.md"),
		"# Feature registries`n`nTemplate and project feature state use separate namespaces.`n",
		[Text.UTF8Encoding]::new($false)
	)

	& git -C $testRoot init -b main | Out-Null
	if ($LASTEXITCODE -ne 0) { throw "git init failed." }
	Invoke-TestGit -Arguments @("config", "user.name", "Feature Workflow Test") | Out-Null
	Invoke-TestGit -Arguments @("config", "user.email", "feature-workflow-test@example.invalid") | Out-Null
	Invoke-TestGit -Arguments @("config", "core.autocrlf", "false") | Out-Null
	Invoke-TestGit -Arguments @("add", ".") | Out-Null
	Invoke-TestGit -Arguments @("commit", "-m", "test fixture") | Out-Null
	$baseOutput = @(Invoke-TestGit -Arguments @("rev-parse", "HEAD"))
	$baseCommit = ([string]$baseOutput[0]).Trim()

	Invoke-Workflow -Arguments @(
		"-Action", "Start",
		"-Feature", "Missing Task Context",
		"-Title", "Missing Task Context",
		"-Slug", "missing-task-context"
	) -ExpectedExitCode 1 -ThreadId "" | Out-Null
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $testRoot "docs\Features\template\missing-task-context"))) "missing app task identity must fail before mutation"

	Invoke-Workflow -Arguments @(
		"-Action", "Start",
		"-Feature", "Manual Task Argument",
		"-Title", "Manual Task Argument",
		"-Slug", "manual-task-argument",
		"-SessionId", $sessionA
	) -ExpectedExitCode 1 -ThreadId $sessionA | Out-Null
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $testRoot "docs\Features\template\manual-task-argument"))) "public SessionId argument must be rejected before mutation"

	Invoke-Workflow -Arguments @(
		"-Action", "Start",
		"-Feature", "Adopt Existing",
		"-Title", "Adopt Existing",
		"-Slug", "existing-folder"
	) -ExpectedExitCode 0 -ThreadId $sessionA | Out-Null
	$firstPath = Join-Path $testRoot "docs\Features\template\existing-folder\feature.json"
	$first = Get-Content -LiteralPath $firstPath -Raw | ConvertFrom-Json
	Assert-True ($first.id -ceq "TF-0001") "first template feature ID must be TF-0001"
	Assert-True ($first.baseCommit -ceq $baseCommit) "start must freeze the exact base commit"
	Assert-True ($first.activity -ceq "active") "new feature must be active"
	Assert-True ($first.activeSessionId -ceq $sessionA) "start must bind the app-provided task ID"

	Invoke-Workflow -Arguments @(
		"-Action", "Start",
		"-Feature", "Second Feature",
		"-Title", "Second Feature",
		"-Slug", "second-feature",
		"-AdoptChanges"
	) -ExpectedExitCode 1 -ThreadId $sessionX | Out-Null

	Invoke-Workflow -Arguments @(
		"-Action", "Pause",
		"-Feature", "TF-0001",
		"-Summary", "Checkpoint after initial implementation.",
		"-NextStep", "Resume and verify completion."
	) -ExpectedExitCode 0 -ThreadId $sessionA | Out-Null
	$first = Get-Content -LiteralPath $firstPath -Raw | ConvertFrom-Json
	Assert-True ($first.status -ceq "in_progress" -and $first.activity -ceq "paused") "pause must retain branch reservation"
	Assert-True ($null -eq $first.activeSessionId) "pause must clear activeSessionId"

	Invoke-Workflow -Arguments @(
		"-Action", "Start",
		"-Feature", "Second Feature",
		"-Title", "Second Feature",
		"-Slug", "second-feature",
		"-AdoptChanges"
	) -ExpectedExitCode 1 -ThreadId $sessionX | Out-Null

	Invoke-Workflow -Arguments @(
		"-Action", "Continue",
		"-Feature", "TF-0001"
	) -ExpectedExitCode 0 -ThreadId $sessionB | Out-Null
	$first = Get-Content -LiteralPath $firstPath -Raw | ConvertFrom-Json
	Assert-True ($first.activity -ceq "active" -and $first.activeSessionId -ceq $sessionB) "continue must transfer sequential ownership"
	Assert-True (@($first.sessions).Count -eq 2) "continue must retain both linked sessions"

	$first.blockers = @("missing evidence")
	[IO.File]::WriteAllText($firstPath, (($first | ConvertTo-Json -Depth 20) + "`n"), [Text.UTF8Encoding]::new($false))
	Invoke-Workflow -Arguments @(
		"-Action", "Finish",
		"-Feature", "TF-0001",
		"-Summary", "Complete.",
		"-VerificationSummary", "All fixture checks passed."
	) -ExpectedExitCode 1 -ThreadId $sessionB | Out-Null
	$first = Get-Content -LiteralPath $firstPath -Raw | ConvertFrom-Json
	Assert-True ($first.status -ceq "in_progress") "blocked finish must not advance state"

	$first.blockers = @()
	[IO.File]::WriteAllText($firstPath, (($first | ConvertTo-Json -Depth 20) + "`n"), [Text.UTF8Encoding]::new($false))
	Invoke-Workflow -Arguments @(
		"-Action", "Finish",
		"-Feature", "TF-0001",
		"-Summary", "Complete.",
		"-VerificationSummary", "All fixture checks passed."
	) -ExpectedExitCode 0 -ThreadId $sessionB | Out-Null
	$first = Get-Content -LiteralPath $firstPath -Raw | ConvertFrom-Json
	Assert-True ($first.status -ceq "ready" -and $first.activity -ceq "none") "finish must produce ready/none"
	$firstHandoff = Get-Content -LiteralPath (Join-Path $testRoot "docs\Features\template\existing-folder\handoff.md") -Raw
	$firstWorklog = Get-Content -LiteralPath (Join-Path $testRoot "docs\Features\template\existing-folder\worklog.md") -Raw
	Assert-True ($firstHandoff.Contains("Feature: TF-0001 Adopt Existing")) "handoff must render the feature label"
	Assert-True (-not $firstHandoff.Contains('$(') -and -not $firstHandoff.Contains('$SessionId')) "handoff must not contain unexpanded PowerShell expressions"
	Assert-True ($firstWorklog.Contains("Feature: TF-0001")) "worklog must render the feature ID"
	Assert-True (-not $firstWorklog.Contains('$(') -and -not $firstWorklog.Contains('$SessionId')) "worklog must not contain unexpanded PowerShell expressions"

	Invoke-Workflow -Arguments @(
		"-Action", "Start",
		"-Feature", "Second Feature",
		"-Title", "Second Feature",
		"-Slug", "second-feature"
	) -ExpectedExitCode 1 -ThreadId $sessionC | Out-Null
	Invoke-Workflow -Arguments @(
		"-Action", "Start",
		"-Feature", "Second Feature",
		"-Title", "Second Feature",
		"-Slug", "second-feature",
		"-AdoptChanges"
	) -ExpectedExitCode 0 -ThreadId $sessionC | Out-Null
	$secondPath = Join-Path $testRoot "docs\Features\template\second-feature\feature.json"
	$second = Get-Content -LiteralPath $secondPath -Raw | ConvertFrom-Json
	Assert-True ($second.id -ceq "TF-0002") "second template feature ID must be TF-0002"

	$duplicateDirectory = Join-Path $testRoot "docs\Features\template\duplicate"
	New-Item -ItemType Directory -Path $duplicateDirectory | Out-Null
	$duplicate = Get-Content -LiteralPath $secondPath -Raw | ConvertFrom-Json
	$duplicate.slug = "duplicate"
	[IO.File]::WriteAllText((Join-Path $duplicateDirectory "feature.json"), (($duplicate | ConvertTo-Json -Depth 20) + "`n"), [Text.UTF8Encoding]::new($false))
	Invoke-FeatureValidator -ExpectedExitCode 1 -TestName "duplicate manifest" | Out-Null
	Remove-Item -LiteralPath $duplicateDirectory -Recurse -Force

	Invoke-IndexSync -Arguments @("-Scope", "Template") -ExpectedExitCode 0 -TestName "template dashboard synchronization" | Out-Null
	$indexPath = Join-Path $testRoot "docs\Features\template\README.md"
	$index = Get-Content -LiteralPath $indexPath -Raw
	$index = $index.Replace("Всего: 2", "Всего: 999")
	[IO.File]::WriteAllText($indexPath, $index, [Text.UTF8Encoding]::new($false))
	Invoke-FeatureValidator -ExpectedExitCode 1 -TestName "dashboard drift" | Out-Null
	Invoke-IndexSync -Arguments @("-Scope", "Template") -ExpectedExitCode 0 -TestName "template dashboard repair" | Out-Null
	Invoke-FeatureValidator -ExpectedExitCode 0 -TestName "repaired dashboard" | Out-Null

	Invoke-Workflow -Arguments @(
		"-Action", "Finish",
		"-Feature", "TF-0002",
		"-Summary", "Second template feature complete.",
		"-VerificationSummary", "Fixture verification passed."
	) -ExpectedExitCode 0 -ThreadId $sessionC | Out-Null
	Invoke-TestGit -Arguments @("add", ".") | Out-Null
	Invoke-TestGit -Arguments @("commit", "-m", "finish template feature fixtures") | Out-Null

	Invoke-TestGit -Arguments @("remote", "add", "upstream", "https://example.invalid/template.git") | Out-Null
	New-Item -ItemType Directory -Path (Join-Path $testRoot "docs\Features\project") -Force | Out-Null
	Invoke-IndexSync -Arguments @("-Scope", "Project") -ExpectedExitCode 0 -TestName "project namespace initialization" | Out-Null
	Invoke-TestGit -Arguments @("add", ".") | Out-Null
	Invoke-TestGit -Arguments @("commit", "-m", "initialize project feature namespace") | Out-Null

	$templateIndexBefore = Get-Content -LiteralPath $indexPath -Raw
	Invoke-Workflow -Arguments @(
		"-Action", "Start",
		"-Feature", "Project Feature",
		"-Title", "Project Feature",
		"-Slug", "existing-folder"
	) -ExpectedExitCode 0 -ThreadId $projectSession | Out-Null
	$projectFeaturePath = Join-Path $testRoot "docs\Features\project\existing-folder\feature.json"
	$projectFeature = Get-Content -LiteralPath $projectFeaturePath -Raw | ConvertFrom-Json
	Assert-True ($projectFeature.id -ceq "PF-0001") "first derived-project feature ID must be PF-0001"
	Assert-True ((Get-Content -LiteralPath $indexPath -Raw) -ceq $templateIndexBefore) "project start must not rewrite the template dashboard"
	$projectIndexPath = Join-Path $testRoot "docs\Features\project\README.md"
	$projectIndex = Get-Content -LiteralPath $projectIndexPath -Raw
	Assert-True ($projectIndex.Contains("PF-0001")) "project dashboard must contain the project feature"
	Assert-True ($projectIndex.Contains("docs/Features/project/*/feature.json")) "project dashboard must render its namespace path"
	Assert-True (-not $projectIndex.Contains('$manifestPattern')) "project dashboard must not contain an unexpanded PowerShell variable"

	Invoke-Workflow -Arguments @(
		"-Action", "Start",
		"-Feature", "TF-0001",
		"-ReopenReason", "Forbidden foreign mutation fixture.",
		"-AdoptChanges"
	) -ExpectedExitCode 1 -ThreadId $foreignSession | Out-Null

	$corruptTemplateIndex = $templateIndexBefore.Replace("Всего: 2", "Всего: 999")
	[IO.File]::WriteAllText($indexPath, $corruptTemplateIndex, [Text.UTF8Encoding]::new($false))
	Invoke-IndexSync -Arguments @("-Scope", "Project") -ExpectedExitCode 0 -TestName "project-only dashboard synchronization" | Out-Null
	Assert-True ((Get-Content -LiteralPath $indexPath -Raw) -ceq $corruptTemplateIndex) "project sync must leave a foreign template dashboard byte-identical"
	Invoke-FeatureValidator -ExpectedExitCode 1 -TestName "foreign dashboard drift" | Out-Null
	Invoke-IndexSync -Arguments @("-Scope", "Template") -ExpectedExitCode 1 -TestName "forbidden foreign dashboard rewrite" | Out-Null
	[IO.File]::WriteAllText($indexPath, $templateIndexBefore, [Text.UTF8Encoding]::new($false))
	Invoke-FeatureValidator -ExpectedExitCode 0 -TestName "restored foreign dashboard" | Out-Null

	Invoke-Workflow -Arguments @(
		"-Action", "Finish",
		"-Feature", "PF-0001",
		"-Summary", "Derived project namespace fixture complete.",
		"-VerificationSummary", "Namespace isolation checks passed."
	) -ExpectedExitCode 0 -ThreadId $projectSession | Out-Null
	Invoke-FeatureValidator -ExpectedExitCode 0 -TestName "completed project namespace" | Out-Null

	Write-Output "Feature workflow tests passed."
} finally {
	if (Test-Path -LiteralPath $testRoot -PathType Container) {
		$resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
		$resolvedTest = [IO.Path]::GetFullPath($testRoot)
		if (-not $resolvedTest.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase)) {
			throw "Refusing to clean unexpected test path '$resolvedTest'."
		}
		Remove-Item -LiteralPath $resolvedTest -Recurse -Force
	}
}
