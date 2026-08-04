Set-StrictMode -Version Latest

$script:SchemaVersion = 1
$script:FeatureRootRelative = "docs/Features"
$script:IndexBegin = "<!-- feature-index:begin -->"
$script:IndexEnd = "<!-- feature-index:end -->"

function Get-FeatureRepositoryRoot {
	$root = (& git -C $PSScriptRoot rev-parse --show-toplevel 2>$null)
	if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($root)) {
		throw "Feature workflow requires a Git repository."
	}
	return $root.Trim()
}

function Invoke-FeatureGit {
	param(
		[Parameter(Mandatory = $true)][string]$RepositoryRoot,
		[Parameter(Mandatory = $true)][string[]]$Arguments,
		[switch]$AllowFailure
	)

	$output = @(& git -C $RepositoryRoot @Arguments 2>&1)
	$exitCode = $LASTEXITCODE
	if (-not $AllowFailure -and $exitCode -ne 0) {
		throw "git $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)"
	}
	return [PSCustomObject]@{
		ExitCode = $exitCode
		Output = $output
	}
}

function Write-Utf8NoBom {
	param(
		[Parameter(Mandatory = $true)][string]$Path,
		[Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content
	)

	$directory = Split-Path -Parent $Path
	if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
		New-Item -ItemType Directory -Path $directory -Force | Out-Null
	}
	$tempPath = Join-Path $directory (".{0}.{1}.tmp" -f (Split-Path -Leaf $Path), [Guid]::NewGuid().ToString("N"))
	try {
		[IO.File]::WriteAllText($tempPath, $Content, [Text.UTF8Encoding]::new($false))
		Move-Item -LiteralPath $tempPath -Destination $Path -Force
	} finally {
		if (Test-Path -LiteralPath $tempPath) {
			Remove-Item -LiteralPath $tempPath -Force
		}
	}
}

function Get-FeatureRoot {
	param([Parameter(Mandatory = $true)][string]$RepositoryRoot)
	return Join-Path $RepositoryRoot $script:FeatureRootRelative
}

function Get-FeatureManifests {
	param([Parameter(Mandatory = $true)][string]$RepositoryRoot)

	$featureRoot = Get-FeatureRoot -RepositoryRoot $RepositoryRoot
	if (-not (Test-Path -LiteralPath $featureRoot -PathType Container)) {
		return @()
	}

	return @(
		Get-ChildItem -LiteralPath $featureRoot -Directory |
			ForEach-Object {
				$manifestPath = Join-Path $_.FullName "feature.json"
				if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
					$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
					[PSCustomObject]@{
						Directory = $_.FullName
						Folder = $_.Name
						Path = $manifestPath
						Manifest = $manifest
					}
				}
			}
	)
}

function Write-FeatureManifest {
	param(
		[Parameter(Mandatory = $true)][string]$Path,
		[Parameter(Mandatory = $true)]$Manifest
	)

	$json = $Manifest | ConvertTo-Json -Depth 20
	Write-Utf8NoBom -Path $Path -Content ($json + [Environment]::NewLine)
}

function ConvertTo-FeatureSlug {
	param([Parameter(Mandatory = $true)][string]$Value)
	$slug = $Value.Trim().ToLowerInvariant()
	$slug = [regex]::Replace($slug, '[^a-z0-9]+', '-')
	$slug = $slug.Trim('-')
	if ([string]::IsNullOrWhiteSpace($slug)) {
		throw "Feature slug must contain ASCII letters or digits. Pass -Slug explicitly."
	}
	return $slug
}

function Get-RepositoryRole {
	param([Parameter(Mandatory = $true)][string]$RepositoryRoot)
	$remotes = (Invoke-FeatureGit -RepositoryRoot $RepositoryRoot -Arguments @("remote")).Output
	if ($remotes -contains "upstream") {
		return "project"
	}
	return "template"
}

function Get-NextFeatureId {
	param(
		[Parameter(Mandatory = $true)][string]$RepositoryRoot,
		[Parameter(Mandatory = $true)][ValidateSet("template", "project")][string]$Role
	)

	$prefix = if ($Role -eq "template") { "TF" } else { "PF" }
	$maximum = 0
	foreach ($record in Get-FeatureManifests -RepositoryRoot $RepositoryRoot) {
		$id = [string]$record.Manifest.id
		if ($id -match ("^{0}-(\d{{4}})$" -f $prefix)) {
			$number = [int]$Matches[1]
			if ($number -gt $maximum) { $maximum = $number }
		}
	}
	return ("{0}-{1:D4}" -f $prefix, ($maximum + 1))
}

function Resolve-FeatureRecord {
	param(
		[Parameter(Mandatory = $true)][string]$RepositoryRoot,
		[Parameter(Mandatory = $true)][string]$Feature
	)

	$needle = $Feature.Trim()
	$matches = @(
		Get-FeatureManifests -RepositoryRoot $RepositoryRoot |
			Where-Object {
				$manifest = $_.Manifest
				([string]$manifest.id).Equals($needle, [StringComparison]::OrdinalIgnoreCase) -or
				([string]$manifest.slug).Equals($needle, [StringComparison]::OrdinalIgnoreCase) -or
				([string]$manifest.title).Equals($needle, [StringComparison]::OrdinalIgnoreCase) -or
				$_.Folder.Equals($needle, [StringComparison]::OrdinalIgnoreCase)
			}
	)
	if ($matches.Count -gt 1) {
		throw "Feature '$Feature' is ambiguous. Use its stable ID."
	}
	if ($matches.Count -eq 0) {
		return $null
	}
	return $matches[0]
}

function Get-CurrentFeatureBranch {
	param([Parameter(Mandatory = $true)][string]$RepositoryRoot)
	$result = Invoke-FeatureGit -RepositoryRoot $RepositoryRoot -Arguments @("symbolic-ref", "--quiet", "--short", "HEAD") -AllowFailure
	if ($result.ExitCode -ne 0 -or $result.Output.Count -eq 0) {
		throw "Feature work requires a named branch; detached HEAD is not supported."
	}
	return ([string]$result.Output[0]).Trim()
}

function Get-FeatureHead {
	param([Parameter(Mandatory = $true)][string]$RepositoryRoot)
	return ([string](Invoke-FeatureGit -RepositoryRoot $RepositoryRoot -Arguments @("rev-parse", "HEAD")).Output[0]).Trim()
}

function Get-FeatureGitCommonDirectory {
	param([Parameter(Mandatory = $true)][string]$RepositoryRoot)
	$path = ([string](Invoke-FeatureGit -RepositoryRoot $RepositoryRoot -Arguments @("rev-parse", "--git-common-dir")).Output[0]).Trim()
	if (-not [IO.Path]::IsPathRooted($path)) {
		$path = Join-Path $RepositoryRoot $path
	}
	return [IO.Path]::GetFullPath($path)
}

function Get-BranchLockPath {
	param(
		[Parameter(Mandatory = $true)][string]$RepositoryRoot,
		[Parameter(Mandatory = $true)][string]$Branch
	)
	$bytes = [Text.Encoding]::UTF8.GetBytes($Branch)
	$sha = [Security.Cryptography.SHA256]::Create()
	try {
		$hash = ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant()
	} finally {
		$sha.Dispose()
	}
	$common = Get-FeatureGitCommonDirectory -RepositoryRoot $RepositoryRoot
	return Join-Path (Join-Path $common "codex-feature-workflow/locks") ("$hash.lock")
}

function Acquire-FeatureWriterLease {
	param(
		[Parameter(Mandatory = $true)][string]$RepositoryRoot,
		[Parameter(Mandatory = $true)][string]$Branch,
		[Parameter(Mandatory = $true)][string]$FeatureId,
		[Parameter(Mandatory = $true)][string]$SessionId
	)

	$lockPath = Get-BranchLockPath -RepositoryRoot $RepositoryRoot -Branch $Branch
	$parent = Split-Path -Parent $lockPath
	New-Item -ItemType Directory -Path $parent -Force | Out-Null
	try {
		New-Item -ItemType Directory -Path $lockPath -ErrorAction Stop | Out-Null
	} catch {
		$leasePath = Join-Path $lockPath "lease.json"
		if (Test-Path -LiteralPath $leasePath -PathType Leaf) {
			$lease = Get-Content -LiteralPath $leasePath -Raw | ConvertFrom-Json
			if (
				([string]$lease.featureId).Equals($FeatureId, [StringComparison]::Ordinal) -and
				([string]$lease.sessionId).Equals($SessionId, [StringComparison]::Ordinal)
			) {
				return $lockPath
			}
			throw "Branch '$Branch' already has writer '$($lease.sessionId)' for feature '$($lease.featureId)'."
		}
		throw "Branch '$Branch' has an unreadable feature writer lease at '$lockPath'."
	}

	$lease = [ordered]@{
		schemaVersion = 1
		branch = $Branch
		featureId = $FeatureId
		sessionId = $SessionId
		createdAt = [DateTimeOffset]::UtcNow.ToString("o")
	}
	Write-Utf8NoBom -Path (Join-Path $lockPath "lease.json") -Content (($lease | ConvertTo-Json -Depth 5) + [Environment]::NewLine)
	return $lockPath
}

function Release-FeatureWriterLease {
	param(
		[Parameter(Mandatory = $true)][string]$RepositoryRoot,
		[Parameter(Mandatory = $true)][string]$Branch,
		[Parameter(Mandatory = $true)][string]$FeatureId,
		[Parameter(Mandatory = $true)][string]$SessionId
	)

	$lockPath = Get-BranchLockPath -RepositoryRoot $RepositoryRoot -Branch $Branch
	if (-not (Test-Path -LiteralPath $lockPath -PathType Container)) { return }
	$leasePath = Join-Path $lockPath "lease.json"
	if (-not (Test-Path -LiteralPath $leasePath -PathType Leaf)) {
		throw "Cannot release unreadable feature writer lease '$lockPath'."
	}
	$lease = Get-Content -LiteralPath $leasePath -Raw | ConvertFrom-Json
	if (
		-not ([string]$lease.featureId).Equals($FeatureId, [StringComparison]::Ordinal) -or
		-not ([string]$lease.sessionId).Equals($SessionId, [StringComparison]::Ordinal)
	) {
		throw "Session '$SessionId' does not own the writer lease for '$Branch'."
	}
	Remove-Item -LiteralPath $lockPath -Recurse -Force
}

function Assert-NoOtherFeatureOnBranch {
	param(
		[Parameter(Mandatory = $true)][string]$RepositoryRoot,
		[Parameter(Mandatory = $true)][string]$Branch,
		[string]$ExceptId
	)

	$conflicts = @(
		Get-FeatureManifests -RepositoryRoot $RepositoryRoot |
			Where-Object {
				$manifest = $_.Manifest
				$manifest.status -eq "in_progress" -and
				([string]$manifest.branch).Equals($Branch, [StringComparison]::Ordinal) -and
				([string]$manifest.id) -ne $ExceptId
			}
	)
	if ($conflicts.Count -gt 0) {
		$descriptions = $conflicts | ForEach-Object { "$($_.Manifest.id) $($_.Manifest.title)" }
		throw "Branch '$Branch' is reserved by another in-progress feature: $($descriptions -join ', ')."
	}
}

function Add-FeatureSession {
	param(
		[Parameter(Mandatory = $true)]$Manifest,
		[Parameter(Mandatory = $true)][string]$SessionId,
		[Parameter(Mandatory = $true)][string]$Role,
		[Parameter(Mandatory = $true)][string]$Head
	)

	$sessions = @($Manifest.sessions)
	$existing = @($sessions | Where-Object { $_.threadId -eq $SessionId })
	if ($existing.Count -gt 0) {
		$session = $existing[0]
		$session.outcome = "active"
		$session.endedAt = $null
		$session.endCommit = $null
		return
	}
	$sessions += [PSCustomObject][ordered]@{
		threadId = $SessionId
		hostId = "local"
		role = $Role
		startedAt = [DateTimeOffset]::UtcNow.ToString("o")
		endedAt = $null
		startCommit = $Head
		endCommit = $null
		outcome = "active"
		summary = $null
	}
	$Manifest.sessions = @($sessions)
}

function Close-FeatureSession {
	param(
		[Parameter(Mandatory = $true)]$Manifest,
		[Parameter(Mandatory = $true)][string]$SessionId,
		[Parameter(Mandatory = $true)][ValidateSet("paused", "completed")][string]$Outcome,
		[Parameter(Mandatory = $true)][string]$Head,
		[Parameter(Mandatory = $true)][string]$Summary
	)
	$session = @($Manifest.sessions | Where-Object { $_.threadId -eq $SessionId }) | Select-Object -First 1
	if ($null -eq $session) {
		throw "Active session '$SessionId' is missing from the manifest."
	}
	$session.outcome = $Outcome
	$session.endedAt = [DateTimeOffset]::UtcNow.ToString("o")
	$session.endCommit = $Head
	$session.summary = $Summary
}

function Write-FeatureHandoff {
	param(
		[Parameter(Mandatory = $true)][string]$Directory,
		[Parameter(Mandatory = $true)]$Manifest,
		[Parameter(Mandatory = $true)][string]$SessionId,
		[Parameter(Mandatory = $true)][string]$Head,
		[Parameter(Mandatory = $true)][string]$Summary,
		[Parameter(Mandatory = $true)][AllowEmptyString()][string]$NextStep
	)
	$content = @"
# Feature handoff

- Feature: `$($Manifest.id) $($Manifest.title)`
- Status: `$($Manifest.status) / $($Manifest.activity)`
- Session: `$SessionId`
- Head: `$Head`
- Updated: $([DateTimeOffset]::UtcNow.ToString("o"))

## Summary

$Summary

## Next confirmed step

$(if ([string]::IsNullOrWhiteSpace($NextStep)) { "None." } else { $NextStep })
"@
	Write-Utf8NoBom -Path (Join-Path $Directory "handoff.md") -Content ($content.TrimEnd() + [Environment]::NewLine)
}

function Append-FeatureWorklog {
	param(
		[Parameter(Mandatory = $true)][string]$Directory,
		[Parameter(Mandatory = $true)]$Manifest,
		[Parameter(Mandatory = $true)][string]$SessionId,
		[Parameter(Mandatory = $true)][string]$Action,
		[Parameter(Mandatory = $true)][string]$Head,
		[Parameter(Mandatory = $true)][string]$Summary
	)
	$path = Join-Path $Directory "worklog.md"
	if (Test-Path -LiteralPath $path -PathType Leaf) {
		$content = Get-Content -LiteralPath $path -Raw
	} else {
		$content = "# Feature worklog`r`n"
	}
	$entry = @"

## $([DateTimeOffset]::UtcNow.ToString("o")) — $Action

- Feature: `$($Manifest.id)`
- Session: `$SessionId`
- Head: `$Head`

$Summary
"@
	Write-Utf8NoBom -Path $path -Content ($content.TrimEnd() + [Environment]::NewLine + $entry.TrimEnd() + [Environment]::NewLine)
}

function Test-FeatureManifestSet {
	param([Parameter(Mandatory = $true)][string]$RepositoryRoot)

	$errors = [Collections.Generic.List[string]]::new()
	$records = @(Get-FeatureManifests -RepositoryRoot $RepositoryRoot)
	$ids = @{}
	$slugs = @{}
	$branches = @{}
	foreach ($record in $records) {
		$m = $record.Manifest
		$label = $record.Path
		if ($m.schemaVersion -ne $script:SchemaVersion) { $errors.Add("$label has unsupported schemaVersion.") }
		if (-not ([string]$m.id -match '^(TF|PF)-\d{4}$')) { $errors.Add("$label has invalid id.") }
		if ([string]::IsNullOrWhiteSpace([string]$m.title)) { $errors.Add("$label has empty title.") }
		if (-not ([string]$m.slug -match '^[a-z0-9]+(?:-[a-z0-9]+)*$')) { $errors.Add("$label has invalid slug.") }
		if ([string]$m.status -notin @("planned", "in_progress", "ready")) { $errors.Add("$label has invalid status.") }
		if ([string]$m.activity -notin @("none", "active", "paused")) { $errors.Add("$label has invalid activity.") }
		if ($ids.ContainsKey([string]$m.id)) { $errors.Add("Duplicate feature id '$($m.id)'.") } else { $ids[[string]$m.id] = $true }
		if ($slugs.ContainsKey([string]$m.slug)) { $errors.Add("Duplicate feature slug '$($m.slug)'.") } else { $slugs[[string]$m.slug] = $true }

		if ($m.status -eq "planned") {
			if ($m.activity -ne "none") { $errors.Add("Planned feature '$($m.id)' must have activity none.") }
			if ($null -ne $m.activeSessionId) { $errors.Add("Planned feature '$($m.id)' cannot have an active session.") }
		}
		if ($m.status -eq "in_progress") {
			if ([string]::IsNullOrWhiteSpace([string]$m.branch)) { $errors.Add("In-progress feature '$($m.id)' needs a branch.") }
			if (-not ([string]$m.baseCommit -match '^[0-9a-f]{40}$')) { $errors.Add("In-progress feature '$($m.id)' needs a full base commit.") }
			if ($m.activity -eq "active" -and [string]::IsNullOrWhiteSpace([string]$m.activeSessionId)) { $errors.Add("Active feature '$($m.id)' needs activeSessionId.") }
			if ($m.activity -eq "paused" -and $null -ne $m.activeSessionId) { $errors.Add("Paused feature '$($m.id)' cannot have activeSessionId.") }
			$branchKey = [string]$m.branch
			if ($branches.ContainsKey($branchKey)) { $errors.Add("Branch '$branchKey' has more than one in-progress feature.") } else { $branches[$branchKey] = [string]$m.id }
		}
		if ($m.status -eq "ready") {
			if ($m.activity -ne "none") { $errors.Add("Ready feature '$($m.id)' must have activity none.") }
			if ($null -ne $m.activeSessionId) { $errors.Add("Ready feature '$($m.id)' cannot have activeSessionId.") }
			if (@($m.blockers).Count -ne 0) { $errors.Add("Ready feature '$($m.id)' cannot have blockers.") }
			if ([string]::IsNullOrWhiteSpace([string]$m.completedAt)) { $errors.Add("Ready feature '$($m.id)' needs completedAt.") }
		}

		$sessionIds = @{}
		foreach ($session in @($m.sessions)) {
			$id = [string]$session.threadId
			if ([string]::IsNullOrWhiteSpace($id)) { $errors.Add("$label contains a session without threadId."); continue }
			if ($sessionIds.ContainsKey($id)) { $errors.Add("Feature '$($m.id)' links task '$id' more than once.") } else { $sessionIds[$id] = $true }
			if ([string]$session.outcome -notin @("active", "paused", "completed", "interrupted", "historical")) { $errors.Add("Feature '$($m.id)' task '$id' has invalid outcome.") }
		}
	}
	return [PSCustomObject]@{ Ok = ($errors.Count -eq 0); Errors = @($errors); Records = $records }
}

function Escape-MarkdownCell {
	param([AllowNull()][object]$Value)
	if ($null -eq $Value) { return "—" }
	$text = [string]$Value
	if ([string]::IsNullOrWhiteSpace($text)) { return "—" }
	return $text.Replace("|", "\|").Replace("`r", " ").Replace("`n", " ")
}

function Get-FeatureIndexBlock {
	param([Parameter(Mandatory = $true)][object[]]$Records)

	$planned = @($Records | Where-Object { $_.Manifest.status -eq "planned" }).Count
	$working = @($Records | Where-Object { $_.Manifest.status -eq "in_progress" }).Count
	$ready = @($Records | Where-Object { $_.Manifest.status -eq "ready" }).Count
	$blocked = @($Records | Where-Object { @($_.Manifest.blockers).Count -gt 0 }).Count
	$lines = [Collections.Generic.List[string]]::new()
	$lines.Add($script:IndexBegin)
	$lines.Add("")
	$lines.Add("Всего: $($Records.Count) | Готово: $ready | В работе: $working | В плане: $planned | С блокерами: $blocked")
	$lines.Add("")
	$lines.Add("| ID | Фича | Состояние | Активность | Ветка | Базовый commit | Сессии | Блокеры | Обновлено |")
	$lines.Add("|---|---|---|---|---|---|---|---|---|")
	$statusOrder = @{ in_progress = 0; planned = 1; ready = 2 }
	$sorted = @($Records | Sort-Object @{ Expression = { $statusOrder[[string]$_.Manifest.status] } }, @{ Expression = { [string]$_.Manifest.id } })
	foreach ($record in $sorted) {
		$m = $record.Manifest
		$status = switch ([string]$m.status) { "planned" { "🟦 В плане" }; "in_progress" { "🟨 В работе" }; "ready" { "🟩 Готова" } }
		$activity = switch ([string]$m.activity) { "active" { "Активна" }; "paused" { "Приостановлена" }; default { "—" } }
		$base = if ([string]::IsNullOrWhiteSpace([string]$m.baseCommit)) { "—" } else { "``$(([string]$m.baseCommit).Substring(0, 8))``" }
		$branch = if ([string]::IsNullOrWhiteSpace([string]$m.branch)) { "—" } else { "``$($m.branch)``" }
		$sessionCount = @($m.sessions).Count
		$sessions = if ($sessionCount -eq 0) { "—" } else { "[$sessionCount](./$($record.Folder)/worklog.md)" }
		$blockers = if (@($m.blockers).Count -eq 0) { "—" } else { Escape-MarkdownCell (@($m.blockers) -join "; ") }
		$title = Escape-MarkdownCell $m.title
		$updated = if ([string]::IsNullOrWhiteSpace([string]$m.updatedAt)) { "—" } else { ([DateTimeOffset]::Parse([string]$m.updatedAt)).ToString("yyyy-MM-dd") }
		$lines.Add("| $($m.id) | [$title](./$($record.Folder)/) | $status | $activity | $branch | $base | $sessions | $blockers | $updated |")
	}
	$lines.Add("")
	$lines.Add($script:IndexEnd)
	return ($lines -join [Environment]::NewLine)
}

function Sync-FeatureIndex {
	param(
		[Parameter(Mandatory = $true)][string]$RepositoryRoot,
		[switch]$Check
	)

	$validation = Test-FeatureManifestSet -RepositoryRoot $RepositoryRoot
	if (-not $validation.Ok) {
		throw "Feature manifest validation failed:`n$($validation.Errors -join [Environment]::NewLine)"
	}
	$featureRoot = Get-FeatureRoot -RepositoryRoot $RepositoryRoot
	$indexPath = Join-Path $featureRoot "README.md"
	$generated = Get-FeatureIndexBlock -Records @($validation.Records)
	if (Test-Path -LiteralPath $indexPath -PathType Leaf) {
		$current = Get-Content -LiteralPath $indexPath -Raw
		$pattern = '(?s)' + [regex]::Escape($script:IndexBegin) + '.*?' + [regex]::Escape($script:IndexEnd)
		if ([regex]::IsMatch($current, $pattern)) {
			$desired = [regex]::Replace($current, $pattern, [Text.RegularExpressions.MatchEvaluator]{ param($match) $generated })
		} else {
			$desired = $current.TrimEnd() + [Environment]::NewLine + [Environment]::NewLine + $generated + [Environment]::NewLine
		}
	} else {
		$desired = @"
# Реестр фичей

Этот dashboard генерируется из `docs/Features/*/feature.json`. Манифесты —
единственный источник состояния; generated-блок не редактируется вручную.

$generated
"@.TrimEnd() + [Environment]::NewLine
	}
	if ($Check) {
		if (-not (Test-Path -LiteralPath $indexPath -PathType Leaf) -or $current -cne $desired) {
			throw "Feature dashboard is out of sync. Run scripts/sync-feature-index.ps1."
		}
		return $indexPath
	}
	Write-Utf8NoBom -Path $indexPath -Content $desired
	return $indexPath
}

Export-ModuleMember -Function @(
	"Acquire-FeatureWriterLease",
	"Add-FeatureSession",
	"Append-FeatureWorklog",
	"Assert-NoOtherFeatureOnBranch",
	"Close-FeatureSession",
	"ConvertTo-FeatureSlug",
	"Get-CurrentFeatureBranch",
	"Get-FeatureHead",
	"Get-FeatureManifests",
	"Get-FeatureRepositoryRoot",
	"Get-FeatureRoot",
	"Get-NextFeatureId",
	"Get-RepositoryRole",
	"Invoke-FeatureGit",
	"Release-FeatureWriterLease",
	"Resolve-FeatureRecord",
	"Sync-FeatureIndex",
	"Test-FeatureManifestSet",
	"Write-FeatureHandoff",
	"Write-FeatureManifest",
	"Write-Utf8NoBom"
)
