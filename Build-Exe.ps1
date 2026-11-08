# Build WatchDog.exe: the monitor window, written in C# (src\*.cs).
# Uses the C# compiler that ships with Windows (.NET Framework 4), so nothing is downloaded.
# The exe must stay in this folder: it reads rules.json / rules.local.json / data\ here,
# and runs the PowerShell helper scripts (watchdog, fixes) from here.
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

# ---- Manifest: modern controls, sharp text on high-DPI screens, Windows 10/11 ----
$manifest = Join-Path $env:TEMP 'WatchDog.manifest'
@'
<?xml version="1.0" encoding="utf-8"?>
<assembly manifestVersion="1.0" xmlns="urn:schemas-microsoft-com:asm.v1">
  <assemblyIdentity version="1.0.0.0" name="WatchDog"/>
  <trustInfo xmlns="urn:schemas-microsoft-com:asm.v2"><security><requestedPrivileges xmlns="urn:schemas-microsoft-com:asm.v3">
    <requestedExecutionLevel level="asInvoker" uiAccess="false"/>
  </requestedPrivileges></security></trustInfo>
  <compatibility xmlns="urn:schemas-microsoft-com:compatibility.v1"><application>
    <supportedOS Id="{8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a}"/>
  </application></compatibility>
  <application xmlns="urn:schemas-microsoft-com:asm.v3"><windowsSettings>
    <dpiAware xmlns="http://schemas.microsoft.com/SMI/2005/WindowsSettings">true</dpiAware>
  </windowsSettings></application>
</assembly>
'@ | Set-Content $manifest -Encoding UTF8

$exe = Join-Path $dir 'WatchDog.exe'
$src = @(Get-ChildItem (Join-Path $dir 'src') -Filter '*.cs' | ForEach-Object { $_.FullName })
if (-not $src) { Write-Host 'src\*.cs not found'; exit 1 }
# The monitor may be running (it hides in the tray): close it first, the exe file is locked while it runs
$running = @(Get-Process WatchDog -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe })
$wasRunning = $running.Count -gt 0
if ($wasRunning) {
    # Ask it to save its live data and exit (WatchDog.exe --exit), then wait for it
    Start-Process $exe -ArgumentList '--exit' -Wait
    foreach ($p in $running) { $p.WaitForExit(5000) | Out-Null }
    if (@(Get-Process WatchDog -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe })) { Write-Host 'WatchDog is still running - exit it from the tray icon first (right-click -> 退出).'; exit 1 }
}
& $csc /nologo /target:winexe /optimize+ /codepage:65001 "/win32icon:$ico" "/win32manifest:$manifest" "/out:$exe" `
    /reference:System.Windows.Forms.dll /reference:System.Drawing.dll /reference:System.Core.dll `
    /reference:System.Web.Extensions.dll /reference:Microsoft.VisualBasic.dll $src
$ok = $LASTEXITCODE -eq 0
Remove-Item $manifest -ErrorAction SilentlyContinue
if ($ok -and (Test-Path $exe)) { Write-Host "Built: $exe" } else { Write-Host 'Build failed'; exit 1 }
if ($wasRunning) { Start-Process $exe }   # it was running before: start the new version
