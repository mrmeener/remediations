<#
.SYNOPSIS
  Intune Remediations - DETECTION script for per-user Google Chrome copies.
.DESCRIPTION
  Runs as the logged-on user and looks for a per-user Chrome install in
  %LOCALAPPDATA%\Google\Chrome\Application. The system MSI never updates
  these copies, so they drift out of date.

  Exit 0 = no per-user copy, or no system-wide Chrome. The second case keeps
           the per-user copy so the user is not left without a browser.
  Exit 1 = per-user copy found alongside system Chrome. Intune then runs
           Remediate-ChromePerUser.ps1 to remove it.

  Intune settings: Run as logged-on credentials = Yes,
                   Run script in 64-bit PowerShell = Yes.
#>

$ErrorActionPreference = 'Stop'

try {
    $systemExe = @(
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1

    $userExe = Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe'

    if (-not (Test-Path $userExe)) {
        Write-Output "Compliant: no per-user Chrome for $env:USERNAME."
        exit 0
    }

    $userVersion = (Get-Item $userExe).VersionInfo.ProductVersion

    if (-not $systemExe) {
        Write-Output "Not applicable: per-user Chrome $userVersion found, but no system-wide Chrome to replace it."
        exit 0
    }

    $systemVersion = (Get-Item $systemExe).VersionInfo.ProductVersion
    Write-Output "Non-compliant: per-user Chrome $userVersion for $env:USERNAME (system Chrome $systemVersion)."
    exit 1
} catch {
    Write-Output "Detection error: $($_.Exception.Message)"
    exit 1
}
