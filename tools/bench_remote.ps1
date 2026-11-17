[CmdletBinding()]
param(
    # Capture name: .local/logs/remote-<HostName>-<Name>.{csv,log,txt,png}
    [Parameter(Mandatory)][string]$Name,
    [string[]]$GameArguments = @(),
    [string]$HostName = 'blindvac',
    [int]$Seconds = 60,
    [int]$RaceWait = 215,
    [int]$Settle = 15,
    # Start the game in the logged-on session (CobaltBench task) instead of
    # over SSH, and take screenshots (CobaltShot task).
    [switch]$Interactive,
    # With -Interactive: screenshots every this many seconds from launch.
    [int]$ShotEvery = 0,
    # Hold the throttle once the race has started, so the window measures the
    # car moving instead of standing on the grid.
    [switch]$Drive,
    # As bench_race.ps1: first-run, or season (C:\cobalt\seeds\after-first-race
    # restored into C:\cobalt\user-season, the race AI driving).
    [ValidateSet('first-run', 'season')]
    [string]$Route = 'first-run'
)

# bench_race.ps1 for another machine on the LAN (the low-end target is
# blindvac's UHD 620). By default the game runs in the SSH session (session
# 0): Vulkan renders there and the guest frame loop runs as usual, but nothing
# is shown. One SSH connection stays open for the run, holding
# C:\cobalt\launch.ps1 -Wait (cvars from C:\cobalt\args.txt), because closing
# it ends the game. With -Interactive the CobaltBench scheduled task starts it
# in the logged-on session, and CobaltShot saves that screen to
# C:\cobalt\logs\shot.png (a disconnected session gives a stale image). The
# build lives in C:\cobalt\bin with an app-local VC++ runtime, the disc in
# C:\cobalt\game\disc (docs/BASELINE.md, "Low-end: blindvac").

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$logs = New-Item -ItemType Directory -Force -Path (Join-Path $root '.local/logs')
$stem = Join-Path $logs "remote-$HostName-$Name"
$python = Join-Path $root '.local/toolchain/python-3.13.15/python.exe'

# Runs a PowerShell script on the host, encoded so quoting survives (CLAUDE.md).
function Invoke-Remote([string]$Script) {
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Script))
    $output = & ssh -o BatchMode=yes $HostName "powershell -NoProfile -NonInteractive -EncodedCommand $encoded" 2>$null
    @($output | Where-Object { $_ -notmatch '^#< CLIXML|^<Objs' })
}
function Save-Shot([string]$Path) {
    Invoke-Remote 'Remove-Item C:\cobalt\logs\shot.png -ErrorAction SilentlyContinue; schtasks /Run /TN CobaltShot | Out-Null; for ($i = 0; $i -lt 20 -and -not (Test-Path C:\cobalt\logs\shot.png); $i++) { Start-Sleep -Milliseconds 500 }; Start-Sleep -Milliseconds 500' | Out-Null
    & scp -q -o BatchMode=yes "${HostName}:C:/cobalt/logs/shot.png" $Path 2>$null
}

# blindvac's NVIDIA 930MX is disabled for Windows, but Vulkan still lists it
# and picks it by default (the game hung there); the UHD 620 is device 0.
$arguments = @('--perf_log_csv=C:\cobalt\logs\bench.csv', '--log_file=C:\cobalt\logs\bench.log',
    '--vulkan_device=0') + $GameArguments
# The user data folder C:\cobalt\launch.ps1 (tools/remote/launch.ps1) uses.
$user = 'C:\cobalt\user'
$userSetup = 'Remove-Item C:\cobalt\user_root.txt -ErrorAction SilentlyContinue'
if ($Route -eq 'season') {
    $user = 'C:\cobalt\user-season'
    $arguments += '--cobalt_ai_player=true'
    if (-not $PSBoundParameters.ContainsKey('RaceWait')) { $RaceWait = 240 }
    $userSetup = "Remove-Item -Recurse -Force $user -ErrorAction SilentlyContinue; " +
        "Copy-Item -Recurse C:\cobalt\seeds\after-first-race $user; Set-Content C:\cobalt\user_root.txt $user"
}
Invoke-Remote @"
if (Get-Process cobalt_shift -ErrorAction SilentlyContinue) { throw 'cobalt_shift is already running' }
Remove-Item C:\cobalt\logs\bench.csv, C:\cobalt\logs\bench.log, $user\pad.txt -ErrorAction SilentlyContinue
$userSetup
Set-Content -LiteralPath C:\cobalt\args.txt -Value @('$($arguments -join "','")')
"@ | Out-Null
$holder = $null
if ($Interactive) {
    Invoke-Remote 'schtasks /Run /TN CobaltBench | Out-Null' | Out-Null
} else {
    $holder = Start-Process -FilePath ssh -WindowStyle Hidden -PassThru -ArgumentList @('-o', 'BatchMode=yes',
        $HostName, 'powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File C:\cobalt\launch.ps1 -Wait')
}
$started = Get-Date
"launched on ${HostName}: $($GameArguments -join ' ')"
$first = 0; $last = 0; $cores = 0.0
try {
    $pad = @('A 200', 'wait 1500', 'A 200', 'wait 1500', 'START 200', 'wait 3000', 'START 200',
        'wait 20000', 'A 200', 'wait 15000', 'DOWN 200', 'wait 500', 'A 200', 'wait 15000') +
        @(1..40 | ForEach-Object { 'A 200'; 'wait 2300' })   # as bench_race.ps1
    $padAt = 40
    if ($Route -eq 'season') {
        $pad = @('A 200', 'wait 25000') + @(1..8 | ForEach-Object { 'A 200'; 'wait 9000' }) +
            @('START 200', 'wait 5000', 'A 200', 'wait 6000', 'A 100', 'wait 3000',
              'A 100', 'wait 800', 'A 100', 'wait 8000', 'A 100', 'wait 15000',
              'A 100', 'wait 1500', 'A 100')               # as bench_race.ps1 -Route season
        $padAt = 60
    }
    if ($Drive) { $pad += @('hold rt 1.0') }
    $nextShot = if ($Interactive -and $ShotEvery) { $ShotEvery } else { [int]::MaxValue }
    while (((Get-Date) - $started).TotalSeconds -lt $RaceWait + $Settle) {
        $elapsed = ((Get-Date) - $started).TotalSeconds
        if ($elapsed -ge $padAt -and $pad) {
            Invoke-Remote "Set-Content -LiteralPath $user\pad.txt -Value @('$($pad -join "','")')" | Out-Null
            $pad = $null
        }
        if ($elapsed -ge $nextShot) {
            Save-Shot "$stem-t$([int]$elapsed).png"
            $nextShot += $ShotEvery
        }
        Start-Sleep -Seconds 2
    }
    # The window: process CPU and perf CSV rows, measured on the host.
    $measure = Invoke-Remote @"
`$p = Get-Process cobalt_shift -ErrorAction Stop
`$rows0 = @(Get-Content C:\cobalt\logs\bench.csv).Count - 1
`$cpu0 = `$p.TotalProcessorTime.TotalSeconds; `$t0 = Get-Date
Start-Sleep -Seconds $Seconds
`$p.Refresh()
`$cores = (`$p.TotalProcessorTime.TotalSeconds - `$cpu0) / ((Get-Date) - `$t0).TotalSeconds
`$rows1 = @(Get-Content C:\cobalt\logs\bench.csv).Count - 1
"`$rows0 `$rows1 `$cores"
"@
    $first, $last, $cores = ($measure | Select-Object -Last 1) -split ' '
    $first = [int]$first; $last = [int]$last; $cores = [double]$cores
    if ($Interactive) { Save-Shot "$stem.png" }
} finally {
    Invoke-Remote 'Stop-Process -Name cobalt_shift -ErrorAction SilentlyContinue; Wait-Process -Name cobalt_shift -Timeout 30 -ErrorAction SilentlyContinue' | Out-Null
    if ($holder) {
        Wait-Process -Id $holder.Id -Timeout 30 -ErrorAction SilentlyContinue
        Stop-Process -Id $holder.Id -ErrorAction SilentlyContinue
    }
}
& scp -q -o BatchMode=yes "${HostName}:C:/cobalt/logs/bench.csv" "$stem.csv" 2>$null
& scp -q -o BatchMode=yes "${HostName}:C:/cobalt/logs/bench.log" "$stem.log" 2>$null
$frames = $last - $first
$summary = @("remote bench $Name on ${HostName}  route: $Route  args: $($GameArguments -join ' ')",
    ('process cores busy: {0:N2}  frames in window: {1}  ({2:N1}/s)  CPU per frame: {3:N2} ms' -f
        $cores, $frames, ($frames / $Seconds), ($cores * $Seconds * 1000 / [Math]::Max(1, $frames))), '') +
    @(& $python -I (Join-Path $PSScriptRoot 'perf_summary.py') "$stem.csv" $first $last)
$summary | Set-Content -LiteralPath "$stem.txt"
$summary
