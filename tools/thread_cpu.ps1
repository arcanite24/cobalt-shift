[CmdletBinding()]
param(
    [Parameter(Mandatory)][int]$ProcessId,
    # A snapshot from an earlier call: print the CPU each thread name used since.
    $Since = $null,
    [int]$Top = 15
)

# Per-thread CPU time of a process, keyed by thread name (GetThreadDescription;
# unnamed threads by id). Without -Since it returns a snapshot; with it, a table
# of cores busy per thread name over the interval.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not ('CobaltThreads' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class CobaltThreads {
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr OpenThread(uint access, bool inherit, uint id);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll")] static extern int GetThreadDescription(IntPtr h, out IntPtr desc);
    [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr p);
    [DllImport("kernel32.dll")] static extern bool GetThreadTimes(IntPtr h, out long c, out long e, out long k, out long u);
    public static string Name(uint id) {
        IntPtr h = OpenThread(0x0800 /* THREAD_QUERY_LIMITED_INFORMATION */, false, id);
        if (h == IntPtr.Zero) return null;
        try {
            IntPtr p;
            if (GetThreadDescription(h, out p) < 0) return null;
            string s = Marshal.PtrToStringUni(p);
            LocalFree(p);
            return s;
        } finally { CloseHandle(h); }
    }
    // Kernel + user time in 100 ns units, or -1.
    public static long Cpu(uint id) {
        IntPtr h = OpenThread(0x0800, false, id);
        if (h == IntPtr.Zero) return -1;
        try {
            long c, e, k, u;
            return GetThreadTimes(h, out c, out e, out k, out u) ? k + u : -1;
        } finally { CloseHandle(h); }
    }
}
'@
}

$snapshot = @{ time = [Diagnostics.Stopwatch]::GetTimestamp(); threads = @{} }
foreach ($thread in (Get-Process -Id $ProcessId).Threads) {
    $id = [uint32]$thread.Id
    $cpu = [CobaltThreads]::Cpu($id)
    if ($cpu -lt 0) { continue }
    $name = [CobaltThreads]::Name($id)
    if (-not $name) { $name = "tid $id" }
    $snapshot.threads[$id] = @{ name = $name; cpu = $cpu }
}
if (-not $Since) { return $snapshot }

$seconds = ($snapshot.time - $Since.time) / [Diagnostics.Stopwatch]::Frequency
$byName = @{}
foreach ($id in $snapshot.threads.Keys) {
    $now = $snapshot.threads[$id]
    $before = if ($Since.threads.ContainsKey($id)) { $Since.threads[$id].cpu } else { 0 }
    $byName[$now.name] = [double]($byName[$now.name]) + ($now.cpu - $before) / 1e7
}
$byName.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First $Top | ForEach-Object {
    '{0,-40} {1,6:N3} cores' -f $_.Key, ($_.Value / $seconds)
}
