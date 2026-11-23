param([Parameter(Mandatory = $true)][string]$AssetDirectory)

$ErrorActionPreference = 'Stop'
$taskName = 'Veyon AutoUpdate (winget)'
$taskPath = '\'
$destination = 'C:\ProgramData\Veyon\Update'
$powerKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
$currentFastStartup = Get-ItemProperty -LiteralPath $powerKey
$installDir = Split-Path -Parent $destination
$installDirExisted = Test-Path -LiteralPath $installDir
$oldNoPause = $env:VEYON_SETUP_NO_PAUSE

if (Get-ScheduledTask -TaskPath $taskPath -ErrorAction SilentlyContinue |
    Where-Object TaskName -eq $taskName) {
    throw 'The installer smoke test requires a clean VM with no existing Veyon task.'
}
if (Test-Path -LiteralPath $destination) {
    throw 'The installer smoke test requires a clean VM with no existing Veyon Update directory.'
}

function Assert-Installation([string]$TriggerType, [string]$Source) {
    $task = Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath
    $xml = [xml](Export-ScheduledTask -TaskName $taskName -TaskPath $taskPath)
    $trigger = $xml.Task.Triggers.$TriggerType
    if (-not $trigger -or [Xml.XmlConvert]::ToTimeSpan($trigger.Delay).TotalSeconds -ne 120) {
        throw "Expected $TriggerType with a two-minute delay."
    }
    if ($xml.Task.Principals.Principal.UserId -ne 'S-1-5-18' -or $task.Principal.RunLevel -ne 'Highest') {
        throw 'Expected SYSTEM with highest privileges.'
    }
    if (-not $task.Settings.Enabled -or $task.Settings.DisallowStartIfOnBatteries -or $task.Settings.StopIfGoingOnBatteries) {
        throw 'Expected an enabled task that starts and keeps running on battery.'
    }
    $installed = Join-Path $destination 'Veyon-AutoUpdate.ps1'
    if ($task.Actions.Count -ne 1 -or $task.Actions.Execute -ne 'powershell.exe' -or
        $task.Actions.Arguments -ne ('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $installed)) {
        throw 'Unexpected updater task action.'
    }
    if ((Get-FileHash -LiteralPath $installed).Hash -ne (Get-FileHash -LiteralPath $Source).Hash) {
        throw 'The installed updater differs from the release payload.'
    }
    if (@(Get-ChildItem -LiteralPath $destination -Force).Count -ne 1) {
        throw 'The installation dry run unexpectedly created logs or backups.'
    }
    Write-Host "PASS: $TriggerType, two-minute delay, SYSTEM, battery settings, updater hash and clean dry run"
}

$config = Get-Content (Join-Path $PSScriptRoot '../release.json') -Raw | ConvertFrom-Json
$assetRoot = (Get-Item -LiteralPath $AssetDirectory).FullName
$zip = Join-Path $assetRoot $config.archive
$setup = Join-Path $assetRoot $config.setup
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('veyon setup ' + [guid]::NewGuid())
try {
    $env:VEYON_SETUP_NO_PAUSE = '1'
    Expand-Archive -LiteralPath $zip -DestinationPath $temporary
    $updater = Join-Path $temporary 'Veyon-AutoUpdate.ps1'
    Set-ItemProperty -LiteralPath $powerKey -Name HiberbootEnabled -Type DWord -Value 0
    Push-Location -LiteralPath $temporary
    try {
        & $env:ComSpec /d /c Install-Veyon-AutoUpdate.cmd
        if ($LASTEXITCODE -ne 0) { throw "ZIP installation failed with exit code $LASTEXITCODE." }
    } finally {
        Pop-Location
    }
    Assert-Installation -TriggerType BootTrigger -Source $updater
    Write-Host 'PASS: release ZIP installer'

    # Keep the existing task to exercise repair in place. Removing the updater
    # verifies that the actual setup EXE ran and copied its payload again.
    Remove-Item -LiteralPath (Join-Path $destination 'Veyon-AutoUpdate.ps1')
    Set-ItemProperty -LiteralPath $powerKey -Name HiberbootEnabled -Type DWord -Value 1
    $process = Start-Process -FilePath $setup -ArgumentList '-y' -PassThru
    try {
        if (-not $process.WaitForExit(60000)) {
            & taskkill.exe /PID $process.Id /T /F | Out-Host
            throw 'Setup EXE timed out.'
        }
        if ($process.ExitCode -ne 0) { throw "Setup EXE failed with exit code $($process.ExitCode)." }
    } finally {
        $process.Dispose()
    }
    Assert-Installation -TriggerType LogonTrigger -Source $updater
    Write-Host 'PASS: release setup EXE replaced the existing task'
} finally {
    $env:VEYON_SETUP_NO_PAUSE = $oldNoPause
    if ($currentFastStartup.PSObject.Properties['HiberbootEnabled']) {
        Set-ItemProperty -LiteralPath $powerKey -Name HiberbootEnabled -Type DWord -Value $currentFastStartup.HiberbootEnabled
    } else {
        Remove-ItemProperty -LiteralPath $powerKey -Name HiberbootEnabled -ErrorAction SilentlyContinue
    }
    Unregister-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Confirm:$false -ErrorAction SilentlyContinue
    foreach ($path in @($destination, $temporary)) {
        if ([IO.Directory]::Exists($path)) { [IO.Directory]::Delete($path, $true) }
    }
    if (-not $installDirExisted -and [IO.Directory]::Exists($installDir)) {
        [IO.Directory]::Delete($installDir)
    }
}
