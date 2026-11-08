# Register MemWatchdog.ps1 as a scheduled task (every 10 min + at logon, as you, with admin rights for service restarts).
# Run with -Uninstall to remove it.
param([switch]$Uninstall)

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    $extra = if ($Uninstall) { '-Uninstall' } else { '' }
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" $extra"
    exit
}

$taskName = 'MemWatchdog'
if ($Uninstall) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host 'Watchdog task removed.'
    Read-Host 'Press Enter to close'; exit
}

$script = Join-Path $PSScriptRoot 'MemWatchdog.ps1'
$user = "$env:USERDOMAIN\$env:USERNAME"
# conhost --headless keeps the window hidden
$action = New-ScheduledTaskAction -Execute 'conhost.exe' -Argument "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$script`""
$trigger = @(
    (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 10)),
    (New-ScheduledTaskTrigger -AtLogOn -User $user)
)
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
Write-Host "Installed: '$taskName' runs every 10 minutes and at logon. Log: $(Join-Path $PSScriptRoot 'MemWatchdog.log')"
Read-Host 'Press Enter to close'
