<#
.SYNOPSIS
  Intune Remediations - REMEDIATION script for per-user Google Chrome copies.
.DESCRIPTION
  Runs when Detect-ChromePerUser.ps1 exits 1. Uninstalls the logged-on user's
  per-user Chrome with Chrome's own uninstaller, leaving the system-wide copy.

  Profile data (bookmarks, passwords, extensions) lives in
  %LOCALAPPDATA%\Google\Chrome\User Data. Per-user and system Chrome share that
  folder, and the uninstall runs without --delete-profile, so the system copy
  picks up the same profile.

  Log: %TEMP%\Remediate-ChromePerUser.log (the user's temp folder, because a
  standard user cannot write to the Intune logs folder).

  Exit 0 = removed, or nothing to do. Exit 1 = failure.

  Intune settings: Run as logged-on credentials = Yes,
                   Run script in 64-bit PowerShell = Yes.
#>

$ErrorActionPreference = 'Stop'

Start-Transcript -Path (Join-Path $env:TEMP 'Remediate-ChromePerUser.log') -Append -Force | Out-Null

$exitCode = 0
try {
    $systemExe = @(
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1

    $appDir  = Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application'
    $userExe = Join-Path $appDir 'chrome.exe'

    if (-not (Test-Path $userExe)) {
        Write-Output "No per-user Chrome for $env:USERNAME. Nothing to do."
    } elseif (-not $systemExe) {
        # Never remove the user's only Chrome
        Write-Output 'No system-wide Chrome installed. Leaving per-user Chrome in place.'
    } else {
        $userVersion = (Get-Item $userExe).VersionInfo.ProductVersion
        Write-Output "Per-user Chrome $userVersion found at $appDir"

        # Chrome's uninstaller lives in <version>\Installer\setup.exe; use the newest
        $setup = Get-ChildItem $appDir -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -as [version] } |
            Sort-Object { [version]$_.Name } -Descending |
            ForEach-Object { Join-Path $_.FullName 'Installer\setup.exe' } |
            Where-Object { Test-Path $_ } |
            Select-Object -First 1
        if (-not $setup) { throw "setup.exe not found under $appDir\<version>\Installer." }

        # Close only this user's per-user Chrome. A system Chrome window is left alone.
        # --force-uninstall does not check for running Chrome, so this must happen first.
        $procs = Get-Process chrome -ErrorAction SilentlyContinue |
            Where-Object { $_.Path -and $_.Path -like "$appDir\*" }
        if ($procs) {
            Write-Output "Closing $(@($procs).Count) per-user Chrome process(es)..."
            $procs | Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 3
        }

        Write-Output "Running $setup --uninstall --force-uninstall"
        $proc = Start-Process $setup -ArgumentList '--uninstall --force-uninstall' -Wait -PassThru
        # 19 = UNINSTALL_SUCCESSFUL in Chrome's installer, so a non-zero code is normal here.
        Write-Output "setup.exe exit code: $($proc.ExitCode)"

        # Trust the result on disk rather than the exit code
        Start-Sleep -Seconds 2
        if (Test-Path $userExe) {
            throw "Per-user Chrome is still present after uninstall (setup.exe exit code $($proc.ExitCode))."
        }
        Write-Output "Removed per-user Chrome $userVersion for $env:USERNAME. Profile data kept for system Chrome."
    }
} catch {
    Write-Output "Remediation failed: $($_.Exception.Message)"
    $exitCode = 1
} finally {
    Stop-Transcript | Out-Null
}

exit $exitCode
