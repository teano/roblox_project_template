Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-HookJson {
	param([Parameter(Mandatory = $true)]$Value)
	[Console]::Out.Write(($Value | ConvertTo-Json -Depth 10 -Compress))
}

try {
	$raw = [Console]::In.ReadToEnd()
	if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }
	$hook = $raw | ConvertFrom-Json
	$rootResult = @(& git -C ([string]$hook.cwd) rev-parse --show-toplevel 2>$null)
	if ($LASTEXITCODE -ne 0 -or $rootResult.Count -eq 0) { exit 0 }
	$root = ([string]$rootResult[0]).Trim()
	$modulePath = Join-Path $root "scripts\FeatureWorkflow.psm1"
	if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) { exit 0 }
	Import-Module $modulePath -Force -DisableNameChecking

	if ($hook.hook_event_name -eq "SessionStart") {
		try {
			$branch = Get-CurrentFeatureBranch -RepositoryRoot $root
			$records = @(Get-FeatureManifests -RepositoryRoot $root)
			$active = @($records | Where-Object {
				$_.Manifest.status -eq "in_progress" -and
				([string]$_.Manifest.branch).Equals($branch, [StringComparison]::Ordinal)
			})
			if ($active.Count -eq 0) {
				$context = "Feature workflow: branch '$branch' has no in-progress feature. Use `$feature-start before feature source edits."
			} else {
				$activeRecord = $active[0]
				$m = $activeRecord.Manifest
				$context = (
					"Feature workflow: branch '$branch' is reserved by " +
					"$($activeRecord.Namespace)/$($m.id) " +
					"'$($m.title)' in state $($m.status)/$($m.activity). " +
					"Active task: $($m.activeSessionId). Use `$feature-continue only " +
					"when paused, `$feature-pause to checkpoint, and `$feature-finish " +
					"only after all gates pass."
				)
			}
			Write-HookJson ([ordered]@{
				hookSpecificOutput = [ordered]@{
					hookEventName = "SessionStart"
					additionalContext = $context
				}
			})
		} catch {
			Write-HookJson ([ordered]@{ systemMessage = "Feature startup context unavailable: $($_.Exception.Message)" })
		}
		exit 0
	}

	if ($hook.hook_event_name -eq "PreToolUse" -and $hook.tool_name -eq "Bash") {
		$command = [string]$hook.tool_input.command
		if ($command -notmatch '(?i)(?:^|[\\/])feature-workflow\.ps1(?:\s|''|"|$)') { exit 0 }
		if ($command -match '(?i)\s-SessionId\s') {
			Write-HookJson ([ordered]@{
				hookSpecificOutput = [ordered]@{
					hookEventName = "PreToolUse"
					permissionDecision = "deny"
					permissionDecisionReason = "Do not supply -SessionId manually inside Codex; the trusted hook injects the verified current task id."
				}
			})
			exit 0
		}
		$sessionId = ([string]$hook.session_id).Replace("'", "''")
		$updated = $command + " -SessionId '$sessionId'"
		Write-HookJson ([ordered]@{
			hookSpecificOutput = [ordered]@{
				hookEventName = "PreToolUse"
				permissionDecision = "allow"
				updatedInput = [ordered]@{ command = $updated }
			}
		})
		exit 0
	}
} catch {
	Write-HookJson ([ordered]@{ systemMessage = "Feature hook failed: $($_.Exception.Message)" })
	exit 0
}
