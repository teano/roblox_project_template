Set-StrictMode -Version Latest

$script:SchemaVersion = 2
$script:FeatureRootRelative = "docs/Features"
$script:FeatureNamespaceRoles = @("template", "project")
$script:IndexBegin = "<!-- feature-index:begin -->"
$script:IndexEnd = "<!-- feature-index:end -->"

function Read-StrictUtf8Text {
	param([Parameter(Mandatory = $true)][string]$Path)
	$bytes = [IO.File]::ReadAllBytes($Path)
	return [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
}

function Test-ByteArrayEqual {
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

function Write-AtomicBytes {
	param(
		[Parameter(Mandatory = $true)][string]$Path,
		[Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Bytes
	)

	$directory = Split-Path -Parent $Path
	if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
		New-Item -ItemType Directory -Path $directory -Force | Out-Null
	}
	$tempPath = Join-Path $directory (".{0}.{1}.tmp" -f (Split-Path -Leaf $Path), [Guid]::NewGuid().ToString("N"))
	try {
		[IO.File]::WriteAllBytes($tempPath, $Bytes)
		Move-Item -LiteralPath $tempPath -Destination $Path -Force
	} finally {
		if (Test-Path -LiteralPath $tempPath) {
			Remove-Item -LiteralPath $tempPath -Force
		}
	}
}

function ConvertTo-FeatureDashboardBytes {
	param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$CanonicalText)
	return [Text.UTF8Encoding]::new($false, $true).GetBytes($CanonicalText)
}

function Write-FeatureDashboard {
	param(
		[Parameter(Mandatory = $true)][string]$Path,
		[Parameter(Mandatory = $true)][AllowEmptyString()][string]$CanonicalText
	)

	$bytes = ConvertTo-FeatureDashboardBytes -CanonicalText $CanonicalText
	if (Test-Path -LiteralPath $Path -PathType Leaf) {
		$currentBytes = [IO.File]::ReadAllBytes($Path)
		if (Test-ByteArrayEqual -Left $currentBytes -Right $bytes) {
			return $false
		}
	}
	Write-AtomicBytes -Path $Path -Bytes $bytes
	return $true
}

function Assert-ValidJsonSurrogateEscapes {
	param(
		[Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
		[Parameter(Mandatory = $true)][string]$Path
	)

	$inString = $false
	for ($index = 0; $index -lt $Text.Length; $index++) {
		$character = $Text[$index]
		if (-not $inString) {
			if ($character -eq [char]'"') { $inString = $true }
			continue
		}
		if ($character -eq [char]'"') {
			$inString = $false
			continue
		}
		if ($character -ne [char]'\') { continue }
		if ($index + 1 -ge $Text.Length) { continue }
		$escapeType = $Text[$index + 1]
		if ($escapeType -ne [char]'u') {
			$index++
			continue
		}
		if ($index + 5 -ge $Text.Length) { continue }
		$hex = $Text.Substring($index + 2, 4)
		if ($hex -notmatch '^[0-9A-Fa-f]{4}$') { continue }
		$codeUnit = [Convert]::ToInt32($hex, 16)
		if ($codeUnit -ge 0xD800 -and $codeUnit -le 0xDBFF) {
			$hasLowEscape = (
				$index + 11 -lt $Text.Length -and
				$Text[$index + 6] -eq [char]'\' -and
				$Text[$index + 7] -eq [char]'u'
			)
			if ($hasLowEscape) {
				$lowHex = $Text.Substring($index + 8, 4)
				$hasLowEscape = $lowHex -match '^[0-9A-Fa-f]{4}$'
			}
			if ($hasLowEscape) {
				$lowUnit = [Convert]::ToInt32($lowHex, 16)
				$hasLowEscape = $lowUnit -ge 0xDC00 -and $lowUnit -le 0xDFFF
			}
			if (-not $hasLowEscape) {
				throw "Feature manifest '$Path' category=manifest cause=invalid-surrogate-escape."
			}
			$index += 11
			continue
		}
		if ($codeUnit -ge 0xDC00 -and $codeUnit -le 0xDFFF) {
			throw "Feature manifest '$Path' category=manifest cause=invalid-surrogate-escape."
		}
		$index += 5
	}
}

function ConvertFrom-FeatureJsonText {
	param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
	$command = Get-Command ConvertFrom-Json -ErrorAction Stop
	if ($command.Parameters.ContainsKey("DateKind")) {
		return ($Text | ConvertFrom-Json -DateKind String -ErrorAction Stop)
	}
	return ($Text | ConvertFrom-Json -ErrorAction Stop)
}

function ConvertFrom-FeatureTimestamp {
	param(
		[AllowNull()][object]$Value,
		[Parameter(Mandatory = $true)][string]$Property,
		[Parameter(Mandatory = $true)][string]$Path,
		[switch]$AllowNull
	)

	if ($null -eq $Value) {
		if ($AllowNull) { return $null }
		throw "$Path has invalid $Property; an RFC 3339 instant is required."
	}
	$text = [string]$Value
	if ([string]::IsNullOrWhiteSpace($text)) {
		throw "$Path has invalid $Property; an RFC 3339 instant is required."
	}
	$pattern = '^\d{4}-\d{2}-\d{2}[Tt]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:[Zz]|[+-]\d{2}:\d{2})$'
	if ($text -notmatch $pattern) {
		throw "$Path has invalid $Property; expected an RFC 3339 instant with an explicit zone."
	}
	$parseText = if ($text.EndsWith("z", [StringComparison]::Ordinal)) {
		$text.Substring(0, $text.Length - 1) + "Z"
	} else {
		$text
	}
	$parsed = [DateTimeOffset]::MinValue
	$valid = [DateTimeOffset]::TryParse(
		$parseText,
		[Globalization.CultureInfo]::InvariantCulture,
		[Globalization.DateTimeStyles]::None,
		[ref]$parsed
	)
	if (-not $valid) {
		throw "$Path has invalid $Property; expected a valid RFC 3339 instant."
	}
	return $parsed
}

function ConvertTo-FeatureUtcDateText {
	param(
		[Parameter(Mandatory = $true)][object]$Value,
		[Parameter(Mandatory = $true)][string]$Property,
		[Parameter(Mandatory = $true)][string]$Path
	)
	$parsed = ConvertFrom-FeatureTimestamp -Value $Value -Property $Property -Path $Path
	return $parsed.ToUniversalTime().ToString("yyyy-MM-dd", [Globalization.CultureInfo]::InvariantCulture)
}

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

	$bytes = [Text.UTF8Encoding]::new($false).GetBytes($Content)
	Write-AtomicBytes -Path $Path -Bytes $bytes
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

function Get-FeatureManifestFailureMessage {
	param(
		[Parameter(Mandatory = $true)][ValidateSet("template", "project")][string]$RepositoryRole,
		[Parameter(Mandatory = $true)][ValidateSet("template", "project")][string]$NamespaceRole,
		[Parameter(Mandatory = $true)][string]$Path,
		[Parameter(Mandatory = $true)][string]$Cause,
		[string]$Detail
	)

	$prefix = "Feature manifest validation failed: namespace=$NamespaceRole category=manifest cause=$Cause path='$Path'."
	$recovery = if ($RepositoryRole -eq "project" -and $NamespaceRole -eq "template") {
		"This derived repository does not own this template manifest; restore or update it from approved upstream content."
	} else {
		$scope = if ($NamespaceRole -eq "template") { "Template" } else { "Project" }
		"Fix this owning $NamespaceRole manifest, then run scripts/sync-feature-index.ps1 -Scope $scope for the owning namespace."
	}
	if ([string]::IsNullOrWhiteSpace($Detail)) {
		return "$prefix $recovery"
	}
	return "$prefix $recovery Detail: $Detail"
}

function Add-FeatureManifestValidationError {
	param(
		[Parameter(Mandatory = $true)][AllowEmptyCollection()][Collections.Generic.List[string]]$Errors,
		[Parameter(Mandatory = $true)]$Record,
		[Parameter(Mandatory = $true)][ValidateSet("schema", "timestamp", "artifact")][string]$Cause,
		[Parameter(Mandatory = $true)][string]$Detail,
		[Parameter(Mandatory = $true)][ValidateSet("template", "project")][string]$RepositoryRole
	)

	$Errors.Add((Get-FeatureManifestFailureMessage `
		-RepositoryRole $RepositoryRole `
		-NamespaceRole $Record.Namespace `
		-Path $Record.Path `
		-Cause $Cause `
		-Detail $Detail))
}

function Get-FeatureManifestRecords {
	param(
		[Parameter(Mandatory = $true)][string]$RepositoryRoot,
		[Parameter(Mandatory = $true)][ValidateSet("template", "project")][string[]]$NamespaceRoles
	)

	$repositoryRole = Get-RepositoryRole -RepositoryRoot $RepositoryRoot
	return @(
		foreach ($namespaceRole in $NamespaceRoles) {
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
						try {
							$manifestText = Read-StrictUtf8Text -Path $manifestPath
						} catch {
							throw (Get-FeatureManifestFailureMessage `
								-RepositoryRole $repositoryRole `
								-NamespaceRole $namespaceRole `
								-Path $manifestPath `
								-Cause "encoding" `
								-Detail $_.Exception.Message)
						}
						try {
							Assert-ValidJsonSurrogateEscapes -Text $manifestText -Path $manifestPath
						} catch {
							throw (Get-FeatureManifestFailureMessage `
								-RepositoryRole $repositoryRole `
								-NamespaceRole $namespaceRole `
								-Path $manifestPath `
								-Cause "invalid-surrogate-escape" `
								-Detail $_.Exception.Message)
						}
						try {
							$manifest = ConvertFrom-FeatureJsonText -Text $manifestText
						} catch {
							throw (Get-FeatureManifestFailureMessage `
								-RepositoryRole $repositoryRole `
								-NamespaceRole $namespaceRole `
								-Path $manifestPath `
								-Cause "json" `
								-Detail $_.Exception.Message)
						}
						if ($null -eq $manifest -or $manifest -isnot [PSCustomObject]) {
							throw (Get-FeatureManifestFailureMessage `
								-RepositoryRole $repositoryRole `
								-NamespaceRole $namespaceRole `
								-Path $manifestPath `
								-Cause "schema" `
								-Detail "The manifest root must be a JSON object.")
						}
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

function Get-FeatureManifests {
	param([Parameter(Mandatory = $true)][string]$RepositoryRoot)
	return @(
		Get-FeatureManifestRecords `
			-RepositoryRoot $RepositoryRoot `
			-NamespaceRoles $script:FeatureNamespaceRoles
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

function Test-FeatureManifestSetForNamespaces {
	param(
		[Parameter(Mandatory = $true)][string]$RepositoryRoot,
		[Parameter(Mandatory = $true)][ValidateSet("template", "project")][string[]]$NamespaceRoles
	)

	$errors = [Collections.Generic.List[string]]::new()
	$records = @(
		Get-FeatureManifestRecords `
			-RepositoryRoot $RepositoryRoot `
			-NamespaceRoles $NamespaceRoles
	)
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
			Add-FeatureManifestValidationError -Errors $errors -Record $record -Cause "schema" -Detail "$label is missing required property '$property'." -RepositoryRole $repositoryRole
		}
		foreach ($property in $unexpectedProperties) {
			Add-FeatureManifestValidationError -Errors $errors -Record $record -Cause "schema" -Detail "$label contains unsupported property '$property'." -RepositoryRole $repositoryRole
		}
		if ($missingProperties.Count -gt 0) { continue }
		if ($m.schemaVersion -ne $script:SchemaVersion) { Add-FeatureManifestValidationError -Errors $errors -Record $record -Cause "schema" -Detail "$label has unsupported schemaVersion." -RepositoryRole $repositoryRole }
		$expectedPrefix = if ($record.Namespace -eq "template") { "TF" } else { "F" }
		if (-not ([string]$m.id -match ("^{0}-\d{{4}}$" -f $expectedPrefix))) {
			Add-FeatureManifestValidationError -Errors $errors -Record $record -Cause "schema" -Detail "$label must use the $expectedPrefix prefix for the '$($record.Namespace)' namespace." -RepositoryRole $repositoryRole
		}
		foreach ($deprecatedProperty in @("activeSessionId", "sessions", "threadId", "hostId")) {
			if ($null -ne $m.PSObject.Properties[$deprecatedProperty]) {
				Add-FeatureManifestValidationError -Errors $errors -Record $record -Cause "schema" -Detail "$label contains deprecated agent/session field '$deprecatedProperty'." -RepositoryRole $repositoryRole
			}
		}
		if ([string]::IsNullOrWhiteSpace([string]$m.title)) { Add-FeatureManifestValidationError -Errors $errors -Record $record -Cause "schema" -Detail "$label has empty title." -RepositoryRole $repositoryRole }
		if (-not ([string]$m.slug -match '^[a-z0-9]+(?:-[a-z0-9]+)*$')) { Add-FeatureManifestValidationError -Errors $errors -Record $record -Cause "schema" -Detail "$label has invalid slug." -RepositoryRole $repositoryRole }
		if ([string]$m.status -notin @("planned", "in_progress", "ready")) { Add-FeatureManifestValidationError -Errors $errors -Record $record -Cause "schema" -Detail "$label has invalid status." -RepositoryRole $repositoryRole }
		if ([string]$m.activity -notin @("none", "active", "paused")) { Add-FeatureManifestValidationError -Errors $errors -Record $record -Cause "schema" -Detail "$label has invalid activity." -RepositoryRole $repositoryRole }
		foreach ($dateProperty in @("startedAt", "completedAt", "updatedAt")) {
			$value = $m.$dateProperty
			try {
				ConvertFrom-FeatureTimestamp `
					-Value $value `
					-Property $dateProperty `
					-Path $label `
					-AllowNull:($dateProperty -ne "updatedAt") | Out-Null
			} catch {
				Add-FeatureManifestValidationError -Errors $errors -Record $record -Cause "timestamp" -Detail $_.Exception.Message -RepositoryRole $repositoryRole
			}
		}
		if ($ids.ContainsKey([string]$m.id)) { Add-FeatureManifestValidationError -Errors $errors -Record $record -Cause "schema" -Detail "Duplicate feature id '$($m.id)'." -RepositoryRole $repositoryRole } else { $ids[[string]$m.id] = $true }
		$slugKey = "$($record.Namespace)/$($m.slug)"
		if ($slugs.ContainsKey($slugKey)) { Add-FeatureManifestValidationError -Errors $errors -Record $record -Cause "schema" -Detail "Duplicate feature slug '$slugKey'." -RepositoryRole $repositoryRole } else { $slugs[$slugKey] = $true }

		if ($m.status -eq "planned") {
			if ($m.activity -ne "none") { Add-FeatureManifestValidationError -Errors $errors -Record $record -Cause "schema" -Detail "Planned feature '$($m.id)' must have activity none." -RepositoryRole $repositoryRole }
		}
		if ($m.status -eq "in_progress") {
			if ($m.activity -notin @("active", "paused")) { Add-FeatureManifestValidationError -Errors $errors -Record $record -Cause "schema" -Detail "In-progress feature '$($m.id)' must be active or paused." -RepositoryRole $repositoryRole }
			if ([string]::IsNullOrWhiteSpace([string]$m.branch)) { Add-FeatureManifestValidationError -Errors $errors -Record $record -Cause "schema" -Detail "In-progress feature '$($m.id)' needs a branch." -RepositoryRole $repositoryRole }
			if (-not ([string]$m.baseCommit -match '^[0-9a-f]{40}$')) { Add-FeatureManifestValidationError -Errors $errors -Record $record -Cause "schema" -Detail "In-progress feature '$($m.id)' needs a full base commit." -RepositoryRole $repositoryRole }
			$branchKey = [string]$m.branch
			if ($branches.ContainsKey($branchKey)) { Add-FeatureManifestValidationError -Errors $errors -Record $record -Cause "schema" -Detail "Branch '$branchKey' has more than one in-progress feature." -RepositoryRole $repositoryRole } else { $branches[$branchKey] = [string]$m.id }
		}
		if ($m.status -eq "ready") {
			if ($m.activity -ne "none") { Add-FeatureManifestValidationError -Errors $errors -Record $record -Cause "schema" -Detail "Ready feature '$($m.id)' must have activity none." -RepositoryRole $repositoryRole }
			if (@($m.blockers).Count -ne 0) { Add-FeatureManifestValidationError -Errors $errors -Record $record -Cause "schema" -Detail "Ready feature '$($m.id)' cannot have blockers." -RepositoryRole $repositoryRole }
			if ([string]::IsNullOrWhiteSpace([string]$m.completedAt)) { Add-FeatureManifestValidationError -Errors $errors -Record $record -Cause "schema" -Detail "Ready feature '$($m.id)' needs completedAt." -RepositoryRole $repositoryRole }
		}

		if ($null -ne $m.verification) {
			$verificationProperties = @($m.verification.PSObject.Properties.Name)
			foreach ($property in @("completedAt", "head", "summary")) {
				if ($property -notin $verificationProperties) {
					Add-FeatureManifestValidationError -Errors $errors -Record $record -Cause "schema" -Detail "Feature '$($m.id)' verification is missing '$property'." -RepositoryRole $repositoryRole
				}
			}
			foreach ($property in $verificationProperties | Where-Object { $_ -notin @("completedAt", "head", "summary") }) {
				Add-FeatureManifestValidationError -Errors $errors -Record $record -Cause "schema" -Detail "Feature '$($m.id)' verification contains unsupported property '$property'." -RepositoryRole $repositoryRole
			}
		}
		foreach ($recovery in @($m.recoveryLog)) {
			$recoveryProperties = @($recovery.PSObject.Properties.Name)
			foreach ($property in @("at", "reason", "previousStatus")) {
				if ($property -notin $recoveryProperties) {
					Add-FeatureManifestValidationError -Errors $errors -Record $record -Cause "schema" -Detail "Feature '$($m.id)' recovery history is missing '$property'." -RepositoryRole $repositoryRole
				}
			}
			foreach ($property in $recoveryProperties | Where-Object { $_ -notin @("at", "reason", "previousStatus") }) {
				Add-FeatureManifestValidationError -Errors $errors -Record $record -Cause "schema" -Detail "Feature '$($m.id)' recovery history contains unsupported property '$property'." -RepositoryRole $repositoryRole
			}
		}
		foreach ($artifactName in @("handoff.md", "worklog.md")) {
			$artifactPath = Join-Path $record.Directory $artifactName
			if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) {
				Add-FeatureManifestValidationError -Errors $errors -Record $record -Cause "artifact" -Detail "Feature '$($m.id)' is missing $artifactName." -RepositoryRole $repositoryRole
				continue
			}
			$artifactContent = Get-Content -LiteralPath $artifactPath -Raw
			if ([regex]::IsMatch($artifactContent, '(?mi)^-\s*(?:session|thread|task|agent)(?:\s+id)?\s*:')) {
				Add-FeatureManifestValidationError -Errors $errors -Record $record -Cause "artifact" -Detail "Feature '$($m.id)' $artifactName contains deprecated agent/session metadata." -RepositoryRole $repositoryRole
			}
		}
	}
	return [PSCustomObject]@{ Ok = ($errors.Count -eq 0); Errors = @($errors); Records = $records }
}

function Test-FeatureManifestSet {
	param([Parameter(Mandatory = $true)][string]$RepositoryRoot)
	return Test-FeatureManifestSetForNamespaces `
		-RepositoryRoot $RepositoryRoot `
		-NamespaceRoles $script:FeatureNamespaceRoles
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
		$updated = ConvertTo-FeatureUtcDateText -Value $m.updatedAt -Property "updatedAt" -Path $record.Path
		$lines.Add("| $($m.id) | [$title](./$($record.Folder)/) | $status | $activity | $branch | $base | $worklog | $blockers | $updated |")
	}
	$lines.Add("")
	$lines.Add($script:IndexEnd)
	return ($lines -join "`n")
}

function ConvertTo-CanonicalFeatureDashboardText {
	param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
	return ([regex]::Replace($Text, '[\r\n]+\z', '') + "`n")
}

function Get-FeatureDashboardText {
	param(
		[Parameter(Mandatory = $true)][ValidateSet("template", "project")][string]$NamespaceRole,
		[Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Records
	)

	$title = if ($NamespaceRole -eq "template") { "Фичи шаблона" } else { "Фичи проекта" }
	$manifestPattern = "docs/Features/$NamespaceRole/*/feature.json"
	$lines = [Collections.Generic.List[string]]::new()
	$lines.Add("# $title")
	$lines.Add("")
	$lines.Add("Этот dashboard генерируется из")
	$lines.Add("``$manifestPattern``. Манифесты —")
	$lines.Add("единственный источник состояния; generated-блок не редактируется вручную.")
	$lines.Add("")
	$lines.Add((Get-FeatureIndexBlock -Records $Records))
	return ConvertTo-CanonicalFeatureDashboardText -Text ($lines -join "`n")
}

function Normalize-FeatureDashboardText {
	param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
	return $Text.Replace("`r`n", "`n").Replace("`r", "`n")
}

function Get-FeatureDashboardDriftCategory {
	param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
	$beginMatches = [regex]::Matches($Text, [regex]::Escape($script:IndexBegin))
	$endMatches = [regex]::Matches($Text, [regex]::Escape($script:IndexEnd))
	if (
		$beginMatches.Count -ne 1 -or
		$endMatches.Count -ne 1 -or
		$beginMatches[0].Index -ge $endMatches[0].Index
	) {
		return "markers"
	}
	return "content"
}

function Get-FeatureDashboardFailureMessage {
	param(
		[Parameter(Mandatory = $true)][ValidateSet("template", "project")][string]$RepositoryRole,
		[Parameter(Mandatory = $true)][ValidateSet("template", "project")][string]$NamespaceRole,
		[Parameter(Mandatory = $true)][ValidateSet("missing", "markers", "encoding", "content", "manifest")][string]$Category,
		[Parameter(Mandatory = $true)][string]$Path
	)
	$prefix = "Feature dashboard validation failed: namespace=$NamespaceRole category=$Category path='$Path'."
	if ($RepositoryRole -eq "project" -and $NamespaceRole -eq "template") {
		return "$prefix This derived repository does not own the template dashboard; restore or update it from approved upstream content."
	}
	$scope = if ($NamespaceRole -eq "template") { "Template" } else { "Project" }
	return "$prefix Run scripts/sync-feature-index.ps1 -Scope $scope for the owning namespace."
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

	$validation = if (
		-not $Check -and
		$repositoryRole -eq "project" -and
		$NamespaceRole -eq "project"
	) {
		Test-FeatureManifestSetForNamespaces `
			-RepositoryRoot $RepositoryRoot `
			-NamespaceRoles @("project")
	} else {
		Test-FeatureManifestSet -RepositoryRoot $RepositoryRoot
	}
	if (-not $validation.Ok) {
		throw "Feature manifest validation failed: category=manifest.`n$($validation.Errors -join [Environment]::NewLine)"
	}
	$featureRoot = Get-FeatureNamespaceRoot -RepositoryRoot $RepositoryRoot -NamespaceRole $NamespaceRole
	$indexPath = Join-Path $featureRoot "README.md"
	$namespaceRecords = @($validation.Records | Where-Object { $_.Namespace -eq $NamespaceRole })
	$desired = Get-FeatureDashboardText -NamespaceRole $NamespaceRole -Records $namespaceRecords
	if ($Check) {
		# Validate the expected output through the same strict encoder without
		# granting Check mode access to the filesystem writer.
		$null = ConvertTo-FeatureDashboardBytes -CanonicalText $desired
		if (-not (Test-Path -LiteralPath $indexPath -PathType Leaf)) {
			throw (Get-FeatureDashboardFailureMessage -RepositoryRole $repositoryRole -NamespaceRole $NamespaceRole -Category "missing" -Path $indexPath)
		}
		try {
			$current = Read-StrictUtf8Text -Path $indexPath
		} catch {
			throw ((Get-FeatureDashboardFailureMessage -RepositoryRole $repositoryRole -NamespaceRole $NamespaceRole -Category "encoding" -Path $indexPath) + " $($_.Exception.Message)")
		}
		$currentLogical = Normalize-FeatureDashboardText -Text $current
		$desiredLogical = Normalize-FeatureDashboardText -Text $desired
		if (-not $currentLogical.Equals($desiredLogical, [StringComparison]::Ordinal)) {
			$category = Get-FeatureDashboardDriftCategory -Text $current
			throw (Get-FeatureDashboardFailureMessage -RepositoryRole $repositoryRole -NamespaceRole $NamespaceRole -Category $category -Path $indexPath)
		}
		return $indexPath
	}
	Write-FeatureDashboard -Path $indexPath -CanonicalText $desired | Out-Null
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
