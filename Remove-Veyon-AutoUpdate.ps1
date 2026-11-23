# Veyon Updater V1.5.0
param([switch]$DeleteBackups)
$ErrorActionPreference = 'Stop'

function Invoke-VeyonRemoval {
    param([switch]$DeleteBackups)
    . (Join-Path $PSScriptRoot 'VeyonUpdater.Security.ps1')
    $root = Get-VeyonRoot
    $lock = $null
    $taskDisabled = $false
    $taskRemoved = $false
    $wasEnabled = $false
    try {
        if ([IO.Directory]::Exists($root)) {
            Assert-VeyonProtectedRoot -Root $root
            $lock = Enter-VeyonUpdateLock -Root $root
            if (-not $lock) { throw 'Eine Installation oder Aktualisierung laeuft bereits.' }
        }
        $task = Get-ScheduledTask -TaskPath '\' | Where-Object TaskName -eq 'Veyon AutoUpdate (winget)'
        if ($task) {
            $expected = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + (Join-Path $root 'Start-VeyonUpdater.ps1') + '"'
            if (@($task.Actions).Count -ne 1 -or $task.Actions.Arguments -cne $expected -or
                $task.Actions.Execute -ine (Get-VeyonPowerShell) -or
                $task.Principal.UserId -notin @('SYSTEM', 'S-1-5-18')) {
                throw 'Unter dem Aufgabennamen ist eine unerwartete Aufgabe vorhanden. Sie wurde nicht entfernt.'
            }
            $wasEnabled = [bool]$task.Settings.Enabled
            Disable-ScheduledTask -TaskName 'Veyon AutoUpdate (winget)' -TaskPath '\' | Out-Null
            $taskDisabled = $true
            if ((Get-ScheduledTask -TaskName 'Veyon AutoUpdate (winget)' -TaskPath '\').State -eq 'Running') {
                throw 'Die Aktualisierung laeuft gerade. Bitte ihren Abschluss abwarten.'
            }
            Unregister-ScheduledTask -TaskName 'Veyon AutoUpdate (winget)' -TaskPath '\' -Confirm:$false
            if (Get-ScheduledTask -TaskPath '\' | Where-Object TaskName -eq 'Veyon AutoUpdate (winget)') {
                throw 'Die geplante Aufgabe konnte nicht entfernt werden.'
            }
            $taskRemoved = $true
        }
        if ([IO.Directory]::Exists($root)) {
            Assert-VeyonProtectedRoot -Root $root
            $directories = @('versions', 'staging', 'logs')
            if ($DeleteBackups) { $directories += 'config-backups' }
            foreach ($name in $directories) {
                $path = Join-Path $root $name
                if ([IO.Directory]::Exists($path)) { [IO.Directory]::Delete($path, $true) }
            }
            foreach ($name in @('Start-VeyonUpdater.ps1', 'VeyonUpdater.Security.ps1',
                'VeyonUpdater-release-public.cer', 'state.json', 'state.json.bak',
                'veyon_autoupdate.log', 'winget_last.log', 'selfupdate.log', 'selfupdate-check.txt')) {
                $path = Join-Path $root $name
                if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) }
            }
            foreach ($item in Get-ChildItem -LiteralPath $root -File -Force) {
                if ($item.Name -cmatch '^state-[a-f0-9]{32}\.tmp$') { [IO.File]::Delete($item.FullName) }
            }
        }
    } catch {
        if ($taskDisabled -and -not $taskRemoved -and $wasEnabled) {
            Enable-ScheduledTask -TaskName 'Veyon AutoUpdate (winget)' -TaskPath '\' | Out-Null
        }
        throw
    } finally {
        if ($lock) { $lock.Dispose() }
    }
    if ($DeleteBackups -and [IO.Directory]::Exists($root)) {
        Assert-VeyonProtectedRoot -Root $root
        $lockFile = Join-Path $root 'update.lock'
        if ([IO.File]::Exists($lockFile)) { [IO.File]::Delete($lockFile) }
        [IO.Directory]::Delete($root, $false)
    }
    Write-Host 'FERTIG. Die automatische Aktualisierung wurde entfernt. Veyon bleibt installiert.'
    if (-not $DeleteBackups -and [IO.Directory]::Exists((Join-Path $root 'config-backups'))) {
        Write-Host ('Konfigurationssicherungen bleiben geschuetzt erhalten: ' + (Join-Path $root 'config-backups'))
    }
}

try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        $powerShell = Join-Path ([Environment]::GetFolderPath('Windows')) 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (-not [Environment]::Is64BitProcess -and [Environment]::Is64BitOperatingSystem) {
            $powerShell = Join-Path ([Environment]::GetFolderPath('Windows')) 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
        }
        $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f $PSCommandPath
        if ($DeleteBackups) { $arguments += ' -DeleteBackups' }
        $process = Start-Process -FilePath $powerShell -Verb RunAs -Wait -PassThru -ArgumentList $arguments
        exit $process.ExitCode
    }
    Invoke-VeyonRemoval -DeleteBackups:$DeleteBackups
    exit 0
} catch {
    Write-Host ('FEHLER: ' + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
