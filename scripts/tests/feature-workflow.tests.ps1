Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$sourceRoot = (& git -C $PSScriptRoot rev-parse --show-toplevel).Trim()
if ($LASTEXITCODE -ne 0) { throw "Source repository root is unavailable." }
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("feature-workflow-tests-{0}" -f [Guid]::NewGuid().ToString("N"))
$powershell = (Get-Command powershell -ErrorAction Stop).Source

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
		[Parameter(Mandatory = $true)][int]$ExpectedExitCode
	)
	$previousPreference = $ErrorActionPreference
	try {
		$ErrorActionPreference = "Continue"
		$output = @(& $powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $testRoot "scripts\feature-workflow.ps1") @Arguments 2>&1)
		$exitCode = $LASTEXITCODE
	} finally {
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

try {
	New-Item -ItemType Directory -Path (Join-Path $testRoot "scripts") -Force | Out-Null
	New-Item -ItemType Directory -Path (Join-Path $testRoot "docs\Features\existing-folder") -Force | Out-Null
	foreach ($name in @(
		"FeatureWorkflow.psm1",
		"feature-workflow.ps1",
		"sync-feature-index.ps1",
		"validate-feature-workflow.ps1",
		"codex-feature-hook.ps1"
	)) {
		Copy-Item -LiteralPath (Join-Path $sourceRoot "scripts\$name") -Destination (Join-Path $testRoot "scripts\$name")
	}
	[IO.File]::WriteAllText(
		(Join-Path $testRoot "docs\Features\existing-folder\product-requirements.md"),
		"# Existing requirements`n",
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
		"-Feature", "Adopt Existing",
		"-Title", "Adopt Existing",
		"-Slug", "existing-folder",
		"-SessionId", "session-a"
	) -ExpectedExitCode 0 | Out-Null
	$firstPath = Join-Path $testRoot "docs\Features\existing-folder\feature.json"
	$first = Get-Content -LiteralPath $firstPath -Raw | ConvertFrom-Json
	Assert-True ($first.id -ceq "TF-0001") "first template feature ID must be TF-0001"
	Assert-True ($first.baseCommit -ceq $baseCommit) "start must freeze the exact base commit"
	Assert-True ($first.activity -ceq "active") "new feature must be active"

	Invoke-Workflow -Arguments @(
		"-Action", "Start",
		"-Feature", "Second Feature",
		"-Title", "Second Feature",
		"-Slug", "second-feature",
		"-AdoptChanges",
		"-SessionId", "session-x"
	) -ExpectedExitCode 1 | Out-Null

	Invoke-Workflow -Arguments @(
		"-Action", "Pause",
		"-Feature", "TF-0001",
		"-Summary", "Checkpoint after initial implementation.",
		"-NextStep", "Resume and verify completion.",
		"-SessionId", "session-a"
	) -ExpectedExitCode 0 | Out-Null
	$first = Get-Content -LiteralPath $firstPath -Raw | ConvertFrom-Json
	Assert-True ($first.status -ceq "in_progress" -and $first.activity -ceq "paused") "pause must retain branch reservation"
	Assert-True ($null -eq $first.activeSessionId) "pause must clear activeSessionId"

	Invoke-Workflow -Arguments @(
		"-Action", "Start",
		"-Feature", "Second Feature",
		"-Title", "Second Feature",
		"-Slug", "second-feature",
		"-AdoptChanges",
		"-SessionId", "session-x"
	) -ExpectedExitCode 1 | Out-Null

	Invoke-Workflow -Arguments @(
		"-Action", "Continue",
		"-Feature", "TF-0001",
		"-SessionId", "session-b"
	) -ExpectedExitCode 0 | Out-Null
	$first = Get-Content -LiteralPath $firstPath -Raw | ConvertFrom-Json
	Assert-True ($first.activity -ceq "active" -and $first.activeSessionId -ceq "session-b") "continue must transfer sequential ownership"
	Assert-True (@($first.sessions).Count -eq 2) "continue must retain both linked sessions"

	$first.blockers = @("missing evidence")
	[IO.File]::WriteAllText($firstPath, (($first | ConvertTo-Json -Depth 20) + "`n"), [Text.UTF8Encoding]::new($false))
	Invoke-Workflow -Arguments @(
		"-Action", "Finish",
		"-Feature", "TF-0001",
		"-Summary", "Complete.",
		"-VerificationSummary", "All fixture checks passed.",
		"-SessionId", "session-b"
	) -ExpectedExitCode 1 | Out-Null
	$first = Get-Content -LiteralPath $firstPath -Raw | ConvertFrom-Json
	Assert-True ($first.status -ceq "in_progress") "blocked finish must not advance state"

	$first.blockers = @()
	[IO.File]::WriteAllText($firstPath, (($first | ConvertTo-Json -Depth 20) + "`n"), [Text.UTF8Encoding]::new($false))
	Invoke-Workflow -Arguments @(
		"-Action", "Finish",
		"-Feature", "TF-0001",
		"-Summary", "Complete.",
		"-VerificationSummary", "All fixture checks passed.",
		"-SessionId", "session-b"
	) -ExpectedExitCode 0 | Out-Null
	$first = Get-Content -LiteralPath $firstPath -Raw | ConvertFrom-Json
	Assert-True ($first.status -ceq "ready" -and $first.activity -ceq "none") "finish must produce ready/none"

	Invoke-Workflow -Arguments @(
		"-Action", "Start",
		"-Feature", "Second Feature",
		"-Title", "Second Feature",
		"-Slug", "second-feature",
		"-SessionId", "session-c"
	) -ExpectedExitCode 1 | Out-Null
	Invoke-Workflow -Arguments @(
		"-Action", "Start",
		"-Feature", "Second Feature",
		"-Title", "Second Feature",
		"-Slug", "second-feature",
		"-AdoptChanges",
		"-SessionId", "session-c"
	) -ExpectedExitCode 0 | Out-Null
	$secondPath = Join-Path $testRoot "docs\Features\second-feature\feature.json"
	$second = Get-Content -LiteralPath $secondPath -Raw | ConvertFrom-Json
	Assert-True ($second.id -ceq "TF-0002") "second template feature ID must be TF-0002"

	$sessionHookInput = [ordered]@{
		hook_event_name = "SessionStart"
		cwd = $testRoot
		session_id = "hook-session"
	} | ConvertTo-Json -Compress
	$sessionHookOutput = $sessionHookInput | & $powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $testRoot "scripts\codex-feature-hook.ps1")
	$sessionHook = $sessionHookOutput | ConvertFrom-Json
	Assert-True ($sessionHook.hookSpecificOutput.additionalContext -match "TF-0002") "SessionStart hook must expose branch feature context"

	$toolHookInput = [ordered]@{
		hook_event_name = "PreToolUse"
		tool_name = "Bash"
		cwd = $testRoot
		session_id = "hook-session"
		tool_input = [ordered]@{ command = "powershell -File scripts/feature-workflow.ps1 -Action Context -Feature TF-0002" }
	} | ConvertTo-Json -Depth 5 -Compress
	$toolHookOutput = $toolHookInput | & $powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $testRoot "scripts\codex-feature-hook.ps1")
	$toolHook = $toolHookOutput | ConvertFrom-Json
	Assert-True ($toolHook.hookSpecificOutput.updatedInput.command -match "-SessionId 'hook-session'$") "PreToolUse hook must inject verified task ID"

	$duplicateDirectory = Join-Path $testRoot "docs\Features\duplicate"
	New-Item -ItemType Directory -Path $duplicateDirectory | Out-Null
	$duplicate = Get-Content -LiteralPath $secondPath -Raw | ConvertFrom-Json
	$duplicate.slug = "duplicate"
	[IO.File]::WriteAllText((Join-Path $duplicateDirectory "feature.json"), (($duplicate | ConvertTo-Json -Depth 20) + "`n"), [Text.UTF8Encoding]::new($false))
	Invoke-FeatureValidator -ExpectedExitCode 1 -TestName "duplicate manifest" | Out-Null
	Remove-Item -LiteralPath $duplicateDirectory -Recurse -Force

	& $powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $testRoot "scripts\sync-feature-index.ps1") | Out-Null
	if ($LASTEXITCODE -ne 0) { throw "Dashboard synchronization failed." }
	$indexPath = Join-Path $testRoot "docs\Features\README.md"
	$index = Get-Content -LiteralPath $indexPath -Raw
	$index = $index.Replace("Всего: 2", "Всего: 999")
	[IO.File]::WriteAllText($indexPath, $index, [Text.UTF8Encoding]::new($false))
	Invoke-FeatureValidator -ExpectedExitCode 1 -TestName "dashboard drift" | Out-Null
	& $powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $testRoot "scripts\sync-feature-index.ps1") | Out-Null
	if ($LASTEXITCODE -ne 0) { throw "Dashboard repair failed." }
	Invoke-FeatureValidator -ExpectedExitCode 0 -TestName "repaired dashboard" | Out-Null

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
