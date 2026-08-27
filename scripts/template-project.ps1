<#
.SYNOPSIS
Initializes, updates, or validates a repository derived from this template.

.DESCRIPTION
This script is intentionally self-contained. It does not import the legacy
feature workflow, an agent skill, or another repository script.

Init and update are two-phase operations: use exactly one of -Check or -Apply.
Validate is always read-only and accepts neither switch. RepositoryPath is
mandatory so the command never guesses which checkout it owns.

TargetRef names a template commit already available in the selected Git
source. Originless init requires its full 40-character ID and exports only that
tracked snapshot from an exact local template root. The script never guesses a
legacy bootstrap branch. For a repository whose target started with its own
README, merge the template history first, then pass the exact fetched template
ref to init. A project README that differs from TargetRef is preserved byte for
byte; a still-template README is replaced by the small project README.

.EXAMPLE
  ./scripts/template-project.ps1 init -Check -OriginUrl https://github.com/OWNER/GAME.git -Destination D:\Games\GAME
  ./scripts/template-project.ps1 init -Apply -OriginUrl https://github.com/OWNER/GAME.git -Destination D:\Games\GAME
  ./scripts/template-project.ps1 init -Check -TemplateUrl D:\Templates\roblox_project_template -Destination D:\Games\LocalGame -TargetRef <full-commit-id>
  ./scripts/template-project.ps1 init -Apply -TemplateUrl D:\Templates\roblox_project_template -Destination D:\Games\LocalGame -TargetRef <full-commit-id>
  ./scripts/template-project.ps1 init -Check -RepositoryPath D:\Games\MyGame
  ./scripts/template-project.ps1 init -Apply -RepositoryPath D:\Games\MyGame
  ./scripts/template-project.ps1 update -Check -RepositoryPath D:\Games\MyGame -TargetRef refs/remotes/upstream/main
  ./scripts/template-project.ps1 update -Apply -RepositoryPath D:\Games\MyGame -TargetRef refs/remotes/upstream/main
  ./scripts/template-project.ps1 validate -RepositoryPath D:\Games\MyGame
#>
[CmdletBinding()]
param(
	[Parameter(Mandatory = $true, Position = 0)]
	[ValidateSet("init", "repair", "update", "validate")]
	[string]$Action,

	[Parameter(Mandatory = $true)]
	[Alias("Destination")]
	[string]$RepositoryPath,

	[switch]$Check,
	[switch]$Apply,

	[string]$TargetRef = "refs/remotes/upstream/main",

	[ValidateSet("Auto", "Template", "Project")]
	[string]$RepositoryRole = "Auto",

	[string]$OriginUrl,
	[string]$TemplateUrl = "https://github.com/teano/roblox_project_template.git",
	[switch]$Push
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:TemplateRepositoryPattern = '(?i)(?:^|[/:\\])roblox_project_template(?:\.git)?$'
$script:TemplatePlaceIds = @([Int64]91045933836846, [Int64]101736951773632)
$script:TemplateGameId = [Int64]10596427617
$script:ReservedProjectPrefixes = @(
	"docs/adr/project/",
	"docs/Features/project/",
	"src/ReplicatedStorage/Project/"
)
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-TextFile {
	param(
		[Parameter(Mandatory = $true)][string]$Path,
		[Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content
	)
	$parent = Split-Path -Parent $Path
	if (-not [string]::IsNullOrWhiteSpace($parent)) {
		[IO.Directory]::CreateDirectory($parent) | Out-Null
	}
	$temp = "$Path.tmp-$([Guid]::NewGuid().ToString('N'))"
	try {
		[IO.File]::WriteAllText($temp, $Content, $script:Utf8NoBom)
		Move-Item -LiteralPath $temp -Destination $Path -Force
	} finally {
		if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
	}
}

function Invoke-Git {
	param(
		[Parameter(Mandatory = $true)][string]$Root,
		[Parameter(Mandatory = $true)][string[]]$Arguments,
		[switch]$AllowFailure
	)
	$priorErrorAction = $ErrorActionPreference
	$ErrorActionPreference = "Continue"
	$output = @()
	$errorOutput = @()
	try {
		$records = @(& git -C $Root @Arguments 2>&1)
		$exitCode = $LASTEXITCODE
		foreach ($record in $records) {
			if ($record -is [System.Management.Automation.ErrorRecord]) {
				$errorOutput += [string]$record.Exception.Message
			} else {
				$output += [string]$record
			}
		}
	} finally {
		$ErrorActionPreference = $priorErrorAction
	}
	if ($exitCode -ne 0 -and -not $AllowFailure) {
		$detail = (@($output) + @($errorOutput) -join [Environment]::NewLine).Trim()
		if ([string]::IsNullOrWhiteSpace($detail)) { $detail = "git exited with code $exitCode" }
		throw "git $($Arguments -join ' ') failed in '$Root': $detail"
	}
	if ($exitCode -eq 0 -and $errorOutput.Count -gt 0) {
		$warning = ($errorOutput -join [Environment]::NewLine).Trim()
		if (-not [string]::IsNullOrWhiteSpace($warning)) { Write-Warning $warning }
	}
	return [PSCustomObject]@{ ExitCode = $exitCode; Output = @($output); Error = @($errorOutput) }
}

function Invoke-GitGlobal {
	param([string[]]$Arguments, [switch]$AllowFailure)
	$priorErrorAction = $ErrorActionPreference
	$ErrorActionPreference = "Continue"
	try {
		$output = @(& git @Arguments 2>&1 | ForEach-Object { [string]$_ })
		$exitCode = $LASTEXITCODE
	} finally {
		$ErrorActionPreference = $priorErrorAction
	}
	if ($exitCode -ne 0 -and -not $AllowFailure) { throw "git $($Arguments -join ' ') failed: $(($output -join ' ').Trim())" }
	return [PSCustomObject]@{ ExitCode = $exitCode; Output = @($output) }
}

function Resolve-RepositoryRoot {
	param([Parameter(Mandatory = $true)][string]$Path)
	if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
		throw "RepositoryPath does not exist or is not a directory: $Path"
	}
	$requested = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Path).Path).TrimEnd('\', '/')
	$result = Invoke-Git -Root $requested -Arguments @("rev-parse", "--show-toplevel")
	$root = [IO.Path]::GetFullPath(([string]$result.Output[0]).Trim()).TrimEnd('\', '/')
	if (-not $root.Equals($requested, [StringComparison]::OrdinalIgnoreCase)) {
		throw "RepositoryPath must name the repository root exactly. Resolved root: $root"
	}
	return $root
}

function Get-GitScalar {
	param([string]$Root, [string[]]$Arguments)
	$result = Invoke-Git -Root $Root -Arguments $Arguments
	if ($result.Output.Count -eq 0) { return "" }
	return ([string]$result.Output[0]).Trim()
}

function Get-ObjectProperty {
	param($Object, [string]$Name)
	if ($null -eq $Object) { return $null }
	return $Object.PSObject.Properties[$Name]
}

function Test-JsonObject {
	param($Value)
	if ($null -eq $Value) { return $false }
	return $Value -is [System.Collections.IDictionary] -or $Value.GetType().FullName -eq "System.Management.Automation.PSCustomObject"
}

function ConvertTo-CanonicalNode {
	param($Value)
	if ($null -eq $Value) { return $null }
	if ($Value -is [System.Array] -or $Value -is [System.Collections.IList]) {
		$result = @()
		foreach ($item in $Value) { $result += ,(ConvertTo-CanonicalNode $item) }
		return ,$result
	}
	if ($Value -is [System.Collections.IDictionary]) {
		$ordered = [ordered]@{}
		$keys = @($Value.Keys | ForEach-Object { [string]$_ })
		[Array]::Sort($keys, [StringComparer]::Ordinal)
		foreach ($key in $keys) { $ordered[$key] = ConvertTo-CanonicalNode $Value[$key] }
		return [PSCustomObject]$ordered
	}
	if (Test-JsonObject $Value) {
		$ordered = [ordered]@{}
		$names = @($Value.PSObject.Properties.Name)
		[Array]::Sort($names, [StringComparer]::Ordinal)
		foreach ($name in $names) { $ordered[$name] = ConvertTo-CanonicalNode $Value.$name }
		return [PSCustomObject]$ordered
	}
	return $Value
}

function ConvertTo-CanonicalJson {
	param($Value)
	return ((ConvertTo-CanonicalNode $Value) | ConvertTo-Json -Depth 100 -Compress)
}

function Test-StructuralEqual {
	param($Left, $Right)
	return (ConvertTo-CanonicalJson $Left).Equals((ConvertTo-CanonicalJson $Right), [StringComparison]::Ordinal)
}

function Read-JsonText {
	param([string]$Text, [string]$Label)
	try { return $Text | ConvertFrom-Json } catch { throw "$Label is not valid JSON: $($_.Exception.Message)" }
}

function Read-JsonFile {
	param([string]$Path, [string]$Label)
	if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "$Label is missing: $Path" }
	return Read-JsonText -Text ([IO.File]::ReadAllText($Path)) -Label $Label
}

function Test-ExactPositiveInteger {
	param($Value)
	if ($Value -isnot [byte] -and $Value -isnot [int16] -and $Value -isnot [int32] -and $Value -isnot [int64] -and $Value -isnot [uint16] -and $Value -isnot [uint32]) {
		return $false
	}
	$number = [Int64]$Value
	return $number -ge 1 -and $number -le [Int64]9007199254740991
}

function Assert-IdentityTuple {
	param($Configuration, [string]$Label, [switch]$AllowTemplateIdentity)
	$names = @("placeId", "gameId", "servePlaceIds")
	$present = @($names | Where-Object { $null -ne (Get-ObjectProperty $Configuration $_) })
	if ($present.Count -eq 0) { return "absent" }
	if ($present.Count -ne 3) {
		throw "$Label must contain either all of placeId, gameId, and servePlaceIds or none of them. Present: $($present -join ', ')."
	}
	if (-not (Test-ExactPositiveInteger $Configuration.placeId)) { throw "$Label placeId must be a positive exact JSON integer in 1..2^53-1." }
	if (-not (Test-ExactPositiveInteger $Configuration.gameId)) { throw "$Label gameId must be a positive exact JSON integer in 1..2^53-1." }
	if ($Configuration.servePlaceIds -isnot [System.Array]) { throw "$Label servePlaceIds must be a non-empty JSON array." }
	$seen = @{}
	$serve = @($Configuration.servePlaceIds)
	if ($serve.Count -eq 0) { throw "$Label servePlaceIds must not be empty." }
	foreach ($id in $serve) {
		if (-not (Test-ExactPositiveInteger $id)) { throw "$Label servePlaceIds entries must be positive exact JSON integers in 1..2^53-1." }
		$key = ([Int64]$id).ToString([Globalization.CultureInfo]::InvariantCulture)
		if ($seen.ContainsKey($key)) { throw "$Label servePlaceIds contains duplicate '$key'." }
		$seen[$key] = $true
	}
	$place = [Int64]$Configuration.placeId
	$game = [Int64]$Configuration.gameId
	if (-not $seen.ContainsKey($place.ToString([Globalization.CultureInfo]::InvariantCulture))) {
		throw "$Label servePlaceIds must contain placeId '$place'."
	}
	if (-not $AllowTemplateIdentity) {
		if ($place -in $script:TemplatePlaceIds -or @($serve | ForEach-Object { [Int64]$_ } | Where-Object { $_ -in $script:TemplatePlaceIds }).Count -gt 0) {
			throw "$Label reuses a non-inheritable template validation PlaceId."
		}
		if ($game -eq $script:TemplateGameId) { throw "$Label reuses the non-inheritable template validation GameId." }
	}
	return "present"
}

function Get-RepositoryRole {
	param([string]$Root, [string]$RequestedRole = "Auto")
	$remote = Invoke-Git -Root $Root -Arguments @("remote", "get-url", "upstream") -AllowFailure
	if ($RequestedRole -eq "Template") {
		if ($remote.ExitCode -eq 0) { throw "RepositoryRole Template is incompatible with a repository that has an upstream remote." }
		return "template"
	}
	if ($RequestedRole -eq "Project") {
		if ($remote.ExitCode -ne 0) { throw "RepositoryRole Project requires a template upstream remote." }
		$url = ([string]$remote.Output[0]).Trim()
		if ($url -notmatch $script:TemplateRepositoryPattern) { throw "Remote 'upstream' is not the Roblox template: $url" }
		return "project"
	}
	if ($remote.ExitCode -ne 0) {
		$origin = Invoke-Git -Root $Root -Arguments @("remote", "get-url", "origin") -AllowFailure
		if ($origin.ExitCode -eq 0 -and ([string]$origin.Output[0]).Trim() -match $script:TemplateRepositoryPattern) { return "template" }
		throw "Repository ownership is ambiguous: no template upstream and origin is not the canonical template. Pass -RepositoryRole Template only for a verified template checkout."
	}
	$url = ([string]$remote.Output[0]).Trim()
	if ($url -notmatch $script:TemplateRepositoryPattern) {
		throw "Remote 'upstream' is not the Roblox template and repository ownership is ambiguous: $url"
	}
	return "project"
}

function Assert-TargetRef {
	param([string]$Root, [string]$Ref)
	if ([string]::IsNullOrWhiteSpace($Ref)) { throw "TargetRef must name an already-fetched template commit." }
	$result = Invoke-Git -Root $Root -Arguments @("rev-parse", "--verify", "$Ref^{commit}") -AllowFailure
	if ($result.ExitCode -ne 0 -or $result.Output.Count -eq 0) {
		throw "TargetRef '$Ref' does not resolve to an already-fetched commit. Fetch the intended template remote and pass its exact ref."
	}
	$commit = ([string]$result.Output[0]).Trim()
	$upstreamRefs = Invoke-Git -Root $Root -Arguments @("for-each-ref", "--format=%(refname)", "refs/remotes/upstream/")
	$allowed = $false
	foreach ($upstreamRef in @($upstreamRefs.Output)) {
		$remoteRef = ([string]$upstreamRef).Trim()
		if ([string]::IsNullOrWhiteSpace($remoteRef) -or $remoteRef.EndsWith("/HEAD", [StringComparison]::Ordinal)) { continue }
		$reachable = Invoke-Git -Root $Root -Arguments @("merge-base", "--is-ancestor", $commit, $remoteRef) -AllowFailure
		if ($reachable.ExitCode -eq 0) { $allowed = $true; break }
	}
	if (-not $allowed) {
		throw "TargetRef '$Ref' resolves to '$commit', but that commit is not reachable from any fetched refs/remotes/upstream/* ref. Fetch the intended template remote and pass a trusted target."
	}
	return $commit
}

function Assert-NamedBranch {
	param([string]$Root)
	$result = Invoke-Git -Root $Root -Arguments @("symbolic-ref", "--quiet", "--short", "HEAD") -AllowFailure
	if ($result.ExitCode -ne 0 -or $result.Output.Count -eq 0) { throw "Template operations require a named current branch; detached HEAD is not supported." }
	return ([string]$result.Output[0]).Trim()
}

function Assert-CleanTrackedState {
	param([string]$Root)
	$unstaged = Invoke-Git -Root $Root -Arguments @("diff", "--quiet", "--ignore-submodules", "--") -AllowFailure
	if ($unstaged.ExitCode -ne 0) { throw "Tracked working-tree changes are present. Commit or explicitly shelve them before this operation." }
	$staged = Invoke-Git -Root $Root -Arguments @("diff", "--cached", "--quiet", "--ignore-submodules", "--") -AllowFailure
	if ($staged.ExitCode -ne 0) { throw "The Git index contains staged changes. Commit or explicitly unstage them before this operation." }
	$untracked = @(Invoke-Git -Root $Root -Arguments @("ls-files", "--others", "--exclude-standard") | Select-Object -ExpandProperty Output)
	if ($untracked.Count -gt 0) {
		throw "Untracked non-ignored paths make the operation unsafe: $($untracked -join ', ')"
	}
}

function Get-ChangedPaths {
	param([string]$Root, [string]$From, [string]$To)
	$result = Invoke-Git -Root $Root -Arguments @("diff", "--name-only", "--diff-filter=ACMRT", $From, $To)
	return @($result.Output | ForEach-Object { ([string]$_).Replace('\', '/') } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Assert-NoReservedIncomingPaths {
	param([string]$Root, [string]$From, [string]$To)
	$paths = Get-ChangedPaths -Root $Root -From $From -To $To
	$collisions = @()
	foreach ($path in $paths) {
		foreach ($prefix in $script:ReservedProjectPrefixes) {
			if ($path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { $collisions += $path; break }
		}
	}
	if ($collisions.Count -gt 0) {
		throw "Template target invades a reserved project-owned namespace: $($collisions -join ', '). Remove the collision upstream before updating a project."
	}
}

function Test-PathCollision {
	param([string]$Left, [string]$Right)
	$leftPath = $Left.TrimEnd('/')
	$rightPath = $Right.TrimEnd('/')
	return $leftPath.Equals($rightPath, [StringComparison]::OrdinalIgnoreCase) -or
		$leftPath.StartsWith($rightPath + "/", [StringComparison]::OrdinalIgnoreCase) -or
		$rightPath.StartsWith($leftPath + "/", [StringComparison]::OrdinalIgnoreCase)
}

function Assert-NoIgnoredIncomingCollision {
	param([string]$Root, [string]$From, [string]$To)
	$incoming = Get-ChangedPaths -Root $Root -From $From -To $To
	$ignored = @((Invoke-Git -Root $Root -Arguments @("ls-files", "--others", "-i", "--exclude-standard")).Output | ForEach-Object { ([string]$_).Replace('\', '/') })
	$collisions = @()
	foreach ($ignoredPath in $ignored) {
		foreach ($incomingPath in $incoming) {
			if (Test-PathCollision -Left $ignoredPath -Right $incomingPath) { $collisions += "$ignoredPath <-> $incomingPath"; break }
		}
	}
	if ($collisions.Count -gt 0) {
		throw "Ignored local content collides with incoming tracked template paths: $($collisions -join ', '). Move or remove only the named local paths before retrying."
	}
}

function Get-GitText {
	param([string]$Root, [string]$Revision, [string]$Path)
	$result = Invoke-Git -Root $Root -Arguments @("show", "$Revision`:$Path") -AllowFailure
	if ($result.ExitCode -ne 0) { throw "'$Path' is missing at '$Revision'." }
	return (($result.Output -join "`n") + "`n")
}

function Get-ThreeWayValue {
	param($Base, $Local, $Incoming, [string]$Path)
	if (Test-StructuralEqual $Local $Base) { return $Incoming }
	if (Test-StructuralEqual $Incoming $Base) { return $Local }
	if (Test-StructuralEqual $Local $Incoming) { return $Local }

	if ((Test-JsonObject $Base) -and (Test-JsonObject $Local) -and (Test-JsonObject $Incoming)) {
		$names = @($Base.PSObject.Properties.Name + $Local.PSObject.Properties.Name + $Incoming.PSObject.Properties.Name | Select-Object -Unique)
		[Array]::Sort($names, [StringComparer]::Ordinal)
		$result = [ordered]@{}
		foreach ($name in $names) {
			$bp = Get-ObjectProperty $Base $name
			$lp = Get-ObjectProperty $Local $name
			$ip = Get-ObjectProperty $Incoming $name
			$b = if ($null -eq $bp) { [PSCustomObject]@{ __missing = $true } } else { $bp.Value }
			$l = if ($null -eq $lp) { [PSCustomObject]@{ __missing = $true } } else { $lp.Value }
			$i = if ($null -eq $ip) { [PSCustomObject]@{ __missing = $true } } else { $ip.Value }
			$value = Get-ThreeWayValue -Base $b -Local $l -Incoming $i -Path "$Path.$name"
			if (-not (Test-JsonObject $value) -or $null -eq (Get-ObjectProperty $value "__missing")) { $result[$name] = $value }
		}
		return [PSCustomObject]$result
	}
	throw "default.project.json has a concurrent three-way conflict at '$Path'. Reconcile that value explicitly before updating."
}

function Get-MergedProjectConfiguration {
	param($Base, $Local, $Incoming)
	Assert-IdentityTuple -Configuration $Local -Label "Local default.project.json" | Out-Null
	Assert-IdentityTuple -Configuration $Incoming -Label "Incoming template default.project.json" -AllowTemplateIdentity | Out-Null
	$special = @("name", "servePort", "placeId", "gameId", "servePlaceIds")
	$projected = @()
	foreach ($configuration in @($Base, $Local, $Incoming)) {
		$copy = [ordered]@{}
		foreach ($property in $configuration.PSObject.Properties) {
			if ($property.Name -notin $special) { $copy[$property.Name] = $property.Value }
		}
		$projected += ,[PSCustomObject]$copy
	}
	$merged = Get-ThreeWayValue -Base $projected[0] -Local $projected[1] -Incoming $projected[2] -Path '$'

	# Project-owned fields are applied as one policy outside the structural merge.
	$nameProperty = Get-ObjectProperty $Local "name"
	if ($null -eq $nameProperty -or [string]::IsNullOrWhiteSpace([string]$nameProperty.Value)) { throw "Local default.project.json must contain a non-empty project name." }
	$merged | Add-Member -NotePropertyName name -NotePropertyValue ([string]$nameProperty.Value)
	$portProperty = Get-ObjectProperty $Local "servePort"
	if ($null -ne $portProperty) { $merged | Add-Member -NotePropertyName servePort -NotePropertyValue $portProperty.Value }

	$identityState = Assert-IdentityTuple -Configuration $Local -Label "Local default.project.json"
	if ($identityState -eq "present") {
		$merged | Add-Member -NotePropertyName placeId -NotePropertyValue $Local.placeId
		$merged | Add-Member -NotePropertyName gameId -NotePropertyValue $Local.gameId
		$merged | Add-Member -NotePropertyName servePlaceIds -NotePropertyValue @($Local.servePlaceIds)
	}
	Assert-IdentityTuple -Configuration $merged -Label "Merged default.project.json" | Out-Null
	return $merged
}

function Format-ProjectJson {
	param($Configuration)
	# Canonical ordering is structural, not a copy of either side.
	return ((ConvertTo-CanonicalNode $Configuration | ConvertTo-Json -Depth 100) -replace "`r`n", "`n").TrimEnd() + "`n"
}

function Get-FileSha256 {
	param([string]$Path)
	if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return "missing" }
	return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Test-ByteArraysEqual {
	param([byte[]]$Left, [byte[]]$Right)
	if ($Left.Length -ne $Right.Length) { return $false }
	for ($index = 0; $index -lt $Left.Length; $index += 1) {
		if ($Left[$index] -ne $Right[$index]) { return $false }
	}
	return $true
}

function Invoke-RojoBuildValidation {
	param([string]$Root)
	$rojo = Get-Command rojo -ErrorAction SilentlyContinue
	if ($null -eq $rojo) { throw "Rojo is required to validate a newly initialized project but was not found on PATH." }
	$outputPath = Join-Path ([IO.Path]::GetTempPath()) ("template-project-init-{0}.rbxlx" -f [Guid]::NewGuid().ToString("N"))
	$priorErrorAction = $ErrorActionPreference
	$ErrorActionPreference = "Continue"
	try {
		$output = @(& $rojo.Source build (Join-Path $Root "default.project.json") --output $outputPath 2>&1 | ForEach-Object { [string]$_ })
		$exitCode = $LASTEXITCODE
		if ($exitCode -ne 0) { throw "Rojo validation build failed: $($output -join ' ')" }
		if (-not (Test-Path -LiteralPath $outputPath -PathType Leaf) -or (Get-Item -LiteralPath $outputPath).Length -eq 0) { throw "Rojo validation build did not produce a non-empty output." }
	} finally {
		$ErrorActionPreference = $priorErrorAction
		if (Test-Path -LiteralPath $outputPath) { Remove-Item -LiteralPath $outputPath -Force }
	}
	Write-Output "ROJO BUILD VALID repository=$Root"
}

function Assert-DerivedRepository {
	param([string]$Root)
	if ((Get-RepositoryRole -Root $Root) -ne "project") { throw "This operation requires a derived repository with upstream pointing to roblox_project_template." }
	$origin = Invoke-Git -Root $Root -Arguments @("remote", "get-url", "origin") -AllowFailure
	if ($origin.ExitCode -ne 0) { throw "Derived repository must have an origin remote for the game repository." }
}

function Assert-UpstreamContainsNoReservedProjectNamespace {
	param([string]$Root, [string]$TargetCommit)
	$paths = @((Invoke-Git -Root $Root -Arguments @("ls-tree", "-r", "--name-only", $TargetCommit)).Output)
	$collisions = @()
	foreach ($pathValue in $paths) {
		$path = ([string]$pathValue).Replace('\', '/')
		foreach ($prefix in $script:ReservedProjectPrefixes) {
			if ($path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { $collisions += $path; break }
		}
	}
	if ($collisions.Count -gt 0) { throw "TargetRef contains reserved project-owned paths: $($collisions -join ', ')." }
}

function Test-GitPathEqual {
	param([string]$Root, [string]$LeftRevision, [string]$RightRevision, [string]$Path)
	$left = Invoke-Git -Root $Root -Arguments @("rev-parse", "$LeftRevision`:$Path") -AllowFailure
	$right = Invoke-Git -Root $Root -Arguments @("rev-parse", "$RightRevision`:$Path") -AllowFailure
	return $left.ExitCode -eq 0 -and $right.ExitCode -eq 0 -and ([string]$left.Output[0]).Trim().Equals(([string]$right.Output[0]).Trim(), [StringComparison]::Ordinal)
}

function Get-ProjectReadme {
	param([string]$Name, [string]$TemplateCommit)
	$content = @"
# $Name

Roblox project derived from ``roblox_project_template``.

## Local development

``````powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/ensure-rojo-server.ps1
``````

The canonical Studio scene is ``place.rbxl``. Update the project from the
already-fetched template ref with ``scripts/template-project.ps1 update``.

Template baseline: ``$TemplateCommit``.
"@
	$normalized = $content.Replace("`r`n", "`n").Replace("`r", "`n")
	return $normalized.TrimEnd([char[]]"`n") + "`n"
}

function Assert-InitializedStructure {
	param([string]$Root, [switch]$RequireEmptyUiConfig)
	Assert-DerivedRepository -Root $Root
	$configPath = Join-Path $Root "default.project.json"
	$config = Read-JsonFile -Path $configPath -Label "default.project.json"
	if ($null -eq (Get-ObjectProperty $config "name") -or [string]::IsNullOrWhiteSpace([string]$config.name)) { throw "default.project.json name must be a non-empty project-owned Rojo identity." }
	$servePortProperty = Get-ObjectProperty $config "servePort"
	if ($null -ne $servePortProperty) {
		$servePort = $servePortProperty.Value
		if ($servePort -isnot [int16] -and $servePort -isnot [int32] -and $servePort -isnot [int64]) { throw "Existing legacy servePort must be an integer in 1..65535." }
		if ([int64]$servePort -lt 1 -or [int64]$servePort -gt 65535) { throw "Existing legacy servePort must be in 1..65535." }
	}
	Assert-IdentityTuple -Configuration $config -Label "default.project.json" | Out-Null
	foreach ($required in @(
		"README.md",
		"place.rbxl",
		"scripts/ensure-rojo-server.ps1",
		"src/ServerScriptService/Bootstrap.server.luau",
		"src/StarterPlayerScripts/Bootstrap.client.luau",
		"src/ReplicatedStorage/Project/Client/UI/DerivedWindowConfig.luau"
	)) {
		if (-not (Test-Path -LiteralPath (Join-Path $Root $required) -PathType Leaf)) { throw "Initialized project is missing '$required'." }
	}
	$uiConfigPath = Join-Path $Root "src/ReplicatedStorage/Project/Client/UI/DerivedWindowConfig.luau"
	$uiBytes = [IO.File]::ReadAllBytes($uiConfigPath)
	if ($uiBytes.Length -ge 3 -and $uiBytes[0] -eq 0xEF -and $uiBytes[1] -eq 0xBB -and $uiBytes[2] -eq 0xBF) { throw "DerivedWindowConfig.luau must be UTF-8 without BOM." }
	$uiText = [Text.Encoding]::UTF8.GetString($uiBytes).Replace("`r`n", "`n").Replace("`r", "`n")
	if ($RequireEmptyUiConfig) {
		if (-not $uiText.Equals("--!strict`n`nreturn table.freeze({})`n", [StringComparison]::Ordinal)) {
			throw "DerivedWindowConfig.luau must use the exact initialized strict frozen-empty-table shape."
		}
	} elseif (-not $uiText.StartsWith("--!strict`n", [StringComparison]::Ordinal) -or $uiText -notmatch '(?s)\breturn\s+table\.freeze\s*\(\s*\{.*\}\s*\)\s*$') {
		throw "DerivedWindowConfig.luau must remain strict and return one frozen sequence; focused UI authoring validation owns entry details."
	}
	$trackedPlace = Invoke-Git -Root $Root -Arguments @("ls-files", "--error-unmatch", "place.rbxl") -AllowFailure
	if ($trackedPlace.ExitCode -ne 0) { throw "Canonical place.rbxl must remain tracked." }
	return $config
}

function Assert-TemplateStructure {
	param([string]$Root)
	$config = Read-JsonFile -Path (Join-Path $Root "default.project.json") -Label "default.project.json"
	if (-not ([string]$config.name).Equals("roblox_project_template", [StringComparison]::Ordinal)) { throw "Template default.project.json name must be 'roblox_project_template'." }
	Assert-IdentityTuple -Configuration $config -Label "template default.project.json" -AllowTemplateIdentity | Out-Null
	if ([Int64]$config.placeId -ne $script:TemplatePlaceIds[0] -or [Int64]$config.gameId -ne $script:TemplateGameId) {
		throw "Template default.project.json must use the canonical template placeId/gameId."
	}
	$serveSet = @($config.servePlaceIds | ForEach-Object { [Int64]$_ } | Sort-Object)
	$templateSet = @($script:TemplatePlaceIds | Sort-Object)
	if ($serveSet.Count -ne $templateSet.Count -or -not (($serveSet -join ',').Equals(($templateSet -join ','), [StringComparison]::Ordinal))) {
		throw "Template default.project.json servePlaceIds must be exactly the canonical template validation set."
	}
	foreach ($required in @(
		"README.md",
		"place.rbxl",
		"docs/Features/template/README.md",
		"scripts/ensure-rojo-server.ps1",
		"src/ServerScriptService/Bootstrap.server.luau",
		"src/StarterPlayerScripts/Bootstrap.client.luau"
	)) {
		if (-not (Test-Path -LiteralPath (Join-Path $Root $required) -PathType Leaf)) { throw "Template repository is missing '$required'." }
	}
	foreach ($reserved in @("docs/adr/project", "docs/Features/project", "src/ReplicatedStorage/Project")) {
		if (Test-Path -LiteralPath (Join-Path $Root $reserved)) { throw "Template repository must not contain project-owned namespace '$reserved'." }
	}
	$trackedPlace = Invoke-Git -Root $Root -Arguments @("ls-files", "--error-unmatch", "place.rbxl") -AllowFailure
	if ($trackedPlace.ExitCode -ne 0) { throw "Canonical place.rbxl must remain tracked." }
	return $config
}

function Assert-ChangedPathSourceBoundaries {
	param([string]$Root, [string]$BaseRef, [string]$CandidateBase)
	$tracked = @((Invoke-Git -Root $Root -Arguments @("ls-files")).Output | ForEach-Object { ([string]$_).Replace('\', '/') })
	$generated = @($tracked | Where-Object {
		$relative = $_
		$denied = $relative -match '(?i)(^|/)sourcemap\.json$' -or
			$relative -match '(?i)\.rbxlx$' -or
			$relative -match '(?i)\.rbxl\.lock$' -or
			$relative -match '(?i)(^|/)\.agentic-pipeline[^/]*(/|$)'
		$denied -and (Test-Path -LiteralPath (Join-Path $Root ($relative.Replace('/', [IO.Path]::DirectorySeparatorChar))))
	})
	if ($generated.Count -gt 0) { throw "Generated validation/runtime files must not be tracked: $($generated -join ', ')." }

	$changed = @()
	$queries = if (-not [string]::IsNullOrWhiteSpace($CandidateBase)) {
		@(
			@("diff", "--name-only", $CandidateBase),
			@("ls-files", "--others", "--exclude-standard")
		)
	} else {
		@(
			@("diff", "--name-only", $BaseRef, "HEAD"),
			@("diff", "--name-only"),
			@("diff", "--cached", "--name-only", $BaseRef),
			@("ls-files", "--others", "--exclude-standard")
		)
	}
	foreach ($arguments in $queries) {
		$changed += @((Invoke-Git -Root $Root -Arguments $arguments).Output | ForEach-Object { ([string]$_).Replace('\', '/') })
	}
	$changed = @($changed | Select-Object -Unique)
	$executableTests = @($changed | Where-Object {
		$_ -match '(?i)(^|/)(Tests?|QA)(/|$)' -and $_ -match '(?i)\.(server|client)\.luau$'
	})
	if ($executableTests.Count -gt 0) { throw "Changed test/QA paths must not use executable .server/.client placement: $($executableTests -join ', ')." }

	$sourceFiles = @($changed | Where-Object { $_.StartsWith("src/", [StringComparison]::Ordinal) -and $_.EndsWith(".luau", [StringComparison]::OrdinalIgnoreCase) })
	foreach ($relative in $sourceFiles) {
		$path = Join-Path $Root ($relative.Replace('/', [IO.Path]::DirectorySeparatorChar))
		if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
		$content = [IO.File]::ReadAllText($path)
		$isTest = $relative -match '(?i)(^|/)(Tests?|TestFixtures|QA)(/|$)'
		if (-not $isTest -and $content -match '[:.]PreloadAsync\s*\(' -and -not $relative.Equals("src/ReplicatedStorage/Shared/ContentPreloading/ContentPreloader.luau", [StringComparison]::Ordinal)) {
			throw "Changed production path calls PreloadAsync outside ContentPreloader: $relative"
		}
		$directRemote = $content -match 'Instance\.new\s*\(\s*["'']Remote(?:Event|Function)["'']\s*\)' -or $content -match '[:.](?:FireServer|FireClient|FireAllClients|InvokeServer|InvokeClient)\s*\('
		if (($relative -match '(?i)AudioManualQa|(^|/)Bootstrap\.(server|client)\.luau$') -and $directRemote) {
			throw "Changed AudioManualQa/bootstrap path contains a direct remote call: $relative"
		}
		if (-not $isTest -and $relative -match '(?i)Teleport' -and ($directRemote -or $content -match 'game\s*:\s*GetService\s*\(\s*["'']Players["'']\s*\)' -or $content -match '\.(?:PlayerAdded|PlayerRemoving)\s*:\s*Connect\s*\(')) {
			throw "Changed Teleport path contains direct Players/remotes access: $relative"
		}
		if (-not $isTest -and $relative -match '(?i)(^|/)Audio/' -and $directRemote) {
			throw "Changed Audio production path contains a direct remote call: $relative"
		}
		if (-not $isTest -and $relative -match '(?i)(^|/)Audio/' -and $content -match '\.AcousticSimulationEnabled\s*=' -and $relative -notin @(
			"src/ReplicatedStorage/Client/Audio/AudioGraphClient.luau",
			"src/ReplicatedStorage/Shared/Audio/AudioPlaybackWrapper.luau"
		)) {
			throw "Changed Audio path writes AcousticSimulationEnabled outside its two property owners: $relative"
		}
	}
}

function Invoke-Init {
	param([string]$Root, [bool]$DoApply, [string]$Ref)
	Assert-DerivedRepository -Root $Root
	Assert-NamedBranch -Root $Root | Out-Null
	Assert-CleanTrackedState -Root $Root
	$targetCommit = Assert-TargetRef -Root $Root -Ref $Ref
	Assert-UpstreamContainsNoReservedProjectNamespace -Root $Root -TargetCommit $targetCommit
	$ancestor = Invoke-Git -Root $Root -Arguments @("merge-base", "--is-ancestor", $targetCommit, "HEAD") -AllowFailure
	if ($ancestor.ExitCode -ne 0) {
		throw "TargetRef '$Ref' is not contained in HEAD. For a legacy target README/bootstrap, merge that exact fetched template history first, then rerun init with the same TargetRef."
	}
	$currentConfig = Read-JsonFile -Path (Join-Path $Root "default.project.json") -Label "default.project.json"
	$currentIdentity = Assert-IdentityTuple -Configuration $currentConfig -Label "default.project.json" -AllowTemplateIdentity
	$currentName = [string]$currentConfig.name
	$usesTemplateIdentity = $currentIdentity -eq "present" -and (
		[Int64]$currentConfig.placeId -in $script:TemplatePlaceIds -or [Int64]$currentConfig.gameId -eq $script:TemplateGameId
	)
	if (-not $currentName.Equals("roblox_project_template", [StringComparison]::Ordinal) -and -not $usesTemplateIdentity) {
		throw "Project already has derived identity in default.project.json. Use validate or update instead."
	}

	$name = Split-Path -Leaf $Root
	$configPath = Join-Path $Root "default.project.json"
	$config = Read-JsonFile -Path $configPath -Label "default.project.json"
	$targetConfig = Read-JsonText -Text (Get-GitText -Root $Root -Revision $targetCommit -Path "default.project.json") -Label "TargetRef default.project.json"
	$localPortProperty = Get-ObjectProperty $config "servePort"
	$targetPortProperty = Get-ObjectProperty $targetConfig "servePort"
	$preserveLocalPort = $null -ne $localPortProperty -and (
		$null -eq $targetPortProperty -or -not (Test-StructuralEqual $localPortProperty.Value $targetPortProperty.Value)
	)
	foreach ($propertyName in @("name", "servePort", "placeId", "gameId", "servePlaceIds")) {
		if ($null -ne (Get-ObjectProperty $config $propertyName)) { $config.PSObject.Properties.Remove($propertyName) }
	}
	$config | Add-Member -NotePropertyName name -NotePropertyValue $name
	if ($preserveLocalPort) { $config | Add-Member -NotePropertyName servePort -NotePropertyValue $localPortProperty.Value }
	$configText = Format-ProjectJson -Configuration $config
	$readmeIsTemplate = Test-GitPathEqual -Root $Root -LeftRevision "HEAD" -RightRevision $targetCommit -Path "README.md"
	$uiConfigPath = Join-Path $Root "src/ReplicatedStorage/Project/Client/UI/DerivedWindowConfig.luau"
	$uiConfigExists = Test-Path -LiteralPath $uiConfigPath -PathType Leaf
	$uiConfigBytes = if ($uiConfigExists) { [IO.File]::ReadAllBytes($uiConfigPath) } else { $null }
	if ($uiConfigExists) {
		$existingUiText = [Text.Encoding]::UTF8.GetString($uiConfigBytes).Replace("`r`n", "`n").Replace("`r", "`n")
		if (($uiConfigBytes.Length -ge 3 -and $uiConfigBytes[0] -eq 0xEF -and $uiConfigBytes[1] -eq 0xBB -and $uiConfigBytes[2] -eq 0xBF) -or -not $existingUiText.StartsWith("--!strict`n", [StringComparison]::Ordinal) -or $existingUiText -notmatch '(?s)\breturn\s+table\.freeze\s*\(\s*\{.*\}\s*\)\s*$') {
			throw "Existing DerivedWindowConfig.luau is not a valid strict frozen-sequence project UI config; refusing to overwrite it."
		}
	}

	Write-Output "INIT PLAN repository=$Root target=$targetCommit name=$name"
	Write-Output "  default.project.json: set name; strip inherited identity/servePort; preserve only an existing project-custom servePort"
	Write-Output "  README.md: $(if ($readmeIsTemplate) { 'replace template README' } else { 'preserve existing project README byte-for-byte' })"
	Write-Output "  place.rbxl: preserve byte-for-byte"
	Write-Output "  $(if ($uiConfigExists) { 'preserve the existing valid project UI config byte-for-byte' } else { 'create the required strict empty project UI config' }); ADR and feature namespaces remain optional"
	if (-not $DoApply) { return }

	$placeHash = Get-FileSha256 (Join-Path $Root "place.rbxl")
	$readmeHash = Get-FileSha256 (Join-Path $Root "README.md")
	$configBytes = [IO.File]::ReadAllBytes($configPath)
	$readmePath = Join-Path $Root "README.md"
	$readmeBytes = [IO.File]::ReadAllBytes($readmePath)
	$preHead = Get-GitScalar -Root $Root -Arguments @("rev-parse", "HEAD")
	$preIndex = Get-GitScalar -Root $Root -Arguments @("write-tree")
	try {
		Write-TextFile -Path $configPath -Content $configText
		if ($readmeIsTemplate) { Write-TextFile -Path $readmePath -Content (Get-ProjectReadme -Name $name -TemplateCommit $targetCommit) }
		if (-not $uiConfigExists) { Write-TextFile -Path $uiConfigPath -Content "--!strict`n`nreturn table.freeze({})`n" }
		Assert-InitializedStructure -Root $Root -RequireEmptyUiConfig:(-not $uiConfigExists) | Out-Null
		if ((Get-FileSha256 (Join-Path $Root "place.rbxl")) -ne $placeHash) { throw "Initialization changed place.rbxl unexpectedly." }
		if (-not $readmeIsTemplate -and (Get-FileSha256 $readmePath) -ne $readmeHash) { throw "Initialization changed the existing project README unexpectedly." }
		Invoke-RojoBuildValidation -Root $Root
	} catch {
		$failure = $_
		[IO.File]::WriteAllBytes($configPath, $configBytes)
		[IO.File]::WriteAllBytes($readmePath, $readmeBytes)
		if ($uiConfigExists) { [IO.File]::WriteAllBytes($uiConfigPath, $uiConfigBytes) } elseif (Test-Path -LiteralPath $uiConfigPath) { Remove-Item -LiteralPath $uiConfigPath -Force }
		$postHead = Get-GitScalar -Root $Root -Arguments @("rev-parse", "HEAD")
		$postIndex = Get-GitScalar -Root $Root -Arguments @("write-tree")
		$postStatus = @((Invoke-Git -Root $Root -Arguments @("status", "--porcelain", "--untracked-files=all")).Output)
		if (-not $postHead.Equals($preHead, [StringComparison]::Ordinal) -or -not $postIndex.Equals($preIndex, [StringComparison]::Ordinal) -or $postStatus.Count -gt 0) {
			throw "Initialization failed and rollback did not restore exact HEAD/index/tree. preHead=$preHead postHead=$postHead preIndex=$preIndex postIndex=$postIndex status=$($postStatus -join '; '). Cause: $($failure.Exception.Message)"
		}
		throw "Initialization failed; exact pre-state was restored. preHead=$preHead preIndex=$preIndex. Cause: $($failure.Exception.Message)"
	}
	Write-Output "INIT APPLIED. Review and commit the project-owned initialization files when ready. No push was performed."
}

function Invoke-Repair {
	param([string]$Root, [bool]$DoApply, [string]$Ref)
	Assert-DerivedRepository -Root $Root
	Assert-NamedBranch -Root $Root | Out-Null
	Assert-CleanTrackedState -Root $Root
	$targetCommit = Assert-TargetRef -Root $Root -Ref $Ref
	Assert-UpstreamContainsNoReservedProjectNamespace -Root $Root -TargetCommit $targetCommit
	$configPath = Join-Path $Root "default.project.json"
	$config = Read-JsonFile -Path $configPath -Label "default.project.json"
	if ($null -eq (Get-ObjectProperty $config "name") -or [string]::IsNullOrWhiteSpace([string]$config.name) -or ([string]$config.name).Equals("roblox_project_template", [StringComparison]::Ordinal)) {
		throw "repair requires an existing project-owned non-template Rojo name. Use init for an untouched template checkout."
	}
	Assert-IdentityTuple -Configuration $config -Label "default.project.json" | Out-Null
	$port = Get-ObjectProperty $config "servePort"
	if ($null -ne $port -and (($port.Value -isnot [int16] -and $port.Value -isnot [int32] -and $port.Value -isnot [int64]) -or [int64]$port.Value -lt 1 -or [int64]$port.Value -gt 65535)) {
		throw "Existing project servePort must be an integer in 1..65535."
	}
	$uiPath = Join-Path $Root "src/ReplicatedStorage/Project/Client/UI/DerivedWindowConfig.luau"
	if (Test-Path -LiteralPath $uiPath) { throw "Required DerivedWindowConfig.luau already exists. Use validate or update; repair never overwrites it." }
	foreach ($required in @("README.md", "place.rbxl", "scripts/ensure-rojo-server.ps1", "src/ServerScriptService/Bootstrap.server.luau", "src/StarterPlayerScripts/Bootstrap.client.luau")) {
		if (-not (Test-Path -LiteralPath (Join-Path $Root $required) -PathType Leaf)) { throw "Compatibility repair cannot proceed because '$required' is missing." }
	}
	Write-Output "REPAIR PLAN repository=$Root target=$targetCommit create=src/ReplicatedStorage/Project/Client/UI/DerivedWindowConfig.luau"
	Write-Output "  preserve name, identity tuple, servePort, README.md, place.rbxl, and all existing project namespaces exactly"
	if (-not $DoApply) { return }
	$preHead = Get-GitScalar -Root $Root -Arguments @("rev-parse", "HEAD")
	$preIndex = Get-GitScalar -Root $Root -Arguments @("write-tree")
	$configHash = Get-FileSha256 $configPath
	$readmeHash = Get-FileSha256 (Join-Path $Root "README.md")
	$placeHash = Get-FileSha256 (Join-Path $Root "place.rbxl")
	try {
		Write-TextFile -Path $uiPath -Content "--!strict`n`nreturn table.freeze({})`n"
		Assert-InitializedStructure -Root $Root -RequireEmptyUiConfig | Out-Null
		if ((Get-FileSha256 $configPath) -ne $configHash -or (Get-FileSha256 (Join-Path $Root "README.md")) -ne $readmeHash -or (Get-FileSha256 (Join-Path $Root "place.rbxl")) -ne $placeHash) {
			throw "Compatibility repair changed a protected project-owned file."
		}
		Invoke-RojoBuildValidation -Root $Root
	} catch {
		$failure = $_
		if (Test-Path -LiteralPath $uiPath) { Remove-Item -LiteralPath $uiPath -Force }
		$postHead = Get-GitScalar -Root $Root -Arguments @("rev-parse", "HEAD")
		$postIndex = Get-GitScalar -Root $Root -Arguments @("write-tree")
		$status = @((Invoke-Git -Root $Root -Arguments @("status", "--porcelain", "--untracked-files=all")).Output)
		if (-not $postHead.Equals($preHead, [StringComparison]::Ordinal) -or -not $postIndex.Equals($preIndex, [StringComparison]::Ordinal) -or $status.Count -gt 0) {
			throw "Repair failed and rollback did not restore exact pre-state. Cause: $($failure.Exception.Message)"
		}
		throw "Repair failed; exact pre-state was restored. Cause: $($failure.Exception.Message)"
	}
	Write-Output "REPAIR APPLIED. Commit the new project-owned UI config when ready. No push was performed."
}

function Test-IsGitRepository {
	param([string]$Path)
	if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
	$result = Invoke-GitGlobal -Arguments @("-C", $Path, "rev-parse", "--show-toplevel") -AllowFailure
	return $result.ExitCode -eq 0
}

function Resolve-LocalTemplateRoot {
	param([string]$Path)
	if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Container)) {
		throw "Originless init requires -TemplateUrl to name an existing local template Git root exactly."
	}
	$requested = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Path).Path).TrimEnd('\', '/')
	$result = Invoke-Git -Root $requested -Arguments @("rev-parse", "--show-toplevel") -AllowFailure
	if ($result.ExitCode -ne 0 -or $result.Output.Count -eq 0) { throw "TemplateUrl is not a readable local Git checkout: $requested" }
	$root = [IO.Path]::GetFullPath(([string]$result.Output[0]).Trim()).TrimEnd('\', '/')
	if (-not $root.Equals($requested, [StringComparison]::OrdinalIgnoreCase)) {
		throw "TemplateUrl must name the local template Git root exactly. Resolved root: $root"
	}
	if ((Get-RepositoryRole -Root $root) -ne "template") { throw "TemplateUrl does not identify the canonical roblox_project_template checkout: $root" }
	return $root
}

function Resolve-ExactCommitId {
	param([string]$Root, [string]$Ref)
	if ([string]::IsNullOrWhiteSpace($Ref) -or $Ref -notmatch '^[0-9a-fA-F]{40}$') {
		throw "Originless init requires TargetRef as an explicit full 40-character commit ID."
	}
	$result = Invoke-Git -Root $Root -Arguments @("rev-parse", "--verify", "$Ref^{commit}") -AllowFailure
	if ($result.ExitCode -ne 0 -or $result.Output.Count -eq 0) { throw "TargetRef '$Ref' does not resolve to a commit in the local template checkout." }
	$commit = ([string]$result.Output[0]).Trim()
	if (-not $commit.Equals($Ref, [StringComparison]::OrdinalIgnoreCase)) { throw "TargetRef '$Ref' is not the exact commit ID '$commit'." }
	return $commit
}

function Assert-OriginlessDestination {
	param([string]$Path)
	$full = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
	$parent = Split-Path -Parent $full
	$leaf = Split-Path -Leaf $full
	if ([string]::IsNullOrWhiteSpace($parent) -or [string]::IsNullOrWhiteSpace($leaf) -or -not (Test-Path -LiteralPath $parent -PathType Container)) {
		throw "Destination must have an existing parent directory and a non-empty leaf name: $full"
	}
	$exists = Test-Path -LiteralPath $full
	if ($exists) {
		if (-not (Test-Path -LiteralPath $full -PathType Container)) { throw "Destination exists and is not a directory: $full" }
		$entries = @(Get-ChildItem -LiteralPath $full -Force)
		if ($entries.Count -gt 0) { throw "Destination must be absent or empty for originless init: $full" }
	}
	$probe = if ($exists) { $full } else { $parent }
	$git = Invoke-GitGlobal -Arguments @("-C", $probe, "rev-parse", "--show-toplevel") -AllowFailure
	if ($git.ExitCode -eq 0) { throw "Destination must be outside every Git worktree for originless init. Resolved containing root: $(([string]$git.Output[0]).Trim())" }
	return [PSCustomObject]@{ Path = $full; Parent = $parent; Leaf = $leaf; Existed = [bool]$exists }
}

function Assert-PlainTemplateTarget {
	param([string]$Root, [string]$Commit)
	$config = Read-JsonText -Text (Get-GitText -Root $Root -Revision $Commit -Path "default.project.json") -Label "TargetRef default.project.json"
	if ($null -eq (Get-ObjectProperty $config "name") -or -not ([string]$config.name).Equals("roblox_project_template", [StringComparison]::Ordinal)) {
		throw "TargetRef default.project.json is not the canonical template configuration."
	}
	Assert-IdentityTuple -Configuration $config -Label "TargetRef default.project.json" -AllowTemplateIdentity | Out-Null
	Assert-UpstreamContainsNoReservedProjectNamespace -Root $Root -TargetCommit $Commit
	foreach ($required in @(
		"README.md",
		"place.rbxl",
		"scripts/ensure-rojo-server.ps1",
		"src/ServerScriptService/Bootstrap.server.luau",
		"src/StarterPlayerScripts/Bootstrap.client.luau"
	)) {
		$result = Invoke-Git -Root $Root -Arguments @("cat-file", "-e", "$Commit`:$required") -AllowFailure
		if ($result.ExitCode -ne 0) { throw "TargetRef is missing required tracked path '$required'." }
	}
}

function Assert-PlainInitializedStructure {
	param([string]$Root, [string]$ExpectedName)
	if (Test-Path -LiteralPath (Join-Path $Root ".git")) { throw "Originless project staging must not contain .git." }
	$config = Read-JsonFile -Path (Join-Path $Root "default.project.json") -Label "default.project.json"
	if ($null -eq (Get-ObjectProperty $config "name") -or -not ([string]$config.name).Equals($ExpectedName, [StringComparison]::Ordinal)) {
		throw "Originless project name must equal destination leaf '$ExpectedName'."
	}
	foreach ($propertyName in @("placeId", "gameId", "servePlaceIds", "servePort")) {
		if ($null -ne (Get-ObjectProperty $config $propertyName)) { throw "Originless project must not inherit '$propertyName'." }
	}
	foreach ($required in @(
		"README.md",
		"place.rbxl",
		"scripts/ensure-rojo-server.ps1",
		"src/ServerScriptService/Bootstrap.server.luau",
		"src/StarterPlayerScripts/Bootstrap.client.luau",
		"src/ReplicatedStorage/Project/Client/UI/DerivedWindowConfig.luau"
	)) {
		if (-not (Test-Path -LiteralPath (Join-Path $Root $required) -PathType Leaf)) { throw "Originless project is missing '$required'." }
	}
	$uiPath = Join-Path $Root "src/ReplicatedStorage/Project/Client/UI/DerivedWindowConfig.luau"
	$uiBytes = [IO.File]::ReadAllBytes($uiPath)
	if ($uiBytes.Length -ge 3 -and $uiBytes[0] -eq 0xEF -and $uiBytes[1] -eq 0xBB -and $uiBytes[2] -eq 0xBF) { throw "DerivedWindowConfig.luau must be UTF-8 without BOM." }
	$uiText = [Text.Encoding]::UTF8.GetString($uiBytes).Replace("`r`n", "`n").Replace("`r", "`n")
	if (-not $uiText.Equals("--!strict`n`nreturn table.freeze({})`n", [StringComparison]::Ordinal)) {
		throw "DerivedWindowConfig.luau must use the exact initialized strict frozen-empty-table shape."
	}
}

function Assert-BootstrapScratchPath {
	param([string]$Path, [string]$Parent, [string]$Prefix)
	$full = [IO.Path]::GetFullPath($Path)
	$actualParent = [IO.Path]::GetFullPath((Split-Path -Parent $full)).TrimEnd('\', '/')
	$expectedParent = [IO.Path]::GetFullPath($Parent).TrimEnd('\', '/')
	$leaf = Split-Path -Leaf $full
	if (-not $actualParent.Equals($expectedParent, [StringComparison]::OrdinalIgnoreCase) -or -not $leaf.StartsWith($Prefix, [StringComparison]::Ordinal)) {
		throw "Refusing unsafe originless init scratch path: $full"
	}
}

function Invoke-OriginlessProjectBootstrap {
	param([string]$DestinationPath, [string]$TemplateSource, [bool]$DoApply, [bool]$DoPush, [string]$Ref)
	if ($DoPush) { throw "Originless init never commits or pushes; omit -Push." }
	$destination = Assert-OriginlessDestination -Path $DestinationPath
	$templateRoot = Resolve-LocalTemplateRoot -Path $TemplateSource
	$targetCommit = Resolve-ExactCommitId -Root $templateRoot -Ref $Ref
	Assert-PlainTemplateTarget -Root $templateRoot -Commit $targetCommit
	Write-Output "ORIGINLESS INIT PLAN destination=$($destination.Path) template=$templateRoot target=$targetCommit name=$($destination.Leaf)"
	Write-Output "  export exact tracked target snapshot; strip cloud identity and servePort; generate README and empty DerivedWindowConfig; create no Git metadata"
	if (-not $DoApply) { return }

	$token = [Guid]::NewGuid().ToString("N")
	$scratchPrefix = ".$($destination.Leaf).template-init-"
	$staging = Join-Path $destination.Parent "$scratchPrefix$token"
	$archive = Join-Path $destination.Parent "$scratchPrefix$token.zip"
	$backup = Join-Path $destination.Parent "$scratchPrefix$token.empty"
	foreach ($scratch in @($staging, $archive, $backup)) { Assert-BootstrapScratchPath -Path $scratch -Parent $destination.Parent -Prefix $scratchPrefix }
	$destinationMoved = $false
	$published = $false
	try {
		[IO.Directory]::CreateDirectory($staging) | Out-Null
		Invoke-Git -Root $templateRoot -Arguments @("-c", "core.autocrlf=false", "archive", "--format=zip", "--output=$archive", $targetCommit) | Out-Null
		Add-Type -AssemblyName System.IO.Compression.FileSystem
		[IO.Compression.ZipFile]::ExtractToDirectory($archive, $staging)
		[IO.File]::Delete($archive)
		$placeHash = Get-FileSha256 (Join-Path $staging "place.rbxl")
		$configPath = Join-Path $staging "default.project.json"
		$config = Read-JsonFile -Path $configPath -Label "TargetRef default.project.json"
		foreach ($propertyName in @("name", "placeId", "gameId", "servePlaceIds", "servePort")) {
			if ($null -ne (Get-ObjectProperty $config $propertyName)) { $config.PSObject.Properties.Remove($propertyName) }
		}
		$config | Add-Member -NotePropertyName name -NotePropertyValue $destination.Leaf
		Write-TextFile -Path $configPath -Content (Format-ProjectJson -Configuration $config)
		Write-TextFile -Path (Join-Path $staging "README.md") -Content (Get-ProjectReadme -Name $destination.Leaf -TemplateCommit $targetCommit)
		Write-TextFile -Path (Join-Path $staging "src/ReplicatedStorage/Project/Client/UI/DerivedWindowConfig.luau") -Content "--!strict`n`nreturn table.freeze({})`n"
		Assert-PlainInitializedStructure -Root $staging -ExpectedName $destination.Leaf
		if ((Get-FileSha256 (Join-Path $staging "place.rbxl")) -ne $placeHash) { throw "Originless initialization changed place.rbxl unexpectedly." }
		Invoke-RojoBuildValidation -Root $staging

		if ($destination.Existed) {
			[IO.Directory]::Move($destination.Path, $backup)
			$destinationMoved = $true
		}
		[IO.Directory]::Move($staging, $destination.Path)
		$published = $true
		if ($destinationMoved) { [IO.Directory]::Delete($backup, $false) }
	} catch {
		$failure = $_
		try {
			if ($published -and (Test-Path -LiteralPath $destination.Path -PathType Container)) { [IO.Directory]::Delete($destination.Path, $true) }
			if ($destinationMoved -and (Test-Path -LiteralPath $backup -PathType Container)) { [IO.Directory]::Move($backup, $destination.Path) }
			if (Test-Path -LiteralPath $staging -PathType Container) { [IO.Directory]::Delete($staging, $true) }
			if (Test-Path -LiteralPath $archive -PathType Leaf) { [IO.File]::Delete($archive) }
			if (Test-Path -LiteralPath $backup) { [IO.Directory]::Delete($backup, $true) }
			$restored = if ($destination.Existed) {
				(Test-Path -LiteralPath $destination.Path -PathType Container) -and @(Get-ChildItem -LiteralPath $destination.Path -Force).Count -eq 0
			} else { -not (Test-Path -LiteralPath $destination.Path) }
			if (-not $restored) { throw "Destination was not restored to its exact absent/empty pre-state." }
		} catch {
			throw "Originless initialization failed and cleanup could not restore the destination. Cause: $($failure.Exception.Message) Cleanup: $($_.Exception.Message)"
		}
		throw "Originless initialization failed; destination was restored exactly. Cause: $($failure.Exception.Message)"
	}
	Write-Output "ORIGINLESS INIT APPLIED destination=$($destination.Path) target=$targetCommit. No Git repository, commit, remote, or push was created."
}

function Assert-BootstrapDestination {
	param([string]$Path)
	$full = [IO.Path]::GetFullPath($Path)
	if (Test-Path -LiteralPath $full) {
		if (-not (Test-Path -LiteralPath $full -PathType Container)) { throw "Destination exists and is not a directory: $full" }
		$entries = @(Get-ChildItem -LiteralPath $full -Force)
		if ($entries.Count -gt 0) { throw "Destination is non-empty and is not an existing prepared Git checkout: $full" }
	} else {
		$parent = Split-Path -Parent $full
		if ([string]::IsNullOrWhiteSpace($parent) -or -not (Test-Path -LiteralPath $parent -PathType Container)) { throw "Destination parent directory does not exist: $parent" }
	}
	return $full
}

function Invoke-NewProjectBootstrap {
	param([string]$DestinationPath, [string]$TargetOrigin, [string]$TemplateSource, [bool]$DoApply, [bool]$DoPush, [string]$Ref)
	if ([string]::IsNullOrWhiteSpace($TargetOrigin)) { throw "New-project bootstrap requires -OriginUrl." }
	if ([string]::IsNullOrWhiteSpace($TemplateSource)) { throw "New-project bootstrap requires -TemplateUrl." }
	if ($DoPush -and -not $DoApply) { throw "-Push requires init -Apply." }
	$destination = Assert-BootstrapDestination -Path $DestinationPath
	$originHeads = Invoke-GitGlobal -Arguments @("ls-remote", $TargetOrigin) -AllowFailure
	if ($originHeads.ExitCode -ne 0) { throw "Cannot inspect target OriginUrl '$TargetOrigin': $($originHeads.Output -join ' ')" }
	if ($originHeads.Output.Count -gt 0) { throw "OriginUrl is not empty. Automatic bootstrap currently refuses non-empty target history; use a reviewed prepared checkout." }
	$templateMain = Invoke-GitGlobal -Arguments @("ls-remote", "--heads", $TemplateSource, "refs/heads/main") -AllowFailure
	if ($templateMain.ExitCode -ne 0 -or $templateMain.Output.Count -eq 0) { throw "TemplateUrl has no readable refs/heads/main: $TemplateSource" }
	Write-Output "BOOTSTRAP PLAN destination=$destination origin=$TargetOrigin template=$TemplateSource targetRef=$Ref push=$DoPush"
	if (-not $DoApply) { return }

	$createdByThisRun = $false
	try {
		$createdByThisRun = $true
		$clone = Invoke-GitGlobal -Arguments @("-c", "core.autocrlf=false", "clone", "--quiet", $TemplateSource, $destination) -AllowFailure
		if ($clone.ExitCode -ne 0) { throw "Template clone failed: $($clone.Output -join ' ')" }
		Invoke-Git -Root $destination -Arguments @("remote", "rename", "origin", "upstream") | Out-Null
		Invoke-Git -Root $destination -Arguments @("remote", "add", "origin", $TargetOrigin) | Out-Null
		Invoke-Init -Root $destination -DoApply $true -Ref $Ref
		if ($DoPush) {
			Invoke-Git -Root $destination -Arguments @("add", "-A") | Out-Null
			Invoke-Git -Root $destination -Arguments @("-c", "user.name=Template Project Tool", "-c", "user.email=template-project@example.invalid", "commit", "-m", "Initialize project from Roblox template") | Out-Null
			Invoke-Git -Root $destination -Arguments @("push", "-u", "origin", "HEAD:main") | Out-Null
			Write-Output "BOOTSTRAP PUSHED origin/main."
		} else {
			Write-Output "BOOTSTRAP APPLIED. No commit or push was performed; use -Push only when explicitly authorized."
		}
	} catch {
		$failure = $_
		if ($createdByThisRun -and (Test-Path -LiteralPath $destination -PathType Container)) {
			$parent = [IO.Path]::GetFullPath((Split-Path -Parent $destination)).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
			$resolved = [IO.Path]::GetFullPath($destination)
			if ($resolved.StartsWith($parent, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolved).Length -gt 0) {
				Remove-Item -LiteralPath $resolved -Recurse -Force
			}
		}
		throw $failure
	}
}

function Invoke-Update {
	param([string]$Root, [bool]$DoApply, [string]$Ref)
	Assert-InitializedStructure -Root $Root | Out-Null
	$branch = Assert-NamedBranch -Root $Root
	Assert-CleanTrackedState -Root $Root
	$targetCommit = Assert-TargetRef -Root $Root -Ref $Ref
	Assert-UpstreamContainsNoReservedProjectNamespace -Root $Root -TargetCommit $targetCommit
	$head = Get-GitScalar -Root $Root -Arguments @("rev-parse", "HEAD")
	$already = Invoke-Git -Root $Root -Arguments @("merge-base", "--is-ancestor", $targetCommit, $head) -AllowFailure
	if ($already.ExitCode -eq 0) { Write-Output "UPDATE CURRENT repository=$Root target=$targetCommit"; return }
	$base = Get-GitScalar -Root $Root -Arguments @("merge-base", $head, $targetCommit)
	if ([string]::IsNullOrWhiteSpace($base)) { throw "HEAD and TargetRef have no merge base. Complete the documented legacy bootstrap merge before update." }
	Assert-NoReservedIncomingPaths -Root $Root -From $base -To $targetCommit
	Assert-NoIgnoredIncomingCollision -Root $Root -From $base -To $targetCommit

	$baseConfig = Read-JsonText -Text (Get-GitText -Root $Root -Revision $base -Path "default.project.json") -Label "merge-base default.project.json"
	$localConfig = Read-JsonText -Text (Get-GitText -Root $Root -Revision $head -Path "default.project.json") -Label "local default.project.json"
	$incomingConfig = Read-JsonText -Text (Get-GitText -Root $Root -Revision $targetCommit -Path "default.project.json") -Label "incoming default.project.json"
	$mergedConfig = Get-MergedProjectConfiguration -Base $baseConfig -Local $localConfig -Incoming $incomingConfig
	$configIsStructurallyUnchanged = Test-StructuralEqual $mergedConfig $localConfig
	$mergedText = if ($configIsStructurallyUnchanged) { $null } else { Format-ProjectJson -Configuration $mergedConfig }
	$rootPrefix = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
	$snapshotPaths = @()
	$seenSnapshotPaths = @{}
	$targetDelta = Invoke-Git -Root $Root -Arguments @("diff", "--name-only", "--no-renames", $base, $targetCommit, "--")
	foreach ($candidate in @($targetDelta.Output) + @("README.md", "place.rbxl", "default.project.json")) {
		$relative = ([string]$candidate).Replace('\', '/')
		$segments = @($relative.Split('/'))
		if ([string]::IsNullOrWhiteSpace($relative) -or [IO.Path]::IsPathRooted($relative) -or @($segments | Where-Object { [string]::IsNullOrWhiteSpace($_) -or $_ -eq "." -or $_ -eq ".." }).Count -gt 0) {
			throw "Template target contains an unsafe update path: '$relative'."
		}
		$fullPath = [IO.Path]::GetFullPath((Join-Path $Root ($relative.Replace('/', [IO.Path]::DirectorySeparatorChar))))
		if (-not $fullPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Template target path escapes the repository root: '$relative'." }
		if (-not $seenSnapshotPaths.ContainsKey($relative)) {
			$seenSnapshotPaths[$relative] = $true
			$snapshotPaths += ,[PSCustomObject]@{ RelativePath = $relative; FullPath = $fullPath }
		}
	}
	$preIndex = Get-GitScalar -Root $Root -Arguments @("write-tree")

	Write-Output "UPDATE PLAN repository=$Root branch=$branch base=$base from=$head target=$targetCommit"
	Write-Output "  preserve exact README.md and place.rbxl"
	Write-Output "  reconcile default.project.json with a true three-way structural merge"
	Write-Output "  preserve only local name, local complete identity tuple, and an already-existing local servePort"
	if (-not $DoApply) { return }
	$pathSnapshot = @()
	$snapshotByPath = @{}
	foreach ($path in $snapshotPaths) {
		$exists = Test-Path -LiteralPath $path.FullPath
		if ($exists -and -not (Test-Path -LiteralPath $path.FullPath -PathType Leaf)) { throw "Update snapshot path is not a file: '$($path.RelativePath)'." }
		$bytes = if ($exists) { [IO.File]::ReadAllBytes($path.FullPath) } else { $null }
		$entry = [PSCustomObject]@{ RelativePath = $path.RelativePath; FullPath = $path.FullPath; Existed = [bool]$exists; Bytes = $bytes }
		$pathSnapshot += ,$entry
		$snapshotByPath[$path.RelativePath] = $entry
	}

	$success = $false
	$failure = $null
	try {
		$merge = Invoke-Git -Root $Root -Arguments @("merge", "--no-commit", "--no-ff", $targetCommit) -AllowFailure
		$unmerged = @((Invoke-Git -Root $Root -Arguments @("diff", "--name-only", "--diff-filter=U")).Output | ForEach-Object { ([string]$_).Replace('\', '/') })
		$unexpected = @($unmerged | Where-Object { $_ -notin @("README.md", "place.rbxl", "default.project.json") })
		if ($unexpected.Count -gt 0) { throw "Template merge has unresolved non-protected conflicts: $($unexpected -join ', '). Resolve their ownership before retrying." }
		if ($merge.ExitCode -ne 0 -and $unmerged.Count -eq 0) { throw "git merge failed before producing resolvable protected-path conflicts: $($merge.Output -join ' ')" }

		foreach ($protected in @("README.md", "place.rbxl")) {
			$protectedSnapshot = $snapshotByPath[$protected]
			if ($null -eq $protectedSnapshot -or -not $protectedSnapshot.Existed) { throw "Protected update path '$protected' was not present in the pre-update snapshot." }
			Invoke-Git -Root $Root -Arguments @("restore", "--source=$head", "--staged", "--", $protected) | Out-Null
			[IO.File]::WriteAllBytes($protectedSnapshot.FullPath, [byte[]]$protectedSnapshot.Bytes)
			Invoke-Git -Root $Root -Arguments @("add", "--", $protected) | Out-Null
		}
		if ($configIsStructurallyUnchanged) {
			$configSnapshot = $snapshotByPath["default.project.json"]
			if ($null -eq $configSnapshot -or -not $configSnapshot.Existed) { throw "Protected update path 'default.project.json' was not present in the pre-update snapshot." }
			Invoke-Git -Root $Root -Arguments @("restore", "--source=$head", "--staged", "--", "default.project.json") | Out-Null
			[IO.File]::WriteAllBytes($configSnapshot.FullPath, [byte[]]$configSnapshot.Bytes)
			Invoke-Git -Root $Root -Arguments @("update-index", "--refresh", "--", "default.project.json") | Out-Null
		} else {
			Write-TextFile -Path (Join-Path $Root "default.project.json") -Content $mergedText
			Invoke-Git -Root $Root -Arguments @("add", "--", "default.project.json") | Out-Null
		}
		$remaining = @((Invoke-Git -Root $Root -Arguments @("diff", "--name-only", "--diff-filter=U")).Output)
		if ($remaining.Count -gt 0) { throw "Template merge still has unresolved paths: $($remaining -join ', ')." }
		foreach ($protected in @("README.md", "place.rbxl")) {
			$protectedSnapshot = $snapshotByPath[$protected]
			if (-not (Test-Path -LiteralPath $protectedSnapshot.FullPath -PathType Leaf) -or -not (Test-ByteArraysEqual -Left ([IO.File]::ReadAllBytes($protectedSnapshot.FullPath)) -Right ([byte[]]$protectedSnapshot.Bytes))) {
				throw "Template update did not preserve $protected byte-exactly."
			}
		}
		$actualConfig = Read-JsonFile -Path (Join-Path $Root "default.project.json") -Label "merged default.project.json"
		if (-not (Test-StructuralEqual $actualConfig $mergedConfig)) { throw "Staged default.project.json differs structurally from the computed three-way result." }
		Assert-InitializedStructure -Root $Root | Out-Null
		Assert-ChangedPathSourceBoundaries -Root $Root -CandidateBase $head

		Invoke-Git -Root $Root -Arguments @("commit", "--no-edit") | Out-Null
		$success = $true
		$postHead = "<receipt unavailable>"
		$postIndex = "<receipt unavailable>"
		try { $postHead = Get-GitScalar -Root $Root -Arguments @("rev-parse", "HEAD") } catch { Write-Warning "Update committed, but post-commit HEAD receipt failed: $($_.Exception.Message)" }
		try { $postIndex = Get-GitScalar -Root $Root -Arguments @("write-tree") } catch { Write-Warning "Update committed, but post-commit index receipt failed: $($_.Exception.Message)" }
		Write-Output "UPDATE APPLIED preHead=$head postHead=$postHead preIndex=$preIndex postIndex=$postIndex target=$targetCommit"
		Write-Output "No push was performed."
	} catch {
		$failure = $_
	} finally {
		if (-not $success) {
			$rollbackIssues = @()
			Invoke-Git -Root $Root -Arguments @("merge", "--abort") -AllowFailure | Out-Null
			foreach ($entry in $pathSnapshot) {
				try {
					if ($entry.Existed) {
						if (Test-Path -LiteralPath $entry.FullPath -PathType Container) { Remove-Item -LiteralPath $entry.FullPath -Recurse -Force }
						$parent = Split-Path -Parent $entry.FullPath
						if (-not [string]::IsNullOrWhiteSpace($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
						[IO.File]::WriteAllBytes($entry.FullPath, [byte[]]$entry.Bytes)
					} elseif (Test-Path -LiteralPath $entry.FullPath) {
						Remove-Item -LiteralPath $entry.FullPath -Recurse -Force
					}
				} catch {
					$rollbackIssues += "restore '$($entry.RelativePath)': $($_.Exception.Message)"
				}
			}
			foreach ($entry in $pathSnapshot) {
				if (-not $entry.Existed) { continue }
				try {
					Invoke-Git -Root $Root -Arguments @("add", "--", $entry.RelativePath) | Out-Null
				} catch {
					$rollbackIssues += "refresh index '$($entry.RelativePath)': $($_.Exception.Message)"
				}
			}
			foreach ($entry in $pathSnapshot) {
				try {
					if ($entry.Existed) {
						if (-not (Test-Path -LiteralPath $entry.FullPath -PathType Leaf) -or -not (Test-ByteArraysEqual -Left ([IO.File]::ReadAllBytes($entry.FullPath)) -Right ([byte[]]$entry.Bytes))) {
							$rollbackIssues += "verify '$($entry.RelativePath)': bytes or existence differ"
						}
					} elseif (Test-Path -LiteralPath $entry.FullPath) {
						$rollbackIssues += "verify '$($entry.RelativePath)': path should be absent"
					}
				} catch {
					$rollbackIssues += "verify '$($entry.RelativePath)': $($_.Exception.Message)"
				}
			}
			$postAbortHead = "<unavailable>"
			$postAbortIndex = "<unavailable>"
			$status = @("<unavailable>")
			try { $postAbortHead = Get-GitScalar -Root $Root -Arguments @("rev-parse", "HEAD") } catch { $rollbackIssues += "HEAD receipt: $($_.Exception.Message)" }
			try { $postAbortIndex = Get-GitScalar -Root $Root -Arguments @("write-tree") } catch { $rollbackIssues += "index receipt: $($_.Exception.Message)" }
			try { $status = @((Invoke-Git -Root $Root -Arguments @("status", "--porcelain", "--untracked-files=all")).Output) } catch { $rollbackIssues += "status receipt: $($_.Exception.Message)" }
			$mergeState = Invoke-Git -Root $Root -Arguments @("rev-parse", "--verify", "-q", "MERGE_HEAD") -AllowFailure
			if ($mergeState.ExitCode -eq 0) { $rollbackIssues += "MERGE_HEAD remains after merge --abort" }
			if (-not $postAbortHead.Equals($head, [StringComparison]::Ordinal)) { $rollbackIssues += "HEAD differs: pre=$head post=$postAbortHead" }
			if (-not $postAbortIndex.Equals($preIndex, [StringComparison]::Ordinal)) { $rollbackIssues += "index differs: pre=$preIndex post=$postAbortIndex" }
			if ($status.Count -gt 0) { $rollbackIssues += "status is not clean: $($status -join '; ')" }
			$failureMessage = if ($null -eq $failure) { "unknown update failure" } else { $failure.Exception.Message }
			if ($rollbackIssues.Count -gt 0) {
				throw "Update failed and exact rollback verification failed. issues=$($rollbackIssues -join ' | ') Original error: $failureMessage"
			}
			throw "Update failed; merge was aborted and exact pre-state was restored. preHead=$head postHead=$postAbortHead preIndex=$preIndex postIndex=$postAbortIndex. Cause: $failureMessage"
		}
	}
}

$normalizedAction = $Action.ToLowerInvariant()
if ($normalizedAction -ne "init" -and (-not [string]::IsNullOrWhiteSpace($OriginUrl) -or $Push)) {
	throw "-OriginUrl and -Push are valid only with init."
}
if ($normalizedAction -eq "init" -and -not (Test-IsGitRepository -Path $RepositoryPath)) {
	if (($Check -and $Apply) -or (-not $Check -and -not $Apply)) { throw "init requires exactly one of -Check or -Apply." }
	if (-not [string]::IsNullOrWhiteSpace($OriginUrl)) {
		Invoke-NewProjectBootstrap -DestinationPath $RepositoryPath -TargetOrigin $OriginUrl -TemplateSource $TemplateUrl -DoApply ([bool]$Apply) -DoPush ([bool]$Push) -Ref $TargetRef
	} else {
		Invoke-OriginlessProjectBootstrap -DestinationPath $RepositoryPath -TemplateSource $TemplateUrl -DoApply ([bool]$Apply) -DoPush ([bool]$Push) -Ref $TargetRef
	}
	exit 0
}

$root = Resolve-RepositoryRoot -Path $RepositoryPath
if ($normalizedAction -eq "init" -and -not [string]::IsNullOrWhiteSpace($OriginUrl)) {
	$actualOrigin = Get-GitScalar -Root $root -Arguments @("remote", "get-url", "origin")
	if (-not $actualOrigin.Equals($OriginUrl, [StringComparison]::OrdinalIgnoreCase)) { throw "Prepared checkout origin '$actualOrigin' does not match requested OriginUrl '$OriginUrl'." }
}
if ($Push) { throw "-Push is supported only for a new-project bootstrap into an empty destination, not a prepared checkout." }
if ($normalizedAction -eq "validate") {
	if ($Check -or $Apply) { throw "validate accepts neither -Check nor -Apply; it is always read-only." }
	$role = Get-RepositoryRole -Root $root -RequestedRole $RepositoryRole
	if ($role -eq "template") {
		$config = Assert-TemplateStructure -Root $root
		$targetCommit = Get-GitScalar -Root $root -Arguments @("rev-parse", "HEAD")
	} else {
		$config = Assert-InitializedStructure -Root $root
		$targetCommit = Assert-TargetRef -Root $root -Ref $TargetRef
		Assert-UpstreamContainsNoReservedProjectNamespace -Root $root -TargetCommit $targetCommit
	}
	Assert-ChangedPathSourceBoundaries -Root $root -BaseRef $targetCommit
	Write-Output "VALID repository=$root role=$role target=$targetCommit identity=$(Assert-IdentityTuple -Configuration $config -Label 'default.project.json' -AllowTemplateIdentity:($role -eq 'template'))"
	exit 0
}

if (($Check -and $Apply) -or (-not $Check -and -not $Apply)) {
	throw "$normalizedAction requires exactly one of -Check or -Apply."
}

if ($normalizedAction -eq "init") {
	Invoke-Init -Root $root -DoApply ([bool]$Apply) -Ref $TargetRef

} elseif ($normalizedAction -eq "repair") {
	Invoke-Repair -Root $root -DoApply ([bool]$Apply) -Ref $TargetRef
} else {
	Invoke-Update -Root $root -DoApply ([bool]$Apply) -Ref $TargetRef
}
