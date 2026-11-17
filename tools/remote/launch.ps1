# Cobalt Shift on a LAN benchmark host (blindvac): C:\cobalt\launch.ps1.
# Copied there by hand; tools/bench_remote.ps1 drives it.
#
# Starts the game with the cvars in C:\cobalt\args.txt: from the CobaltBench
# scheduled task (interactive session), or over SSH with -Wait (session 0,
# where the connection must stay open for the game to live). The user data
# folder is C:\cobalt\user, or the one named in C:\cobalt\user_root.txt
# (bench_remote.ps1 -Route season restores a seed profile there).
param([switch]$Wait)
$user = 'C:\cobalt\user'
if (Test-Path -LiteralPath 'C:\cobalt\user_root.txt') {
    $named = (Get-Content -LiteralPath 'C:\cobalt\user_root.txt' -TotalCount 1).Trim()
    if ($named) { $user = $named }
}
$arguments = @('--game_data_root=C:\cobalt\game\disc', "--user_data_root=$user",
    '--gpu_backend=vulkan', "--pad_script_file=$user\pad.txt") +
    @(Get-Content -LiteralPath 'C:\cobalt\args.txt' -ErrorAction SilentlyContinue | Where-Object { $_ })
$process = Start-Process -FilePath 'C:\cobalt\bin\cobalt_shift.exe' -ArgumentList $arguments -WorkingDirectory 'C:\cobalt\bin' -PassThru
if ($Wait) { $process.WaitForExit() }
