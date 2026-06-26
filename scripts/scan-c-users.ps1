param(
    [string[]]$Root,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$AdditionalRoot,
    [double]$MinGB = 0.1,
    [int]$Top = 50
)

$ErrorActionPreference = "SilentlyContinue"

function Get-FolderSizeBytes {
    param([string]$Path)

    $bytes = 0L
    if (-not (Test-Path -LiteralPath $Path)) {
        return 0L
    }

    Get-ChildItem -LiteralPath $Path -Force -Recurse -File -ErrorAction SilentlyContinue |
        ForEach-Object { $bytes += $_.Length }
    return $bytes
}

function Get-PathAdvice {
    param([string]$Path)

    $p = $Path.ToLowerInvariant()

    if ($p -match "^c:\\program files( \(x86\))?$") {
        return @("high", "Do not directly delete", "Windows installed application root; inspect child folders instead.")
    }
    if ($p -match "^c:\\program files( \(x86\))?\\") {
        if ($p -match "\\(cache|caches|temp|tmp|logs?)$") {
            return @("medium", "Ask; prefer app cleanup first", "Application cache, temp, or log folder under Program Files.")
        }
        return @("high", "Do not directly delete; uninstall or use app cleanup", "Installed application files or app-managed data.")
    }
    if ($p -match "\\all users$" -or $p -match "\\default user$" -or $p -match "\\default$" -or $p -match "\\public$" -or $p -match "\\administrator$") {
        return @("high", "Do not directly delete", "Windows profile, shared profile, or compatibility junction.")
    }
    if ($p -match "^c:\\users\\[^\\]+$") {
        return @("high", "Do not directly delete", "Whole Windows user profile; inspect child folders instead.")
    }
    if ($p -match "\\downloads$") {
        return @("medium", "Ask; installers are often safe after use", "Downloaded files and installers; verify personal files first.")
    }
    if ($p -match "\\downloads\\.*\.(exe|msi)$") {
        return @("low", "Ask; usually safe if installed", "Installer package; delete only if no longer needed.")
    }
    if ($p -match "\\appdata\\local\\temp$") {
        return @("low", "Ask; delete contents only after closing apps", "Temporary files. Some files may be in use.")
    }
    if ($p -match "\\crashdumps$") {
        return @("low", "Ask; usually safe", "Application crash dumps.")
    }
    if ($p -match "\\pip\\cache$") {
        return @("low", "Use pip cache purge", "Python package cache.")
    }
    if ($p -match "\\npm-cache$") {
        return @("low", "Use npm cache clean --force", "Node package cache.")
    }
    if ($p -match "\\\.conda\\pkgs$") {
        return @("low", "Use conda clean --all", "Conda package cache.")
    }
    if ($p -match "\\\.conda\\envs(\\|$)") {
        return @("high", "Do not directly delete; use conda env remove", "Conda environments may contain active project dependencies.")
    }
    if ($p -match "\\xwechat_files(\\|$)" -or $p -match "\\tencent\\xwechat(\\|$)") {
        return @("high", "Use WeChat storage manager first", "WeChat chat files, attachments, images, videos, or app data.")
    }
    if ($p -match "\\wpsdrive(\\|$)" -or $p -match "\\wps cloud files(\\|$)") {
        return @("high", "Use WPS cleanup; inspect before deleting", "WPS cloud sync, offline files, cache, or account data.")
    }
    if ($p -match "\\cachedata$") {
        return @("medium", "Ask; cache folder may be deleted after app is closed and sync is complete", "App cache data.")
    }
    if ($p -match "\\baidunetdisk(\\|$)" -or $p -match "\\baidu\\baidunetdisk(\\|$)") {
        return @("medium", "Use Baidu Netdisk cleanup first", "Cloud drive cache, downloads, or app data.")
    }
    if ($p -match "\\larkshell(\\|$)" -or $p -match "\\dingtalk(\\|$)") {
        return @("medium", "Use app cleanup or inspect cache subfolders", "Work chat app data and cache.")
    }
    if ($p -match "\\jetbrains(\\|$)") {
        return @("medium", "Use IDE cache cleanup first", "IDE caches, indexes, logs, or settings.")
    }
    if ($p -match "\\appdata\\local\\microsoft(\\|$)" -or $p -match "\\appdata\\local\\packages(\\|$)" -or $p -match "\\appdata\\roaming\\microsoft(\\|$)") {
        return @("high", "Do not directly delete", "Windows or Microsoft app data.")
    }
    if ($p -match "\\documents$" -or $p -match "\\desktop$" -or $p -match "\\pictures$" -or $p -match "\\videos$") {
        return @("high", "Do not directly delete", "Personal files may not have backups.")
    }

    return @("unknown", "Inspect before recommending deletion", "Unknown or mixed folder contents.")
}

function New-ReportRow {
    param([string]$Path, [long]$Bytes)

    $advice = Get-PathAdvice -Path $Path
    [PSCustomObject]@{
        SizeGB = [math]::Round($Bytes / 1GB, 2)
        Risk = $advice[0]
        DirectDelete = $advice[1]
        Contents = $advice[2]
        Path = $Path
    }
}

if ($AdditionalRoot -and $AdditionalRoot.Count -gt 0) {
    $Root = @($Root) + @($AdditionalRoot)
}

if (-not $Root -or $Root.Count -eq 0) {
    $Root = @(
        "$env:SystemDrive\Users",
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)}
    )
}

$scanRoots = @()
foreach ($entry in $Root) {
    if ([string]::IsNullOrWhiteSpace($entry)) {
        continue
    }
    if (Test-Path -LiteralPath $entry) {
        $scanRoots += [System.IO.Path]::GetFullPath($entry).TrimEnd('\')
    } else {
        Write-Warning "Root path does not exist and will be skipped: $entry"
    }
}

$scanRoots = $scanRoots | Sort-Object -Unique
if (-not $scanRoots -or $scanRoots.Count -eq 0) {
    Write-Error "No valid root paths to scan."
    exit 1
}

$rows = @()

foreach ($scanRoot in $scanRoots) {
    Get-ChildItem -LiteralPath $scanRoot -Force -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $bytes = Get-FolderSizeBytes -Path $_.FullName
        if (($bytes / 1GB) -ge $MinGB) {
            $rows += New-ReportRow -Path $_.FullName -Bytes $bytes
        }
    }
}

$knownTargets = @(
    "$env:USERPROFILE\Downloads",
    "$env:USERPROFILE\AppData\Local\Temp",
    "$env:USERPROFILE\AppData\Local\CrashDumps",
    "$env:USERPROFILE\AppData\Local\pip\cache",
    "$env:USERPROFILE\AppData\Local\npm-cache",
    "$env:USERPROFILE\.conda\pkgs",
    "$env:USERPROFILE\.conda\envs",
    "$env:USERPROFILE\Documents\xwechat_files",
    "$env:USERPROFILE\AppData\Roaming\Tencent\xwechat",
    "$env:USERPROFILE\WPSDrive",
    "$env:USERPROFILE\WPS Cloud Files",
    "$env:USERPROFILE\AppData\Roaming\BaiduNetdisk",
    "$env:USERPROFILE\AppData\Roaming\baidu\BaiduNetdisk",
    "$env:USERPROFILE\AppData\Roaming\LarkShell",
    "$env:USERPROFILE\AppData\Local\JetBrains",
    "$env:ProgramFiles\Common Files",
    "${env:ProgramFiles(x86)}\Common Files"
)

function Test-UnderScanRoots {
    param([string]$Path)

    $targetFull = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    foreach ($scanRoot in $scanRoots) {
        if ($targetFull.Equals($scanRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
            $targetFull.StartsWith($scanRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

foreach ($target in $knownTargets) {
    if (Test-Path -LiteralPath $target) {
        if (-not (Test-UnderScanRoots -Path $target)) {
            continue
        }
        $bytes = Get-FolderSizeBytes -Path $target
        if (($bytes / 1GB) -ge $MinGB) {
            $rows += New-ReportRow -Path $target -Bytes $bytes
        }
    }
}

$uniqueRows = @{}
foreach ($row in $rows) {
    $uniqueRows[$row.Path] = $row
}

Write-Output "SizeGB`tRisk`tDirectDelete`tContents`tPath"
$uniqueRows.Values |
    Sort-Object SizeGB -Descending |
    Select-Object -First $Top |
    ForEach-Object {
        "{0}`t{1}`t{2}`t{3}`t{4}" -f $_.SizeGB, $_.Risk, $_.DirectDelete, $_.Contents, $_.Path
    }

Write-Output ""
Write-Output "Safety note: this scanner is read-only. Do not delete anything until the user confirms the exact path or file group."
