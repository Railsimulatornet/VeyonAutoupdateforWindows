param(
    [Parameter(Mandatory = $true)]
    [string]$UpdaterPath
)

$ErrorActionPreference = 'Stop'
$powerKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
$fastStartup = (Get-ItemProperty -LiteralPath $powerKey).HiberbootEnabled -eq 1

if ($fastStartup) {
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $triggerText = 'Benutzeranmeldung (Fast Startup aktiv)'
} else {
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $triggerText = 'Systemstart (Fast Startup aus)'
}
$trigger.Delay = 'PT2M'

$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument (
    '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $UpdaterPath
)
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

Register-ScheduledTask -TaskName 'Veyon AutoUpdate (winget)' -TaskPath '\' -Action $action `
    -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
Write-Host "Trigger: $triggerText"
