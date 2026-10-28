#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Intune Remediations - REMEDIATION script for Microsoft .NET 8.0 runtimes.
.DESCRIPTION
  Runs when Detect-DotNet8.ps1 exits 1.

  1. Reads the latest 8.0 runtime patch, with installer URLs and SHA-512
     hashes, from Microsoft's .NET release metadata.
  2. Finds the .NET 8.0 installer bundles registered in Add/Remove Programs
     (.NET Runtime, Windows Desktop Runtime, ASP.NET Core Runtime, Hosting
     Bundle) and, for each type and architecture that is out of date,
     downloads the latest installer, checks its hash and Microsoft signature,
     and installs it. Only installed types are updated; nothing new is added.
  3. Uninstalls any older 8.0 bundles of the same type and architecture that
     are still registered. Apps that target 8.0 roll forward to the newest
     installed 8.0 patch automatically.
  4. Reports any old 8.0 runtime folders that are still present. These belong
     to something this script does not manage (an SDK, Visual Studio, or an
     app's own installer).

  Running apps keep working: each patch installs side by side, and files in use
  are removed at the next reboot.

  Full log: C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\Remediate-DotNet8.log
  Installer logs: Remediate-DotNet8-*.log in the same folder.

  Exit 0 = success. Exit 1 = failure (reported in Intune).

  Intune settings: Run as logged-on credentials = No (SYSTEM),
                   Run script in 64-bit PowerShell = Yes.
#>

$Channel = '8.0'

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # makes web requests much faster on PS 5.1

[Net.ServicePointManager]::SecurityProtocol =
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$logDir = "$env:ProgramData\Microsoft\IntuneManagementExtension\Logs"
if (-not (Test-Path $logDir)) { $logDir = $env:TEMP }
Start-Transcript -Path (Join-Path $logDir 'Remediate-DotNet8.log') -Append -Force | Out-Null

# Installer bundles as they appear in Add/Remove Programs, and the release
# metadata section and file name that updates each one.
$ch = [regex]::Escape($Channel)
$BundleTypes = @(
    @{ Type = 'Runtime'; Section = 'runtime';            File = 'dotnet-runtime-win-{arch}.exe'
       Pattern = "^Microsoft \.NET Runtime - (?<v>$ch\.\d+) \((?<arch>x64|x86|arm64)\)$" }
    @{ Type = 'Desktop'; Section = 'windowsdesktop';     File = 'windowsdesktop-runtime-win-{arch}.exe'
       Pattern = "^Microsoft Windows Desktop Runtime - (?<v>$ch\.\d+) \((?<arch>x64|x86|arm64)\)$" }
    @{ Type = 'AspNet';  Section = 'aspnetcore-runtime'; File = 'aspnetcore-runtime-win-{arch}.exe'
       Pattern = "^Microsoft ASP\.NET Core (?<v>$ch\.\d+) - Shared Framework \((?<arch>x64|x86|arm64)\)$" }
    # The Hosting Bundle covers x64 and x86 in one installer
    @{ Type = 'Hosting'; Section = 'aspnetcore-runtime'; File = 'dotnet-hosting-win.exe'
       Pattern = "^Microsoft (\.NET|\.NET Core|ASP\.NET Core) (?<v>$ch\.\d+) - Windows Server Hosting$" }
)

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

function Get-DotNetBundles {
    # Bundles have a BundleCachePath; the MSIs inside them are hidden
    # SystemComponent entries with the same names, and are skipped.
    $keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    $entries = Get-ItemProperty $keys -ErrorAction SilentlyContinue |
        Where-Object { $_.BundleCachePath -and $_.QuietUninstallString }

    foreach ($e in $entries) {
        foreach ($t in $BundleTypes) {
            if ($e.DisplayName -match $t.Pattern) {
                [pscustomobject]@{
                    Type           = $t.Type
                    Arch           = if ($Matches.arch) { $Matches.arch } else { 'x64+x86' }
                    Version        = [version]$Matches.v
                    Name           = $e.DisplayName
                    QuietUninstall = $e.QuietUninstallString
                    Definition     = $t
                }
                break
            }
        }
    }
}

function Install-DotNetBundle($file, $label) {
    $path = Join-Path $env:TEMP (Split-Path $file.url -Leaf)
    $log  = Join-Path $logDir ('Remediate-DotNet8-{0}.log' -f [IO.Path]::GetFileNameWithoutExtension($path))

    Write-Output "[$label] Downloading $($file.url) ..."
    Invoke-WebRequest -Uri $file.url -OutFile $path -UseBasicParsing

    try {
        $hash = (Get-FileHash $path -Algorithm SHA512).Hash
        if ($hash -ne $file.hash) {
            throw "SHA-512 mismatch for $(Split-Path $path -Leaf)."
        }
        $sig = Get-AuthenticodeSignature $path
        if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
            throw "Signature check failed (Status: $($sig.Status), Signer: $($sig.SignerCertificate.Subject))."
        }
        Write-Output "[$label] Hash and signature OK: Microsoft Corporation"

        Write-Output "[$label] Installing (log: $log) ..."
        $proc = Start-Process $path -Wait -PassThru -ArgumentList "/install /quiet /norestart /log `"$log`""
    } finally {
        Remove-Item $path -Force -ErrorAction SilentlyContinue
    }

    if ($proc.ExitCode -notin 0, 1641, 3010) {
        throw "[$label] Installer failed with exit code $($proc.ExitCode). See $log"
    }
    if ($proc.ExitCode -ne 0) { $script:rebootNeeded = $true }
    Write-Output "[$label] Installer exit code: $($proc.ExitCode)"
}

function Uninstall-DotNetBundle($bundle) {
    if ($bundle.QuietUninstall -notmatch '^"([^"]+)"\s*(.*)$') {
        Write-Output "WARNING: cannot parse uninstall command for $($bundle.Name): $($bundle.QuietUninstall)"
        return
    }
    $exe = $Matches[1]
    $arguments = "$($Matches[2]) /norestart"

    Write-Output "Removing old bundle: $($bundle.Name)"
    $proc = Start-Process $exe -Wait -PassThru -ArgumentList $arguments
    if ($proc.ExitCode -notin 0, 1605, 1641, 3010) {   # 1605 = already gone
        Write-Output "WARNING: uninstall of $($bundle.Name) returned exit code $($proc.ExitCode)."
    }
    if ($proc.ExitCode -in 1641, 3010) { $script:rebootNeeded = $true }
}

function Write-RuntimeInventory($label, $runtimes) {
    Write-Output "=== .NET $Channel runtimes $label ==="
    if (-not $runtimes) { Write-Output '  (none)'; return }
    $runtimes | Sort-Object Framework, Arch, Version | ForEach-Object {
        Write-Output ("  {0,-30} {1,-6} {2}" -f $_.Framework, $_.Arch, $_.Version)
    }
}

$rebootNeeded = $false
$exitCode     = 0
try {
    # --- Inventory and latest version --------------------------------------
    Write-RuntimeInventory 'BEFORE' @(Get-DotNetRuntimes)

    $meta    = Invoke-RestMethod -Uri "https://builds.dotnet.microsoft.com/dotnet/release-metadata/$Channel/releases.json" -UseBasicParsing -TimeoutSec 30
    $latest  = [version]$meta.'latest-runtime'
    $release = $meta.releases | Where-Object { $_.runtime.version -eq $meta.'latest-runtime' } | Select-Object -First 1
    if (-not $release) { throw "Release $latest not found in the .NET release metadata." }
    Write-Output "Latest .NET $Channel runtime: $latest (support phase: $($meta.'support-phase'), end of support: $($meta.'eol-date'))"

    # --- Install the latest patch for each bundle type that is out of date ---
    $bundles = @(Get-DotNetBundles)
    Write-Output "Installer bundles found: $($bundles.Count)"
    $bundles | ForEach-Object { Write-Output "  $($_.Name)" }

    foreach ($group in ($bundles | Group-Object Type, Arch)) {
        $first  = $group.Group[0]
        $label  = "$($first.Type) $($first.Arch)"
        $newest = $group.Group | Sort-Object Version -Descending | Select-Object -First 1

        if ($newest.Version -ge $latest) {
            Write-Output "[$label] Already has $($newest.Version)."
            continue
        }

        $fileName = $first.Definition.File -replace '\{arch\}', $first.Arch
        $file = $release.($first.Definition.Section).files | Where-Object name -eq $fileName | Select-Object -First 1
        if (-not $file) { throw "[$label] $fileName not found in the release metadata for $latest." }

        Install-DotNetBundle $file $label
    }

    # --- Remove older bundles that the new installers did not replace ---------
    $bundles = @(Get-DotNetBundles)
    foreach ($old in ($bundles | Where-Object { $_.Version -lt $latest })) {
        $replacement = $bundles | Where-Object {
            $_.Type -eq $old.Type -and $_.Arch -eq $old.Arch -and $_.Version -ge $latest
        }
        if ($replacement) {
            Uninstall-DotNetBundle $old
        } else {
            Write-Output "WARNING: $($old.Name) is out of date and no $latest bundle of the same type is installed. Left in place."
        }
    }

    # --- Result ------------------------------------------------------------
    $after = @(Get-DotNetRuntimes)
    Write-RuntimeInventory 'AFTER' $after

    $stale = @($after | Where-Object { $_.Version -lt $latest })
    if ($stale) {
        Write-Output 'WARNING: old .NET runtime folders remain. They are not owned by a .NET runtime installer'
        Write-Output '(likely an SDK, Visual Studio, or an application installer) and need to be updated there:'
        $stale | ForEach-Object { Write-Output "  $($_.Path)" }
        $summary = "Updated to $latest where possible. Remaining out-of-date runtime folders: $($stale.Count)."
    } else {
        $summary = "All .NET $Channel runtimes are at $latest."
    }
    if ($rebootNeeded) { $summary += ' A reboot is needed to finish removing files that were in use.' }

    Write-Output $summary
} catch {
    Write-Output "Remediation failed: $($_.Exception.Message)"
    $exitCode = 1
} finally {
    Stop-Transcript | Out-Null
}

exit $exitCode
