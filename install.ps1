#Requires -Version 5.1
<#
.SYNOPSIS
  Installs, updates, or removes Spotifast for Windows.

.DESCRIPTION
  Downloads the official Spotifast MSI from GitHub, verifies its published
  SHA-256 checksum, installs it per-user with msiexec, and adds a small manual
  updater to %LOCALAPPDATA%\Spotifast\bin.

  Spotifast also has a built-in updater. This script is the installer and the
  manual fallback.

.EXAMPLE
  irm https://raw.githubusercontent.com/imdonix/spotifast-install/main/install.ps1 | iex

.EXAMPLE
  .\install.ps1 -Version 0.14.1

.EXAMPLE
  .\install.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [string]$Version,
    [switch]$Update,
    [switch]$Check,
    [switch]$Uninstall,
    [switch]$Purge,
    [switch]$Force,
    [Alias('h')]
    [switch]$Help
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

try {
    [System.Net.ServicePointManager]::SecurityProtocol =
        [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
} catch {
}

$Repo = 'crmne/spotifast'
$AppDir = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'Programs\Spotifast' } else { $null }
$AppExe = if ($AppDir) { Join-Path $AppDir 'Spotifast.exe' } else { $null }
$BinDir = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'Spotifast\bin' } else { $null }
$StateDir = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'Spotifast\installer' } else { $null }
$UpdateScript = if ($BinDir) { Join-Path $BinDir 'spotifast-update.ps1' } else { $null }
$UpdateCmd = if ($BinDir) { Join-Path $BinDir 'spotifast-update.cmd' } else { $null }
$StartMenuDir = if ($env:APPDATA) { Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Spotifast' } else { $null }
$ShortcutPath = if ($StartMenuDir) { Join-Path $StartMenuDir 'Check for Updates.lnk' } else { $null }
$RawBase = if ($env:SPOTIFAST_REPO_RAW) { $env:SPOTIFAST_REPO_RAW } else { 'https://raw.githubusercontent.com/imdonix/spotifast-install/main' }
$AssetArch = $null

$PubKeyPem = @'
-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEA5EyHsVUEhMaHlHvZJ64zP/QxzHrcbMM1M8Yo+CAWtVQ=
-----END PUBLIC KEY-----
'@

function Show-Usage {
    Write-Host @'
Spotifast installer for Windows

Usage:
  install.ps1                    install or update to the latest release
  install.ps1 -Version X.Y.Z     install a specific release
  install.ps1 -Update            check and install updates
  install.ps1 -Check             only report whether an update is available
  install.ps1 -Uninstall         remove Spotifast, keep settings
  install.ps1 -Uninstall -Purge  remove Spotifast and local app data
  install.ps1 -Force             continue when the Windows version check fails
  install.ps1 -Help              show this help

The same script is installed as:
  %LOCALAPPDATA%\Spotifast\bin\spotifast-update.ps1
  %LOCALAPPDATA%\Spotifast\bin\spotifast-update.cmd

Spotifast also updates itself from inside the app. The commands above are the
manual installer and update fallback.
'@
}

function Write-Info {
    param([string]$Message)
    Write-Host "==> $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Warning $Message
}

function Write-Err {
    param([string]$Message)
    Write-Host "error: $Message" -ForegroundColor Red
}

function Fail {
    param([string]$Message)
    Write-Err $Message
    exit 1
}

function Normalize-Version {
    param([string]$Value)

    if (-not $Value) { return $null }
    $Value = $Value.Trim()
    $Value = $Value -replace '^[vV]', ''
    if ($Value -notmatch '^\d+(\.\d+){1,3}$') {
        Fail "Invalid version '$Value'. Use a version such as 0.14.1."
    }
    return $Value
}

function ConvertTo-Version {
    param([string]$Value)

    $parts = @($Value -split '\.')
    while ($parts.Count -lt 4) {
        $parts += '0'
    }
    return [version]($parts -join '.')
}

function Test-NewerVersion {
    param([string]$Current, [string]$Latest)

    if (-not $Latest) { return $false }
    if (-not $Current) { return $true }
    try {
        return (ConvertTo-Version $Latest).CompareTo((ConvertTo-Version $Current)) -gt 0
    } catch {
        return $Latest -ne $Current
    }
}

function Get-LatestVersion {
    try {
        $request = [System.Net.HttpWebRequest]::Create("https://github.com/$Repo/releases/latest")
        $request.AllowAutoRedirect = $true
        $request.UserAgent = 'spotifast-install'
        $request.Timeout = 30000
        $response = $request.GetResponse()
        $finalUrl = $response.ResponseUri.AbsoluteUri
        $response.Close()
        if ($finalUrl -match '/tag/v?([0-9][^/?#]*)') {
            return $Matches[1]
        }
    } catch {
    }

    try {
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" `
            -Headers @{ 'User-Agent' = 'spotifast-install' } -UseBasicParsing
        if ($release.tag_name -match '^v?(.+)$') {
            return $Matches[1]
        }
    } catch {
    }

    throw 'Could not determine the latest Spotifast release.'
}

function Get-RemoteFile {
    param(
        [string]$Url,
        [string]$Destination
    )

    $attempt = 0
    while ($attempt -lt 3) {
        $attempt++
        try {
            Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing
            return
        } catch {
            if ($attempt -ge 3) { throw }
            Start-Sleep -Seconds 2
        }
    }
}

function Get-UninstallEntries {
    $roots = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    $entries = @()

    foreach ($root in $roots) {
        if (-not (Test-Path $root)) { continue }
        foreach ($item in Get-ChildItem -Path $root -ErrorAction SilentlyContinue) {
            $props = Get-ItemProperty -Path $item.PSPath -ErrorAction SilentlyContinue
            if ($props.DisplayName -and $props.DisplayName -like 'Spotifast*') {
                $entries += [PSCustomObject]@{
                    Key             = $item.PSChildName
                    DisplayName     = $props.DisplayName
                    DisplayVersion  = $props.DisplayVersion
                    UninstallString = $props.UninstallString
                    InstallLocation = $props.InstallLocation
                }
            }
        }
    }

    return $entries
}

function Get-InstalledVersion {
    if (Test-Path $AppExe) {
        $info = (Get-Item $AppExe).VersionInfo
        $value = $info.ProductVersion
        if (-not $value) { $value = $info.FileVersion }
        if ($value -and $value -match '\d+(\.\d+){1,3}') {
            return $Matches[0]
        }
    }

    $entry = Get-UninstallEntries | Where-Object { $_.DisplayVersion } | Select-Object -First 1
    if ($entry) {
        return $entry.DisplayVersion
    }
    return $null
}

function Find-InstalledApp {
    if (Test-Path $AppExe) { return $AppExe }

    $entry = Get-UninstallEntries | Where-Object { $_.InstallLocation } | Select-Object -First 1
    if ($entry -and $entry.InstallLocation) {
        $candidate = Join-Path $entry.InstallLocation 'Spotifast.exe'
        if (Test-Path $candidate) { return $candidate }
    }
    return $null
}

function Test-ReleaseSignature {
    param([string]$Directory)

    $openssl = Get-Command openssl.exe -ErrorAction SilentlyContinue
    if (-not $openssl) {
        $openssl = Get-Command openssl -ErrorAction SilentlyContinue
    }
    if (-not $openssl) {
        Write-Warn 'openssl was not found; skipping the Ed25519 checksum signature (SHA-256 is still verified).'
        return
    }

    $versionText = & $openssl.Source version 2>$null
    if ($versionText -notmatch '^OpenSSL ([3-9])\.') {
        Write-Warn 'OpenSSL 3 or newer was not found; skipping the Ed25519 checksum signature (SHA-256 is still verified).'
        return
    }

    $keyPath = Join-Path $Directory 'spotifast-update-key.pem'
    Set-Content -Path $keyPath -Value $PubKeyPem -Encoding ASCII
    & $openssl.Source pkeyutl -verify -pubin -inkey $keyPath `
        -rawin -in (Join-Path $Directory 'checksums.txt') `
        -sigfile (Join-Path $Directory 'checksums.txt.sig') *> $null
    if ($LASTEXITCODE -ne 0) {
        throw 'The release signature is not valid.'
    }
}

function Install-Msi {
    param(
        [string]$MsiPath,
        [string]$TargetVersion
    )

    New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
    $msiLog = Join-Path $StateDir 'msiexec.log'
    Unblock-File -Path $MsiPath -ErrorAction SilentlyContinue

    $msiArgs = @(
        '/i',
        ('"' + $MsiPath + '"'),
        '/qn',
        '/norestart',
        '/l*v',
        ('"' + $msiLog + '"')
    )
    $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArgs -Wait -PassThru
    if (@(0, 3010) -notcontains $process.ExitCode) {
        throw "The Spotifast installer failed with exit code $($process.ExitCode). See $msiLog."
    }

    if (-not (Test-Path $AppExe)) {
        $found = Find-InstalledApp
        if ($found) {
            $script:AppExe = $found
        }
    }
    if (-not (Test-Path $AppExe)) {
        throw "The installer finished, but $AppExe was not found."
    }

    Write-Info "Spotifast $TargetVersion installed."
}

function Install-Updater {
    New-Item -ItemType Directory -Path $BinDir -Force | Out-Null
    New-Item -ItemType Directory -Path $StateDir -Force | Out-Null

    $source = $PSCommandPath
    $temporarySource = $false
    if (-not $source -or -not (Test-Path $source)) {
        $source = Join-Path ([System.IO.Path]::GetTempPath()) ('spotifast-install-' + [Guid]::NewGuid().ToString('N') + '.ps1')
        Get-RemoteFile "$RawBase/install.ps1" $source
        $temporarySource = $true
    }

    try {
        Copy-Item -Path $source -Destination $UpdateScript -Force
    } finally {
        if ($temporarySource) {
            Remove-Item -Path $source -Force -ErrorAction SilentlyContinue
        }
    }

    $cmd = @'
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0spotifast-update.ps1" -Update
if errorlevel 1 pause
'@
    Set-Content -Path $UpdateCmd -Value $cmd -Encoding ASCII

    try {
        New-Item -ItemType Directory -Path $StartMenuDir -Force | Out-Null
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($ShortcutPath)
        $shortcut.TargetPath = $UpdateCmd
        $shortcut.WorkingDirectory = $BinDir
        $shortcut.IconLocation = "$AppExe,0"
        $shortcut.Description = 'Check for Spotifast updates'
        $shortcut.Save()
    } catch {
        Write-Warn "The app was installed, but the updater shortcut could not be created: $($_.Exception.Message)"
    }
}

function Install-Spotifast {
    param([string]$TargetVersion)

    if (-not $TargetVersion) {
        Write-Info 'Finding the latest Spotifast release...'
        $TargetVersion = Get-LatestVersion
    }

    $asset = "spotifast-v$TargetVersion-$AssetArch-pc-windows-msvc.msi"
    $base = "https://github.com/$Repo/releases/download/v$TargetVersion"
    $temp = Join-Path ([System.IO.Path]::GetTempPath()) ('spotifast-install-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $temp -Force | Out-Null

    try {
        $msiPath = Join-Path $temp $asset
        $checksumsPath = Join-Path $temp 'checksums.txt'
        $signaturePath = Join-Path $temp 'checksums.txt.sig'

        Write-Info "Downloading Spotifast $TargetVersion for $AssetArch..."
        Get-RemoteFile "$base/$asset" $msiPath
        Get-RemoteFile "$base/checksums.txt" $checksumsPath
        Get-RemoteFile "$base/checksums.txt.sig" $signaturePath

        Write-Info 'Verifying the release...'
        Test-ReleaseSignature $temp

        $line = Get-Content -Path $checksumsPath |
            Where-Object { $_ -match ('\s\*?' + [regex]::Escape($asset) + '$') } |
            Select-Object -First 1
        if (-not $line) {
            throw "The release does not publish a checksum for $asset."
        }
        $expected = ($line -split '\s+')[0].ToLowerInvariant()
        $actual = (Get-FileHash -Path $msiPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $expected) {
            throw 'The downloaded MSI does not match its published checksum.'
        }

        Write-Info 'Installing Spotifast...'
        Install-Msi -MsiPath $msiPath -TargetVersion $TargetVersion

        try {
            Install-Updater
        } catch {
            Write-Warn "The app was installed, but the updater could not be set up: $($_.Exception.Message)"
        }
    } finally {
        Remove-Item -Path $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Update-Spotifast {
    $current = Get-InstalledVersion
    if (-not $current) {
        Fail 'Spotifast is not installed. Run install.ps1 first.'
    }

    $latest = if ($Version) { Normalize-Version $Version } else { Get-LatestVersion }
    if (-not (Test-NewerVersion -Current $current -Latest $latest)) {
        Write-Info "Spotifast $current is up to date."
        return
    }

    if ($Check) {
        Write-Host "Spotifast $latest is available (installed: $current)."
        return
    }

    Write-Info "Updating Spotifast $current -> $latest..."
    Install-Spotifast -TargetVersion $latest
    Write-Info "Updated to Spotifast $latest."
    Write-Host 'Restart Spotifast to use the new version.'
}

function Uninstall-Spotifast {
    $entries = @(Get-UninstallEntries)
    $found = $false

    foreach ($entry in $entries) {
        $found = $true
        Write-Info "Uninstalling $($entry.DisplayName)..."

        if ($entry.UninstallString -match 'msiexec') {
            $productCode = $entry.Key
            if ($entry.UninstallString -match '\{[0-9A-Fa-f-]+\}') {
                $productCode = $Matches[0]
            }
            $process = Start-Process -FilePath 'msiexec.exe' `
                -ArgumentList @('/x', $productCode, '/qn', '/norestart') -Wait -PassThru
            if (@(0, 3010, 1605) -notcontains $process.ExitCode) {
                Write-Warn "msiexec returned exit code $($process.ExitCode) while uninstalling $($entry.DisplayName)."
            }
        } elseif ($entry.UninstallString) {
            $uninstaller = $null
            if ($entry.UninstallString -match '^"([^"]+)"') {
                $uninstaller = $Matches[1]
            } elseif ($entry.UninstallString -match '^(\S+)') {
                $uninstaller = $Matches[1]
            }
            if ($uninstaller -and (Test-Path $uninstaller)) {
                Start-Process -FilePath $uninstaller `
                    -ArgumentList @('/VERYSILENT', '/NORESTART') -Wait
            } else {
                Write-Warn "Could not find the uninstaller for $($entry.DisplayName)."
            }
        }
    }

    if (-not $found) {
        Write-Warn 'No Spotifast uninstall entry was found. The app may already be removed.'
    }

    Remove-Item -Path $UpdateScript, $UpdateCmd, $ShortcutPath -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $StateDir -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path $BinDir) {
        Remove-Item -Path $BinDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path $StartMenuDir) {
        $remaining = @(Get-ChildItem -Path $StartMenuDir -Force -ErrorAction SilentlyContinue)
        if ($remaining.Count -eq 0) {
            Remove-Item -Path $StartMenuDir -Force -ErrorAction SilentlyContinue
        }
    }

    $appData = Join-Path $env:APPDATA 'paolino\spotifast'
    $localData = Join-Path $env:LOCALAPPDATA 'paolino\spotifast'

    if ($Purge) {
        Remove-Item -Path $appData -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -Path $localData -Recurse -Force -ErrorAction SilentlyContinue
        Write-Info 'Removed Spotifast settings, caches, and local state.'
        Write-Host 'Spotify grants in Windows Credential Manager were not touched.'
        Write-Host 'To revoke them, reinstall Spotifast, open Settings, and use Sign out.'
    } else {
        Write-Host ''
        Write-Host 'Settings and local state were kept in:'
        Write-Host "  $appData"
        Write-Host "  $localData"
        Write-Host 'Run with -Uninstall -Purge to remove those too.'
    }

    Write-Info 'Spotifast was uninstalled.'
}

function Assert-Windows {
    if ($env:OS -ne 'Windows_NT') {
        Fail 'This installer is for Windows. On Linux or macOS, run install.sh instead.'
    }
    if (-not $env:LOCALAPPDATA -or -not $env:APPDATA) {
        Fail 'LOCALAPPDATA or APPDATA is not set.'
    }
    if (-not [Environment]::Is64BitOperatingSystem) {
        Fail 'Spotifast requires a 64-bit version of Windows.'
    }

    $osVersion = [Environment]::OSVersion.Version
    if ($osVersion.Major -lt 10) {
        if ($Force) {
            Write-Warn "Windows $osVersion is old; continuing because -Force was given."
        } else {
            Fail 'Spotifast requires Windows 10 or newer. Use -Force to try anyway.'
        }
    }

    $architecture = $env:PROCESSOR_ARCHITECTURE
    if ($env:PROCESSOR_ARCHITEW6432) {
        $architecture = $env:PROCESSOR_ARCHITEW6432
    }
    switch ($architecture) {
        'AMD64' { $script:AssetArch = 'x86_64' }
        'ARM64' { $script:AssetArch = 'aarch64' }
        default { Fail "Unsupported CPU architecture: $architecture. Spotifast provides x64 and ARM64 Windows builds." }
    }
}

if ($Help) {
    Show-Usage
    exit 0
}

if (-not $Update -and -not $Check -and -not $Uninstall -and $MyInvocation.MyCommand.Name -eq 'spotifast-update.ps1') {
    $Update = $true
}

if ($Purge -and -not $Uninstall) {
    Fail '-Purge can only be used together with -Uninstall.'
}

try {
    Assert-Windows
    if ($Version) {
        $Version = Normalize-Version $Version
    }

    if ($Uninstall) {
        Uninstall-Spotifast
        exit 0
    }

    if ($Update -or $Check) {
        Update-Spotifast
        exit 0
    }

    $target = if ($Version) { $Version } else { Get-LatestVersion }
    Install-Spotifast -TargetVersion $target
} catch {
    Write-Err $_.Exception.Message
    exit 1
}
