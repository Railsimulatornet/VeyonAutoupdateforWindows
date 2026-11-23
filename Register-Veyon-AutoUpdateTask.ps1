param([Parameter(Mandatory = $true)][string]$UpdaterPath)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'VeyonUpdater.Security.ps1')
$root = Get-VeyonRoot
Assert-VeyonProtectedRoot -Root $root
$expected = Join-Path $root 'Start-VeyonUpdater.ps1'
if ([IO.Path]::GetFullPath($UpdaterPath) -ine $expected) {
    throw 'Unerwarteter Pfad fuer die geplante Aufgabe.'
}
Assert-VeyonSafePath -Path $expected
$powerKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
$power = Get-ItemProperty -LiteralPath $powerKey -ErrorAction SilentlyContinue
$fastStartup = $power -and $power.PSObject.Properties['HiberbootEnabled'] -and $power.HiberbootEnabled -eq 1
if ($fastStartup) {
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $triggerText = 'Benutzeranmeldung (Fast Startup aktiv)'
} else {
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $triggerText = 'Systemstart (Fast Startup aus)'
}
$trigger.Delay = 'PT2M'
$action = New-ScheduledTaskAction -Execute (Get-VeyonPowerShell) -WorkingDirectory $root -Argument (
    '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f $expected
)
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::FromHours(1)) -StartWhenAvailable
Register-ScheduledTask -TaskName 'Veyon AutoUpdate (winget)' -TaskPath '\' -Action $action `
    -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
$service = New-Object -ComObject Schedule.Service
$service.Connect()
$task = $service.GetFolder('\').GetTask('Veyon AutoUpdate (winget)')
$task.SetSecurityDescriptor('D:P(A;;GA;;;SY)(A;;GA;;;BA)', 0)
$descriptor = [Security.AccessControl.RawSecurityDescriptor]::new($task.GetSecurityDescriptor(4))
if (-not ($descriptor.ControlFlags -band [Security.AccessControl.ControlFlags]::DiscretionaryAclProtected)) {
    throw 'Die Aufgabenberechtigungen sind nicht gegen Vererbung geschuetzt.'
}
foreach ($ace in $descriptor.DiscretionaryAcl) {
    if ($ace.AceType -ne [Security.AccessControl.AceType]::AccessAllowed -or
        $ace.SecurityIdentifier.Value -notin @('S-1-5-18', 'S-1-5-32-544')) {
        throw 'Die Aufgabenberechtigungen konnten nicht abgesichert werden.'
    }
}
Write-Host "Trigger: $triggerText (2 Minuten Verzoegerung)"
