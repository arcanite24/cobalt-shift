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
    [int]$RaceWait = 215,
    # Seconds after the green light before measuring, for the field to leave.
    [int]$Settle = 15,
    # Drive at full throttle instead of sitting on the grid (not repeatable:
    # the camera and draw counts vary run to run).
    [switch]$Throttle,
    # first-run: the opening race at Montserrat, the car parked on the grid.
    # season: a profile past the first run (-Seed, restored every run) goes
    # Go Race > Season Play into its next event, and the race AI drives the
    # player's car (cobalt_ai_player). The seed is a user data folder holding
    # a profile folder; .local/seeds/after-first-race is at FWD Open race 2,
    # Ladera Test Track Short Circuit Reverse.
    [ValidateSet('first-run', 'season')]
    [string]$Route = 'first-run',
    [string]$Seed = ''
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
$python = Join-Path $root '.local/toolchain/python-3.13.15/python.exe'
$userRoot = Join-Path $root '.local/user'
$routeArguments = @('--cobalt_disc2_content=false')   # keeps the Disc 2 prompt the route answers
if ($Route -eq 'season') {
    if (-not $Seed) { $Seed = Join-Path $root '.local/seeds/after-first-race' }
    if (-not (Test-Path -LiteralPath $Seed)) { throw "No seed profile: $Seed" }
    $userRoot = Join-Path $root '.local/user-season'
    Remove-Item -LiteralPath $userRoot -Recurse -Force -ErrorAction SilentlyContinue
    Copy-Item -LiteralPath $Seed -Destination $userRoot -Recurse
    $routeArguments += '--cobalt_ai_player=true'
    if (-not $PSBoundParameters.ContainsKey('RaceWait')) { $RaceWait = 240 }
}
$pad = Join-Path $userRoot 'pad.txt'

$process = & (Join-Path $PSScriptRoot 'launch.ps1') -Executable $Executable -UserRoot $userRoot -GameArguments (@(
    "--perf_log_csv=$csv", "--log_file=$(Join-Path $logs "bench-$Name.log")") + $routeArguments + $GameArguments)
$started = Get-Date
try {
    if ($Route -eq 'season') {
        # The menus hide after a few idle seconds and the next press only
        # shows them again, so a press that may meet a hidden menu is doubled.
        Start-Sleep -Seconds 60
        Set-Content -LiteralPath $pad -Value (@(
            'A 200', 'wait 25000') +                         # intro movie
            @(1..8 | ForEach-Object { 'A 200'; 'wait 9000' }) + @(  # logo, attract, title
            'START 200', 'wait 5000', 'A 200', 'wait 6000',  # the car showcase > MAIN MENU
            'A 100', 'wait 3000',                            # GO RACE
            'A 100', 'wait 800', 'A 100', 'wait 8000',       # SEASON PLAY, the calendar's event
            'A 100', 'wait 15000',                           # START RACE: loads PRE-RACE
            'A 100', 'wait 1500', 'A 100') -join "`n")       # PRE-RACE: START RACE
    } else {
    Start-Sleep -Seconds 40
    Set-Content -LiteralPath $pad -Value (@(
        'A 200', 'wait 1500', 'A 200', 'wait 1500', 'START 200', 'wait 3000', 'START 200',
        'wait 20000', 'A 200',                               # title: Forza Motorsport 3
        'wait 15000', 'DOWN 200', 'wait 500', 'A 200',       # install Disc 2? NO
        'wait 15000') +
        # Then A every 2.5 s for 100 s: skip bonus content (YES), experience
        # (Casual), the showcase, the flyover and the race intro, whatever
        # their timing. Casual shifts automatically, so A does nothing on the grid.
        @(1..40 | ForEach-Object { 'A 200'; 'wait 2300' }) -join "`n")
    }
    if ($Throttle) { $Settle = 0 }
    $remaining = $RaceWait + $Settle - ((Get-Date) - $started).TotalSeconds
    if ($remaining -gt 0) { Start-Sleep -Seconds $remaining }
    $first = @(Get-Content -LiteralPath $csv).Count - 1
    $process.Refresh()
    $cpu0 = $process.TotalProcessorTime
    $threads0 = & (Join-Path $PSScriptRoot 'thread_cpu.ps1') -ProcessId $process.Id
    # Other ShiftGlue games share the CPU and GPU: record their CPU so a
    # contaminated run says so.
    $others = @(Get-Process -Name 'lavender_shift*', 'pinyon_shift*' -ErrorAction SilentlyContinue)
    $others0 = @{}; foreach ($o in $others) { $others0[$o.Id] = $o.TotalProcessorTime.TotalSeconds }
    $t0 = Get-Date
    if ($Throttle) { Set-Content -LiteralPath $pad -Value 'hold rt 1.0' }
    Start-Sleep -Seconds $Seconds
    $process.Refresh()
    $cores = ($process.TotalProcessorTime - $cpu0).TotalSeconds / ((Get-Date) - $t0).TotalSeconds
    $threads = & (Join-Path $PSScriptRoot 'thread_cpu.ps1') -ProcessId $process.Id -Since $threads0
    $elapsed = ((Get-Date) - $t0).TotalSeconds
    $otherCpu = @(foreach ($o in $others) {
        try { $o.Refresh(); '{0} {1}: {2:N2} cores' -f $o.Name, $o.Id, (($o.TotalProcessorTime.TotalSeconds - $others0[$o.Id]) / $elapsed) }
        catch { '{0} {1}: exited' -f $o.Name, $o.Id }
    })
    $last = @(Get-Content -LiteralPath $csv).Count - 1
    & (Join-Path $PSScriptRoot 'window_shot.ps1') -ProcessId $process.Id -Path (Join-Path $logs "bench-$Name.png")
    $frames = $last - $first
    $summary = @("bench $Name  route: $Route  exe: $Executable  args: $($GameArguments -join ' ')$(if ($Throttle) { '  (throttle)' })",
        ('process cores busy: {0:N2}  frames in window: {1}  ({2:N1}/s)  CPU per frame: {3:N2} ms' -f
            $cores, $frames, ($frames / $Seconds), ($cores * $Seconds * 1000 / [Math]::Max(1, $frames))),
        "other ShiftGlue games during the window: $(if ($otherCpu) { $otherCpu -join ', ' } else { 'none' })",
        '', 'threads:') + $threads + @('') +
        @(& $python -I (Join-Path $PSScriptRoot 'perf_summary.py') $csv $first $last)
    $summary | Set-Content -LiteralPath (Join-Path $logs "bench-$Name.txt")
    $summary
} finally {
    Stop-Process -Id $process.Id -ErrorAction SilentlyContinue
    # Back-to-back runs: launch.ps1 refuses to start while one is still exiting.
    Wait-Process -Id $process.Id -Timeout 30 -ErrorAction SilentlyContinue
}
