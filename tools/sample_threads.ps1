[CmdletBinding()]
param(
    [Parameter(Mandatory)][int]$ProcessId,
    # Thread description prefix to sample, e.g. 'GPU Commands' or 'Guest 822BDE68'.
    [Parameter(Mandatory)][string]$Thread,
    [double]$Seconds = 10,
    [int]$Top = 40,
    # Folders holding <module>.map files from the linker (/MAP).
    [string[]]$MapDirs = @()
)

# A poor man's sampling profiler for Windows: suspends one thread of the game
# about a thousand times a second, reads its instruction pointer, resumes it,
# then names each sample's function from the linker map of the module it
# falls in (no debug info needed). Prints the functions by share of samples.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $MapDirs) {
    $MapDirs = @((Join-Path $root 'out/build/win-amd64-release'),
                 (Join-Path $root 'thirdparty/shiftglue-sdk/out/win-amd64'))
}
& (Join-Path $PSScriptRoot 'thread_cpu.ps1') -ProcessId $ProcessId | Out-Null   # loads CobaltThreads
if (-not ('CobaltSampler' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading;
public static class CobaltSampler {
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenThread(uint a, bool i, uint id);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll")] static extern uint SuspendThread(IntPtr h);
    [DllImport("kernel32.dll")] static extern uint ResumeThread(IntPtr h);
    [DllImport("kernel32.dll")] static extern bool GetThreadContext(IntPtr h, IntPtr ctx);
    [DllImport("winmm.dll")] static extern uint timeBeginPeriod(uint p);
    [DllImport("winmm.dll")] static extern uint timeEndPeriod(uint p);
    public static ulong[] Sample(uint tid, int milliseconds) {
        IntPtr h = OpenThread(0x0002 | 0x0008 | 0x0040, false, tid); // SUSPEND_RESUME | GET_CONTEXT | QUERY_INFORMATION
        if (h == IntPtr.Zero) throw new Exception("OpenThread failed: " + Marshal.GetLastWin32Error());
        // CONTEXT is 1232 bytes and must be 16-byte aligned; Rip is at 0xF8.
        IntPtr raw = Marshal.AllocHGlobal(1232 + 16);
        IntPtr ctx = new IntPtr((raw.ToInt64() + 15) & ~15L);
        var samples = new List<ulong>();
        timeBeginPeriod(1);
        try {
            var end = DateTime.UtcNow.AddMilliseconds(milliseconds);
            while (DateTime.UtcNow < end) {
                if (SuspendThread(h) != 0xFFFFFFFF) {
                    Marshal.WriteInt32(ctx, 0x30, 0x100001); // ContextFlags = CONTEXT_CONTROL
                    if (GetThreadContext(h, ctx)) samples.Add((ulong)Marshal.ReadInt64(ctx, 0xF8));
                    ResumeThread(h);
                }
                Thread.Sleep(1);
            }
        } finally { timeEndPeriod(1); Marshal.FreeHGlobal(raw); CloseHandle(h); }
        return samples.ToArray();
    }
}
'@
}

$process = Get-Process -Id $ProcessId
$target = $process.Threads | Where-Object { ([CobaltThreads]::Name([uint32]$_.Id) -as [string]) -like "$Thread*" } |
    Select-Object -First 1
if (-not $target) { throw "No thread named '$Thread*' in process $ProcessId" }
$samples = [CobaltSampler]::Sample([uint32]$target.Id, [int]($Seconds * 1000))

# Module ranges, and each module's map (sorted RVAs and names) when one exists.
$modules = foreach ($m in $process.Modules) {
    $map = $null
    foreach ($dir in $MapDirs) {
        $path = Join-Path $dir ([IO.Path]::GetFileNameWithoutExtension($m.ModuleName) + '.map')
        if (Test-Path -LiteralPath $path) { $map = $path; break }
    }
    [pscustomobject]@{ Name = $m.ModuleName; Base = [uint64]$m.BaseAddress.ToInt64();
                       End = [uint64]$m.BaseAddress.ToInt64() + [uint64]$m.ModuleMemorySize; Map = $map; Rvas = $null; Syms = $null }
}
function Load-Map($module) {
    $preferred = 0
    $entries = New-Object 'System.Collections.Generic.List[object]'
    foreach ($line in [IO.File]::ReadLines($module.Map)) {
        if ($line -match 'Preferred load address is ([0-9a-fA-F]+)') { $preferred = [Convert]::ToUInt64($Matches[1], 16); continue }
        if ($line -match '^\s*0001:[0-9a-fA-F]{8}\s+(\S+)\s+([0-9a-fA-F]{16})\s') {
            $entries.Add([pscustomobject]@{ Rva = [Convert]::ToUInt64($Matches[2], 16) - $preferred; Name = $Matches[1] })
        }
    }
    $sorted = $entries | Sort-Object Rva
    $module.Rvas = [uint64[]]@($sorted | ForEach-Object Rva)
    $module.Syms = [string[]]@($sorted | ForEach-Object Name)
}

$counts = @{}
foreach ($ip in $samples) {
    $module = $modules | Where-Object { $ip -ge $_.Base -and $ip -lt $_.End } | Select-Object -First 1
    $name = '?'
    if ($module) {
        $name = $module.Name
        if ($module.Map) {
            if ($null -eq $module.Rvas) { Load-Map $module }
            $rva = $ip - $module.Base
            $i = [Array]::BinarySearch($module.Rvas, $rva)
            if ($i -lt 0) { $i = (-bnot $i) - 1 }
            if ($i -ge 0) { $name = "$($module.Name)!$($module.Syms[$i])" }
        }
    }
    $counts[$name] = 1 + [int]$counts[$name]
}
$undname = Join-Path $root '.local/toolchain/llvm-20.1.8/bin/llvm-undname.exe'
"thread '$Thread*' (tid $($target.Id)): $($samples.Count) samples over $Seconds s"
$counts.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First $Top | ForEach-Object {
    $label = $_.Key
    if ($label -match '^(.*?)!(\?.*)$' -and (Test-Path $undname)) {
        $plain = (& $undname --no-calling-convention --no-access-specifier --no-return-type --no-member-type --no-variable-type $Matches[2] 2>$null | Select-Object -Last 1)
        if ($plain) { $label = "$($Matches[1])!$plain" }
    }
    if ($label.Length -gt 150) { $label = $label.Substring(0, 150) }
    '{0,6:P1}  {1}' -f ($_.Value / $samples.Count), $label
}
