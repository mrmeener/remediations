#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Force-updates Google Chrome on this workstation without uninstalling it.
.DESCRIPTION
  1. Inventories every Chrome copy: system-wide and per-user (all profiles).
  2. Asks Google's version history API for the current Windows stable version.
     If the system install is already current, it stops there: no download,
     and Chrome is left alone.
  3. Otherwise downloads Google's enterprise MSI, verifies its signature,
     closes Chrome (unless -LeaveChromeOpen) and upgrades in place.
.PARAMETER LeaveChromeOpen
  By default, all Chrome processes are force-closed before installing so the
  update takes effect immediately (users lose unsaved form data; tabs are
  normally restored on next launch). Use this switch to leave Chrome running;
  the update is then staged and applies on the next restart.
.PARAMETER Force
  Skip the up-to-date check and always run the MSI.
.EXAMPLE
  .\Update-Chrome.ps1
.EXAMPLE
  .\Update-Chrome.ps1 -LeaveChromeOpen
#>
param(
    [switch]$LeaveChromeOpen,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # makes web requests much faster on PS 5.1

[Net.ServicePointManager]::SecurityProtocol =
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

function Get-ChromeInstalls {
    $paths = @(
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe"
    )
    $paths += Get-ChildItem "$env:SystemDrive\Users" -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName 'AppData\Local\Google\Chrome\Application\chrome.exe' }

    foreach ($p in ($paths | Select-Object -Unique)) {
        if (Test-Path $p) {
            # new_chrome.exe = an update downloaded but waiting for Chrome to restart
            $staged = Join-Path (Split-Path $p) 'new_chrome.exe'
            [pscustomobject]@{
                Scope          = if ($p -like "$env:SystemDrive\Users\*") { 'Per-user' } else { 'System' }
                Version        = (Get-Item $p).VersionInfo.ProductVersion
                PendingRestart = Test-Path $staged
                StagedVersion  = if (Test-Path $staged) { (Get-Item $staged).VersionInfo.ProductVersion } else { $null }
                Path           = $p
            }
        }
    }
}

function Get-LatestStableVersion {
    # Releases currently being served on the Windows x64 stable channel
    $uri = 'https://versionhistory.googleapis.com/v1/chrome/platforms/win64/channels/stable/versions/all/releases?filter=endtime=none'
    try {
        $resp = Invoke-RestMethod -Uri $uri -UseBasicParsing -TimeoutSec 30
        # Ignore partial rollouts (fraction < 1), e.g. a new major at 1%. The
        # enterprise MSI ships the newest fully rolled-out version, so counting
        # those would leave this check failing until the rollout finishes.
        $full = @($resp.releases | Where-Object { $_.fraction -ge 1 })
        if (-not $full) { $full = @($resp.releases) }
        $full | ForEach-Object { [version]$_.version } |
            Sort-Object -Descending | Select-Object -First 1
    } catch {
        Write-Warning "Could not query Google's version API ($($_.Exception.Message)). Will install anyway."
        $null
    }
}

function Get-MsiChromeVersion($msiPath) {
    # Google puts the Chrome version at the start of the MSI's Comments
    # summary property ("156.0.8078.74 Copyright ..."). PID 6 = Comments.
    try {
        $wi = New-Object -ComObject WindowsInstaller.Installer
        $comments = $wi.SummaryInformation($msiPath, 0).Property(6)
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($wi)
        if ($comments -match '^(\d+\.\d+\.\d+\.\d+)') { [version]$Matches[1] }
    } catch {
        $null
    }
}

function Stop-Chrome {
    $procs = Get-Process chrome -ErrorAction SilentlyContinue
    if ($procs) {
        Write-Host "Closing $($procs.Count) Chrome process(es)..."
        $procs | Stop-Process -Force
        Start-Sleep -Seconds 3
    }
}

# --- Inventory and up-to-date check ------------------------------------------
Write-Host "`n=== Chrome installs BEFORE ===" -ForegroundColor Cyan
$before = @(Get-ChromeInstalls)
$before | Format-Table -AutoSize

$latest = Get-LatestStableVersion
if ($latest) { Write-Host "Latest stable for Windows x64: $latest" }

$system      = $before | Where-Object Scope -eq 'System' | Select-Object -First 1
$needInstall = $true

if (-not $Force -and $latest -and $system) {
    $effective = if ($system.StagedVersion) { [version]$system.StagedVersion } else { [version]$system.Version }

    if ($effective -ge $latest) {
        $needInstall = $false
        if ($system.PendingRestart) {
            Write-Host "Version $effective is already downloaded and only needs Chrome to restart." -ForegroundColor Yellow
            if (-not $LeaveChromeOpen) {
                Stop-Chrome
                Write-Host "Chrome closed. $effective takes effect the next time Chrome starts." -ForegroundColor Green
            } else {
                Write-Warning "Chrome left open. The fix is NOT active until Chrome is fully restarted."
            }
        } else {
            Write-Host "System Chrome $($system.Version) is already the latest stable. Nothing to install." -ForegroundColor Green
        }
    }
}

# --- Download, verify, install -------------------------------------------------
if ($needInstall) {
    $msiUrl  = 'https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi'
    $msiPath = Join-Path $env:TEMP 'googlechromestandaloneenterprise64.msi'
    $logPath = Join-Path $env:TEMP 'chrome_msi_install.log'

    Write-Host "Downloading $msiUrl ..."
    Invoke-WebRequest -Uri $msiUrl -OutFile $msiPath -UseBasicParsing

    $sig = Get-AuthenticodeSignature $msiPath
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O=Google LLC') {
        Remove-Item $msiPath -Force -ErrorAction SilentlyContinue
        throw "MSI signature check failed (Status: $($sig.Status), Signer: $($sig.SignerCertificate.Subject))."
    }
    Write-Host "Signature OK: Google LLC"

    # Do not reinstall if the MSI is no newer than what is already installed or staged
    $msiVersion = Get-MsiChromeVersion $msiPath
    $sysCurrent = if ($system.StagedVersion) { [version]$system.StagedVersion } elseif ($system) { [version]$system.Version }
    if ($msiVersion) { Write-Host "MSI contains Chrome $msiVersion" }

    if (-not $Force -and $msiVersion -and $sysCurrent -and $sysCurrent -ge $msiVersion) {
        Remove-Item $msiPath -Force -ErrorAction SilentlyContinue
        Write-Host "System Chrome $sysCurrent is already at or above the MSI version $msiVersion. Nothing to install." -ForegroundColor Green
        $needInstall = $false
    }
}

if ($needInstall) {
    if (-not $LeaveChromeOpen) { Stop-Chrome }

    Write-Host "Installing (log: $logPath) ..."
    $proc = Start-Process msiexec.exe -Wait -PassThru -ArgumentList `
        "/i `"$msiPath`" /qn /norestart /l*v `"$logPath`""
    Remove-Item $msiPath -Force -ErrorAction SilentlyContinue

    if ($proc.ExitCode -notin 0, 1641, 3010) {
        throw "msiexec failed with exit code $($proc.ExitCode). See $logPath and $env:SystemRoot\Temp\chrome_installer.log"
    }
    Write-Host "msiexec exit code: $($proc.ExitCode)"

    Write-Host "`n=== Chrome installs AFTER ===" -ForegroundColor Cyan
    $after = @(Get-ChromeInstalls)
    $after | Format-Table -AutoSize
} else {
    $after = $before
}

# --- Warnings -------------------------------------------------------------------
if ($needInstall -and ($after | Where-Object PendingRestart)) {
    Write-Warning "An update is staged but Chrome is still running. The fix is NOT active until Chrome is fully restarted."
}

$perUser = $after | Where-Object Scope -eq 'Per-user'
if ($perUser) {
    $stale = if ($latest) { $perUser | Where-Object { [version]$_.Version -lt $latest } } else { $perUser }
    if ($stale) {
        Write-Warning "Out-of-date per-user Chrome copies found (the system MSI does not update these):"
        $stale | ForEach-Object { Write-Warning "  $($_.Version)  $($_.Path)" }
    }
}