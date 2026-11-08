# Fix NVDisplay.Container high memory / disk use caused by a bloated nvtopps.db3.
# Stops the NVIDIA display container, renames the nvtopps folder (NVIDIA rebuilds a fresh one), starts it again.
# Keeps ONE backup (nvtopps.bak), replacing the previous one, so backups never pile up.
#   -Quiet : no "press Enter" at the end (used by the watchdog)
param([switch]$Quiet)

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    $extra = if ($Quiet) { '-Quiet' } else { '' }
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" $extra"
    exit
}

$out  = Join-Path $PSScriptRoot 'Fix-NvTopps.log'
$name = 'NVDisplay.ContainerLocalSystem'
$dir  = 'C:\ProgramData\NVIDIA Corporation\nvtopps'
$bak  = "$dir.bak"
function Log($m) { $l = '{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $m; Write-Host $l; Add-Content $out $l -Encoding UTF8 }

$old = (Get-CimInstance Win32_Service -Filter "Name='$name'").ProcessId
Log "stopping $name (pid $old)"
& sc.exe stop $name | Out-Null
for ($i = 0; $i -lt 15; $i++) { if ((Get-Service $name).Status -eq 'Stopped') { break }; Start-Sleep 1 }
if ((Get-Service $name).Status -ne 'Stopped') { Log 'stuck, force-ending'; Stop-Process -Id $old -Force -ErrorAction SilentlyContinue; Start-Sleep 2 }
Get-Process NVDisplay.Container -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep 1

if (Test-Path $dir) {
    if (Test-Path $bak) { Remove-Item $bak -Recurse -Force -ErrorAction SilentlyContinue }
    try { Rename-Item $dir $bak -ErrorAction Stop; Log 'renamed nvtopps -> nvtopps.bak' }
    catch { Log "rename failed: $($_.Exception.Message)" }
}

Start-Service $name
Start-Sleep 10
$s = Get-CimInstance Win32_Service -Filter "Name='$name'"
$p = Get-Process -Id $s.ProcessId -ErrorAction SilentlyContinue
Log ("after: {0} pid {1}, {2} MB" -f $s.State, $s.ProcessId, [int]($p.PrivateMemorySize64 / 1MB))
if (Test-Path "$dir\nvtopps.db3") { Log ("new nvtopps.db3: {0:N1} MB" -f ((Get-Item "$dir\nvtopps.db3").Length / 1MB)) }
if (-not $Quiet) { Read-Host 'Done. Press Enter to close' }
