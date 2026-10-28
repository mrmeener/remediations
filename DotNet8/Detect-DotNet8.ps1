<#
.SYNOPSIS
  Intune Remediations - DETECTION script for Microsoft .NET 8.0 runtimes.
.DESCRIPTION
  Compares every installed .NET 8.0 shared runtime (.NET Runtime, Windows
  Desktop Runtime and ASP.NET Core Runtime; x64, x86 and arm64) against the
  latest 8.0 patch in Microsoft's .NET release metadata.

  Each patch is a separate folder (dotnet\shared\<framework>\8.0.x), and
  vulnerability scanners flag any old folder left behind, so every folder is
  checked, not only the newest.

  Exit 0 = compliant, or not applicable (no .NET 8.0 runtime, or the release
           metadata could not be reached).
  Exit 1 = at least one 8.0 runtime is older than the latest patch. Intune
           then runs Remediate-DotNet8.ps1.

  Intune settings: Run as logged-on credentials = No (SYSTEM),
                   Run script in 64-bit PowerShell = Yes.
#>

$Channel = '8.0'

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

[Net.ServicePointManager]::SecurityProtocol =
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

function Get-DotNetRuntimes {
    $nativeArch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
    $roots = @(
        @{ Path = "$env:ProgramFiles\dotnet";        Arch = $nativeArch }
        @{ Path = "$env:ProgramFiles\dotnet\x64";    Arch = 'x64' }    # x64 runtimes on ARM64 devices
        @{ Path = "${env:ProgramFiles(x86)}\dotnet"; Arch = 'x86' }
    )
    foreach ($root in $roots) {
        foreach ($fw in 'Microsoft.NETCore.App', 'Microsoft.WindowsDesktop.App', 'Microsoft.AspNetCore.App') {
            Get-ChildItem (Join-Path $root.Path "shared\$fw") -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like "$Channel.*" -and ($_.Name -as [version]) } |
                ForEach-Object {
                    [pscustomobject]@{
                        Framework = $fw
                        Arch      = $root.Arch
                        Version   = [version]$_.Name
                        Path      = $_.FullName
                    }
                }
        }
    }
}

function Get-LatestRuntimeVersion {
    $uri = "https://builds.dotnet.microsoft.com/dotnet/release-metadata/$Channel/releases.json"
    try {
        [version](Invoke-RestMethod -Uri $uri -UseBasicParsing -TimeoutSec 30).'latest-runtime'
    } catch {
        $null
    }
}

try {
    $installed = @(Get-DotNetRuntimes)
    if (-not $installed) {
        Write-Output "Not applicable: no .NET $Channel runtime installed."
        exit 0
    }

    $latest = Get-LatestRuntimeVersion
    if (-not $latest) {
        Write-Output "Unknown: could not reach the .NET release metadata. Installed: $(($installed.Version | Sort-Object -Unique) -join ', ')."
        exit 0
    }

    $stale = @($installed | Where-Object { $_.Version -lt $latest })
    if (-not $stale) {
        Write-Output "Compliant: all $($installed.Count) .NET $Channel runtime(s) are at $latest."
        exit 0
    }

    $list = ($stale | ForEach-Object { "$($_.Framework -replace '^Microsoft\.', '') $($_.Version) ($($_.Arch))" }) -join '; '
    Write-Output "Non-compliant: latest $latest. Out of date: $list."
    exit 1
} catch {
    Write-Output "Detection error: $($_.Exception.Message)"
    exit 1
}
