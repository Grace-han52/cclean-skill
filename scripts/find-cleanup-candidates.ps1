[CmdletBinding()]
param(
    [ValidateSet('Quick', 'Audit')]
    [string]$Mode = 'Audit',

    [ValidateRange(1, 102400)]
    [int]$MinCandidateMB = 50,

    [ValidateRange(10, 102400)]
    [int]$BigFileMinMB = 200,

    [ValidateRange(10, 102400)]
    [int]$DuplicateMinMB = 200,

    [ValidateSet('Json', 'Table')]
    [string]$OutputFormat = 'Json',

    [string]$UserProfilePath = $env:USERPROFILE
)

$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$candidates = @()
$largeFiles = @()
$duplicateGroups = @()
$policyNotes = @()

function Get-RobocopyBytes {
    param([Parameter(Mandatory)][string]$LiteralPath)

    $item = Get-Item -LiteralPath $LiteralPath -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) {
        return 0L
    }
    if (-not $item.PSIsContainer) {
        return [int64]$item.Length
    }
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        return 0L
    }

    $robocopy = Join-Path $env:SystemRoot 'System32\robocopy.exe'
    $nullTarget = Join-Path $env:SystemDrive '__cclean_scan_null__'
    $output = @(
        & $robocopy $item.FullName $nullTarget /L /E /BYTES /XJ /R:0 /W:0 /NFL /NDL /NJH 2>&1
    )
    $text = $output -join [Environment]::NewLine
    if ($text -match '(?m)^\s*Bytes\s*:\s*(\d+)') {
        return [int64]$matches[1]
    }
    return 0L
}

function Add-Candidate {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string[]]$Paths,
        [Parameter(Mandatory)][long]$Bytes,
        [Parameter(Mandatory)][ValidateSet('low', 'medium', 'high', 'forbidden')][string]$Risk,
        [Parameter(Mandatory)][ValidateSet('File', 'Contents', 'Whole', 'AppCleanup', 'ManualReview', 'Forbidden')][string]$Mode,
        [Parameter(Mandatory)][string]$Evidence,
        [Parameter(Mandatory)][string]$PreferredAction,
        [Parameter(Mandatory)][string]$MayLose,
        [string[]]$RequiresClose = @(),
        [bool]$Regenerable = $false
    )

    if ($Bytes -lt ($MinCandidateMB * 1MB)) {
        return
    }
    $script:candidates += [pscustomobject]@{
        Label = $Label
        Paths = @($Paths)
        SizeGB = [math]::Round($Bytes / 1GB, 3)
        Risk = $Risk
        Mode = $Mode
        Evidence = $Evidence
        PreferredAction = $PreferredAction
        MayLose = $MayLose
        RequiresClose = @($RequiresClose)
        Regenerable = $Regenerable
        RequiresExplicitConfirmation = $true
    }
}

function Add-CachePath {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$Path,
        [string[]]$Processes = @(),
        [string]$Evidence = 'Named application cache directory'
    )

    $bytes = Get-RobocopyBytes -LiteralPath $Path
    Add-Candidate `
        -Label $Label `
        -Paths @($Path) `
        -Bytes $bytes `
        -Risk 'low' `
        -Mode 'Contents' `
        -Evidence $Evidence `
        -PreferredAction 'Prefer the application cleanup UI; otherwise clear only this cache directory after approval.' `
        -MayLose 'Cached resources and offline copies; the application may re-download them.' `
        -RequiresClose $Processes `
        -Regenerable $true
}

$local = Join-Path $UserProfilePath 'AppData\Local'
$roaming = Join-Path $UserProfilePath 'AppData\Roaming'
$documents = Join-Path $UserProfilePath 'Documents'
$downloads = Join-Path $UserProfilePath 'Downloads'

Add-CachePath `
    -Label 'Application crash dumps' `
    -Path (Join-Path $local 'CrashDumps') `
    -Processes @() `
    -Evidence 'Windows application crash diagnostic directory'

$browserDefinitions = @(
    @{
        Name = 'Chrome'
        Root = Join-Path $local 'Google\Chrome\User Data'
        Processes = @('chrome')
    }
    @{
        Name = 'Edge'
        Root = Join-Path $local 'Microsoft\Edge\User Data'
        Processes = @('msedge')
    }
)
$browserRelativeCaches = @(
    'Default\Service Worker\CacheStorage',
    'Default\Cache',
    'Default\Code Cache',
    'Default\GPUCache',
    'Default\DawnWebGPUCache',
    'GrShaderCache',
    'ShaderCache',
    'Default\Shared Dictionary\cache'
)
foreach ($browser in $browserDefinitions) {
    foreach ($relative in $browserRelativeCaches) {
        $path = Join-Path $browser.Root $relative
        Add-CachePath `
            -Label "$($browser.Name) $relative" `
            -Path $path `
            -Processes $browser.Processes `
            -Evidence 'Browser cache path; profile databases, bookmarks, passwords, and extensions are outside this target.'
    }
}

$larkUsers = Join-Path $roaming 'LarkShell\aha\users'
if (Test-Path -LiteralPath $larkUsers) {
    $userDirectories = @(
        Get-ChildItem -LiteralPath $larkUsers -Directory -Force -ErrorAction SilentlyContinue
    )
    foreach ($userDirectory in $userDirectories) {
        $cacheStorage = Join-Path $userDirectory.FullName 'profile_explorer\Service Worker\CacheStorage'
        Add-CachePath `
            -Label 'Feishu Service Worker CacheStorage' `
            -Path $cacheStorage `
            -Processes @('Feishu', 'Lark') `
            -Evidence 'Feishu web-resource cache. Account profile and IndexedDB are outside this target.'
    }
}

$tempRoot = Join-Path $local 'Temp'
if (Test-Path -LiteralPath $tempRoot) {
    $tempChildren = @(
        Get-ChildItem -LiteralPath $tempRoot -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object {
                ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0
            }
    )
    foreach ($child in $tempChildren) {
        $bytes = Get-RobocopyBytes -LiteralPath $child.FullName
        if ($bytes -lt ($MinCandidateMB * 1MB)) {
            continue
        }
        $installerFiles = @(
            Get-ChildItem -LiteralPath $child.FullName -File -Recurse -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -in @('.msi', '.msp', '.cab', '.vsix') } |
                Select-Object -First 5
        )
        if ($installerFiles.Count -gt 0) {
            Add-Candidate `
                -Label 'Temporary installer extraction' `
                -Paths @($child.FullName) `
                -Bytes $bytes `
                -Risk 'medium' `
                -Mode 'Whole' `
                -Evidence "Temporary child contains installer payloads: $($installerFiles.Name -join ', ')" `
                -PreferredAction 'Confirm the related installer or updater is finished, close it, then remove this exact Temp child.' `
                -MayLose 'A pending installation or repair may need these files.' `
                -RequiresClose @('devenv', 'vs_installer', 'setup') `
                -Regenerable $true
        }
    }
}

$wpsRoot = Join-Path $local 'kingsoft\WPS Office'
if (Test-Path -LiteralPath $wpsRoot) {
    $wpsVersions = @(
        Get-ChildItem -LiteralPath $wpsRoot -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^\d+(\.\d+)+$' } |
            Sort-Object { try { [version]$_.Name } catch { [version]'0.0' } } -Descending
    )
    if ($wpsVersions.Count -gt 1) {
        $current = $wpsVersions[0]
        foreach ($old in $wpsVersions | Select-Object -Skip 1) {
            $bytes = Get-RobocopyBytes -LiteralPath $old.FullName
            Add-Candidate `
                -Label "WPS old version $($old.Name)" `
                -Paths @($old.FullName) `
                -Bytes $bytes `
                -Risk 'medium' `
                -Mode 'AppCleanup' `
                -Evidence "A newer WPS version directory exists: $($current.Name)." `
                -PreferredAction 'Prefer WPS update/repair cleanup. Remove only the verified older version after approval.' `
                -MayLose 'Rollback files for the older WPS version.' `
                -RequiresClose @('wps', 'wpp', 'et', 'wpscloudsvr') `
                -Regenerable $true
        }
    }
}

$wpsBackup = Join-Path $roaming 'kingsoft\office6\backup'
$wpsBackupBytes = Get-RobocopyBytes -LiteralPath $wpsBackup
Add-Candidate `
    -Label 'WPS document recovery backups' `
    -Paths @($wpsBackup) `
    -Bytes $wpsBackupBytes `
    -Risk 'high' `
    -Mode 'ManualReview' `
    -Evidence 'WPS backup directory can contain recovery copies of unsaved documents.' `
    -PreferredAction 'Review in WPS Backup Center and choose individual obsolete backups.' `
    -MayLose 'The only recoverable copy of unsaved or overwritten work.' `
    -RequiresClose @('wps', 'wpp', 'et') `
    -Regenerable $false

if (Test-Path -LiteralPath $downloads) {
    $downloadInstallers = @(
        Get-ChildItem -LiteralPath $downloads -File -Force -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Extension -in @('.exe', '.msi') -and $_.Length -ge ($MinCandidateMB * 1MB)
            }
    )
    foreach ($file in $downloadInstallers) {
        Add-Candidate `
            -Label 'Downloaded installer' `
            -Paths @($file.FullName) `
            -Bytes $file.Length `
            -Risk 'low' `
            -Mode 'File' `
            -Evidence 'Installer file in Downloads. Verify the matching software is installed and no offline reinstall is needed.' `
            -PreferredAction 'Delete the exact installer after approval.' `
            -MayLose 'Offline reinstall or rollback without downloading again.' `
            -Regenerable $true
    }
}

$updaterDirectories = @(
    Get-ChildItem -LiteralPath $local -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '(?i)updater|update' }
)
foreach ($updater in $updaterDirectories) {
    $payloads = @(
        Get-ChildItem -LiteralPath $updater.FullName -File -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Extension -in @('.exe', '.msi') -and $_.Length -ge ($MinCandidateMB * 1MB)
            }
    )
    foreach ($payload in $payloads) {
        Add-Candidate `
            -Label 'Application updater payload' `
            -Paths @($payload.FullName) `
            -Bytes $payload.Length `
            -Risk 'medium' `
            -Mode 'File' `
            -Evidence "Large installer payload under updater directory $($updater.Name)." `
            -PreferredAction 'Finish or abandon the update, close the application, then delete the exact payload after approval.' `
            -MayLose 'A pending update may need this installer.' `
            -Regenerable $true
    }
}

$searchRoots = @($downloads)
if ($Mode -eq 'Audit') {
    $searchRoots += $documents
}
$allLargeFiles = @()
foreach ($root in $searchRoots | Select-Object -Unique) {
    if (-not (Test-Path -LiteralPath $root)) {
        continue
    }
    $allLargeFiles += @(
        Get-ChildItem -LiteralPath $root -File -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Length -ge ($BigFileMinMB * 1MB) }
    )
}
$largeFiles = @(
    $allLargeFiles |
        Sort-Object Length -Descending |
        Select-Object -First 100 |
        ForEach-Object {
            [pscustomobject]@{
                Path = $_.FullName
                SizeGB = [math]::Round($_.Length / 1GB, 3)
                Extension = $_.Extension
                LastWriteTime = $_.LastWriteTime
                Recommendation = $(if ($_.Extension -in @('.exe', '.msi')) {
                    'Installer candidate; verify installed software and offline-reinstall needs.'
                } else {
                    'Manual review; size alone is not deletion evidence.'
                })
            }
        }
)

if ($Mode -eq 'Audit') {
    $duplicateCandidates = @(
        $allLargeFiles |
            Where-Object { $_.Length -ge ($DuplicateMinMB * 1MB) } |
            Group-Object Name, Length |
            Where-Object { $_.Count -gt 1 }
    )
    foreach ($group in $duplicateCandidates) {
        $hashed = @(
            $group.Group | ForEach-Object {
                $hash = Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256 -ErrorAction SilentlyContinue
                [pscustomobject]@{
                    Path = $_.FullName
                    SizeGB = [math]::Round($_.Length / 1GB, 3)
                    SHA256 = $hash.Hash
                }
            }
        )
        $matchingHashGroups = @(
            $hashed |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_.SHA256) } |
                Group-Object SHA256 |
                Where-Object { $_.Count -gt 1 }
        )
        foreach ($hashGroup in $matchingHashGroups) {
            $duplicateGroups += [pscustomobject]@{
                Name = $group.Group[0].Name
                SHA256 = $hashGroup.Name
                SizePerCopyGB = $hashGroup.Group[0].SizeGB
                CopyCount = $hashGroup.Count
                PotentialReclaimGB = [math]::Round(
                    $hashGroup.Group[0].SizeGB * ($hashGroup.Count - 1),
                    3
                )
                Paths = @($hashGroup.Group.Path)
                Action = 'Keep one named copy and explicitly approve each duplicate copy to delete.'
            }
        }
    }
}

$condaCommand = Get-Command conda -ErrorAction SilentlyContinue
if ($null -ne $condaCommand) {
    $condaOutput = @(& $condaCommand.Source clean --all --dry-run --json 2>$null)
    try {
        $condaDryRun = ($condaOutput -join [Environment]::NewLine) | ConvertFrom-Json
        $condaBytes = [int64]0
        if ($null -ne $condaDryRun.packages.total_size) {
            $condaBytes += [int64]$condaDryRun.packages.total_size
        }
        if ($null -ne $condaDryRun.tarballs.total_size) {
            $condaBytes += [int64]$condaDryRun.tarballs.total_size
        }
        if ($condaBytes -ge ($MinCandidateMB * 1MB)) {
            Add-Candidate `
                -Label 'Conda dry-run reclaimable cache' `
                -Paths @((Join-Path $UserProfilePath '.conda\pkgs')) `
                -Bytes $condaBytes `
                -Risk 'low' `
                -Mode 'AppCleanup' `
                -Evidence 'conda clean --all --dry-run --json reported reclaimable packages or tarballs.' `
                -PreferredAction 'Run conda clean --all only after approval.' `
                -MayLose 'Cached packages that would otherwise support offline environment creation.' `
                -Regenerable $true
        }
        else {
            $policyNotes += 'Conda dry-run reported no reclaimable cache. Do not manually delete .conda\pkgs.'
        }
    }
    catch {
        $policyNotes += "Conda dry-run output could not be parsed: $($_.Exception.Message)"
    }
}

$registryPaths = @(
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
)
$installedApplications = @(
    Get-ItemProperty $registryPaths -ErrorAction SilentlyContinue |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_.DisplayName) } |
        ForEach-Object {
            [pscustomobject]@{
                Name = $_.DisplayName
                Version = $_.DisplayVersion
                Publisher = $_.Publisher
                EstimatedGB = $(if ($_.EstimatedSize) {
                    [math]::Round($_.EstimatedSize / 1MB, 3)
                } else {
                    $null
                })
                InstallLocation = $_.InstallLocation
                InstallDate = $_.InstallDate
            }
        } |
        Sort-Object Name -Unique
)

$policyNotes += @(
    'Discovery is read-only and does not authorize deletion.',
    'Installed dependencies and download caches are different categories.',
    'Prefer application-native cleanup for chat, cloud, browser, IDE, and vendor-managed data.',
    'Last-write and installed-app metadata are clues, not proof that an application is unused.'
)

$report = [pscustomobject]@{
    SchemaVersion = 2
    ReadOnly = $true
    Mode = $Mode
    GeneratedAt = (Get-Date).ToString('o')
    Candidates = @($candidates | Sort-Object SizeGB -Descending)
    LargeFiles = @($largeFiles)
    ConfirmedDuplicateGroups = @($duplicateGroups | Sort-Object PotentialReclaimGB -Descending)
    InstalledApplications = @($installedApplications | Sort-Object EstimatedGB -Descending)
    PolicyNotes = @($policyNotes)
}

if ($OutputFormat -eq 'Json') {
    $report | ConvertTo-Json -Depth 8
    exit 0
}

Write-Output '[Cleanup candidates]'
$report.Candidates |
    Select-Object SizeGB, Risk, Mode, Label, Evidence |
    Format-Table -AutoSize
Write-Output ''
Write-Output '[Large files]'
$report.LargeFiles | Format-Table -AutoSize
Write-Output ''
Write-Output '[Confirmed duplicate groups]'
$report.ConfirmedDuplicateGroups |
    Select-Object PotentialReclaimGB, CopyCount, Name, SHA256 |
    Format-Table -AutoSize
Write-Output ''
$report.PolicyNotes | ForEach-Object { Write-Output "- $_" }
