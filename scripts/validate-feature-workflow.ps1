param([switch]$RequirePushReady)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "FeatureWorkflow.psm1") -Force -DisableNameChecking
$root = Get-FeatureRepositoryRoot
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
