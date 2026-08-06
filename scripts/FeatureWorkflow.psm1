Set-StrictMode -Version Latest

$script:SchemaVersion = 2
$script:FeatureRootRelative = "docs/Features"
$script:FeatureNamespaceRoles = @("template", "project")
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

function Get-FeatureNamespaceRoot {
	param(
		[Parameter(Mandatory = $true)][string]$RepositoryRoot,
		[Parameter(Mandatory = $true)][ValidateSet("template", "project")][string]$NamespaceRole
	)
	return Join-Path (Join-Path $RepositoryRoot $script:FeatureRootRelative) $NamespaceRole
}

function Get-FeatureRoot {
	param([Parameter(Mandatory = $true)][string]$RepositoryRoot)
	$role = Get-RepositoryRole -RepositoryRoot $RepositoryRoot
	return Get-FeatureNamespaceRoot -RepositoryRoot $RepositoryRoot -NamespaceRole $role
}

function Get-FeatureNamespaceRoles {
	param([Parameter(Mandatory = $true)][string]$RepositoryRoot)
	$roles = @("template")
	if ((Get-RepositoryRole -RepositoryRoot $RepositoryRoot) -eq "project") {
		$roles += "project"
	}
	return @($roles)
}

function Get-FeatureManifests {
	param([Parameter(Mandatory = $true)][string]$RepositoryRoot)

	return @(
		foreach ($namespaceRole in $script:FeatureNamespaceRoles) {
			$namespaceRoot = Get-FeatureNamespaceRoot `
				-RepositoryRoot $RepositoryRoot `
				-NamespaceRole $namespaceRole
			if (-not (Test-Path -LiteralPath $namespaceRoot -PathType Container)) {
				continue
			}
			Get-ChildItem -LiteralPath $namespaceRoot -Directory |
				ForEach-Object {
					$manifestPath = Join-Path $_.FullName "feature.json"
					if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
						$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
						[PSCustomObject]@{
							Namespace = $namespaceRole
							NamespaceRoot = $namespaceRoot
							Directory = $_.FullName
							Folder = $_.Name
							Path = $manifestPath
							Manifest = $manifest
						}
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
	if ($remotes -notcontains "upstream") {
		return "template"
	}

	$upstreamUrls = Invoke-FeatureGit `
		-RepositoryRoot $RepositoryRoot `
		-Arguments @("remote", "get-url", "--all", "upstream")
	$pointsToTemplate = @(
		$upstreamUrls.Output | Where-Object {
			$normalized = ([string]$_).Trim().TrimEnd('/', '\')
			$normalized = [regex]::Replace($normalized, '\.git$', '', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
			$normalized -match '(?i)(?:^|[/:\\])roblox_project_template$'
		}
	).Count -gt 0
	if (-not $pointsToTemplate) {
		throw (
			"Remote 'upstream' exists but does not point to the reusable " +
			"roblox_project_template repository. Repository role is ambiguous."
		)
	}
	return "project"
}

function Assert-FeatureRepositoryInitialized {
	param([Parameter(Mandatory = $true)][string]$RepositoryRoot)

	if ((Get-RepositoryRole -RepositoryRoot $RepositoryRoot) -ne "project") {
		return
	}
	$requiredPaths = @(
		"docs/adr/project/README.md",
		"docs/Features/project/README.md"
	)
	$missing = @(
		$requiredPaths | Where-Object {
			-not (Test-Path -LiteralPath (Join-Path $RepositoryRoot $_) -PathType Leaf)
		}
	)
	if ($missing.Count -gt 0) {
		throw (
			"Derived-project feature work requires completed project initialization. " +
			"Missing: $($missing -join ', '). Follow .agents/rules/project-initialization.md first."
		)
	}
}

function Get-NextFeatureId {
	param(
		[Parameter(Mandatory = $true)][string]$RepositoryRoot,
		[Parameter(Mandatory = $true)][ValidateSet("template", "project")][string]$Role
	)

	$prefix = if ($Role -eq "template") { "TF" } else { "F" }
	$maximum = 0
	foreach ($record in Get-FeatureManifests -RepositoryRoot $RepositoryRoot) {
		if ($record.Namespace -ne $Role) { continue }
		$id = [string]$record.Manifest.id
		$pattern = if ($Role -eq "template") { '^TF-(\d{4})$' } else { '^(?:F|PF)-(\d{4})$' }
		if ($id -match $pattern) {
			$number = [int]$Matches[1]
			if ($number -gt $maximum) { $maximum = $number }
		}
	}
	return ("{0}-{1:D4}" -f $prefix, ($maximum + 1))
}

function Get-CanonicalFeatureBranchName {
	param(
		[Parameter(Mandatory = $true)][ValidateSet("template", "project")][string]$NamespaceRole,
		[Parameter(Mandatory = $true)][string]$FeatureId,
		[Parameter(Mandatory = $true)][string]$Slug
	)

	$resolvedSlug = ConvertTo-FeatureSlug $Slug
	if ($NamespaceRole -eq "template") {
		if ($FeatureId -notmatch '^TF-(\d{4})$') {
			throw "Template feature id '$FeatureId' must match TF-####."
		}
		return "template-feature/$($FeatureId.ToLowerInvariant())-$resolvedSlug"
	}
	if ($FeatureId -notmatch '^F-(\d{4})$') {
		throw "Project feature id '$FeatureId' must match F-####."
	}
	return "feature/t-$($Matches[1])-$resolvedSlug"
}

function Assert-FeatureRecordWritable {
	param(
		[Parameter(Mandatory = $true)][string]$RepositoryRoot,
		[Parameter(Mandatory = $true)]$Record
	)
	$repositoryRole = Get-RepositoryRole -RepositoryRoot $RepositoryRoot
	if ($Record.Namespace -ne $repositoryRole) {
		throw (
			"Feature '$($Record.Manifest.id)' belongs to the '$($Record.Namespace)' " +
			"namespace. A '$repositoryRole' repository may mutate only its own " +
			"feature namespace."
		)
	}
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
	return Join-Path (Join-Path $common "feature-workflow/locks") ("$hash.lock")
}

function Acquire-FeatureWriterLease {
	param(
		[Parameter(Mandatory = $true)][string]$RepositoryRoot,
		[Parameter(Mandatory = $true)][string]$Branch,
		[Parameter(Mandatory = $true)][string]$FeatureId
	)

	$lockPath = Get-BranchLockPath -RepositoryRoot $RepositoryRoot -Branch $Branch
	$parent = Split-Path -Parent $lockPath
	New-Item -ItemType Directory -Path $parent -Force | Out-Null
	try {
		New-Item -ItemType Directory -Path $lockPath -ErrorAction Stop | Out-Null
	} catch {
		$lease = Assert-FeatureWriterLease `
			-RepositoryRoot $RepositoryRoot `
			-Branch $Branch `
			-FeatureId $FeatureId `
			-AllowDifferentOwner
		if (-not ([string]$lease.featureId).Equals($FeatureId, [StringComparison]::Ordinal)) {
			throw "Branch '$Branch' already has a writer lease for feature '$($lease.featureId)'."
		}
		return $lockPath
	}

	$lease = [ordered]@{
		schemaVersion = 2
		branch = $Branch
		featureId = $FeatureId
		createdAt = [DateTimeOffset]::UtcNow.ToString("o")
	}
	Write-Utf8NoBom -Path (Join-Path $lockPath "lease.json") -Content (($lease | ConvertTo-Json -Depth 5) + [Environment]::NewLine)
	return $lockPath
}

function Assert-FeatureWriterLease {
	param(
		[Parameter(Mandatory = $true)][string]$RepositoryRoot,
		[Parameter(Mandatory = $true)][string]$Branch,
		[Parameter(Mandatory = $true)][string]$FeatureId,
		[switch]$AllowDifferentOwner
	)

	$lockPath = Get-BranchLockPath -RepositoryRoot $RepositoryRoot -Branch $Branch
	$leasePath = Join-Path $lockPath "lease.json"
	if (-not (Test-Path -LiteralPath $leasePath -PathType Leaf)) {
		throw "Branch '$Branch' has no readable feature writer lease at '$lockPath'."
	}
	try {
		$lease = Get-Content -LiteralPath $leasePath -Raw | ConvertFrom-Json
	} catch {
		throw "Branch '$Branch' has an unreadable feature writer lease at '$lockPath'."
	}
	$allowedProperties = @("schemaVersion", "branch", "featureId", "createdAt")
	$actualProperties = @($lease.PSObject.Properties.Name)
	$unexpected = @($actualProperties | Where-Object { $_ -notin $allowedProperties })
	$missing = @($allowedProperties | Where-Object { $_ -notin $actualProperties })
	$createdAt = [DateTimeOffset]::MinValue
	if (
		$lease.schemaVersion -ne 2 -or
		$unexpected.Count -gt 0 -or
		$missing.Count -gt 0 -or
		-not [DateTimeOffset]::TryParse([string]$lease.createdAt, [ref]$createdAt) -or
		-not ([string]$lease.branch).Equals($Branch, [StringComparison]::Ordinal)
	) {
		throw "Branch '$Branch' has an invalid or legacy feature writer lease at '$lockPath'."
	}
	if (
		-not $AllowDifferentOwner -and
		-not ([string]$lease.featureId).Equals($FeatureId, [StringComparison]::Ordinal)
	) {
		throw "Feature '$FeatureId' does not own the writer lease for '$Branch'."
	}
	return $lease
}

function Release-FeatureWriterLease {
	param(
		[Parameter(Mandatory = $true)][string]$RepositoryRoot,
		[Parameter(Mandatory = $true)][string]$Branch,
		[Parameter(Mandatory = $true)][string]$FeatureId
	)

	$lockPath = Get-BranchLockPath -RepositoryRoot $RepositoryRoot -Branch $Branch
	if (-not (Test-Path -LiteralPath $lockPath -PathType Container)) {
		throw "Cannot release missing feature writer lease '$lockPath'."
	}
	Assert-FeatureWriterLease `
		-RepositoryRoot $RepositoryRoot `
		-Branch $Branch `
		-FeatureId $FeatureId | Out-Null
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

function Get-FeatureBlockerMarkdown {
	param([Parameter(Mandatory = $true)]$Manifest)
	$blockers = @($Manifest.blockers)
	if ($blockers.Count -eq 0) { return "None." }
	return (($blockers | ForEach-Object { "- $_" }) -join [Environment]::NewLine)
}

function Write-FeatureHandoff {
	param(
		[Parameter(Mandatory = $true)][string]$Directory,
		[Parameter(Mandatory = $true)]$Manifest,
		[Parameter(Mandatory = $true)][string]$Head,
		[Parameter(Mandatory = $true)][string]$Summary,
		[Parameter(Mandatory = $true)][string]$Decisions,
		[Parameter(Mandatory = $true)][string]$VerificationSummary,
		[Parameter(Mandatory = $true)][AllowEmptyString()][string]$NextStep
	)
	$featureLabel = "$($Manifest.id) $($Manifest.title)"
	$blockerMarkdown = Get-FeatureBlockerMarkdown -Manifest $Manifest
	$content = @"
# Feature handoff

- Feature: $featureLabel
- Status: $($Manifest.status) / $($Manifest.activity)
- Head: $Head
- Updated: $([DateTimeOffset]::UtcNow.ToString("o"))

## Result and current state

$Summary

## Important decisions and discussions

$Decisions

## Verification state

$VerificationSummary

## Blockers

$blockerMarkdown

## Next step

$(if ([string]::IsNullOrWhiteSpace($NextStep)) { "None." } else { $NextStep })
"@
	Write-Utf8NoBom -Path (Join-Path $Directory "handoff.md") -Content ($content.TrimEnd() + [Environment]::NewLine)
}

function Append-FeatureWorklog {
	param(
		[Parameter(Mandatory = $true)][string]$Directory,
		[Parameter(Mandatory = $true)]$Manifest,
		[Parameter(Mandatory = $true)][string]$Action,
		[Parameter(Mandatory = $true)][string]$Head,
		[Parameter(Mandatory = $true)][string]$Summary,
		[Parameter(Mandatory = $true)][string]$Decisions,
		[Parameter(Mandatory = $true)][string]$VerificationSummary,
		[Parameter(Mandatory = $true)][AllowEmptyString()][string]$NextStep
	)
	$path = Join-Path $Directory "worklog.md"
	if (Test-Path -LiteralPath $path -PathType Leaf) {
		$content = Get-Content -LiteralPath $path -Raw
	} else {
		$content = "# Feature worklog`r`n"
	}
	$blockerMarkdown = Get-FeatureBlockerMarkdown -Manifest $Manifest
	$entry = @"

## $([DateTimeOffset]::UtcNow.ToString("o")) — $Action

- Feature: $($Manifest.id)
- Head: $Head

### Result and current state

$Summary

### Important decisions and discussions

$Decisions

### Verification state

$VerificationSummary

### Blockers

$blockerMarkdown

### Next step

$(if ([string]::IsNullOrWhiteSpace($NextStep)) { "None." } else { $NextStep })
"@
	Write-Utf8NoBom -Path $path -Content ($content.TrimEnd() + [Environment]::NewLine + $entry.TrimEnd() + [Environment]::NewLine)
}

function Test-FeatureManifestSet {
	param([Parameter(Mandatory = $true)][string]$RepositoryRoot)

	$errors = [Collections.Generic.List[string]]::new()
	$records = @(Get-FeatureManifests -RepositoryRoot $RepositoryRoot)
	$repositoryRole = Get-RepositoryRole -RepositoryRoot $RepositoryRoot
	$featureRoot = Join-Path $RepositoryRoot $script:FeatureRootRelative
	$templateRoot = Get-FeatureNamespaceRoot -RepositoryRoot $RepositoryRoot -NamespaceRole "template"
	$projectRoot = Get-FeatureNamespaceRoot -RepositoryRoot $RepositoryRoot -NamespaceRole "project"
	if (-not (Test-Path -LiteralPath $templateRoot -PathType Container)) {
		$errors.Add("Template feature namespace is missing: $templateRoot")
	}
	if ($repositoryRole -eq "template" -and (Test-Path -LiteralPath $projectRoot)) {
		$errors.Add("The template repository must not contain docs/Features/project.")
	}
	if ($repositoryRole -eq "project" -and -not (Test-Path -LiteralPath $projectRoot -PathType Container)) {
		$errors.Add("Derived repositories must initialize docs/Features/project before feature work.")
	}
	if (
		$repositoryRole -eq "project" -and
		-not (Test-Path -LiteralPath (Join-Path $RepositoryRoot "docs/adr/project/README.md") -PathType Leaf)
	) {
		$errors.Add("Derived repositories must complete project ADR initialization before feature work.")
	}
	if (Test-Path -LiteralPath $featureRoot -PathType Container) {
		foreach ($legacyDirectory in Get-ChildItem -LiteralPath $featureRoot -Directory) {
			if ($legacyDirectory.Name -in @("template", "project", "_schema")) { continue }
			if (Test-Path -LiteralPath (Join-Path $legacyDirectory.FullName "feature.json") -PathType Leaf) {
				$errors.Add("Feature manifests must live under docs/Features/template or docs/Features/project: $($legacyDirectory.FullName)")
			}
		}
	}
	$ids = @{}
	$slugs = @{}
	$branches = @{}
	foreach ($record in $records) {
		$m = $record.Manifest
		$label = $record.Path
		$requiredProperties = @(
			"schemaVersion", "id", "slug", "title", "status", "activity",
			"branch", "baseCommit", "startedAt", "completedAt", "updatedAt",
			"blockers", "artifacts", "verification", "recoveryLog"
		)
		$actualProperties = @($m.PSObject.Properties.Name)
		$missingProperties = @($requiredProperties | Where-Object { $_ -notin $actualProperties })
		$unexpectedProperties = @($actualProperties | Where-Object { $_ -notin $requiredProperties })
		foreach ($property in $missingProperties) {
			$errors.Add("$label is missing required property '$property'.")
		}
		foreach ($property in $unexpectedProperties) {
			$errors.Add("$label contains unsupported property '$property'.")
		}
		if ($missingProperties.Count -gt 0) { continue }
		if ($m.schemaVersion -ne $script:SchemaVersion) { $errors.Add("$label has unsupported schemaVersion.") }
		$expectedPrefix = if ($record.Namespace -eq "template") { "TF" } else { "F" }
		if (-not ([string]$m.id -match ("^{0}-\d{{4}}$" -f $expectedPrefix))) {
			$errors.Add("$label must use the $expectedPrefix prefix for the '$($record.Namespace)' namespace.")
		}
		foreach ($deprecatedProperty in @("activeSessionId", "sessions", "threadId", "hostId")) {
			if ($null -ne $m.PSObject.Properties[$deprecatedProperty]) {
				$errors.Add("$label contains deprecated agent/session field '$deprecatedProperty'.")
			}
		}
		if ([string]::IsNullOrWhiteSpace([string]$m.title)) { $errors.Add("$label has empty title.") }
		if (-not ([string]$m.slug -match '^[a-z0-9]+(?:-[a-z0-9]+)*$')) { $errors.Add("$label has invalid slug.") }
		if ([string]$m.status -notin @("planned", "in_progress", "ready")) { $errors.Add("$label has invalid status.") }
		if ([string]$m.activity -notin @("none", "active", "paused")) { $errors.Add("$label has invalid activity.") }
		foreach ($dateProperty in @("startedAt", "completedAt", "updatedAt")) {
			$value = $m.$dateProperty
			if ($null -eq $value -and $dateProperty -ne "updatedAt") { continue }
			$parsedDate = [DateTimeOffset]::MinValue
			if (-not [DateTimeOffset]::TryParse([string]$value, [ref]$parsedDate)) {
				$errors.Add("$label has invalid $dateProperty.")
			}
		}
		if ($ids.ContainsKey([string]$m.id)) { $errors.Add("Duplicate feature id '$($m.id)'.") } else { $ids[[string]$m.id] = $true }
		$slugKey = "$($record.Namespace)/$($m.slug)"
		if ($slugs.ContainsKey($slugKey)) { $errors.Add("Duplicate feature slug '$slugKey'.") } else { $slugs[$slugKey] = $true }

		if ($m.status -eq "planned") {
			if ($m.activity -ne "none") { $errors.Add("Planned feature '$($m.id)' must have activity none.") }
		}
		if ($m.status -eq "in_progress") {
			if ($m.activity -notin @("active", "paused")) { $errors.Add("In-progress feature '$($m.id)' must be active or paused.") }
			if ([string]::IsNullOrWhiteSpace([string]$m.branch)) { $errors.Add("In-progress feature '$($m.id)' needs a branch.") }
			if (-not ([string]$m.baseCommit -match '^[0-9a-f]{40}$')) { $errors.Add("In-progress feature '$($m.id)' needs a full base commit.") }
			$branchKey = [string]$m.branch
			if ($branches.ContainsKey($branchKey)) { $errors.Add("Branch '$branchKey' has more than one in-progress feature.") } else { $branches[$branchKey] = [string]$m.id }
		}
		if ($m.status -eq "ready") {
			if ($m.activity -ne "none") { $errors.Add("Ready feature '$($m.id)' must have activity none.") }
			if (@($m.blockers).Count -ne 0) { $errors.Add("Ready feature '$($m.id)' cannot have blockers.") }
			if ([string]::IsNullOrWhiteSpace([string]$m.completedAt)) { $errors.Add("Ready feature '$($m.id)' needs completedAt.") }
		}

		if ($null -ne $m.verification) {
			$verificationProperties = @($m.verification.PSObject.Properties.Name)
			foreach ($property in @("completedAt", "head", "summary")) {
				if ($property -notin $verificationProperties) {
					$errors.Add("Feature '$($m.id)' verification is missing '$property'.")
				}
			}
			foreach ($property in $verificationProperties | Where-Object { $_ -notin @("completedAt", "head", "summary") }) {
				$errors.Add("Feature '$($m.id)' verification contains unsupported property '$property'.")
			}
		}
		foreach ($recovery in @($m.recoveryLog)) {
			$recoveryProperties = @($recovery.PSObject.Properties.Name)
			foreach ($property in @("at", "reason", "previousStatus")) {
				if ($property -notin $recoveryProperties) {
					$errors.Add("Feature '$($m.id)' recovery history is missing '$property'.")
				}
			}
			foreach ($property in $recoveryProperties | Where-Object { $_ -notin @("at", "reason", "previousStatus") }) {
				$errors.Add("Feature '$($m.id)' recovery history contains unsupported property '$property'.")
			}
		}
		foreach ($artifactName in @("handoff.md", "worklog.md")) {
			$artifactPath = Join-Path $record.Directory $artifactName
			if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) {
				$errors.Add("Feature '$($m.id)' is missing $artifactName.")
				continue
			}
			$artifactContent = Get-Content -LiteralPath $artifactPath -Raw
			if ([regex]::IsMatch($artifactContent, '(?mi)^-\s*(?:session|thread|task|agent)(?:\s+id)?\s*:')) {
				$errors.Add("Feature '$($m.id)' $artifactName contains deprecated agent/session metadata.")
			}
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
	param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Records)

	$planned = @($Records | Where-Object { $_.Manifest.status -eq "planned" }).Count
	$working = @($Records | Where-Object { $_.Manifest.status -eq "in_progress" }).Count
	$ready = @($Records | Where-Object { $_.Manifest.status -eq "ready" }).Count
	$blocked = @($Records | Where-Object { @($_.Manifest.blockers).Count -gt 0 }).Count
	$lines = [Collections.Generic.List[string]]::new()
	$lines.Add($script:IndexBegin)
	$lines.Add("")
	$lines.Add("Всего: $($Records.Count) | Готово: $ready | В работе: $working | В плане: $planned | С блокерами: $blocked")
	$lines.Add("")
	$lines.Add("| ID | Фича | Состояние | Активность | Ветка | Базовый commit | Worklog | Блокеры | Обновлено |")
	$lines.Add("|---|---|---|---|---|---|---|---|---|")
	$statusOrder = @{ in_progress = 0; planned = 1; ready = 2 }
	$sorted = @($Records | Sort-Object @{ Expression = { $statusOrder[[string]$_.Manifest.status] } }, @{ Expression = { [string]$_.Manifest.id } })
	foreach ($record in $sorted) {
		$m = $record.Manifest
		$status = switch ([string]$m.status) { "planned" { "🟦 В плане" }; "in_progress" { "🟨 В работе" }; "ready" { "🟩 Готова" } }
		$activity = switch ([string]$m.activity) { "active" { "Активна" }; "paused" { "Приостановлена" }; default { "—" } }
		$base = if ([string]::IsNullOrWhiteSpace([string]$m.baseCommit)) { "—" } else { "``$(([string]$m.baseCommit).Substring(0, 8))``" }
		$branch = if ([string]::IsNullOrWhiteSpace([string]$m.branch)) { "—" } else { "``$($m.branch)``" }
		$worklog = "[Открыть](./$($record.Folder)/worklog.md)"
		$blockers = if (@($m.blockers).Count -eq 0) { "—" } else { Escape-MarkdownCell (@($m.blockers) -join "; ") }
		$title = Escape-MarkdownCell $m.title
		$updated = if ([string]::IsNullOrWhiteSpace([string]$m.updatedAt)) { "—" } else { ([DateTimeOffset]::Parse([string]$m.updatedAt)).ToString("yyyy-MM-dd") }
		$lines.Add("| $($m.id) | [$title](./$($record.Folder)/) | $status | $activity | $branch | $base | $worklog | $blockers | $updated |")
	}
	$lines.Add("")
	$lines.Add($script:IndexEnd)
	return ($lines -join [Environment]::NewLine)
}

function Sync-FeatureIndex {
	param(
		[Parameter(Mandatory = $true)][string]$RepositoryRoot,
		[ValidateSet("template", "project")][string]$NamespaceRole,
		[switch]$Check
	)
	if ([string]::IsNullOrWhiteSpace($NamespaceRole)) {
		$NamespaceRole = Get-RepositoryRole -RepositoryRoot $RepositoryRoot
	}
	$repositoryRole = Get-RepositoryRole -RepositoryRoot $RepositoryRoot
	if (-not $Check -and $repositoryRole -eq "project" -and $NamespaceRole -eq "template") {
		throw "A derived repository must not rewrite the template feature dashboard."
	}
	if ($repositoryRole -eq "template" -and $NamespaceRole -eq "project") {
		throw "The reusable template must not create a project feature namespace."
	}

	$validation = Test-FeatureManifestSet -RepositoryRoot $RepositoryRoot
	if (-not $validation.Ok) {
		throw "Feature manifest validation failed:`n$($validation.Errors -join [Environment]::NewLine)"
	}
	$featureRoot = Get-FeatureNamespaceRoot -RepositoryRoot $RepositoryRoot -NamespaceRole $NamespaceRole
	$indexPath = Join-Path $featureRoot "README.md"
	$namespaceRecords = @($validation.Records | Where-Object { $_.Namespace -eq $NamespaceRole })
	$generated = Get-FeatureIndexBlock -Records $namespaceRecords
	if (Test-Path -LiteralPath $indexPath -PathType Leaf) {
		$current = Get-Content -LiteralPath $indexPath -Raw
		$pattern = '(?s)' + [regex]::Escape($script:IndexBegin) + '.*?' + [regex]::Escape($script:IndexEnd)
		if ([regex]::IsMatch($current, $pattern)) {
			$desired = [regex]::Replace($current, $pattern, [Text.RegularExpressions.MatchEvaluator]{ param($match) $generated })
		} else {
			$desired = $current.TrimEnd() + [Environment]::NewLine + [Environment]::NewLine + $generated + [Environment]::NewLine
		}
	} else {
		$manifestPattern = "docs/Features/$NamespaceRole/*/feature.json"
		$title = if ($NamespaceRole -eq "template") { "Фичи шаблона" } else { "Фичи проекта" }
		$desired = @"
# $title

Этот dashboard генерируется из $manifestPattern. Манифесты —
единственный источник состояния; generated-блок не редактируется вручную.

$generated
"@.TrimEnd() + [Environment]::NewLine
	}
	if ($Check) {
		if (-not (Test-Path -LiteralPath $indexPath -PathType Leaf) -or $current -cne $desired) {
			throw "The '$NamespaceRole' feature dashboard is out of sync. Run scripts/sync-feature-index.ps1 for its owning namespace."
		}
		return $indexPath
	}
	Write-Utf8NoBom -Path $indexPath -Content $desired
	return $indexPath
}

Export-ModuleMember -Function @(
	"Acquire-FeatureWriterLease",
	"Assert-FeatureRepositoryInitialized",
	"Assert-FeatureWriterLease",
	"Append-FeatureWorklog",
	"Assert-NoOtherFeatureOnBranch",
	"Assert-FeatureRecordWritable",
	"ConvertTo-FeatureSlug",
	"Get-CanonicalFeatureBranchName",
	"Get-CurrentFeatureBranch",
	"Get-FeatureHead",
	"Get-FeatureManifests",
	"Get-FeatureNamespaceRoles",
	"Get-FeatureNamespaceRoot",
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
