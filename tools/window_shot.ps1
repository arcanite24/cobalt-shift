[CmdletBinding()]
param(
    [Parameter(Mandatory)] [int]$ProcessId,
    [Parameter(Mandatory)] [string]$Path
)

# Saves the main window of a process as a PNG (PrintWindow with full-content
# rendering, so it works when the window is covered), at most 1280 wide.
# The thread is made per-monitor DPI aware first: unaware, a scaled display
# (multivac's 4K at 125 %) reports a client rect 1/1.25 the real size and the
# shot holds only the window's top-left 80 %, which looked like a 1.25x UI.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
if (-not ('CobaltWindowShot2' -as [type])) {
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class CobaltWindowShot2 {
    [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr c);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
}
'@
}
$process = Get-Process -Id $ProcessId
$handle = $process.MainWindowHandle
if ($handle -eq [IntPtr]::Zero) { throw "process $ProcessId has no main window" }
# -4: DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2
[void][CobaltWindowShot2]::SetThreadDpiAwarenessContext([IntPtr]::new(-4))
$rect = New-Object CobaltWindowShot2+RECT
[void][CobaltWindowShot2]::GetClientRect($handle, [ref]$rect)
$width = [Math]::Max(1, $rect.R - $rect.L); $height = [Math]::Max(1, $rect.B - $rect.T)
$bitmap = New-Object System.Drawing.Bitmap $width, $height
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
$dc = $graphics.GetHdc()
# 1 = client area only, 2 = PW_RENDERFULLCONTENT
[void][CobaltWindowShot2]::PrintWindow($handle, $dc, 3)
$graphics.ReleaseHdc($dc)
$scale = [Math]::Min(1.0, 1280.0 / $width)
$out = New-Object System.Drawing.Bitmap $bitmap, ([int]($width * $scale)), ([int]($height * $scale))
$out.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
$graphics.Dispose(); $bitmap.Dispose(); $out.Dispose()
"screenshot: $Path ($width x $height)"
