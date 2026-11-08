# Restart a Windows service safely, even if it hangs in "stop pending".
# If it won't stop within 15 s, its host process is killed - but ONLY when that process hosts
# this one service, so other services sharing the same svchost are never taken down.
# Needs admin. Usage: Restart-ServiceHard.ps1 -Name Audiosrv
param([Parameter(Mandatory)][string]$Name)

$svc = Get-CimInstance Win32_Service -Filter "Name='$Name'" -ErrorAction SilentlyContinue
if (-not $svc) { Write-Host "service not found: $Name"; exit 1 }
$hostPid = [int]$svc.ProcessId

& sc.exe stop $Name | Out-Null
for ($i = 0; $i -lt 15; $i++) {
    if ((Get-Service $Name).Status -eq 'Stopped') { break }
    Start-Sleep -Seconds 1
}
if ((Get-Service $Name).Status -ne 'Stopped' -and $hostPid -gt 0) {
    $shared = @(Get-CimInstance Win32_Service -Filter "ProcessId=$hostPid" -ErrorAction SilentlyContinue)
    if ($shared.Count -le 1) {
        Write-Host "$Name is stuck, force-ending its process $hostPid"
        Stop-Process -Id $hostPid -Force -ErrorAction SilentlyContinue
        if ($Name -eq 'Audiosrv') { Get-Process audiodg -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Seconds 2
    } else {
        Write-Host "$Name is stuck but shares process $hostPid with $($shared.Count - 1) other services; not killing it"
        exit 2
    }
}
Start-Service $Name
Write-Host "$Name restarted"
