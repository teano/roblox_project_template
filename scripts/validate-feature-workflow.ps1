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
