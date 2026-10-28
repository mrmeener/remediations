<#
.SYNOPSIS
  Intune Remediations - DETECTION script for Google Chrome.
.DESCRIPTION
  Compares the system-wide Chrome install against the current Windows x64
  stable version from Google's version history API.

  Exit 0 = compliant, or not applicable (no system-wide Chrome, or the API
           could not be reached).
  Exit 1 = out of date, or an update is staged but waiting for a Chrome
           restart. Intune then runs Remediate-Chrome.ps1.

  Per-user Chrome copies are reported in the output, but they do not cause
  a non-compliant result because the system MSI cannot update them.

  Intune settings: Run as logged-on credentials = No (SYSTEM),
                   Run script in 64-bit PowerShell = Yes.
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

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
        # those would leave every device non-compliant until the rollout finishes.
        $full = @($resp.releases | Where-Object { $_.fraction -ge 1 })
        if (-not $full) { $full = @($resp.releases) }
        $full | ForEach-Object { [version]$_.version } |
            Sort-Object -Descending | Select-Object -First 1
    } catch {
        $null
    }
}

try {
    $installs = @(Get-ChromeInstalls)
    $system   = $installs | Where-Object Scope -eq 'System' | Select-Object -First 1
    $perUser  = @($installs | Where-Object Scope -eq 'Per-user')

    if (-not $system) {
        Write-Output "Not applicable: no system-wide Chrome. Per-user copies: $($perUser.Count)."
        exit 0
    }

    $latest = Get-LatestStableVersion
    if (-not $latest) {
        Write-Output "Unknown: could not reach Google's version API. System Chrome $($system.Version)."
        exit 0
    }

    $installed = [version]$system.Version

    $note = ''
    $stale = @($perUser | Where-Object { [version]$_.Version -lt $latest })
    if ($stale) { $note = " Out-of-date per-user copies: $($stale.Count)." }

    if ($installed -ge $latest) {
        Write-Output "Compliant: system Chrome $installed (latest $latest).$note"
        exit 0
    }

    if ($system.StagedVersion -and [version]$system.StagedVersion -ge $latest) {
        Write-Output "Non-compliant: Chrome $installed is running; $($system.StagedVersion) is staged and needs a Chrome restart.$note"
        exit 1
    }

    Write-Output "Non-compliant: system Chrome $installed, latest $latest.$note"
    exit 1
} catch {
    Write-Output "Detection error: $($_.Exception.Message)"
    exit 1
}
