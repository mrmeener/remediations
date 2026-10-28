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

## Running from GitHub (one-liners)

Paste a whole line into PowerShell. Every one-liner does the same three things:

1. Downloads the script from this repo into your `%TEMP%` folder.
2. Runs it in Windows PowerShell 5.1, the same engine Intune uses. The
   execution policy is bypassed for that one run only.
3. Prints the exit code: `0` means compliant or succeeded, `1` means it needs
   fixing or failed.

Only the URL (`$u`) changes between them. Options go after `-File $f`.

**Admin** means open PowerShell with *Run as administrator*. **User** means a
normal, non-elevated PowerShell window as the person who uses the device.

### Check system Chrome is up to date (`Detect-Chrome.ps1`)

Any user. Changes nothing.

```powershell
$u='https://raw.githubusercontent.com/mrmeener/remediations/main/Chrome/Detect-Chrome.ps1'; $f=Join-Path $env:TEMP (Split-Path $u -Leaf); iwr $u -OutFile $f -UseBasicParsing; powershell -NoProfile -ExecutionPolicy Bypass -File $f; "Exit: $LASTEXITCODE"
```

Example result: `Non-compliant: system Chrome 156.0.8078.48, latest 156.0.8078.74.` and `Exit: 1`.

### Update system Chrome (`Remediate-Chrome.ps1`)

**Admin.** Closes all Chrome windows, then installs the latest version.

```powershell
$u='https://raw.githubusercontent.com/mrmeener/remediations/main/Chrome/Remediate-Chrome.ps1'; $f=Join-Path $env:TEMP (Split-Path $u -Leaf); iwr $u -OutFile $f -UseBasicParsing; powershell -NoProfile -ExecutionPolicy Bypass -File $f; "Exit: $LASTEXITCODE"
```

### Check, and update only if needed

**Admin.** Runs the update script only when the check exits `1`, the same
way Intune does.

```powershell
$b='https://raw.githubusercontent.com/mrmeener/remediations/main/Chrome'; 'Detect-Chrome.ps1','Remediate-Chrome.ps1' | % { iwr "$b/$_" -OutFile "$env:TEMP\$_" -UseBasicParsing }; powershell -NoProfile -ExecutionPolicy Bypass -File "$env:TEMP\Detect-Chrome.ps1"; if ($LASTEXITCODE -eq 1) { powershell -NoProfile -ExecutionPolicy Bypass -File "$env:TEMP\Remediate-Chrome.ps1" }; "Exit: $LASTEXITCODE"
```

### Manual update with options (`Update-Chrome.ps1`)

**Admin.** Prints before/after tables and skips the install if Chrome is
already current.

```powershell
$u='https://raw.githubusercontent.com/mrmeener/remediations/main/Chrome/Update-Chrome.ps1'; $f=Join-Path $env:TEMP (Split-Path $u -Leaf); iwr $u -OutFile $f -UseBasicParsing; powershell -NoProfile -ExecutionPolicy Bypass -File $f; "Exit: $LASTEXITCODE"
```

Options: add them after `-File $f`.

| Option | Effect |
|---|---|
| `-LeaveChromeOpen` | Do not close Chrome. The update is staged and applies when the user next restarts Chrome. |
| `-Force` | Install even if Chrome is already current. |

For example: `... -File $f -LeaveChromeOpen; "Exit: $LASTEXITCODE"`

### Check for a per-user Chrome (`Detect-ChromePerUser.ps1`)

**User, not elevated.** It checks the signed-in user's own
`%LOCALAPPDATA%`. Running it as a different admin account checks that admin's
profile instead.

```powershell
$u='https://raw.githubusercontent.com/mrmeener/remediations/main/Chrome/Detect-ChromePerUser.ps1'; $f=Join-Path $env:TEMP (Split-Path $u -Leaf); iwr $u -OutFile $f -UseBasicParsing; powershell -NoProfile -ExecutionPolicy Bypass -File $f; "Exit: $LASTEXITCODE"
```

### Remove the per-user Chrome (`Remediate-ChromePerUser.ps1`)

**User, not elevated.** Uninstalls the user's per-user copy. Bookmarks,
passwords and extensions are kept for the system-wide Chrome. It does nothing
if there is no system-wide Chrome.

```powershell
$u='https://raw.githubusercontent.com/mrmeener/remediations/main/Chrome/Remediate-ChromePerUser.ps1'; $f=Join-Path $env:TEMP (Split-Path $u -Leaf); iwr $u -OutFile $f -UseBasicParsing; powershell -NoProfile -ExecutionPolicy Bypass -File $f; "Exit: $LASTEXITCODE"
```

### From cmd, the Run box, or an RMM tool

These start with `powershell`, so they work outside PowerShell too. The
script's exit code is passed back as `%ERRORLEVEL%`. Change the URL for other
scripts.

```cmd
powershell -NoProfile -ExecutionPolicy Bypass -Command "$u='https://raw.githubusercontent.com/mrmeener/remediations/main/Chrome/Detect-Chrome.ps1'; $f=Join-Path $env:TEMP (Split-Path $u -Leaf); iwr $u -OutFile $f -UseBasicParsing; powershell -NoProfile -ExecutionPolicy Bypass -File $f; exit $LASTEXITCODE"
```

```cmd
powershell -NoProfile -ExecutionPolicy Bypass -Command "$u='https://raw.githubusercontent.com/mrmeener/remediations/main/Chrome/Remediate-Chrome.ps1'; $f=Join-Path $env:TEMP (Split-Path $u -Leaf); iwr $u -OutFile $f -UseBasicParsing; powershell -NoProfile -ExecutionPolicy Bypass -File $f; exit $LASTEXITCODE"
```

**Pin a version for production:** replace `main` in the URL with a commit SHA,
e.g. `.../remediations/91fe122/Chrome/...`. A later push to the repo then
cannot change what runs.

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
