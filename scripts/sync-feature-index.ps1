param(
	[switch]$Check,
	[ValidateSet("Default", "Writable", "All", "Template", "Project")]
	[string]$Scope = "Default"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "FeatureWorkflow.psm1") -Force -DisableNameChecking
$root = Get-FeatureRepositoryRoot
$repositoryRole = Get-RepositoryRole -RepositoryRoot $root
$resolvedScope = if ($Scope -eq "Default") {
	if ($Check) { "All" } else { "Writable" }
} else {
	$Scope
}
$namespaceRoles = switch ($resolvedScope) {
	"Writable" { @($repositoryRole) }
	"All" { @(Get-FeatureNamespaceRoles -RepositoryRoot $root) }
	"Template" { @("template") }
	"Project" { @("project") }
}
foreach ($namespaceRole in $namespaceRoles) {
	$path = Sync-FeatureIndex `
		-RepositoryRoot $root `
		-NamespaceRole ($namespaceRole.ToLowerInvariant()) `
		-Check:$Check
	if ($Check) {
		Write-Output "Feature dashboard is synchronized: $path"
	} else {
		Write-Output "Feature dashboard updated: $path"
	}
}
