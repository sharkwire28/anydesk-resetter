# AnyDesk Resetter

A Windows PowerShell utility that resets the standard AnyDesk configuration, keeps dated backups, preserves the current user's `user.conf` and thumbnails, and restarts AnyDesk. Supports Windows PowerShell 5.1 and PowerShell 7.

## Automatic method (PowerShell)

The command below downloads `Reset-AnyDesk.ps1` from the `main` branch of [sharkwire28/anydesk-resetter](https://github.com/sharkwire28/anydesk-resetter).

Open **PowerShell as administrator**, then paste:

```powershell
irm https://raw.githubusercontent.com/sharkwire28/anydesk-resetter/main/Reset-AnyDesk.ps1 | iex
```

This downloads and runs the script, then asks you to confirm the reset. `irm` is short for `Invoke-RestMethod`; `iex` is short for `Invoke-Expression`. The script runs in memory without saving a local copy.

For an **unattended reset** without the confirmation prompt:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/sharkwire28/anydesk-resetter/main/Reset-AnyDesk.ps1 -ErrorAction Stop))) -Force
```

To keep using **Invoke-WebRequest** and save a copy before running:

```powershell
$ErrorActionPreference = 'Stop'
$f = Join-Path $env:TEMP ('Reset-AnyDesk-' + [guid]::NewGuid() + '.ps1')
Invoke-WebRequest -UseBasicParsing -Uri 'https://raw.githubusercontent.com/sharkwire28/anydesk-resetter/main/Reset-AnyDesk.ps1' -OutFile $f
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $f -Force
```

Use a URL you control and trust; replace `main` with a commit SHA to pin a specific version. On older Windows PowerShell configurations that report a TLS connection error, run `[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12` before downloading.

## Run locally

From this folder in an administrator PowerShell window:

```powershell
# Preview the paths and operation without stopping AnyDesk or changing files.
.\Reset-AnyDesk.ps1 -WhatIf

# Reset after a confirmation prompt.
.\Reset-AnyDesk.ps1

# Reset automatically.
.\Reset-AnyDesk.ps1 -Force

# Portable installation or a nonstandard executable location.
.\Reset-AnyDesk.ps1 -AnyDeskPath 'C:\Tools\AnyDesk.exe' -Force
```

If local script policy blocks execution, use `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Reset-AnyDesk.ps1 -Force`.

## What changes

- Stops the standard `AnyDesk` service and all processes named `AnyDesk`.
- Moves `%ProgramData%\AnyDesk` and the elevated account's `%APPDATA%\AnyDesk` to unique sibling directories named `AnyDesk.backup-<timestamp>-<suffix>`.
- Creates fresh configuration folders with the original folder permissions, then copies back the user's `user.conf` and `thumbnails` if present.
- Starts AnyDesk and waits up to 60 seconds for a device ID in a newly generated `system.conf`.
- Attempts automatic rollback if the reset, restart, or ID check fails. Failed replacement folders are preserved with a `.failed` suffix.

Run locally: this disconnects current AnyDesk sessions. Your device ID and unattended-access/security settings may change; review them afterward. It resets only the two standard configuration folders, not other Windows users or custom-client profiles. If you elevate as another account, that account's roaming profile is used. Custom service names are unsupported.

A generated ID confirms configuration was recreated; it does not prove the ID changed or guarantee removal of account/server-side restrictions. This utility does not activate or extend an AnyDesk license.

Backups can contain private configuration and access credentials. They stay beside the original directories with their existing permissions; keep them private and retain them until you have verified the reset.

## Manual recovery

If automatic recovery is incomplete, the error output lists the backup paths. In an administrator PowerShell window, stop the `AnyDesk` service and AnyDesk processes. For each original configuration directory, rename its replacement to an unused sibling name, then move the corresponding `AnyDesk.backup-...` directory back to the exact original path printed by the script. Restart AnyDesk. Do not merge old identity files into the new configuration while AnyDesk is running.

## Reference

Inspired by [henriquelucas/Reset-Licen-a-Anydesk](https://github.com/henriquelucas/Reset-Licen-a-Anydesk). This is an independently written PowerShell implementation of the configuration-reset workflow; no upstream script is downloaded or executed by this project.
