[CmdletBinding()]
param(
    # The seed folder: .local/seeds/<Name>, a user data folder holding the
    # profile (bench_race.ps1 -Route season restores it every run).
    [string]$Name = 'after-first-race',
    # Minutes of play. About 20 finished the first-run race, picked the Ford
    # Fiesta and won FWD Open race 1 at the Iberian Short Circuit; the next
    # event is then FWD Open race 2, Ladera Test Track Short Circuit Reverse.
    [int]$Minutes = 20
)

# Makes a profile past FM3's first run (#24): a fresh user folder walks the
# first-run flow with the race AI driving the player's car
# (cobalt_ai_player), while the scripted pad presses A every 2.8 s through
# the menus between races. Then the game closes and the profile is copied
# into the seed folder. What the A presses pick after the first race can
# vary; bench_race.ps1 -Route season only needs Season Play's next event.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$user = Join-Path $root '.local/user-seed'
$seed = Join-Path $root ".local/seeds/$Name"
Remove-Item -LiteralPath $user -Recurse -Force -ErrorAction SilentlyContinue
$process = & (Join-Path $PSScriptRoot 'launch.ps1') -UserRoot $user -GameArguments @(
    '--cobalt_ai_player=true', "--log_file=$(Join-Path $root '.local/logs/make-seed.log')")
try {
    Start-Sleep -Seconds 40
    Set-Content -LiteralPath (Join-Path $user 'pad.txt') -Value ((@(
        'A 200', 'wait 1500', 'A 200', 'wait 1500', 'START 200', 'wait 3000', 'START 200',
        'wait 20000', 'A 200', 'wait 15000', 'DOWN 200', 'wait 500', 'A 200', 'wait 15000') +
        @(1..1000 | ForEach-Object { 'A 200'; 'wait 2800' })) -join "`n")
    Start-Sleep -Seconds ($Minutes * 60 - 40)
} finally {
    # Closing the window lets the game finish its last profile write.
    $process.CloseMainWindow() | Out-Null
    if (-not $process.WaitForExit(30000)) { Stop-Process -Id $process.Id }
}
Remove-Item -LiteralPath $seed -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $seed | Out-Null
Get-ChildItem -LiteralPath $user -Directory |
    Where-Object { $_.Name -notin @('cache', 'utility_drive') } |
    Copy-Item -Destination $seed -Recurse
"seed: $seed"
