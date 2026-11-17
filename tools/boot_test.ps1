[CmdletBinding()]
param(
    # Seconds to let the game run before the screenshot and the stop.
    [int]$Seconds = 60,
    [string[]]$GameArguments = @(),
    [string]$Name = 'boot',
    # Leave the game running after the screenshot.
    [switch]$KeepRunning
)

# Development boot check: start the game with a debug log, wait, save a
# screenshot of the game window's screen, then stop it and print the log's
# last fatal or error lines. Output goes to .local/logs/<Name>.*

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$logs = Join-Path $root '.local/logs'
[void](New-Item -ItemType Directory -Force -Path $logs)
$log = Join-Path $logs "$Name.log"
if (Test-Path $log) { Remove-Item $log -Force }
$process = & (Join-Path $PSScriptRoot 'launch.ps1') -GameArguments (@("--log_file=$log") + $GameArguments)
$deadline = (Get-Date).AddSeconds($Seconds)
while ((Get-Date) -lt $deadline -and -not $process.HasExited) { Start-Sleep -Milliseconds 500 }

$shot = Join-Path $logs "$Name.png"
if (-not $process.HasExited) {
    & (Join-Path $PSScriptRoot 'window_shot.ps1') -ProcessId $process.Id -Path $shot
    if (-not $KeepRunning) { Stop-Process -Id $process.Id -Force }
    "state: running after $Seconds s"
} else {
    "state: exited with 0x{0:X8} " -f $process.ExitCode
}
Start-Sleep -Milliseconds 500
if (Test-Path $log) {
    Get-Content -LiteralPath $log | Select-String -Pattern '\[critical\]|\[error\]|FATAL' | Select-Object -Last 12 |
        ForEach-Object { $_.Line }
}
