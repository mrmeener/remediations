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
