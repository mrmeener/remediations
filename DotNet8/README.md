# DotNet8

Keeps the Microsoft .NET 8.0 runtimes patched, and finds the apps that
depend on them.

> **.NET 8 reaches end of support on 10 November 2026.** After that date
> Microsoft releases no more patches, and vulnerability scanners flag every
> .NET 8 install. These scripts keep devices on the final 8.0 patch; the
> long-term fix is moving apps to .NET 10 (supported until November 2028).
> To target another version, change `$Channel` at the top of the detect and
> remediate scripts.

| Script | Purpose | Intune: run as logged-on user | 64-bit PowerShell |
|---|---|---|---|
| `Detect-DotNet8.ps1` | Checks every installed 8.0 runtime folder (.NET, Desktop, ASP.NET Core; x64, x86, arm64) against the latest 8.0 patch. | No (SYSTEM) | Yes |
| `Remediate-DotNet8.ps1` | Installs the latest patch for each out-of-date installer type, then removes older 8.0 installers. | No (SYSTEM) | Yes |
| `Find-DotNet8Dependents.ps1` | Lists apps that need .NET 8 and whether they break if it is removed. | No (SYSTEM) | Yes |

## Running from GitHub (one-liners)

Paste a whole line into PowerShell. Every one-liner does the same three things:

1. Downloads the script from this repo into your `%TEMP%` folder.
2. Runs it in Windows PowerShell 5.1, the same engine Intune uses. The
   execution policy is bypassed for that one run only.
3. Prints the exit code: `0` means compliant or succeeded, `1` means it needs
   fixing or failed.

Only the URL (`$u`) changes between them. **Admin** means open PowerShell
with *Run as administrator*.

### Check .NET 8 is fully patched (`Detect-DotNet8.ps1`)

Any user. Changes nothing.

```powershell
$u='https://raw.githubusercontent.com/mrmeener/remediations/main/DotNet8/Detect-DotNet8.ps1'; $f=Join-Path $env:TEMP (Split-Path $u -Leaf); iwr $u -OutFile $f -UseBasicParsing; powershell -NoProfile -ExecutionPolicy Bypass -File $f; "Exit: $LASTEXITCODE"
```

Example result: `Non-compliant: latest 8.0.33. Out of date: NETCore.App 8.0.32 (x64); WindowsDesktop.App 8.0.32 (x64).` and `Exit: 1`.

### Update .NET 8 to the latest patch (`Remediate-DotNet8.ps1`)

**Admin.** Does not close any apps. If the output ends with "A reboot is
needed", reboot to finish removing old files that were in use.

```powershell
$u='https://raw.githubusercontent.com/mrmeener/remediations/main/DotNet8/Remediate-DotNet8.ps1'; $f=Join-Path $env:TEMP (Split-Path $u -Leaf); iwr $u -OutFile $f -UseBasicParsing; powershell -NoProfile -ExecutionPolicy Bypass -File $f; "Exit: $LASTEXITCODE"
```

### Check, and update only if needed

**Admin.** Runs the update script only when the check exits `1`, the same
way Intune does.

```powershell
$b='https://raw.githubusercontent.com/mrmeener/remediations/main/DotNet8'; 'Detect-DotNet8.ps1','Remediate-DotNet8.ps1' | % { iwr "$b/$_" -OutFile "$env:TEMP\$_" -UseBasicParsing }; powershell -NoProfile -ExecutionPolicy Bypass -File "$env:TEMP\Detect-DotNet8.ps1"; if ($LASTEXITCODE -eq 1) { powershell -NoProfile -ExecutionPolicy Bypass -File "$env:TEMP\Remediate-DotNet8.ps1" }; "Exit: $LASTEXITCODE"
```

### List the apps that depend on .NET 8 (`Find-DotNet8Dependents.ps1`)

Any user. Changes nothing. Run it as **Admin** to include services and other
users' running apps. It takes around 15 seconds.

As a table on screen:

```powershell
$u='https://raw.githubusercontent.com/mrmeener/remediations/main/DotNet8/Find-DotNet8Dependents.ps1'; $f=Join-Path $env:TEMP (Split-Path $u -Leaf); iwr $u -OutFile $f -UseBasicParsing; powershell -NoProfile -ExecutionPolicy Bypass -Command "& '$f' | Format-Table Program, Kind, Impact, Running, Path -AutoSize | Out-String -Width 300"
```

Saved to a CSV file in your user folder, to open in Excel:

```powershell
$u='https://raw.githubusercontent.com/mrmeener/remediations/main/DotNet8/Find-DotNet8Dependents.ps1'; $f=Join-Path $env:TEMP (Split-Path $u -Leaf); iwr $u -OutFile $f -UseBasicParsing; powershell -NoProfile -ExecutionPolicy Bypass -Command "& '$f' | Export-Csv '$HOME\dotnet8-dependents.csv' -NoTypeInformation"; "Saved: $HOME\dotnet8-dependents.csv"
```

As one summary line, which is what Intune or an RMM tool records:

```powershell
$u='https://raw.githubusercontent.com/mrmeener/remediations/main/DotNet8/Find-DotNet8Dependents.ps1'; $f=Join-Path $env:TEMP (Split-Path $u -Leaf); iwr $u -OutFile $f -UseBasicParsing; powershell -NoProfile -ExecutionPolicy Bypass -File $f -Compact
```

Example result: `3 program(s) targeting .NET 8.0: Dell Display and Peripheral Manager [shared, running]; dotnet-core-uninstall [self-contained]; Windows Subsystem for Linux [self-contained]`

To search extra folders, such as apps installed on another drive, add `-Path`
inside the quotes of the table or CSV version:
`"& '$f' -Path 'D:\Apps','E:\Tools' | Format-Table ..."`

### From cmd, the Run box, or an RMM tool

These start with `powershell`, so they work outside PowerShell too. The
script's exit code is passed back as `%ERRORLEVEL%`.

```cmd
powershell -NoProfile -ExecutionPolicy Bypass -Command "$u='https://raw.githubusercontent.com/mrmeener/remediations/main/DotNet8/Detect-DotNet8.ps1'; $f=Join-Path $env:TEMP (Split-Path $u -Leaf); iwr $u -OutFile $f -UseBasicParsing; powershell -NoProfile -ExecutionPolicy Bypass -File $f; exit $LASTEXITCODE"
```

```cmd
powershell -NoProfile -ExecutionPolicy Bypass -Command "$u='https://raw.githubusercontent.com/mrmeener/remediations/main/DotNet8/Remediate-DotNet8.ps1'; $f=Join-Path $env:TEMP (Split-Path $u -Leaf); iwr $u -OutFile $f -UseBasicParsing; powershell -NoProfile -ExecutionPolicy Bypass -File $f; exit $LASTEXITCODE"
```

```cmd
powershell -NoProfile -ExecutionPolicy Bypass -Command "$u='https://raw.githubusercontent.com/mrmeener/remediations/main/DotNet8/Find-DotNet8Dependents.ps1'; $f=Join-Path $env:TEMP (Split-Path $u -Leaf); iwr $u -OutFile $f -UseBasicParsing; powershell -NoProfile -ExecutionPolicy Bypass -File $f -Compact"
```

**Pin a version for production:** replace `main` in the URL with a commit SHA,
e.g. `.../remediations/91fe122/DotNet8/...`. A later push to the repo then
cannot change what runs.

## How remediation works

1. Reads the latest 8.0 patch, with installer URLs and SHA-512 hashes, from
   Microsoft's release metadata.
2. For each .NET 8 installer in Add/Remove Programs that is out of date, it
   downloads the matching new installer and checks its hash and Microsoft
   signature, then installs it silently.
3. Removes older 8.0 installers of the same type. Apps built for 8.0 switch
   to the newest installed 8.0 patch automatically.
4. Lists any old runtime folders that remain. These belong to an SDK, Visual
   Studio or an app's own installer, and need updating there.

It only updates the installer types already on the device, and it does not
close any apps. Exit code 3010 means a reboot is needed to finish removing
files that were in use.

Microsoft Update also delivers .NET 8 patches. If your Intune update rings set
**Microsoft product updates** to **Allow**, most devices get them through
Windows Update. This remediation catches the devices that miss them and cleans
up leftover old versions.

## Finding what depends on .NET 8

```powershell
.\Find-DotNet8Dependents.ps1 | Format-Table -AutoSize
.\Find-DotNet8Dependents.ps1 | Export-Csv dotnet8.csv -NoTypeInformation
.\Find-DotNet8Dependents.ps1 -Path D:\Apps          # search extra folders
```

The script searches Program Files, ProgramData, `C:\inetpub` and user
profiles for `*.runtimeconfig.json`, and checks running processes for the
loaded .NET 8 runtime. It skips OneDrive folders and cloud-only files.
Run it elevated to include services.

| Kind | What end of support means |
|---|---|
| Framework-dependent | Uses the shared runtime. **Stops starting if .NET 8 is uninstalled**, unless the app is set to roll forward to a newer major version. |
| Self-contained | Ships its own copy of .NET 8 and is unaffected by removing the shared runtime. Only the vendor can update that copy. |

**Fleet-wide:** add the script as an Intune Remediation with a detection
script only. Intune cannot pass parameters, so change the `-Compact` default
to `$true` in the uploaded copy. Each device then reports one line, such as
`3 program(s) targeting .NET 8.0: Dell Display and Peripheral Manager [shared, running]; ...`,
in the **Pre-remediation detection output** column.

With Defender for Endpoint, this query lists programs that loaded .NET 8 in
the last 30 days:

```kql
DeviceImageLoadEvents
| where Timestamp > ago(30d)
| where FileName =~ "coreclr.dll" and FolderPath has @"\shared\Microsoft.NETCore.App\8.0."
| summarize Devices = dcount(DeviceId), LastSeen = max(Timestamp)
    by InitiatingProcessFileName, InitiatingProcessFolderPath, InitiatingProcessVersionInfoCompanyName
| order by Devices desc
```

## Logs

- `C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\Remediate-DotNet8.log`
- `C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\Remediate-DotNet8-*.log` (installer logs)
