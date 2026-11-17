[CmdletBinding()]
param(
    # Capture name: .local/logs/bench-<Name>.{csv,log,txt,png}
    [Parameter(Mandatory)][string]$Name,
    # Extra cvars for this run.
    [string[]]$GameArguments = @(),
    # Executable in the build folder (A/B builds).
    [string]$Executable = 'cobalt_shift.exe',
    # Seconds to measure.
    [int]$Seconds = 60,
    # Seconds from launch to the first race's green light.
    [int]$RaceWait = 205,
    # Seconds after the green light before measuring, for the field to leave.
    [int]$Settle = 15,
    # Drive at full throttle instead of sitting on the grid (not repeatable:
    # the camera and draw counts vary run to run).
    [switch]$Throttle
)

# Repeatable baseline: boots FM3, walks the first-run flow into the opening
# race at Montserrat (Disc 2 declined, Casual, showcase and flyover skipped)
# with the scripted pad, then measures the perf CSV window, process CPU, CPU
# per thread and a screenshot. By default the player's car sits on the grid
# while the field drives off, a static view like FM3-ReGPU's grid benchmark.
# FM3 does not keep the first-run choices without a signed-in profile, so
# every run takes the same route.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$logs = New-Item -ItemType Directory -Force -Path (Join-Path $root '.local/logs')
$csv = Join-Path $logs "bench-$Name.csv"
Remove-Item -LiteralPath $csv -ErrorAction SilentlyContinue
$pad = Join-Path $root '.local/user/pad.txt'
$python = Join-Path $root '.local/toolchain/python-3.13.15/python.exe'

$process = & (Join-Path $PSScriptRoot 'launch.ps1') -Executable $Executable -GameArguments (@(
    "--perf_log_csv=$csv", "--log_file=$(Join-Path $logs "bench-$Name.log")") + $GameArguments)
$started = Get-Date
try {
    Start-Sleep -Seconds 40
    Set-Content -LiteralPath $pad -Value (@(
        'A 200', 'wait 1500', 'A 200', 'wait 1500', 'START 200', 'wait 3000', 'START 200',
        'wait 20000', 'A 200',                               # title: Forza Motorsport 3
        'wait 15000', 'DOWN 200', 'wait 500', 'A 200',       # install Disc 2? NO
        'wait 20000', 'A 200',                               # skip bonus content: YES
        'wait 20000', 'A 200',                               # experience: Casual
        'wait 15000', 'A 200', 'wait 8000', 'A 200', 'wait 8000', 'A 200', 'wait 3000', 'A 200'
    ) -join "`n")
    if ($Throttle) { $Settle = 0 }
    $remaining = $RaceWait + $Settle - ((Get-Date) - $started).TotalSeconds
    if ($remaining -gt 0) { Start-Sleep -Seconds $remaining }
    $first = @(Get-Content -LiteralPath $csv).Count - 1
    $process.Refresh()
    $cpu0 = $process.TotalProcessorTime
    $threads0 = & (Join-Path $PSScriptRoot 'thread_cpu.ps1') -ProcessId $process.Id
    $t0 = Get-Date
    if ($Throttle) { Set-Content -LiteralPath $pad -Value 'hold rt 1.0' }
    Start-Sleep -Seconds $Seconds
    $process.Refresh()
    $cores = ($process.TotalProcessorTime - $cpu0).TotalSeconds / ((Get-Date) - $t0).TotalSeconds
    $threads = & (Join-Path $PSScriptRoot 'thread_cpu.ps1') -ProcessId $process.Id -Since $threads0
    $last = @(Get-Content -LiteralPath $csv).Count - 1
    & (Join-Path $PSScriptRoot 'window_shot.ps1') -ProcessId $process.Id -Path (Join-Path $logs "bench-$Name.png")
    $frames = $last - $first
    $summary = @("bench $Name  exe: $Executable  args: $($GameArguments -join ' ')$(if ($Throttle) { '  (throttle)' })",
        ('process cores busy: {0:N2}  frames in window: {1}  ({2:N1}/s)  CPU per frame: {3:N2} ms' -f
            $cores, $frames, ($frames / $Seconds), ($cores * $Seconds * 1000 / [Math]::Max(1, $frames))),
        '', 'threads:') + $threads + @('') +
        @(& $python -I (Join-Path $PSScriptRoot 'perf_summary.py') $csv $first $last)
    $summary | Set-Content -LiteralPath (Join-Path $logs "bench-$Name.txt")
    $summary
} finally {
    Stop-Process -Id $process.Id -ErrorAction SilentlyContinue
}
