# MemMonitor：内存 / CPU 监控面板（赛博朋克风格界面：红黑底 + 荧光蓝）
# 只在打开时运行，关掉窗口就完全退出。每 5 秒刷新一次，只保留最新一份数据，不会越用越大。
# 所有画笔 / 画刷 / 字体只在启动时创建一次，绘制时反复使用，避免 GDI 资源泄漏。
# 历史数据来自看门狗（MemWatchdog.ps1，每 10 分钟记录一次），用来判断是否有程序在持续泄漏内存。
#   -SelfTest -Loops N [-Snapshot x.png] : 不显示窗口，连续刷新并重绘 N 次，打印结果、自身内存和 GDI 句柄数
param(
    [string]$DataDir = (Join-Path $PSScriptRoot 'data'),
    [switch]$SelfTest,
    [int]$Loops = 1,
    [string]$Snapshot,
    [string]$Select      # 启动时默认选中的程序（曲线图显示它）
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;
public static class NativeInfo {
    [StructLayout(LayoutKind.Sequential)]
    public struct MEMSTAT {
        public uint dwLength; public uint dwMemoryLoad;
        public ulong ullTotalPhys; public ulong ullAvailPhys;
        public ulong ullTotalPageFile; public ulong ullAvailPageFile;
        public ulong ullTotalVirtual; public ulong ullAvailVirtual; public ulong ullAvailExtendedVirtual;
    }
    [DllImport("kernel32.dll")] static extern bool GlobalMemoryStatusEx(ref MEMSTAT m);
    [DllImport("kernel32.dll")] static extern bool GetSystemTimes(out long idle, out long kernel, out long user);
    [DllImport("user32.dll")] public static extern uint GetGuiResources(IntPtr h, uint flags);
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr h, int attr, ref int val, int size);
    [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)] public static extern int SetWindowTheme(IntPtr h, string app, string id);
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, int msg, IntPtr w, IntPtr l);
    public static MEMSTAT Mem() { MEMSTAT m = new MEMSTAT(); m.dwLength = (uint)Marshal.SizeOf(m); GlobalMemoryStatusEx(ref m); return m; }
    static long pIdle, pTotal;
    public static double Cpu() {
        long i, k, u; GetSystemTimes(out i, out k, out u);
        long t = k + u; double r = 0;
        if (pTotal > 0 && t - pTotal > 0) r = 100.0 * (1.0 - (double)(i - pIdle) / (t - pTotal));
        pIdle = i; pTotal = t;
        return Math.Max(0, Math.Min(100, r));
    }
    public static void Dwm(IntPtr h, int attr, int val) { try { DwmSetWindowAttribute(h, attr, ref val, 4); } catch { } }
}
public class BufferedPanel : Panel {
    public BufferedPanel() { DoubleBuffered = true; ResizeRedraw = true; }
}
public class BufferedListView : ListView {
    public BufferedListView() { DoubleBuffered = true; }
}
"@

$LogFile = Join-Path (Split-Path $DataDir) 'MemWatchdog.log'
$NvDb    = 'C:\ProgramData\NVIDIA Corporation\nvtopps\nvtopps.db3'
$WatchedServices = @('Audiosrv', 'LightingService', 'NVDisplay.ContainerLocalSystem')

# 常见程序的中文说明
$Desc = @{
    'NVDisplay.Container' = 'NVIDIA 显示驱动容器'; 'nvcontainer' = 'NVIDIA App 后台（即时重放等）'
    'NVIDIA Overlay' = 'NVIDIA 覆盖层（Alt+Z）'; 'svchost' = 'Windows 系统服务（多个合计）'
    'svc:Audiosrv' = 'Windows 音频服务'; 'svc:LightingService' = '华硕 Aura 灯效服务'
    'svc:NVDisplay.ContainerLocalSystem' = 'NVIDIA 显示驱动容器（服务）'
    'lghub_system_tray' = '罗技 G HUB 托盘'; 'lghub_agent' = '罗技 G HUB 后台（管设备）'; 'lghub' = '罗技 G HUB 主窗口'
    'steamwebhelper' = 'Steam 内置浏览器'; 'steam' = 'Steam'; 'Weixin' = '微信'; 'WeChatAppEx' = '微信小程序 / 文章'
    'claude' = 'Claude'; 'vivaldi' = 'Vivaldi 浏览器'; 'msedge' = 'Edge 浏览器'; 'chrome' = 'Chrome 浏览器'
    'msedgewebview2' = '其他软件内嵌的网页'; 'MsMpEng' = 'Windows Defender 杀毒'; 'dwm' = '桌面窗口管理器'
    'explorer' = '资源管理器 / 任务栏'; 'BongoCat' = 'BongoCat 桌宠'; 'HueSync' = 'Philips Hue 灯光同步'
    'LightingService' = '华硕 Aura 灯效'; 'RazerAppEngine' = '雷蛇 Synapse'; 'iCUE' = '海盗船 iCUE'
    'Corsair.Service' = '海盗船后台服务'; 'Discord' = 'Discord'; 'wallpaper32' = 'Wallpaper Engine 壁纸'
    'wallpaperui' = 'Wallpaper Engine 界面'; 'lw' = 'Live2DViewerEX'; 'SAO Utils' = 'SAO Utils 桌面'
    'StreamDeck' = 'Stream Deck'; 'QQ' = 'QQ'; 'QQMusic' = 'QQ 音乐'; 'qmbrowser' = 'QQ 音乐内置浏览器'
    'ArmouryCrate' = '华硕奥创中心'; 'ROGLiveService' = 'ROG Live 服务'; 'audiodg' = 'Windows 音频引擎'
    'powershell' = 'PowerShell（含本监控窗口）'; 'MemCompression' = 'Windows 内存压缩（正常）'
}

# 判断标准
$LeakSlopeMBh = 50     # 每小时至少涨 50 MB
$LeakGrowthMB = 300    # 累计至少涨 300 MB
$LeakR2       = 0.6    # 涨势要稳定（不是忽高忽低）
$BigMB        = 1500   # 超过这个算"占用较大"

# ---------- 状态（每次刷新都整体替换，不累积） ----------
$script:prevCpu   = @{}
$script:prevTime  = $null
$script:denied    = @{}
$script:cpuHist   = New-Object 'System.Collections.Generic.Queue[double]'
$script:hist      = @{}
$script:analysis  = @{}
$script:sys       = @()
$script:histSig   = ''
$script:lastSlow  = [datetime]::MinValue
$script:svcPid    = @{}
$script:taskState = $null
$script:lastAction = ''
$script:nvMB      = 0
$script:selected  = if ($Select) { $Select } else { $null }
$script:updating  = $false
$script:tick      = 0
$script:selfMB    = 0
$script:selfGdi   = 0
$script:leakLines = @()

# ---------- 数据 ----------
function Analyze($pts) {
    $n = $pts.Count
    if ($n -lt 6) { return $null }
    # 只看最近一次重启（内存骤降或断档超过 1 小时）之后的数据
    $start = 0
    for ($i = 1; $i -lt $n; $i++) {
        if ($pts[$i].MB -lt 0.6 * $pts[$i - 1].MB -or ($pts[$i].T - $pts[$i - 1].T).TotalMinutes -gt 60) { $start = $i }
    }
    $m = $n - $start
    if ($m -lt 6) { return $null }
    $t0 = $pts[$start].T
    $span = ($pts[$n - 1].T - $t0).TotalHours
    if ($span -lt 2) { return $null }
    $sx = 0.0; $sy = 0.0; $sxx = 0.0; $sxy = 0.0; $syy = 0.0
    for ($i = $start; $i -lt $n; $i++) {
        $x = ($pts[$i].T - $t0).TotalHours; $y = $pts[$i].MB
        $sx += $x; $sy += $y; $sxx += $x * $x; $sxy += $x * $y; $syy += $y * $y
    }
    $den = $m * $sxx - $sx * $sx
    if ($den -le 0) { return $null }
    $num = $m * $sxy - $sx * $sy
    $vy = $m * $syy - $sy * $sy
    $r2 = if ($vy -gt 0) { ($num * $num) / ($den * $vy) } else { 0 }
    [pscustomobject]@{ Slope = $num / $den; R2 = $r2; Growth = $pts[$n - 1].MB - $pts[$start].MB; Span = $span }
}

function Load-History {
    if (-not (Test-Path $DataDir)) { $script:hist = @{}; $script:analysis = @{}; $script:sys = @(); return }
    $pf = @(Get-ChildItem $DataDir -Filter 'proc-*.csv' | Sort-Object Name | Select-Object -Last 2)
    $sf = @(Get-ChildItem $DataDir -Filter 'sys-*.csv'  | Sort-Object Name | Select-Object -Last 2)
    $sig = (@($pf) + @($sf) | ForEach-Object { '{0}:{1}' -f $_.Name, $_.Length }) -join '|'
    if ($sig -eq $script:histSig) { return }   # 文件没变就不重读
    $script:histSig = $sig
    $cut = (Get-Date).AddHours(-24)
    $h = @{}
    foreach ($f in $pf) {
        foreach ($r in (Import-Csv $f.FullName)) {
            $t = [datetime]::ParseExact($r.Time, 'yyyy-MM-dd HH:mm:ss', $null)
            if ($t -lt $cut) { continue }
            if (-not $h.ContainsKey($r.Name)) { $h[$r.Name] = New-Object 'System.Collections.Generic.List[object]' }
            $h[$r.Name].Add([pscustomobject]@{ T = $t; MB = [double]$r.PrivMB })
        }
    }
    $a = @{}
    foreach ($k in $h.Keys) { $r = Analyze $h[$k]; if ($r) { $a[$k] = $r } }
    $script:hist = $h
    $script:analysis = $a
    $script:sys = @(foreach ($f in $sf) { Import-Csv $f.FullName })
}

function Update-Slow {
    # 每分钟一次：历史数据、服务进程号、计划任务状态、最近动作、NVIDIA 数据库大小
    Load-History
    $map = @{}
    $filter = ($WatchedServices | ForEach-Object { "Name='$_'" }) -join ' OR '
    foreach ($s in (Get-CimInstance Win32_Service -Filter $filter -ErrorAction SilentlyContinue)) { if ($s.ProcessId -gt 0) { $map[[int]$s.ProcessId] = "svc:$($s.Name)" } }
    $script:svcPid = $map
    $t = Get-ScheduledTask -TaskName 'MemWatchdog' -ErrorAction SilentlyContinue
    $script:taskState = if ($t) { [string]$t.State } else { $null }
    $script:lastAction = ''
    if (Test-Path $LogFile) {
        $hit = Get-Content $LogFile -Tail 200 -Encoding UTF8 | Where-Object { $_ -match 'RESTART|REBUILD|HIGH' } | Select-Object -Last 1
        if ($hit) { $script:lastAction = $hit }
    }
    $script:nvMB = if (Test-Path $NvDb) { [int]((Get-Item $NvDb).Length / 1MB) } else { 0 }
}

function Sample-Processes {
    $now = [DateTime]::UtcNow
    $elapsedMs = if ($script:prevTime) { ($now - $script:prevTime).TotalMilliseconds } else { 0 }
    $cores = [Environment]::ProcessorCount
    $cur = @{}; $newDenied = @{}; $byName = @{}
    foreach ($p in [System.Diagnostics.Process]::GetProcesses()) {
        try {
            $id = $p.Id
            $names = @($p.ProcessName)
            if ($script:svcPid.ContainsKey($id)) { $names += $script:svcPid[$id] }
            $priv = $p.PrivateMemorySize64 / 1MB
            $d = 0.0
            if (-not $script:denied.ContainsKey($id)) {
                try {
                    $ms = $p.TotalProcessorTime.TotalMilliseconds
                    $cur[$id] = $ms
                    if ($script:prevCpu.ContainsKey($id)) { $d = [math]::Max(0, $ms - $script:prevCpu[$id]) }
                } catch { $newDenied[$id] = 1 }
            } else { $newDenied[$id] = 1 }
            foreach ($nm in $names) {
                if (-not $byName.ContainsKey($nm)) { $byName[$nm] = [pscustomobject]@{ Name = $nm; PrivMB = 0.0; CpuMs = 0.0; Count = 0; CpuPct = 0.0 } }
                $e = $byName[$nm]; $e.PrivMB += $priv; $e.CpuMs += $d; $e.Count++
            }
        } catch {} finally { $p.Dispose() }
    }
    $script:prevCpu = $cur; $script:denied = $newDenied; $script:prevTime = $now
    foreach ($e in $byName.Values) { if ($elapsedMs -gt 0) { $e.CpuPct = [math]::Round(100 * $e.CpuMs / $elapsedMs / $cores, 1) } }
    return @($byName.Values)
}

function Get-Status($name, $mb) {
    $a = $script:analysis[$name]
    # 现在的占用比最后一条记录低很多 = 刚被重启过，泄漏已清掉
    if ($a -and $script:hist.ContainsKey($name)) {
        $lastMB = $script:hist[$name][$script:hist[$name].Count - 1].MB
        if ($mb -lt 0.6 * $lastMB) { $a = $null }
    }
    if ($a -and $a.Slope -ge $LeakSlopeMBh -and $a.Growth -ge $LeakGrowthMB -and $a.R2 -ge $LeakR2) {
        return @('疑似泄漏', ('近 {0:N1} 小时持续上涨 {1:N0} MB（约 {2:N0} MB/小时）' -f $a.Span, $a.Growth, $a.Slope))
    }
    if ($mb -ge $BigMB) { return @('占用较大', '偏大，但没有持续上涨') }
    return @('正常', '')
}

function Trend-Text($name) {
    $a = $script:analysis[$name]
    if (-not $a) { return '数据不足' }
    '{0:+#,0;-#,0;0} MB / {1:N1} 小时' -f $a.Growth, $a.Span
}

function Ago($t) {
    $m = [int]((Get-Date) - $t).TotalMinutes
    if ($m -lt 1) { '刚刚' } elseif ($m -lt 60) { "$m 分钟前" } elseif ($m -lt 1440) { '{0:N1} 小时前' -f ($m / 60) } else { '{0:N0} 天前' -f ($m / 1440) }
}

# ---------- 主题：颜色、字体、画笔（只创建一次） ----------
function RGB($r, $g, $b) { [Drawing.Color]::FromArgb($r, $g, $b) }
$cBg     = RGB 14 9 12      # 窗口底色：红黑
$cPanel  = RGB 32 13 17     # 面板底色：暗红
$cRowA   = RGB 19 10 13
$cRowB   = RGB 26 12 16
$cCyan   = RGB 94 246 255   # 荧光蓝：数值 / 正常
$cYellow = RGB 245 217 10   # 黄：警告
$cRed    = RGB 255 40 60    # 亮红：告警
$cAccent = RGB 255 95 87    # 珊瑚红：边框 / 标题
$cRedDim = RGB 92 30 33     # 暗红：网格 / 次要线条
$cText   = RGB 236 220 214
$cGray   = RGB 160 116 112
$cDim    = RGB 58 24 28
$LevelColor = @{ 0 = $cCyan; 1 = $cYellow; 2 = $cRed; -1 = $cGray }

$fCN    = New-Object Drawing.Font('Microsoft YaHei UI', 9)
$fCNb   = New-Object Drawing.Font('Microsoft YaHei UI', 9, [Drawing.FontStyle]::Bold)
$fCNbig = New-Object Drawing.Font('Microsoft YaHei UI', 11, [Drawing.FontStyle]::Bold)
$fTag   = New-Object Drawing.Font('Bahnschrift SemiCondensed', 9)
$fTagB  = New-Object Drawing.Font('Bahnschrift SemiBold SemiConden', 10)
$fNum   = New-Object Drawing.Font('Bahnschrift SemiBold', 22)
$fHead  = New-Object Drawing.Font('Bahnschrift SemiBold', 18)
$fSmall = New-Object Drawing.Font('Bahnschrift', 8.5)

$GDI = @{}   # 统一保存，关闭时一起释放
function Brush($name, $color) { $GDI[$name] = New-Object Drawing.SolidBrush($color) }
function Pen($name, $color, $w) { $GDI[$name] = New-Object Drawing.Pen($color, $w) }
Brush 'bg' $cBg; Brush 'panel' $cPanel; Brush 'rowA' $cRowA; Brush 'rowB' $cRowB; Brush 'dim' $cDim
Brush 'sel' (RGB 12 46 54); Brush 'leakRow' (RGB 78 14 22); Brush 'warnRow' (RGB 48 40 8)
Brush 'acc' $cAccent; Pen 'accPen' $cAccent 1; Pen 'accDim' $cRedDim 1
Pen 'scan' ([Drawing.Color]::FromArgb(12, 255, 90, 80)) 1
Pen 'grid' ([Drawing.Color]::FromArgb(150, 92, 30, 33)) 1
Pen 'line' $cDim 1
foreach ($l in 0, 1, 2, -1) {
    $c = $LevelColor[$l]
    Brush "lv$l" $c
    Pen "pen$l" $c 1.5
    Pen "glow$l" ([Drawing.Color]::FromArgb(60, $c)) 7
    Pen "core$l" $c 2
    Brush "fill$l" ([Drawing.Color]::FromArgb(28, $c))
}
$GDI['glow0'].LineJoin = 'Round'; $GDI['glow1'].LineJoin = 'Round'; $GDI['glow2'].LineJoin = 'Round'

$TF = [Windows.Forms.TextFormatFlags]
$tfL = $TF::Left -bor $TF::VerticalCenter -bor $TF::SingleLine -bor $TF::EndEllipsis -bor $TF::NoPrefix -bor $TF::NoPadding
$tfR = $TF::Right -bor $TF::VerticalCenter -bor $TF::SingleLine -bor $TF::NoPrefix -bor $TF::NoPadding
$tfC = $TF::HorizontalCenter -bor $TF::VerticalCenter -bor $TF::SingleLine -bor $TF::NoPrefix -bor $TF::NoPadding

function Txt($g, $s, $font, $color, $x, $y, $w, $h, $flags = $tfL) {
    [Windows.Forms.TextRenderer]::DrawText($g, [string]$s, $font, (New-Object Drawing.Rectangle([int]$x, [int]$y, [int]$w, [int]$h)), $color, $flags)
}
function TxtW($g, $s, $font) { [Windows.Forms.TextRenderer]::MeasureText($g, [string]$s, $font, (New-Object Drawing.Size(2000, 100)), $tfL).Width }

# 切角多边形（右上大切角，左下小切角）
function CutPoly($x, $y, $w, $h, $c) {
    [Drawing.PointF[]]@(
        (New-Object Drawing.PointF($x, $y)), (New-Object Drawing.PointF(($x + $w - $c), $y)),
        (New-Object Drawing.PointF(($x + $w), ($y + $c))), (New-Object Drawing.PointF(($x + $w), ($y + $h))),
        (New-Object Drawing.PointF(($x + $c / 2), ($y + $h))), (New-Object Drawing.PointF($x, ($y + $h - $c / 2)))
    )
}
function Scanlines($g, $w, $h) { for ($y = 2; $y -lt $h; $y += 3) { $g.DrawLine($GDI['scan'], 0, $y, $w, $y) } }

# ---------- 界面 ----------
$form = New-Object Windows.Forms.Form
$form.Text = 'WATCHDOG // 内存 · CPU 监控'
$form.Size = New-Object Drawing.Size(1140, 880)
$form.MinimumSize = New-Object Drawing.Size(1000, 640)
$form.StartPosition = 'CenterScreen'
$form.Font = $fCN
$form.BackColor = $cBg
$form.ForeColor = $cText

# 顶部标题条
$header = New-Object BufferedPanel
$header.Dock = 'Top'; $header.Height = 52
$header.Add_Paint({
    param($s, $e)
    $g = $e.Graphics; $w = $s.Width; $h = $s.Height
    $g.FillRectangle($GDI['bg'], 0, 0, $w, $h)
    Txt $g 'WATCHDOG' $fHead $cCyan 16 6 200 36
    Txt $g '// 内存 · CPU 监控终端' $fCN $cAccent 152 8 300 36
    $live = if ($script:tick % 2 -eq 0) { $GDI['lv2'] } else { $GDI['panel'] }
    $g.FillRectangle($live, $w - 230, 18, 8, 8)
    Txt $g ('LIVE  ' + (Get-Date).ToString('HH:mm')) $fTagB $cCyan ($w - 214) 8 90 28
    Txt $g 'SYS.MON v3 // 0x5744' $fSmall $cRedDim ($w - 190) 8 176 28 $tfR
    # 底部红线，左侧加粗一段
    $g.FillRectangle($GDI['acc'], 0, $h - 3, $w, 1)
    $g.FillPolygon($GDI['acc'], [Drawing.PointF[]]@((New-Object Drawing.PointF(0, ($h - 6))), (New-Object Drawing.PointF(220, ($h - 6))), (New-Object Drawing.PointF(226, ($h - 2))), (New-Object Drawing.PointF(0, ($h - 2)))))
})

# 三张卡片
$cards = New-Object BufferedPanel
$cards.Dock = 'Top'; $cards.Height = 150; $cards.BackColor = $cBg

function New-Card($tag, $title, $code) {
    $p = New-Object BufferedPanel
    $p.Tag = @{ Code = $code; Tag = $tag; Title = $title; Value = '--'; Badge = '...'; Level = -1; Sub = ''; Pct = -1 }
    $p.Add_Paint({
        param($s, $e)
        $g = $e.Graphics; $w = $s.Width; $h = $s.Height; $d = $s.Tag
        $g.SmoothingMode = 'AntiAlias'
        $g.FillRectangle($GDI['bg'], 0, 0, $w, $h)
        $poly = CutPoly 0.5 0.5 ($w - 1.5) ($h - 1.5) 18
        $g.FillPolygon($GDI['panel'], $poly)
        Scanlines $g $w $h
        $lvl = [int]$d.Level
        $g.DrawPolygon($GDI['accPen'], $poly)
        $g.FillRectangle($GDI['acc'], 0, 0, 46, 4)
        Txt $g $d.Code $fSmall $cRedDim ($w - 160) ($h - 17) 148 14 $tfR
        # 标题
        Txt $g ('// ' + $d.Tag) $fTagB $cAccent 12 8 120 22
        $tw = TxtW $g ('// ' + $d.Tag) $fTagB
        Txt $g $d.Title $fCNb $cGray (18 + $tw) 8 120 22
        # 状态标签（平行四边形）
        if ($d.Badge) {
            $bx = $w - 132; $by = 10
            $g.FillPolygon($GDI["lv$lvl"], [Drawing.PointF[]]@((New-Object Drawing.PointF(($bx + 8), $by)), (New-Object Drawing.PointF(($bx + 108), $by)), (New-Object Drawing.PointF(($bx + 100), ($by + 22))), (New-Object Drawing.PointF($bx, ($by + 22)))))
            Txt $g $d.Badge $fCNb $cBg $bx $by 108 22 $tfC
        }
        # 主数值
        Txt $g $d.Value $fNum $cCyan 10 32 ($w - 20) 40
        # 分段进度条
        if ($d.Pct -ge 0) {
            $n = 30; $gap = 3; $bw = ($w - 24 - $gap * ($n - 1)) / $n
            $on = [math]::Round($n * [math]::Min(100, $d.Pct) / 100)
            for ($i = 0; $i -lt $n; $i++) {
                $br = if ($i -lt $on) { $GDI["lv$lvl"] } else { $GDI['dim'] }
                $g.FillRectangle($br, [single](12 + $i * ($bw + $gap)), [single]80, [single]$bw, [single]8)
            }
        }
        Txt $g $d.Sub $fCN $cGray 12 92 ($w - 24) 22
    })
    $cards.Controls.Add($p)
    $p
}
$cardMem = New-Card 'MEMORY' '内存' 'MEM-01 // 0x4D45'
$cardCpu = New-Card 'CPU' '处理器' 'CPU-02 // 0x4350'
$cardDog = New-Card 'WATCHDOG' '看门狗' 'WDG-03 // 0x5744'
$cards.Add_Resize({
    $w = [int](($cards.ClientSize.Width - 48) / 3)
    $i = 0
    foreach ($c in @($cardMem, $cardCpu, $cardDog)) { $c.SetBounds(12 + $i * ($w + 12), 6, $w, 140); $i++ }
})

function Set-Card($card, $value, $badge, $level, $sub, $pct) {
    $d = $card.Tag; $d.Value = $value; $d.Badge = $badge; $d.Level = $level; $d.Sub = $sub; $d.Pct = $pct
    $card.Invalidate()
}

# 泄漏扫描栏
$leak = New-Object BufferedPanel
$leak.Dock = 'Top'; $leak.Height = 96
$leak.Add_Paint({
    param($s, $e)
    $g = $e.Graphics; $w = $s.Width; $h = $s.Height
    $g.FillRectangle($GDI['bg'], 0, 0, $w, $h)
    $g.FillRectangle($GDI['panel'], 12, 6, $w - 24, $h - 12)
    Scanlines $g $w $h
    $g.DrawRectangle($GDI['accPen'], 12, 6, $w - 25, $h - 13)
    $lvl = 0; foreach ($l in $script:leakLines) { if ($l[1] -gt $lvl) { $lvl = $l[1] } }
    $g.FillRectangle($GDI["lv$lvl"], 12, 6, 5, $h - 12)
    Txt $g '// LEAK SCAN' $fTagB $cAccent 28 10 120 20
    Txt $g '泄漏扫描' $fCNb $cGray 128 10 100 20
    $y = 32
    foreach ($l in $script:leakLines) {
        $c = if ($l[1] -eq 2) { $cRed } elseif ($l[1] -eq 1) { $cYellow } elseif ($l[1] -eq 0) { $cCyan } else { $cGray }
        Txt $g $l[0] $fCN $c 28 $y ($w - 56) 20
        $y += 19
    }
})

# 程序列表（自绘）
$lv = New-Object BufferedListView
$lv.Dock = 'Fill'; $lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.HideSelection = $false; $lv.MultiSelect = $false
$lv.OwnerDraw = $true; $lv.BackColor = $cRowA; $lv.ForeColor = $cText; $lv.BorderStyle = 'None'
$rowH = New-Object Windows.Forms.ImageList; $rowH.ImageSize = New-Object Drawing.Size(1, 26); $lv.SmallImageList = $rowH
foreach ($c in @(@('程序', 170), @('说明', 200), @('内存 MB', 90), @('CPU %', 70), @('进程', 55), @('状态', 90), @('24 小时变化', 160), @('备注', 260))) {
    [void]$lv.Columns.Add($c[0], $c[1])
}
$RightCols = @(2, 3, 4)
$lv.Add_DrawColumnHeader({
    param($s, $e)
    $g = $e.Graphics; $r = $e.Bounds
    $g.FillRectangle($GDI['bg'], $r)
    $g.FillRectangle($GDI['acc'], $r.X, $r.Bottom - 2, $r.Width, 2)
    $f = if ($RightCols -contains $e.ColumnIndex) { $tfR } else { $tfL }
    Txt $g $e.Header.Text $fCNb $cAccent ($r.X + 8) $r.Y ($r.Width - 16) $r.Height $f
})
$lv.Add_DrawItem({ param($s, $e) })
$lv.Add_DrawSubItem({
    param($s, $e)
    $g = $e.Graphics; $r = $e.Bounds; $it = $e.Item
    $st = $it.SubItems[5].Text
    $bg = if ($it.Selected) { $GDI['sel'] } elseif ($st -eq '疑似泄漏') { $GDI['leakRow'] } elseif ($st -eq '占用较大') { $GDI['warnRow'] } elseif ($it.Index % 2) { $GDI['rowB'] } else { $GDI['rowA'] }
    $g.FillRectangle($bg, $r)
    $col = $e.ColumnIndex
    $c = switch ($col) {
        0 { $cText }
        1 { $cGray }
        5 { if ($st -eq '疑似泄漏') { $cRed } elseif ($st -eq '占用较大') { $cYellow } else { $cCyan } }
        6 { if ($st -eq '疑似泄漏') { $cRed } else { $cGray } }
        7 { if ($st -eq '疑似泄漏') { $cRed } else { $cGray } }
        default { $cText }
    }
    $f = if ($RightCols -contains $col) { $tfR } else { $tfL }
    $font = if ($col -eq 0 -or $col -eq 5) { $fCNb } else { $fCN }
    Txt $g $e.SubItem.Text $font $c ($r.X + 8) $r.Y ($r.Width - 16) $r.Height $f
    if ($col -eq 0 -and $it.Selected) { $g.FillRectangle($GDI['lv0'], $r.X, $r.Y + 3, 3, $r.Height - 6) }
})
function Fit-Columns {
    $n = $lv.Columns.Count; $sum = 0
    for ($i = 0; $i -lt $n - 1; $i++) { $sum += $lv.Columns[$i].Width }
    $want = [math]::Max(120, $lv.ClientSize.Width - $sum - 2)
    if ($lv.Columns[$n - 1].Width -ne $want) { $lv.Columns[$n - 1].Width = $want }
}
$lv.Add_Resize({ Fit-Columns })
$lv.Add_SelectedIndexChanged({
    if ($script:updating) { return }
    if ($lv.SelectedItems.Count -gt 0) { $script:selected = $lv.SelectedItems[0].Text; $chart.Invalidate() }
})

# 内存曲线
$chart = New-Object BufferedPanel
$chart.Dock = 'Bottom'; $chart.Height = 196
$chart.Add_Paint({
    param($s, $e)
    $g = $e.Graphics; $w = $s.Width; $h = $s.Height
    $g.FillRectangle($GDI['bg'], 0, 0, $w, $h)
    $g.SmoothingMode = 'AntiAlias'
    $poly = CutPoly 12.5 8.5 ($w - 25) ($h - 17) 18
    $g.FillPolygon($GDI['panel'], $poly)
    Scanlines $g $w $h
    $g.DrawPolygon($GDI['accPen'], $poly)
    $name = $script:selected
    Txt $g '// MEM TRACE 24H' $fTagB $cAccent 26 14 160 20
    if (-not $name -or -not $script:hist.ContainsKey($name) -or $script:hist[$name].Count -lt 2) {
        $msg = if ($name) { "$name ：还没有足够的历史数据（看门狗每 10 分钟记录一次）" } else { '点选上方任意一个程序，这里显示它最近 24 小时的内存曲线（数据来自看门狗，每 10 分钟一个点）' }
        Txt $g $msg $fCN $cGray 26 40 ($w - 52) 24
        return
    }
    $pts = $script:hist[$name]
    $st = (Get-Status $name $pts[$pts.Count - 1].MB)[0]
    $lvl = if ($st -eq '疑似泄漏') { 2 } elseif ($st -eq '占用较大') { 1 } else { 0 }
    $title = '{0}  ·  {1}' -f $name, $(if ($Desc[$name]) { $Desc[$name] } else { '-' })
    Txt $g $title $fCNb $cText 160 14 ($w - 200) 20
    $L = 84; $R = 30; $T = 42; $B = 30
    $pw = $w - $L - $R; $ph = $h - $T - $B
    $end = Get-Date; $begin = $end.AddHours(-24)
    $max = 0.0; $min = [double]::MaxValue
    foreach ($p in $pts) { if ($p.MB -gt $max) { $max = $p.MB }; if ($p.MB -lt $min) { $min = $p.MB } }
    $lo = [math]::Max(0, $min - ($max - $min) * 0.15 - 10); $hi = $max + ($max - $min) * 0.15 + 10
    for ($i = 0; $i -le 3; $i++) {
        $y = $T + $ph * $i / 3
        $g.DrawLine($GDI['grid'], $L, $y, $L + $pw, $y)
        Txt $g ('{0:N0}' -f ($hi - ($hi - $lo) * $i / 3)) $fSmall $cGray 20 ($y - 9) ($L - 28) 18 $tfR
    }
    for ($hr = 0; $hr -le 24; $hr += 6) {
        $x = $L + $pw * $hr / 24
        $g.DrawLine($GDI['grid'], $x, $T, $x, $T + $ph)
        Txt $g $begin.AddHours($hr).ToString('HH:mm') $fSmall $cGray ($x - 20) ($T + $ph + 4) 40 18 $tfC
    }
    $arr = New-Object 'System.Collections.Generic.List[System.Drawing.PointF]'
    foreach ($p in $pts) {
        $x = $L + $pw * (($p.T - $begin).TotalHours / 24)
        $y = $T + $ph * (1 - ($p.MB - $lo) / ($hi - $lo))
        $arr.Add((New-Object Drawing.PointF([single]$x, [single]$y)))
    }
    $line = $arr.ToArray()
    $area = New-Object 'System.Collections.Generic.List[System.Drawing.PointF]'
    $area.Add((New-Object Drawing.PointF($line[0].X, [single]($T + $ph)))); $area.AddRange($line); $area.Add((New-Object Drawing.PointF($line[$line.Length - 1].X, [single]($T + $ph))))
    $g.SetClip((New-Object Drawing.RectangleF([single]$L, [single]$T, [single]$pw, [single]$ph)))
    $g.FillPolygon($GDI["fill$lvl"], $area.ToArray())
    $g.DrawLines($GDI["glow$lvl"], $line)
    $g.DrawLines($GDI["core$lvl"], $line)
    $g.ResetClip()
    $lp = $line[$line.Length - 1]
    $g.FillRectangle($GDI["lv$lvl"], $lp.X - 4, $lp.Y - 4, 8, 8)
    Txt $g ('{0:N0} MB' -f $pts[$pts.Count - 1].MB) $fTagB $LevelColor[$lvl] ($lp.X - 110) ($lp.Y - 26) 104 20 $tfR
})

# 底部状态栏
$status = New-Object BufferedPanel
$status.Dock = 'Bottom'; $status.Height = 28
$status.Add_Paint({
    param($s, $e)
    $g = $e.Graphics; $w = $s.Width; $h = $s.Height
    $g.FillRectangle($GDI['bg'], 0, 0, $w, $h)
    $g.DrawLine($GDI['accDim'], 0, 0, $w, 0)
    $g.FillRectangle($GDI['acc'], 12, 10, 8, 8)
    $txt = '每 5 秒刷新 · 最小化时暂停 · 本窗口自身占用 {0:N0} MB · GDI 对象 {1} · 历史数据 {2}' -f $script:selfMB, $script:selfGdi, $DataDir
    Txt $g $txt $fCN $cGray 28 0 ($w - 40) $h
})

$form.Controls.Add($lv)
$form.Controls.Add($leak)
$form.Controls.Add($cards)
$form.Controls.Add($header)
$form.Controls.Add($chart)
$form.Controls.Add($status)
$lv.BringToFront()

# 深色标题栏、深色滚动条（Windows 11）
$form.Add_HandleCreated({
    [NativeInfo]::Dwm($form.Handle, 20, 1)            # 深色模式
    [NativeInfo]::Dwm($form.Handle, 35, 0x000C090E)   # 标题栏底色：红黑
    [NativeInfo]::Dwm($form.Handle, 36, 0x00575FFF)   # 标题文字：珊瑚红
    [NativeInfo]::Dwm($form.Handle, 34, 0x00575FFF)   # 窗口边框：珊瑚红
})
$lv.Add_HandleCreated({
    [void][NativeInfo]::SetWindowTheme($lv.Handle, 'DarkMode_Explorer', $null)
    $hdr = [NativeInfo]::SendMessage($lv.Handle, 0x101F, [IntPtr]::Zero, [IntPtr]::Zero)   # LVM_GETHEADER
    if ($hdr -ne [IntPtr]::Zero) { [void][NativeInfo]::SetWindowTheme($hdr, 'DarkMode_ItemsView', $null) }
})

function Refresh-All {
    if ($form.WindowState -eq [Windows.Forms.FormWindowState]::Minimized) { return }
    $script:tick++
    $now = Get-Date
    if (($now - $script:lastSlow).TotalSeconds -ge 60) { $script:lastSlow = $now; Update-Slow }

    # 内存
    $m = [NativeInfo]::Mem()
    $totalGB = $m.ullTotalPhys / 1GB; $usedGB = ($m.ullTotalPhys - $m.ullAvailPhys) / 1GB
    $pct = 100 * $usedGB / $totalGB
    $commitGB = ($m.ullTotalPageFile - $m.ullAvailPageFile) / 1GB; $limitGB = $m.ullTotalPageFile / 1GB
    $cpct = 100 * $commitGB / $limitGB
    $worst = [math]::Max($pct, $cpct)
    $lvl = if ($worst -lt 70) { 0 } elseif ($worst -lt 85) { 1 } else { 2 }
    $badge = @('正常', '偏高', '紧张')[$lvl]
    Set-Card $cardMem ('{0:N1} / {1:N0} GB' -f $usedGB, $totalGB) ('{0}  {1:N0}%' -f $badge, $pct) $lvl ('已提交 {0:N1} / {1:N0} GB（{2:N0}%）· 70% 以下都算正常' -f $commitGB, $limitGB, $cpct) $pct

    # CPU（取最近 30 秒平均，避免一瞬间的波动）
    $script:cpuHist.Enqueue([NativeInfo]::Cpu())
    while ($script:cpuHist.Count -gt 6) { [void]$script:cpuHist.Dequeue() }
    $cpuAvg = ($script:cpuHist | Measure-Object -Average).Average
    $procs = Sample-Processes
    $busy = @($procs | Where-Object { $_.Name -notlike 'svc:*' -and $_.Name -ne 'Idle' } | Sort-Object CpuPct -Descending | Select-Object -First 2)
    $lvl = if ($cpuAvg -lt 50) { 0 } elseif ($cpuAvg -lt 85) { 1 } else { 2 }
    Set-Card $cardCpu ('{0:N0} %' -f $cpuAvg) (@('正常', '较忙', '很忙')[$lvl]) $lvl ('30 秒平均 · 最忙：' + (($busy | ForEach-Object { '{0} {1:N1}%' -f $_.Name, $_.CpuPct }) -join '，')) $cpuAvg

    # 看门狗
    $last = if ($script:sys.Count -gt 0) { $script:sys[$script:sys.Count - 1] } else { $null }
    if (-not $script:taskState) {
        Set-Card $cardDog '未安装' '离线' 1 '运行 Install-Watchdog.ps1 后每 10 分钟自动检查' -1
    } elseif (-not $last) {
        Set-Card $cardDog '等待首次检查' '待命' 1 '已安装，第一次检查完成后显示结果' -1
    } else {
        $lt = [datetime]::ParseExact($last.Time, 'yyyy-MM-dd HH:mm:ss', $null)
        $mins = ($now - $lt).TotalMinutes
        $ok = $mins -le 25
        Set-Card $cardDog ('上次 ' + (Ago $lt)) $(if ($ok) { '运行中' } else { '可能停了' }) $(if ($ok) { 0 } else { 2 }) ('每次耗时 {0:N1} 秒，查完即退出 · 进度条 = 距下次检查' -f ([double]$last.RunMs / 1000)) ([math]::Min(100, $mins * 10))
    }

    # 泄漏扫描
    $rows = @($procs | Where-Object { $_.Name -ne 'Idle' -and $_.Name -ne 'Memory Compression' })
    $suspects = @(foreach ($r in $rows) { $st = Get-Status $r.Name $r.PrivMB; if ($st[0] -eq '疑似泄漏') { '{0}（{1:+#,0} MB/小时）' -f $r.Name, $script:analysis[$r.Name].Slope } })
    $lines = @()
    if ($script:hist.Count -eq 0) { $lines += , @('还没有历史数据：看门狗安装后每 10 分钟记录一次，大约 2 小时后开始判断有没有内存泄漏。', 1) }
    elseif ($suspects.Count -gt 0) { $lines += , @(('▲ 疑似内存泄漏（内存持续稳定地上涨）：' + ($suspects -join '、')), 2) }
    else { $lines += , @('■ 最近 24 小时没有发现持续上涨的程序。', 0) }
    if ($script:nvMB -gt 300) { $lines += , @("▲ NVIDIA 的 nvtopps.db3 已经 $($script:nvMB) MB（正常只有几 MB），看门狗下次检查会自动重建。", 2) }
    if ($script:lastAction) { $lines += , @(('看门狗最近一次动作：' + $script:lastAction), -1) }
    $script:leakLines = $lines
    $leak.Invalidate()

    # 程序列表：内存前 25，加上不在前 25 但状态异常的
    $list = @($rows | Where-Object { $_.Name -notlike 'svc:*' } | Sort-Object PrivMB -Descending | Select-Object -First 25)
    $inList = @{}; foreach ($r in $list) { $inList[$r.Name] = 1 }
    foreach ($r in $rows) { if (-not $inList.ContainsKey($r.Name) -and (Get-Status $r.Name $r.PrivMB)[0] -ne '正常') { $list += $r } }
    $script:updating = $true
    $lv.BeginUpdate()
    try {
        $lv.Items.Clear()
        foreach ($r in $list) {
            $st = Get-Status $r.Name $r.PrivMB
            $it = New-Object Windows.Forms.ListViewItem($r.Name)
            [void]$it.SubItems.Add([string]$Desc[$r.Name])
            [void]$it.SubItems.Add(('{0:N0}' -f $r.PrivMB))
            [void]$it.SubItems.Add(('{0:N1}' -f $r.CpuPct))
            [void]$it.SubItems.Add([string]$r.Count)
            [void]$it.SubItems.Add($st[0])
            [void]$it.SubItems.Add((Trend-Text $r.Name))
            [void]$it.SubItems.Add($st[1])
            [void]$lv.Items.Add($it)
            if ($r.Name -eq $script:selected) { $it.Selected = $true }
        }
    } finally { $lv.EndUpdate(); $script:updating = $false }
    Fit-Columns

    # 本窗口自己的占用
    $me = [Diagnostics.Process]::GetCurrentProcess()
    try { $script:selfMB = $me.PrivateMemorySize64 / 1MB; $script:selfGdi = [NativeInfo]::GetGuiResources($me.Handle, 0) } finally { $me.Dispose() }
    $header.Invalidate(); $status.Invalidate(); $chart.Invalidate()
}

function Dispose-All {
    foreach ($o in $GDI.Values) { $o.Dispose() }
    foreach ($f in @($fCN, $fCNb, $fCNbig, $fTag, $fTagB, $fNum, $fHead, $fSmall)) { $f.Dispose() }
    $rowH.Dispose()
}

# 先取一次基准，CPU 才能算出差值
[void][NativeInfo]::Cpu(); [void](Sample-Processes)

if ($SelfTest) {
    Start-Sleep -Milliseconds 500
    # 在屏幕外真实显示窗口，让所有控件都按正常流程创建和绘制
    $form.StartPosition = 'Manual'; $form.Location = New-Object Drawing.Point(-5000, -5000); $form.ShowInTaskbar = $false
    $form.Show(); [Windows.Forms.Application]::DoEvents()
    $bmp = New-Object Drawing.Bitmap($form.Width, $form.Height)
    $rect = New-Object Drawing.Rectangle(0, 0, $form.Width, $form.Height)
    $mem = @()
    for ($i = 1; $i -le $Loops; $i++) {
        Refresh-All
        [Windows.Forms.Application]::DoEvents()   # 处理重绘消息
        $form.DrawToBitmap($bmp, $rect)           # 再完整画一遍，检查绘制有没有泄漏
        if ($i -eq [math]::Min(20, $Loops) -or $i -eq $Loops) {
            [GC]::Collect(); [GC]::WaitForPendingFinalizers()
            $me = [Diagnostics.Process]::GetCurrentProcess()
            $mem += '第 {0} 次刷新+重绘后：本程序 {1:N1} MB，托管堆 {2:N1} MB，句柄 {3}，GDI 对象 {4}，USER 对象 {5}' -f $i, ($me.PrivateMemorySize64 / 1MB), ([GC]::GetTotalMemory($true) / 1MB), $me.HandleCount, [NativeInfo]::GetGuiResources($me.Handle, 0), [NativeInfo]::GetGuiResources($me.Handle, 1)
            $me.Dispose()
        }
    }
    if ($Snapshot) { $bmp.Save($Snapshot, [Drawing.Imaging.ImageFormat]::Png) }
    $bmp.Dispose()
    '内存卡片: {0} [{1}] {2}' -f $cardMem.Tag.Value, $cardMem.Tag.Badge, $cardMem.Tag.Sub
    'CPU 卡片: {0} [{1}] {2}' -f $cardCpu.Tag.Value, $cardCpu.Tag.Badge, $cardCpu.Tag.Sub
    '看门狗卡片: {0} [{1}] {2}' -f $cardDog.Tag.Value, $cardDog.Tag.Badge, $cardDog.Tag.Sub
    '泄漏扫描: ' + ((@(foreach ($l in $script:leakLines) { $l[0] })) -join ' / ')
    '--- 异常项 ---'
    foreach ($it in $lv.Items) { if ($it.SubItems[5].Text -ne '正常') { ($it.SubItems | ForEach-Object { $_.Text }) -join ' | ' } }
    '--- 自身资源 ---'
    $mem
    $form.Dispose(); Dispose-All
    return
}

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 5000
$timer.Add_Tick({ Refresh-All })
$form.Add_Shown({ Start-Sleep -Milliseconds 300; Refresh-All; $timer.Start() })
$form.Add_FormClosed({ $timer.Stop(); $timer.Dispose() })
[void]$form.ShowDialog()
$form.Dispose()
Dispose-All
