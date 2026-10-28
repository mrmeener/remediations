<#
.SYNOPSIS
  Finds applications on this device that depend on the .NET 8.0 runtime.
.DESCRIPTION
  .NET apps record the runtime they need in <app>.runtimeconfig.json next to
  the app. This script searches for those files and reports every app that
  targets the chosen .NET version:

    Framework-dependent  Uses the shared runtime in Program Files\dotnet.
                         Stops starting if that runtime is removed, unless
                         it is configured to roll forward to a newer major
                         version (rollForward = Major or LatestMajor).
    Self-contained       Ships its own copy of the runtime. Removing the
                         shared runtime does not affect it, but its bundled
                         runtime gets no more fixes; only the vendor can
                         update it.

  It also checks running processes for a loaded .NET runtime of that version,
  which catches apps in folders the search does not cover. Run elevated to
  see services and other users' processes.

  Searched: Program Files, Program Files (x86), ProgramData, C:\inetpub and
  every user profile. OneDrive folders and cloud-only files are skipped so
  nothing is downloaded. Add other locations with -Path.
.PARAMETER Channel
  .NET version to look for. Default 8.0.
.PARAMETER Path
  Extra folders to search, e.g. D:\Apps.
.PARAMETER Compact
  Write one summary line and exit 0. Use this to run the script as an Intune
  Remediations detection script (with no remediation script) and read the
  results from the "Pre-remediation detection output" column.
.EXAMPLE
  .\Find-DotNet8Dependents.ps1 | Format-Table -AutoSize
.EXAMPLE
  .\Find-DotNet8Dependents.ps1 | Export-Csv dotnet8-dependents.csv -NoTypeInformation
#>
param(
    [string]$Channel = '8.0',
    [string[]]$Path,
    [switch]$Compact
)

$ErrorActionPreference = 'Stop'

$dotnetRoots = "$env:ProgramFiles\dotnet", "${env:ProgramFiles(x86)}\dotnet"
$skipDirs    = 'node_modules', '.git', '$Recycle.Bin'
# Offline, RecallOnOpen, RecallOnDataAccess: cloud-only files that would be downloaded if read
$cloudAttrs  = 0x1000 -bor 0x40000 -bor 0x400000

function Find-RuntimeConfigs([string]$root) {
    if (-not (Test-Path $root)) { return }
    $stack = New-Object 'System.Collections.Generic.Stack[System.IO.DirectoryInfo]'
    $stack.Push([IO.DirectoryInfo]$root)

    while ($stack.Count) {
        $dir = $stack.Pop()
        try {
            foreach ($f in $dir.EnumerateFiles('*.runtimeconfig.json')) {
                if ([int]$f.Attributes -band $cloudAttrs) { continue }
                if ($f.Name -like '*.runtimeconfig.json') { $f }
            }
            foreach ($d in $dir.EnumerateDirectories()) {
                # Reparse points: junctions such as "Application Data" loop back on themselves
                if ([int]$d.Attributes -band ([int][IO.FileAttributes]::ReparsePoint -bor $cloudAttrs)) { continue }
                if ($d.Name -in $skipDirs -or $d.Name -like 'OneDrive*') { continue }
                if ($d.FullName -in $dotnetRoots) { continue }   # the .NET install itself
                $stack.Push($d)
            }
        } catch {
            # Access denied or the folder vanished; skip it
        }
    }
}

function Get-InstalledPrograms {
    $keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'Registry::HKEY_USERS\*\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
    Get-ItemProperty $keys -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -and $_.InstallLocation } |
        ForEach-Object {
            [pscustomobject]@{
                Name     = $_.DisplayName
                Location = $_.InstallLocation.Trim('"').TrimEnd('\') + '\'
            }
        } |
        Where-Object { $_.Location.Length -gt 4 }   # ignore entries pointing at a drive root
}

$runtimePattern = "*\shared\Microsoft.NETCore.App\$Channel.*\coreclr.dll"
$rollForwardEnv = [Environment]::GetEnvironmentVariable('DOTNET_ROLL_FORWARD', 'Machine')

# --- Search for runtimeconfig.json files ---------------------------------------
$roots = @(
    $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData,
    "$env:SystemDrive\inetpub", "$env:SystemDrive\Users"
) + $Path | Where-Object { $_ } | Select-Object -Unique

$programs  = @(Get-InstalledPrograms)
$processes = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)

$results = foreach ($root in $roots) {
    foreach ($file in (Find-RuntimeConfigs $root)) {
        try {
            $opts = (Get-Content $file.FullName -Raw | ConvertFrom-Json).runtimeOptions
        } catch {
            continue
        }
        if (-not $opts) { continue }

        $kind       = 'Framework-dependent'
        $frameworks = @(@($opts.framework) + @($opts.frameworks) | Where-Object { $_ })
        if (-not $frameworks -and $opts.includedFrameworks) {
            $kind       = 'Self-contained'
            $frameworks = @($opts.includedFrameworks)
        }
        if (-not ($frameworks | Where-Object { "$($_.version)" -like "$Channel.*" })) { continue }

        $base    = $file.FullName -replace '\.runtimeconfig\.json$', ''
        $appFile = @("$base.exe", "$base.dll") | Where-Object { Test-Path $_ } | Select-Object -First 1
        if (-not $appFile) { $appFile = "$base.dll" }
        $info    = if (Test-Path $appFile) { (Get-Item $appFile).VersionInfo }

        $program = $programs | Where-Object { $appFile.StartsWith($_.Location, [StringComparison]::OrdinalIgnoreCase) } |
            Sort-Object { $_.Location.Length } -Descending | Select-Object -First 1

        $rollForward = if ($kind -eq 'Self-contained') { 'n/a' } elseif ($opts.rollForward) { $opts.rollForward } elseif ($rollForwardEnv) { "$rollForwardEnv (machine env)" } else { 'default (Minor)' }
        $impact = if ($kind -eq 'Self-contained') {
            'Not affected by removal; vendor must update its bundled runtime'
        } elseif ($rollForward -match '^(Major|LatestMajor)') {
            'Runs on a newer major .NET if one is installed'
        } else {
            "Stops working if .NET $Channel is removed"
        }

        $running = [bool]($processes | Where-Object {
            $_.ExecutablePath -eq $appFile -or ($_.CommandLine -and $_.CommandLine -like "*$appFile*")
        })

        [pscustomobject]@{
            Program     = if ($program) { $program.Name } elseif ($info.ProductName) { $info.ProductName } else { Split-Path $appFile -Leaf }
            Kind        = $kind
            Targets     = ($frameworks | ForEach-Object { "$($_.name) $($_.version)" }) -join ', '
            RollForward = $rollForward
            Impact      = $impact
            Running     = $running
            Company     = $info.CompanyName
            AppVersion  = $info.ProductVersion
            Path        = $appFile
        }
    }
}
$results = @($results)

# --- Running processes using the runtime from somewhere the search missed ------
$known = $results.Path
foreach ($p in (Get-Process -ErrorAction SilentlyContinue)) {
    try {
        $clr = $p.Modules | Where-Object { $_.FileName -like $runtimePattern } | Select-Object -First 1
    } catch {
        continue   # no access to this process
    }
    if (-not $clr -or $p.Path -in $known) { continue }
    $known += $p.Path

    $results += [pscustomobject]@{
        Program     = if ($p.Product) { $p.Product } else { $p.ProcessName }
        Kind        = 'Framework-dependent (found running)'
        Targets     = "Microsoft.NETCore.App $(Split-Path (Split-Path $clr.FileName) -Leaf)"
        RollForward = 'unknown'
        Impact      = "Loaded .NET $Channel from the shared runtime"
        Running     = $true
        Company     = $p.Company
        AppVersion  = $p.ProductVersion
        Path        = $p.Path
    }
}

$results = $results | Sort-Object Program, Path

if ($Compact) {
    if (-not $results) {
        Write-Output "No apps targeting .NET $Channel found."
    } else {
        # One entry per program; a program can have several .NET executables
        $groups = @($results | Group-Object Program)
        $items = $groups | ForEach-Object {
            $g = $_.Group
            $flags = @()
            if ($g | Where-Object Kind -notlike 'Self*') { $flags += 'shared' }
            if ($g | Where-Object Kind -like 'Self*') { $flags += 'self-contained' }
            if ($g | Where-Object RollForward -match '^(Major|LatestMajor)') { $flags += 'rolls forward' }
            if ($g | Where-Object Running) { $flags += 'running' }
            "$($_.Name) [$($flags -join ', ')]"
        }
        $line = "$($groups.Count) program(s) targeting .NET ${Channel}: $($items -join '; ')"
        if ($line.Length -gt 2000) { $line = $line.Substring(0, 1997) + '...' }
        Write-Output $line
    }
    exit 0
}

$results
