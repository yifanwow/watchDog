# MemMonitor：内存 / CPU / 磁盘 监控面板（赛博朋克风格界面：红黑底 + 荧光蓝）
# 和任务管理器的区别：不只看"现在谁占得多"，而是看"谁在变坏、为什么、怎么修"——
#   1. 稳定性评级：用看门狗记录的 24 小时历史，判断每个程序是稳定、波动、缓慢上涨还是疑似泄漏，并预测 24 小时后的占用
#   2. 问题规则库：rules.json（公共）+ rules.local.json（自己的）写明"症状 → 原因 → 修复方法"，命中就给出修复按钮
# 只在打开时运行，关掉窗口就完全退出。每 5 秒刷新一次，只保留最新一份数据，不会越用越大。
# 所有画笔 / 画刷 / 字体只在启动时创建一次；系统句柄（进程、磁盘计数器）用完立即关闭；图标缓存有上限。
#   -SelfTest -Loops N [-Snapshot x.png] [-Select 程序名] : 在屏幕外显示窗口，连续刷新并重绘 N 次，打印结果和自身资源
param(
    [string]$DataDir = (Join-Path $PSScriptRoot 'data'),
    [string]$RulesDir = $PSScriptRoot,
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
$LeakSlopeMBh = 50     # 疑似泄漏：每小时至少涨 50 MB
$LeakGrowthMB = 300    #           累计至少涨 300 MB
$LeakR2       = 0.6    #           涨势稳定（不是忽高忽低）
$RiseSlopeMBh = 15     # 缓慢上涨：每小时至少涨 15 MB
$RiseGrowthMB = 100    #           累计至少涨 100 MB
$RiseR2       = 0.5
$WobbleCv     = 0.15   # 波动大：波动幅度超过平均值的 15%
$HeavyIoMBs   = 30     # 单个程序读写超过这个速度会提示

# ---------- 状态（每次刷新都整体替换，不累积） ----------
$script:prevCpu   = @{}; $script:prevIo = @{}; $script:prevTime = $null; $script:denied = @{}
$script:cpuHist   = New-Object 'System.Collections.Generic.Queue[double]'
$script:hist      = @{}; $script:analysis = @{}; $script:sys = @(); $script:histSig = ''
$script:lastSlow  = [datetime]::MinValue; $script:forceSlowAt = $null
$script:svcPid    = @{}; $script:taskState = $null; $script:lastAction = ''
$script:rules     = @(); $script:rulesSig = ''; $script:fileMB = @{}
$script:hits      = @(); $script:hitByTarget = @{}
$script:selected  = if ($Select) { $Select } else { $null }
$script:updating  = $false; $script:tick = 0; $script:sortMode = 'issue'
$script:selfMB = 0; $script:selfGdi = 0; $script:selfCpu = 0.0; $script:selfPrevCpu = $null
$script:issues    = @(); $script:verdict = @('正在检查…', -1, ''); $script:issueRects = @()
$script:rows = @{}; $script:ratings = @{}; $script:disk = @(0, 0, 0)
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
    $mean = $sy / $m
    $cv = if ($mean -gt 0) { [math]::Sqrt([math]::Max(0, $syy / $m - $mean * $mean)) / $mean } else { 0 }
    [pscustomobject]@{ Slope = $num / $den; R2 = $r2; Growth = $pts[$n - 1].MB - $pts[$start].MB; Span = $span; Cv = $cv }
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

function Load-Rules {
    $files = @(foreach ($n in 'rules.json', 'rules.local.json') { $p = Join-Path $RulesDir $n; if (Test-Path $p) { Get-Item $p } })
    $sig = ($files | ForEach-Object { '{0}:{1}' -f $_.Name, $_.LastWriteTimeUtc.Ticks }) -join '|'
    if ($sig -eq $script:rulesSig) { return }
    $script:rulesSig = $sig
    $all = @()
    # PowerShell 5.1 把 JSON 数组当成一个整体返回，用 foreach 拆成单条规则
    foreach ($f in $files) { try { foreach ($r in (ConvertFrom-Json (Get-Content $f.FullName -Raw -Encoding UTF8))) { $all += $r } } catch {} }
    $script:rules = $all
}

function Update-Slow {
    # 每分钟一次：规则、历史数据、服务进程号、计划任务状态、最近动作、规则里的文件大小
    Load-Rules
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
        $t = if ($r.target) { $r.target } else { $w.process }
        $h = [pscustomobject]@{ Rule = $r; Why = ($why -join '；'); Target = $t }
        $hits += $h
        if ($t -and -not $byT.ContainsKey($t)) { $byT[$t] = $h }
    }
    $script:hits = $hits; $script:hitByTarget = $byT
}

function Fmt-MB($mb) { if ($mb -ge 1024) { '{0:N1} GB' -f ($mb / 1024) } else { '{0:N0} MB' -f $mb } }

# 稳定性评级。Level：2 = 有问题（红）、1 = 需要留意（黄）、0 = 正常（蓝）、-1 = 中性（灰）。Score 用于"问题优先"排序。
function Get-Rating($name, $mb) {
    $hit = $script:hitByTarget[$name]
    if ($hit) {
        $lvl = if ($hit.Rule.fix.type -eq 'none') { 1 } else { 2 }
        return [pscustomobject]@{ Text = '已知问题'; Level = $lvl; Score = (100 + 5 * $lvl); Note = $hit.Rule.title; Forecast = '' }
    }
    $a = $script:analysis[$name]
    # 现在的占用比最后一条记录低很多 = 刚被重启过，之前的趋势作废
    if ($a -and $script:hist.ContainsKey($name)) {
        $lastMB = $script:hist[$name][$script:hist[$name].Count - 1].MB
        if ($mb -lt 0.6 * $lastMB) { $a = $null }
    }
    if (-not $a) { return [pscustomobject]@{ Text = '数据不足'; Level = -1; Score = 0; Note = ''; Forecast = '' } }
    $fc = if ($a.Slope -gt 0) { '照这个速度，24 小时后约 ' + (Fmt-MB ($mb + $a.Slope * 24)) } else { '' }
    $note = '近 {0:N1} 小时涨了 {1:N0} MB（约 {2:N0} MB/小时）' -f $a.Span, $a.Growth, $a.Slope
    if ($a.Slope -ge $LeakSlopeMBh -and $a.Growth -ge $LeakGrowthMB -and $a.R2 -ge $LeakR2) {
        return [pscustomobject]@{ Text = '疑似泄漏'; Level = 2; Score = 90; Note = $note; Forecast = $fc }
    }
    if ($a.Slope -ge $RiseSlopeMBh -and $a.Growth -ge $RiseGrowthMB -and $a.R2 -ge $RiseR2) {
        return [pscustomobject]@{ Text = '缓慢上涨'; Level = 1; Score = 60; Note = $note; Forecast = $fc }
    }
    if ($a.Cv -ge $WobbleCv) { return [pscustomobject]@{ Text = '波动大'; Level = -1; Score = 10; Note = '忽高忽低，通常是正常使用（比如开关网页）'; Forecast = '' } }
    [pscustomobject]@{ Text = '稳定'; Level = 0; Score = 0; Note = ''; Forecast = '' }
}

function Trend-Text($name) {
    $a = $script:analysis[$name]
    if (-not $a) { return '—' }
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
$form.Size = New-Object Drawing.Size(1340, 980)
$form.MinimumSize = New-Object Drawing.Size(1150, 920)
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
    Txt $g '// 不只看谁占得多，而是看谁在变坏、为什么、怎么修' $fCN $cAccent 152 6 520 34
    $live = if ($script:tick % 2 -eq 0) { $GDI['lv2'] } else { $GDI['panel'] }
    $g.FillRectangle($live, $w - 250, 17, 8, 8)
    Txt $g ('LIVE  ' + (Get-Date).ToString('HH:mm')) $fTagB $cCyan ($w - 234) 6 90 28
    Txt $g 'SYS.MON v5 // 0x5744' $fSmall $cRedDim ($w - 200) 6 186 28 $tfR
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
        Txt $g $is.Title $fCNb $c 30 $y ($w - 44) 18
        Txt $g $is.Sub $fCN $cGray 30 ($y + 17) ($w - 44) 17
        $rects += , @($y, ($y + 36), $is.Target)
        $y += 38
    }
    $script:issueRects = $rects
})
$diag.Add_MouseClick({
    param($s, $e)
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
    if (-not $r) { Txt $g '在左边列表里点选一个程序（或点上面的问题），这里显示它的稳定性、原因和修复方法。' $fCN $cGray 14 40 ($w - 28) 60 $tfW; return }
    $icon = Get-Icon $name
    if ($icon) { $g.InterpolationMode = 'HighQualityBicubic'; $g.DrawImage($icon, 14, 38, 32, 32) }
    else { $g.FillRectangle($GDI['dim'], 14, 38, 32, 32); $g.DrawRectangle($GDI['accPen'], 14, 38, 32, 32) }
    Txt $g $name $fCNbig $cCyan 56 36 ($w - 70) 22
    Txt $g $(if ($Desc[$name]) { $Desc[$name] } else { '-' }) $fCN $cGray 56 58 ($w - 70) 18
    $cols = @(@('内存', ('{0:N0} MB' -f $r.PrivMB)), @('CPU', ('{0:N1} %' -f $r.CpuPct)), @('读写', ('{0:N1} MB/s' -f $r.IoMBs)), @('进程', [string]$r.Count))
    $cw = ($w - 28) / 4
    for ($i = 0; $i -lt 4; $i++) {
        Txt $g $cols[$i][0] $fCN $cGray (14 + $i * $cw) 80 $cw 16
        Txt $g $cols[$i][1] $fTagB $cText (14 + $i * $cw) 96 $cw 20
    }
    $rt = Get-Rating $name $r.PrivMB
    Txt $g ('稳定性：' + $rt.Text) $fCNb $LevelColor[[int]$rt.Level] 14 122 130 18
    Txt $g $(if ($rt.Text -eq '已知问题') { Trend-Text $name } else { $rt.Note }) $fCN $cGray 140 122 ($w - 154) 18
    $hit = $script:hitByTarget[$name]
    if ($hit) {
        Txt $g ('已知问题：' + $hit.Rule.title) $fCNb $LevelColor[[int]$rt.Level] 14 144 ($w - 28) 18
        Txt $g ($hit.Why + '。' + $hit.Rule.cause) $fCN $cGray 14 164 ($w - 28) 30 $tfW
    } elseif ($rt.Forecast) {
        Txt $g $rt.Forecast $fCNb $LevelColor[[int]$rt.Level] 14 144 ($w - 28) 18
    } elseif ($rt.Text -eq '数据不足') {
        Txt $g '看门狗记录满 2 小时后才能判断稳定性。' $fCN $cGray 14 144 ($w - 28) 18
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

# ---------- 主区域：程序列表 + 曲线 ----------
$main = New-Object Windows.Forms.Panel
$main.Dock = 'Fill'; $main.BackColor = $cBg; $main.Padding = New-Object Windows.Forms.Padding(12, 0, 12, 0)

$lv = New-Object BufferedListView
$lv.Dock = 'Fill'; $lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.HideSelection = $false; $lv.MultiSelect = $false
$lv.OwnerDraw = $true; $lv.BackColor = $cRowA; $lv.ForeColor = $cText; $lv.BorderStyle = 'None'
$rowH = New-Object Windows.Forms.ImageList; $rowH.ImageSize = New-Object Drawing.Size(1, 28); $lv.SmallImageList = $rowH
foreach ($c in @(@('程序', 175), @('说明', 140), @('内存 MB', 80), @('CPU %', 58), @('读写 MB/s', 78), @('稳定性', 78), @('24 小时变化', 135), @('判断 / 预测', 180))) {
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
        Txt $g $it.Text $fCNb $cText ($r.X + 34) $r.Y ($r.Width - 40) $r.Height
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
    if ($lv.SelectedItems.Count -gt 0) { $script:selected = $lv.SelectedItems[0].Text; Update-DetailButtons; $chart.Invalidate(); $detail.Invalidate() }
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
    $cur = if ($script:rows[$name]) { $script:rows[$name].PrivMB } else { $pts[$pts.Count - 1].MB }
    $rt = Get-Rating $name $cur
    $lvl = if ($rt.Level -lt 0) { 0 } else { [int]$rt.Level }
    $title = '{0}  ·  {1}  ·  {2}' -f $name, $(if ($Desc[$name]) { $Desc[$name] } else { '-' }), $rt.Text
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
    $txt = '每 5 秒刷新 · 最小化时暂停 · 本窗口：内存 {0:N0} MB / CPU {1:N2}% / GDI {2} · 后台检查：每 10 分钟约 5 秒，查完即退出 · 点列标题可切换排序' -f $script:selfMB, $script:selfCpu, $script:selfGdi
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
    try { foreach ($it in $lv.Items) { $it.Selected = ($it.Text -eq $name); if ($it.Selected) { $it.EnsureVisible() } } } finally { $script:updating = $false }
    Update-DetailButtons; $detail.Invalidate(); $chart.Invalidate(); $lv.Invalidate()
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
        if ((Get-Rating $r.Name $r.PrivMB).Text -eq '疑似泄漏') { $todo += , @(('重启 {0}（疑似泄漏）' -f $r.Name), $r.Name); $seen[$r.Name] = 1 }
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
function Edit-Rules {
    $p = Join-Path $RulesDir 'rules.local.json'
    if (-not (Test-Path $p)) { Copy-Item (Join-Path $RulesDir 'rules.local.example.json') $p }
    Start-Process notepad.exe "`"$p`""
    $script:forceSlowAt = (Get-Date).AddSeconds(20)
}

# 右键菜单
$menu = New-Object Windows.Forms.ContextMenuStrip
$menu.Renderer = New-Object Windows.Forms.ToolStripProfessionalRenderer((New-Object CyberColors))
$menu.Font = $fCN; $menu.ForeColor = $cText
$menuFix = $menu.Items.Add('修复 / 重启'); $menuFix.ForeColor = $cText; $menuFix.Add_Click({ Fix-Selected })
foreach ($m in @(@('结束这个程序', { Kill-Target $script:selected }), @('打开文件位置', { Open-Location $script:selected }))) {
    $item = $menu.Items.Add($m[0]); $item.ForeColor = $cText; $item.Add_Click($m[1])
}
$menu.Add_Opening({ param($s, $e); if (-not $script:selected) { $e.Cancel = $true } else { $menuFix.Text = $btnPrimary.Text } })
$lv.ContextMenuStrip = $menu

# 选中程序的按钮：主按钮的文字随规则变化（命中规则时显示对应的修复方法）
$btnPrimary = New-Btn $detail '重启这个程序' 14 196 334 { Fix-Selected } -Primary
$btnKill    = New-Btn $detail '结束' 14 234 163 { Kill-Target $script:selected }
$btnOpen    = New-Btn $detail '打开位置' 185 234 163 { Open-Location $script:selected }
function Update-DetailButtons {
    $name = $script:selected
    $hit = if ($name) { $script:hitByTarget[$name] } else { $null }
    $btnPrimary.Text = if ($hit) { if ($hit.Rule.fix.type -eq 'none') { '查看建议：' + $hit.Rule.fix.label } else { '修复：' + $hit.Rule.fix.label } } elseif ($name -like 'svc:*') { '重启这个服务' } else { '重启这个程序' }
}

# 操作区按钮（两列）
$ax = 14; $half = 163; $full = 334; $ay = 36; $step = 38
$btnFix     = New-Btn $actions '一键修复全部问题' $ax $ay $full { Fix-All } -Primary; $ay += $step
$btnNow     = New-Btn $actions '立即检查一次' $ax $ay $half { Run-CheckNow }
$btnNv      = New-Btn $actions '修复 NVIDIA 数据库' ($ax + $half + 8) $ay $half { if (Ask '将停止并重建 NVIDIA 的 nvtopps 数据库，屏幕可能闪一下。需要管理员权限。确定吗？') { Run-Tool 'Fix-NvTopps.ps1'; Reload-Soon } }; $ay += $step
$btnRules   = New-Btn $actions '编辑我的规则' $ax $ay $half { Edit-Rules }
$btnFolder  = New-Btn $actions '打开工具文件夹' ($ax + $half + 8) $ay $half { Start-Process explorer.exe "`"$ToolDir`"" }; $ay += $step
$btnInstall = New-Btn $actions '安装看门狗（每 10 分钟自动检查）' $ax $ay $full {
    if ($script:taskState) { if (Ask '将删除看门狗计划任务，之后不再自动检查。确定吗？') { Run-Tool 'Install-Watchdog.ps1' '-Uninstall' } }
    else { Run-Tool 'Install-Watchdog.ps1' }
    $script:forceSlowAt = (Get-Date).AddSeconds(15)
}

# ---------- 刷新 ----------
function Refresh-All {
    if ($form.WindowState -eq [Windows.Forms.FormWindowState]::Minimized) { return }
    $script:tick++
    $now = Get-Date
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

    # 进程采样 + 规则
    $script:cpuHist.Enqueue([NativeInfo]::Cpu())
    while ($script:cpuHist.Count -gt 6) { [void]$script:cpuHist.Dequeue() }
    $cpuAvg = ($script:cpuHist | Measure-Object -Average).Average
    $procs = Sample-Processes
    $rows = @($procs | Where-Object { $_.Name -ne 'Idle' -and $_.Name -ne 'Memory Compression' })
    $byName = @{}; foreach ($r in $rows) { $byName[$r.Name] = $r }
    $script:rows = $byName
    Eval-Rules
    $ratings = @{}; foreach ($r in $rows) { $ratings[$r.Name] = Get-Rating $r.Name $r.PrivMB }
    $script:ratings = $ratings
    $real = @($rows | Where-Object { $_.Name -notlike 'svc:*' })

    # CPU（最近 30 秒平均）
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
        Set-Card $cardDog ('上次 ' + (Ago $lt)) $(if ($ok) { '运行中' } else { '可能停了' }) $(if ($ok) { 0 } else { 2 }) ('每次约 {0:N1} 秒 · 规则 {1} 条 · 进度条 = 距下次检查' -f ([double]$last.RunMs / 1000), $script:rules.Count) ([math]::Min(100, $mins * 10))
    }

    # 体检结论
    $issues = @(); $seen = @{}
    foreach ($h in $script:hits) {
        $lv2 = if ($h.Rule.fix.type -eq 'none') { 1 } else { 2 }
        $issues += [pscustomobject]@{ Title = $h.Rule.title; Sub = $h.Why; Level = $lv2; Target = $h.Target }; $seen[$h.Target] = 1
    }
    foreach ($r in $rows) {
        if ($seen.ContainsKey($r.Name)) { continue }
        $rt = $ratings[$r.Name]
        $label = if ($Desc[$r.Name]) { '{0}（{1}）' -f $r.Name, $Desc[$r.Name] } else { $r.Name }
        if ($rt.Text -eq '疑似泄漏') { $issues += [pscustomobject]@{ Title = "$label 疑似内存泄漏"; Sub = $rt.Note; Level = 2; Target = $r.Name } }
        elseif ($rt.Text -eq '缓慢上涨') { $issues += [pscustomobject]@{ Title = "$label 在缓慢上涨"; Sub = $rt.Forecast; Level = 1; Target = $r.Name } }
    }
    foreach ($r in @($real | Where-Object { $_.IoMBs -ge $HeavyIoMBs } | Sort-Object IoMBs -Descending | Select-Object -First 2)) {
        $issues += [pscustomobject]@{ Title = ('{0} 正在大量读写' -f $r.Name); Sub = ('{0:N0} MB/s。偶尔一下正常，一直这样要注意硬盘磨损。' -f $r.IoMBs); Level = 1; Target = $r.Name }
    }
    $issues = @($issues | Sort-Object { - $_.Level })
    $nBad = @($issues | Where-Object { $_.Level -eq 2 }).Count; $nWarn = @($issues | Where-Object { $_.Level -eq 1 }).Count
    $basis = '已分析 {0} 个程序的 24 小时记录 · 规则 {1} 条' -f $script:analysis.Count, $script:rules.Count
    $script:verdict = if ($nBad) { @("发现 $nBad 个问题", 2, $basis) }
        elseif ($nWarn) { @("有 $nWarn 项需要留意", 1, $basis) }
        elseif ($script:hist.Count -eq 0) { @('数据收集中', 1, '看门狗每 10 分钟记录一次，约 2 小时后开始判断稳定性') }
        else { @('电脑健康', 0, $basis) }
    if ($script:lastAction -and $issues.Count -lt 3) { $issues += [pscustomobject]@{ Title = '看门狗最近一次动作'; Sub = $script:lastAction; Level = -1; Target = $null } }
    $script:issues = $issues
    $diag.Invalidate()

    # 程序列表：内存前 25 + 有问题 / 需要留意 / 大量读写的；按当前排序方式排
    $list = @($real | Sort-Object PrivMB -Descending | Select-Object -First 25)
    $inList = @{}; foreach ($r in $list) { $inList[$r.Name] = 1 }
    foreach ($r in $rows) { if (-not $inList.ContainsKey($r.Name) -and ($ratings[$r.Name].Level -ge 1 -or $r.IoMBs -ge $HeavyIoMBs)) { $list += $r; $inList[$r.Name] = 1 } }
    $list = switch ($script:sortMode) {
        'mem' { @($list | Sort-Object PrivMB -Descending) }
        'cpu' { @($list | Sort-Object CpuPct -Descending) }
        'io'  { @($list | Sort-Object IoMBs -Descending) }
        default { @($list | Sort-Object @{ Expression = { $ratings[$_.Name].Score + $(if ($_.IoMBs -ge $HeavyIoMBs) { 40 } else { 0 }) }; Descending = $true }, @{ Expression = 'PrivMB'; Descending = $true }) }
    }
    $script:updating = $true
    $lv.BeginUpdate()
    try {
        $lv.Items.Clear()
        foreach ($r in $list) {
            $rt = $ratings[$r.Name]
            $it = New-Object Windows.Forms.ListViewItem($r.Name)
            $it.Tag = [int]$rt.Level
            [void]$it.SubItems.Add([string]$Desc[$r.Name])
            [void]$it.SubItems.Add(('{0:N0}' -f $r.PrivMB))
            [void]$it.SubItems.Add(('{0:N1}' -f $r.CpuPct))
            [void]$it.SubItems.Add(('{0:N1}' -f $r.IoMBs))
            [void]$it.SubItems.Add($rt.Text)
            [void]$it.SubItems.Add((Trend-Text $r.Name))
            [void]$it.SubItems.Add($(if ($rt.Forecast) { $rt.Forecast } else { $rt.Note }))
            [void]$lv.Items.Add($it)
            if ($r.Name -eq $script:selected) { $it.Selected = $true }
        }
    } finally { $lv.EndUpdate(); $script:updating = $false }
    Fit-Columns
    Update-DetailButtons

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
        if ($i -eq [math]::Min(20, $Loops) -or $i -eq $Loops -or $i % 150 -eq 0) {
            [GC]::Collect(); [GC]::WaitForPendingFinalizers()
            $me = [Diagnostics.Process]::GetCurrentProcess()
            $mem += '第 {0} 次刷新+重绘后：本程序 {1:N1} MB，托管堆 {2:N1} MB，句柄 {3}，GDI 对象 {4}，USER 对象 {5}，图标缓存 {6}' -f $i, ($me.PrivateMemorySize64 / 1MB), ([GC]::GetTotalMemory($true) / 1MB), $me.HandleCount, [NativeInfo]::GetGuiResources($me.Handle, 0), [NativeInfo]::GetGuiResources($me.Handle, 1), $script:icons.Count
            $me.Dispose()
        }
    }
    if ($Snapshot) { $bmp.Save($Snapshot, [Drawing.Imaging.ImageFormat]::Png) }
    $bmp.Dispose()
    foreach ($c in @($cardMem, $cardCpu, $cardDisk, $cardDog)) { '{0}: {1} [{2}] {3}' -f $c.Tag.Tag, $c.Tag.Value, $c.Tag.Badge, $c.Tag.Sub }
    '结论: {0} | {1}' -f $script:verdict[0], $script:verdict[2]
    foreach ($is in $script:issues) { '  - [{0}] {1} | {2} | -> {3}' -f $is.Level, $is.Title, $is.Sub, $is.Target }
    '评级:'
    foreach ($k in ($script:ratings.Keys | Where-Object { $script:ratings[$_].Text -ne '数据不足' -and $script:ratings[$_].Text -ne '稳定' })) { '  {0}: {1} | {2} | {3}' -f $k, $script:ratings[$k].Text, $script:ratings[$k].Note, $script:ratings[$k].Forecast }
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
