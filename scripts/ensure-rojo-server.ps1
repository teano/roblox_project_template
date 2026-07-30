[CmdletBinding()]
param(
	[ValidateRange(1, 60)]
	[int]$StartupTimeoutSeconds = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$rojoPort = 34872
$repositoryRootOutput = @(
	& git -C $PSScriptRoot rev-parse --show-toplevel 2>$null
)
if ($LASTEXITCODE -ne 0 -or $repositoryRootOutput.Count -ne 1) {
	throw "Could not resolve the repository root from '$PSScriptRoot'."
}

$repositoryRoot = [IO.Path]::GetFullPath($repositoryRootOutput[0].Trim())
$projectPath = Join-Path $repositoryRoot "default.project.json"
if (-not (Test-Path -LiteralPath $projectPath -PathType Leaf)) {
	throw "Rojo project file is missing: '$projectPath'."
}

$project = Get-Content -LiteralPath $projectPath -Raw | ConvertFrom-Json
$servePortProperty = $project.PSObject.Properties["servePort"]
if ($null -ne $servePortProperty) {
	throw (
		"default.project.json must not define servePort. This repository uses " +
		"the shared Rojo default port $rojoPort and switches its active server."
	)
}

$expectedProjectName = [string]$project.name
$repositoryName = Split-Path -Leaf $repositoryRoot
if ([string]::IsNullOrWhiteSpace($expectedProjectName)) {
	throw "default.project.json must define a non-empty name."
}
if ($expectedProjectName -cne $repositoryName) {
	throw (
		"default.project.json name '$expectedProjectName' must match the " +
		"repository directory '$repositoryName'."
	)
}

function Find-ByteSequence {
	param(
		[Parameter(Mandatory)]
		[byte[]]$Bytes,

		[Parameter(Mandatory)]
		[byte[]]$Sequence
	)

	for ($index = 0; $index -le $Bytes.Length - $Sequence.Length; $index++) {
		$matches = $true
		for ($offset = 0; $offset -lt $Sequence.Length; $offset++) {
			if ($Bytes[$index + $offset] -ne $Sequence[$offset]) {
				$matches = $false
				break
			}
		}
		if ($matches) {
			return $index
		}
	}

	return -1
}

function Read-MessagePackStringField {
	param(
		[Parameter(Mandatory)]
		[byte[]]$Bytes,

		[Parameter(Mandatory)]
		[string]$FieldName
	)

	$fieldNameBytes = [Text.Encoding]::UTF8.GetBytes($FieldName)
	if ($fieldNameBytes.Length -gt 31) {
		throw "Only MessagePack fixstr field names are supported."
	}

	$fieldPrefix = [byte](0xA0 -bor $fieldNameBytes.Length)
	$fieldBytes = [byte[]](@($fieldPrefix) + @($fieldNameBytes))
	$fieldIndex = Find-ByteSequence -Bytes $Bytes -Sequence $fieldBytes
	if ($fieldIndex -lt 0) {
		return $null
	}

	$prefixIndex = $fieldIndex + $fieldBytes.Length
	if ($prefixIndex -ge $Bytes.Length) {
		return $null
	}

	$prefix = [int]$Bytes[$prefixIndex]
	$stringOffset = $prefixIndex + 1
	$stringLength = 0

	if ($prefix -ge 0xA0 -and $prefix -le 0xBF) {
		$stringLength = $prefix -band 0x1F
	} elseif ($prefix -eq 0xD9) {
		if ($stringOffset -ge $Bytes.Length) {
			return $null
		}
		$stringLength = [int]$Bytes[$stringOffset]
		$stringOffset++
	} elseif ($prefix -eq 0xDA) {
		if ($stringOffset + 1 -ge $Bytes.Length) {
			return $null
		}
		$stringLength = (
			([int]$Bytes[$stringOffset] -shl 8) -bor
			[int]$Bytes[$stringOffset + 1]
		)
		$stringOffset += 2
	} elseif ($prefix -eq 0xDB) {
		if ($stringOffset + 3 -ge $Bytes.Length) {
			return $null
		}
		$stringLength = (
			([int]$Bytes[$stringOffset] -shl 24) -bor
			([int]$Bytes[$stringOffset + 1] -shl 16) -bor
			([int]$Bytes[$stringOffset + 2] -shl 8) -bor
			[int]$Bytes[$stringOffset + 3]
		)
		$stringOffset += 4
	} else {
		return $null
	}

	if (
		$stringLength -lt 0 -or
		$stringOffset + $stringLength -gt $Bytes.Length
	) {
		return $null
	}

	return [Text.Encoding]::UTF8.GetString(
		$Bytes,
		$stringOffset,
		$stringLength
	)
}

function Get-ActiveRojoProjectName {
	try {
		$response = Invoke-WebRequest `
			-UseBasicParsing `
			-Uri "http://127.0.0.1:$rojoPort/api/rojo" `
			-TimeoutSec 2
		if ($response.StatusCode -ne 200 -or $response.Content -isnot [byte[]]) {
			return $null
		}

		return Read-MessagePackStringField `
			-Bytes $response.Content `
			-FieldName "projectName"
	} catch {
		return $null
	}
}

function Get-PortListeners {
	try {
		return @(
			Get-NetTCPConnection `
				-State Listen `
				-LocalPort $rojoPort `
				-ErrorAction Stop
		)
	} catch {
		if ($_.FullyQualifiedErrorId -like "CmdletizationQuery_NotFound*") {
			return @()
		}
		throw
	}
}

$activeProjectName = Get-ActiveRojoProjectName
if ($activeProjectName -ceq $expectedProjectName) {
	Write-Output (
		"Rojo preflight passed: '$expectedProjectName' is already serving on " +
		"127.0.0.1:$rojoPort."
	)
	exit 0
}

$listeners = @(Get-PortListeners)
if ($listeners.Count -gt 0) {
	$ownerProcessIds = @(
		$listeners |
			Select-Object -ExpandProperty OwningProcess -Unique
	)
	if ($ownerProcessIds.Count -ne 1) {
		throw (
			"Port $rojoPort has multiple listener owners: " +
			"$($ownerProcessIds -join ', ')."
		)
	}

	$ownerProcessId = [int]$ownerProcessIds[0]
	$ownerProcess = Get-Process -Id $ownerProcessId -ErrorAction Stop
	if ($ownerProcess.ProcessName -ine "rojo") {
		throw (
			"Port $rojoPort is owned by non-Rojo process " +
			"'$($ownerProcess.ProcessName)' (PID $ownerProcessId). Refusing " +
			"to terminate it."
		)
	}

	$shownProjectName = if ([string]::IsNullOrWhiteSpace($activeProjectName)) {
		"<unidentified>"
	} else {
		$activeProjectName
	}
	Write-Output (
		"Rojo preflight: replacing '$shownProjectName' on port $rojoPort with " +
		"'$expectedProjectName'."
	)

	$taskkillOutput = @(
		& taskkill.exe /PID $ownerProcessId /T /F 2>&1
	)
	if ($LASTEXITCODE -ne 0) {
		throw (
			"Could not stop Rojo PID ${ownerProcessId}: " +
			"$($taskkillOutput -join [Environment]::NewLine)"
		)
	}

	$releaseDeadline = [DateTime]::UtcNow.AddSeconds(5)
	do {
		if (@(Get-PortListeners).Count -eq 0) {
			break
		}
		Start-Sleep -Milliseconds 100
	} while ([DateTime]::UtcNow -lt $releaseDeadline)

	if (@(Get-PortListeners).Count -gt 0) {
		throw "Port $rojoPort did not become available after stopping Rojo."
	}
}

$rojoCommand = Get-Command rojo.exe -ErrorAction Stop
$logToken = [Guid]::NewGuid().ToString("N")
$standardOutputPath = Join-Path $env:TEMP "rojo-$logToken.stdout.log"
$standardErrorPath = Join-Path $env:TEMP "rojo-$logToken.stderr.log"
$rojoProcess = Start-Process `
	-FilePath $rojoCommand.Source `
	-ArgumentList @("serve", "default.project.json") `
	-WorkingDirectory $repositoryRoot `
	-WindowStyle Hidden `
	-RedirectStandardOutput $standardOutputPath `
	-RedirectStandardError $standardErrorPath `
	-PassThru

$startupDeadline = [DateTime]::UtcNow.AddSeconds($StartupTimeoutSeconds)
do {
	$rojoProcess.Refresh()
	if ($rojoProcess.HasExited) {
		$errorOutput = if (Test-Path -LiteralPath $standardErrorPath) {
			Get-Content -LiteralPath $standardErrorPath -Raw
		} else {
			""
		}
		throw (
			"Rojo exited before serving '$expectedProjectName'. " +
			"stderr: $errorOutput"
		)
	}

	$activeProjectName = Get-ActiveRojoProjectName
	if ($activeProjectName -ceq $expectedProjectName) {
		Write-Output (
			"Rojo preflight passed: started '$expectedProjectName' on " +
			"127.0.0.1:$rojoPort (PID $($rojoProcess.Id))."
		)
		exit 0
	}

	Start-Sleep -Milliseconds 200
} while ([DateTime]::UtcNow -lt $startupDeadline)

throw (
	"Rojo did not report project '$expectedProjectName' on port $rojoPort " +
	"within $StartupTimeoutSeconds seconds. Logs: '$standardOutputPath', " +
	"'$standardErrorPath'."
)
