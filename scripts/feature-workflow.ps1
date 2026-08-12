param(
	[Parameter(Mandatory = $true)]
	[ValidateSet("Start", "Continue", "Pause", "Finish", "Context")]
	[string]$Action,

	[Parameter(Mandatory = $true)]
	[string]$Feature,

	[string]$Title,
	[string]$Slug,
	[string]$Summary,
	[string]$Decisions,
	[string]$NextStep,
	[string]$VerificationSummary,
	[string]$ReopenReason,
	[switch]$AdoptChanges
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "FeatureWorkflow.psm1") -Force -DisableNameChecking

function Assert-ActiveFeature {
	param($Manifest)
	if ($Manifest.status -ne "in_progress" -or $Manifest.activity -ne "active") {
		throw "Feature '$($Manifest.id)' is not active."
	}
}

function Assert-FeatureActionContext {
	param(
		[Parameter(Mandatory = $true)]$Record,
		[Parameter(Mandatory = $true)][string]$RepositoryRoot,
		[Parameter(Mandatory = $true)][string]$CurrentBranch
	)

	$recordedBranch = [string]$Record.Manifest.branch
	if (-not $recordedBranch.Equals($CurrentBranch, [StringComparison]::Ordinal)) {
		throw "Feature '$($Record.Manifest.id)' belongs to branch '$recordedBranch', not '$CurrentBranch'."
	}
	Assert-NoOtherFeatureOnBranch `
		-RepositoryRoot $RepositoryRoot `
		-Branch $CurrentBranch `
		-ExceptId $Record.Manifest.id
	Assert-FeatureWriterLease `
		-RepositoryRoot $RepositoryRoot `
		-Branch $CurrentBranch `
		-FeatureId $Record.Manifest.id | Out-Null
}

function New-ServiceArtifacts {
	param(
		[Parameter(Mandatory = $true)][string]$Directory,
		[Parameter(Mandatory = $true)]$Manifest
	)
	$handoff = Join-Path $Directory "handoff.md"
	if (-not (Test-Path -LiteralPath $handoff -PathType Leaf)) {
		$featureLabel = "$($Manifest.id) $($Manifest.title)"
		$blockerText = if (@($Manifest.blockers).Count -eq 0) {
			"None."
		} else {
			(@($Manifest.blockers) | ForEach-Object { "- $_" }) -join [Environment]::NewLine
		}
		Write-Utf8NoBom -Path $handoff -Content @"
# Feature handoff

- Feature: $featureLabel
- Status: $($Manifest.status) / $($Manifest.activity)

## Result and current state

Feature work has started; no durable checkpoint has been recorded yet.

## Important decisions and discussions

No decisions have been recorded yet.

## Verification state

No verification evidence has been recorded yet.

## Blockers

$blockerText

## Next step

Resolve the current feature requirements and implementation plan.
"@
	}
	$worklog = Join-Path $Directory "worklog.md"
	if (-not (Test-Path -LiteralPath $worklog -PathType Leaf)) {
		Write-Utf8NoBom -Path $worklog -Content "# Feature worklog`r`n"
	}
}

function Switch-ToNewFeatureBranch {
	param(
		[Parameter(Mandatory = $true)][string]$RepositoryRoot,
		[Parameter(Mandatory = $true)][string]$CurrentBranch,
		[Parameter(Mandatory = $true)][string]$TargetBranch
	)
	if ($CurrentBranch.Equals($TargetBranch, [StringComparison]::Ordinal)) {
		return $CurrentBranch
	}
	$existing = Invoke-FeatureGit `
		-RepositoryRoot $RepositoryRoot `
		-Arguments @("show-ref", "--verify", "--quiet", "refs/heads/$TargetBranch") `
		-AllowFailure
	if ($existing.ExitCode -eq 0) {
		throw "Canonical feature branch '$TargetBranch' already exists. Switch to it explicitly or resolve the collision."
	}
	Invoke-FeatureGit -RepositoryRoot $RepositoryRoot -Arguments @("switch", "--quiet", "-c", $TargetBranch) | Out-Null
	return $TargetBranch
}

function Switch-ToRecordedFeatureBranch {
	param(
		[Parameter(Mandatory = $true)][string]$RepositoryRoot,
		[Parameter(Mandatory = $true)][string]$CurrentBranch,
		[Parameter(Mandatory = $true)][string]$RecordedBranch
	)
	if ($CurrentBranch.Equals($RecordedBranch, [StringComparison]::Ordinal)) {
		return $CurrentBranch
	}
	$existing = Invoke-FeatureGit `
		-RepositoryRoot $RepositoryRoot `
		-Arguments @("show-ref", "--verify", "--quiet", "refs/heads/$RecordedBranch") `
		-AllowFailure
	if ($existing.ExitCode -ne 0) {
		throw "Recorded feature branch '$RecordedBranch' is missing. Restore it or migrate feature metadata explicitly."
	}
	Invoke-FeatureGit -RepositoryRoot $RepositoryRoot -Arguments @("switch", "--quiet", $RecordedBranch) | Out-Null
	return $RecordedBranch
}

function Get-InitialArtifactState {
	param([Parameter(Mandatory = $true)][string]$Directory)
	$artifacts = [Collections.Generic.List[string]]::new()
	$blockers = [Collections.Generic.List[string]]::new()
	$productRequirements = Join-Path $Directory "product-requirements.md"
	$technicalSpecification = Join-Path $Directory "technical-specification.md"
	if (Test-Path -LiteralPath $productRequirements -PathType Leaf) {
		$artifacts.Add("product-requirements.md")
	} else {
		$blockers.Add("Product requirements are missing.")
	}
	if (Test-Path -LiteralPath $technicalSpecification -PathType Leaf) {
		$artifacts.Add("technical-specification.md")
	} else {
		$blockers.Add("Technical specification is missing.")
	}
	return [PSCustomObject]@{ Artifacts = @($artifacts); Blockers = @($blockers) }
}

$repositoryRoot = Get-FeatureRepositoryRoot
$stateChangingActions = @("Start", "Continue", "Pause", "Finish")
if ($Action -in $stateChangingActions) {
	Assert-FeatureRepositoryInitialized -RepositoryRoot $repositoryRoot
}
$branch = Get-CurrentFeatureBranch -RepositoryRoot $repositoryRoot
$head = Get-FeatureHead -RepositoryRoot $repositoryRoot
$record = Resolve-FeatureRecord -RepositoryRoot $repositoryRoot -Feature $Feature

switch ($Action) {
	"Start" {
		$wasReopened = $false
		$workingTree = (Invoke-FeatureGit -RepositoryRoot $repositoryRoot -Arguments @("status", "--porcelain", "--untracked-files=all")).Output
		if ($workingTree.Count -gt 0 -and -not $AdoptChanges) {
			throw "Starting a feature requires a clean worktree. Use -AdoptChanges only after explicit user authorization."
		}

		if ($null -eq $record) {
			$role = Get-RepositoryRole -RepositoryRoot $repositoryRoot
			$id = Get-NextFeatureId -RepositoryRoot $repositoryRoot -Role $role
			$resolvedTitle = if ([string]::IsNullOrWhiteSpace($Title)) { $Feature.Trim() } else { $Title.Trim() }
			$resolvedSlug = if ([string]::IsNullOrWhiteSpace($Slug)) { ConvertTo-FeatureSlug $resolvedTitle } else { ConvertTo-FeatureSlug $Slug }
			$directory = Join-Path (Get-FeatureRoot -RepositoryRoot $repositoryRoot) $resolvedSlug
			if (Test-Path -LiteralPath $directory -PathType Container) {
				$unexpectedManifest = Join-Path $directory "feature.json"
				if (Test-Path -LiteralPath $unexpectedManifest -PathType Leaf) {
					throw "Feature directory contains an unresolved manifest: $unexpectedManifest"
				}
			}
			$canonicalBranch = Get-CanonicalFeatureBranchName `
				-NamespaceRole $role `
				-FeatureId $id `
				-Slug $resolvedSlug
			$branch = Switch-ToNewFeatureBranch `
				-RepositoryRoot $repositoryRoot `
				-CurrentBranch $branch `
				-TargetBranch $canonicalBranch
			if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
				New-Item -ItemType Directory -Path $directory | Out-Null
			}
			$artifactState = Get-InitialArtifactState -Directory $directory
			$manifest = [PSCustomObject][ordered]@{
				schemaVersion = 2
				id = $id
				slug = $resolvedSlug
				title = $resolvedTitle
				status = "in_progress"
				activity = "active"
				branch = $branch
				baseCommit = $head
				startedAt = [DateTimeOffset]::UtcNow.ToString("o")
				completedAt = $null
				updatedAt = [DateTimeOffset]::UtcNow.ToString("o")
				blockers = @($artifactState.Blockers)
				artifacts = @($artifactState.Artifacts)
				verification = $null
				recoveryLog = @()
			}
			$record = [PSCustomObject]@{
				Namespace = $role
				NamespaceRoot = Get-FeatureNamespaceRoot -RepositoryRoot $repositoryRoot -NamespaceRole $role
				Directory = $directory
				Folder = (Split-Path -Leaf $directory)
				Path = (Join-Path $directory "feature.json")
				Manifest = $manifest
			}
		} else {
			Assert-FeatureRecordWritable -RepositoryRoot $repositoryRoot -Record $record
			$manifest = $record.Manifest
			if ($manifest.status -eq "ready") {
				if ([string]::IsNullOrWhiteSpace($ReopenReason)) {
					throw "Feature '$($manifest.id)' is ready. Reopening requires -ReopenReason."
				}
				if (
					[string]::IsNullOrWhiteSpace([string]$manifest.branch) -or
					-not ([string]$manifest.baseCommit -match '^[0-9a-f]{40}$')
				) {
					throw "Ready feature '$($manifest.id)' has incomplete branch/base metadata. Migrate it explicitly before reopening."
				}
				Assert-NoOtherFeatureOnBranch `
					-RepositoryRoot $repositoryRoot `
					-Branch ([string]$manifest.branch) `
					-ExceptId $manifest.id
				$branch = Switch-ToRecordedFeatureBranch `
					-RepositoryRoot $repositoryRoot `
					-CurrentBranch $branch `
					-RecordedBranch ([string]$manifest.branch)
				$head = Get-FeatureHead -RepositoryRoot $repositoryRoot
				$ancestor = Invoke-FeatureGit `
					-RepositoryRoot $repositoryRoot `
					-Arguments @("merge-base", "--is-ancestor", [string]$manifest.baseCommit, "HEAD") `
					-AllowFailure
				if ($ancestor.ExitCode -ne 0) {
					throw "Feature baseCommit is no longer an ancestor of HEAD; migrate metadata explicitly after rebase."
				}
				$recoveries = @($manifest.recoveryLog)
				$recoveries += [PSCustomObject][ordered]@{
					at = [DateTimeOffset]::UtcNow.ToString("o")
					reason = $ReopenReason
					previousStatus = "ready"
				}
				$manifest.recoveryLog = @($recoveries)
				$manifest.status = "in_progress"
				$manifest.completedAt = $null
				$wasReopened = $true
			} elseif ($manifest.status -eq "in_progress") {
				throw "Feature '$($manifest.id)' is already in progress. Use `$feature-continue."
			} else {
				$canonicalBranch = Get-CanonicalFeatureBranchName `
					-NamespaceRole $record.Namespace `
					-FeatureId $manifest.id `
					-Slug $manifest.slug
				$branch = Switch-ToNewFeatureBranch `
					-RepositoryRoot $repositoryRoot `
					-CurrentBranch $branch `
					-TargetBranch $canonicalBranch
				$manifest.branch = $branch
				$manifest.baseCommit = $head
			}
			$manifest.status = "in_progress"
			$manifest.activity = "active"
			$manifest.updatedAt = [DateTimeOffset]::UtcNow.ToString("o")
		}

		Assert-NoOtherFeatureOnBranch -RepositoryRoot $repositoryRoot -Branch $branch -ExceptId $record.Manifest.id
		Acquire-FeatureWriterLease -RepositoryRoot $repositoryRoot -Branch $branch -FeatureId $record.Manifest.id | Out-Null
		New-ServiceArtifacts -Directory $record.Directory -Manifest $record.Manifest
		if ($wasReopened) {
			$reopenSummary = "Feature was explicitly reopened and is active on its preserved recorded branch. Prior completion evidence remains historical."
			$reopenDecisions = "Reopen reason: $ReopenReason"
			$reopenVerification = "No new verification has been completed for the reopened work; read the previous finished checkpoint as historical evidence only."
			$reopenNextStep = "Audit the reopened scope and record new implementation and verification evidence."
			Write-FeatureHandoff -Directory $record.Directory -Manifest $record.Manifest -Head $head -Summary $reopenSummary -Decisions $reopenDecisions -VerificationSummary $reopenVerification -NextStep $reopenNextStep
			Append-FeatureWorklog -Directory $record.Directory -Manifest $record.Manifest -Action "reopened" -Head $head -Summary $reopenSummary -Decisions $reopenDecisions -VerificationSummary $reopenVerification -NextStep $reopenNextStep
		}
		Write-FeatureManifest -Path $record.Path -Manifest $record.Manifest
		Sync-FeatureIndex -RepositoryRoot $repositoryRoot -NamespaceRole $record.Namespace | Out-Null
		Write-Output "Started $($record.Manifest.id) '$($record.Manifest.title)' on '$branch' at $head."
	}

	"Continue" {
		if ($null -eq $record) { throw "Unknown feature '$Feature'." }
		Assert-FeatureRecordWritable -RepositoryRoot $repositoryRoot -Record $record
		$manifest = $record.Manifest
		if ($manifest.status -eq "planned") { throw "Feature '$($manifest.id)' is planned. Use `$feature-start." }
		if ($manifest.status -eq "ready") { throw "Feature '$($manifest.id)' is ready. Reopen it explicitly with `$feature-start." }
		if ($manifest.activity -ne "paused") { throw "Feature '$($manifest.id)' is not paused." }
		if (-not ([string]$manifest.branch).Equals($branch, [StringComparison]::Ordinal)) {
			throw "Feature '$($manifest.id)' belongs to branch '$($manifest.branch)', not '$branch'."
		}
		$ancestor = Invoke-FeatureGit -RepositoryRoot $repositoryRoot -Arguments @("merge-base", "--is-ancestor", [string]$manifest.baseCommit, "HEAD") -AllowFailure
		if ($ancestor.ExitCode -ne 0) { throw "Feature baseCommit is no longer an ancestor of HEAD; migrate metadata explicitly after rebase." }
		Assert-NoOtherFeatureOnBranch -RepositoryRoot $repositoryRoot -Branch $branch -ExceptId $manifest.id
		Acquire-FeatureWriterLease -RepositoryRoot $repositoryRoot -Branch $branch -FeatureId $manifest.id | Out-Null
		$manifest.activity = "active"
		$manifest.updatedAt = [DateTimeOffset]::UtcNow.ToString("o")
		Write-FeatureManifest -Path $record.Path -Manifest $manifest
		Sync-FeatureIndex -RepositoryRoot $repositoryRoot -NamespaceRole $record.Namespace | Out-Null
		Write-Output "Continuing $($manifest.id) '$($manifest.title)'."
		Write-Output "Namespace: $($record.Namespace)"
		Write-Output "State: $($manifest.status) / $($manifest.activity)"
		Write-Output "Branch: $($manifest.branch)"
		Write-Output "Base: $($manifest.baseCommit)"
		Write-Output "Blockers: $(@($manifest.blockers) -join '; ')"
		Write-Output "Manifest: $($record.Path)"
		Write-Output "Handoff: $(Join-Path $record.Directory 'handoff.md')"
	}

	"Pause" {
		if ($null -eq $record) { throw "Unknown feature '$Feature'." }
		Assert-FeatureRecordWritable -RepositoryRoot $repositoryRoot -Record $record
		Assert-ActiveFeature -Manifest $record.Manifest
		Assert-FeatureActionContext -Record $record -RepositoryRoot $repositoryRoot -CurrentBranch $branch
		if ([string]::IsNullOrWhiteSpace($Summary)) { throw "Pausing requires -Summary for the durable checkpoint." }
		if ([string]::IsNullOrWhiteSpace($Decisions)) { throw "Pausing requires -Decisions with important chat decisions and discussions." }
		if ([string]::IsNullOrWhiteSpace($VerificationSummary)) { throw "Pausing requires -VerificationSummary with factual check state." }
		if ([string]::IsNullOrWhiteSpace($NextStep)) { throw "Pausing requires -NextStep." }
		$record.Manifest.activity = "paused"
		$record.Manifest.updatedAt = [DateTimeOffset]::UtcNow.ToString("o")
		Write-FeatureHandoff -Directory $record.Directory -Manifest $record.Manifest -Head $head -Summary $Summary -Decisions $Decisions -VerificationSummary $VerificationSummary -NextStep $NextStep
		Append-FeatureWorklog -Directory $record.Directory -Manifest $record.Manifest -Action "paused" -Head $head -Summary $Summary -Decisions $Decisions -VerificationSummary $VerificationSummary -NextStep $NextStep
		Write-FeatureManifest -Path $record.Path -Manifest $record.Manifest
		Sync-FeatureIndex -RepositoryRoot $repositoryRoot -NamespaceRole $record.Namespace | Out-Null
		Release-FeatureWriterLease -RepositoryRoot $repositoryRoot -Branch $record.Manifest.branch -FeatureId $record.Manifest.id
		Write-Output "Paused $($record.Manifest.id) '$($record.Manifest.title)'."
	}

	"Finish" {
		if ($null -eq $record) { throw "Unknown feature '$Feature'." }
		Assert-FeatureRecordWritable -RepositoryRoot $repositoryRoot -Record $record
		Assert-ActiveFeature -Manifest $record.Manifest
		Assert-FeatureActionContext -Record $record -RepositoryRoot $repositoryRoot -CurrentBranch $branch
		if ([string]::IsNullOrWhiteSpace($Summary)) { throw "Finishing requires -Summary." }
		if ([string]::IsNullOrWhiteSpace($Decisions)) { throw "Finishing requires -Decisions with important chat decisions and discussions." }
		if ([string]::IsNullOrWhiteSpace($VerificationSummary)) { throw "Finishing requires -VerificationSummary describing checks completed before Finish." }
		if (@($record.Manifest.blockers).Count -gt 0) { throw "Feature '$($record.Manifest.id)' still has blockers: $(@($record.Manifest.blockers) -join '; ')" }
		$record.Manifest.status = "ready"
		$record.Manifest.activity = "none"
		$record.Manifest.completedAt = [DateTimeOffset]::UtcNow.ToString("o")
		$record.Manifest.updatedAt = $record.Manifest.completedAt
		$record.Manifest.verification = [PSCustomObject][ordered]@{
			completedAt = $record.Manifest.completedAt
			head = $head
			summary = $VerificationSummary
		}
		Write-FeatureHandoff -Directory $record.Directory -Manifest $record.Manifest -Head $head -Summary $Summary -Decisions $Decisions -VerificationSummary $VerificationSummary -NextStep "None; feature is ready."
		Append-FeatureWorklog -Directory $record.Directory -Manifest $record.Manifest -Action "finished" -Head $head -Summary $Summary -Decisions $Decisions -VerificationSummary $VerificationSummary -NextStep "None; feature is ready."
		Write-FeatureManifest -Path $record.Path -Manifest $record.Manifest
		Sync-FeatureIndex -RepositoryRoot $repositoryRoot -NamespaceRole $record.Namespace | Out-Null
		Release-FeatureWriterLease -RepositoryRoot $repositoryRoot -Branch $record.Manifest.branch -FeatureId $record.Manifest.id
		Write-Output "Finished $($record.Manifest.id) '$($record.Manifest.title)'."
	}

	"Context" {
		if ($null -eq $record) { throw "Unknown feature '$Feature'." }
		$m = $record.Manifest
		Write-Output "Feature: $($m.id) $($m.title)"
		Write-Output "Namespace: $($record.Namespace)"
		Write-Output "State: $($m.status) / $($m.activity)"
		Write-Output "Branch: $($m.branch)"
		Write-Output "Base: $($m.baseCommit)"
		Write-Output "Blockers: $(@($m.blockers) -join '; ')"
		Write-Output "Worklog: $(Join-Path $record.Directory 'worklog.md')"
		Write-Output "Directory: $($record.Directory)"
	}
}
