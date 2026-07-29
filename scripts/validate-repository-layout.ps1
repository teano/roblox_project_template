[CmdletBinding()]
param(
	[string]$TargetRepositoryRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repositoryRoot = if ([string]::IsNullOrWhiteSpace($TargetRepositoryRoot)) {
	(Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
} else {
	(Resolve-Path -LiteralPath $TargetRepositoryRoot).Path
}
$failures = [System.Collections.Generic.List[string]]::new()

function Add-Failure {
	param([string]$Message)
	$failures.Add($Message)
}

function Test-AdrIndex {
	param(
		[string]$ScopeName,
		[string]$Directory,
		[string]$IndexPath,
		[bool]$IndexRequired
	)

	if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
		if ($IndexRequired) {
			Add-Failure "$ScopeName ADR directory is missing: $Directory"
		}
		return
	}

	$decisionFiles = @(
		Get-ChildItem -LiteralPath $Directory -File |
			Where-Object { $_.Name -match '^\d{4}-.+\.md$' }
	)
	$indexExists = Test-Path -LiteralPath $IndexPath -PathType Leaf

	if ($IndexRequired -and -not $indexExists) {
		Add-Failure "$ScopeName ADR index is missing: $IndexPath"
		return
	}

	if (-not $indexExists) {
		if ($decisionFiles.Count -gt 0) {
			Add-Failure "$ScopeName ADR files exist without their own README.md index."
		}
		return
	}

	$indexContent = Get-Content -LiteralPath $IndexPath -Raw
	foreach ($decisionFile in $decisionFiles) {
		$link = "($($decisionFile.Name))"
		if (-not $indexContent.Contains($link)) {
			Add-Failure "$ScopeName ADR index does not reference $($decisionFile.Name)."
		}
	}

	$linkMatches = [regex]::Matches(
		$indexContent,
		'\]\((\d{4}-[^)]+\.md)\)'
	)
	foreach ($linkMatch in $linkMatches) {
		$linkedPath = Join-Path $Directory $linkMatch.Groups[1].Value
		if (-not (Test-Path -LiteralPath $linkedPath -PathType Leaf)) {
			Add-Failure "$ScopeName ADR index references a missing file: $linkedPath"
		}
	}
}

function Test-TemplateDivergenceDocumentation {
	param(
		[string]$RepositoryRoot,
		[string]$ProjectAdrDirectory
	)

	$upstreamRefs = @(
		& git -C $RepositoryRoot for-each-ref `
			--format="%(refname)" refs/remotes/upstream/main
	)
	if ($upstreamRefs.Count -eq 0) {
		Add-Failure (
			"Derived repository has no upstream/main ref. Fetch upstream before " +
			"validating template divergence."
		)
		return
	}

	$mergeBaseOutput = @(
		& git -C $RepositoryRoot merge-base HEAD refs/remotes/upstream/main
	)
	if ($LASTEXITCODE -ne 0 -or $mergeBaseOutput.Count -eq 0) {
		$gitDirectory = (
			& git -C $RepositoryRoot rev-parse --absolute-git-dir
		).Trim()
		$mergeHeadPath = Join-Path $gitDirectory "MERGE_HEAD"
		if (Test-Path -LiteralPath $mergeHeadPath -PathType Leaf) {
			$mergeBase = "refs/remotes/upstream/main"
		} else {
			Add-Failure (
				"Derived repository does not share history with upstream/main. " +
				"Start the reviewed initial merge before validating."
			)
			return
		}
	} else {
		$mergeBase = $mergeBaseOutput[0].Trim()
	}

	$templatePaths = @{}
	$baselinePaths = @(
		& git -C $RepositoryRoot ls-tree -r --name-only $mergeBase
	)
	$upstreamPaths = @(
		& git -C $RepositoryRoot ls-tree -r --name-only refs/remotes/upstream/main
	)
	foreach ($path in @($baselinePaths) + @($upstreamPaths)) {
		$templatePaths[$path] = $true
	}

	$projectAdrFiles = @(
		Get-ChildItem -LiteralPath $ProjectAdrDirectory -File |
			Where-Object { $_.Name -match '^\d{4}-.+\.md$' }
	)
	$projectAdrDocuments = @(
		foreach ($adrFile in $projectAdrFiles) {
			$content = Get-Content -LiteralPath $adrFile.FullName -Raw
			[PSCustomObject]@{
				Path = $adrFile.FullName
				Name = $adrFile.Name
				Content = $content
				IsActiveAccepted = [regex]::IsMatch(
					$content,
					'(?m)^- Status:\s*Accepted\s*$'
				) -and [regex]::IsMatch(
					$content,
					'(?m)^- Superseded by:\s*None\s*$'
				)
			}
		}
	)

	$activePathOwners = @{}
	foreach ($document in $projectAdrDocuments | Where-Object {
		$_.IsActiveAccepted
	}) {
		$divergenceSection = [regex]::Match(
			$document.Content,
			'(?ms)^## Template divergence\s*\r?\n(?<Body>.*?)(?=^## |\z)'
		)
		if (-not $divergenceSection.Success) {
			continue
		}

		$pathsBlock = [regex]::Match(
			$divergenceSection.Groups["Body"].Value,
			'(?m)^- Paths:[ \t]*\r?\n' +
				'(?<Paths>(?:[ \t]+- `[^`\r\n]+`[ \t]*\r?\n?)+)'
		)
		if (-not $pathsBlock.Success) {
			continue
		}

		foreach ($pathMatch in [regex]::Matches(
			$pathsBlock.Groups["Paths"].Value,
			'`([^`]+)`'
		)) {
			$ownedPath = $pathMatch.Groups[1].Value
			if (-not $activePathOwners.ContainsKey($ownedPath)) {
				$activePathOwners[$ownedPath] = [System.Collections.Generic.List[string]]::new()
			}
			$activePathOwners[$ownedPath].Add($document.Name)
		}
	}

	foreach ($ownedPath in $activePathOwners.Keys) {
		$owners = $activePathOwners[$ownedPath]
		if ($owners.Count -gt 1) {
			Add-Failure (
				"Template divergence path has multiple active Accepted project " +
				"ADR owners: $ownedPath ($($owners -join ', '))"
			)
		}
	}

	$placeOwnershipAdr = @($activePathOwners["place.rbxl"])
	if (@($placeOwnershipAdr).Count -eq 0) {
		Add-Failure (
			"An active Accepted project ADR must document place.rbxl ownership " +
			"and upstream merge policy in a Template divergence section."
		)
	}

	$localChangedPaths = @(
		& git -C $RepositoryRoot diff --name-only $mergeBase --
	)
	foreach ($path in $localChangedPaths | Sort-Object -Unique) {
		if ($path.StartsWith("docs/adr/project/")) {
			continue
		}
		if (-not $templatePaths.ContainsKey($path)) {
			continue
		}

		if (-not $activePathOwners.ContainsKey($path)) {
			Add-Failure (
				"Locally changed template path is not documented in a project " +
				"ADR active Accepted Template divergence Paths list: $path"
			)
		}
	}
}

$canonicalPlace = Join-Path $repositoryRoot "place.rbxl"
$legacyPlace = Join-Path $repositoryRoot "template_place.rbxl"
if (-not (Test-Path -LiteralPath $canonicalPlace -PathType Leaf)) {
	Add-Failure "Canonical place.rbxl is missing."
}
if (Test-Path -LiteralPath $legacyPlace) {
	Add-Failure "Legacy template_place.rbxl must not exist."
}

$gitignorePath = Join-Path $repositoryRoot ".gitignore"
$gitignore = Get-Content -LiteralPath $gitignorePath -Raw
if (-not $gitignore.Contains("!/place.rbxl")) {
	Add-Failure ".gitignore must explicitly track /place.rbxl."
}

$routerPath = Join-Path $repositoryRoot "docs\adr\README.md"
$routerContent = Get-Content -LiteralPath $routerPath -Raw
if ([regex]::IsMatch($routerContent, '\]\((?:template/|project/)?\d{4}-')) {
	Add-Failure "The ADR router must not index individual decisions."
}

$adrRoot = Join-Path $repositoryRoot "docs\adr"
$rootDecisionFiles = @(
	Get-ChildItem -LiteralPath $adrRoot -File |
		Where-Object { $_.Name -match '^\d{4}-.+\.md$' }
)
if ($rootDecisionFiles.Count -gt 0) {
	Add-Failure "Numbered ADRs must live in the template or project namespace."
}

$templateDirectory = Join-Path $repositoryRoot "docs\adr\template"
$projectDirectory = Join-Path $repositoryRoot "docs\adr\project"
Test-AdrIndex `
	-ScopeName "Template" `
	-Directory $templateDirectory `
	-IndexPath (Join-Path $templateDirectory "README.md") `
	-IndexRequired $true

$remoteNames = @(& git -C $repositoryRoot remote)
$isDerivedRepository = $remoteNames -contains "upstream"
if ($isDerivedRepository) {
	Test-AdrIndex `
		-ScopeName "Project" `
		-Directory $projectDirectory `
		-IndexPath (Join-Path $projectDirectory "README.md") `
		-IndexRequired $true
	if (Test-Path -LiteralPath $projectDirectory -PathType Container) {
		Test-TemplateDivergenceDocumentation `
			-RepositoryRoot $repositoryRoot `
			-ProjectAdrDirectory $projectDirectory
	}
} elseif (Test-Path -LiteralPath $projectDirectory) {
	Add-Failure "The template repository must not contain docs/adr/project."
}

$projectConfigurationPath = Join-Path $repositoryRoot "default.project.json"
$projectConfiguration = Get-Content -LiteralPath $projectConfigurationPath -Raw |
	ConvertFrom-Json
$expectedRojoConnectionName = Split-Path -Leaf $repositoryRoot
if ($projectConfiguration.name -cne $expectedRojoConnectionName) {
	Add-Failure (
		"default.project.json name must match the repository directory: " +
		"'$expectedRojoConnectionName'."
	)
}

$servePortProperty = $projectConfiguration.PSObject.Properties["servePort"]
if ($null -ne $servePortProperty) {
	Add-Failure (
		"default.project.json must not define servePort; projects share Rojo's " +
		"default endpoint and switch the active server through the preflight."
	)
}

$rojoPreflightPath = Join-Path $repositoryRoot "scripts\ensure-rojo-server.ps1"
if (-not (Test-Path -LiteralPath $rojoPreflightPath -PathType Leaf)) {
	Add-Failure "scripts/ensure-rojo-server.ps1 is missing."
}

$agentsPath = Join-Path $repositoryRoot "AGENTS.md"
$agentsContent = Get-Content -LiteralPath $agentsPath -Raw
$rojoPreflightCommand = (
	"powershell -NoProfile -ExecutionPolicy Bypass -File " +
	"scripts/ensure-rojo-server.ps1"
)
if (-not $agentsContent.Contains($rojoPreflightCommand)) {
	Add-Failure "AGENTS.md must require the Rojo server preflight command."
}

$contentPreloaderImplementation = (
	"src/ReplicatedStorage/Shared/ContentPreloading/ContentPreloader.luau"
)
$directPreloadCalls = @(
	Get-ChildItem -LiteralPath (Join-Path $repositoryRoot "src") -Recurse -File -Filter "*.luau" |
		ForEach-Object {
			$relativePath = $_.FullName.Substring($repositoryRoot.Length + 1)
			$relativePath = $relativePath.Replace("\", "/")
			if (
				$relativePath -eq $contentPreloaderImplementation -or
				$relativePath.StartsWith("src/ServerScriptService/Tests/")
			) {
				return
			}
			$content = Get-Content -LiteralPath $_.FullName -Raw
			if ([regex]::IsMatch($content, ':PreloadAsync\s*\(')) {
				$relativePath
			}
		}
)
foreach ($directPreloadCall in $directPreloadCalls) {
	Add-Failure (
		"Production content preloading must route through ContentPreloader; " +
		"direct PreloadAsync call found in '$directPreloadCall'."
	)
}

if ($failures.Count -gt 0) {
	foreach ($failure in $failures) {
		Write-Error -Message $failure -ErrorAction Continue
	}
	exit 1
}

Write-Output "Repository layout validation passed."
