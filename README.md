# remediations

PowerShell scripts for keeping Windows devices patched, written for
[Intune Remediations](https://learn.microsoft.com/intune/intune-service/fundamentals/remediations)
and also usable by hand.

| Folder | What it does |
|---|---|
| [Chrome](Chrome/) | Keeps system-wide Google Chrome on the latest stable version and removes unmanaged per-user copies. |
| [DotNet8](DotNet8/) | Keeps the Microsoft .NET 8.0 runtimes on the latest patch, and finds apps that depend on .NET 8 ahead of its end of support (10 November 2026). |

## How each remediation works

Each remediation is a pair of scripts:

- `Detect-*.ps1` exits `0` when the device is compliant (or the check does
  not apply) and `1` when it needs fixing. It writes a one-line result,
  which Intune shows in the detection output column.
- `Remediate-*.ps1` runs only when detection exits `1`. It exits `0` on
  success and `1` on failure, and writes a full log to
  `C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\`.

Each folder's README lists the Intune settings for its scripts.

## Running a script straight from GitHub

Each folder's README has a ready-to-paste one-liner for every script:
[Chrome](Chrome/README.md#running-from-github-one-liners),
[DotNet8](DotNet8/README.md#running-from-github-one-liners).

They all follow the same pattern: download the script to a temp file, then
run it with `-File`. Avoid
`irm ... | iex`: the scripts end with `exit`, which closes your PowerShell
window under `iex`, and `#Requires -RunAsAdministrator` only works in a
script file.

```powershell
$f=Join-Path $env:TEMP 'Detect-Chrome.ps1'; iwr 'https://raw.githubusercontent.com/mrmeener/remediations/main/Chrome/Detect-Chrome.ps1' -OutFile $f -UseBasicParsing; powershell -NoProfile -ExecutionPolicy Bypass -File $f; "Exit: $LASTEXITCODE"
```

From cmd or an RMM tool, which passes the exit code back to the caller:

```cmd
powershell -NoProfile -ExecutionPolicy Bypass -Command "$f=Join-Path $env:TEMP 'Detect-Chrome.ps1'; iwr 'https://raw.githubusercontent.com/mrmeener/remediations/main/Chrome/Detect-Chrome.ps1' -OutFile $f -UseBasicParsing; powershell -NoProfile -ExecutionPolicy Bypass -File $f; exit $LASTEXITCODE"
```

Change the folder and file name for other scripts. Remediation scripts need
an elevated prompt.

**Security:** anyone who can push to this repo can run code as admin on every
device that runs these one-liners. For production use, replace `main` in the
URL with a commit SHA so a later push cannot change what runs, and keep
write access to the repo restricted.

## Adding a remediation

1. Create a folder named after the product.
2. Add `Detect-<Product>.ps1` and `Remediate-<Product>.ps1` that follow the
   exit-code rules above. The Chrome scripts are a good template.
3. Add a README with the Intune settings and anything that needs a decision
   before rollout.
4. Add a row to the table at the top of this file.
