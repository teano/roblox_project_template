[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
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
			[PSCustomObject]@{
				Path = $adrFile.FullName
				Content = Get-Content -LiteralPath $adrFile.FullName -Raw
			}
		}
	)
	$placeOwnershipAdr = $projectAdrDocuments | Where-Object {
		$_.Content.Contains("## Template divergence") -and
		$_.Content.Contains('`place.rbxl`')
	}
	if (@($placeOwnershipAdr).Count -eq 0) {
		Add-Failure (
			"Project ADRs must document place.rbxl ownership and upstream " +
			"merge policy in a Template divergence section."
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

		$documentedPath = '`' + $path + '`'
		$owningAdr = $projectAdrDocuments | Where-Object {
			$_.Content.Contains("## Template divergence") -and
			$_.Content.Contains($documentedPath)
		}
		if (@($owningAdr).Count -eq 0) {
			Add-Failure (
				"Locally changed template path is not documented in a project " +
				"ADR Template divergence section: $path"
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

if ($failures.Count -gt 0) {
	foreach ($failure in $failures) {
		Write-Error $failure
	}
	exit 1
}

Write-Output "Repository layout validation passed."
