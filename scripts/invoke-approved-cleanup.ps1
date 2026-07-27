[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$PlanPath,

    [switch]$Execute,

    [string]$ConfirmationToken = ''
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

if (-not (Test-Path -LiteralPath $PlanPath -PathType Leaf)) {
    throw "Plan file not found: $PlanPath"
}

$planText = Get-Content -LiteralPath $PlanPath -Raw -Encoding UTF8
$plan = $planText | ConvertFrom-Json
if ($null -eq $plan.targets -or @($plan.targets).Count -eq 0) {
    throw 'The plan must contain at least one target.'
}
if ($Execute -and $ConfirmationToken -ne 'DELETE-APPROVED-TARGETS') {
    throw 'Execution requires -ConfirmationToken DELETE-APPROVED-TARGETS.'
}

$userProfile = [System.IO.Path]::GetFullPath($env:USERPROFILE).TrimEnd('\')
$safeRoots = @(
    (Join-Path $userProfile 'AppData\Local\Temp'),
    (Join-Path $userProfile 'AppData\Local\CrashDumps'),
    (Join-Path $userProfile 'AppData\Local\Google\Chrome\User Data'),
    (Join-Path $userProfile 'AppData\Local\Microsoft\Edge\User Data'),
    (Join-Path $userProfile 'AppData\Roaming\LarkShell'),
    (Join-Path $userProfile 'AppData\Local\kingsoft\WPS Office'),
    (Join-Path $userProfile 'Downloads'),
    (Join-Path $userProfile 'Documents\xwechat_files')
) | ForEach-Object {
    [System.IO.Path]::GetFullPath($_).TrimEnd('\')
}

$forbiddenExactPaths = @(
    $env:SystemDrive,
    (Join-Path $env:SystemDrive 'Users'),
    $userProfile,
    (Join-Path $userProfile 'AppData'),
    (Join-Path $userProfile 'AppData\Local'),
    (Join-Path $userProfile 'AppData\Roaming'),
    (Join-Path $userProfile 'Documents'),
    (Join-Path $userProfile 'Desktop'),
    (Join-Path $userProfile 'Pictures'),
    (Join-Path $userProfile 'Videos'),
    $env:ProgramFiles,
    ${env:ProgramFiles(x86)},
    $env:ProgramData,
    (Join-Path $env:SystemDrive 'Windows')
) | Where-Object {
    -not [string]::IsNullOrWhiteSpace($_)
} | ForEach-Object {
    [System.IO.Path]::GetFullPath($_).TrimEnd('\')
}

function Test-PathUnder {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root
    )

    return (
        $Path.Equals($Root, [System.StringComparison]::OrdinalIgnoreCase) -or
        $Path.StartsWith($Root + '\', [System.StringComparison]::OrdinalIgnoreCase)
    )
}

function Test-SafeRoot {
    param([Parameter(Mandatory)][string]$Path)

    foreach ($root in $safeRoots) {
        if (Test-PathUnder -Path $Path -Root $root) {
            return $true
        }
    }
    return $false
}

function Get-TargetBytes {
    param([Parameter(Mandatory)][string]$LiteralPath)

    $item = Get-Item -LiteralPath $LiteralPath -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) {
        return 0L
    }
    if (-not $item.PSIsContainer) {
        return [int64]$item.Length
    }
    $sum = (
        Get-ChildItem -LiteralPath $LiteralPath -File -Recurse -Force -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum
    ).Sum
    if ($null -eq $sum) {
        return 0L
    }
    return [int64]$sum
}

function Test-ReparsePoint {
    param([Parameter(Mandatory)]$Item)

    return (
        ($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
    )
}

function Test-ModeAllowed {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Mode
    )

    $tempRoot = [System.IO.Path]::GetFullPath(
        (Join-Path $userProfile 'AppData\Local\Temp')
    ).TrimEnd('\')
    $wpsRoot = [System.IO.Path]::GetFullPath(
        (Join-Path $userProfile 'AppData\Local\kingsoft\WPS Office')
    ).TrimEnd('\')
    $downloadsRoot = [System.IO.Path]::GetFullPath(
        (Join-Path $userProfile 'Downloads')
    ).TrimEnd('\')
    $wechatRoot = [System.IO.Path]::GetFullPath(
        (Join-Path $userProfile 'Documents\xwechat_files')
    ).TrimEnd('\')

    switch ($Mode) {
        'File' {
            return (
                (Test-PathUnder -Path $Path -Root $downloadsRoot) -or
                (Test-PathUnder -Path $Path -Root $wechatRoot) -or
                ($Path -match '(?i)\\[^\\]*(updater|update)[^\\]*\\.*\.(exe|msi)$')
            )
        }
        'Contents' {
            $leaf = Split-Path -Path $Path -Leaf
            return $leaf -match '(?i)^(cache|cache storage|cachestorage|code cache|gpucache|grshadercache|shadercache|dawnwebgpucache|crashdumps|log|logs)$'
        }
        'Whole' {
            if (
                (Test-PathUnder -Path $Path -Root $tempRoot) -and
                -not $Path.Equals($tempRoot, [System.StringComparison]::OrdinalIgnoreCase)
            ) {
                return $true
            }
            if (
                (Test-PathUnder -Path $Path -Root $wpsRoot) -and
                -not $Path.Equals($wpsRoot, [System.StringComparison]::OrdinalIgnoreCase) -and
                (Split-Path -Path $Path -Leaf) -match '^\d+(\.\d+)+$'
            ) {
                return $true
            }
            return $false
        }
        default {
            return $false
        }
    }
}

$driveBefore = [System.IO.DriveInfo]::new($env:SystemDrive).AvailableFreeSpace
$results = @()

foreach ($target in @($plan.targets)) {
    $label = [string]$target.label
    $mode = [string]$target.mode
    $requestedPath = [string]$target.path
    $result = [ordered]@{
        Label = $label
        RequestedPath = $requestedPath
        ResolvedPath = ''
        Mode = $mode
        Status = 'Rejected'
        BeforeGB = 0
        AfterGB = 0
        FreedGB = 0
        Error = ''
    }

    try {
        if ([string]::IsNullOrWhiteSpace($requestedPath)) {
            throw 'Target path is empty.'
        }
        if ($mode -notin @('File', 'Contents', 'Whole')) {
            throw "Unsupported mode: $mode"
        }

        $resolved = [System.IO.Path]::GetFullPath($requestedPath).TrimEnd('\')
        $result.ResolvedPath = $resolved
        if (
            -not $resolved.Equals(
                $requestedPath.TrimEnd('\'),
                [System.StringComparison]::OrdinalIgnoreCase
            )
        ) {
            throw 'Resolved path differs from the approved path.'
        }
        foreach ($forbidden in $forbiddenExactPaths) {
            if ($resolved.Equals($forbidden, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw 'Broad or system-managed path is forbidden.'
            }
        }
        if (-not (Test-SafeRoot -Path $resolved)) {
            throw 'Target is outside the executor safe roots.'
        }
        if (-not (Test-ModeAllowed -Path $resolved -Mode $mode)) {
            throw "Mode $mode is not allowed for this path."
        }

        $item = Get-Item -LiteralPath $resolved -Force -ErrorAction SilentlyContinue
        if ($null -eq $item) {
            $result.Status = 'NotFound'
            $results += [pscustomobject]$result
            continue
        }
        if (Test-ReparsePoint -Item $item) {
            throw 'Target is a reparse point.'
        }
        if ($mode -eq 'File' -and $item.PSIsContainer) {
            throw 'File mode requires a file target.'
        }
        if ($mode -in @('Contents', 'Whole') -and -not $item.PSIsContainer) {
            throw "$mode mode requires a directory target."
        }
        if ($mode -eq 'Contents') {
            $reparseChildren = @(
                Get-ChildItem -LiteralPath $resolved -Force -ErrorAction SilentlyContinue |
                    Where-Object { Test-ReparsePoint -Item $_ }
            )
            if ($reparseChildren.Count -gt 0) {
                throw 'Contents include an immediate reparse point.'
            }
        }

        if (-not [string]::IsNullOrWhiteSpace([string]$target.expected_sha256)) {
            if ($item.PSIsContainer) {
                throw 'SHA-256 validation applies only to files.'
            }
            $actualHash = (
                Get-FileHash -LiteralPath $resolved -Algorithm SHA256 -ErrorAction Stop
            ).Hash
            if ($actualHash -ne [string]$target.expected_sha256) {
                throw 'SHA-256 does not match the approved value.'
            }
        }

        $processNames = @($target.processes) |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
            Select-Object -Unique
        $running = @()
        foreach ($processName in $processNames) {
            $running += @(
                Get-Process -Name ([string]$processName) -ErrorAction SilentlyContinue
            )
        }
        $visible = @($running | Where-Object { $_.MainWindowHandle -ne 0 })
        if ($visible.Count -gt 0) {
            throw 'A related application still has a visible window.'
        }
        if ($running.Count -gt 0) {
            if ([bool]$target.allow_stop_background) {
                if ($Execute) {
                    $running | Stop-Process -Force -ErrorAction Stop
                    Start-Sleep -Seconds 2
                }
            }
            else {
                throw 'Related background processes are still running.'
            }
        }

        $bytesBefore = Get-TargetBytes -LiteralPath $resolved
        $result.BeforeGB = [math]::Round($bytesBefore / 1GB, 3)

        if (-not $Execute) {
            $result.Status = 'WouldDelete'
            $results += [pscustomobject]$result
            continue
        }

        switch ($mode) {
            'File' {
                Remove-Item -LiteralPath $resolved -Force -ErrorAction Stop
            }
            'Contents' {
                Get-ChildItem -LiteralPath $resolved -Force -ErrorAction Stop |
                    Remove-Item -Recurse -Force -ErrorAction Stop
            }
            'Whole' {
                Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction Stop
            }
        }

        $bytesAfter = Get-TargetBytes -LiteralPath $resolved
        $result.AfterGB = [math]::Round($bytesAfter / 1GB, 3)
        $result.FreedGB = [math]::Round(($bytesBefore - $bytesAfter) / 1GB, 3)
        $result.Status = 'Deleted'
    }
    catch {
        $result.Error = $_.Exception.Message
    }
    $results += [pscustomobject]$result
}

$keepChecks = @()
foreach ($keep in @($plan.keep)) {
    $keepPath = [string]$keep.path
    if ([string]::IsNullOrWhiteSpace($keepPath)) {
        continue
    }
    $resolvedKeep = [System.IO.Path]::GetFullPath($keepPath).TrimEnd('\')
    $keepItem = Get-Item -LiteralPath $resolvedKeep -Force -ErrorAction SilentlyContinue
    $keepChecks += [pscustomobject]@{
        Label = [string]$keep.label
        Path = $resolvedKeep
        Exists = $null -ne $keepItem
        SizeGB = $(if ($null -ne $keepItem) {
            [math]::Round((Get-TargetBytes -LiteralPath $resolvedKeep) / 1GB, 3)
        } else {
            0
        })
    }
}

$driveAfter = [System.IO.DriveInfo]::new($env:SystemDrive).AvailableFreeSpace
$targetFreed = (
    $results |
        Measure-Object -Property FreedGB -Sum
).Sum
if ($null -eq $targetFreed) {
    $targetFreed = 0
}

[pscustomobject]@{
    SchemaVersion = 2
    Execute = [bool]$Execute
    DeletionBypassesRecycleBin = [bool]$Execute
    FreeBeforeGB = [math]::Round($driveBefore / 1GB, 3)
    FreeAfterGB = [math]::Round($driveAfter / 1GB, 3)
    DriveFreeIncreaseGB = [math]::Round(($driveAfter - $driveBefore) / 1GB, 3)
    TargetFreedGB = [math]::Round($targetFreed, 3)
    Results = @($results)
    KeepChecks = @($keepChecks)
} | ConvertTo-Json -Depth 8
