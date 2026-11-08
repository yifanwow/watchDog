# Memory-leak watchdog + history recorder for MemMonitor.
# Runs as a scheduled task every 10 minutes, takes a few seconds, then exits.
# It never stays resident, so it cannot leak memory itself.
#   -DryRun      : only print what it would do, write nothing
#   -CollectOnly : record history, but never restart anything
param([switch]$DryRun, [switch]$CollectOnly)
$sw = [Diagnostics.Stopwatch]::StartNew()
$noAct = $DryRun -or $CollectOnly

# ---- Config (limits in MB of private memory) ----
$Apps = @(
    @{ Name = 'lghub_system_tray'; LimitMB = 800 }   # Logitech G HUB tray
    @{ Name = 'BongoCat';          LimitMB = 2500 }  # ~1.4 GB is its normal size
    @{ Name = 'HueSync';           LimitMB = 2500 }  # ~1.3 GB normal; light sync pauses a few seconds
)
$Services = @(
    @{ Name = 'Audiosrv';          LimitMB = 1000 }  # Windows Audio, sound drops ~3s
    @{ Name = 'LightingService';   LimitMB = 1200 }  # ASUS Aura
    @{ Name = 'NVDisplay.ContainerLocalSystem'; LimitMB = 1500 }  # NVIDIA display container, screen may flicker once
)
# Only report, never restart (would interrupt you / log you out)
$WatchOnly = @(
    @{ Name = 'Weixin';            LimitMB = 3000 }
)
$NvToppsLimitMB = 300     # NVIDIA nvtopps.db3, normally a few MB
$HistoryDays    = 7       # history files kept for MemMonitor
# --------------------------------------------------

$log = Join-Path $PSScriptRoot 'MemWatchdog.log'
function Log($msg) {
    $tag = if ($DryRun) { '[dry-run] ' } elseif ($CollectOnly) { '[check-only] ' } else { '' }
    $line = '{0:yyyy-MM-dd HH:mm:ss} {1}{2}' -f (Get-Date), $tag, $msg
    Write-Host $line
    if (-not $noAct) { Add-Content -Path $log -Value $line -Encoding UTF8 }
}
function PrivMB($procs) { [int](($procs | Measure-Object PrivateMemorySize64 -Sum).Sum / 1MB) }

# ---- Leaky apps ----
foreach ($a in $Apps) {
    $procs = @(Get-Process -Name $a.Name -ErrorAction SilentlyContinue)
    if (-not $procs) { continue }
    $mb = PrivMB $procs
    if ($mb -le $a.LimitMB) { Write-Host ("ok   {0}: {1} MB (limit {2})" -f $a.Name, $mb, $a.LimitMB); continue }
    $path = ($procs | Where-Object Path | Select-Object -First 1).Path
    Log ("RESTART {0}: {1} MB > {2} MB" -f $a.Name, $mb, $a.LimitMB)
    if ($noAct) { continue }
    $procs | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 5
    if ($path -and -not (Get-Process -Name $a.Name -ErrorAction SilentlyContinue)) {
        Start-Process -FilePath $path -WorkingDirectory (Split-Path $path)
    }
}

# ---- NVIDIA nvtopps.db3 bloat: restarting the container alone doesn't help, the database must be rebuilt ----
# Keeps one backup (nvtopps.bak-auto), replacing the previous auto backup.
$nvDir = 'C:\ProgramData\NVIDIA Corporation\nvtopps'
$nvDb  = Join-Path $nvDir 'nvtopps.db3'
if (Test-Path $nvDb) {
    $dbMB = [int]((Get-Item $nvDb).Length / 1MB)
    if ($dbMB -le $NvToppsLimitMB) { Write-Host ("ok   nvtopps.db3: {0} MB (limit {1})" -f $dbMB, $NvToppsLimitMB) }
    else {
        Log ("REBUILD nvtopps.db3: {0} MB > {1} MB" -f $dbMB, $NvToppsLimitMB)
        if (-not $noAct) {
            $svcName = 'NVDisplay.ContainerLocalSystem'
            $oldPid = (Get-CimInstance Win32_Service -Filter "Name='$svcName'").ProcessId
            & sc.exe stop $svcName | Out-Null
            for ($i = 0; $i -lt 15; $i++) { if ((Get-Service $svcName).Status -eq 'Stopped') { break }; Start-Sleep 1 }
            if ((Get-Service $svcName).Status -ne 'Stopped' -and $oldPid -gt 0) { Stop-Process -Id $oldPid -Force -ErrorAction SilentlyContinue; Start-Sleep 2 }
            Get-Process NVDisplay.Container -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep 1
            $bak = "$nvDir.bak-auto"
            if (Test-Path $bak) { Remove-Item $bak -Recurse -Force -ErrorAction SilentlyContinue }
            try { Rename-Item $nvDir $bak -ErrorAction Stop } catch { Log ("  rename failed: {0}" -f $_.Exception.Message) }
            Start-Service $svcName -ErrorAction SilentlyContinue
        }
    }
}

# ---- Leaky services ----
foreach ($s in $Services) {
    $svc = Get-CimInstance Win32_Service -Filter "Name='$($s.Name)'" -ErrorAction SilentlyContinue
    if (-not $svc -or $svc.ProcessId -eq 0) { continue }
    $mb = PrivMB (Get-Process -Id $svc.ProcessId -ErrorAction SilentlyContinue)
    if ($mb -le $s.LimitMB) { Write-Host ("ok   {0}: {1} MB (limit {2})" -f $s.Name, $mb, $s.LimitMB); continue }
    Log ("RESTART service {0}: {1} MB > {2} MB" -f $s.Name, $mb, $s.LimitMB)
    if ($noAct) { continue }
    try { Restart-Service $s.Name -Force -ErrorAction Stop } catch { Log ("  failed: {0}" -f $_.Exception.Message) }
}

# ---- Report only ----
foreach ($w in $WatchOnly) {
    $procs = @(Get-Process -Name $w.Name -ErrorAction SilentlyContinue)
    if (-not $procs) { continue }
    $mb = PrivMB $procs
    if ($mb -gt $w.LimitMB) { Log ("HIGH {0}: {1} MB > {2} MB - restart it yourself when convenient" -f $w.Name, $mb, $w.LimitMB) }
    else { Write-Host ("ok   {0}: {1} MB (limit {2})" -f $w.Name, $mb, $w.LimitMB) }
}

# ---- History for MemMonitor: one small CSV per day, old days deleted ----
if ($DryRun) { return }
$dataDir = Join-Path $PSScriptRoot 'data'
if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory -Path $dataDir | Out-Null }
$stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
$day   = (Get-Date).ToString('yyyyMMdd')

# Per program (grouped by name): top 30 by memory + everything on the watch lists
$all = Get-Process
$groups = foreach ($g in ($all | Group-Object ProcessName)) {
    $cpuSec = 0.0
    foreach ($p in $g.Group) { try { $cpuSec += $p.TotalProcessorTime.TotalSeconds } catch {} }
    [pscustomobject]@{ Time = $stamp; Name = $g.Name; PrivMB = PrivMB $g.Group; Count = $g.Count; CpuSec = [math]::Round($cpuSec, 1) }
}
$watchNames = @($Apps | ForEach-Object { $_.Name }) + @($WatchOnly | ForEach-Object { $_.Name })
$rows = @($groups | Sort-Object PrivMB -Descending | Select-Object -First 30)
$have = @($rows | ForEach-Object { $_.Name })
$rows += @($groups | Where-Object { $watchNames -contains $_.Name -and $have -notcontains $_.Name })
# Services hidden inside svchost etc. get their own row: svc:<name>
foreach ($s in $Services) {
    $svc = Get-CimInstance Win32_Service -Filter "Name='$($s.Name)'" -ErrorAction SilentlyContinue
    if (-not $svc -or $svc.ProcessId -eq 0) { continue }
    $p = Get-Process -Id $svc.ProcessId -ErrorAction SilentlyContinue
    if ($p) { $rows += [pscustomobject]@{ Time = $stamp; Name = "svc:$($s.Name)"; PrivMB = PrivMB $p; Count = 1; CpuSec = 0 } }
}
$rows | Export-Csv -Path (Join-Path $dataDir "proc-$day.csv") -Append -NoTypeInformation -Encoding UTF8

# Whole system
$os  = Get-CimInstance Win32_OperatingSystem
$cpu = [int](Get-CimInstance Win32_Processor | Measure-Object LoadPercentage -Average).Average
$dbNow = if (Test-Path $nvDb) { [int]((Get-Item $nvDb).Length / 1MB) } else { 0 }
[pscustomobject]@{
    Time          = $stamp
    UsedMB        = [int](($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1KB)
    TotalMB       = [int]($os.TotalVisibleMemorySize / 1KB)
    CommitMB      = [int](($os.TotalVirtualMemorySize - $os.FreeVirtualMemory) / 1KB)
    CommitLimitMB = [int]($os.TotalVirtualMemorySize / 1KB)
    CpuPct        = $cpu
    NvToppsMB     = $dbNow
    RunMs         = $sw.ElapsedMilliseconds
} | Export-Csv -Path (Join-Path $dataDir "sys-$day.csv") -Append -NoTypeInformation -Encoding UTF8

Get-ChildItem $dataDir -Filter '*.csv' | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$HistoryDays) } | Remove-Item -Force -ErrorAction SilentlyContinue
