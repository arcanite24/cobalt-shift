[CmdletBinding()]
param(
    # Names the log, CSV, results and screenshots under .local/logs.
    [Parameter(Mandatory)][string]$Name,
    # Switches to A/B in this boot, one after another, each "cvar=off/on"
    # (cvars that reload live, Lifecycle::kHotReload). None: one null A/B,
    # the noise floor.
    [string[]]$Switch = @(),
    [int]$Rounds = 5,
    # Seconds measured per side per round, after Settle seconds.
    [int]$Window = 5,
    [double]$Settle = 2,
    # No frame cap: render limit 180, no present limit, no vsync.
    [switch]$Uncapped,
    [string[]]$GameArguments = @(),
    [string]$Executable = 'cobalt_shift.exe',
    # Seconds from launch to the frozen grid.
    [int]$RaceWait = 240,
    [string]$Seed = ''
)

# Frozen-grid A/B (#5), like FM3-ReGPU's tools/fm3_ab.ps1: boots the Season
# Play race at Ladera from a seed profile (the route of bench_race.ps1 -Route
# season), stops the world on the start grid at the countdown's "1"
# (--cobalt_freeze_grid_at=9, src/frozen_grid.cpp), then switches each -Switch
# between its two values through the live file (--cobalt_live_file),
# interleaved, -Rounds times. The frozen scene holds steady (draw calls per
# frame within ±0.7 %), so the sides differ by the switch alone. A warm-up
# window is measured and dropped first.
# Each window counts as its median frame time (tools/ab_windows.py), so the
# odd slow frame does not move it.
# Screenshots of each switch's first round go to ab-<Name>-<cvar>-off.png and
# -on.png.
#
# A switch's result is clear when the on-off difference has the same sign in
# every round (each round's two windows are back to back, in ABBA order, so
# slow drift and the second window's bias cancel).
#   pwsh -File tools/bench_ab.ps1 -Name rates -Uncapped -Switch cobalt_shadow_rate=1/2,cobalt_reflect_rate=1/2

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$logs = New-Item -ItemType Directory -Force -Path (Join-Path $root '.local/logs')
$csv = Join-Path $logs "ab-$Name.csv"
Remove-Item -LiteralPath $csv -ErrorAction SilentlyContinue
if (-not $Seed) { $Seed = Join-Path $root '.local/seeds/after-first-race' }
if (-not (Test-Path -LiteralPath $Seed)) { throw "No seed profile: $Seed" }
$userRoot = Join-Path $root '.local/user-ab'
Remove-Item -LiteralPath $userRoot -Recurse -Force -ErrorAction SilentlyContinue
Copy-Item -LiteralPath $Seed -Destination $userRoot -Recurse
$pad = Join-Path $userRoot 'pad.txt'
$live = Join-Path $userRoot 'live.txt'
$python = Join-Path $root '.local/toolchain/python-3.13.15/python.exe'
# pwsh -File passes an array as one comma-joined string.
$GameArguments = @($GameArguments | ForEach-Object { $_ -split ',(?=--)' } | Where-Object { $_ })
$Switch = @($Switch | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
if ($Uncapped) {
    $GameArguments += '--pinyon_shift_fh1_render_fps_limit=180', '--host_present_fps_limit=0', '--vsync=false'
}
$specs = @(foreach ($s in $Switch) {
    if ($s -notmatch '^([^=]+)=([^/]*)/(.*)$') { throw "Switch '$s': expected cvar=off/on" }
    [pscustomobject]@{ Cvar = $Matches[1]; Off = $Matches[2]; On = $Matches[3] }
})
if (-not $specs) { $specs = @([pscustomobject]@{ Cvar = ''; Off = ''; On = '' }) }

function Rows { [Math]::Max(0, @(Get-Content -LiteralPath $csv).Count - 1) }
function Set-Live([string]$cvar, [string]$value) {
    if ($cvar) { Set-Content -LiteralPath $live -Value "$cvar $value" }
    $deadline = (Get-Date).AddSeconds(5)
    while ((Test-Path -LiteralPath $live) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
    Start-Sleep -Seconds $Settle
}
function Sample {
    $first = Rows
    Start-Sleep -Seconds $Window
    "${first}:$(Rows)"
}
# Each window's median frame time, as fps (tools/ab_windows.py).
function Median-Fps([string[]]$windows) {
    $ms = (& $python -I (Join-Path $PSScriptRoot 'ab_windows.py') $csv @windows) -split ' '
    @($ms | ForEach-Object { [Math]::Round(1000 / [double]$_, 1) })
}
function Shot([string]$path) {
    & (Join-Path $PSScriptRoot 'window_shot.ps1') -ProcessId $process.Id -Path $path | Out-Null
}

$process = & (Join-Path $PSScriptRoot 'launch.ps1') -Executable $Executable -UserRoot $userRoot -GameArguments (@(
    "--perf_log_csv=$csv", "--log_file=$(Join-Path $logs "ab-$Name.log")",
    '--cobalt_freeze_grid_at=9', "--cobalt_live_file=$live") + $GameArguments)
$started = Get-Date
$summary = @("ab $Name  args: $($GameArguments -join ' ')")
try {
    Start-Sleep -Seconds 60
    Set-Content -LiteralPath $pad -Value (@(
        'A 200', 'wait 25000') +                         # intro movie
        @(1..8 | ForEach-Object { 'A 200'; 'wait 9000' }) + @(  # logo, attract, title
        'START 200', 'wait 5000', 'A 200', 'wait 6000',  # the car showcase > MAIN MENU
        'A 100', 'wait 3000',                            # GO RACE
        'A 100', 'wait 800', 'A 100', 'wait 8000',       # SEASON PLAY, the calendar's event
        'A 100', 'wait 15000',                           # START RACE: loads PRE-RACE
        'A 100', 'wait 1500', 'A 100') -join "`n")       # PRE-RACE: START RACE
    $remaining = $RaceWait - ((Get-Date) - $started).TotalSeconds
    if ($remaining -gt 0) { Start-Sleep -Seconds $remaining }
    Set-Live '' ''; $null = Sample   # warm-up
    foreach ($spec in $specs) {
        $off = @(); $on = @()
        for ($r = 0; $r -lt $Rounds; $r++) {
            # ABBA: odd rounds measure "on" first, so a bias of the second
            # window in a pair (seen in null A/Bs: +2.4 %) cancels.
            foreach ($side in $(if ($r % 2) { "on", "off" } else { "off", "on" })) {
                Set-Live $spec.Cvar $(if ($side -eq "on") { $spec.On } else { $spec.Off })
                if ($side -eq "on") { $on += Sample } else { $off += Sample }
                if ($r -eq 0) { Shot (Join-Path $logs "ab-$Name-$($spec.Cvar)-$side.png") }
            }
        }
        Set-Live $spec.Cvar $spec.Off
        $off = Median-Fps $off; $on = Median-Fps $on
        $diff = @(for ($r = 0; $r -lt $Rounds; $r++) { [Math]::Round(100 * ($on[$r] - $off[$r]) / $off[$r], 1) })
        $avgOff = ($off | Measure-Object -Average).Average; $avgOn = ($on | Measure-Object -Average).Average
        $verdict = if (@($diff | Where-Object { $_ -gt 0 }).Count -eq $Rounds) { 'on faster in every round' }
            elseif (@($diff | Where-Object { $_ -lt 0 }).Count -eq $Rounds) { 'off faster in every round' }
            else { 'rounds disagree: no clear difference' }
        $summary += @('',
            "$(if ($spec.Cvar) { "$($spec.Cvar) $($spec.Off) / $($spec.On)" } else { 'null A/B' })",
            ('  off: {0}  avg {1:N1} fps (median frame)' -f ($off -join ' '), $avgOff),
            ('  on:  {0}  avg {1:N1} fps (median frame)' -f ($on -join ' '), $avgOn),
            ('  on vs off by round: {0} %  avg {1:N1} %  -> {2}' -f ($diff -join ' '), (100 * ($avgOn - $avgOff) / $avgOff), $verdict))
    }
    $summary | Set-Content -LiteralPath (Join-Path $logs "ab-$Name.txt")
    $summary
} finally {
    Stop-Process -Id $process.Id -ErrorAction SilentlyContinue
    Wait-Process -Id $process.Id -Timeout 30 -ErrorAction SilentlyContinue
}
