param([switch]$RequirePushReady)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "FeatureWorkflow.psm1") -Force -DisableNameChecking
$root = Get-FeatureRepositoryRoot
$skillFailures = [Collections.Generic.List[string]]::new()
$authorizationPattern = '(?s)Only\s+an\s+explicit\s+request\s+in\s+the\s+current\s+user\s+message\s+authorizes\s+this\s+lifecycle\s+transition\.'
foreach ($skillName in @("feature-start", "feature-continue", "feature-pause", "feature-finish")) {
	$skillDirectory = Join-Path $root ".agents/skills/$skillName"
	$skillPath = Join-Path $skillDirectory "SKILL.md"
	$metadataPath = Join-Path $skillDirectory "agents/openai.yaml"
	if (-not (Test-Path -LiteralPath $skillPath -PathType Leaf)) {
		$skillFailures.Add("Missing lifecycle skill contract: $skillPath")
		continue
	}
	$skillContent = Get-Content -LiteralPath $skillPath -Raw
	if (-not $skillContent.Contains("## User authorization gate")) {
		$skillFailures.Add("$skillName must contain a User authorization gate section.")
	}
	if (-not [regex]::IsMatch($skillContent, $authorizationPattern)) {
		$skillFailures.Add("$skillName must reserve lifecycle transitions for an explicit request in the current user message.")
	}
	if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
		$skillFailures.Add("Missing lifecycle skill metadata: $metadataPath")
		continue
	}
	$metadataContent = Get-Content -LiteralPath $metadataPath -Raw
	if (-not [regex]::IsMatch($metadataContent, '(?m)^\s*allow_implicit_invocation:\s*false\s*$')) {
		$skillFailures.Add("$skillName must keep policy.allow_implicit_invocation false.")
	}
}
$continueSkillContent = ""
$continueSkillPath = Join-Path $root ".agents/skills/feature-continue/SKILL.md"
if (Test-Path -LiteralPath $continueSkillPath -PathType Leaf) {
	$continueSkillContent = Get-Content -LiteralPath $continueSkillPath -Raw
	foreach ($contract in @(
		[PSCustomObject]@{ Text = "## Continue-only context boundary"; Error = "feature-continue must contain the Continue-only context boundary section." },
		[PSCustomObject]@{ Text = "Continue-only context: read only feature.json and handoff.md as feature-specific recovery context."; Error = "feature-continue must limit feature-specific recovery context to feature.json and handoff.md." },
		[PSCustomObject]@{ Text = "## Continue-only terminal fence"; Error = "feature-continue must contain the Continue-only terminal fence section." },
		[PSCustomObject]@{ Text = "Continue-only terminal fence: after the recovery report, end the turn without executing the recorded next step."; Error = "feature-continue must end the turn without executing the recorded next step." },
		[PSCustomObject]@{ Text = "Continue-only forbidden work: do not implement, review, audit, run a pipeline, edit source, run tests or validators, run Rojo or Studio, or create or use subagents."; Error = "feature-continue must forbid work, checks, Rojo/Studio, and subagents in Continue-only turns." }
	)) {
		if (-not $continueSkillContent.Contains($contract.Text)) { $skillFailures.Add($contract.Error) }
	}
}
$pauseSkillContent = ""
$pauseSkillPath = Join-Path $root ".agents/skills/feature-pause/SKILL.md"
if (Test-Path -LiteralPath $pauseSkillPath -PathType Leaf) {
	$pauseSkillContent = Get-Content -LiteralPath $pauseSkillPath -Raw
	foreach ($contract in @(
		[PSCustomObject]@{ Text = "## Pause-only factual checkpoint boundary"; Error = "feature-pause must contain the Pause-only factual checkpoint boundary section." },
		[PSCustomObject]@{ Text = "Pause-only factual checkpoint: use only facts already known before Pause; do not create new verification evidence, run new work or checks, or create or use subagents."; Error = "feature-pause must remain factual-only and non-delegated." },
		[PSCustomObject]@{ Text = "Pause-only post-command boundary: after successful Pause, report the command result without new reads or checks."; Error = "feature-pause must not perform post-command reads or checks." }
	)) {
		if (-not $pauseSkillContent.Contains($contract.Text)) { $skillFailures.Add($contract.Error) }
	}
}
foreach ($forbiddenSkillText in @(
	[PSCustomObject]@{ Skill = "feature-continue"; Content = $continueSkillContent; Text = "Reconstruct context in this bounded order:"; Error = "feature-continue retains the obsolete heavy-context recovery sequence." },
	[PSCustomObject]@{ Skill = "feature-continue"; Content = $continueSkillContent; Text = 'Git commits and staged, unstaged, and untracked changes from `baseCommit`'; Error = "feature-continue retains the obsolete Git recovery inventory." },
	[PSCustomObject]@{ Skill = "feature-pause"; Content = $pauseSkillContent; Text = "Inspect Git status and prepare a self-contained checkpoint"; Error = "feature-pause must not inspect Git to prepare its checkpoint." },
	[PSCustomObject]@{ Skill = "feature-pause"; Content = $pauseSkillContent; Text = 'Verify that the manifest is `in_progress/paused`'; Error = "feature-pause must not reread artifacts to verify successful Pause." },
	[PSCustomObject]@{ Skill = "feature-pause"; Content = $pauseSkillContent; Text = "the worklog and handoff contain every checkpoint section"; Error = "feature-pause must not reread full checkpoint artifacts after Pause." }
)) {
	if ($forbiddenSkillText.Content.Contains($forbiddenSkillText.Text)) { $skillFailures.Add($forbiddenSkillText.Error) }
}
if ($skillFailures.Count -gt 0) {
	foreach ($failure in $skillFailures) { Write-Error $failure -ErrorAction Continue }
	exit 1
}

$validation = Test-FeatureManifestSet -RepositoryRoot $root
if (-not $validation.Ok) {
	foreach ($failure in $validation.Errors) { Write-Error $failure -ErrorAction Continue }
	exit 1
}

try {
	foreach ($namespaceRole in Get-FeatureNamespaceRoles -RepositoryRoot $root) {
		Sync-FeatureIndex -RepositoryRoot $root -NamespaceRole $namespaceRole -Check | Out-Null
	}
} catch {
	Write-Error $_.Exception.Message
	exit 1
}

if ($RequirePushReady) {
	$branch = Get-CurrentFeatureBranch -RepositoryRoot $root
	$unfinished = @(
		$validation.Records | Where-Object {
			$_.Manifest.status -eq "in_progress" -and
			([string]$_.Manifest.branch).Equals($branch, [StringComparison]::Ordinal)
		}
	)
	if ($unfinished.Count -gt 0) {
		foreach ($record in $unfinished) {
			Write-Error "Push blocked: $($record.Manifest.id) '$($record.Manifest.title)' is still in progress on '$branch'." -ErrorAction Continue
		}
		exit 1
	}
}

Write-Output "Feature workflow validation passed."
