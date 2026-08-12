Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$sourceRoot = (& git -C $PSScriptRoot rev-parse --show-toplevel).Trim()
if ($LASTEXITCODE -ne 0) { throw "Source repository root is unavailable." }
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("feature-workflow-tests-{0}" -f [Guid]::NewGuid().ToString("N"))
$repositoryValidationRoots = [Collections.Generic.List[string]]::new()
$powershell = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
if (-not (Test-Path -LiteralPath $powershell -PathType Leaf)) {
	throw "The current PowerShell host executable is unavailable: '$powershell'."
}
$hostLeaf = [IO.Path]::GetFileName($powershell)
if ($hostLeaf -notin @("powershell.exe", "pwsh.exe")) {
	throw "Unsupported current PowerShell host executable: '$powershell'."
}
$passedTf0008Identities = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$expectedCanonicalMatrixSha256 = "8d540766923b8cd7fa70217cd981802dd89951412a6c92563118b34fe9cffc0b"
$hadCodexThreadId = Test-Path Env:CODEX_THREAD_ID
$previousCodexThreadId = $env:CODEX_THREAD_ID
$env:CODEX_THREAD_ID = "invalid-product-specific-context-must-be-ignored"

function Assert-True {
	param([Parameter(Mandatory = $true)][bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
	if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Complete-Tf0008Identity {
	param([Parameter(Mandatory = $true)][ValidatePattern('^AUTO-TF0008-SPEC-TEST-\d{3}$')][string]$Identity)
	$null = $passedTf0008Identities.Add($Identity)
	Write-Output "$Identity passed on $hostLeaf"
}

function ConvertTo-TestDiagnosticLogicalText {
	param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
	$withoutAnsi = [regex]::Replace($Text, "`e\[[0-9;]*m", "")
	return [regex]::Replace($withoutAnsi, '\s+', ' ')
}

function Get-TestFileSha256 {
	param([Parameter(Mandatory = $true)][string]$Path)
	return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Test-TestByteArrayEqual {
	param(
		[Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Left,
		[Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Right
	)
	if ($Left.Length -ne $Right.Length) { return $false }
	for ($index = 0; $index -lt $Left.Length; $index++) {
		if ($Left[$index] -ne $Right[$index]) { return $false }
	}
	return $true
}

function Assert-CanonicalDashboardBytes {
	param([Parameter(Mandatory = $true)][string]$Path)
	$bytes = [IO.File]::ReadAllBytes($Path)
	Assert-True ($bytes.Length -gt 1) "$Path must not be empty"
	Assert-True (-not ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) "$Path must not contain a UTF-8 BOM"
	Assert-True (-not ($bytes -contains 0x0D)) "$Path must contain LF separators only"
	Assert-True ($bytes[$bytes.Length - 1] -eq 0x0A) "$Path must end with LF"
	Assert-True ($bytes[$bytes.Length - 2] -ne 0x0A) "$Path must contain exactly one terminal LF"
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

function Write-TestBytes {
	param(
		[Parameter(Mandatory = $true)][string]$Path,
		[Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Bytes
	)
	$parent = Split-Path -Parent $Path
	if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
		New-Item -ItemType Directory -Path $parent -Force | Out-Null
	}
	[IO.File]::WriteAllBytes($Path, $Bytes)
}

function Write-CultureHarness {
	param([Parameter(Mandatory = $true)][string]$Root)
	$content = @'
param(
	[Parameter(Mandatory = $true)][string]$Culture,
	[Parameter(Mandatory = $true)][string]$ScriptPath,
	[Parameter(Mandatory = $true)][ValidateSet("Default", "Writable", "All", "Template", "Project")][string]$Scope,
	[switch]$Check
)
$ErrorActionPreference = "Stop"
$previousCulture = [Threading.Thread]::CurrentThread.CurrentCulture
$previousUiCulture = [Threading.Thread]::CurrentThread.CurrentUICulture
$exitCode = 1
try {
	$selected = [Globalization.CultureInfo]::GetCultureInfo($Culture)
	[Threading.Thread]::CurrentThread.CurrentCulture = $selected
	[Threading.Thread]::CurrentThread.CurrentUICulture = $selected
	if ($Check) {
		& $ScriptPath -Scope $Scope -Check
	} else {
		& $ScriptPath -Scope $Scope
	}
	$exitCode = $LASTEXITCODE
} finally {
	[Threading.Thread]::CurrentThread.CurrentCulture = $previousCulture
	[Threading.Thread]::CurrentThread.CurrentUICulture = $previousUiCulture
}
exit $exitCode
'@
	Write-TestUtf8 -Path (Join-Path $Root "scripts\invoke-with-culture.ps1") -Content ($content + "`n")
}

function Invoke-IndexSyncAt {
	param(
		[Parameter(Mandatory = $true)][string]$Root,
		[Parameter(Mandatory = $true)][string[]]$Arguments,
		[Parameter(Mandatory = $true)][int]$ExpectedExitCode,
		[Parameter(Mandatory = $true)][string]$TestName,
		[string]$Culture
	)
	$scriptPath = Join-Path $Root "scripts\sync-feature-index.ps1"
	$previousPreference = $ErrorActionPreference
	try {
		$ErrorActionPreference = "Continue"
		if ([string]::IsNullOrWhiteSpace($Culture)) {
			$output = @(& $powershell -NoProfile -ExecutionPolicy Bypass -File $scriptPath @Arguments 2>&1)
		} else {
			$scopeIndex = [Array]::IndexOf($Arguments, "-Scope")
			if ($scopeIndex -lt 0 -or $scopeIndex + 1 -ge $Arguments.Count) {
				throw "$TestName culture invocation requires an exact -Scope value."
			}
			$scopeValue = $Arguments[$scopeIndex + 1]
			if ($Arguments -contains "-Check") {
				$output = @(& $powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "scripts\invoke-with-culture.ps1") -Culture $Culture -ScriptPath $scriptPath -Scope $scopeValue -Check 2>&1)
			} else {
				$output = @(& $powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "scripts\invoke-with-culture.ps1") -Culture $Culture -ScriptPath $scriptPath -Scope $scopeValue 2>&1)
			}
		}
		$exitCode = $LASTEXITCODE
	} finally {
		$ErrorActionPreference = $previousPreference
	}
	if ($exitCode -ne $ExpectedExitCode) {
		throw "$TestName sync exit $exitCode, expected $ExpectedExitCode.`n$($output -join [Environment]::NewLine)"
	}
	return $output
}

function Invoke-PowerShellScriptAt {
	param(
		[Parameter(Mandatory = $true)][string]$Root,
		[Parameter(Mandatory = $true)][string]$RelativePath,
		[Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Arguments,
		[Parameter(Mandatory = $true)][int]$ExpectedExitCode,
		[Parameter(Mandatory = $true)][string]$TestName
	)
	$scriptPath = Join-Path $Root $RelativePath
	$previousPreference = $ErrorActionPreference
	try {
		$ErrorActionPreference = "Continue"
		$output = @(& $powershell -NoProfile -ExecutionPolicy Bypass -File $scriptPath @Arguments 2>&1)
		$exitCode = $LASTEXITCODE
	} finally {
		$ErrorActionPreference = $previousPreference
	}
	if ($exitCode -ne $ExpectedExitCode) {
		throw "$TestName exit $exitCode, expected $ExpectedExitCode.`n$($output -join [Environment]::NewLine)"
	}
	return $output
}

function Write-RepositoryGateCultureHarness {
	param([Parameter(Mandatory = $true)][string]$Root)
	$content = @'
param(
	[Parameter(Mandatory = $true)][string]$Culture,
	[Parameter(Mandatory = $true)][string]$ScriptPath
)
$ErrorActionPreference = "Stop"
$previousCulture = [Threading.Thread]::CurrentThread.CurrentCulture
$previousUiCulture = [Threading.Thread]::CurrentThread.CurrentUICulture
try {
	$selected = [Globalization.CultureInfo]::GetCultureInfo($Culture)
	[Threading.Thread]::CurrentThread.CurrentCulture = $selected
	[Threading.Thread]::CurrentThread.CurrentUICulture = $selected
	& $ScriptPath
	if (-not $?) { exit 1 }
} finally {
	[Threading.Thread]::CurrentThread.CurrentCulture = $previousCulture
	[Threading.Thread]::CurrentThread.CurrentUICulture = $previousUiCulture
}
exit 0
'@
	Write-TestUtf8 -Path (Join-Path $Root "scripts\invoke-repository-gate-with-culture.ps1") -Content ($content + "`n")
}

function Invoke-RepositoryGateAtWithCulture {
	param(
		[Parameter(Mandatory = $true)][string]$Root,
		[Parameter(Mandatory = $true)][string]$RelativePath,
		[Parameter(Mandatory = $true)][string]$Culture,
		[Parameter(Mandatory = $true)][int]$ExpectedExitCode,
		[Parameter(Mandatory = $true)][string]$TestName
	)
	$harnessPath = Join-Path $Root "scripts\invoke-repository-gate-with-culture.ps1"
	$scriptPath = Join-Path $Root $RelativePath
	$previousPreference = $ErrorActionPreference
	try {
		$ErrorActionPreference = "Continue"
		$output = @(& $powershell -NoProfile -ExecutionPolicy Bypass -File $harnessPath -Culture $Culture -ScriptPath $scriptPath 2>&1)
		$exitCode = $LASTEXITCODE
	} finally {
		$ErrorActionPreference = $previousPreference
	}
	if ($exitCode -ne $ExpectedExitCode) {
		throw "$TestName exit $exitCode, expected $ExpectedExitCode.`n$($output -join [Environment]::NewLine)"
	}
	return $output
}

function New-TemplateDashboardFixture {
	param(
		[Parameter(Mandatory = $true)][string]$Name,
		[Parameter(Mandatory = $true)][string]$UpdatedAt,
		[Parameter(Mandatory = $true)][ValidateSet("false", "true")][string]$CoreAutoCrlf
	)
	$root = Join-Path $testRoot "dashboard-fixtures\$Name"
	New-Item -ItemType Directory -Path (Join-Path $root "scripts") -Force | Out-Null
	New-Item -ItemType Directory -Path (Join-Path $root "docs\Features\template\fixture") -Force | Out-Null
	foreach ($nameToCopy in @("FeatureWorkflow.psm1", "sync-feature-index.ps1")) {
		Copy-Item -LiteralPath (Join-Path $sourceRoot "scripts\$nameToCopy") -Destination (Join-Path $root "scripts\$nameToCopy")
	}
	Copy-Item -LiteralPath (Join-Path $sourceRoot ".gitattributes") -Destination (Join-Path $root ".gitattributes")
	Write-CultureHarness -Root $root
	& git -C $root init -b main | Out-Null
	if ($LASTEXITCODE -ne 0) { throw "git init failed for dashboard fixture '$Name'." }
	& git -C $root config core.autocrlf $CoreAutoCrlf
	if ($LASTEXITCODE -ne 0) { throw "git core.autocrlf configuration failed for dashboard fixture '$Name'." }
	$manifest = [ordered]@{
		schemaVersion = 2
		id = "TF-0001"
		slug = "fixture"
		title = "Пример | 🧪"
		status = "ready"
		activity = "none"
		branch = "main"
		baseCommit = ("a" * 40)
		startedAt = "2026-08-01T00:00:00Z"
		completedAt = "2026-08-02T00:00:00Z"
		updatedAt = $UpdatedAt
		blockers = @()
		artifacts = @()
		verification = $null
		recoveryLog = @()
	}
	Write-TestUtf8 -Path (Join-Path $root "docs\Features\template\fixture\feature.json") -Content (($manifest | ConvertTo-Json -Depth 10) + "`n")
	Write-TestUtf8 -Path (Join-Path $root "docs\Features\template\fixture\handoff.md") -Content "# Feature handoff`n"
	Write-TestUtf8 -Path (Join-Path $root "docs\Features\template\fixture\worklog.md") -Content "# Feature worklog`n"
	Write-TestUtf8 -Path (Join-Path $root "docs\Features\README.md") -Content "# Feature registries`n"
	return $root
}

function New-RepositoryValidationFixture {
	param([Parameter(Mandatory = $true)][string]$Name)
	$container = Join-Path ([IO.Path]::GetTempPath()) ("feature-workflow-repository-fixture-{0}-{1}" -f $Name, [Guid]::NewGuid().ToString("N"))
	$repositoryValidationRoots.Add($container)
	$root = Join-Path $container (Split-Path -Leaf $sourceRoot)
	New-Item -ItemType Directory -Path $root -Force | Out-Null
	$excludedTopLevelNames = @(".agentic-pipeline", ".codegraph", ".git")
	foreach ($item in Get-ChildItem -LiteralPath $sourceRoot -Force) {
		if ($item.Name -in $excludedTopLevelNames) { continue }
		Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $root $item.Name) -Recurse -Force
	}
	& git -C $root init -b main | Out-Null
	if ($LASTEXITCODE -ne 0) { throw "git init failed for repository fixture '$Name'." }
	& git -C $root config core.autocrlf false
	if ($LASTEXITCODE -ne 0) { throw "git core.autocrlf configuration failed for repository fixture '$Name'." }
	Write-CultureHarness -Root $root
	Write-RepositoryGateCultureHarness -Root $root
	return $root
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

	# AUTO-TF0008-SPEC-TEST-001 / 009: current-host culture and Git matrix.
	$matrixHashes = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
	foreach ($autoCrlf in @("false", "true")) {
		foreach ($culture in @("en-US", "ru-RU")) {
			$matrixRoot = New-TemplateDashboardFixture -Name "matrix-$autoCrlf-$culture" -UpdatedAt "2026-08-05T13:28:08Z" -CoreAutoCrlf $autoCrlf
			Invoke-IndexSyncAt -Root $matrixRoot -Arguments @("-Scope", "Template") -ExpectedExitCode 0 -TestName "matrix $autoCrlf $culture" -Culture $culture | Out-Null
			$matrixIndex = Join-Path $matrixRoot "docs\Features\template\README.md"
			Assert-CanonicalDashboardBytes -Path $matrixIndex
			$matrixText = [Text.UTF8Encoding]::new($false, $true).GetString([IO.File]::ReadAllBytes($matrixIndex))
			Assert-True ($matrixText.Contains("Пример \| 🧪")) "matrix dashboard must preserve Cyrillic, emoji, and Markdown escaping"
			Assert-True ($matrixText.Contains("| 2026-08-05 |")) "Z instant must render as the invariant UTC date"
			$matrixHash = Get-TestFileSha256 -Path $matrixIndex
			Assert-True ($matrixHash -ceq $expectedCanonicalMatrixSha256) "matrix output must match the fixed cross-host canonical SHA-256"
			$null = $matrixHashes.Add($matrixHash)
			$matrixBefore = Get-TestFileSha256 -Path $matrixIndex
			Invoke-IndexSyncAt -Root $matrixRoot -Arguments @("-Check", "-Scope", "Template") -ExpectedExitCode 0 -TestName "matrix Check $autoCrlf $culture" -Culture $culture | Out-Null
			Assert-True ((Get-TestFileSha256 -Path $matrixIndex) -ceq $matrixBefore) "matrix Check must preserve exact bytes"
			Assert-True ((& git -C $matrixRoot config --get core.autocrlf).Trim() -ceq $autoCrlf) "matrix fixture must retain core.autocrlf=$autoCrlf"
		}
	}
	Assert-True ($matrixHashes.Count -eq 1) "all current-host culture/Git cells must produce one canonical dashboard SHA-256"
	Write-Output "TF-0008 canonical matrix SHA-256: $expectedCanonicalMatrixSha256"
	Complete-Tf0008Identity "AUTO-TF0008-SPEC-TEST-001"
	Complete-Tf0008Identity "AUTO-TF0008-SPEC-TEST-009"

	# AUTO-TF0008-SPEC-TEST-015: reproduce the reported ru-RU input on Windows 11.
	$reportedFixtureRoot = New-RepositoryValidationFixture -Name "reported-windows10-pwsh7-ruru"
	$reportedManifest = Join-Path $reportedFixtureRoot "docs\Features\template\deterministic-feature-dashboard-validation\feature.json"
	$reportedManifestText = [Text.UTF8Encoding]::new($false, $true).GetString([IO.File]::ReadAllBytes($reportedManifest))
	$reportedManifestText = [regex]::Replace(
		$reportedManifestText,
		'("updatedAt"\s*:\s*")[^"]*(")',
		{ param($match) $match.Groups[1].Value + "2026-08-05T13:28:08.08195+03:00" + $match.Groups[2].Value },
		1
	)
	Write-TestUtf8 -Path $reportedManifest -Content $reportedManifestText
	Invoke-IndexSyncAt -Root $reportedFixtureRoot -Arguments @("-Scope", "Template") -ExpectedExitCode 0 -TestName "reported ru-RU fixture" -Culture "ru-RU" | Out-Null
	$reportedIndex = Join-Path $reportedFixtureRoot "docs\Features\template\README.md"
	$reportedText = [Text.UTF8Encoding]::new($false, $true).GetString([IO.File]::ReadAllBytes($reportedIndex))
	$reportedFeatureRow = @($reportedText -split "`n" | Where-Object { $_ -match '^\| TF-0008 ' })
	Assert-True ($reportedFeatureRow.Count -eq 1 -and $reportedFeatureRow[0].Contains("| 2026-08-05 |")) "reported ru-RU fixture must not transpose the UTC date"
	$reportedBefore = Get-TestFileSha256 -Path $reportedIndex
	Invoke-IndexSyncAt -Root $reportedFixtureRoot -Arguments @("-Check", "-Scope", "Template") -ExpectedExitCode 0 -TestName "reported ru-RU fixture Check" -Culture "ru-RU" | Out-Null
	Invoke-RepositoryGateAtWithCulture -Root $reportedFixtureRoot -RelativePath "scripts\validate-feature-workflow.ps1" -Culture "ru-RU" -ExpectedExitCode 0 -TestName "reported ru-RU feature validator" | Out-Null
	Invoke-RepositoryGateAtWithCulture -Root $reportedFixtureRoot -RelativePath "scripts\validate-repository-layout.ps1" -Culture "ru-RU" -ExpectedExitCode 0 -TestName "reported ru-RU repository-layout validator" | Out-Null
	Assert-True ((Get-TestFileSha256 -Path $reportedIndex) -ceq $reportedBefore) "reported ru-RU fixture Check must be read-only"
	Complete-Tf0008Identity "AUTO-TF0008-SPEC-TEST-015"

	$eolRoot = New-TemplateDashboardFixture -Name "eol" -UpdatedAt "2026-08-05T13:28:08Z" -CoreAutoCrlf "false"
	Invoke-IndexSyncAt -Root $eolRoot -Arguments @("-Scope", "Template") -ExpectedExitCode 0 -TestName "canonical EOL fixture" | Out-Null
	$eolIndex = Join-Path $eolRoot "docs\Features\template\README.md"
	$canonicalEolBytes = [IO.File]::ReadAllBytes($eolIndex)
	$canonicalEolText = [Text.UTF8Encoding]::new($false, $true).GetString($canonicalEolBytes)

	# AUTO-TF0008-SPEC-TEST-002: canonical LF Check is byte-immutable.
	$lfBefore = Get-TestFileSha256 -Path $eolIndex
	Invoke-IndexSyncAt -Root $eolRoot -Arguments @("-Check", "-Scope", "Template") -ExpectedExitCode 0 -TestName "LF Check" | Out-Null
	Assert-True ((Get-TestFileSha256 -Path $eolIndex) -ceq $lfBefore) "LF Check must preserve exact bytes"
	Complete-Tf0008Identity "AUTO-TF0008-SPEC-TEST-002"

	# AUTO-TF0008-SPEC-TEST-003: only line-separator representation is ignored.
	$mixedBuilder = [Text.StringBuilder]::new()
	$mixedParts = $canonicalEolText.Split([char]10)
	for ($partIndex = 0; $partIndex -lt $mixedParts.Length - 1; $partIndex++) {
		$null = $mixedBuilder.Append($mixedParts[$partIndex])
		$null = $mixedBuilder.Append($(if (($partIndex % 2) -eq 0) { "`r`n" } else { "`r" }))
	}
	$eolVariants = [ordered]@{
		CRLF = $canonicalEolText.Replace("`n", "`r`n")
		CR = $canonicalEolText.Replace("`n", "`r")
		mixed = $mixedBuilder.ToString()
	}
	foreach ($variantName in $eolVariants.Keys) {
		Write-TestUtf8 -Path $eolIndex -Content $eolVariants[$variantName]
		$variantBefore = Get-TestFileSha256 -Path $eolIndex
		Invoke-IndexSyncAt -Root $eolRoot -Arguments @("-Check", "-Scope", "Template") -ExpectedExitCode 0 -TestName "$variantName logical Check" | Out-Null
		Assert-True ((Get-TestFileSha256 -Path $eolIndex) -ceq $variantBefore) "$variantName Check must preserve exact bytes"
	}
	Complete-Tf0008Identity "AUTO-TF0008-SPEC-TEST-003"

	# AUTO-TF0008-SPEC-TEST-004: owning sync canonicalizes and is idempotent.
	Write-TestUtf8 -Path $eolIndex -Content $eolVariants.CRLF
	Invoke-IndexSyncAt -Root $eolRoot -Arguments @("-Scope", "Template") -ExpectedExitCode 0 -TestName "owning CRLF canonicalization" | Out-Null
	Assert-True (Test-TestByteArrayEqual -Left ([IO.File]::ReadAllBytes($eolIndex)) -Right $canonicalEolBytes) "owning sync must restore exact canonical LF bytes"
	$canonicalizedHash = Get-TestFileSha256 -Path $eolIndex
	Invoke-IndexSyncAt -Root $eolRoot -Arguments @("-Scope", "Template") -ExpectedExitCode 0 -TestName "owning canonical idempotence" | Out-Null
	Assert-True ((Get-TestFileSha256 -Path $eolIndex) -ceq $canonicalizedHash) "second owning sync must preserve exact SHA-256"
	Complete-Tf0008Identity "AUTO-TF0008-SPEC-TEST-004"

	# AUTO-TF0008-SPEC-TEST-013: a missing owning dashboard is fully recreated.
	Remove-Item -LiteralPath $eolIndex -Force
	Invoke-IndexSyncAt -Root $eolRoot -Arguments @("-Scope", "Template") -ExpectedExitCode 0 -TestName "missing owning dashboard recovery" | Out-Null
	Assert-True (Test-TestByteArrayEqual -Left ([IO.File]::ReadAllBytes($eolIndex)) -Right $canonicalEolBytes) "missing owning dashboard must be recreated canonically"
	Assert-CanonicalDashboardBytes -Path $eolIndex
	Complete-Tf0008Identity "AUTO-TF0008-SPEC-TEST-013"

	# AUTO-TF0008-SPEC-TEST-007: full-file drift is detected and owning sync repairs it.
	$canonicalIndexBytes = [IO.File]::ReadAllBytes($indexPath)
	$canonicalIndexText = [Text.UTF8Encoding]::new($false, $true).GetString($canonicalIndexBytes)
	$featureRows = @([regex]::Matches($canonicalIndexText, '(?m)^\| TF-\d{4} .+\|$') | ForEach-Object { $_.Value })
	Assert-True ($featureRows.Count -eq 2) "drift matrix fixture must expose two feature rows"
	$rowSwapToken = "__TF0008_ROW_SWAP_TOKEN__"
	$rowSwapped = $canonicalIndexText.Replace($featureRows[0], $rowSwapToken).Replace($featureRows[1], $featureRows[0]).Replace($rowSwapToken, $featureRows[1])
	$driftCases = @(
		[pscustomobject]@{ Name = "counter"; Category = "content"; Text = $canonicalIndexText.Replace("Всего: 2", "Всего: 999") },
		[pscustomobject]@{ Name = "feature row"; Category = "content"; Text = $canonicalIndexText.Replace("[Adopt Existing]", "[Altered Existing]") },
		[pscustomobject]@{ Name = "date"; Category = "content"; Text = [regex]::Replace($canonicalIndexText, '\| \d{4}-\d{2}-\d{2} \|', '| 1999-12-31 |', 1) },
		[pscustomobject]@{ Name = "marker"; Category = "markers"; Text = $canonicalIndexText.Replace("<!-- feature-index:begin -->", "<!-- feature-index:broken -->") },
		[pscustomobject]@{ Name = "table"; Category = "content"; Text = $canonicalIndexText.Replace("| ID | Фича |", "| IX | Фича |") },
		[pscustomobject]@{ Name = "row order"; Category = "content"; Text = $rowSwapped },
		[pscustomobject]@{ Name = "title"; Category = "content"; Text = $canonicalIndexText.Replace("# Фичи шаблона", "# Повреждённый заголовок") },
		[pscustomobject]@{ Name = "prose"; Category = "content"; Text = $canonicalIndexText.Replace("Этот dashboard генерируется из", "Этот dashboard больше не каноничен") },
		[pscustomobject]@{ Name = "namespace path"; Category = "content"; Text = $canonicalIndexText.Replace("docs/Features/template/*/feature.json", "docs/Features/project/*/feature.json") }
	)
	foreach ($driftCase in $driftCases) {
		Write-TestUtf8 -Path $indexPath -Content $driftCase.Text
		$driftBefore = Get-TestFileSha256 -Path $indexPath
		$driftOutput = @(Invoke-IndexSync -Arguments @("-Check", "-Scope", "Template") -ExpectedExitCode 1 -TestName "$($driftCase.Name) drift")
		Assert-True ((Get-TestFileSha256 -Path $indexPath) -ceq $driftBefore) "$($driftCase.Name) Check must preserve exact bytes"
		Assert-True (($driftOutput -join "`n").Contains("category=$($driftCase.Category)")) "$($driftCase.Name) must report category=$($driftCase.Category)"
		Invoke-IndexSync -Arguments @("-Scope", "Template") -ExpectedExitCode 0 -TestName "$($driftCase.Name) owning repair" | Out-Null
		Assert-True (Test-TestByteArrayEqual -Left ([IO.File]::ReadAllBytes($indexPath)) -Right $canonicalIndexBytes) "$($driftCase.Name) owning sync must repair the complete dashboard"
	}
	Complete-Tf0008Identity "AUTO-TF0008-SPEC-TEST-007"

	$dateRoot = New-TemplateDashboardFixture -Name "dates" -UpdatedAt "2026-08-05T13:28:08Z" -CoreAutoCrlf "false"
	Invoke-IndexSyncAt -Root $dateRoot -Arguments @("-Scope", "Template") -ExpectedExitCode 0 -TestName "date fixture baseline" | Out-Null
	$dateIndex = Join-Path $dateRoot "docs\Features\template\README.md"
	$dateManifest = Join-Path $dateRoot "docs\Features\template\fixture\feature.json"
	$dateManifestBaseline = [Text.UTF8Encoding]::new($false, $true).GetString([IO.File]::ReadAllBytes($dateManifest))
	$dateIndexBaselineHash = Get-TestFileSha256 -Path $dateIndex
	$updatedAtPattern = '("updatedAt"\s*:\s*")[^"]*(")'

	# AUTO-TF0008-SPEC-TEST-010 / 011: UTC date boundaries.
	$positiveOffsetManifest = [regex]::Replace($dateManifestBaseline, $updatedAtPattern, { param($match) $match.Groups[1].Value + "2026-08-05T00:30:00+14:00" + $match.Groups[2].Value })
	Write-TestUtf8 -Path $dateManifest -Content $positiveOffsetManifest
	Invoke-IndexSyncAt -Root $dateRoot -Arguments @("-Scope", "Template") -ExpectedExitCode 0 -TestName "positive offset UTC boundary" | Out-Null
	Assert-True (([Text.UTF8Encoding]::new($false, $true).GetString([IO.File]::ReadAllBytes($dateIndex))).Contains("| 2026-08-04 |")) "+14:00 timestamp must render as UTC date 2026-08-04"
	Complete-Tf0008Identity "AUTO-TF0008-SPEC-TEST-010"
	$negativeOffsetManifest = [regex]::Replace($dateManifestBaseline, $updatedAtPattern, { param($match) $match.Groups[1].Value + "2026-08-05T23:30:00-12:00" + $match.Groups[2].Value })
	Write-TestUtf8 -Path $dateManifest -Content $negativeOffsetManifest
	Invoke-IndexSyncAt -Root $dateRoot -Arguments @("-Scope", "Template") -ExpectedExitCode 0 -TestName "negative offset UTC boundary" | Out-Null
	Assert-True (([Text.UTF8Encoding]::new($false, $true).GetString([IO.File]::ReadAllBytes($dateIndex))).Contains("| 2026-08-06 |")) "-12:00 timestamp must render as UTC date 2026-08-06"
	Complete-Tf0008Identity "AUTO-TF0008-SPEC-TEST-011"

	# AUTO-TF0008-SPEC-TEST-012: invalid timestamps fail before dashboard write.
	Write-TestUtf8 -Path $dateManifest -Content $dateManifestBaseline
	Invoke-IndexSyncAt -Root $dateRoot -Arguments @("-Scope", "Template") -ExpectedExitCode 0 -TestName "date fixture restore" | Out-Null
	$dateIndexBaselineHash = Get-TestFileSha256 -Path $dateIndex
	foreach ($invalidTimestamp in @("2026-08-05", "08/05/2026", "2026-02-30T10:00:00Z", "2026-08-05T10:00:00", "2026-08-05T10:00:00+15:99")) {
		$invalidManifest = [regex]::Replace($dateManifestBaseline, $updatedAtPattern, { param($match) $match.Groups[1].Value + $invalidTimestamp + $match.Groups[2].Value })
		Write-TestUtf8 -Path $dateManifest -Content $invalidManifest
		$invalidOutput = @(Invoke-IndexSyncAt -Root $dateRoot -Arguments @("-Scope", "Template") -ExpectedExitCode 1 -TestName "invalid timestamp $invalidTimestamp")
		Assert-True ((Get-TestFileSha256 -Path $dateIndex) -ceq $dateIndexBaselineHash) "invalid timestamp '$invalidTimestamp' must not mutate the dashboard"
		Assert-True (($invalidOutput -join "`n").Contains("category=manifest")) "invalid timestamp '$invalidTimestamp' must report manifest validation"
	}
	Write-TestUtf8 -Path $dateManifest -Content $dateManifestBaseline
	Complete-Tf0008Identity "AUTO-TF0008-SPEC-TEST-012"

	# AUTO-TF0008-SPEC-TEST-018: strict UTF-8, surrogate, recovery, and encoder boundaries.
	$utfRoot = New-TemplateDashboardFixture -Name "unicode" -UpdatedAt "2026-08-05T13:28:08Z" -CoreAutoCrlf "false"
	Invoke-IndexSyncAt -Root $utfRoot -Arguments @("-Scope", "Template") -ExpectedExitCode 0 -TestName "Unicode fixture baseline" | Out-Null
	$utfIndex = Join-Path $utfRoot "docs\Features\template\README.md"
	$utfManifest = Join-Path $utfRoot "docs\Features\template\fixture\feature.json"
	$utfManifestBytes = [IO.File]::ReadAllBytes($utfManifest)
	$utfManifestText = [Text.UTF8Encoding]::new($false, $true).GetString($utfManifestBytes)
	$utfIndexCanonicalBytes = [IO.File]::ReadAllBytes($utfIndex)
	$utfIndexCanonicalHash = Get-TestFileSha256 -Path $utfIndex
	$invalidManifestBytes = [byte[]]::new($utfManifestBytes.Length)
	[Array]::Copy($utfManifestBytes, $invalidManifestBytes, $utfManifestBytes.Length)
	$nonAsciiByteIndex = -1
	for ($byteIndex = 0; $byteIndex -lt $invalidManifestBytes.Length; $byteIndex++) {
		if ($invalidManifestBytes[$byteIndex] -ge 0x80) { $nonAsciiByteIndex = $byteIndex; break }
	}
	Assert-True ($nonAsciiByteIndex -ge 0) "Unicode fixture manifest must contain non-ASCII UTF-8 bytes"
	$invalidManifestBytes[$nonAsciiByteIndex] = 0xFF
	Write-TestBytes -Path $utfManifest -Bytes $invalidManifestBytes
	$invalidUtf8ManifestOutput = @(Invoke-IndexSyncAt -Root $utfRoot -Arguments @("-Scope", "Template") -ExpectedExitCode 1 -TestName "invalid UTF-8 manifest")
	Assert-True ((Get-TestFileSha256 -Path $utfIndex) -ceq $utfIndexCanonicalHash) "invalid UTF-8 manifest must not mutate the dashboard"
	Assert-True (($invalidUtf8ManifestOutput -join "`n").Contains("category=manifest") -and ($invalidUtf8ManifestOutput -join "`n").Contains("cause=encoding")) "invalid UTF-8 manifest must report stable manifest encoding diagnostics"

	$titlePattern = '("title"\s*:\s*")[^"]*(")'
	foreach ($invalidTitleEscape in @('\uD800', '\uDC00', '\uD800\u0041')) {
		$invalidSurrogateManifest = [regex]::Replace($utfManifestText, $titlePattern, { param($match) $match.Groups[1].Value + $invalidTitleEscape + $match.Groups[2].Value })
		Write-TestUtf8 -Path $utfManifest -Content $invalidSurrogateManifest
		$surrogateOutput = @(Invoke-IndexSyncAt -Root $utfRoot -Arguments @("-Scope", "Template") -ExpectedExitCode 1 -TestName "invalid surrogate $invalidTitleEscape")
		Assert-True ((Get-TestFileSha256 -Path $utfIndex) -ceq $utfIndexCanonicalHash) "invalid surrogate '$invalidTitleEscape' must not mutate the dashboard"
		Assert-True (($surrogateOutput -join "`n").Contains("invalid-surrogate-escape")) "invalid surrogate '$invalidTitleEscape' must report its stable cause"
		Assert-True (@(Get-ChildItem -LiteralPath (Split-Path -Parent $utfIndex) -Filter "*.tmp" -Force).Count -eq 0) "invalid surrogate must not leave a temporary dashboard"
	}
	$validPairManifest = [regex]::Replace($utfManifestText, $titlePattern, { param($match) $match.Groups[1].Value + '\uD83D\uDE00' + $match.Groups[2].Value })
	Write-TestUtf8 -Path $utfManifest -Content $validPairManifest
	Invoke-IndexSyncAt -Root $utfRoot -Arguments @("-Scope", "Template") -ExpectedExitCode 0 -TestName "valid surrogate pair" | Out-Null
	$validPairText = [Text.UTF8Encoding]::new($false, $true).GetString([IO.File]::ReadAllBytes($utfIndex))
	Assert-True ($validPairText.Contains("😀")) "valid surrogate pair must render the intended scalar"
	$escapedBackslashManifest = [regex]::Replace($utfManifestText, $titlePattern, { param($match) $match.Groups[1].Value + '\\uD800' + $match.Groups[2].Value })
	Write-TestUtf8 -Path $utfManifest -Content $escapedBackslashManifest
	Invoke-IndexSyncAt -Root $utfRoot -Arguments @("-Scope", "Template") -ExpectedExitCode 0 -TestName "escaped backslash surrogate text" | Out-Null
	$escapedBackslashText = [Text.UTF8Encoding]::new($false, $true).GetString([IO.File]::ReadAllBytes($utfIndex))
	Assert-True ($escapedBackslashText.Contains("\uD800")) "escaped backslash must remain literal text"

	Write-TestUtf8 -Path $utfManifest -Content $utfManifestText
	Invoke-IndexSyncAt -Root $utfRoot -Arguments @("-Scope", "Template") -ExpectedExitCode 0 -TestName "Unicode fixture canonical restore" | Out-Null
	Write-TestBytes -Path $utfIndex -Bytes ([byte[]]@(0xFF, 0xFE, 0x0A))
	$invalidDashboardHash = Get-TestFileSha256 -Path $utfIndex
	$invalidDashboardOutput = @(Invoke-IndexSyncAt -Root $utfRoot -Arguments @("-Check", "-Scope", "Template") -ExpectedExitCode 1 -TestName "invalid UTF-8 dashboard Check")
	Assert-True ((Get-TestFileSha256 -Path $utfIndex) -ceq $invalidDashboardHash) "invalid UTF-8 dashboard Check must preserve exact bytes"
	Assert-True (($invalidDashboardOutput -join "`n").Contains("category=encoding")) "invalid UTF-8 dashboard Check must report encoding drift"
	Invoke-IndexSyncAt -Root $utfRoot -Arguments @("-Scope", "Template") -ExpectedExitCode 0 -TestName "invalid UTF-8 owning recovery" | Out-Null
	Assert-True (Test-TestByteArrayEqual -Left ([IO.File]::ReadAllBytes($utfIndex)) -Right $utfIndexCanonicalBytes) "owning sync must recover invalid UTF-8 dashboard bytes"

	$module = Import-Module (Join-Path $utfRoot "scripts\FeatureWorkflow.psm1") -Force -PassThru
	$strictEncoderTarget = Join-Path $utfRoot "missing-parent\README.md"
	$strictEncoderThrew = $false
	try {
		& $module { param($path, $text) Write-FeatureDashboard -Path $path -CanonicalText $text } $strictEncoderTarget ([string][char]0xD800) | Out-Null
	} catch [Text.EncoderFallbackException] {
		$strictEncoderThrew = $true
	}
	Assert-True $strictEncoderThrew "strict dashboard encoder must reject an unpaired surrogate"
	Assert-True (-not (Test-Path -LiteralPath (Split-Path -Parent $strictEncoderTarget))) "strict encoder failure must precede parent/temp/destination creation"
	$dashboardFixturesPath = Join-Path $testRoot "dashboard-fixtures"
	Assert-True (Test-Path -LiteralPath $dashboardFixturesPath -PathType Container) "dashboard fixture root must exist before guarded cleanup"
	Remove-Item -LiteralPath $dashboardFixturesPath -Recurse -Force

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

	$templateCanonicalBytes = [IO.File]::ReadAllBytes($indexPath)
	$templateCanonicalText = [Text.UTF8Encoding]::new($false, $true).GetString($templateCanonicalBytes)
	$diagnosticProjectIndexPath = Join-Path $testRoot "docs\Features\project\README.md"
	$diagnosticProjectIndexHash = Get-TestFileSha256 -Path $diagnosticProjectIndexPath

	# AUTO-TF0008-SPEC-TEST-018 remediation: strict foreign manifest failures
	# must identify the manifest owner and only offer upstream recovery.
	$foreignManifestPath = $secondPath
	$foreignManifestBytes = [IO.File]::ReadAllBytes($foreignManifestPath)
	$foreignManifestText = [Text.UTF8Encoding]::new($false, $true).GetString($foreignManifestBytes)
	$foreignManifestWithoutClosingBrace = $foreignManifestText.Substring(0, $foreignManifestText.LastIndexOf([char]'}')) + "`n"
	$foreignManifestInvalidSurrogate = [regex]::Replace(
		$foreignManifestText,
		'("title"\s*:\s*")[^"]*(")',
		{ param($match) $match.Groups[1].Value + '\uD800' + $match.Groups[2].Value },
		1
	)
	$foreignManifestInvalidUtf8 = [byte[]]::new($foreignManifestBytes.Length + 1)
	$foreignManifestInvalidUtf8[0] = 0xFF
	[Array]::Copy($foreignManifestBytes, 0, $foreignManifestInvalidUtf8, 1, $foreignManifestBytes.Length)
	$strictForeignManifestCases = @(
		[pscustomobject]@{ Name = "foreign manifest invalid UTF-8"; Cause = "encoding"; Bytes = $foreignManifestInvalidUtf8 },
		[pscustomobject]@{ Name = "foreign manifest invalid JSON"; Cause = "json"; Bytes = [Text.UTF8Encoding]::new($false).GetBytes($foreignManifestWithoutClosingBrace) },
		[pscustomobject]@{ Name = "foreign manifest invalid surrogate"; Cause = "invalid-surrogate-escape"; Bytes = [Text.UTF8Encoding]::new($false).GetBytes($foreignManifestInvalidSurrogate) }
	)
	try {
		foreach ($strictForeignManifestCase in $strictForeignManifestCases) {
			Write-TestBytes -Path $foreignManifestPath -Bytes $strictForeignManifestCase.Bytes
			$templateDashboardBefore = Get-TestFileSha256 -Path $indexPath
			$projectDashboardBefore = Get-TestFileSha256 -Path $diagnosticProjectIndexPath
			$strictForeignOutput = @(Invoke-IndexSync -Arguments @("-Check", "-Scope", "All") -ExpectedExitCode 1 -TestName $strictForeignManifestCase.Name)
			$strictForeignText = ConvertTo-TestDiagnosticLogicalText -Text ($strictForeignOutput -join "`n")
			Assert-True ($strictForeignText.Contains("namespace=template") -and $strictForeignText.Contains("category=manifest") -and $strictForeignText.Contains("cause=$($strictForeignManifestCase.Cause)")) "$($strictForeignManifestCase.Name) must retain the failing template namespace and stable cause"
			Assert-True ($strictForeignText.Contains("path='") -and $strictForeignText.Contains("does not own this template manifest") -and $strictForeignText.Contains("upstream")) "$($strictForeignManifestCase.Name) must identify the foreign manifest path and upstream recovery"
			Assert-True (-not $strictForeignText.Contains("-Scope Template")) "$($strictForeignManifestCase.Name) must not recommend forbidden template sync"
			Assert-True ((Get-TestFileSha256 -Path $indexPath) -ceq $templateDashboardBefore) "$($strictForeignManifestCase.Name) must preserve inherited template dashboard bytes"
			Assert-True ((Get-TestFileSha256 -Path $diagnosticProjectIndexPath) -ceq $projectDashboardBefore) "$($strictForeignManifestCase.Name) must preserve owned project dashboard bytes"
		}
	} finally {
		Write-TestBytes -Path $foreignManifestPath -Bytes $foreignManifestBytes
	}
	Assert-True ((Get-TestFileSha256 -Path $diagnosticProjectIndexPath) -ceq $diagnosticProjectIndexHash) "strict foreign manifest diagnostics must leave the project dashboard byte-identical"

	# AUTO-TF0008-SPEC-TEST-008 remediation: aggregate validation reached while
	# checking template first must attribute an owned project schema failure to
	# project, not to the caller dashboard namespace.
	$ownedInvalidDirectory = Join-Path $testRoot "docs\Features\project\owned-invalid-manifest"
	$ownedInvalidManifestPath = Join-Path $ownedInvalidDirectory "feature.json"
	$ownedInvalidManifest = [ordered]@{
		schemaVersion = 2
		id = "TF-9999"
		slug = "owned-invalid-manifest"
		title = "Owned invalid manifest"
		status = "planned"
		activity = "none"
		branch = $null
		baseCommit = $null
		startedAt = $null
		completedAt = $null
		updatedAt = "2026-08-05T13:28:08Z"
		blockers = @()
		artifacts = @()
		verification = $null
		recoveryLog = @()
	}
	try {
		Write-TestUtf8 -Path $ownedInvalidManifestPath -Content (($ownedInvalidManifest | ConvertTo-Json -Depth 10) + "`n")
		Write-TestUtf8 -Path (Join-Path $ownedInvalidDirectory "handoff.md") -Content "# Feature handoff`n"
		Write-TestUtf8 -Path (Join-Path $ownedInvalidDirectory "worklog.md") -Content "# Feature worklog`n"
		$ownedTemplateDashboardBefore = Get-TestFileSha256 -Path $indexPath
		$ownedProjectDashboardBefore = Get-TestFileSha256 -Path $diagnosticProjectIndexPath
		$ownedManifestOutput = @(Invoke-IndexSync -Arguments @("-Check", "-Scope", "All") -ExpectedExitCode 1 -TestName "owned project manifest attribution during all Check")
		$ownedManifestText = ConvertTo-TestDiagnosticLogicalText -Text ($ownedManifestOutput -join "`n")
		Assert-True ($ownedManifestText.Contains("namespace=project") -and $ownedManifestText.Contains("category=manifest") -and $ownedManifestText.Contains("cause=schema")) "owned project schema failure must retain the failing project namespace during all Check"
		Assert-True ($ownedManifestText.Contains("path='") -and $ownedManifestText.Contains("owning project manifest") -and $ownedManifestText.Contains("-Scope Project")) "owned project schema failure must identify its path and owning recovery"
		Assert-True (-not $ownedManifestText.Contains("namespace=template category=manifest") -and -not $ownedManifestText.Contains("upstream")) "owned project schema failure must not be relabelled as template or foreign"
		Assert-True ((Get-TestFileSha256 -Path $indexPath) -ceq $ownedTemplateDashboardBefore) "owned project schema failure must preserve template dashboard bytes"
		Assert-True ((Get-TestFileSha256 -Path $diagnosticProjectIndexPath) -ceq $ownedProjectDashboardBefore) "owned project schema failure must preserve project dashboard bytes"
	} finally {
		if (Test-Path -LiteralPath $ownedInvalidDirectory) {
			Remove-Item -LiteralPath $ownedInvalidDirectory -Recurse -Force
		}
	}

	# AUTO-TF0008-SPEC-TEST-005: inherited CRLF is logically equal and immutable.
	Write-TestUtf8 -Path $indexPath -Content $templateCanonicalText.Replace("`n", "`r`n")
	$foreignCrlfHash = Get-TestFileSha256 -Path $indexPath
	Invoke-IndexSync -Arguments @("-Check", "-Scope", "All") -ExpectedExitCode 0 -TestName "derived inherited CRLF all Check" | Out-Null
	Assert-True ((Get-TestFileSha256 -Path $indexPath) -ceq $foreignCrlfHash) "derived all Check must preserve inherited CRLF bytes"
	Write-TestBytes -Path $indexPath -Bytes $templateCanonicalBytes
	Complete-Tf0008Identity "AUTO-TF0008-SPEC-TEST-005"

	# AUTO-TF0008-SPEC-TEST-014: a missing foreign dashboard fails closed.
	Remove-Item -LiteralPath $indexPath -Force
	$missingForeignOutput = @(Invoke-IndexSync -Arguments @("-Check", "-Scope", "All") -ExpectedExitCode 1 -TestName "missing foreign template dashboard")
	Assert-True (-not (Test-Path -LiteralPath $indexPath)) "foreign Check must not recreate a missing template dashboard"
	$missingForeignText = $missingForeignOutput -join "`n"
	Assert-True ($missingForeignText.Contains("namespace=template") -and $missingForeignText.Contains("category=missing") -and $missingForeignText.Contains("upstream")) "missing foreign dashboard must report ownership-aware recovery"
	Assert-True (-not $missingForeignText.Contains("-Scope Template")) "missing foreign dashboard must not recommend forbidden template sync"
	Write-TestBytes -Path $indexPath -Bytes $templateCanonicalBytes
	Complete-Tf0008Identity "AUTO-TF0008-SPEC-TEST-014"

	# AUTO-TF0008-SPEC-TEST-008: outer-scaffold foreign drift stays immutable.
	$foreignDriftCases = @(
		[pscustomobject]@{ Name = "foreign title"; Text = $templateCanonicalText.Replace("# Фичи шаблона", "# Foreign title drift") },
		[pscustomobject]@{ Name = "foreign prose"; Text = $templateCanonicalText.Replace("Этот dashboard генерируется из", "Foreign prose drift") },
		[pscustomobject]@{ Name = "foreign namespace path"; Text = $templateCanonicalText.Replace("docs/Features/template/*/feature.json", "docs/Features/project/*/feature.json") }
	)
	foreach ($foreignDriftCase in $foreignDriftCases) {
		Write-TestUtf8 -Path $indexPath -Content $foreignDriftCase.Text
		$foreignBefore = Get-TestFileSha256 -Path $indexPath
		$foreignOutput = @(Invoke-IndexSync -Arguments @("-Check", "-Scope", "All") -ExpectedExitCode 1 -TestName $foreignDriftCase.Name)
		$foreignText = $foreignOutput -join "`n"
		Assert-True ((Get-TestFileSha256 -Path $indexPath) -ceq $foreignBefore) "$($foreignDriftCase.Name) Check must preserve exact inherited bytes"
		Assert-True ($foreignText.Contains("namespace=template") -and $foreignText.Contains("category=content") -and $foreignText.Contains("upstream")) "$($foreignDriftCase.Name) must report foreign content drift"
		Assert-True (-not $foreignText.Contains("-Scope Template")) "$($foreignDriftCase.Name) must not recommend forbidden template sync"
		Invoke-IndexSync -Arguments @("-Scope", "Project") -ExpectedExitCode 0 -TestName "$($foreignDriftCase.Name) project-only sync" | Out-Null
		Assert-True ((Get-TestFileSha256 -Path $indexPath) -ceq $foreignBefore) "$($foreignDriftCase.Name) project sync must preserve inherited bytes"
	}
	Write-TestBytes -Path $indexPath -Bytes $templateCanonicalBytes
	Complete-Tf0008Identity "AUTO-TF0008-SPEC-TEST-008"

	# AUTO-TF0008-SPEC-TEST-018 foreign subcase: invalid UTF-8 is never repaired.
	Write-TestBytes -Path $indexPath -Bytes ([byte[]]@(0xFF, 0xFE, 0x0A))
	$foreignInvalidHash = Get-TestFileSha256 -Path $indexPath
	$foreignInvalidOutput = @(Invoke-IndexSync -Arguments @("-Check", "-Scope", "All") -ExpectedExitCode 1 -TestName "foreign invalid UTF-8 dashboard")
	Assert-True (($foreignInvalidOutput -join "`n").Contains("namespace=template") -and ($foreignInvalidOutput -join "`n").Contains("category=encoding")) "foreign invalid UTF-8 dashboard must report encoding drift"
	Assert-True ((Get-TestFileSha256 -Path $indexPath) -ceq $foreignInvalidHash) "foreign invalid UTF-8 Check must preserve exact bytes"
	Invoke-IndexSync -Arguments @("-Scope", "Project") -ExpectedExitCode 0 -TestName "foreign invalid UTF-8 project-only sync" | Out-Null
	Assert-True ((Get-TestFileSha256 -Path $indexPath) -ceq $foreignInvalidHash) "project-only sync must preserve invalid foreign bytes"
	Write-TestBytes -Path $indexPath -Bytes $templateCanonicalBytes
	Complete-Tf0008Identity "AUTO-TF0008-SPEC-TEST-018"

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
	$corruptTemplateHash = Get-TestFileSha256 -Path $indexPath
	$projectCanonicalBytes = [IO.File]::ReadAllBytes($projectIndexPath)
	$projectCanonicalText = [Text.UTF8Encoding]::new($false, $true).GetString($projectCanonicalBytes)
	Write-TestUtf8 -Path $projectIndexPath -Content $projectCanonicalText.Replace("Всего: 1", "Всего: 999")
	$templateManifestBytes = [IO.File]::ReadAllBytes($firstPath)
	Write-TestBytes -Path $firstPath -Bytes ([byte[]]@(0xFF, 0xFE, 0x0A))
	Invoke-IndexSync -Arguments @("-Scope", "Project") -ExpectedExitCode 0 -TestName "project-only dashboard synchronization" | Out-Null
	Assert-True (Test-TestByteArrayEqual -Left ([IO.File]::ReadAllBytes($projectIndexPath)) -Right $projectCanonicalBytes) "project sync must repair its owned dashboard without reading an invalid inherited template manifest"
	Assert-True ((Get-Content -LiteralPath $indexPath -Raw) -ceq $corruptTemplateIndex) "project sync must leave a foreign template dashboard byte-identical"
	Assert-True ((Get-TestFileSha256 -Path $indexPath) -ceq $corruptTemplateHash) "project sync must preserve the exact inherited template SHA-256"
	Assert-True (Test-TestByteArrayEqual -Left ([IO.File]::ReadAllBytes($firstPath)) -Right ([byte[]]@(0xFF, 0xFE, 0x0A))) "project sync must not read or rewrite an invalid inherited template manifest"
	Write-TestBytes -Path $firstPath -Bytes $templateManifestBytes
	Complete-Tf0008Identity "AUTO-TF0008-SPEC-TEST-006"
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

	# AUTO-TF0008-SPEC-TEST-016 / 017: unchanged public surface and release-host source policy.
	$expectedExports = @(
		"Acquire-FeatureWriterLease", "Append-FeatureWorklog", "Assert-FeatureRecordWritable",
		"Assert-FeatureRepositoryInitialized", "Assert-FeatureWriterLease", "Assert-NoOtherFeatureOnBranch",
		"ConvertTo-FeatureSlug", "Get-CanonicalFeatureBranchName", "Get-CurrentFeatureBranch",
		"Get-FeatureHead", "Get-FeatureManifests", "Get-FeatureNamespaceRoles",
		"Get-FeatureNamespaceRoot", "Get-FeatureRepositoryRoot", "Get-FeatureRoot",
		"Get-NextFeatureId", "Get-RepositoryRole", "Invoke-FeatureGit",
		"Release-FeatureWriterLease", "Resolve-FeatureRecord", "Sync-FeatureIndex",
		"Test-FeatureManifestSet", "Write-FeatureHandoff", "Write-FeatureManifest", "Write-Utf8NoBom"
	) | Sort-Object
	$sourceModule = Import-Module (Join-Path $sourceRoot "scripts\FeatureWorkflow.psm1") -Force -PassThru
	$actualExports = @(Get-Command -Module $sourceModule.Name | Select-Object -ExpandProperty Name | Sort-Object)
	Assert-True (($actualExports -join "`n") -ceq ($expectedExports -join "`n")) "TF-0008 must preserve the exact exported command surface"
	foreach ($internalName in @("ConvertTo-FeatureDashboardBytes", "Write-FeatureDashboard", "Normalize-FeatureDashboardText")) {
		Assert-True ($internalName -notin $actualExports) "$internalName must remain non-exported"
	}
	$attributes = Get-Content -LiteralPath (Join-Path $sourceRoot ".gitattributes")
	foreach ($attributeRule in @(
		"docs/Features/template/README.md text eol=lf",
		"docs/Features/project/README.md text eol=lf"
	)) {
		Assert-True (@($attributes | Where-Object { $_ -ceq $attributeRule }).Count -eq 1) ".gitattributes must contain exact rule '$attributeRule' once"
	}
	foreach ($bomRelativePath in @("scripts\FeatureWorkflow.psm1", "scripts\tests\feature-workflow.tests.ps1")) {
		$bomBytes = [IO.File]::ReadAllBytes((Join-Path $sourceRoot $bomRelativePath))
		Assert-True ($bomBytes.Length -ge 3 -and $bomBytes[0] -eq 0xEF -and $bomBytes[1] -eq 0xBB -and $bomBytes[2] -eq 0xBF) "$bomRelativePath must be UTF-8 with BOM for dual-host source compatibility"
	}
	$currentBuild = [int](Get-ItemPropertyValue -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -Name CurrentBuildNumber)
	Assert-True ($currentBuild -ge 22000) "mandatory release execution must run on Windows 11"
	Complete-Tf0008Identity "AUTO-TF0008-SPEC-TEST-016"

	$sourceDashboardPath = Join-Path $sourceRoot "docs\Features\template\README.md"
	$sourceDashboardBefore = Get-TestFileSha256 -Path $sourceDashboardPath
	Invoke-PowerShellScriptAt -Root $sourceRoot -RelativePath "scripts\validate-feature-workflow.ps1" -Arguments @() -ExpectedExitCode 0 -TestName "source feature-workflow release gate" | Out-Null
	Invoke-PowerShellScriptAt -Root $sourceRoot -RelativePath "scripts\sync-feature-index.ps1" -Arguments @("-Check", "-Scope", "All") -ExpectedExitCode 0 -TestName "source all-namespace dashboard release gate" | Out-Null
	Invoke-PowerShellScriptAt -Root $sourceRoot -RelativePath "scripts\validate-repository-layout.ps1" -Arguments @() -ExpectedExitCode 0 -TestName "source repository-layout release gate" | Out-Null
	Assert-True ((Get-TestFileSha256 -Path $sourceDashboardPath) -ceq $sourceDashboardBefore) "repository release-gate checks must preserve the source dashboard bytes"
	$previousPreference = $ErrorActionPreference
	try {
		$ErrorActionPreference = "Continue"
		$diffOutput = @(& git -C $sourceRoot diff --check 2>&1)
		$diffExitCode = $LASTEXITCODE
	} finally {
		$ErrorActionPreference = $previousPreference
	}
	if ($diffExitCode -ne 0) {
		throw "source git diff --check exit $diffExitCode, expected 0.`n$($diffOutput -join [Environment]::NewLine)"
	}
	$rojoOutputPath = Join-Path $testRoot ("tf0008-release-gate-{0}.rbxlx" -f [Guid]::NewGuid().ToString("N"))
	try {
		$rojoCommand = Get-Command rojo.exe -ErrorAction Stop
		$previousPreference = $ErrorActionPreference
		try {
			$ErrorActionPreference = "Continue"
			$rojoOutput = @(& $rojoCommand.Source build (Join-Path $sourceRoot "default.project.json") --output $rojoOutputPath 2>&1)
			$rojoExitCode = $LASTEXITCODE
		} finally {
			$ErrorActionPreference = $previousPreference
		}
		if ($rojoExitCode -ne 0) {
			throw "source Rojo build exit $rojoExitCode, expected 0.`n$($rojoOutput -join [Environment]::NewLine)"
		}
		Assert-True ((Test-Path -LiteralPath $rojoOutputPath -PathType Leaf) -and (Get-Item -LiteralPath $rojoOutputPath).Length -gt 0) "source Rojo release-gate build must produce a non-empty temporary artifact"
	} finally {
		if (Test-Path -LiteralPath $rojoOutputPath -PathType Leaf) {
			Remove-Item -LiteralPath $rojoOutputPath -Force
		}
	}
	Complete-Tf0008Identity "AUTO-TF0008-SPEC-TEST-017"

	$expectedTf0008Identities = @(1..18 | ForEach-Object { "AUTO-TF0008-SPEC-TEST-{0:D3}" -f $_ })
	Assert-True ($passedTf0008Identities.Count -eq $expectedTf0008Identities.Count) "all 18 TF-0008 identities must execute exactly once per suite run"
	foreach ($expectedIdentity in $expectedTf0008Identities) {
		Assert-True ($passedTf0008Identities.Contains($expectedIdentity)) "$expectedIdentity must execute in the complete suite"
	}

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
	foreach ($repositoryValidationRoot in $repositoryValidationRoots) {
		if (-not (Test-Path -LiteralPath $repositoryValidationRoot -PathType Container)) { continue }
		$resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
		$resolvedValidationRoot = [IO.Path]::GetFullPath($repositoryValidationRoot)
		if (-not $resolvedValidationRoot.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase)) {
			throw "Refusing to clean unexpected repository validation path '$resolvedValidationRoot'."
		}
		Remove-Item -LiteralPath $resolvedValidationRoot -Recurse -Force
	}
}
