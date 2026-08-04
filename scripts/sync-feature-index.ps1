param([switch]$Check)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "FeatureWorkflow.psm1") -Force -DisableNameChecking
$root = Get-FeatureRepositoryRoot
$path = Sync-FeatureIndex -RepositoryRoot $root -Check:$Check
if ($Check) {
	Write-Output "Feature dashboard is synchronized: $path"
} else {
	Write-Output "Feature dashboard updated: $path"
}
