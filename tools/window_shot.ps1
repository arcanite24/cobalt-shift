[CmdletBinding()]
param(
    [Parameter(Mandatory)] [int]$ProcessId,
    [Parameter(Mandatory)] [string]$Path
)

# Saves the main window of a process as a PNG (PrintWindow with full-content
# rendering, so it works when the window is covered), at most 1280 wide.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
if (-not ('CobaltWindowShot' -as [type])) {
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class CobaltWindowShot {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
}
'@
}
$process = Get-Process -Id $ProcessId
$handle = $process.MainWindowHandle
if ($handle -eq [IntPtr]::Zero) { throw "process $ProcessId has no main window" }
$rect = New-Object CobaltWindowShot+RECT
[void][CobaltWindowShot]::GetClientRect($handle, [ref]$rect)
$width = [Math]::Max(1, $rect.R - $rect.L); $height = [Math]::Max(1, $rect.B - $rect.T)
$bitmap = New-Object System.Drawing.Bitmap $width, $height
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
$dc = $graphics.GetHdc()
# 1 = client area only, 2 = PW_RENDERFULLCONTENT
[void][CobaltWindowShot]::PrintWindow($handle, $dc, 3)
$graphics.ReleaseHdc($dc)
$scale = [Math]::Min(1.0, 1280.0 / $width)
$out = New-Object System.Drawing.Bitmap $bitmap, ([int]($width * $scale)), ([int]($height * $scale))
$out.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
$graphics.Dispose(); $bitmap.Dispose(); $out.Dispose()
"screenshot: $Path ($width x $height)"
