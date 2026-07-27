[CmdletBinding()]
param(
    [ValidateSet('Quick', 'Audit', 'DeepSystem')]
    [string]$Mode = 'Audit',

    [ValidateRange(0.001, 1000)]
    [double]$MinGB = 0.05,

    [ValidateRange(1, 200)]
    [int]$Top = 40,

    [ValidateSet('Json', 'Table')]
    [string]$OutputFormat = 'Json',

    [string]$UserProfilePath = $env:USERPROFILE
)

$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

function Get-NormalizedPath {
    param([Parameter(Mandatory)][string]$LiteralPath)

    return [System.IO.Path]::GetFullPath($LiteralPath).TrimEnd('\')
}

function Get-RobocopyMetric {
    param([Parameter(Mandatory)][string]$LiteralPath)

    $normalized = Get-NormalizedPath -LiteralPath $LiteralPath
    $item = Get-Item -LiteralPath $normalized -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) {
        return [pscustomobject]@{
            Bytes = 0L
            Exists = $false
            Accessible = $false
            Error = 'Not found'
        }
    }
    if (-not $item.PSIsContainer) {
        return [pscustomobject]@{
            Bytes = [int64]$item.Length
            Exists = $true
            Accessible = $true
            Error = ''
        }
    }
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        return [pscustomobject]@{
            Bytes = 0L
            Exists = $true
            Accessible = $false
            Error = 'Reparse point skipped'
        }
    }

    $robocopy = Join-Path $env:SystemRoot 'System32\robocopy.exe'
    $nullTarget = Join-Path $env:SystemDrive '__cclean_scan_null__'
    $output = @(
        & $robocopy $normalized $nullTarget /L /E /BYTES /XJ /R:0 /W:0 /NFL /NDL /NJH 2>&1
    )
    $text = $output -join [Environment]::NewLine
    $bytes = 0L
    if ($text -match '(?m)^\s*Bytes\s*:\s*(\d+)') {
        $bytes = [int64]$matches[1]
    }
    $accessDenied = $text -match '(?i)access is denied|error\s+5'

    return [pscustomobject]@{
        Bytes = $bytes
        Exists = $true
        Accessible = -not $accessDenied
        Error = $(if ($accessDenied) { 'Access denied or partially inaccessible' } else { '' })
    }
}

function New-SizeRow {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Metric,
        [string]$Category = ''
    )

    return [pscustomobject]@{
        Path = $Path
        Category = $Category
        SizeGB = [math]::Round(([int64]$Metric.Bytes / 1GB), 3)
        Exists = [bool]$Metric.Exists
        Accessible = [bool]$Metric.Accessible
        Note = [string]$Metric.Error
    }
}

function Get-DirectoryBreakdown {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][double]$MinimumGB,
        [Parameter(Mandatory)][int]$Limit
    )

    $rows = @()
    $children = @(
        Get-ChildItem -LiteralPath $Root -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object {
                ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0
            }
    )
    foreach ($child in $children) {
        $metric = Get-RobocopyMetric -LiteralPath $child.FullName
        if (($metric.Bytes / 1GB) -ge $MinimumGB) {
            $rows += New-SizeRow -Path $child.FullName -Metric $metric
        }
    }
    return @($rows | Sort-Object SizeGB -Descending | Select-Object -First $Limit)
}

$drive = [System.IO.DriveInfo]::new($env:SystemDrive)
$totalBytes = [int64]$drive.TotalSize
$freeBytes = [int64]$drive.AvailableFreeSpace
$usedBytes = $totalBytes - $freeBytes

$rootDefinitions = @(
    @{ Path = Join-Path $env:SystemDrive 'Users'; Category = 'User profiles' }
    @{ Path = Join-Path $env:SystemDrive 'Windows'; Category = 'Windows system' }
    @{ Path = $env:ProgramFiles; Category = 'Installed applications' }
    @{ Path = ${env:ProgramFiles(x86)}; Category = 'Installed 32-bit applications' }
    @{ Path = $env:ProgramData; Category = 'Shared application data' }
    @{ Path = Join-Path $env:SystemDrive '$Recycle.Bin'; Category = 'Recycle Bin' }
    @{ Path = Join-Path $env:SystemDrive 'Recovery'; Category = 'Recovery environment' }
    @{ Path = Join-Path $env:SystemDrive 'System Volume Information'; Category = 'Restore points and volume metadata' }
    @{ Path = Join-Path $env:SystemDrive 'Config.Msi'; Category = 'Installer rollback data' }
)

$ledger = @()
foreach ($definition in $rootDefinitions) {
    if ([string]::IsNullOrWhiteSpace($definition.Path)) {
        continue
    }
    $metric = Get-RobocopyMetric -LiteralPath $definition.Path
    if ($metric.Exists) {
        $ledger += New-SizeRow -Path $definition.Path -Metric $metric -Category $definition.Category
    }
}

$rootFileNames = @(
    'pagefile.sys',
    'swapfile.sys',
    'hiberfil.sys',
    'MEMORY.DMP',
    'DumpStack.log.tmp'
)
foreach ($name in $rootFileNames) {
    $path = Join-Path $env:SystemDrive $name
    $metric = Get-RobocopyMetric -LiteralPath $path
    if ($metric.Exists) {
        $ledger += New-SizeRow -Path $path -Metric $metric -Category 'Root system file'
    }
}

$visibleBytes = [int64]0
foreach ($row in $ledger) {
    if ($row.Accessible) {
        $visibleBytes += [int64]([math]::Round($row.SizeGB * 1GB))
    }
}
$gapDifference = [int64]($usedBytes - $visibleBytes)
$gapBytes = $(if ($gapDifference -gt 0) { $gapDifference } else { 0L })

$breakdowns = [ordered]@{}
if ($Mode -in @('Audit', 'DeepSystem')) {
    $auditRoots = [ordered]@{
        UserProfile = $UserProfilePath
        AppData = (Join-Path $UserProfilePath 'AppData')
        AppDataLocal = (Join-Path $UserProfilePath 'AppData\Local')
        AppDataRoaming = (Join-Path $UserProfilePath 'AppData\Roaming')
        Documents = (Join-Path $UserProfilePath 'Documents')
        ProgramData = $env:ProgramData
        ProgramFiles = $env:ProgramFiles
        ProgramFilesX86 = ${env:ProgramFiles(x86)}
        Windows = (Join-Path $env:SystemDrive 'Windows')
    }
    foreach ($name in $auditRoots.Keys) {
        $path = $auditRoots[$name]
        if (-not [string]::IsNullOrWhiteSpace($path) -and (Test-Path -LiteralPath $path)) {
            $breakdowns[$name] = @(
                Get-DirectoryBreakdown -Root $path -MinimumGB $MinGB -Limit $Top
            )
        }
    }
}

$systemNotes = @(
    'Directory totals are logical sizes. NTFS hard links can make Windows subdirectories overlap.',
    'Reparse points and junctions are skipped.',
    'Protected paths can remain partially or wholly inaccessible without elevation.',
    'Use elevated DISM AnalyzeComponentStore for reclaimable WinSxS size.',
    'Use elevated vssadmin list shadowstorage for restore-point and shadow-copy usage.'
)
if ($Mode -eq 'DeepSystem') {
    $systemNotes += @(
        'DeepSystem mode reports visible system sizes but does not delete or run elevated cleanup.',
        'Never manually delete WinSxS, Windows Installer, Package Cache, pagefile, swapfile, or hiberfil.'
    )
}

$report = [pscustomobject]@{
    SchemaVersion = 2
    ReadOnly = $true
    Mode = $Mode
    GeneratedAt = (Get-Date).ToString('o')
    Drive = [pscustomobject]@{
        Name = $drive.Name
        TotalGB = [math]::Round($totalBytes / 1GB, 3)
        UsedGB = [math]::Round($usedBytes / 1GB, 3)
        FreeGB = [math]::Round($freeBytes / 1GB, 3)
        FreePercent = [math]::Round(100 * $freeBytes / $totalBytes, 1)
        VisibleLogicalGB = [math]::Round($visibleBytes / 1GB, 3)
        ProtectedOrUnattributedLowerBoundGB = [math]::Round($gapBytes / 1GB, 3)
    }
    Ledger = @($ledger | Sort-Object SizeGB -Descending)
    Breakdowns = $breakdowns
    Notes = $systemNotes
}

if ($OutputFormat -eq 'Json') {
    $report | ConvertTo-Json -Depth 8
    exit 0
}

$report.Drive | Format-List
$report.Ledger | Format-Table -AutoSize
foreach ($name in $breakdowns.Keys) {
    Write-Output ''
    Write-Output "[$name]"
    $breakdowns[$name] | Format-Table -AutoSize
}
Write-Output ''
$systemNotes | ForEach-Object { Write-Output "- $_" }
