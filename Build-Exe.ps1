# Build WatchDog.exe: a tiny launcher that opens MemMonitor.ps1 without a console window.
# Uses the C# compiler that ships with Windows (.NET Framework 4), so nothing is downloaded.
# The exe must stay in this folder, next to MemMonitor.ps1.
Add-Type -AssemblyName System.Drawing
$dir = $PSScriptRoot
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
if (-not (Test-Path $csc)) { Write-Host 'csc.exe (.NET Framework 4) not found'; exit 1 }

# ---- Icon: red-black tile, coral cut-corner frame, neon cyan "W" (PNG images packed into an .ico) ----
function New-IconPng([int]$s) {
    $bmp = New-Object Drawing.Bitmap($s, $s)
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAliasGridFit'
    $c = [single]($s * 0.22); $m = [single]([math]::Max(1, $s * 0.04))
    $pts = [Drawing.PointF[]]@(
        (New-Object Drawing.PointF($m, $m)), (New-Object Drawing.PointF(($s - $m - $c), $m)),
        (New-Object Drawing.PointF(($s - $m), ($m + $c))), (New-Object Drawing.PointF(($s - $m), ($s - $m))),
        (New-Object Drawing.PointF(($m + $c / 2), ($s - $m))), (New-Object Drawing.PointF($m, ($s - $m - $c / 2))))
    $bg = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(32, 13, 17))
    $pen = New-Object Drawing.Pen([Drawing.Color]::FromArgb(255, 95, 87), [single]([math]::Max(1, $s * 0.05)))
    $cyan = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(94, 246, 255))
    $red = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(255, 40, 60))
    $font = New-Object Drawing.Font('Bahnschrift SemiBold', [single]($s * 0.52), [Drawing.FontStyle]::Bold, [Drawing.GraphicsUnit]::Pixel)
    $fmt = New-Object Drawing.StringFormat; $fmt.Alignment = 'Center'; $fmt.LineAlignment = 'Center'
    try {
        $g.FillPolygon($bg, $pts); $g.DrawPolygon($pen, $pts)
        $g.DrawString('W', $font, $cyan, (New-Object Drawing.RectangleF(0, [single]($s * 0.02), $s, $s)), $fmt)
        if ($s -ge 32) { $d = [single]($s * 0.12); $g.FillRectangle($red, [single]($s * 0.14), [single]($s * 0.14), $d, $d) }
        $ms = New-Object IO.MemoryStream
        $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png)
        , $ms.ToArray()
    } finally { $g.Dispose(); $bmp.Dispose(); $bg.Dispose(); $pen.Dispose(); $cyan.Dispose(); $red.Dispose(); $font.Dispose(); $fmt.Dispose() }
}
$sizes = 256, 48, 32, 16
$pngs = @(foreach ($s in $sizes) { , (New-IconPng $s) })
$ico = Join-Path $dir 'WatchDog.ico'
$fs = [IO.File]::Create($ico); $bw = New-Object IO.BinaryWriter($fs)
try {
    $bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$sizes.Count)
    $offset = 6 + 16 * $sizes.Count
    for ($i = 0; $i -lt $sizes.Count; $i++) {
        $s = $sizes[$i]; $b = if ($s -ge 256) { 0 } else { $s }
        $bw.Write([byte]$b); $bw.Write([byte]$b); $bw.Write([byte]0); $bw.Write([byte]0)
        $bw.Write([uint16]1); $bw.Write([uint16]32); $bw.Write([uint32]$pngs[$i].Length); $bw.Write([uint32]$offset)
        $offset += $pngs[$i].Length
    }
    foreach ($p in $pngs) { $bw.Write($p) }
} finally { $bw.Close() }

# ---- Launcher source (saved as UTF-8 with BOM so csc reads the Chinese message correctly) ----
$src = Join-Path $env:TEMP 'WatchDogLauncher.cs'
@'
using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;
class WatchDogLauncher {
    [STAThread]
    static void Main() {
        string dir = AppDomain.CurrentDomain.BaseDirectory;
        string ps1 = Path.Combine(dir, "MemMonitor.ps1");
        if (!File.Exists(ps1)) {
            MessageBox.Show("找不到 MemMonitor.ps1。请把 WatchDog.exe 放在工具文件夹里。", "WATCHDOG");
            return;
        }
        ProcessStartInfo psi = new ProcessStartInfo("powershell.exe",
            "-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File \"" + ps1 + "\"");
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.WorkingDirectory = dir;
        Process.Start(psi);
    }
}
'@ | Set-Content $src -Encoding UTF8

$exe = Join-Path $dir 'WatchDog.exe'
& $csc /nologo /target:winexe /optimize+ "/win32icon:$ico" "/out:$exe" /reference:System.Windows.Forms.dll $src
Remove-Item $src -ErrorAction SilentlyContinue
if (Test-Path $exe) { Write-Host "Built: $exe" } else { Write-Host 'Build failed'; exit 1 }
