# MemMonitor：内存 / CPU / 磁盘 监控面板（赛博朋克风格界面：红黑底 + 荧光蓝）
# 只在打开时运行，关掉窗口就完全退出。每 5 秒刷新一次，只保留最新一份数据，不会越用越大。
# 所有画笔 / 画刷 / 字体只在启动时创建一次；系统句柄（进程、磁盘计数器）用完立即关闭；图标缓存有上限。
# 历史数据来自看门狗（MemWatchdog.ps1，每 10 分钟记录一次），用来判断是否有程序在持续泄漏内存。
#   -SelfTest -Loops N [-Snapshot x.png] [-Select 程序名] : 在屏幕外显示窗口，连续刷新并重绘 N 次，打印结果和自身资源
param(
    [string]$DataDir = (Join-Path $PSScriptRoot 'data'),
    [switch]$SelfTest,
    [int]$Loops = 1,
    [string]$Snapshot,
    [string]$Select
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @"
using System;
using System.Text;
using System.Drawing;
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
    [StructLayout(LayoutKind.Sequential)]
    struct IO_COUNTERS { public ulong ReadOps, WriteOps, OtherOps, ReadBytes, WriteBytes, OtherBytes; }
    [DllImport("kernel32.dll")] static extern bool GlobalMemoryStatusEx(ref MEMSTAT m);
    [DllImport("kernel32.dll")] static extern bool GetSystemTimes(out long idle, out long kernel, out long user);
    [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll")] static extern bool GetProcessIoCounters(IntPtr h, out IO_COUNTERS c);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool QueryFullProcessImageName(IntPtr h, int flags, StringBuilder sb, ref int size);
    [DllImport("user32.dll")] public static extern uint GetGuiResources(IntPtr h, uint flags);
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr h, int attr, ref int val, int size);
    [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)] public static extern int SetWindowTheme(IntPtr h, string app, string id);
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, int msg, IntPtr w, IntPtr l);
    const uint QUERY_LIMITED = 0x1000;

    public static MEMSTAT Mem() { MEMSTAT m = new MEMSTAT(); m.dwLength = (uint)Marshal.SizeOf(m); GlobalMemoryStatusEx(ref m); return m; }
    static long pIdle, pTotal;
    public static double Cpu() {
        long i, k, u; GetSystemTimes(out i, out k, out u);
        long t = k + u; double r = 0;
        if (pTotal > 0 && t - pTotal > 0) r = 100.0 * (1.0 - (double)(i - pIdle) / (t - pTotal));
        pIdle = i; pTotal = t;
        return Math.Max(0, Math.Min(100, r));
    }
    // 进程累计读写字节数（文件 + 其他 I/O）。拿不到返回 -1。句柄用完立即关闭。
    public static long IoBytes(int pid) {
        IntPtr h = OpenProcess(QUERY_LIMITED, false, pid);
        if (h == IntPtr.Zero) return -1;
        try { IO_COUNTERS c; if (!GetProcessIoCounters(h, out c)) return -1; return (long)(c.ReadBytes + c.WriteBytes); }
        finally { CloseHandle(h); }
    }
    public static string ImagePath(int pid) {
        IntPtr h = OpenProcess(QUERY_LIMITED, false, pid);
        if (h == IntPtr.Zero) return null;
        try { StringBuilder sb = new StringBuilder(1024); int n = sb.Capacity; return QueryFullProcessImageName(h, 0, sb, ref n) ? sb.ToString() : null; }
        finally { CloseHandle(h); }
    }
    public static void Dwm(IntPtr h, int attr, int val) { try { DwmSetWindowAttribute(h, attr, ref val, 4); } catch { } }
}
// 整机磁盘读写（PDH，英文计数器名，不受系统语言影响）。只打开一次，关窗时关闭。
public static class DiskPerf {
    [StructLayout(LayoutKind.Explicit)] struct FMT { [FieldOffset(0)] public uint CStatus; [FieldOffset(8)] public double Value; }
    [DllImport("pdh.dll", CharSet = CharSet.Unicode)] static extern int PdhOpenQuery(string src, IntPtr user, out IntPtr q);
    [DllImport("pdh.dll", CharSet = CharSet.Unicode)] static extern int PdhAddEnglishCounter(IntPtr q, string path, IntPtr user, out IntPtr c);
    [DllImport("pdh.dll")] static extern int PdhCollectQueryData(IntPtr q);
    [DllImport("pdh.dll")] static extern int PdhGetFormattedCounterValue(IntPtr c, uint fmt, IntPtr type, out FMT v);
    [DllImport("pdh.dll")] static extern int PdhCloseQuery(IntPtr q);
    static IntPtr q, cr, cw, ci;
    public static bool Open() {
        if (PdhOpenQuery(null, IntPtr.Zero, out q) != 0) return false;
        PdhAddEnglishCounter(q, @"\PhysicalDisk(_Total)\Disk Read Bytes/sec", IntPtr.Zero, out cr);
        PdhAddEnglishCounter(q, @"\PhysicalDisk(_Total)\Disk Write Bytes/sec", IntPtr.Zero, out cw);
        PdhAddEnglishCounter(q, @"\PhysicalDisk(_Total)\% Idle Time", IntPtr.Zero, out ci);
        PdhCollectQueryData(q); return true;
    }
    static double Get(IntPtr c) { FMT v; return PdhGetFormattedCounterValue(c, 0x200, IntPtr.Zero, out v) == 0 ? v.Value : 0; }
    // [读 B/s, 写 B/s, 忙碌 %]
    public static double[] Read() {
        if (q == IntPtr.Zero) return new double[] { 0, 0, 0 };
        PdhCollectQueryData(q);
        return new double[] { Get(cr), Get(cw), Math.Max(0, Math.Min(100, 100 - Get(ci))) };
    }
    public static void Close() { if (q != IntPtr.Zero) { PdhCloseQuery(q); q = IntPtr.Zero; } }
}
public class BufferedPanel : Panel { public BufferedPanel() { DoubleBuffered = true; ResizeRedraw = true; } }
public class BufferedListView : ListView { public BufferedListView() { DoubleBuffered = true; } }
public class CyberColors : ProfessionalColorTable {
    static Color bg = Color.FromArgb(24, 11, 14), sel = Color.FromArgb(70, 20, 26), acc = Color.FromArgb(255, 95, 87);
    public override Color ToolStripDropDownBackground { get { return bg; } }
    public override Color ImageMarginGradientBegin { get { return bg; } }
    public override Color ImageMarginGradientMiddle { get { return bg; } }
    public override Color ImageMarginGradientEnd { get { return bg; } }
    public override Color MenuItemSelected { get { return sel; } }
    public override Color MenuItemSelectedGradientBegin { get { return sel; } }
    public override Color MenuItemSelectedGradientEnd { get { return sel; } }
    public override Color MenuItemBorder { get { return acc; } }
    public override Color MenuBorder { get { return acc; } }
    public override Color SeparatorDark { get { return Color.FromArgb(92, 30, 33); } }
    public override Color SeparatorLight { get { return bg; } }
}
"@

$ToolDir = $PSScriptRoot
$LogFile = Join-Path (Split-Path $DataDir) 'MemWatchdog.log'
$NvDb    = 'C:\ProgramData\NVIDIA Corporation\nvtopps\nvtopps.db3'
$WatchedServices = @('Audiosrv', 'LightingService', 'NVDisplay.ContainerLocalSystem')
# 系统关键进程：不允许在界面里结束或重启
$Protected = @('System', 'Idle', 'Registry', 'smss', 'csrss', 'wininit', 'winlogon', 'services', 'lsass', 'LsaIso', 'svchost',
    'dwm', 'Memory Compression', 'MemCompression', 'fontdrvhost', 'MsMpEng', 'audiodg', 'sihost', 'ctfmon', 'spoolsv',
    'SecurityHealthService', 'Secure System', 'NVDisplay.Container')

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
    'System' = 'Windows 内核'; 'SearchIndexer' = 'Windows 搜索索引'; 'Taskmgr' = '任务管理器'
}

# 判断标准
$LeakSlopeMBh = 50     # 每小时至少涨 50 MB
$LeakGrowthMB = 300    # 累计至少涨 300 MB
$LeakR2       = 0.6    # 涨势要稳定（不是忽高忽低）
$BigMB        = 1500   # 超过这个算"占用较大"
$HeavyIoMBs   = 30     # 单个程序读写超过这个速度会提示

# ---------- 状态（每次刷新都整体替换，不累积） ----------
$script:prevCpu   = @{}; $script:prevIo = @{}; $script:prevTime = $null; $script:denied = @{}
$script:cpuHist   = New-Object 'System.Collections.Generic.Queue[double]'
$script:hist      = @{}; $script:analysis = @{}; $script:sys = @(); $script:histSig = ''
$script:lastSlow  = [datetime]::MinValue; $script:forceSlowAt = $null
$script:svcPid    = @{}; $script:taskState = $null; $script:lastAction = ''; $script:nvMB = 0
$script:selected  = if ($Select) { $Select } else { $null }
$script:updating  = $false; $script:tick = 0
$script:selfMB = 0; $script:selfGdi = 0; $script:selfCpu = 0.0; $script:selfPrevCpu = $null
$script:alerts    = @(); $script:rows = @{}; $script:disk = @(0, 0, 0)
$script:icons     = @{}   # 程序名 -> 32px 图标（Bitmap 或 $null），上限 150 个

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
    if ($btnInstall) { $btnInstall.Text = if ($script:taskState) { '卸载看门狗计划任务' } else { '安装看门狗（每 10 分钟自动检查）' } }
}

function Sample-Processes {
    $now = [DateTime]::UtcNow
    $elapsedMs = if ($script:prevTime) { ($now - $script:prevTime).TotalMilliseconds } else { 0 }
    $cores = [Environment]::ProcessorCount
    $cur = @{}; $curIo = @{}; $newDenied = @{}; $byName = @{}
    foreach ($p in [System.Diagnostics.Process]::GetProcesses()) {
        try {
            $id = $p.Id
            $names = @($p.ProcessName)
            if ($script:svcPid.ContainsKey($id)) { $names += $script:svcPid[$id] }
            $priv = $p.PrivateMemorySize64 / 1MB
            $d = 0.0; $dio = 0.0
            if (-not $script:denied.ContainsKey($id)) {
                try {
                    $ms = $p.TotalProcessorTime.TotalMilliseconds
                    $cur[$id] = $ms
                    if ($script:prevCpu.ContainsKey($id)) { $d = [math]::Max(0, $ms - $script:prevCpu[$id]) }
                } catch { $newDenied[$id] = 1 }
            } else { $newDenied[$id] = 1 }
            $io = [NativeInfo]::IoBytes($id)
            if ($io -ge 0) { $curIo[$id] = $io; if ($script:prevIo.ContainsKey($id)) { $dio = [math]::Max(0, $io - $script:prevIo[$id]) } }
            foreach ($nm in $names) {
                if (-not $byName.ContainsKey($nm)) { $byName[$nm] = [pscustomobject]@{ Name = $nm; Pid = $id; PrivMB = 0.0; CpuMs = 0.0; IoB = 0.0; Count = 0; CpuPct = 0.0; IoMBs = 0.0 } }
                $e = $byName[$nm]; $e.PrivMB += $priv; $e.CpuMs += $d; $e.IoB += $dio; $e.Count++
            }
        } catch {} finally { $p.Dispose() }
    }
    $script:prevCpu = $cur; $script:prevIo = $curIo; $script:denied = $newDenied; $script:prevTime = $now
    if ($elapsedMs -gt 0) {
        foreach ($e in $byName.Values) {
            $e.CpuPct = [math]::Round(100 * $e.CpuMs / $elapsedMs / $cores, 1)
            $e.IoMBs = [math]::Round($e.IoB / 1MB / ($elapsedMs / 1000), 1)
        }
    }
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

function Get-Icon($name) {
    if ($script:icons.ContainsKey($name)) { return $script:icons[$name] }
    if ($script:icons.Count -ge 150) {   # 上限：满了就整体释放重来
        foreach ($b in $script:icons.Values) { if ($b) { $b.Dispose() } }
        $script:icons = @{}
    }
    $bmp = $null
    $r = $script:rows[$name]
    if ($r -and $name -notlike 'svc:*') {
        $path = [NativeInfo]::ImagePath([int]$r.Pid)
        if ($path -and (Test-Path -LiteralPath $path)) {
            try {
                $ico = [Drawing.Icon]::ExtractAssociatedIcon($path)
                try { $bmp = $ico.ToBitmap() } finally { $ico.Dispose() }   # 图标句柄立即释放，只留位图
            } catch { $bmp = $null }
        }
    }
    $script:icons[$name] = $bmp
    $bmp
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
$fCNbig = New-Object Drawing.Font('Microsoft YaHei UI', 12, [Drawing.FontStyle]::Bold)
$fTagB  = New-Object Drawing.Font('Bahnschrift SemiBold SemiConden', 10)
$fNum   = New-Object Drawing.Font('Bahnschrift SemiBold', 20)
$fHead  = New-Object Drawing.Font('Bahnschrift SemiBold', 18)
$fSmall = New-Object Drawing.Font('Bahnschrift', 8.5)
$Fonts  = @($fCN, $fCNb, $fCNbig, $fTagB, $fNum, $fHead, $fSmall)

$GDI = @{}   # 统一保存，关闭时一起释放
function Brush($name, $color) { $GDI[$name] = New-Object Drawing.SolidBrush($color) }
function Pen($name, $color, $w) { $GDI[$name] = New-Object Drawing.Pen($color, $w) }
Brush 'bg' $cBg; Brush 'panel' $cPanel; Brush 'rowA' $cRowA; Brush 'rowB' $cRowB; Brush 'dim' $cDim
Brush 'sel' (RGB 12 46 54); Brush 'leakRow' (RGB 78 14 22); Brush 'warnRow' (RGB 48 40 8)
Brush 'acc' $cAccent; Pen 'accPen' $cAccent 1; Pen 'accDim' $cRedDim 1
Pen 'scan' ([Drawing.Color]::FromArgb(12, 255, 90, 80)) 1
Pen 'grid' ([Drawing.Color]::FromArgb(150, 92, 30, 33)) 1
foreach ($l in 0, 1, 2, -1) {
    $c = $LevelColor[$l]
    Brush "lv$l" $c
    Pen "glow$l" ([Drawing.Color]::FromArgb(60, $c)) 7
    Pen "core$l" $c 2
    Brush "fill$l" ([Drawing.Color]::FromArgb(28, $c))
}
foreach ($l in 0, 1, 2) { $GDI["glow$l"].LineJoin = 'Round' }

$TF = [Windows.Forms.TextFormatFlags]
$tfL = $TF::Left -bor $TF::VerticalCenter -bor $TF::SingleLine -bor $TF::EndEllipsis -bor $TF::NoPrefix -bor $TF::NoPadding
$tfR = $TF::Right -bor $TF::VerticalCenter -bor $TF::SingleLine -bor $TF::NoPrefix -bor $TF::NoPadding
$tfC = $TF::HorizontalCenter -bor $TF::VerticalCenter -bor $TF::SingleLine -bor $TF::NoPrefix -bor $TF::NoPadding
$tfW = $TF::Left -bor $TF::Top -bor $TF::WordBreak -bor $TF::NoPrefix -bor $TF::NoPadding

function Txt($g, $s, $font, $color, $x, $y, $w, $h, $flags = $tfL) {
    [Windows.Forms.TextRenderer]::DrawText($g, [string]$s, $font, (New-Object Drawing.Rectangle([int]$x, [int]$y, [int]$w, [int]$h)), $color, $flags)
}
function TxtW($g, $s, $font) { [Windows.Forms.TextRenderer]::MeasureText($g, [string]$s, $font, (New-Object Drawing.Size(2000, 100)), $tfL).Width }
function TxtH($g, $s, $font, $w) { [Windows.Forms.TextRenderer]::MeasureText($g, [string]$s, $font, (New-Object Drawing.Size([int]$w, 1000)), $tfW).Height }

# 切角多边形（右上大切角，左下小切角）
function CutPoly($x, $y, $w, $h, $c) {
    [Drawing.PointF[]]@(
        (New-Object Drawing.PointF($x, $y)), (New-Object Drawing.PointF(($x + $w - $c), $y)),
        (New-Object Drawing.PointF(($x + $w), ($y + $c))), (New-Object Drawing.PointF(($x + $w), ($y + $h))),
        (New-Object Drawing.PointF(($x + $c / 2), ($y + $h))), (New-Object Drawing.PointF($x, ($y + $h - $c / 2)))
    )
}
function Scanlines($g, $w, $h) { for ($y = 2; $y -lt $h; $y += 3) { $g.DrawLine($GDI['scan'], 0, $y, $w, $y) } }
# 面板外框：底色 + 扫描线 + 珊瑚红切角框 + 标题
function Frame($g, $w, $h, $tag, $title) {
    $g.SmoothingMode = 'AntiAlias'
    $g.FillRectangle($GDI['bg'], 0, 0, $w, $h)
    $poly = CutPoly 0.5 0.5 ($w - 1.5) ($h - 1.5) 16
    $g.FillPolygon($GDI['panel'], $poly)
    Scanlines $g $w $h
    $g.DrawPolygon($GDI['accPen'], $poly)
    $g.FillRectangle($GDI['acc'], 0, 0, 46, 4)
    if ($tag) {
        Txt $g ('// ' + $tag) $fTagB $cAccent 12 8 160 22
        Txt $g $title $fCNb $cGray (18 + (TxtW $g ('// ' + $tag) $fTagB)) 8 160 22
    }
}

# ---------- 界面 ----------
$form = New-Object Windows.Forms.Form
$form.Text = 'WATCHDOG // 内存 · CPU · 磁盘 监控'
$form.Size = New-Object Drawing.Size(1320, 920)
$form.MinimumSize = New-Object Drawing.Size(1150, 860)
$form.StartPosition = 'CenterScreen'
$form.Font = $fCN
$form.BackColor = $cBg
$form.ForeColor = $cText

# 顶部标题条
$header = New-Object BufferedPanel
$header.Dock = 'Top'; $header.Height = 50
$header.Add_Paint({
    param($s, $e)
    $g = $e.Graphics; $w = $s.Width; $h = $s.Height
    $g.FillRectangle($GDI['bg'], 0, 0, $w, $h)
    Txt $g 'WATCHDOG' $fHead $cCyan 16 6 200 34
    Txt $g '// 内存 · CPU · 磁盘 监控终端' $fCN $cAccent 152 6 320 34
    $live = if ($script:tick % 2 -eq 0) { $GDI['lv2'] } else { $GDI['panel'] }
    $g.FillRectangle($live, $w - 250, 17, 8, 8)
    Txt $g ('LIVE  ' + (Get-Date).ToString('HH:mm')) $fTagB $cCyan ($w - 234) 6 90 28
    Txt $g 'SYS.MON v4 // 0x5744' $fSmall $cRedDim ($w - 200) 6 186 28 $tfR
    $g.FillRectangle($GDI['acc'], 0, $h - 3, $w, 1)
    $g.FillPolygon($GDI['acc'], [Drawing.PointF[]]@((New-Object Drawing.PointF(0, ($h - 6))), (New-Object Drawing.PointF(220, ($h - 6))), (New-Object Drawing.PointF(226, ($h - 2))), (New-Object Drawing.PointF(0, ($h - 2)))))
})

# 四张卡片
$cards = New-Object BufferedPanel
$cards.Dock = 'Top'; $cards.Height = 146; $cards.BackColor = $cBg

function New-Card($tag, $title, $code) {
    $p = New-Object BufferedPanel
    $p.Tag = @{ Code = $code; Tag = $tag; Title = $title; Value = '--'; Badge = '...'; Level = -1; Sub = ''; Pct = -1 }
    $p.Add_Paint({
        param($s, $e)
        $g = $e.Graphics; $w = $s.Width; $h = $s.Height; $d = $s.Tag
        Frame $g $w $h $d.Tag $d.Title
        $lvl = [int]$d.Level
        Txt $g $d.Code $fSmall $cRedDim ($w - 160) ($h - 17) 148 14 $tfR
        if ($d.Badge) {
            $bx = $w - 118; $by = 10
            $g.FillPolygon($GDI["lv$lvl"], [Drawing.PointF[]]@((New-Object Drawing.PointF(($bx + 8), $by)), (New-Object Drawing.PointF(($bx + 104), $by)), (New-Object Drawing.PointF(($bx + 96), ($by + 22))), (New-Object Drawing.PointF($bx, ($by + 22)))))
            Txt $g $d.Badge $fCNb $cBg $bx $by 104 22 $tfC
        }
        Txt $g $d.Value $fNum $cCyan 10 34 ($w - 20) 36
        if ($d.Pct -ge 0) {
            $n = 24; $gap = 3; $bw = ($w - 24 - $gap * ($n - 1)) / $n
            $on = [math]::Round($n * [math]::Min(100, $d.Pct) / 100)
            for ($i = 0; $i -lt $n; $i++) {
                $br = if ($i -lt $on) { $GDI["lv$lvl"] } else { $GDI['dim'] }
                $g.FillRectangle($br, [single](12 + $i * ($bw + $gap)), [single]76, [single]$bw, [single]8)
            }
        }
        Txt $g $d.Sub $fCN $cGray 12 90 ($w - 24) 20
    })
    $cards.Controls.Add($p)
    $p
}
$cardMem  = New-Card 'MEMORY' '内存' 'MEM-01 // 0x4D45'
$cardCpu  = New-Card 'CPU' '处理器' 'CPU-02 // 0x4350'
$cardDisk = New-Card 'DISK' '磁盘读写' 'DSK-03 // 0x4453'
$cardDog  = New-Card 'WATCHDOG' '看门狗' 'WDG-04 // 0x5744'
$cards.Add_Resize({
    $w = [int](($cards.ClientSize.Width - 60) / 4)
    $i = 0
    foreach ($c in @($cardMem, $cardCpu, $cardDisk, $cardDog)) { $c.SetBounds(12 + $i * ($w + 12), 6, $w, 134); $i++ }
})
function Set-Card($card, $value, $badge, $level, $sub, $pct) {
    $d = $card.Tag; $d.Value = $value; $d.Badge = $badge; $d.Level = $level; $d.Sub = $sub; $d.Pct = $pct
    $card.Invalidate()
}

# ---------- 右侧栏：告警 / 选中程序 / 操作 ----------
$side = New-Object Windows.Forms.Panel
$side.Dock = 'Right'; $side.Width = 360; $side.BackColor = $cBg; $side.Padding = New-Object Windows.Forms.Padding(0, 0, 12, 0)

$alertsPanel = New-Object BufferedPanel
$alertsPanel.Dock = 'Top'; $alertsPanel.Height = 150
$alertsPanel.Add_Paint({
    param($s, $e)
    $g = $e.Graphics; $w = $s.Width; $h = $s.Height
    Frame $g $w $h 'ALERTS' '告警'
    $y = 36
    foreach ($a in $script:alerts) {
        $c = if ($a[1] -eq 2) { $cRed } elseif ($a[1] -eq 1) { $cYellow } elseif ($a[1] -eq 0) { $cCyan } else { $cGray }
        $mark = if ($a[1] -eq 2 -or $a[1] -eq 1) { '▲' } elseif ($a[1] -eq 0) { '■' } else { '·' }
        Txt $g $mark $fCN $c 14 $y 14 20 ($TF::Left -bor $TF::Top -bor $TF::NoPadding)
        $th = TxtH $g $a[0] $fCN ($w - 46)
        if ($y + $th -gt $h - 8) { break }
        Txt $g $a[0] $fCN $c 30 $y ($w - 46) $th $tfW
        $y += $th + 6
    }
})

$detail = New-Object BufferedPanel
$detail.Dock = 'Top'; $detail.Height = 200
$detail.Add_Paint({
    param($s, $e)
    $g = $e.Graphics; $w = $s.Width; $h = $s.Height
    Frame $g $w $h 'TARGET' '选中的程序'
    $name = $script:selected
    $r = if ($name) { $script:rows[$name] } else { $null }
    if (-not $r) { Txt $g '在左边列表里点选一个程序，或右键它直接操作。' $fCN $cGray 14 40 ($w - 28) 40 $tfW; return }
    $icon = Get-Icon $name
    if ($icon) { $g.InterpolationMode = 'HighQualityBicubic'; $g.DrawImage($icon, 14, 38, 32, 32) }
    else { $g.FillRectangle($GDI['dim'], 14, 38, 32, 32); $g.DrawRectangle($GDI['accPen'], 14, 38, 32, 32) }
    Txt $g $name $fCNbig $cCyan 56 36 ($w - 70) 22
    Txt $g $(if ($Desc[$name]) { $Desc[$name] } else { '-' }) $fCN $cGray 56 58 ($w - 70) 18
    $st = Get-Status $name $r.PrivMB
    $lvl = if ($st[0] -eq '疑似泄漏') { 2 } elseif ($st[0] -eq '占用较大') { 1 } else { 0 }
    $cols = @(@('内存', ('{0:N0} MB' -f $r.PrivMB)), @('CPU', ('{0:N1} %' -f $r.CpuPct)), @('读写', ('{0:N1} MB/s' -f $r.IoMBs)), @('进程', [string]$r.Count))
    $cw = ($w - 28) / 4
    for ($i = 0; $i -lt 4; $i++) {
        Txt $g $cols[$i][0] $fCN $cGray (14 + $i * $cw) 82 $cw 16
        Txt $g $cols[$i][1] $fTagB $cText (14 + $i * $cw) 98 $cw 20
    }
    Txt $g ('状态：' + $st[0]) $fCNb $LevelColor[$lvl] 14 124 120 18
    Txt $g $(if ($st[1]) { $st[1] } else { Trend-Text $name }) $fCN $cGray 120 124 ($w - 134) 18
})

$actions = New-Object BufferedPanel
$actions.Dock = 'Fill'; $actions.AutoScroll = $true
$actions.Add_Paint({ param($s, $e); Frame $e.Graphics $s.Width $s.Height 'ACTIONS' '操作' })

# 赛博风格按钮（扁平 + 珊瑚红边框）
function New-Btn($parent, $text, $x, $y, $w, $onClick, [switch]$Primary) {
    $b = New-Object Windows.Forms.Button
    $b.Text = $text; $b.SetBounds($x, $y, $w, 32)
    $b.FlatStyle = 'Flat'; $b.Font = $fCNb; $b.Cursor = 'Hand'
    $b.BackColor = if ($Primary) { RGB 70 18 24 } else { $cPanel }
    $b.ForeColor = if ($Primary) { $cText } else { $cAccent }
    $b.FlatAppearance.BorderColor = $cAccent; $b.FlatAppearance.BorderSize = 1
    $b.FlatAppearance.MouseOverBackColor = RGB 12 46 54
    $b.FlatAppearance.MouseDownBackColor = RGB 20 70 82
    $b.Add_Click($onClick)
    $parent.Controls.Add($b)
    $b
}

$side.Controls.Add($actions)
$side.Controls.Add((New-Object Windows.Forms.Panel -Property @{ Dock = 'Top'; Height = 10; BackColor = $cBg }))
$side.Controls.Add($detail)
$side.Controls.Add((New-Object Windows.Forms.Panel -Property @{ Dock = 'Top'; Height = 10; BackColor = $cBg }))
$side.Controls.Add($alertsPanel)

# ---------- 主区域：程序列表 + 曲线 ----------
$main = New-Object Windows.Forms.Panel
$main.Dock = 'Fill'; $main.BackColor = $cBg; $main.Padding = New-Object Windows.Forms.Padding(12, 0, 12, 0)

$lv = New-Object BufferedListView
$lv.Dock = 'Fill'; $lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.HideSelection = $false; $lv.MultiSelect = $false
$lv.OwnerDraw = $true; $lv.BackColor = $cRowA; $lv.ForeColor = $cText; $lv.BorderStyle = 'None'
$rowH = New-Object Windows.Forms.ImageList; $rowH.ImageSize = New-Object Drawing.Size(1, 28); $lv.SmallImageList = $rowH
foreach ($c in @(@('程序', 180), @('说明', 150), @('内存 MB', 80), @('CPU %', 58), @('读写 MB/s', 78), @('状态', 78), @('24 小时变化', 140), @('备注', 160))) {
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
    if ($col -eq 0) {
        $icon = Get-Icon $it.Text
        $g.InterpolationMode = 'HighQualityBicubic'
        if ($icon) { $g.DrawImage($icon, $r.X + 8, $r.Y + 5, 18, 18) } else { $g.FillRectangle($GDI['dim'], $r.X + 11, $r.Y + 8, 12, 12) }
        if ($it.Selected) { $g.FillRectangle($GDI['lv0'], $r.X, $r.Y + 3, 3, $r.Height - 6) }
        Txt $g $it.Text $fCNb $cText ($r.X + 34) $r.Y ($r.Width - 40) $r.Height
        return
    }
    $io = 0.0; [void][double]::TryParse($it.SubItems[4].Text, [ref]$io)
    $c = switch ($col) {
        1 { $cGray }
        4 { if ($io -ge $HeavyIoMBs) { $cYellow } else { $cText } }
        5 { if ($st -eq '疑似泄漏') { $cRed } elseif ($st -eq '占用较大') { $cYellow } else { $cCyan } }
        6 { if ($st -eq '疑似泄漏') { $cRed } else { $cGray } }
        7 { if ($st -eq '疑似泄漏') { $cRed } else { $cGray } }
        default { $cText }
    }
    $f = if ($RightCols -contains $col) { $tfR } else { $tfL }
    $font = if ($col -eq 5) { $fCNb } else { $fCN }
    Txt $g $e.SubItem.Text $font $c ($r.X + 8) $r.Y ($r.Width - 16) $r.Height $f
})
function Fit-Columns {
    $n = $lv.Columns.Count; $sum = 0
    for ($i = 0; $i -lt $n - 1; $i++) { $sum += $lv.Columns[$i].Width }
    $want = [math]::Max(100, $lv.ClientSize.Width - $sum - 2)
    if ($lv.Columns[$n - 1].Width -ne $want) { $lv.Columns[$n - 1].Width = $want }
}
$lv.Add_Resize({ Fit-Columns })
$lv.Add_SelectedIndexChanged({
    if ($script:updating) { return }
    if ($lv.SelectedItems.Count -gt 0) { $script:selected = $lv.SelectedItems[0].Text; $chart.Invalidate(); $detail.Invalidate() }
})

$chart = New-Object BufferedPanel
$chart.Dock = 'Bottom'; $chart.Height = 200
$chart.Add_Paint({
    param($s, $e)
    $g = $e.Graphics; $w = $s.Width; $h = $s.Height
    $g.FillRectangle($GDI['bg'], 0, 0, $w, $h)
    $g.SmoothingMode = 'AntiAlias'
    $poly = CutPoly 0.5 10.5 ($w - 1.5) ($h - 12) 16
    $g.FillPolygon($GDI['panel'], $poly)
    Scanlines $g $w $h
    $g.DrawPolygon($GDI['accPen'], $poly)
    $g.FillRectangle($GDI['acc'], 0, 10, 46, 4)
    $name = $script:selected
    Txt $g '// MEM TRACE 24H' $fTagB $cAccent 12 18 160 20
    if (-not $name -or -not $script:hist.ContainsKey($name) -or $script:hist[$name].Count -lt 2) {
        $msg = if ($name) { "$name ：还没有足够的历史数据（看门狗每 10 分钟记录一次）" } else { '点选上方任意一个程序，这里显示它最近 24 小时的内存曲线（数据来自看门狗，每 10 分钟一个点）' }
        Txt $g $msg $fCN $cGray 14 46 ($w - 28) 24
        return
    }
    $pts = $script:hist[$name]
    $st = (Get-Status $name $pts[$pts.Count - 1].MB)[0]
    $lvl = if ($st -eq '疑似泄漏') { 2 } elseif ($st -eq '占用较大') { 1 } else { 0 }
    $title = '{0}  ·  {1}' -f $name, $(if ($Desc[$name]) { $Desc[$name] } else { '-' })
    Txt $g $title $fCNb $cText 150 18 ($w - 190) 20
    $L = 70; $R = 24; $T = 46; $B = 28
    $pw = $w - $L - $R; $ph = $h - $T - $B
    $end = Get-Date; $begin = $end.AddHours(-24)
    $max = 0.0; $min = [double]::MaxValue
    foreach ($p in $pts) { if ($p.MB -gt $max) { $max = $p.MB }; if ($p.MB -lt $min) { $min = $p.MB } }
    $lo = [math]::Max(0, $min - ($max - $min) * 0.15 - 10); $hi = $max + ($max - $min) * 0.15 + 10
    for ($i = 0; $i -le 3; $i++) {
        $y = $T + $ph * $i / 3
        $g.DrawLine($GDI['grid'], $L, $y, $L + $pw, $y)
        Txt $g ('{0:N0}' -f ($hi - ($hi - $lo) * $i / 3)) $fSmall $cGray 6 ($y - 9) ($L - 14) 18 $tfR
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
$main.Controls.Add($lv)
$main.Controls.Add((New-Object Windows.Forms.Panel -Property @{ Dock = 'Bottom'; Height = 6; BackColor = $cBg }))
$main.Controls.Add($chart)
$lv.BringToFront()

# 底部状态栏
$status = New-Object BufferedPanel
$status.Dock = 'Bottom'; $status.Height = 28
$status.Add_Paint({
    param($s, $e)
    $g = $e.Graphics; $w = $s.Width; $h = $s.Height
    $g.FillRectangle($GDI['bg'], 0, 0, $w, $h)
    $g.DrawLine($GDI['accDim'], 0, 0, $w, 0)
    $g.FillRectangle($GDI['acc'], 12, 10, 8, 8)
    $txt = '每 5 秒刷新 · 最小化时暂停 · 本窗口：内存 {0:N0} MB / CPU {1:N2}% / GDI {2} · 后台检查：每 10 分钟约 5 秒，查完即退出' -f $script:selfMB, $script:selfCpu, $script:selfGdi
    Txt $g $txt $fCN $cGray 28 0 ($w - 40) $h
})

$form.Controls.Add($main)
$form.Controls.Add($side)
$form.Controls.Add((New-Object Windows.Forms.Panel -Property @{ Dock = 'Top'; Height = 6; BackColor = $cBg }))
$form.Controls.Add($cards)
$form.Controls.Add($header)
$form.Controls.Add($status)
$main.BringToFront()

# 深色标题栏、深色滚动条（Windows 11）
$form.Add_HandleCreated({
    [NativeInfo]::Dwm($form.Handle, 20, 1)
    [NativeInfo]::Dwm($form.Handle, 35, 0x000C090E)   # 标题栏底色：红黑
    [NativeInfo]::Dwm($form.Handle, 36, 0x00575FFF)   # 标题文字：珊瑚红
    [NativeInfo]::Dwm($form.Handle, 34, 0x00575FFF)   # 窗口边框：珊瑚红
})
$lv.Add_HandleCreated({
    [void][NativeInfo]::SetWindowTheme($lv.Handle, 'DarkMode_Explorer', $null)
    $hdr = [NativeInfo]::SendMessage($lv.Handle, 0x101F, [IntPtr]::Zero, [IntPtr]::Zero)   # LVM_GETHEADER
    if ($hdr -ne [IntPtr]::Zero) { [void][NativeInfo]::SetWindowTheme($hdr, 'DarkMode_ItemsView', $null) }
})

# ---------- 操作 ----------
function Ask($msg) { [Windows.Forms.MessageBox]::Show($form, $msg, 'WATCHDOG', 'YesNo', 'Warning') -eq 'Yes' }
function Say($msg) { [void][Windows.Forms.MessageBox]::Show($form, $msg, 'WATCHDOG', 'OK', 'Information') }
function Run-Tool($file, $argText = '') {
    Start-Process powershell.exe -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "{0}" {1}' -f (Join-Path $ToolDir $file), $argText)
}
function Reload-Soon { $script:forceSlowAt = (Get-Date).AddSeconds(8) }
function Path-Of($name) { $r = $script:rows[$name]; if ($r) { [NativeInfo]::ImagePath([int]$r.Pid) } else { $null } }

# 重启一个程序（或服务）。$NoAsk 用于"一键处理"时已统一确认过。
function Restart-Target($name, [switch]$NoAsk) {
    if (-not $name) { Say '先在列表里选一个程序。'; return $false }
    if ($name -like 'svc:*') {
        $svc = $name.Substring(4)
        if (-not $NoAsk -and -not (Ask "将重启系统服务 $svc（需要管理员权限，会弹出确认窗口）。确定吗？")) { return $false }
        Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -ArgumentList "-NoProfile -Command Restart-Service '$svc' -Force"
        Reload-Soon; return $true
    }
    if ($Protected -contains $name) { Say "$name 是系统关键进程，不能在这里重启。"; return $false }
    $procs = @(Get-Process -Name $name -ErrorAction SilentlyContinue)
    if (-not $procs) { Say "$name 已经不在运行了。"; return $false }
    if ($procs.Id -contains $PID) { Say '这是监控窗口自己，关掉窗口再打开即可。'; return $false }
    $path = Path-Of $name
    if (-not $path) { Say "拿不到 $name 的程序路径（可能是管理员或系统进程），无法自动重新打开。"; return $false }
    if (-not $NoAsk -and -not (Ask ("将结束 {0}（{1} 个进程）并重新打开：`n{2}`n`n这个程序里没保存的内容可能会丢失。确定吗？" -f $name, $procs.Count, $path))) { return $false }
    $failed = 0
    foreach ($p in $procs) { try { $p.Kill() } catch { $failed++ } finally { $p.Dispose() } }
    if ($failed) { Say "$name 有 $failed 个进程结束失败（可能需要管理员权限）。"; return $false }
    Start-Sleep -Seconds 2
    if (-not (Get-Process -Name $name -ErrorAction SilentlyContinue)) { Start-Process -FilePath $path -WorkingDirectory (Split-Path $path) }
    Reload-Soon; return $true
}
function Kill-Target($name) {
    if (-not $name) { Say '先在列表里选一个程序。'; return }
    if ($name -like 'svc:*' -or $Protected -contains $name) { Say "$name 是系统服务或关键进程，不能在这里结束。"; return }
    $procs = @(Get-Process -Name $name -ErrorAction SilentlyContinue)
    if (-not $procs) { return }
    if ($procs.Id -contains $PID) { Say '这是监控窗口自己。'; return }
    if (-not (Ask ("将结束 {0}（{1} 个进程），不会自动重新打开。没保存的内容可能会丢失。确定吗？" -f $name, $procs.Count))) { return }
    $failed = 0
    foreach ($p in $procs) { try { $p.Kill() } catch { $failed++ } finally { $p.Dispose() } }
    if ($failed) { Say "有 $failed 个进程结束失败（可能需要管理员权限）。" }
}
function Open-Location($name) {
    $path = Path-Of $name
    if ($path) { Start-Process explorer.exe "/select,`"$path`"" } else { Say '拿不到这个程序的路径。' }
}
function Fix-Leaks {
    $targets = @(foreach ($r in $script:rows.Values) { if ((Get-Status $r.Name $r.PrivMB)[0] -eq '疑似泄漏' -and $Protected -notcontains $r.Name) { $r.Name } })
    if (-not $targets) { Say '现在没有疑似内存泄漏的程序，不需要处理。'; return }
    if (-not (Ask ("将重启下面这些疑似泄漏的程序，释放它们占着的内存：`n`n  " + ($targets -join "`n  ") + "`n`n这些程序里没保存的内容可能会丢失。确定吗？"))) { return }
    $ok = 0; foreach ($t in $targets) { if (Restart-Target $t -NoAsk) { $ok++ } }
    Say "已处理 $ok / $($targets.Count) 个。"
}
function Run-CheckNow {
    if ($script:taskState) { Start-ScheduledTask -TaskName 'MemWatchdog'; Say '已开始检查，大约 5 秒后完成，结果会自动刷新到界面上。' }
    else { Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $ToolDir 'MemWatchdog.ps1')) }
    Reload-Soon
}

# 右键菜单
$menu = New-Object Windows.Forms.ContextMenuStrip
$menu.Renderer = New-Object Windows.Forms.ToolStripProfessionalRenderer((New-Object CyberColors))
$menu.Font = $fCN; $menu.ForeColor = $cText
foreach ($m in @(@('重启这个程序', { [void](Restart-Target $script:selected) }), @('结束这个程序', { Kill-Target $script:selected }), @('打开文件位置', { Open-Location $script:selected }))) {
    $item = $menu.Items.Add($m[0]); $item.ForeColor = $cText; $item.Add_Click($m[1])
}
$menu.Add_Opening({ param($s, $e); if (-not $script:selected) { $e.Cancel = $true } })
$lv.ContextMenuStrip = $menu

# 选中程序的按钮
$bw = 104
$btnRestart = New-Btn $detail '重启' 14 154 $bw { [void](Restart-Target $script:selected) } -Primary
$btnKill    = New-Btn $detail '结束' (14 + $bw + 8) 154 $bw { Kill-Target $script:selected }
$btnOpen    = New-Btn $detail '打开位置' (14 + 2 * ($bw + 8)) 154 $bw { Open-Location $script:selected }

# 操作区按钮
$ax = 14; $aw = 320; $ay = 36; $step = 38
$btnFix  = New-Btn $actions '一键处理疑似泄漏的程序' $ax $ay $aw { Fix-Leaks } -Primary; $ay += $step
$btnNow  = New-Btn $actions '立即运行一次看门狗检查' $ax $ay $aw { Run-CheckNow }; $ay += $step
$btnNv   = New-Btn $actions '修复 NVIDIA 数据库（显示容器占内存 / 狂写硬盘）' $ax $ay $aw { if (Ask '将停止并重建 NVIDIA 的 nvtopps 数据库，屏幕可能闪一下。需要管理员权限。确定吗？') { Run-Tool 'Fix-NvTopps.ps1'; Reload-Soon } }; $ay += $step
$btnSsOn = New-Btn $actions 'Sonic Studio 开' $ax $ay 156 { Run-Tool 'SonicStudio.ps1' '-Mode On' }
$btnSsOff = New-Btn $actions 'Sonic Studio 关' ($ax + 164) $ay 156 { Run-Tool 'SonicStudio.ps1' '-Mode Off' }; $ay += $step
$btnInstall = New-Btn $actions '安装看门狗（每 10 分钟自动检查）' $ax $ay $aw {
    if ($script:taskState) { if (Ask '将删除看门狗计划任务，之后不再自动检查。确定吗？') { Run-Tool 'Install-Watchdog.ps1' '-Uninstall' } }
    else { Run-Tool 'Install-Watchdog.ps1' }
    $script:forceSlowAt = (Get-Date).AddSeconds(15)
}; $ay += $step
$btnFolder = New-Btn $actions '打开工具文件夹 / 日志' $ax $ay $aw { Start-Process explorer.exe "`"$ToolDir`"" }
$side.Add_Resize({ foreach ($b in @($btnFix, $btnNow, $btnNv, $btnInstall, $btnFolder)) { $b.Width = $side.ClientSize.Width - 12 - 28 } })

# ---------- 刷新 ----------
function Refresh-All {
    if ($form.WindowState -eq [Windows.Forms.FormWindowState]::Minimized) { return }
    $script:tick++
    $now = Get-Date
    if ($script:forceSlowAt -and $now -ge $script:forceSlowAt) { $script:forceSlowAt = $null; $script:lastSlow = [datetime]::MinValue; $script:histSig = '' }
    if (($now - $script:lastSlow).TotalSeconds -ge 60) { $script:lastSlow = $now; Update-Slow }

    # 内存
    $m = [NativeInfo]::Mem()
    $totalGB = $m.ullTotalPhys / 1GB; $usedGB = ($m.ullTotalPhys - $m.ullAvailPhys) / 1GB
    $pct = 100 * $usedGB / $totalGB
    $commitGB = ($m.ullTotalPageFile - $m.ullAvailPageFile) / 1GB; $limitGB = $m.ullTotalPageFile / 1GB
    $cpct = 100 * $commitGB / $limitGB
    $worst = [math]::Max($pct, $cpct)
    $lvl = if ($worst -lt 70) { 0 } elseif ($worst -lt 85) { 1 } else { 2 }
    Set-Card $cardMem ('{0:N1} / {1:N0} GB' -f $usedGB, $totalGB) ('{0}  {1:N0}%' -f (@('正常', '偏高', '紧张')[$lvl]), $pct) $lvl ('已提交 {0:N1} / {1:N0} GB · 70% 以下都算正常' -f $commitGB, $limitGB) $pct

    # CPU（最近 30 秒平均）
    $script:cpuHist.Enqueue([NativeInfo]::Cpu())
    while ($script:cpuHist.Count -gt 6) { [void]$script:cpuHist.Dequeue() }
    $cpuAvg = ($script:cpuHist | Measure-Object -Average).Average
    $procs = Sample-Processes
    $rows = @($procs | Where-Object { $_.Name -ne 'Idle' -and $_.Name -ne 'Memory Compression' })
    $byName = @{}; foreach ($r in $rows) { $byName[$r.Name] = $r }
    $script:rows = $byName
    $real = @($rows | Where-Object { $_.Name -notlike 'svc:*' })
    $busy = @($real | Sort-Object CpuPct -Descending | Select-Object -First 2)
    $lvl = if ($cpuAvg -lt 50) { 0 } elseif ($cpuAvg -lt 85) { 1 } else { 2 }
    Set-Card $cardCpu ('{0:N0} %' -f $cpuAvg) (@('正常', '较忙', '很忙')[$lvl]) $lvl ('最忙：' + (($busy | ForEach-Object { '{0} {1:N1}%' -f $_.Name, $_.CpuPct }) -join '，')) $cpuAvg

    # 磁盘
    $script:disk = [DiskPerf]::Read()
    $rd = $script:disk[0] / 1MB; $wr = $script:disk[1] / 1MB; $busyPct = $script:disk[2]
    $topIo = @($real | Sort-Object IoMBs -Descending | Select-Object -First 1)
    $lvl = if ($busyPct -lt 60) { 0 } elseif ($busyPct -lt 90) { 1 } else { 2 }
    $ioSub = if ($topIo -and $topIo[0].IoMBs -ge 0.1) { '读写最多：{0} {1:N1} MB/s' -f $topIo[0].Name, $topIo[0].IoMBs } else { '没有程序在大量读写' }
    Set-Card $cardDisk ('R {0:N1}  W {1:N1} MB/s' -f $rd, $wr) ('{0}  {1:N0}%' -f (@('正常', '较忙', '很忙')[$lvl]), $busyPct) $lvl $ioSub $busyPct

    # 看门狗
    $last = if ($script:sys.Count -gt 0) { $script:sys[$script:sys.Count - 1] } else { $null }
    if (-not $script:taskState) {
        Set-Card $cardDog '未安装' '离线' 1 '在右侧"操作"里安装后每 10 分钟检查' -1
    } elseif (-not $last) {
        Set-Card $cardDog '等待首次检查' '待命' 1 '已安装，第一次检查完成后显示结果' -1
    } else {
        $lt = [datetime]::ParseExact($last.Time, 'yyyy-MM-dd HH:mm:ss', $null)
        $mins = ($now - $lt).TotalMinutes
        $ok = $mins -le 25
        Set-Card $cardDog ('上次 ' + (Ago $lt)) $(if ($ok) { '运行中' } else { '可能停了' }) $(if ($ok) { 0 } else { 2 }) ('每次约 {0:N1} 秒 · 进度条 = 距下次检查' -f ([double]$last.RunMs / 1000)) ([math]::Min(100, $mins * 10))
    }

    # 告警
    $alerts = @()
    $suspects = @(foreach ($r in $real) { if ((Get-Status $r.Name $r.PrivMB)[0] -eq '疑似泄漏') { '{0}（{1:+#,0} MB/小时）' -f $r.Name, $script:analysis[$r.Name].Slope } })
    foreach ($r in $rows) { if ($r.Name -like 'svc:*' -and (Get-Status $r.Name $r.PrivMB)[0] -eq '疑似泄漏') { $suspects += '{0}（{1:+#,0} MB/小时）' -f $Desc[$r.Name], $script:analysis[$r.Name].Slope } }
    if ($suspects.Count -gt 0) { $alerts += , @(('疑似内存泄漏：' + ($suspects -join '、') + '。可以用"一键处理"重启它们。'), 2) }
    if ($script:nvMB -gt 300) { $alerts += , @(("NVIDIA 的 nvtopps.db3 已经 $($script:nvMB) MB（正常只有几 MB），会让显示容器占大量内存、狂写硬盘。"), 2) }
    foreach ($r in @($real | Where-Object { $_.IoMBs -ge $HeavyIoMBs } | Sort-Object IoMBs -Descending | Select-Object -First 2)) { $alerts += , @(('{0} 正在大量读写：{1:N0} MB/s。偶尔一下正常，一直这样就要注意。' -f $r.Name, $r.IoMBs), 1) }
    if ($script:hist.Count -eq 0) { $alerts += , @('还没有历史数据：看门狗安装后每 10 分钟记录一次，大约 2 小时后开始判断内存泄漏。', 1) }
    elseif ($alerts.Count -eq 0) { $alerts += , @('一切正常：最近 24 小时没有发现持续上涨的程序。', 0) }
    if ($script:lastAction) { $alerts += , @(('看门狗最近一次动作：' + $script:lastAction), -1) }
    $script:alerts = $alerts
    $alertsPanel.Invalidate()

    # 程序列表：内存前 25，加上不在前 25 但状态异常或读写很大的
    $list = @($real | Sort-Object PrivMB -Descending | Select-Object -First 25)
    $inList = @{}; foreach ($r in $list) { $inList[$r.Name] = 1 }
    foreach ($r in $rows) { if (-not $inList.ContainsKey($r.Name) -and ((Get-Status $r.Name $r.PrivMB)[0] -ne '正常' -or $r.IoMBs -ge $HeavyIoMBs)) { $list += $r; $inList[$r.Name] = 1 } }
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
            [void]$it.SubItems.Add(('{0:N1}' -f $r.IoMBs))
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
    try {
        $script:selfMB = $me.PrivateMemorySize64 / 1MB
        $script:selfGdi = [NativeInfo]::GetGuiResources($me.Handle, 0)
        $cpuNow = $me.TotalProcessorTime.TotalMilliseconds; $tNow = [DateTime]::UtcNow
        if ($script:selfPrevCpu) { $script:selfCpu = 100 * ($cpuNow - $script:selfPrevCpu[0]) / ($tNow - $script:selfPrevCpu[1]).TotalMilliseconds / [Environment]::ProcessorCount }
        $script:selfPrevCpu = @($cpuNow, $tNow)
    } finally { $me.Dispose() }
    $header.Invalidate(); $status.Invalidate(); $chart.Invalidate(); $detail.Invalidate()
}

function Dispose-All {
    [DiskPerf]::Close()
    foreach ($o in $GDI.Values) { $o.Dispose() }
    foreach ($f in $Fonts) { $f.Dispose() }
    foreach ($b in $script:icons.Values) { if ($b) { $b.Dispose() } }
    $rowH.Dispose(); $menu.Dispose()
}

# 先取一次基准，CPU / 磁盘 / 读写速度才能算出差值
[void][DiskPerf]::Open()
[void][NativeInfo]::Cpu(); [void](Sample-Processes)

if ($SelfTest) {
    Start-Sleep -Milliseconds 800
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
            $mem += '第 {0} 次刷新+重绘后：本程序 {1:N1} MB，托管堆 {2:N1} MB，句柄 {3}，GDI 对象 {4}，USER 对象 {5}，图标缓存 {6}' -f $i, ($me.PrivateMemorySize64 / 1MB), ([GC]::GetTotalMemory($true) / 1MB), $me.HandleCount, [NativeInfo]::GetGuiResources($me.Handle, 0), [NativeInfo]::GetGuiResources($me.Handle, 1), $script:icons.Count
            $me.Dispose()
        }
    }
    if ($Snapshot) { $bmp.Save($Snapshot, [Drawing.Imaging.ImageFormat]::Png) }
    $bmp.Dispose()
    foreach ($c in @($cardMem, $cardCpu, $cardDisk, $cardDog)) { '{0}: {1} [{2}] {3}' -f $c.Tag.Tag, $c.Tag.Value, $c.Tag.Badge, $c.Tag.Sub }
    '告警: ' + ((@(foreach ($a in $script:alerts) { $a[0] })) -join ' / ')
    '--- 自身资源 ---'
    $mem
    $form.Close(); $form.Dispose(); Dispose-All
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
