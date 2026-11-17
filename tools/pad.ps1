[CmdletBinding()]
param(
    # Pad commands (see src/pad_script.h), one per element.
    [string[]]$Commands = @(),
    # Seconds to wait after sending, before the screenshot.
    [double]$Wait = 5,
    [string]$Shot = 'shot'
)

# Sends scripted pad commands to the running game (tools/launch.ps1 points
# --pad_script_file at .local/user/pad.txt) and saves a window screenshot to
# .local/logs/<Shot>.png.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$process = Get-Process -Name 'cobalt_shift*' -ErrorAction Stop | Select-Object -First 1
if ($Commands.Count) { Set-Content -LiteralPath (Join-Path $root '.local/user/pad.txt') -Value ($Commands -join "`n") }
Start-Sleep -Milliseconds ([int]($Wait * 1000))
& (Join-Path $PSScriptRoot 'window_shot.ps1') -ProcessId $process.Id -Path (Join-Path $root ".local/logs/$Shot.png")
