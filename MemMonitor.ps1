# MemMonitor：内存 / CPU / 磁盘 监控面板（赛博朋克风格界面：红黑底 + 荧光蓝）
# 和任务管理器的区别：不只看"现在谁占得多"，而是看"谁在变坏、为什么、怎么修"——
#   1. 稳定性评级：窗口打开 10 分钟后用实时数据给出初步判断；看门狗记录满 1 小时后给出长期判断（含疑似泄漏）
#   2. 问题规则库：rules.json（公共）+ rules.local.json（自己的）写明"症状 → 原因 → 修复方法"，命中就给出修复按钮
# 只在打开时运行，关掉窗口就完全退出。每 5 秒刷新一次。
# 实时数据存在固定大小的环形缓存里（每条最多 1 小时 / 720 个点，最多 150 条），不会越用越大。
# 所有画笔 / 画刷 / 字体只在启动时创建一次；系统句柄（进程、磁盘计数器）用完立即关闭；图标缓存有上限。
#   -SelfTest -Loops N [-Snapshot x.png] [-Select 程序名] [-StartChart mem|cpu|disk|dog|proc] [-StartRange 30m|1h|3h|12h|24h] : 在屏幕外显示窗口，连续刷新并重绘 N 次
param(
    [string]$DataDir = (Join-Path $PSScriptRoot 'data'),
    [string]$RulesDir = $PSScriptRoot,
    [switch]$SelfTest,
    [int]$Loops = 1,
    [string]$Snapshot,
    [string]$Select,
    [string]$StartChart = 'mem',
    [string]$StartRange = '30m',
    [int]$SimMinutes = 0,         # 仅自测：预先填入最近 N 分钟的模拟实时数据
    [string]$SimRising = ''       # 仅自测：让这个程序在模拟数据里持续上涨
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic
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
    [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr h);
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
// 固定大小的环形缓存：满了就覆盖最旧的点，所以内存占用有上限。
public class Ring {
    long[] t; float[] v; int head, n, cap;
    public DateTime LastSeen;
    public Ring(int capacity) { cap = capacity; t = new long[cap]; v = new float[cap]; }
    public void Add(DateTime when, double val) {
        int i;
        if (n < cap) { i = (head + n) % cap; n++; } else { i = head; head = (head + 1) % cap; }
        t[i] = when.Ticks; v[i] = (float)val; LastSeen = when;
    }
    public int Count { get { return n; } }
    public long TimeAt(int k) { return t[(head + k) % cap]; }
    public float ValueAt(int k) { return v[(head + k) % cap]; }
    // 内存趋势（只看最近一次重启之后：值骤降 40% 以上或断档超过 gapSec 秒视为重启）
    // 返回 [每小时变化 MB, R², 累计变化, 时长(小时), 波动系数, 点数]；数据不够返回 null
    public double[] Stats(double gapSec) {
        if (n < 3) return null;
        int s = 0;
        for (int k = 1; k < n; k++) {
            if (ValueAt(k) < 0.6 * ValueAt(k - 1) || (TimeAt(k) - TimeAt(k - 1)) / 1e7 > gapSec) s = k;
        }
        int m = n - s;
        if (m < 3) return null;
        double t0 = TimeAt(s), sx = 0, sy = 0, sxx = 0, sxy = 0, syy = 0;
        for (int k = s; k < n; k++) {
            double x = (TimeAt(k) - t0) / 36e9, y = ValueAt(k);
            sx += x; sy += y; sxx += x * x; sxy += x * y; syy += y * y;
        }
        double span = (TimeAt(n - 1) - t0) / 36e9;
        double den = m * sxx - sx * sx;
        if (den <= 0) return null;
        double num = m * sxy - sx * sy, vy = m * syy - sy * sy;
        double r2 = vy > 0 ? (num * num) / (den * vy) : 0;
        double mean = sy / m;
        double cv = mean > 0 ? Math.Sqrt(Math.Max(0, syy / m - mean * mean)) / mean : 0;
        return new double[] { num / den, r2, ValueAt(n - 1) - ValueAt(s), span, cv, m };
    }
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

# 稳定性判断标准
# 长期（看门狗记录 ≥ 1 小时）
$LeakSlopeMBh = 50; $LeakGrowthMB = 100; $LeakR2 = 0.6     # 疑似泄漏
$RiseSlopeMBh = 15; $RiseGrowthMB = 40;  $RiseR2 = 0.5     # 缓慢上涨
# 短期（窗口实时数据 ≥ 10 分钟）：只给初步判断，不下"泄漏"结论
$ShortMinHours = 10 / 60
$ShortSlopeMBh = 60; $ShortGrowthMB = 30; $ShortR2 = 0.8   # 短时上涨
$WobbleCv     = 0.15   # 波动大：波动幅度超过平均值的 15%
$HeavyIoMBs   = 30     # 单个程序读写超过这个速度会提示
$RingSize     = 720    # 每条实时数据最多 720 个点（5 秒一个 = 1 小时）
$MaxSeries    = 150    # 最多同时记录 150 条

# ---------- 状态（每次刷新都整体替换，不累积） ----------
$script:prevCpu   = @{}; $script:prevIo = @{}; $script:prevTime = $null; $script:denied = @{}
$script:cpuHist   = New-Object 'System.Collections.Generic.Queue[double]'
$script:hist      = @{}; $script:analysis = @{}; $script:sys = @(); $script:histSig = ''
$script:lastSlow  = [datetime]::MinValue; $script:forceSlowAt = $null
$script:svcPid    = @{}; $script:taskState = $null; $script:lastAction = ''
$script:rules     = @(); $script:rulesSig = ''; $script:fileMB = @{}; $script:watched = @{}
$script:hits      = @(); $script:hitByTarget = @{}
$script:selected  = if ($Select) { $Select } else { $null }
$script:chartMode = $StartChart; $script:chartRange = $StartRange; $script:rangeRects = @()
# 走势图可选的时间范围（小时）。默认近 30 分钟
$RangeHours = [ordered]@{ '30m' = 0.5; '1h' = 1; '3h' = 3; '12h' = 12; '24h' = 24 }
$RangeLabel = @{ '30m' = '30 分钟'; '1h' = '1 小时'; '3h' = '3 小时'; '12h' = '12 小时'; '24h' = '24 小时' }
$script:updating  = $false; $script:tick = 0; $script:sortMode = 'issue'
$script:selfMB = 0; $script:selfGdi = 0; $script:selfCpu = 0.0; $script:selfPrevCpu = $null
$script:issues    = @(); $script:verdict = @('正在检查…', -1, ''); $script:issueRects = @()
$script:rows = @{}; $script:ratings = @{}; $script:disk = @(0, 0, 0)
$script:series    = @{}   # 实时数据：名字 -> Ring（程序内存，以及 sys:mem / sys:cpu / sys:dr / sys:dw / sys:self）
$script:icons     = @{}   # 程序名 -> 32px 图标（Bitmap 或 $null），上限 150 个
$script:ignores   = @{}; $script:ignoreSig = $null   # 用户忽略 / 确认正常的问题

# ---------- 数据 ----------
# 看门狗历史（10 分钟一个点）的趋势，至少 1 小时
function Analyze($pts) {
    $n = $pts.Count
    if ($n -lt 6) { return $null }
    $start = 0
    for ($i = 1; $i -lt $n; $i++) {
        if ($pts[$i].MB -lt 0.6 * $pts[$i - 1].MB -or ($pts[$i].T - $pts[$i - 1].T).TotalMinutes -gt 60) { $start = $i }
    }
    $m = $n - $start
    if ($m -lt 6) { return $null }
    $t0 = $pts[$start].T
    $span = ($pts[$n - 1].T - $t0).TotalHours
    if ($span -lt 1) { return $null }
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
    $mean = $sy / $m
    $cv = if ($mean -gt 0) { [math]::Sqrt([math]::Max(0, $syy / $m - $mean * $mean)) / $mean } else { 0 }
    [pscustomobject]@{ Slope = $num / $den; R2 = $r2; Growth = $pts[$n - 1].MB - $pts[$start].MB; Span = $span; Cv = $cv }
}

function Load-History {
    if (-not (Test-Path $DataDir)) { $script:hist = @{}; $script:analysis = @{}; $script:sys = @(); return }
    $pf = @(Get-ChildItem $DataDir -Filter 'proc-*.csv' | Sort-Object Name | Select-Object -Last 2)
    $sf = @(Get-ChildItem $DataDir -Filter 'sys*.csv' | Sort-Object LastWriteTime | Select-Object -Last 4)
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
    # sys-*.csv（旧格式）和 sysv2-*.csv（多了磁盘列）合并，按时间排序
    $s = @(foreach ($f in $sf) { foreach ($r in (Import-Csv $f.FullName)) { $t = [datetime]::ParseExact($r.Time, 'yyyy-MM-dd HH:mm:ss', $null); if ($t -ge $cut) { $r | Add-Member -NotePropertyName T -NotePropertyValue $t -PassThru } } })
    $script:sys = @($s | Sort-Object T)
}

function Load-Rules {
    $files = @(foreach ($n in 'rules.json', 'rules.local.json') { $p = Join-Path $RulesDir $n; if (Test-Path $p) { Get-Item $p } })
    $sig = ($files | ForEach-Object { '{0}:{1}' -f $_.Name, $_.LastWriteTimeUtc.Ticks }) -join '|'
    if ($sig -eq $script:rulesSig) { return }
    $script:rulesSig = $sig
    $all = @()
    # PowerShell 5.1 把 JSON 数组当成一个整体返回，用 foreach 拆成单条规则
    foreach ($f in $files) { try { foreach ($r in (ConvertFrom-Json (Get-Content $f.FullName -Raw -Encoding UTF8))) { $all += $r } } catch {} }
    $script:rules = $all
    $w = @{}; foreach ($r in $all) { if ($r.id -like 'watch-*' -and $r.when.process) { $w[$r.when.process] = $r } }
    $script:watched = $w
}

function Update-Slow {
    # 每分钟一次：规则、历史数据、服务进程号、计划任务状态、最近动作、规则里的文件大小、清理过期的实时数据
    Load-Rules
    Load-Ignores
    Load-History
    $svcNames = @($script:rules | ForEach-Object { $_.when.process } | Where-Object { $_ -like 'svc:*' } | ForEach-Object { $_.Substring(4) } | Sort-Object -Unique)
    $map = @{}
    if ($svcNames) {
        $filter = ($svcNames | ForEach-Object { "Name='$_'" }) -join ' OR '
        foreach ($s in (Get-CimInstance Win32_Service -Filter $filter -ErrorAction SilentlyContinue)) { if ($s.ProcessId -gt 0) { $map[[int]$s.ProcessId] = "svc:$($s.Name)" } }
    }
    $script:svcPid = $map
    $t = Get-ScheduledTask -TaskName 'MemWatchdog' -ErrorAction SilentlyContinue
    $script:taskState = if ($t) { [string]$t.State } else { $null }
    $script:lastAction = ''
    if (Test-Path $LogFile) {
        $hit = Get-Content $LogFile -Tail 200 -Encoding UTF8 | Where-Object { $_ -match 'FIX|NOTICE|RESTART|REBUILD|HIGH' } | Select-Object -Last 1
        if ($hit) { $script:lastAction = $hit }
    }
    $fm = @{}
    foreach ($r in $script:rules) { $f = $r.when.file; if ($f -and -not $fm.ContainsKey($f)) { $fm[$f] = if (Test-Path -LiteralPath $f) { [int]((Get-Item -LiteralPath $f).Length / 1MB) } else { $null } } }
    $script:fileMB = $fm
    # 15 分钟没出现的程序，丢掉它的实时数据
    $old = (Get-Date).AddMinutes(-15)
    foreach ($k in @($script:series.Keys)) { if ($k -notlike 'sys:*' -and $script:series[$k].LastSeen -lt $old) { $script:series.Remove($k) } }
    if ($btnInstall) { Set-Text $btnInstall $(if ($script:taskState) { '卸载看门狗' } else { '安装看门狗' }) }
}

function Record($name, $value, $now) {
    $r = $script:series[$name]
    if (-not $r) {
        if ($script:series.Count -ge $MaxSeries) {   # 满了：丢掉最久没出现的那条
            $oldest = $null
            foreach ($k in $script:series.Keys) { if ($k -notlike 'sys:*' -and (-not $oldest -or $script:series[$k].LastSeen -lt $script:series[$oldest].LastSeen)) { $oldest = $k } }
            if ($oldest) { $script:series.Remove($oldest) }
        }
        $r = New-Object Ring($RingSize); $script:series[$name] = $r
    }
    $r.Add($now, $value)
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

# 规则命中：when 里的条件全部满足才算
function Eval-Rules {
    $hits = @(); $byT = @{}
    foreach ($r in $script:rules) {
        $w = $r.when; $why = @()
        if ($w.process) {
            $row = $script:rows[$w.process]
            if (-not $row) { continue }
            if ($w.minMB) { if ($row.PrivMB -lt $w.minMB) { continue }; $why += ('现在 {0:N0} MB，超过上限 {1} MB' -f $row.PrivMB, $w.minMB) }
        }
        if ($w.file) {
            $fmb = $script:fileMB[$w.file]
            if ($null -eq $fmb) { continue }
            if ($w.minFileMB) { if ($fmb -lt $w.minFileMB) { continue }; $why += ('{0} 已经 {1:N0} MB，超过上限 {2} MB' -f (Split-Path $w.file -Leaf), $fmb, $w.minFileMB) }
        }
        if (-not $why) { continue }
        if (Is-Ignored "rule:$($r.id)") { continue }   # 用户选了忽略 / 确认正常
        $t = if ($r.target) { $r.target } else { $w.process }
        $h = [pscustomobject]@{ Rule = $r; Why = ($why -join '；'); Target = $t }
        $hits += $h
        if ($t -and -not $byT.ContainsKey($t)) { $byT[$t] = $h }
    }
    $script:hits = $hits; $script:hitByTarget = $byT
}

function Fmt-MB($mb) { if ($mb -ge 1024) { '{0:N1} GB' -f ($mb / 1024) } else { '{0:N0} MB' -f $mb } }
# [int]：裸写的 -1 当参数传进来会变成字符串 "-1"，比较大小会出错
function New-Rating($text, [int]$level, [int]$score, $note, $forecast, $trend) { [pscustomobject]@{ Text = $text; Level = $level; Score = $score; Note = $note; Forecast = $forecast; Trend = $trend } }

# ---- 忽略 / 确认正常（ignore.json，个人设置，不进 git）----
# key：rule:<规则 id> / prog:<程序名>（稳定性问题） / io:<程序名>（大量读写）
# type：snooze = 忽略 24 小时（until 到期后恢复提醒）；normal = 确认正常，不再提醒
function Ignore-Path { Join-Path $RulesDir 'ignore.json' }
function Load-Ignores {
    $p = Ignore-Path
    $sig = if (Test-Path $p) { (Get-Item $p).LastWriteTimeUtc.Ticks } else { 0 }
    if ($sig -eq $script:ignoreSig) { return }
    $script:ignoreSig = $sig
    $m = @{}
    if (Test-Path $p) { try { foreach ($i in (ConvertFrom-Json (Get-Content $p -Raw -Encoding UTF8))) { $m[$i.key] = $i } } catch {} }
    $script:ignores = $m
}
function Save-Ignores {
    $now = Get-Date
    $list = @($script:ignores.Values | Where-Object { $_.type -ne 'snooze' -or [datetime]$_.until -gt $now })
    [IO.File]::WriteAllText((Ignore-Path), (ConvertTo-Json -InputObject $list -Depth 4), (New-Object Text.UTF8Encoding $false))
    $script:ignoreSig = $null; Load-Ignores
}
function Is-Ignored($key) {
    if (-not $key) { return $null }
    $i = $script:ignores[$key]
    if (-not $i) { return $null }
    if ($i.type -eq 'snooze' -and [datetime]$i.until -lt (Get-Date)) { return $null }
    $i
}
function Ignore-Issue($key, $label, [switch]$Normal) {
    if (-not $key) { return }
    $script:ignores[$key] = [pscustomobject][ordered]@{
        key = $key; label = $label
        type = $(if ($Normal) { 'normal' } else { 'snooze' })
        until = $(if ($Normal) { '' } else { (Get-Date).AddHours(24).ToString('yyyy-MM-ddTHH:mm:ss') })
    }
    Save-Ignores; Refresh-All
}
function Unignore-Name($name) {
    foreach ($k in @($script:ignores.Keys)) {
        if ($k -eq "prog:$name" -or $k -eq "io:$name") { $script:ignores.Remove($k) }
        elseif ($k -like 'rule:*') { $r = $script:rules | Where-Object { "rule:$($_.id)" -eq $k } | Select-Object -First 1; if ($r -and ($r.target -eq $name -or $r.when.process -eq $name)) { $script:ignores.Remove($k) } }
    }
    Save-Ignores; Refresh-All
}
function Ignore-Note($i) { if ($i.type -eq 'normal') { '你已确认正常，不再提醒' } else { '已忽略，{0} 后恢复提醒' -f ([datetime]$i.until).ToString('MM-dd HH:mm') } }

# 稳定性评级（加上用户的忽略设置）
function Get-Rating($name, $mb) {
    $rt = Get-RatingRaw $name $mb
    if ($rt.Level -ge 1 -and $rt.Text -ne '已知问题') {
        $ig = Is-Ignored "prog:$name"
        if ($ig) { return (New-Rating $rt.Text -1 0 (Ignore-Note $ig) '' $rt.Trend) }
    }
    $rt
}

# 稳定性评级。Level：2 = 有问题（红）、1 = 需要留意（黄）、0 = 正常（蓝）、-1 = 中性（灰）。Score 用于"问题优先"排序。
# 优先用看门狗的长期记录（≥ 1 小时）；没有的话用窗口的实时数据（≥ 10 分钟）给初步判断。
function Get-RatingRaw($name, $mb) {
    $hit = $script:hitByTarget[$name]
    if ($hit) {
        $lvl = if ($hit.Rule.fix.type -eq 'none') { 1 } else { 2 }
        return (New-Rating '已知问题' $lvl (100 + 5 * $lvl) $hit.Rule.title '' '')
    }
    $a = $script:analysis[$name]
    # 现在的占用比最后一条记录低很多 = 刚被重启过，之前的趋势作废
    if ($a -and $script:hist.ContainsKey($name)) {
        $lastMB = $script:hist[$name][$script:hist[$name].Count - 1].MB
        if ($mb -lt 0.6 * $lastMB) { $a = $null }
    }
    if ($a) {
        $trend = '{0:+#,0;-#,0;0} MB / {1:N1} 小时' -f $a.Growth, $a.Span
        $fc = if ($a.Slope -gt 0) { '照这个速度，24 小时后约 ' + (Fmt-MB ($mb + $a.Slope * 24)) } else { '' }
        $note = '近 {0:N1} 小时涨了 {1:N0} MB（约 {2:N0} MB/小时）' -f $a.Span, $a.Growth, $a.Slope
        if ($a.Slope -ge $LeakSlopeMBh -and $a.Growth -ge $LeakGrowthMB -and $a.R2 -ge $LeakR2) { return (New-Rating '疑似泄漏' 2 90 $note $fc $trend) }
        if ($a.Slope -ge $RiseSlopeMBh -and $a.Growth -ge $RiseGrowthMB -and $a.R2 -ge $RiseR2) { return (New-Rating '缓慢上涨' 1 60 $note $fc $trend) }
        if ($a.Cv -ge $WobbleCv) { return (New-Rating '波动大' -1 10 '忽高忽低，通常是正常使用（比如开关网页）' '' $trend) }
        return (New-Rating '稳定' 0 0 ('近 {0:N1} 小时平稳' -f $a.Span) '' $trend)
    }
    $ring = $script:series[$name]
    $st = if ($ring) { $ring.Stats(120) } else { $null }
    if ($st -and $st[3] -ge $ShortMinHours) {
        $mins = $st[3] * 60
        $trend = '{0:+#,0;-#,0;0} MB / {1:N0} 分钟' -f $st[2], $mins
        if ($st[0] -ge $ShortSlopeMBh -and $st[2] -ge $ShortGrowthMB -and $st[1] -ge $ShortR2) {
            return (New-Rating '短时上涨' 1 50 ('近 {0:N0} 分钟持续上涨 {1:N0} MB，继续观察（满 1 小时才判断是否泄漏）' -f $mins, $st[2]) ('照这个速度，1 小时后约 ' + (Fmt-MB ($mb + $st[0]))) $trend)
        }
        if ($st[4] -ge $WobbleCv) { return (New-Rating '波动大' -1 10 '忽高忽低，通常是正常使用' '' $trend) }
        return (New-Rating '稳定' 0 0 ('近 {0:N0} 分钟平稳（初步，满 1 小时更准）' -f $mins) '' $trend)
    }
    New-Rating '数据不足' -1 0 '窗口打开满 10 分钟后开始判断' '' '—'
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

# 只在文字真的变了时才改，避免控件无谓重绘（闪烁）
function Set-Text($ctl, $text) { if ($ctl.Text -ne $text) { $ctl.Text = $text } }

# ---------- 主题：颜色、字体、画笔（只创建一次） ----------
function RGB($r, $g, $b) { [Drawing.Color]::FromArgb($r, $g, $b) }
$cBg     = RGB 14 9 12      # 窗口底色：红黑
$cPanel  = RGB 32 13 17     # 面板底色：暗红
$cRowA   = RGB 19 10 13
$cRowB   = RGB 26 12 16
$cCyan   = RGB 94 246 255   # 荧光蓝：数值 / 正常
$cYellow = RGB 245 217 10   # 黄：需要留意
$cRed    = RGB 255 40 60    # 亮红：有问题
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
$fNumCN = New-Object Drawing.Font('Microsoft YaHei UI', 16, [Drawing.FontStyle]::Bold)   # 数值里有中文时用它，Bahnschrift 没有中文字形
$fHead  = New-Object Drawing.Font('Bahnschrift SemiBold', 18)
$fSmall = New-Object Drawing.Font('Bahnschrift', 8.5)
$Fonts  = @($fCN, $fCNb, $fCNbig, $fTagB, $fNum, $fNumCN, $fHead, $fSmall)

$GDI = @{}   # 统一保存，关闭时一起释放
function Brush($name, $color) { $GDI[$name] = New-Object Drawing.SolidBrush($color) }
function Pen($name, $color, $w) { $GDI[$name] = New-Object Drawing.Pen($color, $w) }
Brush 'bg' $cBg; Brush 'panel' $cPanel; Brush 'rowA' $cRowA; Brush 'rowB' $cRowB; Brush 'dim' $cDim
Brush 'sel' (RGB 12 46 54); Brush 'row2' (RGB 78 14 22); Brush 'row1' (RGB 48 40 8)
Brush 'dimLine' $cRedDim; Brush 'acc' $cAccent; Pen 'accPen' $cAccent 1; Pen 'accDim' $cRedDim 1; Pen 'cyanPen' $cCyan 2
Pen 'scan' ([Drawing.Color]::FromArgb(12, 255, 90, 80)) 1
Pen 'grid' ([Drawing.Color]::FromArgb(150, 92, 30, 33)) 1
foreach ($l in 0, 1, 2, -1) {
    $c = $LevelColor[$l]
    Brush "lv$l" $c
    Pen "glow$l" ([Drawing.Color]::FromArgb(60, $c)) 7
    Pen "core$l" $c 2
    Brush "fill$l" ([Drawing.Color]::FromArgb(28, $c))
}
foreach ($l in 0, 1, 2, -1) { $GDI["glow$l"].LineJoin = 'Round' }

$TF = [Windows.Forms.TextFormatFlags]
$tfL = $TF::Left -bor $TF::VerticalCenter -bor $TF::SingleLine -bor $TF::EndEllipsis -bor $TF::NoPrefix -bor $TF::NoPadding
$tfR = $TF::Right -bor $TF::VerticalCenter -bor $TF::SingleLine -bor $TF::NoPrefix -bor $TF::NoPadding
$tfC = $TF::HorizontalCenter -bor $TF::VerticalCenter -bor $TF::SingleLine -bor $TF::NoPrefix -bor $TF::NoPadding
$tfW = $TF::Left -bor $TF::Top -bor $TF::WordBreak -bor $TF::EndEllipsis -bor $TF::NoPrefix -bor $TF::NoPadding

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
# 面板外框：底色 + 扫描线 + 切角框 + 标题。$active = 荧光蓝边框（表示下方走势图正在显示它）
function Frame($g, $w, $h, $tag, $title, [switch]$Active) {
    $g.SmoothingMode = 'AntiAlias'
    $g.FillRectangle($GDI['bg'], 0, 0, $w, $h)
    $poly = CutPoly 1 1 ($w - 2.5) ($h - 2.5) 16
    $g.FillPolygon($GDI['panel'], $poly)
    Scanlines $g $w $h
    $g.DrawPolygon($(if ($Active) { $GDI['cyanPen'] } else { $GDI['accPen'] }), $poly)
    $g.FillRectangle($(if ($Active) { $GDI['lv0'] } else { $GDI['acc'] }), 0, 0, 46, 4)
    if ($tag) {
        Txt $g ('// ' + $tag) $fTagB $cAccent 12 8 160 22
        Txt $g $title $fCNb $cGray (18 + (TxtW $g ('// ' + $tag) $fTagB)) 8 160 22
    }
}

# ---------- 界面 ----------
$form = New-Object Windows.Forms.Form
$form.Text = 'WATCHDOG // 内存 · CPU · 磁盘 监控'
$form.Size = New-Object Drawing.Size(1340, 980)
$form.MinimumSize = New-Object Drawing.Size(1150, 920)
$form.StartPosition = 'CenterScreen'
$form.Font = $fCN
$form.BackColor = $cBg
$form.ForeColor = $cText

# 窗口 / 任务栏图标：有 WatchDog.ico（Build-Exe.ps1 生成）就用它，否则启动时画一个同样的
$script:iconHandle = [IntPtr]::Zero
$script:formIcon = $null
$icoPath = Join-Path $ToolDir 'WatchDog.ico'
if (Test-Path $icoPath) { try { $script:formIcon = New-Object Drawing.Icon($icoPath); $null = $script:formIcon.Handle } catch { $script:formIcon = $null } }
if (-not $script:formIcon) {
    $ib = New-Object Drawing.Bitmap(32, 32); $ig = [Drawing.Graphics]::FromImage($ib)
    try {
        $ig.SmoothingMode = 'AntiAlias'; $ig.TextRenderingHint = 'AntiAliasGridFit'
        $pts = CutPoly 1 1 29.5 29.5 7
        $ig.FillPolygon($GDI['panel'], $pts); $ig.DrawPolygon($GDI['accPen'], $pts)
        $iconFont = New-Object Drawing.Font('Bahnschrift SemiBold', 17, [Drawing.FontStyle]::Bold, [Drawing.GraphicsUnit]::Pixel)
        $sf = New-Object Drawing.StringFormat; $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
        try { $ig.DrawString('W', $iconFont, $GDI['lv0'], (New-Object Drawing.RectangleF(0, 1, 32, 32)), $sf) } finally { $iconFont.Dispose(); $sf.Dispose() }
        $ig.FillRectangle($GDI['lv2'], 4, 4, 4, 4)
        $script:iconHandle = $ib.GetHicon()
        $script:formIcon = [Drawing.Icon]::FromHandle($script:iconHandle)
    } finally { $ig.Dispose(); $ib.Dispose() }
}
$form.Icon = $script:formIcon

# 顶部标题条
$header = New-Object BufferedPanel
$header.Dock = 'Top'; $header.Height = 50
$header.Add_Paint({
    param($s, $e)
    $g = $e.Graphics; $w = $s.Width; $h = $s.Height
    $g.FillRectangle($GDI['bg'], 0, 0, $w, $h)
    Txt $g 'WATCHDOG' $fHead $cCyan 16 6 200 34
    Txt $g '// Which dream is your want' $fTagB $cAccent 152 6 260 34
    # 自身占用：看门狗（最近一次后台检查）+ 本窗口
    $last = if ($script:sys.Count -gt 0) { $script:sys[$script:sys.Count - 1] } else { $null }
    $dogTxt = if ($last -and $last.SelfPeakMB) { '看门狗 每 10 分钟运行 {0:N1} 秒 · CPU {1:N1} 秒 · 峰值 {2} MB，用完即退出' -f ([double]$last.RunMs / 1000), [double]$last.SelfCpuSec, $last.SelfPeakMB }
              elseif ($last) { '看门狗 每 10 分钟运行 {0:N1} 秒，用完即退出' -f ([double]$last.RunMs / 1000) }
              else { '看门狗 未运行' }
    $selfTxt = '本窗口 {0:N0} MB · CPU {1:N1}%' -f $script:selfMB, $script:selfCpu
    $rx = $w - 262; $rw = [math]::Max(200, $rx - 420)
    Txt $g $dogTxt $fCN $cGray ($rx - $rw) 6 $rw 18 $tfR
    Txt $g $selfTxt $fCN $cCyan ($rx - $rw) 24 $rw 18 $tfR
    $g.FillRectangle($GDI['dimLine'], $rx + 4, 12, 1, 26)
    $live = if ($script:tick % 2 -eq 0) { $GDI['lv2'] } else { $GDI['panel'] }
    $g.FillRectangle($live, $w - 250, 17, 8, 8)
    Txt $g ('LIVE  ' + (Get-Date).ToString('HH:mm')) $fTagB $cCyan ($w - 234) 6 90 28
    Txt $g 'SYS.MON v6 // 0x5744' $fSmall $cRedDim ($w - 200) 6 186 28 $tfR
    $g.FillRectangle($GDI['acc'], 0, $h - 3, $w, 1)
    $g.FillPolygon($GDI['acc'], [Drawing.PointF[]]@((New-Object Drawing.PointF(0, ($h - 6))), (New-Object Drawing.PointF(220, ($h - 6))), (New-Object Drawing.PointF(226, ($h - 2))), (New-Object Drawing.PointF(0, ($h - 2)))))
})

# 四张卡片（点击切换下方走势图）
$cards = New-Object BufferedPanel
$cards.Dock = 'Top'; $cards.Height = 146; $cards.BackColor = $cBg

function New-Card($tag, $title, $code, $mode) {
    $p = New-Object BufferedPanel
    $p.Cursor = 'Hand'
    $p.Tag = @{ Code = $code; Tag = $tag; Title = $title; Mode = $mode; Value = '--'; Badge = '...'; Level = -1; Sub = ''; Pct = -1 }
    $p.Add_Paint({
        param($s, $e)
        $g = $e.Graphics; $w = $s.Width; $h = $s.Height; $d = $s.Tag
        $active = $script:chartMode -eq $d.Mode
        Frame $g $w $h $d.Tag $d.Title -Active:$active
        $lvl = [int]$d.Level
        Txt $g $(if ($active) { '▼ 走势显示中' } else { $d.Code }) $fSmall $(if ($active) { $cCyan } else { $cRedDim }) ($w - 160) ($h - 17) 148 14 $tfR
        if ($d.Badge) {
            $bx = $w - 118; $by = 10
            $g.FillPolygon($GDI["lv$lvl"], [Drawing.PointF[]]@((New-Object Drawing.PointF(($bx + 8), $by)), (New-Object Drawing.PointF(($bx + 104), $by)), (New-Object Drawing.PointF(($bx + 96), ($by + 22))), (New-Object Drawing.PointF($bx, ($by + 22)))))
            Txt $g $d.Badge $fCNb $cBg $bx $by 104 22 $tfC
        }
        $vf = if ([string]$d.Value -match '[^\x00-\x7F]') { $fNumCN } else { $fNum }
        Txt $g $d.Value $vf $cCyan 10 34 ($w - 20) 36
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
    $p.Add_Click({ param($s, $e); Set-ChartMode $s.Tag.Mode })
    $cards.Controls.Add($p)
    $p
}
$cardMem  = New-Card 'MEMORY' '内存' 'MEM-01 // 0x4D45' 'mem'
$cardCpu  = New-Card 'CPU' '处理器' 'CPU-02 // 0x4350' 'cpu'
$cardDisk = New-Card 'DISK' '磁盘读写' 'DSK-03 // 0x4453' 'disk'
$cardDog  = New-Card 'WATCHDOG' '看门狗 · 自身占用' 'WDG-04 // 0x5744' 'dog'
$CardList = @($cardMem, $cardCpu, $cardDisk, $cardDog)   # 注意：PowerShell 变量名不分大小写，不能叫 $Cards
$cards.Add_Resize({
    $w = [int](($cards.ClientSize.Width - 60) / 4)
    $i = 0
    foreach ($c in $CardList) { $c.SetBounds(12 + $i * ($w + 12), 6, $w, 134); $i++ }
})
function Set-Card($card, $value, $badge, [int]$level, $sub, [double]$pct) {
    $d = $card.Tag
    if ($d.Value -eq $value -and $d.Badge -eq $badge -and $d.Level -eq $level -and $d.Sub -eq $sub -and [int]$d.Pct -eq [int]$pct) { return }
    $d.Value = $value; $d.Badge = $badge; $d.Level = $level; $d.Sub = $sub; $d.Pct = $pct
    $card.Invalidate()
}
function Set-ChartMode($mode) {
    $script:chartMode = $mode   # 时间范围保持用户上次选的
    foreach ($c in $CardList) { $c.Invalidate() }
    $chart.Invalidate()
}

# ---------- 右侧栏：体检结论 / 选中程序 / 操作 ----------
$side = New-Object Windows.Forms.Panel
$side.Dock = 'Right'; $side.Width = 372; $side.BackColor = $cBg; $side.Padding = New-Object Windows.Forms.Padding(0, 0, 12, 0)

$diag = New-Object BufferedPanel
$diag.Dock = 'Top'; $diag.Height = 216; $diag.Cursor = 'Hand'
$diag.Add_Paint({
    param($s, $e)
    $g = $e.Graphics; $w = $s.Width; $h = $s.Height
    Frame $g $w $h 'DIAGNOSIS' '体检结论'
    $v = $script:verdict
    Txt $g $v[0] $fCNbig $LevelColor[[int]$v[1]] 14 32 ($w - 28) 24
    Txt $g $v[2] $fCN $cGray 14 56 ($w - 28) 18
    $y = 80; $rects = @()
    foreach ($is in $script:issues) {
        if ($y + 36 -gt $h - 6) { Txt $g ('…还有更多，见左侧列表（按"稳定性"排在最前）') $fCN $cGray 30 $y ($w - 44) 18; break }
        $c = $LevelColor[[int]$is.Level]
        Txt $g '▲' $fCN $c 14 $y 14 18
        $tw = $w - 44
        if ($is.Key) {
            # 右侧两个小按钮：忽略 24 小时 / 确认正常
            $bx1 = $w - 112; $bx2 = $w - 62
            $g.DrawRectangle($GDI['accPen'], $bx1, $y + 1, 44, 16); Txt $g '忽略' $fCN $cAccent $bx1 ($y + 1) 44 16 $tfC
            $g.DrawRectangle($GDI['accPen'], $bx2, $y + 1, 44, 16); Txt $g '正常' $fCN $cAccent $bx2 ($y + 1) 44 16 $tfC
            $tw = $w - 150
        }
        Txt $g $is.Title $fCNb $c 30 $y $tw 18
        Txt $g $is.Sub $fCN $cGray 30 ($y + 17) ($w - 44) 17
        $rects += , @($y, ($y + 36), $is.Target, $is.Key, $is.Title, ($w - 112), ($w - 62))
        $y += 38
    }
    $script:issueRects = $rects
})
$diag.Add_MouseClick({
    param($s, $e)
    foreach ($r in $script:issueRects) {
        if ($e.Y -lt $r[0] -or $e.Y -ge $r[1] -or -not $r[3] -or $e.Y -gt $r[0] + 18) { continue }
        if ($e.X -ge $r[5] -and $e.X -lt $r[5] + 44) { Ignore-Issue $r[3] $r[4]; return }
        if ($e.X -ge $r[6] -and $e.X -lt $r[6] + 44) {
            if (Ask ("确认「{0}」是正常的？`n`n以后不再提醒这个问题；如果是规则发现的，看门狗也不会再自动处理它。可以随时在右键菜单或""已忽略的问题""里恢复。" -f $r[4])) { Ignore-Issue $r[3] $r[4] -Normal }
            return
        }
    }
    foreach ($r in $script:issueRects) { if ($e.Y -ge $r[0] -and $e.Y -lt $r[1] -and $r[2]) { Select-Target $r[2]; break } }
})

$detail = New-Object BufferedPanel
$detail.Dock = 'Top'; $detail.Height = 276
$detail.Add_Paint({
    param($s, $e)
    $g = $e.Graphics; $w = $s.Width; $h = $s.Height
    Frame $g $w $h 'TARGET' '选中的程序'
    $name = $script:selected
    $r = if ($name) { $script:rows[$name] } else { $null }
    if (-not $r) { Txt $g '在左边列表里点选一个程序（或点上面的问题），这里显示它的稳定性、原因和修复方法。右键程序可以让看门狗专门监控它。' $fCN $cGray 14 40 ($w - 28) 60 $tfW; return }
    $icon = Get-Icon $name
    if ($icon) { $g.InterpolationMode = 'HighQualityBicubic'; $g.DrawImage($icon, 14, 38, 32, 32) }
    else { $g.FillRectangle($GDI['dim'], 14, 38, 32, 32); $g.DrawRectangle($GDI['accPen'], 14, 38, 32, 32) }
    Txt $g $name $fCNbig $cCyan 56 36 ($w - 70) 22
    $sub = if ($Desc[$name]) { $Desc[$name] } else { '-' }
    if ($script:watched.ContainsKey($name)) { $wr = $script:watched[$name]; $sub += ('  ·  ◉ 看门狗监控中（超过 {0} MB {1}）' -f $wr.when.minMB, $(if ($wr.auto) { '自动重启' } else { '提醒' })) }
    Txt $g $sub $fCN $cGray 56 58 ($w - 70) 18
    $cols = @(@('内存', ('{0:N0} MB' -f $r.PrivMB)), @('CPU', ('{0:N1} %' -f $r.CpuPct)), @('读写', ('{0:N1} MB/s' -f $r.IoMBs)), @('进程', [string]$r.Count))
    $cw = ($w - 28) / 4
    for ($i = 0; $i -lt 4; $i++) {
        Txt $g $cols[$i][0] $fCN $cGray (14 + $i * $cw) 80 $cw 16
        Txt $g $cols[$i][1] $fTagB $cText (14 + $i * $cw) 96 $cw 20
    }
    $rt = Get-Rating $name $r.PrivMB
    Txt $g ('稳定性：' + $rt.Text) $fCNb $LevelColor[[int]$rt.Level] 14 122 130 18
    Txt $g $(if ($rt.Text -eq '已知问题') { $rt.Trend } else { $rt.Note }) $fCN $cGray 140 122 ($w - 154) 18
    $hit = $script:hitByTarget[$name]
    if ($hit) {
        Txt $g ('已知问题：' + $hit.Rule.title) $fCNb $LevelColor[[int]$rt.Level] 14 144 ($w - 28) 18
        Txt $g ($hit.Why + '。' + $hit.Rule.cause) $fCN $cGray 14 164 ($w - 28) 30 $tfW
    } elseif ($rt.Forecast) {
        Txt $g $rt.Forecast $fCNb $LevelColor[[int]$rt.Level] 14 144 ($w - 28) 18
    }
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
$side.Controls.Add($diag)

# ---------- 主区域：程序列表 + 走势图 ----------
$main = New-Object Windows.Forms.Panel
$main.Dock = 'Fill'; $main.BackColor = $cBg; $main.Padding = New-Object Windows.Forms.Padding(12, 0, 12, 0)

$lv = New-Object BufferedListView
$lv.Dock = 'Fill'; $lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.HideSelection = $false; $lv.MultiSelect = $false
$lv.OwnerDraw = $true; $lv.BackColor = $cRowA; $lv.ForeColor = $cText; $lv.BorderStyle = 'None'
$rowH = New-Object Windows.Forms.ImageList; $rowH.ImageSize = New-Object Drawing.Size(1, 28); $lv.SmallImageList = $rowH
foreach ($c in @(@('程序', 175), @('说明', 140), @('内存 MB', 80), @('CPU %', 58), @('读写 MB/s', 78), @('稳定性', 78), @('变化', 135), @('判断 / 预测', 180))) {
    [void]$lv.Columns.Add($c[0], $c[1])
}
$RightCols = @(2, 3, 4)
$SortCol = @{ 'mem' = 2; 'cpu' = 3; 'io' = 4; 'issue' = 5 }
$lv.Add_DrawColumnHeader({
    param($s, $e)
    $g = $e.Graphics; $r = $e.Bounds
    $g.FillRectangle($GDI['bg'], $r)
    $g.FillRectangle($GDI['acc'], $r.X, $r.Bottom - 2, $r.Width, 2)
    $f = if ($RightCols -contains $e.ColumnIndex) { $tfR } else { $tfL }
    $sorted = $SortCol[$script:sortMode] -eq $e.ColumnIndex
    $text = if ($sorted) { $e.Header.Text + ' ▼' } else { $e.Header.Text }
    Txt $g $text $fCNb $(if ($sorted) { $cCyan } else { $cAccent }) ($r.X + 8) $r.Y ($r.Width - 16) $r.Height $f
})
$lv.Add_ColumnClick({
    param($s, $e)
    $m = switch ($e.Column) { 2 { 'mem' } 3 { 'cpu' } 4 { 'io' } default { 'issue' } }
    $script:sortMode = $m; Refresh-All
})
$lv.Add_DrawItem({ param($s, $e) })
$lv.Add_DrawSubItem({
    param($s, $e)
    $g = $e.Graphics; $r = $e.Bounds; $it = $e.Item
    $lvl = [int]$it.Tag
    $bg = if ($it.Selected) { $GDI['sel'] } elseif ($lvl -eq 2) { $GDI['row2'] } elseif ($lvl -eq 1) { $GDI['row1'] } elseif ($it.Index % 2) { $GDI['rowB'] } else { $GDI['rowA'] }
    $g.FillRectangle($bg, $r)
    $col = $e.ColumnIndex
    if ($col -eq 0) {
        $icon = Get-Icon $it.Text
        $g.InterpolationMode = 'HighQualityBicubic'
        if ($icon) { $g.DrawImage($icon, $r.X + 8, $r.Y + 5, 18, 18) } else { $g.FillRectangle($GDI['dim'], $r.X + 11, $r.Y + 8, 12, 12) }
        if ($it.Selected) { $g.FillRectangle($GDI['lv0'], $r.X, $r.Y + 3, 3, $r.Height - 6) }
        $tw = $r.Width - 40
        if ($script:watched.ContainsKey($it.Text)) { Txt $g '◉' $fCN $cCyan ($r.Right - 20) $r.Y 16 $r.Height; $tw -= 18 }
        Txt $g $it.Text $fCNb $cText ($r.X + 34) $r.Y $tw $r.Height
        return
    }
    $io = 0.0; [void][double]::TryParse($it.SubItems[4].Text, [ref]$io)
    $c = switch ($col) {
        1 { $cGray }
        4 { if ($io -ge $HeavyIoMBs) { $cYellow } else { $cText } }
        5 { $LevelColor[$lvl] }
        6 { $cGray }
        7 { if ($lvl -ge 1) { $LevelColor[$lvl] } else { $cGray } }
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
    if ($lv.SelectedItems.Count -gt 0) { $script:selected = $lv.SelectedItems[0].Text; Update-DetailButtons; Set-ChartMode 'proc'; $detail.Invalidate() }
})

# ---------- 走势图：内存 / CPU / 磁盘 / 看门狗 / 选中的程序，1 小时（实时）或 24 小时（看门狗记录） ----------
$chart = New-Object BufferedPanel
$chart.Dock = 'Top'; $chart.Height = 210   # 走势图在列表上方

# 一条线：@{ T = long[] ticks; V = double[] 值; Level = 颜色; Name = 图例 }
function Ring-Line($key, $level, $label, $scale = 1.0) {
    $r = $script:series[$key]
    if (-not $r -or $r.Count -lt 2) { return $null }
    $n = $r.Count; $t = New-Object 'long[]' $n; $v = New-Object 'double[]' $n
    for ($i = 0; $i -lt $n; $i++) { $t[$i] = $r.TimeAt($i); $v[$i] = $r.ValueAt($i) * $scale }
    @{ T = $t; V = $v; Level = $level; Name = $label }
}
function Hist-Line($items, $getter, $level, $label) {
    $items = @(foreach ($x in $items) { $x }); $n = $items.Count   # 不用 @(List)，PowerShell 5.1 有时会报"参数类型不匹配"
    if ($n -lt 2) { return $null }
    $t = New-Object 'long[]' $n; $v = New-Object 'double[]' $n
    for ($i = 0; $i -lt $n; $i++) { $t[$i] = $items[$i].T.ToUniversalTime().Ticks; $v[$i] = [double](& $getter $items[$i]) }
    @{ T = $t; V = $v; Level = $level; Name = $label }
}
# 按当前模式取数据：返回 @{ Title; Unit; Lines; Note; FixedMax }
function Get-ChartData($range) {
    $m = $script:chartMode
    $long = $RangeHours[$range] -gt 1   # 1 小时以内用窗口的实时数据（5 秒一个点），更长用看门狗的记录（10 分钟一个点）
    switch ($m) {
        'mem' {
            if ($long) { return @{ Title = '整机内存占用'; Unit = 'GB'; Lines = @(Hist-Line $script:sys { param($x) [double]$x.UsedMB / 1024 } 0 '已用'); Note = '看门狗每 10 分钟记录一次' } }
            return @{ Title = '整机内存占用'; Unit = 'GB'; Lines = @(Ring-Line 'sys:mem' 0 '已用'); Note = '窗口打开期间每 5 秒一个点' }
        }
        'cpu' {
            if ($long) { return @{ Title = 'CPU 占用'; Unit = '%'; FixedMax = 100; Lines = @(Hist-Line $script:sys { param($x) [double]$x.CpuPct } 0 'CPU'); Note = '看门狗检查时的瞬间值' } }
            return @{ Title = 'CPU 占用'; Unit = '%'; FixedMax = 100; Lines = @(Ring-Line 'sys:cpu' 0 'CPU'); Note = '窗口打开期间每 5 秒一个点' }
        }
        'disk' {
            if ($long) {
                $v2 = @($script:sys | Where-Object { $null -ne $_.DiskWriteMBs })
                return @{ Title = '磁盘读写'; Unit = 'MB/s'; Lines = @((Hist-Line $v2 { param($x) [double]$x.DiskReadMBs } 0 '读'), (Hist-Line $v2 { param($x) [double]$x.DiskWriteMBs } 1 '写')); Note = '看门狗检查时的瞬间值' }
            }
            return @{ Title = '磁盘读写'; Unit = 'MB/s'; Lines = @((Ring-Line 'sys:dr' 0 '读'), (Ring-Line 'sys:dw' 1 '写')); Note = '窗口打开期间每 5 秒一个点' }
        }
        'dog' {
            $what = '看门狗做什么：每 10 分钟在后台运行约 5 秒 → ① 按规则检查，超过上限的自动修复  ② 记录各程序内存，用来判断稳定性 → 然后退出，不常驻内存'
            if ($long) { return @{ Title = '看门狗每次检查耗时'; Unit = '秒'; Lines = @(Hist-Line $script:sys { param($x) [double]$x.RunMs / 1000 } 0 '耗时'); Note = $what } }
            return @{ Title = '本监控窗口自身内存'; Unit = 'MB'; Lines = @(Ring-Line 'sys:self' 0 '本窗口'); Note = $what }
        }
        default {
            $name = $script:selected
            if (-not $name) { return @{ Title = ''; Lines = @(); Note = '点选列表里的程序看它的内存走势；点上面的卡片看整机内存 / CPU / 磁盘 / 看门狗' } }
            $label = '{0}  ·  {1}' -f $name, $(if ($Desc[$name]) { $Desc[$name] } else { '-' })
            if ($long) { return @{ Title = $label; Unit = 'MB'; Lines = @(Hist-Line $script:hist[$name] { param($x) $x.MB } 0 '内存'); Note = '看门狗每 10 分钟记录一次' } }
            return @{ Title = $label; Unit = 'MB'; Lines = @(Ring-Line $name 0 '内存'); Note = '窗口打开期间每 5 秒一个点' }
        }
    }
}
$chart.Add_Paint({
    param($s, $e)
    $g = $e.Graphics; $w = $s.Width; $h = $s.Height
    $g.FillRectangle($GDI['bg'], 0, 0, $w, $h)
    $g.SmoothingMode = 'AntiAlias'
    $poly = CutPoly 0.5 0.5 ($w - 1.5) ($h - 2) 16
    $g.FillPolygon($GDI['panel'], $poly)
    Scanlines $g $w $h
    $g.DrawPolygon($GDI['accPen'], $poly)
    $g.FillRectangle($GDI['acc'], 0, 0, 46, 4)
    $range = $script:chartRange
    if (-not $RangeHours.Contains($range)) { $range = '30m' }
    $data = Get-ChartData $range
    Txt $g '// TREND' $fTagB $cAccent 12 8 70 20
    # 右上角范围切换：近 30 分钟 / 1 / 3 / 12 / 24 小时
    $rw = 64; $gap = 4
    $x = $w - 24 - $RangeHours.Count * ($rw + $gap) + $gap
    Txt $g '近' $fCN $cGray ($x - 26) 7 22 20 $tfR
    Txt $g $data.Title $fCNb $cText 84 8 ($x - 84 - 34) 20
    $rects = @()
    foreach ($key in $RangeHours.Keys) {
        if ($range -eq $key) { $g.FillRectangle($GDI['lv0'], $x, 7, $rw, 20); Txt $g $RangeLabel[$key] $fCNb $cBg $x 7 $rw 20 $tfC }
        else { $g.DrawRectangle($GDI['accPen'], $x, 7, $rw, 20); Txt $g $RangeLabel[$key] $fCN $cAccent $x 7 $rw 20 $tfC }
        $rects += , @($x, ($x + $rw), $key); $x += $rw + $gap
    }
    $script:rangeRects = $rects
    $end = [DateTime]::UtcNow.Ticks
    $spanT = [long]([TimeSpan]::FromHours($RangeHours[$range]).Ticks)
    $begin = $end - $spanT
    # 只留在这段时间里至少有 2 个点的线
    $lines = @(foreach ($ln in $data.Lines) {
        if (-not $ln) { continue }
        $n = 0; foreach ($tk in $ln.T) { if ($tk -ge $begin) { $n++ } }
        if ($n -ge 2) { $ln }
    })
    $L = 70; $R = 24; $T = 36; $B = 42
    $pw = $w - $L - $R; $ph = $h - $T - $B
    Txt $g $data.Note $fCN $cGray 14 ($h - 22) ($w - 28) 16
    if (-not $lines) {
        $msg = if ($script:chartMode -eq 'proc' -and -not $script:selected) { $data.Note }
            elseif ($RangeHours[$range] -le 1) { '实时数据还不够：窗口每 5 秒记录一个点，稍等片刻；或者选"3 小时"以上，看看门狗的记录。' }
            else { '这段时间还没有看门狗的记录（每 10 分钟记录一次）。可以先看"30 分钟 / 1 小时"的实时数据，或者选更长的时间。' }
        Txt $g $msg $fCN $cGray 14 44 ($w - 28) 40 $tfW
        return
    }
    $max = 0.0; $min = [double]::MaxValue
    foreach ($ln in $lines) { for ($i = 0; $i -lt $ln.V.Length; $i++) { if ($ln.T[$i] -lt $begin) { continue }; $v = $ln.V[$i]; if ($v -gt $max) { $max = $v }; if ($v -lt $min) { $min = $v } } }
    if ($min -eq [double]::MaxValue) { $min = 0 }
    if ($data.FixedMax) { $lo = 0; $hi = $data.FixedMax }
    else { $pad = [math]::Max(($max - $min) * 0.15, [math]::Max($max * 0.02, 0.5)); $lo = [math]::Max(0, $min - $pad); $hi = $max + $pad }
    $fmt = if ($hi - $lo -lt 10) { '{0:N1}' } else { '{0:N0}' }   # 范围小时多显示一位小数，免得刻度重复
    for ($i = 0; $i -le 3; $i++) {
        $y = $T + $ph * $i / 3
        $g.DrawLine($GDI['grid'], $L, $y, $L + $pw, $y)
        Txt $g (($fmt -f ($hi - ($hi - $lo) * $i / 3)) + ' ' + $data.Unit) $fSmall $cGray 4 ($y - 9) ($L - 10) 18 $tfR
    }
    $ticks = if ($range -eq '3h' -or $range -eq '12h') { 6 } else { 4 }
    for ($k = 0; $k -le $ticks; $k++) {
        $x = $L + $pw * $k / $ticks
        $g.DrawLine($GDI['grid'], $x, $T, $x, $T + $ph)
        $lt = ([datetime]($begin + $spanT * $k / $ticks)).ToLocalTime()
        Txt $g $lt.ToString('HH:mm') $fSmall $cGray ($x - 20) ($T + $ph + 4) 40 16 $tfC
    }
    $g.SetClip((New-Object Drawing.RectangleF([single]$L, [single]$T, [single]$pw, [single]$ph)))
    $legendX = $w - 190
    foreach ($ln in $lines) {
        $lvl = [int]$ln.Level
        $pts = New-Object 'System.Collections.Generic.List[System.Drawing.PointF]'
        for ($i = 0; $i -lt $ln.V.Length; $i++) {
            if ($ln.T[$i] -lt $begin) { continue }
            $x = $L + $pw * ($ln.T[$i] - $begin) / $spanT
            $y = $T + $ph * (1 - ($ln.V[$i] - $lo) / ($hi - $lo))
            $pts.Add((New-Object Drawing.PointF([single]$x, [single]$y)))
        }
        if ($pts.Count -lt 2) { continue }
        $arr = $pts.ToArray()
        if ($lines.Count -eq 1) {
            $area = New-Object 'System.Collections.Generic.List[System.Drawing.PointF]'
            $area.Add((New-Object Drawing.PointF($arr[0].X, [single]($T + $ph)))); $area.AddRange($arr); $area.Add((New-Object Drawing.PointF($arr[$arr.Length - 1].X, [single]($T + $ph))))
            $g.FillPolygon($GDI["fill$lvl"], $area.ToArray())
        }
        $g.DrawLines($GDI["glow$lvl"], $arr)
        $g.DrawLines($GDI["core$lvl"], $arr)
        $ln.LastPt = $arr[$arr.Length - 1]
    }
    $g.ResetClip()
    # 末端数值 + 多条线时的图例
    $ly = 50
    foreach ($ln in $lines) {
        if (-not $ln.LastPt) { continue }
        $lvl = [int]$ln.Level; $lp = $ln.LastPt
        $g.FillRectangle($GDI["lv$lvl"], $lp.X - 4, $lp.Y - 4, 8, 8)
        $lastV = $ln.V[$ln.V.Length - 1]
        $txt = ($fmt -f $lastV) + ' ' + $data.Unit
        if ($lines.Count -gt 1) { $txt = $ln.Name + ' ' + $txt; Txt $g $txt $fTagB $LevelColor[$lvl] ($L + 8) $ly 160 18; $ly += 18 }
        else { Txt $g $txt $fTagB $LevelColor[$lvl] ($lp.X - 130) ($lp.Y - 26) 124 20 $tfR }
    }
})
$chart.Add_MouseClick({
    param($s, $e)
    if ($e.Y -lt 4 -or $e.Y -gt 30) { return }
    foreach ($r in $script:rangeRects) { if ($e.X -ge $r[0] -and $e.X -lt $r[1]) { $script:chartRange = $r[2]; $chart.Invalidate(); break } }
})
$main.Controls.Add($lv)
$main.Controls.Add((New-Object Windows.Forms.Panel -Property @{ Dock = 'Top'; Height = 8; BackColor = $cBg }))
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
    $txt = '每 5 秒刷新 · 最小化时暂停 · 本窗口：内存 {0:N0} MB / CPU {1:N2}% / GDI {2} · 实时数据 {3} 条 · 点卡片切换走势图 · 点列标题切换排序 · 右键程序可让看门狗监控它' -f $script:selfMB, $script:selfCpu, $script:selfGdi, $script:series.Count
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
function Restart-ServiceElevated($svc) {
    Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -Name {1}' -f (Join-Path $ToolDir 'Restart-ServiceHard.ps1'), $svc)
}
function Reload-Soon { $script:forceSlowAt = (Get-Date).AddSeconds(8) }
function Path-Of($name) { $r = $script:rows[$name]; if ($r) { [NativeInfo]::ImagePath([int]$r.Pid) } else { $null } }

function Select-Target($name) {
    $script:selected = $name
    $script:updating = $true
    try { foreach ($it in $lv.Items) { $sel = ($it.Text -eq $name); if ($it.Selected -ne $sel) { $it.Selected = $sel }; if ($sel) { $it.EnsureVisible() } } } finally { $script:updating = $false }
    Update-DetailButtons; Set-ChartMode 'proc'; $detail.Invalidate()
}

# 重启一个程序（或服务）。$NoAsk 用于"一键修复"时已统一确认过。
function Restart-Target($name, [switch]$NoAsk) {
    if (-not $name) { Say '先在列表里选一个程序。'; return $false }
    if ($name -like 'svc:*') {
        $svc = $name.Substring(4)
        if (-not $NoAsk -and -not (Ask "将重启系统服务 $svc（需要管理员权限，会弹出确认窗口）。确定吗？")) { return $false }
        Restart-ServiceElevated $svc; Reload-Soon; return $true
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
# 按规则修复
function Apply-Fix($hit, [switch]$NoAsk) {
    $r = $hit.Rule
    switch ($r.fix.type) {
        'restartProcess' { return (Restart-Target $r.when.process -NoAsk:$NoAsk) }
        'restartService' {
            if (-not $NoAsk -and -not (Ask ("{0}`n`n{1}`n`n将执行：{2}（需要管理员权限）。确定吗？" -f $r.title, $r.cause, $r.fix.label))) { return $false }
            Restart-ServiceElevated $r.fix.service; Reload-Soon; return $true
        }
        'script' {
            if (-not $NoAsk -and -not (Ask ("{0}`n`n{1}`n`n将执行：{2}（需要管理员权限）。确定吗？" -f $r.title, $r.cause, $r.fix.label))) { return $false }
            Run-Tool $r.fix.script '-Quiet'; Reload-Soon; return $true
        }
        default { Say ("{0}`n`n{1}`n`n建议：{2}" -f $r.title, $r.cause, $r.fix.label); return $false }
    }
}
function Fix-Selected {
    $name = $script:selected
    $hit = if ($name) { $script:hitByTarget[$name] } else { $null }
    if ($hit) { [void](Apply-Fix $hit) } else { [void](Restart-Target $name) }
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
# 一键修复：所有命中规则且有修复方法的问题 + 没有规则但疑似泄漏的程序（重启它）
function Fix-All {
    $todo = @(); $seen = @{}
    foreach ($h in $script:hits) { if ($h.Rule.fix.type -ne 'none' -and -not $seen.ContainsKey($h.Target)) { $todo += , @($h.Rule.fix.label, $h); $seen[$h.Target] = 1 } }
    foreach ($r in $script:rows.Values) {
        if ($seen.ContainsKey($r.Name) -or $Protected -contains $r.Name) { continue }
        if ($script:ratings[$r.Name].Text -eq '疑似泄漏' -and $script:ratings[$r.Name].Level -ge 2) { $todo += , @(('重启 {0}（疑似泄漏）' -f $r.Name), $r.Name); $seen[$r.Name] = 1 }
    }
    if (-not $todo) { Say '现在没有需要修复的问题。'; return }
    if (-not (Ask ("将依次执行：`n`n  " + (($todo | ForEach-Object { $_[0] }) -join "`n  ") + "`n`n相关程序里没保存的内容可能会丢失；部分操作需要管理员权限。确定吗？"))) { return }
    $ok = 0
    foreach ($t in $todo) { $res = if ($t[1] -is [string]) { Restart-Target $t[1] -NoAsk } else { Apply-Fix $t[1] -NoAsk }; if ($res) { $ok++ } }
    Say "已执行 $ok / $($todo.Count) 项。"
}
function Run-CheckNow {
    if ($script:taskState) { Start-ScheduledTask -TaskName 'MemWatchdog'; Say '已开始检查，大约 5 秒后完成，结果会自动刷新到界面上。' }
    else { Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $ToolDir 'MemWatchdog.ps1')) }
    Reload-Soon
}

# ---- 个人规则文件（rules.local.json）读写：右键"用看门狗监控"就是往这里加一条规则 ----
function Local-RulesPath { Join-Path $RulesDir 'rules.local.json' }
function Read-LocalRules {
    $p = Local-RulesPath
    if (-not (Test-Path $p)) { return @() }
    $list = @(); try { foreach ($r in (ConvertFrom-Json (Get-Content $p -Raw -Encoding UTF8))) { $list += $r } } catch { throw "rules.local.json 格式有误：$($_.Exception.Message)" }
    $list
}
function Write-LocalRules($list) {
    $json = ConvertTo-Json -InputObject @($list) -Depth 6
    [IO.File]::WriteAllText((Local-RulesPath), $json, (New-Object Text.UTF8Encoding $false))
    $script:rulesSig = ''; Load-Rules
}
function Add-Watch($name, [switch]$Auto) {
    if (-not $name) { return }
    $r = $script:rows[$name]; $cur = if ($r) { $r.PrivMB } else { 0 }
    $default = [int]([math]::Ceiling([math]::Max($cur * 1.5, $cur + 300) / 100) * 100)
    $what = if ($Auto) { '自动重启它' } else { '提醒你' }
    $ans = [Microsoft.VisualBasic.Interaction]::InputBox(("让看门狗监控 {0}（现在 {1:N0} MB）。`n`n内存超过多少 MB 时{2}？`n`n看门狗每 10 分钟检查一次，也会专门记录它的内存走势。" -f $name, $cur, $what), 'WATCHDOG · 监控这个程序', [string]$default)
    if (-not $ans) { return }
    $limit = 0; if (-not [int]::TryParse($ans.Trim(), [ref]$limit) -or $limit -le 0) { Say '请输入一个正整数（单位 MB）。'; return }
    try { $list = @(Read-LocalRules | Where-Object { $_.id -ne "watch-$name" }) } catch { Say $_.Exception.Message; return }
    $fix = if ($name -like 'svc:*') { [ordered]@{ type = $(if ($Auto) { 'restartService' } else { 'none' }); service = $name.Substring(4); label = "重启服务 $($name.Substring(4))" } }
           else { [ordered]@{ type = $(if ($Auto) { 'restartProcess' } else { 'none' }); label = $(if ($Auto) { "重启 $name" } else { "方便时手动重启 $name" }) } }
    $list += [pscustomobject][ordered]@{
        id = "watch-$name"; title = "$name 超过监控上限"; target = $name
        when = [ordered]@{ process = $name; minMB = $limit }
        cause = "你在监控窗口里设置的：内存超过 $limit MB 时$what。"
        fix = $fix; auto = [bool]$Auto
    }
    Write-LocalRules $list
    Say ("已加入看门狗监控：{0} 超过 {1} MB 时{2}。`n规则保存在 rules.local.json，可以随时在右键菜单里取消。" -f $name, $limit, $what)
    Refresh-All
}
function Remove-Watch($name) {
    try { $list = @(Read-LocalRules | Where-Object { $_.id -ne "watch-$name" }) } catch { Say $_.Exception.Message; return }
    Write-LocalRules $list
    Refresh-All
}
function Edit-Rules {
    $p = Local-RulesPath
    if (-not (Test-Path $p)) { [IO.File]::WriteAllText($p, "[]", (New-Object Text.UTF8Encoding $false)); Start-Process notepad.exe "`"$(Join-Path $RulesDir 'rules.local.example.json')`"" }
    Start-Process notepad.exe "`"$p`""
    $script:forceSlowAt = (Get-Date).AddSeconds(20)
}

# 右键菜单
$menu = New-Object Windows.Forms.ContextMenuStrip
$menu.Renderer = New-Object Windows.Forms.ToolStripProfessionalRenderer((New-Object CyberColors))
$menu.Font = $fCN; $menu.ForeColor = $cText
function Menu-Item($text, $onClick) { $i = $menu.Items.Add($text); $i.ForeColor = $cText; $i.Add_Click($onClick); $i }
$menuFix    = Menu-Item '修复 / 重启' { Fix-Selected }
$menuKill   = Menu-Item '结束这个程序' { Kill-Target $script:selected }
$menuOpen   = Menu-Item '打开文件位置' { Open-Location $script:selected }
[void]$menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
$menuWatch  = Menu-Item '◉ 用看门狗监控（超过上限时提醒）' { Add-Watch $script:selected }
$menuWatchA = Menu-Item '◉ 用看门狗监控（超过上限时自动重启）' { Add-Watch $script:selected -Auto }
$menuUnwatch = Menu-Item '取消看门狗监控' { Remove-Watch $script:selected }
[void]$menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
# 选中程序当前的问题：@(key, 标题)；没有问题返回 $null
function Issue-Of($name) {
    if (-not $name) { return $null }
    $hit = $script:hitByTarget[$name]
    if ($hit) { return , @("rule:$($hit.Rule.id)", $hit.Rule.title) }
    $rt = $script:ratings[$name]
    if ($rt -and $rt.Level -ge 1) { return , @("prog:$name", "$name $($rt.Text)") }
    $r = $script:rows[$name]
    if ($r -and $r.IoMBs -ge $HeavyIoMBs -and -not (Is-Ignored "io:$name")) { return , @("io:$name", "$name 正在大量读写") }
    $null
}
function Has-Ignore($name) {
    foreach ($k in $script:ignores.Keys) {
        if (-not (Is-Ignored $k)) { continue }
        if ($k -eq "prog:$name" -or $k -eq "io:$name") { return $true }
        if ($k -like 'rule:*') { $r = $script:rules | Where-Object { "rule:$($_.id)" -eq $k } | Select-Object -First 1; if ($r -and ($r.target -eq $name -or $r.when.process -eq $name)) { return $true } }
    }
    $false
}
$menuSnooze = Menu-Item '忽略这个问题（24 小时内不提醒）' { $is = Issue-Of $script:selected; if ($is) { Ignore-Issue $is[0] $is[1] } }
$menuNormal = Menu-Item '确认正常，不再提醒' { $is = Issue-Of $script:selected; if ($is -and (Ask ("确认「{0}」是正常的？以后不再提醒；如果是规则发现的，看门狗也不会再自动处理它。" -f $is[1]))) { Ignore-Issue $is[0] $is[1] -Normal } }
$menuRestore = Menu-Item '恢复提醒' { Unignore-Name $script:selected }
$menu.Add_Opening({
    param($s, $e)
    $n = $script:selected
    if (-not $n) { $e.Cancel = $true; return }
    $menuFix.Text = $btnPrimary.Text
    $hasIssue = [bool](Issue-Of $n)
    $menuSnooze.Visible = $hasIssue; $menuNormal.Visible = $hasIssue
    $menuRestore.Visible = Has-Ignore $n
    $isW = $script:watched.ContainsKey($n)
    $menuUnwatch.Visible = $isW
    $menuWatch.Text = if ($isW) { '◉ 修改监控（超过上限时提醒）' } else { '◉ 用看门狗监控（超过上限时提醒）' }
    $menuWatchA.Text = if ($isW) { '◉ 修改监控（超过上限时自动重启）' } else { '◉ 用看门狗监控（超过上限时自动重启）' }
    $menuWatchA.Visible = $Protected -notcontains $n
})
$lv.ContextMenuStrip = $menu

# 选中程序的按钮：主按钮的文字随规则变化（命中规则时显示对应的修复方法）
$btnPrimary = New-Btn $detail '重启这个程序' 14 196 334 { Fix-Selected } -Primary
$btnKill    = New-Btn $detail '结束' 14 234 163 { Kill-Target $script:selected }
$btnOpen    = New-Btn $detail '打开位置' 185 234 163 { Open-Location $script:selected }
function Update-DetailButtons {
    $name = $script:selected
    $hit = if ($name) { $script:hitByTarget[$name] } else { $null }
    $t = if ($hit) { if ($hit.Rule.fix.type -eq 'none') { '查看建议：' + $hit.Rule.fix.label } else { '修复：' + $hit.Rule.fix.label } } elseif ($name -like 'svc:*') { '重启这个服务' } else { '重启这个程序' }
    Set-Text $btnPrimary $t
}

# 操作区按钮（两列）
$ax = 14; $half = 163; $full = 334; $ay = 36; $step = 38
$btnFix     = New-Btn $actions '一键修复全部问题' $ax $ay $full { Fix-All } -Primary; $ay += $step
$btnNow     = New-Btn $actions '立即检查一次' $ax $ay $half { Run-CheckNow }
$btnNv      = New-Btn $actions '修复 NVIDIA 数据库' ($ax + $half + 8) $ay $half { if (Ask '将停止并重建 NVIDIA 的 nvtopps 数据库，屏幕可能闪一下。需要管理员权限。确定吗？') { Run-Tool 'Fix-NvTopps.ps1'; Reload-Soon } }; $ay += $step
$btnRules   = New-Btn $actions '编辑我的规则' $ax $ay $half { Edit-Rules }
$btnIgnored = New-Btn $actions '已忽略的问题' ($ax + $half + 8) $ay $half { Show-Ignored }; $ay += $step
$btnInstall = New-Btn $actions '安装看门狗' $ax $ay $half {
    if ($script:taskState) { if (Ask '将删除看门狗计划任务，之后不再自动检查。确定吗？') { Run-Tool 'Install-Watchdog.ps1' '-Uninstall' } }
    else { Run-Tool 'Install-Watchdog.ps1' }
    $script:forceSlowAt = (Get-Date).AddSeconds(15)
}
$btnFolder  = New-Btn $actions '打开工具文件夹' ($ax + $half + 8) $ay $half { Start-Process explorer.exe "`"$ToolDir`"" }
function Active-Ignores { @($script:ignores.Values | Where-Object { Is-Ignored $_.key }) }
function Show-Ignored {
    $list = @(Active-Ignores)
    if (-not $list) { Say '现在没有被忽略或确认正常的问题。'; return }
    $lines = $list | ForEach-Object { '  · {0}（{1}）' -f $_.label, $(if ($_.type -eq 'normal') { '已确认正常' } else { '忽略到 ' + ([datetime]$_.until).ToString('MM-dd HH:mm') }) }
    if (Ask ("下面这些问题现在不会提醒：`n`n" + ($lines -join "`n") + "`n`n要全部恢复提醒吗？")) { $script:ignores = @{}; Save-Ignores; Refresh-All }
}

# ---------- 刷新 ----------
function Refresh-All {
    if ($form.WindowState -eq [Windows.Forms.FormWindowState]::Minimized) { return }
    $script:tick++
    $now = Get-Date; $nowU = [DateTime]::UtcNow
    if ($script:forceSlowAt -and $now -ge $script:forceSlowAt) { $script:forceSlowAt = $null; $script:lastSlow = [datetime]::MinValue; $script:histSig = ''; $script:rulesSig = '' }
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
    Record 'sys:mem' $usedGB $nowU

    # 进程采样 + 规则
    $cpuNow = [NativeInfo]::Cpu()
    $script:cpuHist.Enqueue($cpuNow)
    while ($script:cpuHist.Count -gt 6) { [void]$script:cpuHist.Dequeue() }
    $cpuAvg = ($script:cpuHist | Measure-Object -Average).Average
    Record 'sys:cpu' $cpuNow $nowU
    $procs = Sample-Processes
    $rows = @($procs | Where-Object { $_.Name -ne 'Idle' -and $_.Name -ne 'Memory Compression' })
    $byName = @{}; foreach ($r in $rows) { $byName[$r.Name] = $r }
    $script:rows = $byName
    $real = @($rows | Where-Object { $_.Name -notlike 'svc:*' })
    # 实时数据：内存前 40 + 规则 / 监控涉及的 + 选中的
    $rec = @{}
    foreach ($r in @($real | Sort-Object PrivMB -Descending | Select-Object -First 40)) { $rec[$r.Name] = $r }
    foreach ($r in $script:rules) { $p = $r.when.process; if ($p -and $byName.ContainsKey($p)) { $rec[$p] = $byName[$p] } }
    if ($script:selected -and $byName.ContainsKey($script:selected)) { $rec[$script:selected] = $byName[$script:selected] }
    foreach ($r in $rec.Values) { Record $r.Name $r.PrivMB $nowU }
    Eval-Rules
    $ratings = @{}; foreach ($r in $rows) { $ratings[$r.Name] = Get-Rating $r.Name $r.PrivMB }
    $script:ratings = $ratings

    # CPU（最近 30 秒平均）
    $busy = @($real | Sort-Object CpuPct -Descending | Select-Object -First 2)
    $lvl = if ($cpuAvg -lt 50) { 0 } elseif ($cpuAvg -lt 85) { 1 } else { 2 }
    Set-Card $cardCpu ('{0:N0} %' -f $cpuAvg) (@('正常', '较忙', '很忙')[$lvl]) $lvl ('最忙：' + (($busy | ForEach-Object { '{0} {1:N1}%' -f $_.Name, $_.CpuPct }) -join '，')) $cpuAvg

    # 磁盘
    $script:disk = [DiskPerf]::Read()
    $rd = $script:disk[0] / 1MB; $wr = $script:disk[1] / 1MB; $busyPct = $script:disk[2]
    Record 'sys:dr' $rd $nowU; Record 'sys:dw' $wr $nowU
    $topIo = @($real | Sort-Object IoMBs -Descending | Select-Object -First 1)
    $lvl = if ($busyPct -lt 60) { 0 } elseif ($busyPct -lt 90) { 1 } else { 2 }
    $ioSub = if ($topIo -and $topIo[0].IoMBs -ge 0.1) { '读写最多：{0} {1:N1} MB/s' -f $topIo[0].Name, $topIo[0].IoMBs } else { '没有程序在大量读写' }
    Set-Card $cardDisk ('R {0:N1}  W {1:N1} MB/s' -f $rd, $wr) ('{0}  {1:N0}%' -f (@('正常', '较忙', '很忙')[$lvl]), $busyPct) $lvl $ioSub $busyPct

    # 本窗口自己的占用
    $me = [Diagnostics.Process]::GetCurrentProcess()
    try {
        $script:selfMB = $me.PrivateMemorySize64 / 1MB
        $script:selfGdi = [NativeInfo]::GetGuiResources($me.Handle, 0)
        $c = $me.TotalProcessorTime.TotalMilliseconds
        if ($script:selfPrevCpu) { $script:selfCpu = 100 * ($c - $script:selfPrevCpu[0]) / ($nowU - $script:selfPrevCpu[1]).TotalMilliseconds / [Environment]::ProcessorCount }
        $script:selfPrevCpu = @($c, $nowU)
    } finally { $me.Dispose() }
    Record 'sys:self' $script:selfMB $nowU

    # 看门狗 + 自身占用
    $last = if ($script:sys.Count -gt 0) { $script:sys[$script:sys.Count - 1] } else { $null }
    $selfTxt = '本窗口 {0:N0} MB · CPU {1:N1}%' -f $script:selfMB, $script:selfCpu
    if (-not $script:taskState) {
        Set-Card $cardDog '未安装' '离线' 1 ($selfTxt + ' · 看门狗未安装') -1
    } elseif (-not $last) {
        Set-Card $cardDog '等待首次检查' '待命' 1 ($selfTxt + ' · 等待第一次检查') -1
    } else {
        $mins = ($now - $last.T).TotalMinutes
        $ok = $mins -le 25
        Set-Card $cardDog ('上次 ' + (Ago $last.T)) $(if ($ok) { '运行中' } else { '可能停了' }) $(if ($ok) { 0 } else { 2 }) ('{0} · 后台每次 {1:N1} 秒' -f $selfTxt, ([double]$last.RunMs / 1000)) ([math]::Min(100, $mins * 10))
    }

    # 体检结论
    $issues = @(); $seen = @{}
    foreach ($h in $script:hits) {
        $lv2 = if ($h.Rule.fix.type -eq 'none') { 1 } else { 2 }
        $issues += [pscustomobject]@{ Title = $h.Rule.title; Sub = $h.Why; Level = $lv2; Target = $h.Target; Key = "rule:$($h.Rule.id)" }; $seen[$h.Target] = 1
    }
    foreach ($r in $rows) {
        if ($seen.ContainsKey($r.Name)) { continue }
        $rt = $ratings[$r.Name]
        $label = if ($Desc[$r.Name]) { '{0}（{1}）' -f $r.Name, $Desc[$r.Name] } else { $r.Name }
        if ($rt.Level -lt 1) { continue }   # 正常的、或已被忽略 / 确认正常的
        if ($rt.Text -eq '疑似泄漏') { $issues += [pscustomobject]@{ Title = "$label 疑似内存泄漏"; Sub = $rt.Note; Level = 2; Target = $r.Name; Key = "prog:$($r.Name)" } }
        elseif ($rt.Text -eq '缓慢上涨') { $issues += [pscustomobject]@{ Title = "$label 在缓慢上涨"; Sub = $rt.Forecast; Level = 1; Target = $r.Name; Key = "prog:$($r.Name)" } }
        elseif ($rt.Text -eq '短时上涨') { $st = $script:series[$r.Name].Stats(120); if ($st -and $st[2] -ge 100) { $issues += [pscustomobject]@{ Title = "$label 在上涨（观察中）"; Sub = $rt.Note; Level = 1; Target = $r.Name; Key = "prog:$($r.Name)" } } }
    }
    foreach ($r in @($real | Where-Object { $_.IoMBs -ge $HeavyIoMBs } | Sort-Object IoMBs -Descending | Select-Object -First 2)) {
        if (Is-Ignored "io:$($r.Name)") { continue }
    }
    $issues = @($issues | Sort-Object { - $_.Level })
    $nBad = @($issues | Where-Object { $_.Level -eq 2 }).Count; $nWarn = @($issues | Where-Object { $_.Level -eq 1 }).Count
    $nLong = $script:analysis.Count
    $nShort = @($ratings.Values | Where-Object { $_.Trend -like '*分钟' }).Count
    $basis = '已评级 {0} 个程序（长期 {1} · 实时 {2}）· 规则 {3} 条' -f ($nLong + $nShort), $nLong, $nShort, $script:rules.Count
    $script:verdict = if ($nBad) { @("发现 $nBad 个问题", 2, $basis) }
        elseif ($nWarn) { @("有 $nWarn 项需要留意", 1, $basis) }
        elseif (($nLong + $nShort) -eq 0) { @('数据收集中', 1, '窗口打开满 10 分钟后给出初步判断') }
        else { @('电脑健康', 0, $basis) }
    if ($script:lastAction -and $issues.Count -lt 3) { $issues += [pscustomobject]@{ Title = '看门狗最近一次动作'; Sub = $script:lastAction; Level = -1; Target = $null } }
    $script:issues = $issues
    $diag.Invalidate()

    # 程序列表：内存前 25 + 有问题 / 需要留意 / 大量读写 / 被监控的；按当前排序方式排
    $list = @($real | Sort-Object PrivMB -Descending | Select-Object -First 25)
    $inList = @{}; foreach ($r in $list) { $inList[$r.Name] = 1 }
    foreach ($r in $rows) { if (-not $inList.ContainsKey($r.Name) -and ($ratings[$r.Name].Level -ge 1 -or $r.IoMBs -ge $HeavyIoMBs -or $script:watched.ContainsKey($r.Name))) { $list += $r; $inList[$r.Name] = 1 } }
    $list = switch ($script:sortMode) {
        'mem' { @($list | Sort-Object PrivMB -Descending) }
        'cpu' { @($list | Sort-Object CpuPct -Descending) }
        'io'  { @($list | Sort-Object IoMBs -Descending) }
        default { @($list | Sort-Object @{ Expression = { $ratings[$_.Name].Score + $(if ($_.IoMBs -ge $HeavyIoMBs) { 40 } else { 0 }) }; Descending = $true }, @{ Expression = 'PrivMB'; Descending = $true }) }
    }
    # 原地更新列表（不清空重建）：只改变了的格子，滚动位置和选中都保留。
    # 不用 BeginUpdate/EndUpdate：EndUpdate 会把整张列表擦掉重画，看起来像消失了一下再出现；
    # 逐格修改只重画变了的行，而且要等这次刷新结束后才一起画，不会闪
    $script:updating = $true
    try {
        while ($lv.Items.Count -gt $list.Count) { $lv.Items.RemoveAt($lv.Items.Count - 1) }
        for ($i = 0; $i -lt $list.Count; $i++) {
            $r = $list[$i]; $rt = $ratings[$r.Name]
            if ($i -lt $lv.Items.Count) { $it = $lv.Items[$i] }
            else { $it = New-Object Windows.Forms.ListViewItem(''); for ($k = 1; $k -lt 8; $k++) { [void]$it.SubItems.Add('') }; [void]$lv.Items.Add($it) }
            $vals = @($r.Name, [string]$Desc[$r.Name], ('{0:N0}' -f $r.PrivMB), ('{0:N1}' -f $r.CpuPct), ('{0:N1}' -f $r.IoMBs), $rt.Text, $rt.Trend, $(if ($rt.Forecast) { $rt.Forecast } else { $rt.Note }))
            for ($k = 0; $k -lt 8; $k++) { if ($it.SubItems[$k].Text -ne $vals[$k]) { $it.SubItems[$k].Text = $vals[$k] } }
            if ([int]$it.Tag -ne [int]$rt.Level -or $null -eq $it.Tag) { $it.Tag = [int]$rt.Level }
            $sel = $r.Name -eq $script:selected
            if ($it.Selected -ne $sel) { $it.Selected = $sel }
        }
    } finally { $script:updating = $false }
    Fit-Columns
    Update-DetailButtons
    $nIg = @(Active-Ignores).Count; Set-Text $btnIgnored $(if ($nIg) { "已忽略的问题（$nIg）" } else { '已忽略的问题' })

    $header.Invalidate(); $status.Invalidate(); $chart.Invalidate(); $detail.Invalidate()
}

function Dispose-All {
    [DiskPerf]::Close()
    foreach ($o in $GDI.Values) { $o.Dispose() }
    foreach ($f in $Fonts) { $f.Dispose() }
    foreach ($b in $script:icons.Values) { if ($b) { $b.Dispose() } }
    $rowH.Dispose(); $menu.Dispose()
    if ($script:formIcon) { $script:formIcon.Dispose() }
    if ($script:iconHandle -ne [IntPtr]::Zero) { [void][NativeInfo]::DestroyIcon($script:iconHandle) }
}

# 先取一次基准，CPU / 磁盘 / 读写速度才能算出差值
[void][DiskPerf]::Open()
[void][NativeInfo]::Cpu(); [void](Sample-Processes)

if ($SelfTest) {
    Start-Sleep -Milliseconds 800
    # 在屏幕外真实显示窗口，让所有控件都按正常流程创建和绘制
    $form.StartPosition = 'Manual'; $form.Location = New-Object Drawing.Point(-5000, -5000); $form.ShowInTaskbar = $false
    $form.Show(); [Windows.Forms.Application]::DoEvents()
    if ($SimMinutes -gt 0) {
        $rows0 = @(Sample-Processes | Where-Object { $_.Name -ne 'Idle' } | Sort-Object PrivMB -Descending | Select-Object -First 40)
        $n = [math]::Min($RingSize, $SimMinutes * 12); $t0 = [DateTime]::UtcNow.AddMinutes(-$SimMinutes)
        $rnd = New-Object Random 7
        for ($i = 0; $i -lt $n; $i++) {
            $t = $t0.AddSeconds($i * 5); $f = $i / [math]::Max(1, $n - 1)
            foreach ($r in $rows0) { $v = if ($r.Name -eq $SimRising) { $r.PrivMB - 250 * (1 - $f) } else { $r.PrivMB * (1 + ($rnd.NextDouble() - 0.5) * 0.02) }; Record $r.Name $v $t }
            Record 'sys:mem' (19 + $f + $rnd.NextDouble() * 0.3) $t; Record 'sys:cpu' (20 + 15 * [math]::Sin($i / 20) + $rnd.NextDouble() * 8) $t
            Record 'sys:dr' ([math]::Max(0, $rnd.NextDouble() * 3 - 1)) $t; Record 'sys:dw' ([math]::Max(0, $rnd.NextDouble() * 6 - 2 + $(if ($i % 90 -lt 5) { 40 } else { 0 }))) $t
            Record 'sys:self' (128 + $rnd.NextDouble() * 4) $t
        }
    }
    $bmp = New-Object Drawing.Bitmap($form.Width, $form.Height)
    $rect = New-Object Drawing.Rectangle(0, 0, $form.Width, $form.Height)
    $mem = @()
    for ($i = 1; $i -le $Loops; $i++) {
        Refresh-All
        [Windows.Forms.Application]::DoEvents()   # 处理重绘消息
        $form.DrawToBitmap($bmp, $rect)           # 再完整画一遍，检查绘制有没有泄漏
        if ($i -eq [math]::Min(20, $Loops) -or $i -eq $Loops -or $i % 150 -eq 0) {
            [GC]::Collect(); [GC]::WaitForPendingFinalizers()
            $me = [Diagnostics.Process]::GetCurrentProcess()
            $mem += '第 {0} 次刷新+重绘后：本程序 {1:N1} MB，托管堆 {2:N1} MB，句柄 {3}，GDI 对象 {4}，USER 对象 {5}，图标缓存 {6}，实时数据 {7} 条' -f $i, ($me.PrivateMemorySize64 / 1MB), ([GC]::GetTotalMemory($true) / 1MB), $me.HandleCount, [NativeInfo]::GetGuiResources($me.Handle, 0), [NativeInfo]::GetGuiResources($me.Handle, 1), $script:icons.Count, $script:series.Count
            $me.Dispose()
        }
    }
    if ($Snapshot) { $bmp.Save($Snapshot, [Drawing.Imaging.ImageFormat]::Png) }
    $bmp.Dispose()
    foreach ($c in $CardList) { '{0}: {1} [{2}] {3}' -f $c.Tag.Tag, $c.Tag.Value, $c.Tag.Badge, $c.Tag.Sub }
    '结论: {0} | {1}' -f $script:verdict[0], $script:verdict[2]
    foreach ($is in $script:issues) { '  - [{0}] {1} | {2} | -> {3}' -f $is.Level, $is.Title, $is.Sub, $is.Target }
    '评级:'
    foreach ($k in ($script:ratings.Keys | Where-Object { $script:ratings[$_].Text -ne '数据不足' })) { '  {0}: {1}(级别 {5}, {6}) | {2} | {3} | {4}' -f $k, $script:ratings[$k].Text, $script:ratings[$k].Trend, $script:ratings[$k].Note, $script:ratings[$k].Forecast, $script:ratings[$k].Level, $script:ratings[$k].Level.GetType().Name }
    '主按钮: ' + $btnPrimary.Text
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
