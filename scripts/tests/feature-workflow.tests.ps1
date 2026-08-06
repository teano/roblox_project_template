Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$sourceRoot = (& git -C $PSScriptRoot rev-parse --show-toplevel).Trim()
if ($LASTEXITCODE -ne 0) { throw "Source repository root is unavailable." }
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("feature-workflow-tests-{0}" -f [Guid]::NewGuid().ToString("N"))
$powershell = (Get-Command powershell -ErrorAction Stop).Source
$hadCodexThreadId = Test-Path Env:CODEX_THREAD_ID
$previousCodexThreadId = $env:CODEX_THREAD_ID
$env:CODEX_THREAD_ID = "invalid-product-specific-context-must-be-ignored"

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

function Write-TestUtf8 {
	param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Content)
	$parent = Split-Path -Parent $Path
	if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
		New-Item -ItemType Directory -Path $parent -Force | Out-Null
	}
	[IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
}

try {
	New-Item -ItemType Directory -Path (Join-Path $testRoot "scripts") -Force | Out-Null
	New-Item -ItemType Directory -Path (Join-Path $testRoot ".agents\skills") -Force | Out-Null
	New-Item -ItemType Directory -Path (Join-Path $testRoot "docs\Features\template\existing-folder") -Force | Out-Null
	foreach ($name in @(
		"FeatureWorkflow.psm1",
		"feature-workflow.ps1",
		"sync-feature-index.ps1",
		"validate-feature-workflow.ps1"
	)) {
		Copy-Item -LiteralPath (Join-Path $sourceRoot "scripts\$name") -Destination (Join-Path $testRoot "scripts\$name")
	}
	foreach ($skillName in @("feature-start", "feature-continue", "feature-pause", "feature-finish")) {
		Copy-Item `
			-LiteralPath (Join-Path $sourceRoot ".agents\skills\$skillName") `
			-Destination (Join-Path $testRoot ".agents\skills\$skillName") `
			-Recurse
	}
	Write-TestUtf8 -Path (Join-Path $testRoot "docs\Features\template\existing-folder\product-requirements.md") -Content "# Existing requirements`n"
	Write-TestUtf8 -Path (Join-Path $testRoot "docs\Features\template\existing-folder\technical-specification.md") -Content "# Existing specification`n"
	Write-TestUtf8 -Path (Join-Path $testRoot "docs\Features\README.md") -Content "# Feature registries`n`nTemplate and project feature state use separate namespaces.`n"

	& git -C $testRoot init -b main | Out-Null
	if ($LASTEXITCODE -ne 0) { throw "git init failed." }
	Invoke-TestGit -Arguments @("config", "user.name", "Feature Workflow Test") | Out-Null
	Invoke-TestGit -Arguments @("config", "user.email", "feature-workflow-test@example.invalid") | Out-Null
	Invoke-TestGit -Arguments @("config", "core.autocrlf", "false") | Out-Null
	Invoke-TestGit -Arguments @("add", ".") | Out-Null
	Invoke-TestGit -Arguments @("commit", "-m", "test fixture") | Out-Null
	$baseCommit = ([string]@(Invoke-TestGit -Arguments @("rev-parse", "HEAD"))[0]).Trim()

	$workflowSource = Get-Content -LiteralPath (Join-Path $testRoot "scripts\feature-workflow.ps1") -Raw
	Assert-True (-not $workflowSource.Contains("CODEX_THREAD_ID")) "lifecycle command must not read Codex task identity"
	$authorizationPattern = '(?s)Only\s+an\s+explicit\s+request\s+in\s+the\s+current\s+user\s+message\s+authorizes\s+this\s+lifecycle\s+transition\.'
	foreach ($skillName in @("feature-start", "feature-continue", "feature-pause", "feature-finish")) {
		$skillDirectory = Join-Path $testRoot ".agents\skills\$skillName"
		$skillContent = Get-Content -LiteralPath (Join-Path $skillDirectory "SKILL.md") -Raw
		$metadataContent = Get-Content -LiteralPath (Join-Path $skillDirectory "agents\openai.yaml") -Raw
		Assert-True ($skillContent.Contains("## User authorization gate")) "$skillName must expose its user authorization gate"
		Assert-True ([regex]::IsMatch($skillContent, $authorizationPattern)) "$skillName must require an explicit current user request"
		Assert-True ([regex]::IsMatch($metadataContent, '(?m)^\s*allow_implicit_invocation:\s*false\s*$')) "$skillName must reject implicit invocation"
	}
	foreach ($forbiddenFinishCommand in @("validate-feature-workflow.ps1", "validate-repository-layout.ps1", "ensure-rojo-server.ps1", "rojo build", "AllTestsRunner")) {
		Assert-True (-not $workflowSource.Contains($forbiddenFinishCommand)) "Finish must not invoke '$forbiddenFinishCommand'"
	}

	Invoke-Workflow -Arguments @(
		"-Action", "Start",
		"-Feature", "Manual Session Argument",
		"-Title", "Manual Session Argument",
		"-Slug", "manual-session-argument",
		"-SessionId", "forbidden"
	) -ExpectedExitCode 1 | Out-Null
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $testRoot "docs\Features\template\manual-session-argument"))) "public SessionId argument must be rejected before mutation"

	Invoke-Workflow -Arguments @(
		"-Action", "Start",
		"-Feature", "Adopt Existing",
		"-Title", "Adopt Existing",
		"-Slug", "existing-folder"
	) -ExpectedExitCode 0 | Out-Null
	$firstPath = Join-Path $testRoot "docs\Features\template\existing-folder\feature.json"
	$first = Get-Content -LiteralPath $firstPath -Raw | ConvertFrom-Json
	Assert-True ($first.schemaVersion -eq 2) "new feature must use schema version 2"
	Assert-True ($first.id -ceq "TF-0001") "first template feature ID must be TF-0001"
	Assert-True ($first.branch -ceq "template-feature/tf-0001-existing-folder") "template feature branch must use the canonical format"
	Assert-True (([string]@(Invoke-TestGit -Arguments @("branch", "--show-current"))[0]).Trim() -ceq $first.branch) "Start must switch to the canonical template feature branch"
	Assert-True ($first.baseCommit -ceq $baseCommit) "start must freeze the exact base commit"
	Assert-True ($first.activity -ceq "active") "new feature must be active"
	Assert-True ($null -eq $first.PSObject.Properties["activeSessionId"] -and $null -eq $first.PSObject.Properties["sessions"]) "manifest must not store session history"

	$leaseFiles = @(Get-ChildItem -LiteralPath (Join-Path $testRoot ".git\feature-workflow\locks") -Recurse -File -Filter "lease.json")
	Assert-True ($leaseFiles.Count -eq 1) "Start must create one feature-scoped lease"
	$lease = Get-Content -LiteralPath $leaseFiles[0].FullName -Raw | ConvertFrom-Json
	Assert-True ($lease.featureId -ceq "TF-0001" -and $null -eq $lease.PSObject.Properties["sessionId"]) "lease must identify only the feature and branch"

	Invoke-Workflow -Arguments @(
		"-Action", "Pause",
		"-Feature", "TF-0001",
		"-Summary", "Initial implementation is checkpointed with an uncommitted manifest and dashboard.",
		"-Decisions", "Use repository artifacts as the complete context source; do not retain chat identity.",
		"-VerificationSummary", "No runtime checks were required; workflow state was inspected.",
		"-NextStep", "Resume and complete the fixture."
	) -ExpectedExitCode 0 | Out-Null
	$first = Get-Content -LiteralPath $firstPath -Raw | ConvertFrom-Json
	Assert-True ($first.status -ceq "in_progress" -and $first.activity -ceq "paused") "pause must retain branch reservation"
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $testRoot ".git\feature-workflow\locks") -PathType Container) -or @(Get-ChildItem -LiteralPath (Join-Path $testRoot ".git\feature-workflow\locks") -Directory).Count -eq 0) "pause must release the feature-scoped lease"

	Invoke-Workflow -Arguments @(
		"-Action", "Start",
		"-Feature", "Second Feature",
		"-Title", "Second Feature",
		"-Slug", "second-feature"
	) -ExpectedExitCode 1 | Out-Null

	Invoke-Workflow -Arguments @("-Action", "Continue", "-Feature", "TF-0001") -ExpectedExitCode 0 | Out-Null
	$first = Get-Content -LiteralPath $firstPath -Raw | ConvertFrom-Json
	Assert-True ($first.activity -ceq "active") "continue must reactivate paused work without task ownership"

	$first.blockers = @("missing evidence")
	Write-TestUtf8 -Path $firstPath -Content (($first | ConvertTo-Json -Depth 20) + "`n")
	Invoke-Workflow -Arguments @(
		"-Action", "Finish",
		"-Feature", "TF-0001",
		"-Summary", "Fixture complete.",
		"-Decisions", "The durable worklog is authoritative.",
		"-VerificationSummary", "All fixture checks passed before Finish."
	) -ExpectedExitCode 1 | Out-Null
	$first = Get-Content -LiteralPath $firstPath -Raw | ConvertFrom-Json
	Assert-True ($first.status -ceq "in_progress") "blocked finish must not advance state"

	$first.blockers = @()
	Write-TestUtf8 -Path $firstPath -Content (($first | ConvertTo-Json -Depth 20) + "`n")
	Invoke-Workflow -Arguments @(
		"-Action", "Finish",
		"-Feature", "TF-0001",
		"-Summary", "Fixture complete.",
		"-Decisions", "The durable worklog is authoritative; no transcript lookup is allowed.",
		"-VerificationSummary", "All fixture checks passed before Finish."
	) -ExpectedExitCode 0 | Out-Null
	$first = Get-Content -LiteralPath $firstPath -Raw | ConvertFrom-Json
	Assert-True ($first.status -ceq "ready" -and $first.activity -ceq "none") "finish must produce ready/none"
	$firstHandoff = Get-Content -LiteralPath (Join-Path $testRoot "docs\Features\template\existing-folder\handoff.md") -Raw
	$firstWorklog = Get-Content -LiteralPath (Join-Path $testRoot "docs\Features\template\existing-folder\worklog.md") -Raw
	foreach ($requiredHeading in @("Result and current state", "Important decisions and discussions", "Verification state", "Blockers", "Next step")) {
		Assert-True ($firstHandoff.Contains($requiredHeading) -and $firstWorklog.Contains($requiredHeading)) "handoff and worklog must contain '$requiredHeading'"
	}
	Assert-True (-not [regex]::IsMatch(($firstHandoff + $firstWorklog), '(?i)session\s*:|threadId|activeSessionId|CODEX_THREAD_ID')) "durable context must not store agent/session identity"
	$indexPath = Join-Path $testRoot "docs\Features\template\README.md"
	$index = Get-Content -LiteralPath $indexPath -Raw
	Assert-True ($index.Contains("| Worklog |") -and $index.Contains("[Открыть](./existing-folder/worklog.md)")) "dashboard must link directly to the worklog without a session count"

	Invoke-TestGit -Arguments @("add", ".") | Out-Null
	Invoke-TestGit -Arguments @("commit", "-m", "finish first template feature fixture") | Out-Null
	$currentBeforeCollision = ([string]@(Invoke-TestGit -Arguments @("branch", "--show-current"))[0]).Trim()
	Invoke-TestGit -Arguments @("branch", "template-feature/tf-0002-collision-feature") | Out-Null
	Invoke-Workflow -Arguments @(
		"-Action", "Start",
		"-Feature", "Collision Feature",
		"-Title", "Collision Feature",
		"-Slug", "collision-feature"
	) -ExpectedExitCode 1 | Out-Null
	Assert-True (([string]@(Invoke-TestGit -Arguments @("branch", "--show-current"))[0]).Trim() -ceq $currentBeforeCollision) "branch collision must not switch the current branch"
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $testRoot "docs\Features\template\collision-feature"))) "branch collision must fail before feature artifact mutation"
	Invoke-TestGit -Arguments @("branch", "-D", "template-feature/tf-0002-collision-feature") | Out-Null

	Invoke-Workflow -Arguments @(
		"-Action", "Start",
		"-Feature", "Second Feature",
		"-Title", "Second Feature",
		"-Slug", "second-feature"
	) -ExpectedExitCode 0 | Out-Null
	$secondPath = Join-Path $testRoot "docs\Features\template\second-feature\feature.json"
	$second = Get-Content -LiteralPath $secondPath -Raw | ConvertFrom-Json
	Assert-True ($second.id -ceq "TF-0002") "second template feature ID must be TF-0002"
	Assert-True ($second.branch -ceq "template-feature/tf-0002-second-feature") "second template branch must use the canonical format"
	Assert-True (@($second.blockers).Count -eq 2) "missing PRD and specification must be recorded as blockers"

	$duplicateDirectory = Join-Path $testRoot "docs\Features\template\duplicate"
	New-Item -ItemType Directory -Path $duplicateDirectory | Out-Null
	$duplicate = Get-Content -LiteralPath $secondPath -Raw | ConvertFrom-Json
	$duplicate.slug = "duplicate"
	Write-TestUtf8 -Path (Join-Path $duplicateDirectory "feature.json") -Content (($duplicate | ConvertTo-Json -Depth 20) + "`n")
	Write-TestUtf8 -Path (Join-Path $duplicateDirectory "handoff.md") -Content "# Feature handoff`n"
	Write-TestUtf8 -Path (Join-Path $duplicateDirectory "worklog.md") -Content "# Feature worklog`n"
	Invoke-FeatureValidator -ExpectedExitCode 1 -TestName "duplicate manifest" | Out-Null
	Remove-Item -LiteralPath $duplicateDirectory -Recurse -Force

	Invoke-IndexSync -Arguments @("-Scope", "Template") -ExpectedExitCode 0 -TestName "template dashboard synchronization" | Out-Null
	$index = Get-Content -LiteralPath $indexPath -Raw
	$index = $index.Replace("Всего: 2", "Всего: 999")
	Write-TestUtf8 -Path $indexPath -Content $index
	Invoke-FeatureValidator -ExpectedExitCode 1 -TestName "dashboard drift" | Out-Null
	Invoke-IndexSync -Arguments @("-Scope", "Template") -ExpectedExitCode 0 -TestName "template dashboard repair" | Out-Null
	Invoke-FeatureValidator -ExpectedExitCode 0 -TestName "repaired dashboard" | Out-Null

	$finishSkillPath = Join-Path $testRoot ".agents\skills\feature-finish\SKILL.md"
	$finishSkillContent = Get-Content -LiteralPath $finishSkillPath -Raw
	Write-TestUtf8 -Path $finishSkillPath -Content ($finishSkillContent.Replace("## User authorization gate", "## Removed authorization gate"))
	Invoke-FeatureValidator -ExpectedExitCode 1 -TestName "missing user authorization gate" | Out-Null
	Write-TestUtf8 -Path $finishSkillPath -Content $finishSkillContent

	$finishMetadataPath = Join-Path $testRoot ".agents\skills\feature-finish\agents\openai.yaml"
	$finishMetadataContent = Get-Content -LiteralPath $finishMetadataPath -Raw
	Write-TestUtf8 -Path $finishMetadataPath -Content ($finishMetadataContent.Replace("allow_implicit_invocation: false", "allow_implicit_invocation: true"))
	Invoke-FeatureValidator -ExpectedExitCode 1 -TestName "implicit lifecycle invocation" | Out-Null
	Write-TestUtf8 -Path $finishMetadataPath -Content $finishMetadataContent
	Invoke-FeatureValidator -ExpectedExitCode 0 -TestName "restored user authorization contract" | Out-Null

	Write-TestUtf8 -Path (Join-Path $testRoot "docs\Features\template\second-feature\product-requirements.md") -Content "# Second requirements`n"
	Write-TestUtf8 -Path (Join-Path $testRoot "docs\Features\template\second-feature\technical-specification.md") -Content "# Second specification`n"
	$second = Get-Content -LiteralPath $secondPath -Raw | ConvertFrom-Json
	$second.blockers = @()
	$second.artifacts = @("product-requirements.md", "technical-specification.md")
	Write-TestUtf8 -Path $secondPath -Content (($second | ConvertTo-Json -Depth 20) + "`n")
	Invoke-Workflow -Arguments @(
		"-Action", "Finish",
		"-Feature", "TF-0002",
		"-Summary", "Second template feature complete.",
		"-Decisions", "Canonical template branch format is mandatory for newly created work.",
		"-VerificationSummary", "Fixture verification passed before Finish."
	) -ExpectedExitCode 0 | Out-Null
	Invoke-TestGit -Arguments @("add", ".") | Out-Null
	Invoke-TestGit -Arguments @("commit", "-m", "finish template feature fixtures") | Out-Null

	$branchBeforeProjectRoleChecks = ([string]@(Invoke-TestGit -Arguments @("branch", "--show-current"))[0]).Trim()
	Invoke-TestGit -Arguments @("remote", "add", "upstream", "https://example.invalid/not-the-template.git") | Out-Null
	Invoke-Workflow -Arguments @(
		"-Action", "Start",
		"-Feature", "Ambiguous Repository Role",
		"-Title", "Ambiguous Repository Role",
		"-Slug", "ambiguous-repository-role"
	) -ExpectedExitCode 1 | Out-Null
	Assert-True (([string]@(Invoke-TestGit -Arguments @("branch", "--show-current"))[0]).Trim() -ceq $branchBeforeProjectRoleChecks) "an unrelated upstream remote must fail before branch mutation"
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $testRoot "docs\Features\project"))) "an unrelated upstream remote must not create project feature state"

	Invoke-TestGit -Arguments @("remote", "set-url", "upstream", "https://github.com/teano/roblox_project_template.git") | Out-Null
	Invoke-Workflow -Arguments @(
		"-Action", "Start",
		"-Feature", "Uninitialized Project Feature",
		"-Title", "Uninitialized Project Feature",
		"-Slug", "uninitialized-project-feature"
	) -ExpectedExitCode 1 | Out-Null
	Assert-True (([string]@(Invoke-TestGit -Arguments @("branch", "--show-current"))[0]).Trim() -ceq $branchBeforeProjectRoleChecks) "uninitialized derived project must fail before branch mutation"
	Assert-True (-not (Test-Path -LiteralPath (Join-Path $testRoot "docs\Features\project"))) "feature Start must not perform project initialization implicitly"

	New-Item -ItemType Directory -Path (Join-Path $testRoot "docs\adr\project") -Force | Out-Null
	Write-TestUtf8 -Path (Join-Path $testRoot "docs\adr\project\README.md") -Content "# Project ADRs`n"
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
	) -ExpectedExitCode 0 | Out-Null
	$projectFeaturePath = Join-Path $testRoot "docs\Features\project\existing-folder\feature.json"
	$projectFeature = Get-Content -LiteralPath $projectFeaturePath -Raw | ConvertFrom-Json
	Assert-True ($projectFeature.id -ceq "F-0001") "first derived-project feature ID must be F-0001"
	Assert-True ($projectFeature.branch -ceq "feature/t-0001-existing-folder") "project branch must use feature/t-####-slug"
	Assert-True ((Get-Content -LiteralPath $indexPath -Raw) -ceq $templateIndexBefore) "project start must not rewrite the template dashboard"
	$projectIndexPath = Join-Path $testRoot "docs\Features\project\README.md"
	$projectIndex = Get-Content -LiteralPath $projectIndexPath -Raw
	Assert-True ($projectIndex.Contains("F-0001")) "project dashboard must contain the project feature"
	Assert-True ($projectIndex.Contains("docs/Features/project/*/feature.json")) "project dashboard must render its namespace path"
	$projectBranch = [string]$projectFeature.branch

	Invoke-TestGit -Arguments @("switch", "--quiet", "-c", "unrelated-project-work") | Out-Null
	Invoke-Workflow -Arguments @(
		"-Action", "Pause",
		"-Feature", "F-0001",
		"-Summary", "Must not be recorded from another branch.",
		"-Decisions", "Recorded branch owns lifecycle mutations.",
		"-VerificationSummary", "Wrong-branch gate is under test.",
		"-NextStep", "Return to the recorded branch."
	) -ExpectedExitCode 1 | Out-Null
	$projectFeature = Get-Content -LiteralPath $projectFeaturePath -Raw | ConvertFrom-Json
	Assert-True ($projectFeature.activity -ceq "active") "wrong-branch Pause must not mutate project feature state"
	Invoke-TestGit -Arguments @("switch", "--quiet", $projectBranch) | Out-Null

	$projectLeaseFile = @(Get-ChildItem -LiteralPath (Join-Path $testRoot ".git\feature-workflow\locks") -Recurse -File -Filter "lease.json")[0]
	$projectLeaseDirectory = Split-Path -Parent $projectLeaseFile.FullName
	$projectLeaseContent = Get-Content -LiteralPath $projectLeaseFile.FullName -Raw
	Remove-Item -LiteralPath $projectLeaseDirectory -Recurse -Force
	Invoke-Workflow -Arguments @(
		"-Action", "Pause",
		"-Feature", "F-0001",
		"-Summary", "Must not be recorded without a lease.",
		"-Decisions", "Feature-scoped writer exclusion is mandatory.",
		"-VerificationSummary", "Missing-lease gate is under test.",
		"-NextStep", "Restore the valid lease."
	) -ExpectedExitCode 1 | Out-Null
	$projectFeature = Get-Content -LiteralPath $projectFeaturePath -Raw | ConvertFrom-Json
	Assert-True ($projectFeature.activity -ceq "active") "lease-less Pause must not mutate project feature state"
	New-Item -ItemType Directory -Path $projectLeaseDirectory -Force | Out-Null
	Write-TestUtf8 -Path (Join-Path $projectLeaseDirectory "lease.json") -Content $projectLeaseContent

	$legacyLease = $projectLeaseContent | ConvertFrom-Json
	$legacyLease | Add-Member -NotePropertyName sessionId -NotePropertyValue "forbidden-product-session"
	Write-TestUtf8 -Path (Join-Path $projectLeaseDirectory "lease.json") -Content (($legacyLease | ConvertTo-Json -Depth 10) + "`n")
	Invoke-Workflow -Arguments @(
		"-Action", "Pause",
		"-Feature", "F-0001",
		"-Summary", "Must not be recorded with a legacy lease.",
		"-Decisions", "Leases contain no agent or session identity.",
		"-VerificationSummary", "Legacy-lease gate is under test.",
		"-NextStep", "Restore the schema-v2 lease."
	) -ExpectedExitCode 1 | Out-Null
	Write-TestUtf8 -Path (Join-Path $projectLeaseDirectory "lease.json") -Content $projectLeaseContent

	Invoke-Workflow -Arguments @(
		"-Action", "Pause",
		"-Feature", "F-0001",
		"-Summary", "Derived-project implementation is paused with portable repository context.",
		"-Decisions", "Project features remain isolated under their owned namespace.",
		"-VerificationSummary", "Start, branch, initialization, and lease gates have passed.",
		"-NextStep", "Continue the same project feature from its recorded branch."
	) -ExpectedExitCode 0 | Out-Null
	$projectFeature = Get-Content -LiteralPath $projectFeaturePath -Raw | ConvertFrom-Json
	Assert-True ($projectFeature.activity -ceq "paused") "project Pause must create an in-progress paused checkpoint"
	Invoke-TestGit -Arguments @("switch", "--quiet", "unrelated-project-work") | Out-Null
	Invoke-Workflow -Arguments @("-Action", "Continue", "-Feature", "F-0001") -ExpectedExitCode 1 | Out-Null
	Invoke-TestGit -Arguments @("switch", "--quiet", $projectBranch) | Out-Null
	Invoke-Workflow -Arguments @("-Action", "Continue", "-Feature", "F-0001") -ExpectedExitCode 0 | Out-Null
	$projectFeature = Get-Content -LiteralPath $projectFeaturePath -Raw | ConvertFrom-Json
	Assert-True ($projectFeature.activity -ceq "active") "project Continue must reacquire the feature-scoped lease"

	Invoke-Workflow -Arguments @(
		"-Action", "Start",
		"-Feature", "TF-0001",
		"-ReopenReason", "Forbidden foreign mutation fixture.",
		"-AdoptChanges"
	) -ExpectedExitCode 1 | Out-Null

	$corruptTemplateIndex = $templateIndexBefore.Replace("Всего: 2", "Всего: 999")
	Write-TestUtf8 -Path $indexPath -Content $corruptTemplateIndex
	Invoke-IndexSync -Arguments @("-Scope", "Project") -ExpectedExitCode 0 -TestName "project-only dashboard synchronization" | Out-Null
	Assert-True ((Get-Content -LiteralPath $indexPath -Raw) -ceq $corruptTemplateIndex) "project sync must leave a foreign template dashboard byte-identical"
	Invoke-FeatureValidator -ExpectedExitCode 1 -TestName "foreign dashboard drift" | Out-Null
	Invoke-IndexSync -Arguments @("-Scope", "Template") -ExpectedExitCode 1 -TestName "forbidden foreign dashboard rewrite" | Out-Null
	Write-TestUtf8 -Path $indexPath -Content $templateIndexBefore
	Invoke-FeatureValidator -ExpectedExitCode 0 -TestName "restored foreign dashboard" | Out-Null

	Write-TestUtf8 -Path (Join-Path $testRoot "docs\Features\project\existing-folder\product-requirements.md") -Content "# Project requirements`n"
	Write-TestUtf8 -Path (Join-Path $testRoot "docs\Features\project\existing-folder\technical-specification.md") -Content "# Project specification`n"
	$projectFeature = Get-Content -LiteralPath $projectFeaturePath -Raw | ConvertFrom-Json
	$projectFeature.blockers = @()
	$projectFeature.artifacts = @("product-requirements.md", "technical-specification.md")
	Write-TestUtf8 -Path $projectFeaturePath -Content (($projectFeature | ConvertTo-Json -Depth 20) + "`n")
	Invoke-IndexSync -Arguments @("-Scope", "Project") -ExpectedExitCode 0 -TestName "project blocker dashboard update" | Out-Null
	$projectFeature | Add-Member -NotePropertyName agentId -NotePropertyValue "forbidden-agent-owner"
	Write-TestUtf8 -Path $projectFeaturePath -Content (($projectFeature | ConvertTo-Json -Depth 20) + "`n")
	Invoke-FeatureValidator -ExpectedExitCode 1 -TestName "unsupported project manifest identity" | Out-Null
	$projectFeature.PSObject.Properties.Remove("agentId")
	Write-TestUtf8 -Path $projectFeaturePath -Content (($projectFeature | ConvertTo-Json -Depth 20) + "`n")

	Invoke-TestGit -Arguments @("switch", "--quiet", "unrelated-project-work") | Out-Null
	Invoke-Workflow -Arguments @(
		"-Action", "Finish",
		"-Feature", "F-0001",
		"-Summary", "Must not finish from another branch.",
		"-Decisions", "Recorded branch remains authoritative.",
		"-VerificationSummary", "Wrong-branch Finish gate is under test."
	) -ExpectedExitCode 1 | Out-Null
	$projectFeature = Get-Content -LiteralPath $projectFeaturePath -Raw | ConvertFrom-Json
	Assert-True ($projectFeature.status -ceq "in_progress") "wrong-branch Finish must not mutate project feature state"
	Invoke-TestGit -Arguments @("switch", "--quiet", $projectBranch) | Out-Null
	Invoke-Workflow -Arguments @(
		"-Action", "Finish",
		"-Feature", "F-0001",
		"-Summary", "Derived project namespace fixture complete.",
		"-Decisions", "Project features use F-#### and feature/t-####-slug.",
		"-VerificationSummary", "Namespace isolation checks passed before Finish."
	) -ExpectedExitCode 0 | Out-Null
	Invoke-FeatureValidator -ExpectedExitCode 0 -TestName "completed project namespace" | Out-Null
	Invoke-TestGit -Arguments @("add", ".") | Out-Null
	Invoke-TestGit -Arguments @("commit", "-m", "finish derived project feature fixture") | Out-Null

	$historicalBranch = "legacy/project-feature-branch"
	Invoke-TestGit -Arguments @("switch", "--quiet", "-c", $historicalBranch) | Out-Null
	$projectFeature = Get-Content -LiteralPath $projectFeaturePath -Raw | ConvertFrom-Json
	$projectFeature.branch = $historicalBranch
	Write-TestUtf8 -Path $projectFeaturePath -Content (($projectFeature | ConvertTo-Json -Depth 20) + "`n")
	Invoke-IndexSync -Arguments @("-Scope", "Project") -ExpectedExitCode 0 -TestName "historical project branch dashboard" | Out-Null
	Invoke-TestGit -Arguments @("add", ".") | Out-Null
	Invoke-TestGit -Arguments @("commit", "-m", "record historical project branch fixture") | Out-Null
	Invoke-TestGit -Arguments @("switch", "--quiet", "-c", "project-reopen-caller") | Out-Null
	Invoke-Workflow -Arguments @(
		"-Action", "Start",
		"-Feature", "F-0001",
		"-ReopenReason", "Audit reopening from another branch."
	) -ExpectedExitCode 0 | Out-Null
	$projectFeature = Get-Content -LiteralPath $projectFeaturePath -Raw | ConvertFrom-Json
	Assert-True (([string]@(Invoke-TestGit -Arguments @("branch", "--show-current"))[0]).Trim() -ceq $historicalBranch) "project reopen must switch to the recorded existing branch"
	Assert-True ($projectFeature.branch -ceq $historicalBranch) "project reopen must preserve a historical branch name"
	Assert-True ($projectFeature.status -ceq "in_progress" -and $projectFeature.activity -ceq "active") "project reopen must reactivate ready work"
	$reopenedHandoff = Get-Content -LiteralPath (Join-Path $testRoot "docs\Features\project\existing-folder\handoff.md") -Raw
	$reopenedWorklog = Get-Content -LiteralPath (Join-Path $testRoot "docs\Features\project\existing-folder\worklog.md") -Raw
	Assert-True ($reopenedHandoff.Contains("Status: in_progress / active")) "project reopen must refresh the portable handoff state"
	Assert-True ($reopenedWorklog.Contains("— reopened") -and $reopenedWorklog.Contains("Audit reopening from another branch.")) "project reopen must append its reason to the portable worklog"
	Assert-True ((Get-Content -LiteralPath $indexPath -Raw) -ceq $templateIndexBefore) "project lifecycle must preserve the inherited template dashboard byte-for-byte"

	Write-Output "Feature workflow tests passed."
} finally {
	if ($hadCodexThreadId) {
		$env:CODEX_THREAD_ID = $previousCodexThreadId
	} else {
		Remove-Item Env:CODEX_THREAD_ID -ErrorAction SilentlyContinue
	}
	if (Test-Path -LiteralPath $testRoot -PathType Container) {
		$resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
		$resolvedTest = [IO.Path]::GetFullPath($testRoot)
		if (-not $resolvedTest.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase)) {
			throw "Refusing to clean unexpected test path '$resolvedTest'."
		}
		Remove-Item -LiteralPath $resolvedTest -Recurse -Force
	}
}
