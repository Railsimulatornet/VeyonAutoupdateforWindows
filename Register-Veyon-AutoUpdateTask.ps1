param([Parameter(Mandatory = $true)][string]$UpdaterPath)

$ErrorActionPreference = 'Stop'
$env:PSModulePath = [IO.Path]::Combine($PSHOME, 'Modules')
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
$task.SetSecurityDescriptor('O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)', 0x10)
$descriptor = [Security.AccessControl.RawSecurityDescriptor]::new($task.GetSecurityDescriptor(7))
# Verify the effective owner and rights returned by the Task Scheduler service.
if ($null -eq $descriptor.Owner -or $descriptor.Owner.Value -ne 'S-1-5-32-544' -or
    $null -eq $descriptor.Group -or $descriptor.Group.Value -ne 'S-1-5-32-544' -or
    -not ($descriptor.ControlFlags -band [Security.AccessControl.ControlFlags]::DiscretionaryAclPresent) -or
    $null -eq $descriptor.DiscretionaryAcl -or $descriptor.DiscretionaryAcl.Count -ne 2) {
    throw 'Besitzer oder Zugriffsregeln der Aufgabe entsprechen nicht den Vorgaben.'
}
$seen = @{}
foreach ($ace in $descriptor.DiscretionaryAcl) {
    if ($ace.AceType -ne [Security.AccessControl.AceType]::AccessAllowed -or
        $ace.AceFlags -ne [Security.AccessControl.AceFlags]::None -or
        $ace.SecurityIdentifier.Value -notin @('S-1-5-18', 'S-1-5-32-544') -or
        $ace.AccessMask -notin @(0x001F01FF, 0x10000000) -or
        $seen.ContainsKey($ace.SecurityIdentifier.Value)) {
        throw 'Die Aufgabenberechtigungen konnten nicht abgesichert werden.'
    }
    $seen[$ace.SecurityIdentifier.Value] = $true
}
Write-Host "Trigger: $triggerText (2 Minuten Verzoegerung)"
