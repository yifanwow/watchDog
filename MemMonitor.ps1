# MemMonitor：内存 / CPU 监控面板
# 只在打开时运行，关掉窗口就完全退出。每 5 秒刷新一次，只保留最新一份数据，不会越用越大。
# 历史数据来自看门狗（MemWatchdog.ps1，每 10 分钟记录一次），用来判断是否有程序在持续泄漏内存。
#   -SelfTest -Loops N : 不显示窗口，连续刷新 N 次并打印结果和本程序内存（用来验证自身不泄漏）
param(
    [string]$DataDir = (Join-Path $PSScriptRoot 'data'),
    [switch]$SelfTest,
    [int]$Loops = 1
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
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
    public static MEMSTAT Mem() { MEMSTAT m = new MEMSTAT(); m.dwLength = (uint)Marshal.SizeOf(m); GlobalMemoryStatusEx(ref m); return m; }
    static long pIdle, pTotal;
    public static double Cpu() {
        long i, k, u; GetSystemTimes(out i, out k, out u);
        long t = k + u; double r = 0;
        if (pTotal > 0 && t - pTotal > 0) r = 100.0 * (1.0 - (double)(i - pIdle) / (t - pTotal));
        pIdle = i; pTotal = t;
        return Math.Max(0, Math.Min(100, r));
    }
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
$script:selected  = $null
$script:updating  = $false

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

# ---------- 界面 ----------
$font      = New-Object Drawing.Font('Microsoft YaHei UI', 9)
$fontTitle = New-Object Drawing.Font('Microsoft YaHei UI', 9, [Drawing.FontStyle]::Bold)
$fontBig   = New-Object Drawing.Font('Microsoft YaHei UI', 16, [Drawing.FontStyle]::Bold)
$fontBadge = New-Object Drawing.Font('Microsoft YaHei UI', 11, [Drawing.FontStyle]::Bold)
$cGreen = [Drawing.Color]::FromArgb(40, 150, 60)
$cAmber = [Drawing.Color]::FromArgb(200, 125, 0)
$cRed   = [Drawing.Color]::FromArgb(200, 40, 40)
$cGray  = [Drawing.Color]::FromArgb(110, 110, 110)
$bgRed   = [Drawing.Color]::FromArgb(255, 232, 232)
$bgAmber = [Drawing.Color]::FromArgb(255, 245, 220)

$form = New-Object Windows.Forms.Form
$form.Text = '内存 / CPU 监控'
$form.Size = New-Object Drawing.Size(1080, 780)
$form.MinimumSize = New-Object Drawing.Size(1080, 600)
$form.StartPosition = 'CenterScreen'
$form.Font = $font
$form.BackColor = [Drawing.Color]::FromArgb(248, 248, 248)

$top = New-Object Windows.Forms.Panel
$top.Dock = 'Top'; $top.Height = 118

function New-Card($x, $title) {
    $p = New-Object Windows.Forms.Panel
    $p.Location = New-Object Drawing.Point($x, 10); $p.Size = New-Object Drawing.Size(340, 100)
    $p.BackColor = [Drawing.Color]::White; $p.BorderStyle = 'FixedSingle'
    $t = New-Object Windows.Forms.Label; $t.Text = $title; $t.Font = $fontTitle; $t.Location = New-Object Drawing.Point(10, 8); $t.AutoSize = $true; $t.ForeColor = $cGray
    $v = New-Object Windows.Forms.Label; $v.Font = $fontBig; $v.Location = New-Object Drawing.Point(8, 28); $v.AutoSize = $true
    $b = New-Object Windows.Forms.Label; $b.Font = $fontBadge; $b.Location = New-Object Drawing.Point(230, 8); $b.Size = New-Object Drawing.Size(100, 24); $b.TextAlign = 'MiddleRight'
    $s = New-Object Windows.Forms.Label; $s.Location = New-Object Drawing.Point(10, 66); $s.Size = New-Object Drawing.Size(320, 30); $s.ForeColor = $cGray
    $p.Controls.AddRange(@($t, $v, $b, $s))
    $top.Controls.Add($p)
    @{ Value = $v; Badge = $b; Sub = $s }
}
$cardMem = New-Card 10  '内存'
$cardCpu = New-Card 360 'CPU'
$cardDog = New-Card 710 '看门狗'

function Set-Badge($card, $text, $color) { $card.Badge.Text = $text; $card.Badge.ForeColor = $color }

$leak = New-Object Windows.Forms.Label
$leak.Dock = 'Top'; $leak.Height = 70; $leak.Padding = New-Object Windows.Forms.Padding(12, 6, 12, 4)
$leak.BackColor = [Drawing.Color]::White

$lv = New-Object Windows.Forms.ListView
$lv.Dock = 'Fill'; $lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.HideSelection = $false; $lv.MultiSelect = $false
foreach ($c in @(@('程序', 170), @('说明', 200), @('内存 (MB)', 85), @('CPU %', 65), @('进程数', 60), @('状态', 85), @('24 小时变化', 150), @('备注', 230))) {
    $col = $lv.Columns.Add($c[0], $c[1]); if ($c[0] -match 'MB|CPU|进程') { $col.TextAlign = 'Right' }
}

$chart = New-Object Windows.Forms.PictureBox
$chart.Dock = 'Bottom'; $chart.Height = 170; $chart.BackColor = [Drawing.Color]::White

$status = New-Object Windows.Forms.Label
$status.Dock = 'Bottom'; $status.Height = 22; $status.ForeColor = $cGray; $status.Padding = New-Object Windows.Forms.Padding(8, 3, 0, 0)

$form.Controls.Add($lv)
$form.Controls.Add($leak)
$form.Controls.Add($top)
$form.Controls.Add($chart)
$form.Controls.Add($status)
$lv.BringToFront()

$lv.Add_SelectedIndexChanged({
    if ($script:updating) { return }
    if ($lv.SelectedItems.Count -gt 0) { $script:selected = $lv.SelectedItems[0].Text; $chart.Invalidate() }
})

$chart.Add_Paint({
    param($s, $e)
    $g = $e.Graphics
    $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $w = $s.Width; $h = $s.Height
    $name = $script:selected
    $txt = New-Object Drawing.SolidBrush($cGray)
    try {
        if (-not $name -or -not $script:hist.ContainsKey($name) -or $script:hist[$name].Count -lt 2) {
            $msg = if ($name) { "$name ：还没有足够的历史数据（看门狗每 10 分钟记录一次）" } else { '点选上方某个程序，这里显示它最近 24 小时的内存曲线（数据来自看门狗，每 10 分钟一个点）' }
            $g.DrawString($msg, $font, $txt, 12, 12)
            return
        }
        $pts = $script:hist[$name]
        $L = 70; $R = 20; $T = 30; $B = 26
        $pw = $w - $L - $R; $ph = $h - $T - $B
        $end = Get-Date; $begin = $end.AddHours(-24)
        $max = 0.0; $min = [double]::MaxValue
        foreach ($p in $pts) { if ($p.MB -gt $max) { $max = $p.MB }; if ($p.MB -lt $min) { $min = $p.MB } }
        $lo = [math]::Max(0, $min - ($max - $min) * 0.15 - 10); $hi = $max + ($max - $min) * 0.15 + 10
        $title = '{0}（{1}）最近 24 小时内存，单位 MB' -f $name, $(if ($Desc[$name]) { $Desc[$name] } else { '-' })
        $g.DrawString($title, $fontTitle, $txt, 10, 6)
        $grid = New-Object Drawing.Pen([Drawing.Color]::FromArgb(230, 230, 230))
        try {
            for ($i = 0; $i -le 3; $i++) {
                $y = $T + $ph * $i / 3
                $g.DrawLine($grid, $L, $y, $L + $pw, $y)
                $g.DrawString(('{0:N0}' -f ($hi - ($hi - $lo) * $i / 3)), $font, $txt, 4, $y - 8)
            }
            for ($hr = 0; $hr -le 24; $hr += 6) {
                $x = $L + $pw * $hr / 24
                $g.DrawLine($grid, $x, $T, $x, $T + $ph)
                $g.DrawString($begin.AddHours($hr).ToString('HH:mm'), $font, $txt, $x - 16, $T + $ph + 4)
            }
        } finally { $grid.Dispose() }
        $arr = New-Object 'System.Collections.Generic.List[System.Drawing.PointF]'
        foreach ($p in $pts) {
            $x = $L + $pw * (($p.T - $begin).TotalHours / 24)
            $y = $T + $ph * (1 - ($p.MB - $lo) / ($hi - $lo))
            $arr.Add((New-Object Drawing.PointF([single]$x, [single]$y)))
        }
        $st = (Get-Status $name $pts[$pts.Count - 1].MB)[0]
        $lineColor = if ($st -eq '疑似泄漏') { $cRed } elseif ($st -eq '占用较大') { $cAmber } else { [Drawing.Color]::FromArgb(40, 110, 200) }
        $pen = New-Object Drawing.Pen($lineColor, 2)
        try { $g.DrawLines($pen, $arr.ToArray()) } finally { $pen.Dispose() }
    } finally { $txt.Dispose() }
})

function Refresh-All {
    if ($form.WindowState -eq [Windows.Forms.FormWindowState]::Minimized) { return }
    $now = Get-Date
    if (($now - $script:lastSlow).TotalSeconds -ge 60) { $script:lastSlow = $now; Update-Slow }

    # 内存
    $m = [NativeInfo]::Mem()
    $totalGB = $m.ullTotalPhys / 1GB; $usedGB = ($m.ullTotalPhys - $m.ullAvailPhys) / 1GB
    $pct = 100 * $usedGB / $totalGB
    $commitGB = ($m.ullTotalPageFile - $m.ullAvailPageFile) / 1GB; $limitGB = $m.ullTotalPageFile / 1GB
    $cpct = 100 * $commitGB / $limitGB
    $cardMem.Value.Text = '{0:N1} / {1:N0} GB  ({2:N0}%)' -f $usedGB, $totalGB, $pct
    $worst = [math]::Max($pct, $cpct)
    if ($worst -lt 70) { Set-Badge $cardMem '正常' $cGreen } elseif ($worst -lt 85) { Set-Badge $cardMem '偏高' $cAmber } else { Set-Badge $cardMem '紧张' $cRed }
    $cardMem.Sub.Text = '已提交 {0:N1} / {1:N0} GB（{2:N0}%）。70% 以下都算正常，空着的内存不会让电脑更快。' -f $commitGB, $limitGB, $cpct

    # CPU（取最近 30 秒平均，避免一瞬间的波动）
    $script:cpuHist.Enqueue([NativeInfo]::Cpu())
    while ($script:cpuHist.Count -gt 6) { [void]$script:cpuHist.Dequeue() }
    $cpuAvg = ($script:cpuHist | Measure-Object -Average).Average
    $procs = Sample-Processes
    $busy = @($procs | Where-Object { $_.Name -notlike 'svc:*' -and $_.Name -ne 'Idle' } | Sort-Object CpuPct -Descending | Select-Object -First 2)
    $cardCpu.Value.Text = '{0:N0}%' -f $cpuAvg
    if ($cpuAvg -lt 50) { Set-Badge $cardCpu '正常' $cGreen } elseif ($cpuAvg -lt 85) { Set-Badge $cardCpu '较忙' $cAmber } else { Set-Badge $cardCpu '很忙' $cRed }
    $cardCpu.Sub.Text = '最近 30 秒平均。最忙：' + (($busy | ForEach-Object { '{0} {1:N1}%' -f $_.Name, $_.CpuPct }) -join '，')

    # 看门狗
    $last = if ($script:sys.Count -gt 0) { $script:sys[$script:sys.Count - 1] } else { $null }
    if (-not $script:taskState) {
        Set-Badge $cardDog '未安装' $cAmber; $cardDog.Value.Text = '没有自动运行'
        $cardDog.Sub.Text = '运行 Install-Watchdog.ps1 安装后，每 10 分钟自动检查一次。'
    } elseif (-not $last) {
        Set-Badge $cardDog '等待中' $cAmber; $cardDog.Value.Text = '还没有记录'
        $cardDog.Sub.Text = '已安装，第一次检查完成后这里会显示结果。'
    } else {
        $lt = [datetime]::ParseExact($last.Time, 'yyyy-MM-dd HH:mm:ss', $null)
        $cardDog.Value.Text = '上次检查 ' + (Ago $lt)
        if (($now - $lt).TotalMinutes -le 25) { Set-Badge $cardDog '运行中' $cGreen } else { Set-Badge $cardDog '可能停了' $cRed }
        $cardDog.Sub.Text = '每次检查耗时 {0:N1} 秒，查完就退出，不常驻内存。' -f ([double]$last.RunMs / 1000)
    }

    # 泄漏提示
    $rows = @($procs | Where-Object { $_.Name -ne 'Idle' -and $_.Name -ne 'Memory Compression' })
    $suspects = @(foreach ($r in $rows) { $st = Get-Status $r.Name $r.PrivMB; if ($st[0] -eq '疑似泄漏') { '{0}（{1:+#,0} MB/小时）' -f $r.Name, $script:analysis[$r.Name].Slope } })
    $lines = @()
    if ($script:hist.Count -eq 0) { $lines += '还没有历史数据：看门狗安装后每 10 分钟记录一次，大约 2 小时后开始判断有没有内存泄漏。' }
    elseif ($suspects.Count -gt 0) { $lines += '⚠ 疑似内存泄漏（内存持续稳定地上涨）：' + ($suspects -join '、') }
    else { $lines += '✓ 最近 24 小时没有发现持续上涨的程序。' }
    if ($script:nvMB -gt 300) { $lines += "⚠ NVIDIA 的 nvtopps.db3 已经 $($script:nvMB) MB（正常只有几 MB），看门狗下次检查会自动重建它。" }
    if ($script:lastAction) { $lines += '看门狗最近一次动作：' + $script:lastAction }
    $leak.Text = $lines -join "`r`n"
    $leak.ForeColor = if ($suspects.Count -gt 0 -or $script:nvMB -gt 300) { $cRed } else { [Drawing.Color]::Black }

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
            if ($st[0] -eq '疑似泄漏') { $it.BackColor = $bgRed; $it.ForeColor = $cRed }
            elseif ($st[0] -eq '占用较大') { $it.BackColor = $bgAmber }
            [void]$lv.Items.Add($it)
            if ($r.Name -eq $script:selected) { $it.Selected = $true }
        }
    } finally { $lv.EndUpdate(); $script:updating = $false }

    # 本窗口自己的占用
    $me = [Diagnostics.Process]::GetCurrentProcess()
    try { $myMB = $me.PrivateMemorySize64 / 1MB } finally { $me.Dispose() }
    $status.Text = '每 5 秒刷新（窗口最小化时暂停）　·　本窗口自身占用 {0:N0} MB　·　历史数据：{1}' -f $myMB, $DataDir
    $chart.Invalidate()
}

# 先取一次基准，CPU 才能算出差值
[void][NativeInfo]::Cpu(); [void](Sample-Processes)

if ($SelfTest) {
    Start-Sleep -Milliseconds 500
    $mem = @()
    for ($i = 1; $i -le $Loops; $i++) {
        Refresh-All
        if ($i -eq [math]::Min(20, $Loops) -or $i -eq $Loops) {
            [GC]::Collect(); [GC]::WaitForPendingFinalizers()
            $me = [Diagnostics.Process]::GetCurrentProcess()
            $mem += '第 {0} 次刷新后：本程序 {1:N1} MB，托管堆 {2:N1} MB，句柄 {3}' -f $i, ($me.PrivateMemorySize64 / 1MB), ([GC]::GetTotalMemory($true) / 1MB), $me.HandleCount
            $me.Dispose()
        }
    }
    '内存卡片: ' + $cardMem.Value.Text + ' [' + $cardMem.Badge.Text + ']'
    'CPU 卡片: ' + $cardCpu.Value.Text + ' [' + $cardCpu.Badge.Text + '] ' + $cardCpu.Sub.Text
    '看门狗卡片: ' + $cardDog.Value.Text + ' [' + $cardDog.Badge.Text + '] ' + $cardDog.Sub.Text
    '提示栏: ' + $leak.Text
    '--- 列表前 10 ---'
    foreach ($it in ($lv.Items | Select-Object -First 10)) { ($it.SubItems | ForEach-Object { $_.Text }) -join ' | ' }
    '--- 异常项 ---'
    foreach ($it in $lv.Items) { if ($it.SubItems[5].Text -ne '正常') { ($it.SubItems | ForEach-Object { $_.Text }) -join ' | ' } }
    '--- 自身内存 ---'
    $mem
    $form.Dispose()
    return
}

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 5000
$timer.Add_Tick({ Refresh-All })
$form.Add_Shown({ Start-Sleep -Milliseconds 300; Refresh-All; $timer.Start() })
$form.Add_FormClosed({ $timer.Stop(); $timer.Dispose() })
[void]$form.ShowDialog()
$form.Dispose()
