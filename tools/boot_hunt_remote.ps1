# Cobalt Shift: boot the game repeatedly on a LAN benchmark host (blindvac) to
# catch an intermittent startup fault.
#
# Each run restores the season seed with a cold shader cache, starts the game
# with --cobalt_low_end=true and -Extra, walks the title screens to the career
# hub with the scripted pad, and checks at about 135 s whether it is still
# running. A run that leaves a crash-*.dmp (in the user folder, or next to
# the executable for a fault before that folder is known) stops the loop and
# copies the dump and log to .local\dumps.
#
#   pwsh -File tools/boot_hunt_remote.ps1 -Runs 12 -Extra '--vulkan_device=0'
param([int]$Runs = 12, [string]$Extra = '', [string]$Tag = 'hunt')
$ErrorActionPreference = 'Continue'
function Remote([string]$s) {
    $e = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($s))
    & ssh -o BatchMode=yes blindvac "powershell -NoProfile -NonInteractive -EncodedCommand $e" 2>$null | Where-Object { $_ -notmatch '^#< CLIXML|^<Objs' }
}
$user = 'C:\cobalt\user-hunt'
$out = 'C:\Users\neri\code\cobalt-shift\.local\dumps'
New-Item -ItemType Directory -Force $out | Out-Null
$prefix = (@('A 200', 'wait 25000') + @(1..8 | ForEach-Object { 'A 200'; 'wait 9000' }) + @('START 200', 'wait 5000', 'A 200')) -join "','"
$args2 = @('--log_file=C:\cobalt\logs\hunt.log', '--cobalt_low_end=true') + @($Extra -split ' ' | Where-Object { $_ })
for ($r = 1; $r -le $Runs; $r++) {
    Remote @"
if (Get-Process cobalt_shift -ErrorAction SilentlyContinue) { Stop-Process -Name cobalt_shift; Start-Sleep 3 }
Remove-Item C:\cobalt\logs\hunt.log -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force $user -ErrorAction SilentlyContinue
Copy-Item -Recurse C:\cobalt\seeds\after-first-race $user
Remove-Item -Recurse -Force $user\cache -ErrorAction SilentlyContinue
Set-Content C:\cobalt\user_root.txt $user
Set-Content -LiteralPath C:\cobalt\args.txt -Value @('$($args2 -join "','")')
"@ | Out-Null
    $t0 = Get-Date
    $holder = Start-Process -FilePath ssh -WindowStyle Hidden -PassThru -ArgumentList @('-o', 'BatchMode=yes', 'blindvac',
        'powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File C:\cobalt\launch.ps1 -Wait')
    Start-Sleep 60
    Remote "Set-Content -LiteralPath $user\pad.txt -Value @('$prefix')" | Out-Null
    $died = $null
    while (((Get-Date) - $t0).TotalSeconds -lt 135) {
        Start-Sleep 5
        if ($holder.HasExited) { $died = [int]((Get-Date) - $t0).TotalSeconds; break }
    }
    Remote 'Stop-Process -Name cobalt_shift -ErrorAction SilentlyContinue' | Out-Null
    Start-Sleep 3
    Stop-Process -Id $holder.Id -ErrorAction SilentlyContinue
    $dumps = @(Remote "Get-ChildItem $user\crash-*.dmp, C:\cobalt\bin\crash-*.dmp -ErrorAction SilentlyContinue | ForEach-Object FullName")
    $status = if ($died) { "exited at ${died}s" } else { 'alive' }
    "$Tag run ${r}: $status dumps: $($dumps -join ' ')"
    foreach ($d in $dumps) {
        $leaf = Split-Path -Leaf $d
        & scp -q -o BatchMode=yes "blindvac:$($d -replace '\\', '/')" "$out\$leaf"
        & scp -q -o BatchMode=yes 'blindvac:C:/cobalt/logs/hunt.log' "$out\$leaf.log"
        Remote "Remove-Item -LiteralPath '$d'" | Out-Null
    }
    if ($dumps) { break }
}
