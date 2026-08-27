[CmdletBinding()]
param(
	[Alias("RepositoryPath")]
	[string]$TargetRepositoryRoot,

	[ValidateSet("Auto", "Template", "Project")]
	[string]$RepositoryRole = "Auto",

	[string]$TargetRef = "refs/remotes/upstream/main"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$tool = Join-Path $PSScriptRoot "template-project.ps1"
if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) {
	throw "Repository validator is unavailable because template-project.ps1 is missing: '$tool'."
}

$root = if ([string]::IsNullOrWhiteSpace($TargetRepositoryRoot)) {
	(Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
} else {
	$TargetRepositoryRoot
}

& $tool validate -RepositoryPath $root -RepositoryRole $RepositoryRole -TargetRef $TargetRef
