[CmdletBinding()]
param(
    [ValidateSet('Release', 'RelWithDebInfo')]
    [string]$Configuration = 'Release',
    # Player data (saves, cache, logs). Defaults to .local/user.
    [string]$UserRoot = '',
    # Extra cvars, e.g. '--log_level=debug'.
    [string[]]$GameArguments = @(),
    # Wait for the game to exit and return its exit code.
    [switch]$Wait
)

# Starts the Stage 0 reference build against the extracted Disc 1:
# .local/game/disc as game:\ and d:\.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$preset = 'win-amd64-' + $Configuration.ToLowerInvariant()
$exe = Join-Path $root "out/build/$preset/cobalt_shift.exe"
if (-not (Test-Path -LiteralPath $exe)) { throw "Build first: $exe" }
$disc = Join-Path $root '.local/game/disc'
if (-not (Test-Path -LiteralPath $disc)) { throw "Run tools/cobalt_setup.py disc first: $disc" }
if (-not $UserRoot) { $UserRoot = Join-Path $root '.local/user' }
$UserRoot = (New-Item -ItemType Directory -Force -Path $UserRoot).FullName
if (Get-Process -Name 'cobalt_shift' -ErrorAction SilentlyContinue) {
    throw 'cobalt_shift is already running.'
}
$arguments = @("--game_data_root=$disc", "--user_data_root=$UserRoot", '--gpu_backend=vulkan') +
    $GameArguments
$arguments = @($arguments | ForEach-Object {
    if ($_ -match '[\s"]') { '"' + ($_ -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"' } else { $_ }
})
Write-Host "$exe $($arguments -join ' ')"
$process = Start-Process -FilePath $exe -ArgumentList $arguments -WorkingDirectory (Split-Path $exe) -PassThru
if ($Wait) { $process.WaitForExit(); exit $process.ExitCode }
$process
