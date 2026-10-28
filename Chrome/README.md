# Chrome

Keeps Google Chrome up to date on every device.

| Script | Purpose | Intune: run as logged-on user | 64-bit PowerShell |
|---|---|---|---|
| `Detect-Chrome.ps1` | Checks the system-wide Chrome against the latest stable version. | No (SYSTEM) | Yes |
| `Remediate-Chrome.ps1` | Downloads Google's enterprise MSI, checks its signature and upgrades Chrome in place. | No (SYSTEM) | Yes |
| `Detect-ChromePerUser.ps1` | Finds a per-user Chrome in `%LOCALAPPDATA%` when a system-wide Chrome also exists. | **Yes** | Yes |
| `Remediate-ChromePerUser.ps1` | Uninstalls that per-user copy. Bookmarks, passwords and extensions are kept for the system copy. | **Yes** | Yes |
| `Update-Chrome.ps1` | Manual version of the system update, for an elevated prompt. `-LeaveChromeOpen` and `-Force` switches. | n/a | n/a |

Deploy the system pair and the per-user pair as two separate remediations.

## Behaviour to know about

- **Chrome is closed during the update.** `$CloseChrome = $true` at the top of
  `Remediate-Chrome.ps1` force-closes Chrome so the update takes effect
  straight away. Tabs are normally restored, but unsaved form data is lost.
  Set it to `$false` to leave Chrome running; the update then applies when
  the user next restarts Chrome.
- **"Latest" means the newest version Google is giving to 100% of users.**
  Google first releases new versions to a small percentage of users.
  The enterprise MSI only installs fully rolled-out versions, so detection
  ignores the partial ones.
- **No reinstall loop.** If the downloaded MSI is no newer than the installed
  Chrome, the install is skipped. Reinstalling the same version starts an MSI
  repair, which fails with error 1603.
- **Per-user copies are never updated by the system MSI.** That is why the
  per-user pair removes them. It does nothing when the device has no
  system-wide Chrome, so users are never left without a browser.

## Logs

- `C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\Remediate-Chrome.log`
- `C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\Remediate-Chrome-msi.log`
- `C:\Windows\Temp\chrome_installer.log` (Google's installer)
- `%TEMP%\Remediate-ChromePerUser.log` (per-user script, in the user's temp folder)

## Troubleshooting

| msiexec exit code | Meaning |
|---|---|
| 1603 | Install failed. Check the MSI log for `Return value 3`. |
| 1622 | Could not write the MSI log. The script was run without admin rights. |
| 3010 / 1641 | Success; a reboot is needed or was started. |
