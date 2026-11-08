# Memory-leak watchdog + history recorder for MemMonitor.
# Runs as a scheduled task every 10 minutes, takes a few seconds, then exits.
# It never stays resident, so it cannot leak memory itself.
# What to check and how to fix it comes from rules.json (shared) + rules.local.json (your own, not in git).
#   -DryRun      : only print what it would do, write nothing
#   -CollectOnly : record history, but never fix anything
param([switch]$DryRun, [switch]$CollectOnly)
$sw = [Diagnostics.Stopwatch]::StartNew()
$noAct = $DryRun -or $CollectOnly
$HistoryDays = 7

$log = Join-Path $PSScriptRoot 'MemWatchdog.log'
function Log($msg) {
    $tag = if ($DryRun) { '[dry-run] ' } elseif ($CollectOnly) { '[check-only] ' } else { '' }
    $line = '{0:yyyy-MM-dd HH:mm:ss} {1}{2}' -f (Get-Date), $tag, $msg
    Write-Host $line
    if (-not $noAct) { Add-Content -Path $log -Value $line -Encoding UTF8 }
}
function PrivMB($procs) { [int](($procs | Measure-Object PrivateMemorySize64 -Sum).Sum / 1MB) }

function Load-Rules {
    $all = @()
    foreach ($f in 'rules.json', 'rules.local.json') {
        $p = Join-Path $PSScriptRoot $f
        if (-not (Test-Path $p)) { continue }
        # PowerShell 5.1 returns a JSON array as ONE object; foreach unrolls it into single rules
        try { foreach ($r in (ConvertFrom-Json (Get-Content $p -Raw -Encoding UTF8))) { $all += $r } }
        catch { Log ("RULES ERROR in {0}: {1}" -f $f, $_.Exception.Message) }
    }
    $all
}

# Current private memory of a rule's process ("svc:Name" = the process hosting that service). $null = not running.
function Get-TargetMB($name) {
    if ($name -like 'svc:*') {
        $svc = Get-CimInstance Win32_Service -Filter "Name='$($name.Substring(4))'" -ErrorAction SilentlyContinue
        if (-not $svc -or $svc.ProcessId -eq 0) { return $null }
        $p = Get-Process -Id $svc.ProcessId -ErrorAction SilentlyContinue
        if (-not $p) { return $null }
        return PrivMB $p
    }
    $procs = @(Get-Process -Name $name -ErrorAction SilentlyContinue)
    if (-not $procs) { return $null }
    PrivMB $procs
}

# Returns a description of why the rule matched, or $null. All conditions in "when" must hold.
function Test-Rule($r) {
    $w = $r.when; $why = @()
    if ($w.process) {
        $mb = Get-TargetMB $w.process
        if ($null -eq $mb) { return $null }
        if ($w.minMB) { if ($mb -lt $w.minMB) { return $null }; $why += ('{0} {1} MB >= {2} MB' -f $w.process, $mb, $w.minMB) }
    }
    if ($w.file) {
        if (-not (Test-Path -LiteralPath $w.file)) { return $null }
        $fmb = [int]((Get-Item -LiteralPath $w.file).Length / 1MB)
        if ($w.minFileMB -and $fmb -lt $w.minFileMB) { return $null }
        $why += ('{0} {1} MB >= {2} MB' -f (Split-Path $w.file -Leaf), $fmb, $w.minFileMB)
    }
    if (-not $why) { return $null }
    $why -join ', '
}

function Restart-ProcessByName($name) {
    $procs = @(Get-Process -Name $name -ErrorAction SilentlyContinue)
    if (-not $procs) { return }
    $path = ($procs | Where-Object Path | Select-Object -First 1).Path
    $procs | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 5
    if ($path -and -not (Get-Process -Name $name -ErrorAction SilentlyContinue)) {
        Start-Process -FilePath $path -WorkingDirectory (Split-Path $path)
    }
}

function Invoke-Fix($r) {
    switch ($r.fix.type) {
        'restartProcess' { Restart-ProcessByName $r.when.process }
        'restartService' { & (Join-Path $PSScriptRoot 'Restart-ServiceHard.ps1') -Name $r.fix.service | Out-Null }
        'script'         { & (Join-Path $PSScriptRoot $r.fix.script) -Quiet | Out-Null }
    }
}

# ---- Check every rule ----
$rules = @(Load-Rules)
$fixedTargets = @{}
foreach ($r in $rules) {
    $why = Test-Rule $r
    if (-not $why) { Write-Host ("ok   {0}" -f $r.id); continue }
    if (-not $r.auto -or $r.fix.type -eq 'none') { Log ("NOTICE {0}: {1} ({2})" -f $r.id, $r.title, $why); continue }
    # one fix per target per run (e.g. the NVIDIA database rebuild already restarts the container)
    if ($fixedTargets.ContainsKey($r.target)) { Write-Host ("skip {0}: {1} already fixed this run" -f $r.id, $r.target); continue }
    Log ("FIX {0}: {1} ({2}) -> {3}" -f $r.id, $r.title, $why, $r.fix.label)
    if ($noAct) { continue }
    try { Invoke-Fix $r; $fixedTargets[$r.target] = 1 } catch { Log ("  failed: {0}" -f $_.Exception.Message) }
}

# ---- History for MemMonitor: one small CSV per day, old days deleted ----
if ($DryRun) { return }
$dataDir = Join-Path $PSScriptRoot 'data'
if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory -Path $dataDir | Out-Null }
$stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
$day   = (Get-Date).ToString('yyyyMMdd')

# Per program (grouped by name): top 30 by memory + every process named in a rule
$all = Get-Process
$groups = foreach ($g in ($all | Group-Object ProcessName)) {
    $cpuSec = 0.0
    foreach ($p in $g.Group) { try { $cpuSec += $p.TotalProcessorTime.TotalSeconds } catch {} }
    [pscustomobject]@{ Time = $stamp; Name = $g.Name; PrivMB = PrivMB $g.Group; Count = $g.Count; CpuSec = [math]::Round($cpuSec, 1) }
}
$ruleProcs = @($rules | ForEach-Object { $_.when.process } | Where-Object { $_ } | Sort-Object -Unique)
$rows = @($groups | Sort-Object PrivMB -Descending | Select-Object -First 30)
$have = @($rows | ForEach-Object { $_.Name })
$rows += @($groups | Where-Object { $ruleProcs -contains $_.Name -and $have -notcontains $_.Name })
# Services hidden inside svchost etc. get their own row: svc:<name>
foreach ($n in ($ruleProcs | Where-Object { $_ -like 'svc:*' })) {
    $mb = Get-TargetMB $n
    if ($null -ne $mb) { $rows += [pscustomobject]@{ Time = $stamp; Name = $n; PrivMB = $mb; Count = 1; CpuSec = 0 } }
}
$rows | Export-Csv -Path (Join-Path $dataDir "proc-$day.csv") -Append -NoTypeInformation -Encoding UTF8

# Whole system
$os  = Get-CimInstance Win32_OperatingSystem
$cpu = [int](Get-CimInstance Win32_Processor | Measure-Object LoadPercentage -Average).Average
$nvDb = 'C:\ProgramData\NVIDIA Corporation\nvtopps\nvtopps.db3'
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
