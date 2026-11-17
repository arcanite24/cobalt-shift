[CmdletBinding()]
param(
    # Capture name: .local/logs/regpu-<Name>.{log,txt,png}
    [Parameter(Mandatory)][string]$Name,
    # FM3-ReGPU checkout with build\rel\fm3.exe (route decision, docs/RESEARCH.md).
    [string]$Root = 'C:\Users\neri\code\FM3-ReGPU',
    # settings.ini values (FM3-ReGPU src/settings.cpp). max_fps is clamped to 30..360.
    [string]$Resolution = '1280x720',
    [int]$MaxFps = 60,
    [hashtable]$Settings = @{},
    # Extra environment for the game (REGPU_* switches).
    [hashtable]$Env = @{},
    [int]$Seconds = 60,
    [int]$RaceWait = 215,
    [int]$Settle = 15,
    # Another machine (blindvac): the game, disc and capture folders.
    [string]$Exe = '',
    [string]$Game = '',
    [string]$Logs = '',
    [string]$UserRoot = ''
)

# FM3-ReGPU on the same route and window as bench_race.ps1: boots with a
# fresh profile, walks FM3's first-run flow into the opening race at
# Montserrat (Disc 2 declined, Casual, showcase and flyover skipped) through
# ReGPU's debug server (TCP 7341, REGPU_DEBUG=1), then measures process CPU
# and ReGPU's light performance log (one "perf lite" line a second) while the
# player's car sits on the grid and the field drives off.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$cobalt = Split-Path -Parent $PSScriptRoot
$logs = New-Item -ItemType Directory -Force -Path $(if ($Logs) { $Logs } else { Join-Path $cobalt '.local/logs' })
$game = if ($Game) { $Game } else { Join-Path $cobalt '.local/game/disc' }
if (-not $Exe) { $Exe = Join-Path $Root 'build/rel/fm3.exe' }
if (-not $UserRoot) { $UserRoot = Join-Path $Root 'out' }
$user = Join-Path $UserRoot 'user-cobalt'
$run = Join-Path $UserRoot 'run-cobalt'
New-Item -ItemType Directory -Force $user, $run | Out-Null
$profiles = Join-Path $user 'profiles'
if (Test-Path $profiles) { Remove-Item -Recurse -Force $profiles }
$ini = @{ resolution = $Resolution; max_fps = $MaxFps; vsync = 0; skip_intro = 1 }
foreach ($k in $Settings.Keys) { $ini[$k] = $Settings[$k] }
($ini.Keys | Sort-Object | ForEach-Object { "$_=$($ini[$_])" }) | Set-Content (Join-Path $user 'settings.ini') -Encoding ascii
$log = Join-Path $run 'fm3.log'
if (Test-Path $log) { Clear-Content $log }

Get-Process fm3 -ErrorAction SilentlyContinue | Stop-Process -Force
$vars = @{ FM3_USER_DIR = $user; REGPU_DEBUG = '1'; REGPU_PERF_LITE = '1'; FM3_SKIP_INTRO = '1' }
foreach ($k in $Env.Keys) { $vars[$k] = $Env[$k] }
foreach ($k in $vars.Keys) { Set-Item "env:$k" $vars[$k] }
$process = Start-Process -FilePath $Exe -ArgumentList "`"$game`"" -WorkingDirectory $run -PassThru
foreach ($k in $vars.Keys) { Remove-Item "env:$k" -ErrorAction SilentlyContinue }
$started = Get-Date

$script:sock = $null
function Send-Fm3([string]$Command) {
    if (-not $script:sock -or -not $script:sock.Connected) {
        $script:sock = New-Object System.Net.Sockets.TcpClient
        $script:sock.Connect('127.0.0.1', 7341)
        $script:sock.ReceiveTimeout = 30000
        $stream = $script:sock.GetStream()
        $script:writer = New-Object System.IO.StreamWriter($stream); $script:writer.AutoFlush = $true
        $script:reader = New-Object System.IO.StreamReader($stream)
    }
    $script:writer.Write("$Command`n")
    $script:reader.ReadLine()
}
function Press([string]$Button, [int]$WaitMs) {
    $null = Send-Fm3 "press $Button 200"
    Start-Sleep -Milliseconds (200 + $WaitMs)
}

try {
    Start-Sleep -Seconds 40
    # The debug pad counts as connected only while it holds something: a
    # neutral stick with no duration keeps it plugged in between presses.
    $null = Send-Fm3 'stick L 0 0'
    # bench_race.ps1's pad script, step for step.
    Press A 1500; Press A 1500; Press START 3000; Press START 20000
    Press A 15000                                   # title: Forza Motorsport 3
    Press DOWN 500; Press A 15000                   # install Disc 2? NO
    for ($i = 0; $i -lt 40; $i++) { Press A 2300 }  # bonus content, Casual, showcase, flyover, intro
    $remaining = $RaceWait + $Settle - ((Get-Date) - $started).TotalSeconds
    if ($remaining -gt 0) { Start-Sleep -Seconds $remaining }
    $process.Refresh()
    $cpu0 = $process.TotalProcessorTime
    $t0 = Get-Date
    $logStart = ((Get-Date) - $process.StartTime).TotalSeconds
    Start-Sleep -Seconds $Seconds
    $process.Refresh()
    $elapsed = ((Get-Date) - $t0).TotalSeconds
    $cores = ($process.TotalProcessorTime - $cpu0).TotalSeconds / $elapsed
    $shot = Join-Path $logs "regpu-$Name.png"
    $null = Send-Fm3 "shot $shot"
    Start-Sleep -Seconds 2
    # The log clock starts near process start; take the perf lines inside the window.
    $rx = '^\[\s*([\d.]+)\] perf lite: ([\d.]+) fps, ([\d.]+) ms/frame \(p99 ([\d.]+) ms, max ([\d.]+) ms\) \| (\d+) draws/frame \| GPU ([\d.]+) ms/frame \| draw thread (-?\d+)% busy'
    $rows = @(Get-Content $log | ForEach-Object { if ($_ -match $rx) {
                [pscustomobject]@{ t = [double]$Matches[1]; fps = [double]$Matches[2]; p99 = [double]$Matches[4]
                    max = [double]$Matches[5]; draws = [int]$Matches[6]; gpu = [double]$Matches[7]; busy = [int]$Matches[8] } } } |
        Where-Object { $_.t -ge $logStart - 2 -and $_.t -le $logStart + $Seconds + 2 })
    $size = (Select-String -Path $log -Pattern 'gpu: ReGPU at (\d+x\d+), msaa (\d+)' | Select-Object -First 1)
    $avg = { param($f) if ($rows.Count) { ($rows | Measure-Object -Property $f -Average).Average } else { 0 } }
    $p99s = @($rows | ForEach-Object p99 | Sort-Object)
    $summary = @(
        "regpu $Name  $(if ($size) { $size.Matches[0].Value })  max_fps $MaxFps  env: $(($Env.Keys | ForEach-Object { "$_=$($Env[$_])" }) -join ' ')",
        ('process cores busy: {0:N2}  perf lines: {1}' -f $cores, $rows.Count),
        ('fps avg {0:N1}  lowest second {1:N1}  p99 median {2:N2} ms  max {3:N2} ms  draws {4:N0}  GPU {5:N2} ms/frame  draw thread {6:N0}% busy' -f
            (& $avg 'fps'), ($(if ($rows.Count) { ($rows | Measure-Object fps -Minimum).Minimum } else { 0 })),
            ($(if ($p99s.Count) { $p99s[[int]($p99s.Count / 2)] } else { 0 })),
            ($(if ($rows.Count) { ($rows | Measure-Object max -Maximum).Maximum } else { 0 })),
            (& $avg 'draws'), (& $avg 'gpu'), (& $avg 'busy')),
        ('CPU per frame: {0:N2} ms' -f ($cores * 1000 / [Math]::Max(1, (& $avg 'fps')))))
    $summary | Set-Content -LiteralPath (Join-Path $logs "regpu-$Name.txt")
    Copy-Item $log (Join-Path $logs "regpu-$Name.log")
    $summary
} finally {
    if ($script:sock) { $script:sock.Close() }
    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    Wait-Process -Id $process.Id -Timeout 30 -ErrorAction SilentlyContinue
}
