# Turn Sonic Studio (Nahimic / A-Volute) on or off.
# Off: disable its virtual devices, stop NahimicService, restart Windows Audio to free leaked memory.
# On : re-enable devices and service, restart Windows Audio.
# Usage: SonicStudio.ps1 -Mode On|Off|Status
param([ValidateSet('On','Off','Status')][string]$Mode = 'Status')

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($Mode -ne 'Status' -and -not $isAdmin) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Mode $Mode"
    exit
}

# Sonic Studio Virtual Mixer + A-Volute Nh3 audio effects component
$devices = Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match 'AVOLUTESS3VAD|AVOLUTE_NH3APO' }
$svcName = 'NahimicService'

# Restart Windows Audio; if it hangs in "stop pending", kill its host process.
function Restart-Audio {
    $audioPid = (Get-CimInstance Win32_Service -Filter "Name='Audiosrv'").ProcessId
    & sc.exe stop Audiosrv | Out-Null
    for ($i = 0; $i -lt 15; $i++) {
        if ((Get-Service Audiosrv).Status -eq 'Stopped') { break }
        Start-Sleep -Seconds 1
    }
    if ((Get-Service Audiosrv).Status -ne 'Stopped' -and $audioPid -gt 0) {
        Write-Host 'Windows Audio is stuck, force-ending it...'
        Stop-Process -Id $audioPid -Force -ErrorAction SilentlyContinue
        Get-Process audiodg -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }
    Start-Service Audiosrv
}

function Show-Status {
    foreach ($d in $devices) { Write-Host ("  {0,-45} {1}" -f $d.FriendlyName, $d.Status) }
    $s = Get-Service $svcName -ErrorAction SilentlyContinue
    if ($s) { Write-Host ("  {0,-45} {1} ({2})" -f $svcName, $s.Status, $s.StartType) }
    $audioPid = (Get-CimInstance Win32_Service -Filter "Name='Audiosrv'").ProcessId
    $p = Get-Process -Id $audioPid -ErrorAction SilentlyContinue
    if ($p) { Write-Host ("  {0,-45} {1} MB" -f 'Windows Audio (Audiosrv) memory', [int]($p.WorkingSet64/1MB)) }
}

if ($Mode -eq 'Off') {
    Write-Host 'Turning Sonic Studio OFF...'
    Stop-Service $svcName -Force -ErrorAction SilentlyContinue
    Set-Service $svcName -StartupType Manual -ErrorAction SilentlyContinue
    Get-Process -Name 'Nahimic*','SonicStudio*' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    foreach ($d in $devices) { Disable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false -ErrorAction SilentlyContinue }
    Restart-Audio
}
elseif ($Mode -eq 'On') {
    Write-Host 'Turning Sonic Studio ON...'
    foreach ($d in $devices) { Enable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false -ErrorAction SilentlyContinue }
    Set-Service $svcName -StartupType Automatic -ErrorAction SilentlyContinue
    Start-Service $svcName -ErrorAction SilentlyContinue
    Restart-Audio
    Write-Host 'If you need light sync, open Sonic Studio / Armoury Crate and pick the "Sonic Studio Virtual Mixer" output.'
}

Start-Sleep -Seconds 2
$devices = Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match 'AVOLUTESS3VAD|AVOLUTE_NH3APO' }
Write-Host 'Current status:'
Show-Status
if ($Mode -ne 'Status') { Write-Host ''; Read-Host 'Done. Press Enter to close' }
