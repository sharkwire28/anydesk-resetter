#requires -Version 5.1
<#
.SYNOPSIS
Resets the standard Windows AnyDesk configuration with recoverable backups.
.EXAMPLE
.\Reset-AnyDesk.ps1 -WhatIf
.EXAMPLE
.\Reset-AnyDesk.ps1 -Force
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string]$AnyDeskPath,
    [ValidateRange(5, 300)]
    [int]$TimeoutSeconds = 60,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-PlainDirectoryTree {
    param([string]$Path)
    # Reject junctions/symlinks, including ancestors, before moving configuration.
    $cursor = $Path
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Linked paths are not supported: $cursor"
            }
        }
        $cursor = Split-Path -Path $cursor -Parent
    }
    if (Test-Path -LiteralPath $Path) {
        if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
            throw "Expected a directory: $Path"
        }
        $children = @(Get-ChildItem -LiteralPath $Path -Force)
        foreach ($child in $children) {
            if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Linked configuration entries are not supported: $($child.FullName)"
            }
            if ($child.PSIsContainer) { Assert-PlainDirectoryTree -Path $child.FullName }
        }
    }
}

function Stop-AnyDeskRuntime {
    $service = Get-Service -Name AnyDesk -ErrorAction SilentlyContinue
    if ($service -and $service.Status -ne 'Stopped') {
        Stop-Service -Name AnyDesk -ErrorAction Stop
        $service.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))
    }
    foreach ($process in @(Get-Process -Name AnyDesk -ErrorAction SilentlyContinue)) {
        Stop-Process -Id $process.Id -Force -ErrorAction Stop
        if (-not $process.WaitForExit(15000)) { throw 'AnyDesk did not exit in time.' }
    }
}

function Start-AnyDeskRuntime {
    param([string]$Executable, [bool]$HasService)
    if ($HasService) {
        Start-Service -Name AnyDesk -ErrorAction Stop
        (Get-Service -Name AnyDesk).WaitForStatus('Running', [TimeSpan]::FromSeconds(30))
    }
    Start-Process -FilePath $Executable -ErrorAction Stop | Out-Null
}

function Move-ConfigurationToBackup {
    param([object[]]$Entries)
    foreach ($entry in $Entries) {
        Assert-PlainDirectoryTree -Path $entry.Path
        if ($entry.Existed) {
            if (Test-Path -LiteralPath $entry.Backup) { throw "Backup already exists: $($entry.Backup)" }
            # Destination is an exact, unique sibling of the validated source.
            Move-Item -LiteralPath $entry.Path -Destination $entry.Backup -ErrorAction Stop
            $entry.Moved = $true
        }
        $entry.Touched = $true
        New-Item -ItemType Directory -Path $entry.Path -ErrorAction Stop | Out-Null
        if ($entry.Existed) {
            # Keep the original ACL (the files can contain credentials).
            Set-Acl -LiteralPath $entry.Path -AclObject (Get-Acl -LiteralPath $entry.Backup)
        }
        if ($entry.Kind -eq 'User' -and $entry.Existed) {
            foreach ($name in @('user.conf', 'thumbnails')) {
                $saved = Join-Path $entry.Backup $name
                if (Test-Path -LiteralPath $saved) {
                    Copy-Item -LiteralPath $saved -Destination $entry.Path -Recurse -Force
                }
            }
        }
    }
}

function Undo-ConfigurationReset {
    param([object[]]$Entries)
    foreach ($entry in $Entries) {
        if (-not $entry.Touched -and -not $entry.Moved) { continue }
        Assert-PlainDirectoryTree -Path $entry.Path
        if (Test-Path -LiteralPath $entry.Path) {
            # Preserve even the failed configuration; never recursively delete it.
            $failed = $entry.Backup + '.failed'
            if (Test-Path -LiteralPath $failed) { throw "Recovery destination already exists: $failed" }
            Move-Item -LiteralPath $entry.Path -Destination $failed
        }
        if ($entry.Moved) {
            Assert-PlainDirectoryTree -Path $entry.Backup
            Move-Item -LiteralPath $entry.Backup -Destination $entry.Path
        }
    }
}

function Wait-AnyDeskId {
    param([object[]]$Entries, [int]$Seconds)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($timer.Elapsed.TotalSeconds -lt $Seconds) {
        foreach ($entry in $Entries) {
            $config = Join-Path $entry.Path 'system.conf'
            if (Test-Path -LiteralPath $config -PathType Leaf) {
                try { $content = Get-Content -LiteralPath $config -Raw -ErrorAction Stop }
                catch [IO.IOException] { continue } # AnyDesk may still be writing.
                if ($content -match '(?m)^ad\.anynet\.id\s*=\s*(\d+)\s*$') {
                    return $Matches[1]
                }
            }
        }
        Start-Sleep -Milliseconds 500
    }
    throw "AnyDesk did not write a device ID within $Seconds seconds."
}

function Invoke-AnyDeskReset {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param([string]$Executable, [int]$Timeout = 60, [switch]$Force)

    if ($env:OS -ne 'Windows_NT') { throw 'This script supports Windows only.' }
    $service = Get-CimInstance -ClassName Win32_Service -Filter "Name='AnyDesk'"
    if (-not $Executable -and $service) {
        if ($service.PathName -match '^\s*"([^"]+\.exe)"') { $Executable = $Matches[1] }
        elseif ($service.PathName -match '^\s*(.+?\.exe)(?:\s|$)') { $Executable = $Matches[1] }
    }
    if (-not $Executable) {
        foreach ($base in @(${env:ProgramFiles(x86)}, $env:ProgramFiles)) {
            if ($base) {
                $candidate = Join-Path $base 'AnyDesk\AnyDesk.exe'
                if (Test-Path -LiteralPath $candidate -PathType Leaf) { $Executable = $candidate; break }
            }
        }
    }
    if (-not $Executable -or -not (Test-Path -LiteralPath $Executable -PathType Leaf)) {
        throw 'AnyDesk.exe was not found. Supply -AnyDeskPath with its full path.'
    }
    $Executable = (Resolve-Path -LiteralPath $Executable).ProviderPath
    if ([IO.Path]::GetFileName($Executable) -ine 'AnyDesk.exe') { throw 'Expected AnyDesk.exe.' }
    $stamp = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $entries = @(
        foreach ($kind in @('Machine', 'User')) {
            $base = if ($kind -eq 'Machine') { $env:ProgramData } else { $env:APPDATA }
            if (-not $base -or -not [IO.Path]::IsPathRooted($base)) { throw "Invalid $kind configuration root." }
            $path = [IO.Path]::GetFullPath((Join-Path $base 'AnyDesk'))
            Assert-PlainDirectoryTree -Path $path
            [pscustomobject]@{
                Kind = $kind; Path = $path; Backup = "$path.backup-$stamp"
                Existed = (Test-Path -LiteralPath $path); Moved = $false; Touched = $false
            }
        }
    )
    if ($entries[0].Path -eq $entries[1].Path) { throw 'Machine and user configuration paths must differ.' }
    if (-not (@($entries | Where-Object Existed).Count)) { throw 'No standard AnyDesk configuration directories were found.' }
    Write-Warning 'This disconnects AnyDesk sessions and may change the device ID and unattended-access settings.'
    foreach ($entry in $entries) { Write-Host "$($entry.Path) -> $($entry.Backup)" }
    if ($Force) { $ConfirmPreference = 'None' }
    if (-not $PSCmdlet.ShouldProcess(($entries.Path -join ', '), 'Back up and reset AnyDesk configuration')) { return }
    if (-not (Test-Administrator)) {
        throw 'Open PowerShell using Run as administrator, then run this script again.'
    }
    $wasRunning = (@(Get-Process -Name AnyDesk -ErrorAction SilentlyContinue).Count -gt 0)
    $serviceWasRunning = $service -and $service.State -eq 'Running'
    try {
        Stop-AnyDeskRuntime
        Move-ConfigurationToBackup -Entries $entries
        Start-AnyDeskRuntime -Executable $Executable -HasService ([bool]$service)
        $id = Wait-AnyDeskId -Entries $entries -Seconds $Timeout
    }
    catch {
        $originalError = $_
        try {
            Stop-AnyDeskRuntime
            Undo-ConfigurationReset -Entries $entries
            if ($serviceWasRunning) { Start-Service -Name AnyDesk }
            if ($wasRunning) { Start-Process -FilePath $Executable | Out-Null }
        }
        catch { Write-Warning "Automatic recovery was incomplete: $($_.Exception.Message). Backups are listed above." }
        throw $originalError
    }
    Write-Host "Reset completed. AnyDesk device ID: $id" -ForegroundColor Green
    Write-Host 'Original configuration is retained in the backup directories listed above.'
    [pscustomobject]@{ DeviceId = $id; Backups = @($entries | Where-Object Moved | Select-Object -ExpandProperty Backup) }
}

# Dot-sourcing exposes functions for isolated tests without touching AnyDesk.
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-AnyDeskReset -Executable $AnyDeskPath -Timeout $TimeoutSeconds -Force:$Force
}
