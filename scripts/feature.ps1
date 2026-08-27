<#
.SYNOPSIS
Small feature bookkeeping for template and derived repositories.

.DESCRIPTION
The command has three verbs: new, status, and close. It stores one minimal
schema-v3 feature.json per feature and has no dependency on branches, leases,
dashboards, skills, FeatureWorkflow.psm1, or pipeline state.

Schema-v2 records remain readable. Closing an owning schema-v2 record performs
one safe migration: its exact original bytes are copied to feature.legacy.json
and feature.json becomes schema v3. In a derived repository only project
records are writable; inherited template history is always read-only.

.EXAMPLE
  ./scripts/feature.ps1 new -RepositoryPath D:\Games\MyGame -Title "Inventory"
  ./scripts/feature.ps1 status -RepositoryPath D:\Games\MyGame
  ./scripts/feature.ps1 close -RepositoryPath D:\Games\MyGame -Feature F-0001
#>
[CmdletBinding()]
param(
	[Parameter(Mandatory = $true, Position = 0)]
	[ValidateSet("new", "status", "close")]
	[string]$Action,

	[Parameter(Mandatory = $true)]
	[string]$RepositoryPath,

	[string]$Feature,
	[string]$Title,
	[string]$Slug
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:TemplateRepositoryPattern = '(?i)(?:^|[/:\\])roblox_project_template(?:\.git)?$'

function Invoke-FeatureGit {
	param([string]$Root, [string[]]$Arguments, [switch]$AllowFailure)
	$priorErrorAction = $ErrorActionPreference
	$ErrorActionPreference = "Continue"
	try {
		$output = @(& git -C $Root @Arguments 2>&1 | ForEach-Object { [string]$_ })
		$exitCode = $LASTEXITCODE
	} finally {
		$ErrorActionPreference = $priorErrorAction
	}
	if ($exitCode -ne 0 -and -not $AllowFailure) {
		throw "git $($Arguments -join ' ') failed in '$Root': $(($output -join ' ').Trim())"
	}
	return [PSCustomObject]@{ ExitCode = $exitCode; Output = @($output) }
}

function Resolve-FeatureRepositoryRoot {
	param([string]$Path)
	if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "RepositoryPath does not exist or is not a directory: $Path" }
	$requested = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Path).Path).TrimEnd('\', '/')
	$result = Invoke-FeatureGit -Root $requested -Arguments @("rev-parse", "--show-toplevel")
	$root = [IO.Path]::GetFullPath(([string]$result.Output[0]).Trim()).TrimEnd('\', '/')
	if (-not $root.Equals($requested, [StringComparison]::OrdinalIgnoreCase)) { throw "RepositoryPath must name the repository root exactly. Resolved root: $root" }
	return $root
}

function Get-FeatureRepositoryRole {
	param([string]$Root)
	$result = Invoke-FeatureGit -Root $Root -Arguments @("remote", "get-url", "upstream") -AllowFailure
	if ($result.ExitCode -ne 0) {
		$origin = Invoke-FeatureGit -Root $Root -Arguments @("remote", "get-url", "origin") -AllowFailure
		if ($origin.ExitCode -eq 0 -and ([string]$origin.Output[0]).Trim() -match $script:TemplateRepositoryPattern) { return "template" }
		throw "Repository ownership is ambiguous: no template upstream and origin is not the canonical roblox_project_template remote."
	}
	$url = ([string]$result.Output[0]).Trim()
	if ($url -notmatch $script:TemplateRepositoryPattern) { throw "Remote 'upstream' is unrelated to roblox_project_template; feature ownership is ambiguous: $url" }
	return "project"
}

function ConvertTo-FeatureSlug {
	param([string]$Value)
	$slugValue = $Value.Trim().ToLowerInvariant()
	$slugValue = [Text.RegularExpressions.Regex]::Replace($slugValue, '[^a-z0-9]+', '-')
	$slugValue = $slugValue.Trim('-')
	if ([string]::IsNullOrWhiteSpace($slugValue)) { throw "Title/Slug must contain at least one ASCII letter or digit." }
	return $slugValue
}

function Read-FeatureManifest {
	param([string]$Path)
	try { $manifest = [IO.File]::ReadAllText($Path) | ConvertFrom-Json } catch { throw "Feature manifest is invalid JSON: $Path. $($_.Exception.Message)" }
	$schemaProperty = $manifest.PSObject.Properties["schemaVersion"]
	if ($null -eq $schemaProperty -or [int]$schemaProperty.Value -notin @(2, 3)) { throw "Feature manifest has unsupported schemaVersion at '$Path'." }
	if ([string]::IsNullOrWhiteSpace([string]$manifest.id) -or [string]::IsNullOrWhiteSpace([string]$manifest.slug) -or [string]::IsNullOrWhiteSpace([string]$manifest.title)) {
		throw "Feature manifest is missing id, slug, or title at '$Path'."
	}
	if ([int]$manifest.schemaVersion -eq 3) {
		$allowed = @("schemaVersion", "id", "slug", "title", "state", "createdAt", "updatedAt")
		$actual = @($manifest.PSObject.Properties.Name)
		$missing = @($allowed | Where-Object { $_ -notin $actual })
		$extra = @($actual | Where-Object { $_ -notin $allowed })
		if ($missing.Count -gt 0 -or $extra.Count -gt 0) { throw "Schema-v3 feature manifest shape is invalid at '$Path'. Missing: $($missing -join ', '); extra: $($extra -join ', ')." }
		if ([string]$manifest.state -notin @("open", "done")) { throw "Schema-v3 feature state must be open or done at '$Path'." }
		foreach ($field in @("createdAt", "updatedAt")) {
			$value = [string]$manifest.$field
			$parsed = [DateTimeOffset]::MinValue
			if (-not [DateTimeOffset]::TryParse($value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) { throw "Schema-v3 feature $field is not an RFC3339 timestamp at '$Path'." }
		}
	}
	return $manifest
}

function Get-FeatureRecords {
	param([string]$Root)
	$records = @()
	foreach ($namespace in @("template", "project")) {
		$namespaceRoot = Join-Path $Root "docs/Features/$namespace"
		if (-not (Test-Path -LiteralPath $namespaceRoot -PathType Container)) { continue }
		foreach ($file in Get-ChildItem -LiteralPath $namespaceRoot -Filter "feature.json" -File -Recurse) {
			$records += [PSCustomObject]@{
				Namespace = $namespace
				Directory = $file.Directory.FullName
				Path = $file.FullName
				Manifest = Read-FeatureManifest -Path $file.FullName
			}
		}
	}
	return @($records)
}

function Get-OwningNamespace {
	param([string]$Role)
	if ($Role -eq "template") { return "template" }
	return "project"
}

function Resolve-FeatureRecord {
	param([object[]]$Records, [string]$Reference)
	if ([string]::IsNullOrWhiteSpace($Reference)) { throw "-Feature is required for close and for a single-record status query." }
	$needle = $Reference.Trim()
	$matches = @()
	if ($needle -match '^\d{4}$') {
		$matches = @($Records | Where-Object { ([string]$_.Manifest.id).EndsWith("-$needle", [StringComparison]::OrdinalIgnoreCase) })
	} else {
		$matches = @($Records | Where-Object {
			([string]$_.Manifest.id).Equals($needle, [StringComparison]::OrdinalIgnoreCase) -or
			([string]$_.Manifest.slug).Equals($needle, [StringComparison]::OrdinalIgnoreCase) -or
			([string]$_.Manifest.title).Equals($needle, [StringComparison]::OrdinalIgnoreCase)
		})
	}
	if ($matches.Count -eq 0) { throw "Unknown feature '$Reference'." }
	if ($matches.Count -gt 1) { throw "Feature '$Reference' is ambiguous: $(@($matches | ForEach-Object { $_.Manifest.id } | Sort-Object) -join ', '). Use the full ID." }
	return $matches[0]
}

function Get-FeatureState {
	param($Manifest)
	if ([int]$Manifest.schemaVersion -eq 3) { return [string]$Manifest.state }
	if ([string]$Manifest.status -eq "ready") { return "done" }
	return "open"
}

function Write-FeatureJson {
	param([string]$Path, $Manifest)
	$content = (($Manifest | ConvertTo-Json -Depth 10) -replace "`r`n", "`n").TrimEnd() + "`n"
	$temp = "$Path.tmp-$([Guid]::NewGuid().ToString('N'))"
	try {
		[IO.File]::WriteAllText($temp, $content, $script:Utf8NoBom)
		Move-Item -LiteralPath $temp -Destination $Path -Force
	} finally {
		if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
	}
}

function Test-BytesEqual {
	param([byte[]]$Left, [byte[]]$Right)
	if ($Left.Length -ne $Right.Length) { return $false }
	for ($index = 0; $index -lt $Left.Length; $index += 1) {
		if ($Left[$index] -ne $Right[$index]) { return $false }
	}
	return $true
}

function Complete-LegacyMigration {
	param($Record)
	if ([int]$Record.Manifest.schemaVersion -ne 2) { return $Record.Manifest }
	$backup = Join-Path $Record.Directory "feature.legacy.json"
	$createdAt = [string]$Record.Manifest.startedAt
	$parsed = [DateTimeOffset]::MinValue
	if ([string]::IsNullOrWhiteSpace($createdAt) -or -not [DateTimeOffset]::TryParse($createdAt, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) {
		throw "Legacy feature '$($Record.Manifest.id)' has no valid startedAt. Repair the timestamp before migration; no sidecar or replacement was written."
	}
	$original = [IO.File]::ReadAllBytes($Record.Path)
	$backupExists = Test-Path -LiteralPath $backup -PathType Leaf
	if ($backupExists -and -not (Test-BytesEqual -Left ([IO.File]::ReadAllBytes($backup)) -Right $original)) {
		throw "Legacy migration sidecar exists but does not match the current schema-v2 feature.json exactly: $backup"
	}
	$now = [DateTimeOffset]::UtcNow.ToString("o")
	$replacement = [PSCustomObject][ordered]@{
		schemaVersion = 3
		id = [string]$Record.Manifest.id
		slug = [string]$Record.Manifest.slug
		title = [string]$Record.Manifest.title
		state = "done"
		createdAt = $parsed.ToUniversalTime().ToString("o")
		updatedAt = $now
	}
	$replacementText = (($replacement | ConvertTo-Json -Depth 10) -replace "`r`n", "`n").TrimEnd() + "`n"
	$token = [Guid]::NewGuid().ToString("N")
	$backupTemp = Join-Path $Record.Directory "feature.legacy.json.tmp-$token"
	$manifestTemp = Join-Path $Record.Directory "feature.json.tmp-$token"
	try {
		if (-not $backupExists) { [IO.File]::WriteAllBytes($backupTemp, $original) }
		[IO.File]::WriteAllText($manifestTemp, $replacementText, $script:Utf8NoBom)
		if (-not $backupExists) { Move-Item -LiteralPath $backupTemp -Destination $backup }
		Move-Item -LiteralPath $manifestTemp -Destination $Record.Path -Force
	} finally {
		foreach ($temp in @($backupTemp, $manifestTemp)) { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force } }
	}
	return $replacement
}

function Set-ClosedHandoff {
	param($Record)
	$handoff = Join-Path $Record.Directory "handoff.md"
	$archive = Join-Path $Record.Directory "handoff.legacy.md"
	if (Test-Path -LiteralPath $handoff -PathType Leaf) {
		$current = [IO.File]::ReadAllBytes($handoff)
		$currentText = [IO.File]::ReadAllText($handoff)
		if ($currentText.StartsWith("# $($Record.Manifest.id) closed", [StringComparison]::Ordinal)) { return }
		if (Test-Path -LiteralPath $archive -PathType Leaf) {
			$archived = [IO.File]::ReadAllBytes($archive)
			if (-not (Test-BytesEqual -Left $archived -Right $current)) {
				throw "Cannot preserve handoff.md because handoff.legacy.md already contains different bytes: $archive"
			}
		} else {
			[IO.File]::WriteAllBytes($archive, $current)
		}
	}
	$content = "# $($Record.Manifest.id) closed`n`nState: done.`n`nThis bookkeeping record does not assert release or verification evidence. Historical handoff content is preserved in handoff.legacy.md when one existed.`n"
	$temp = "$handoff.tmp-$([Guid]::NewGuid().ToString('N'))"
	try {
		[IO.File]::WriteAllText($temp, $content, $script:Utf8NoBom)
		Move-Item -LiteralPath $temp -Destination $handoff -Force
	} finally {
		if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
	}
}

function Assert-HandoffCanClose {
	param($Record)
	$handoff = Join-Path $Record.Directory "handoff.md"
	$archive = Join-Path $Record.Directory "handoff.legacy.md"
	if (-not (Test-Path -LiteralPath $handoff -PathType Leaf) -or -not (Test-Path -LiteralPath $archive -PathType Leaf)) { return }
	$currentText = [IO.File]::ReadAllText($handoff)
	if ($currentText.StartsWith("# $($Record.Manifest.id) closed", [StringComparison]::Ordinal)) { return }
	if (-not (Test-BytesEqual -Left ([IO.File]::ReadAllBytes($handoff)) -Right ([IO.File]::ReadAllBytes($archive)))) {
		throw "Cannot close feature because handoff.legacy.md already contains different bytes: $archive"
	}
}

$root = Resolve-FeatureRepositoryRoot -Path $RepositoryPath
$role = Get-FeatureRepositoryRole -Root $root
$owningNamespace = Get-OwningNamespace -Role $role
$owningRoot = Join-Path $root "docs/Features/$owningNamespace"
$records = @(Get-FeatureRecords -Root $root)
$verb = $Action.ToLowerInvariant()

if ($verb -eq "status") {
	$selected = if ([string]::IsNullOrWhiteSpace($Feature)) { @($records) } else { @(Resolve-FeatureRecord -Records $records -Reference $Feature) }
	foreach ($record in @($selected | Sort-Object @{ Expression = { [string]$_.Manifest.id } })) {
		$access = if ($record.Namespace -eq $owningNamespace) { "writable" } else { "read-only" }
		Write-Output "$($record.Manifest.id) state=$(Get-FeatureState $record.Manifest) schema=$($record.Manifest.schemaVersion) namespace=$($record.Namespace) access=$access title=$($record.Manifest.title)"
	}
	exit 0
}

if (-not (Test-Path -LiteralPath $owningRoot -PathType Container)) {
	if ($verb -eq "new") {
		[IO.Directory]::CreateDirectory($owningRoot) | Out-Null
	} else {
		throw "Owning feature namespace is missing: $owningRoot. There is no owning feature to close."
	}
}

if ($verb -eq "new") {
	if ([string]::IsNullOrWhiteSpace($Title)) { throw "new requires -Title." }
	$resolvedSlug = if ([string]::IsNullOrWhiteSpace($Slug)) { ConvertTo-FeatureSlug $Title } else { ConvertTo-FeatureSlug $Slug }
	if (@($records | Where-Object { $_.Namespace -eq $owningNamespace -and ([string]$_.Manifest.slug).Equals($resolvedSlug, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) {
		throw "Feature slug '$resolvedSlug' already exists in the owning namespace."
	}
	$prefix = if ($owningNamespace -eq "template") { "TF" } else { "F" }
	$numbers = @($records | Where-Object { $_.Namespace -eq $owningNamespace -and [string]$_.Manifest.id -match "^$prefix-(\d{4})$" } | ForEach-Object { [int]([Text.RegularExpressions.Regex]::Match([string]$_.Manifest.id, '(\d{4})$').Groups[1].Value) })
	$next = if ($numbers.Count -eq 0) { 1 } else { ([Linq.Enumerable]::Max([int[]]$numbers) + 1) }
	if ($next -gt 9999) { throw "Feature ID space for '$prefix' is exhausted." }
	$id = "{0}-{1:D4}" -f $prefix, $next
	$directory = Join-Path $owningRoot $resolvedSlug
	if (Test-Path -LiteralPath $directory) { throw "Feature directory already exists: $directory" }
	[IO.Directory]::CreateDirectory($directory) | Out-Null
	$now = [DateTimeOffset]::UtcNow.ToString("o")
	$manifest = [PSCustomObject][ordered]@{
		schemaVersion = 3
		id = $id
		slug = $resolvedSlug
		title = $Title.Trim()
		state = "open"
		createdAt = $now
		updatedAt = $now
	}
	Write-FeatureJson -Path (Join-Path $directory "feature.json") -Manifest $manifest
	Write-Output "CREATED $id state=open namespace=$owningNamespace path=$(Join-Path $directory 'feature.json')"
	exit 0
}

if ([string]::IsNullOrWhiteSpace($Feature)) { throw "close requires -Feature." }
$record = Resolve-FeatureRecord -Records $records -Reference $Feature
if ($record.Namespace -ne $owningNamespace) {
	throw "Feature '$($record.Manifest.id)' belongs to the read-only '$($record.Namespace)' namespace; this '$role' repository may close only '$owningNamespace' features."
}
$manifest = $record.Manifest
$wasLegacy = [int]$manifest.schemaVersion -eq 2
if ($wasLegacy) {
	$legacyCreatedAt = [string]$manifest.startedAt
	$legacyParsed = [DateTimeOffset]::MinValue
	if ([string]::IsNullOrWhiteSpace($legacyCreatedAt) -or -not [DateTimeOffset]::TryParse($legacyCreatedAt, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$legacyParsed)) {
		throw "Legacy feature '$($manifest.id)' has no valid startedAt. Repair the timestamp before migration; no sidecar, handoff, or replacement was written."
	}
}
Assert-HandoffCanClose -Record $record
if ([int]$manifest.schemaVersion -eq 2) {
	$manifest = Complete-LegacyMigration -Record $record
}
if ([string]$manifest.state -eq "done") {
	Set-ClosedHandoff -Record $record
	Write-Output "$(if ($wasLegacy) { 'MIGRATED AND CLOSED' } else { 'ALREADY CLOSED' }) $($manifest.id) namespace=$owningNamespace"
	exit 0
}
$manifest.state = "done"
$manifest.updatedAt = [DateTimeOffset]::UtcNow.ToString("o")
Write-FeatureJson -Path $record.Path -Manifest $manifest
Set-ClosedHandoff -Record $record
Write-Output "CLOSED $($manifest.id) namespace=$owningNamespace. This is bookkeeping only; it does not assert release or verification evidence."
