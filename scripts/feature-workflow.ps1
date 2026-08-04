param(
	[Parameter(Mandatory = $true)]
	[ValidateSet("Start", "Continue", "Pause", "Finish", "Context")]
	[string]$Action,

	[Parameter(Mandatory = $true)]
	[string]$Feature,

	[string]$Title,
	[string]$Slug,
	[string]$SessionId,
	[string]$Summary,
	[string]$NextStep,
	[string]$VerificationSummary,
	[string]$ReopenReason,
	[switch]$AdoptChanges
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "FeatureWorkflow.psm1") -Force -DisableNameChecking

function Require-SessionId {
	if ([string]::IsNullOrWhiteSpace($SessionId)) {
		throw (
			"The current Codex task id is required. Trust the repository " +
			"PreToolUse hook or pass -SessionId from verified hook input."
		)
	}
}

function Assert-CurrentOwner {
	param($Manifest)
	Require-SessionId
	if ($Manifest.status -ne "in_progress" -or $Manifest.activity -ne "active") {
		throw "Feature '$($Manifest.id)' is not active."
	}
	if (-not ([string]$Manifest.activeSessionId).Equals($SessionId, [StringComparison]::Ordinal)) {
		throw "Task '$SessionId' does not own active feature '$($Manifest.id)'."
	}
}

function New-ServiceArtifacts {
	param(
		[Parameter(Mandatory = $true)][string]$Directory,
		[Parameter(Mandatory = $true)]$Manifest
	)
	$handoff = Join-Path $Directory "handoff.md"
	if (-not (Test-Path -LiteralPath $handoff -PathType Leaf)) {
		$featureLabel = "$($Manifest.id) $($Manifest.title)"
		Write-Utf8NoBom -Path $handoff -Content @"
# Feature handoff

- Feature: $featureLabel
- Status: $($Manifest.status) / $($Manifest.activity)

## Summary

No durable handoff has been recorded yet.

## Next confirmed step

Resolve the current feature requirements and implementation plan.
"@
	}
	$worklog = Join-Path $Directory "worklog.md"
	if (-not (Test-Path -LiteralPath $worklog -PathType Leaf)) {
		Write-Utf8NoBom -Path $worklog -Content "# Feature worklog`r`n"
	}
}

$repositoryRoot = Get-FeatureRepositoryRoot
$branch = Get-CurrentFeatureBranch -RepositoryRoot $repositoryRoot
$head = Get-FeatureHead -RepositoryRoot $repositoryRoot
$record = Resolve-FeatureRecord -RepositoryRoot $repositoryRoot -Feature $Feature

switch ($Action) {
	"Start" {
		Require-SessionId
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
			} else {
				New-Item -ItemType Directory -Path $directory | Out-Null
			}
			$manifest = [PSCustomObject][ordered]@{
				schemaVersion = 1
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
				activeSessionId = $SessionId
				sessions = @()
				blockers = @()
				artifacts = @()
				verification = $null
				recoveryLog = @()
			}
			Add-FeatureSession -Manifest $manifest -SessionId $SessionId -Role "implementation" -Head $head
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
				$recoveries = @($manifest.recoveryLog)
				$recoveries += [PSCustomObject][ordered]@{
					at = [DateTimeOffset]::UtcNow.ToString("o")
					sessionId = $SessionId
					reason = $ReopenReason
					previousStatus = "ready"
				}
				$manifest.recoveryLog = @($recoveries)
				$manifest.status = "in_progress"
				$manifest.completedAt = $null
			} elseif ($manifest.status -eq "in_progress") {
				throw "Feature '$($manifest.id)' is already in progress. Use `$feature-continue."
			}
			if ($null -ne $manifest.branch -and -not ([string]$manifest.branch).Equals($branch, [StringComparison]::Ordinal)) {
				throw "Feature '$($manifest.id)' belongs to branch '$($manifest.branch)', not '$branch'."
			}
			$manifest.status = "in_progress"
			$manifest.activity = "active"
			$manifest.branch = $branch
			if ([string]::IsNullOrWhiteSpace([string]$manifest.baseCommit)) { $manifest.baseCommit = $head }
			$manifest.activeSessionId = $SessionId
			$manifest.updatedAt = [DateTimeOffset]::UtcNow.ToString("o")
			Add-FeatureSession -Manifest $manifest -SessionId $SessionId -Role "implementation" -Head $head
		}

		Assert-NoOtherFeatureOnBranch -RepositoryRoot $repositoryRoot -Branch $branch -ExceptId $record.Manifest.id
		Acquire-FeatureWriterLease -RepositoryRoot $repositoryRoot -Branch $branch -FeatureId $record.Manifest.id -SessionId $SessionId | Out-Null
		New-ServiceArtifacts -Directory $record.Directory -Manifest $record.Manifest
		Write-FeatureManifest -Path $record.Path -Manifest $record.Manifest
		Sync-FeatureIndex -RepositoryRoot $repositoryRoot -NamespaceRole $record.Namespace | Out-Null
		Write-Output "Started $($record.Manifest.id) '$($record.Manifest.title)' on '$branch' at $head."
	}

	"Continue" {
		Require-SessionId
		if ($null -eq $record) { throw "Unknown feature '$Feature'." }
		Assert-FeatureRecordWritable -RepositoryRoot $repositoryRoot -Record $record
		$manifest = $record.Manifest
		if ($manifest.status -eq "planned") { throw "Feature '$($manifest.id)' is planned. Use `$feature-start." }
		if ($manifest.status -eq "ready") { throw "Feature '$($manifest.id)' is ready. Reopen it explicitly with `$feature-start." }
		if (-not ([string]$manifest.branch).Equals($branch, [StringComparison]::Ordinal)) {
			throw "Feature '$($manifest.id)' belongs to branch '$($manifest.branch)', not '$branch'."
		}
		$ancestor = Invoke-FeatureGit -RepositoryRoot $repositoryRoot -Arguments @("merge-base", "--is-ancestor", [string]$manifest.baseCommit, "HEAD") -AllowFailure
		if ($ancestor.ExitCode -ne 0) { throw "Feature baseCommit is no longer an ancestor of HEAD; migrate metadata explicitly after rebase." }
		Assert-NoOtherFeatureOnBranch -RepositoryRoot $repositoryRoot -Branch $branch -ExceptId $manifest.id
		if ($manifest.activity -eq "active" -and -not ([string]$manifest.activeSessionId).Equals($SessionId, [StringComparison]::Ordinal)) {
			throw "Feature '$($manifest.id)' is active in task '$($manifest.activeSessionId)'. Resume that task or recover it explicitly."
		}
		Acquire-FeatureWriterLease -RepositoryRoot $repositoryRoot -Branch $branch -FeatureId $manifest.id -SessionId $SessionId | Out-Null
		$manifest.activity = "active"
		$manifest.activeSessionId = $SessionId
		$manifest.updatedAt = [DateTimeOffset]::UtcNow.ToString("o")
		Add-FeatureSession -Manifest $manifest -SessionId $SessionId -Role "continuation" -Head $head
		Write-FeatureManifest -Path $record.Path -Manifest $manifest
		Sync-FeatureIndex -RepositoryRoot $repositoryRoot -NamespaceRole $record.Namespace | Out-Null
		Write-Output "Continuing $($manifest.id) '$($manifest.title)'."
		Write-Output "Manifest: $($record.Path)"
		Write-Output "Handoff: $(Join-Path $record.Directory 'handoff.md')"
		Write-Output "Worklog: $(Join-Path $record.Directory 'worklog.md')"
		Write-Output "Git range: $($manifest.baseCommit)..HEAD"
	}

	"Pause" {
		if ($null -eq $record) { throw "Unknown feature '$Feature'." }
		Assert-FeatureRecordWritable -RepositoryRoot $repositoryRoot -Record $record
		Assert-CurrentOwner -Manifest $record.Manifest
		if ([string]::IsNullOrWhiteSpace($Summary)) { throw "Pausing requires -Summary for the durable handoff." }
		if ([string]::IsNullOrWhiteSpace($NextStep)) { throw "Pausing requires -NextStep." }
		Close-FeatureSession -Manifest $record.Manifest -SessionId $SessionId -Outcome "paused" -Head $head -Summary $Summary
		$record.Manifest.activity = "paused"
		$record.Manifest.activeSessionId = $null
		$record.Manifest.updatedAt = [DateTimeOffset]::UtcNow.ToString("o")
		Write-FeatureHandoff -Directory $record.Directory -Manifest $record.Manifest -SessionId $SessionId -Head $head -Summary $Summary -NextStep $NextStep
		Append-FeatureWorklog -Directory $record.Directory -Manifest $record.Manifest -SessionId $SessionId -Action "paused" -Head $head -Summary $Summary
		Write-FeatureManifest -Path $record.Path -Manifest $record.Manifest
		Sync-FeatureIndex -RepositoryRoot $repositoryRoot -NamespaceRole $record.Namespace | Out-Null
		Release-FeatureWriterLease -RepositoryRoot $repositoryRoot -Branch $branch -FeatureId $record.Manifest.id -SessionId $SessionId
		Write-Output "Paused $($record.Manifest.id) '$($record.Manifest.title)'."
	}

	"Finish" {
		if ($null -eq $record) { throw "Unknown feature '$Feature'." }
		Assert-FeatureRecordWritable -RepositoryRoot $repositoryRoot -Record $record
		Assert-CurrentOwner -Manifest $record.Manifest
		if ([string]::IsNullOrWhiteSpace($Summary)) { throw "Finishing requires -Summary." }
		if ([string]::IsNullOrWhiteSpace($VerificationSummary)) { throw "Finishing requires -VerificationSummary." }
		if (@($record.Manifest.blockers).Count -gt 0) { throw "Feature '$($record.Manifest.id)' still has blockers: $(@($record.Manifest.blockers) -join '; ')" }
		Close-FeatureSession -Manifest $record.Manifest -SessionId $SessionId -Outcome "completed" -Head $head -Summary $Summary
		$record.Manifest.status = "ready"
		$record.Manifest.activity = "none"
		$record.Manifest.activeSessionId = $null
		$record.Manifest.completedAt = [DateTimeOffset]::UtcNow.ToString("o")
		$record.Manifest.updatedAt = $record.Manifest.completedAt
		$record.Manifest.verification = [PSCustomObject][ordered]@{
			completedAt = $record.Manifest.completedAt
			head = $head
			summary = $VerificationSummary
		}
		Write-FeatureHandoff -Directory $record.Directory -Manifest $record.Manifest -SessionId $SessionId -Head $head -Summary $Summary -NextStep "None; feature is ready."
		Append-FeatureWorklog -Directory $record.Directory -Manifest $record.Manifest -SessionId $SessionId -Action "finished" -Head $head -Summary $Summary
		Write-FeatureManifest -Path $record.Path -Manifest $record.Manifest
		Sync-FeatureIndex -RepositoryRoot $repositoryRoot -NamespaceRole $record.Namespace | Out-Null
		Release-FeatureWriterLease -RepositoryRoot $repositoryRoot -Branch $branch -FeatureId $record.Manifest.id -SessionId $SessionId
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
		Write-Output "Active task: $($m.activeSessionId)"
		Write-Output "Tasks: $(@($m.sessions).Count)"
		Write-Output "Blockers: $(@($m.blockers) -join '; ')"
		Write-Output "Directory: $($record.Directory)"
	}
}
