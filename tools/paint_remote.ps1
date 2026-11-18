# Cobalt Shift: check the paint editor on a LAN benchmark host (blindvac).
#
# Boots the season seed (C:\cobalt\seeds\after-first-race), reaches the
# career hub, opens PAINT > APPLY DECALS, dismisses the design tips, and saves
# to the current car, then stops the game, fetches its log to
# .local\logs\remote-blindvac-decal.log and prints the readback lines
# (docs/BASELINE.md, "Liveries and car pictures read back"). It drives the
# menus blind: one press per pad file about a second apart, LB first to wake
# a menu that has hidden. The timings are blindvac's (slower loads).
$ErrorActionPreference = 'Stop'
function Remote([string]$s) {
    $e = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($s))
    & ssh -o BatchMode=yes blindvac "powershell -NoProfile -NonInteractive -EncodedCommand $e" 2>$null | Where-Object { $_ -notmatch '^#< CLIXML|^<Objs' }
}
$user = 'C:\cobalt\user-decal'
Remote @"
if (Get-Process cobalt_shift -ErrorAction SilentlyContinue) { throw 'running' }
Remove-Item C:\cobalt\logs\decal.log -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force $user -ErrorAction SilentlyContinue
Copy-Item -Recurse C:\cobalt\seeds\after-first-race $user
Set-Content C:\cobalt\user_root.txt $user
Set-Content -LiteralPath C:\cobalt\args.txt -Value @('--log_file=C:\cobalt\logs\decal.log','--vulkan_device=0')
"@
$holder = Start-Process -FilePath ssh -WindowStyle Hidden -PassThru -ArgumentList @('-o', 'BatchMode=yes', 'blindvac',
    'powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File C:\cobalt\launch.ps1 -Wait')
Start-Sleep 60
$prefix = (@('A 200', 'wait 25000') + @(1..8 | ForEach-Object { 'A 200'; 'wait 9000' }) + @('START 200', 'wait 5000', 'A 200')) -join "','"
Remote "Set-Content -LiteralPath $user\pad.txt -Value @('$prefix')"
Start-Sleep 150
Remote @"
function Pad(`$k, `$s) { Set-Content -LiteralPath $user\pad.txt -Value "`$k 140"; Start-Sleep -Milliseconds `$s }
foreach (`$k in 'LB','DOWN','DOWN','DOWN') { Pad `$k 1000 }
Pad 'A' 8000
foreach (`$k in 'LB','DOWN') { Pad `$k 1000 }
Pad 'A' 40000
Pad 'A' 4000
Pad 'START' 5000
Pad 'A' 30000
"@
$alive = Remote '[bool](Get-Process cobalt_shift -ErrorAction SilentlyContinue)'
"game alive at the end: $alive"
Remote 'Stop-Process -Name cobalt_shift -ErrorAction SilentlyContinue; Wait-Process -Name cobalt_shift -Timeout 30 -ErrorAction SilentlyContinue' | Out-Null
Stop-Process -Id $holder.Id -ErrorAction SilentlyContinue
& scp -q -o BatchMode=yes 'blindvac:C:/cobalt/logs/decal.log' 'C:\Users\neri\code\cobalt-shift\.local\logs\remote-blindvac-decal.log' 2>$null
Remote 'Get-WinEvent -FilterHashtable @{LogName="Application"; StartTime=(Get-Date).AddMinutes(-8)} -ErrorAction SilentlyContinue | Where-Object { $_.Message -match "cobalt_shift" } | ForEach-Object { $_.TimeCreated.ToString() + " " + ($_.Message -split "`n")[0..4] -join " | " }'
Select-String -Path 'C:\Users\neri\code\cobalt-shift\.local\logs\remote-blindvac-decal.log' -Pattern 'large resolve destination: \w+ 2048x2048|read back with what|rendered again|resolve read back:' | ForEach-Object { $_.Line.Substring(12, [Math]::Min(150, $_.Line.Length - 12)) }
