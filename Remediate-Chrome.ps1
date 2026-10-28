#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Intune Remediations - REMEDIATION script for Google Chrome.
.DESCRIPTION
  Runs when Detect-Chrome.ps1 exits 1.

  1. Checks the system-wide Chrome version again, because detection may have
     run some time ago. If an update is only staged, it closes Chrome so the
     staged version takes effect.
  2. Otherwise downloads Google's enterprise MSI, verifies its signature,
     closes Chrome (if $CloseChrome) and upgrades in place.

  Full log: C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\Remediate-Chrome.log
  (you can collect it with the Intune "Collect diagnostics" action).

  Exit 0 = success. Exit 1 = failure (reported in Intune).

  Intune settings: Run as logged-on credentials = No (SYSTEM),
                   Run script in 64-bit PowerShell = Yes.
#>

# $true  = force-close every Chrome process so the update takes effect now.
#          Users lose unsaved form data; tabs are normally restored on relaunch.
# $false = leave Chrome running; the update is staged and applies on the next
#          Chrome restart. Detection keeps reporting the device as non-compliant
#          until that happens.
$CloseChrome = $true

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # makes web requests much faster on PS 5.1

[Net.ServicePointManager]::SecurityProtocol =
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$logDir = "$env:ProgramData\Microsoft\IntuneManagementExtension\Logs"
if (-not (Test-Path $logDir)) { $logDir = $env:TEMP }
Start-Transcript -Path (Join-Path $logDir 'Remediate-Chrome.log') -Append -Force | Out-Null

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
        Write-Output "WARNING: could not query Google's version API ($($_.Exception.Message)). Will install anyway."
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
        Write-Output "Closing $($procs.Count) Chrome process(es)..."
        $procs | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
    }
}

function Write-Inventory($label, $installs) {
    Write-Output "=== Chrome installs $label ==="
    if (-not $installs) { Write-Output '  (none)'; return }
    $installs | ForEach-Object {
        Write-Output ("  {0,-8} {1,-16} staged={2,-16} {3}" -f $_.Scope, $_.Version, $_.StagedVersion, $_.Path)
    }
}

$exitCode = 0
try {
    # --- Inventory and up-to-date check --------------------------------------
    $before = @(Get-ChromeInstalls)
    Write-Inventory 'BEFORE' $before

    $latest = Get-LatestStableVersion
    if ($latest) { Write-Output "Latest stable for Windows x64: $latest" }

    $system      = $before | Where-Object Scope -eq 'System' | Select-Object -First 1
    $needInstall = $true
    $summary     = ''

    if ($latest -and $system) {
        $effective = if ($system.StagedVersion) { [version]$system.StagedVersion } else { [version]$system.Version }

        if ($effective -ge $latest) {
            $needInstall = $false
            if ($system.PendingRestart) {
                if ($CloseChrome) {
                    Stop-Chrome
                    $summary = "Chrome closed; staged $effective takes effect on next launch."
                } else {
                    $summary = "Chrome $effective is staged; waiting for the user to restart Chrome."
                }
            } else {
                $summary = "System Chrome $($system.Version) is already the latest stable. Nothing to do."
            }
        }
    }

    # --- Download, verify, install ---------------------------------------------
    if ($needInstall) {
        $msiUrl  = 'https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi'
        $msiPath = Join-Path $env:TEMP 'googlechromestandaloneenterprise64.msi'
        $logPath = Join-Path $logDir 'Remediate-Chrome-msi.log'

        Write-Output "Downloading $msiUrl ..."
        Invoke-WebRequest -Uri $msiUrl -OutFile $msiPath -UseBasicParsing

        $sig = Get-AuthenticodeSignature $msiPath
        if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O=Google LLC') {
            Remove-Item $msiPath -Force -ErrorAction SilentlyContinue
            throw "MSI signature check failed (Status: $($sig.Status), Signer: $($sig.SignerCertificate.Subject))."
        }
        Write-Output 'Signature OK: Google LLC'

        # Do not reinstall if the MSI is no newer than what is already installed or staged
        $msiVersion = Get-MsiChromeVersion $msiPath
        $sysCurrent = if ($system.StagedVersion) { [version]$system.StagedVersion } elseif ($system) { [version]$system.Version }
        if ($msiVersion) { Write-Output "MSI contains Chrome $msiVersion" }

        if ($msiVersion -and $sysCurrent -and $sysCurrent -ge $msiVersion) {
            Remove-Item $msiPath -Force -ErrorAction SilentlyContinue
            $summary = "System Chrome $sysCurrent is already at or above the MSI version $msiVersion. Nothing installed."
            $after   = $before
        } else {
            if ($CloseChrome) { Stop-Chrome }

            Write-Output "Installing (log: $logPath) ..."
            $proc = Start-Process msiexec.exe -Wait -PassThru -ArgumentList `
                "/i `"$msiPath`" /qn /norestart /l*v `"$logPath`""
            Remove-Item $msiPath -Force -ErrorAction SilentlyContinue

            if ($proc.ExitCode -notin 0, 1641, 3010) {
                throw "msiexec failed with exit code $($proc.ExitCode). See $logPath and $env:SystemRoot\Temp\chrome_installer.log"
            }
            Write-Output "msiexec exit code: $($proc.ExitCode)"

            $after = @(Get-ChromeInstalls)
            Write-Inventory 'AFTER' $after

            $sysAfter = $after | Where-Object Scope -eq 'System' | Select-Object -First 1
            if ($sysAfter.PendingRestart) {
                $summary = "Installed; Chrome $($sysAfter.StagedVersion) is staged and applies when Chrome restarts."
            } else {
                $summary = "Updated system Chrome to $($sysAfter.Version)."
            }
        }
    } else {
        $after = $before
    }

    # --- Per-user copies (not updated by the system MSI) ------------------------
    $perUser = @($after | Where-Object Scope -eq 'Per-user')
    if ($perUser) {
        $stale = if ($latest) { @($perUser | Where-Object { [version]$_.Version -lt $latest }) } else { $perUser }
        if ($stale) {
            Write-Output 'WARNING: out-of-date per-user Chrome copies found (the system MSI does not update these):'
            $stale | ForEach-Object { Write-Output "  $($_.Version)  $($_.Path)" }
            $summary += " Out-of-date per-user copies: $($stale.Count)."
        }
    }

    Write-Output $summary
} catch {
    Write-Output "Remediation failed: $($_.Exception.Message)"
    $exitCode = 1
} finally {
    Stop-Transcript | Out-Null
}

exit $exitCode
