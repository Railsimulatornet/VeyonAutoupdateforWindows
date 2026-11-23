param([Parameter(Mandatory = $true)][string]$AssetDirectory)
$ErrorActionPreference = 'Stop'
$taskName = 'Veyon AutoUpdate (winget)'
$root = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'VeyonUpdater'
$legacyParent = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'Veyon'
$legacy = Join-Path $legacyParent 'Update'
$powerKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
$power = Get-ItemProperty -LiteralPath $powerKey
$oldNoPause = $env:VEYON_SETUP_NO_PAUSE
$windows = [Environment]::GetFolderPath('Windows')
$nativePowerShell = Join-Path $windows 'System32\WindowsPowerShell\v1.0\powershell.exe'
$systemTaskName = 'Veyon Updater installation check ' + [guid]::NewGuid().ToString('N')
$probeRoot = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) ('VeyonAccessTest-' + [guid]::NewGuid().ToString('N'))
$testUser = 'VeyonTest' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$userCreated = $false
$moduleRoot = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) ('VeyonModuleTest-' + [guid]::NewGuid().ToString('N'))
$moduleMarker = Join-Path $moduleRoot 'caller-module-loaded.txt'
$temporary = Join-Path ([IO.Path]::GetTempPath()) ("veyon setup ' package " + [guid]::NewGuid().ToString('N'))

if ((Get-ScheduledTask -TaskPath '\' | Where-Object TaskName -eq $taskName) -or
    [IO.Directory]::Exists($root) -or [IO.Directory]::Exists($legacyParent)) {
    throw 'The installation smoke test requires a disposable clean Windows runner without existing Veyon data or task.'
}

function Assert-Installation {
    param([string]$TriggerType, [string]$PackageRoot)
    $task = Get-ScheduledTask -TaskName $taskName -TaskPath '\'
    $xml = [xml](Export-ScheduledTask -TaskName $taskName -TaskPath '\')
    $trigger = $xml.Task.Triggers.$TriggerType
    if (-not $trigger -or [Xml.XmlConvert]::ToTimeSpan($trigger.Delay).TotalSeconds -ne 120) {
        throw "Expected $TriggerType with a two-minute delay."
    }
    if ($xml.Task.Principals.Principal.UserId -ne 'S-1-5-18' -or $task.Principal.RunLevel -ne 'Highest') {
        throw 'Expected SYSTEM with highest privileges.'
    }
    if (-not $task.Settings.Enabled -or $task.Settings.DisallowStartIfOnBatteries -or $task.Settings.StopIfGoingOnBatteries -or
        $task.Settings.MultipleInstances -ne 'IgnoreNew' -or [Xml.XmlConvert]::ToTimeSpan($task.Settings.ExecutionTimeLimit).TotalHours -gt 1) {
        throw 'Unexpected task concurrency, timeout or battery settings.'
    }
    $expectedArguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + (Join-Path $root 'Start-VeyonUpdater.ps1') + '"'
    if (@($task.Actions).Count -ne 1 -or $task.Actions.Execute -ine (Get-VeyonPowerShell) -or
        $task.Actions.Arguments -cne $expectedArguments -or $task.Actions.WorkingDirectory -ine $root) {
        throw 'Unexpected updater task action.'
    }
    Assert-VeyonProtectedRoot -Root $root
    $state = Read-VeyonState -Root $root
    Assert-VeyonVersionFiles -Root $root -Record $state.current | Out-Null
    $installed = Join-Path (Join-Path (Join-Path $root 'versions') $state.current.directory) 'Veyon-AutoUpdate.ps1'
    if ((Get-FileHash -LiteralPath $installed).Hash -ne (Get-FileHash -LiteralPath (Join-Path $PackageRoot 'Veyon-AutoUpdate.ps1')).Hash) {
        throw 'Installed updater differs from the package.'
    }
    $service = New-Object -ComObject Schedule.Service
    $service.Connect()
    $descriptor = [Security.AccessControl.RawSecurityDescriptor]::new($service.GetFolder('\').GetTask($taskName).GetSecurityDescriptor(4))
    foreach ($ace in $descriptor.DiscretionaryAcl) {
        if ($ace.AceType -ne [Security.AccessControl.AceType]::AccessAllowed -or $ace.SecurityIdentifier.Value -notin @('S-1-5-18', 'S-1-5-32-544')) {
            throw 'Unexpected task permission.'
        }
    }
    Write-Host "PASS: $TriggerType, two-minute delay, SYSTEM, bounded runtime, protected files and task"
}

function Initialize-CallerModuleFixture {
    $directory = Join-Path $moduleRoot 'Microsoft.PowerShell.Utility'
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $manifest = "@{ RootModule = 'Microsoft.PowerShell.Utility.psm1'; ModuleVersion = '1.0.0'; FunctionsToExport = @('Get-FileHash'); CmdletsToExport = @(); AliasesToExport = @() }"
    [IO.File]::WriteAllText((Join-Path $directory 'Microsoft.PowerShell.Utility.psd1'), $manifest)
    $module = "[IO.File]::WriteAllText('" + $moduleMarker.Replace("'", "''") + "', 'caller module loaded')" + "`r`n" +
        "function Get-FileHash { throw 'Unexpected caller module was loaded.' }`r`nExport-ModuleMember -Function Get-FileHash"
    [IO.File]::WriteAllText((Join-Path $directory 'Microsoft.PowerShell.Utility.psm1'), $module)
    $control = Join-Path $moduleRoot 'control.ps1'
    [IO.File]::WriteAllText($control, 'Get-FileHash -LiteralPath $PSCommandPath -ErrorAction Stop')
    $saved = $env:PSModulePath
    $process = $null
    try {
        $env:PSModulePath = $moduleRoot
        $process = Start-Process -FilePath $nativePowerShell -PassThru -ArgumentList (
            '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f $control) `
            -RedirectStandardOutput (Join-Path $moduleRoot 'control-output.txt') `
            -RedirectStandardError (Join-Path $moduleRoot 'control-error.txt')
        if (-not $process.WaitForExit(30000)) { $process.Kill(); throw 'Caller module control timed out.' }
        if ($process.ExitCode -eq 0 -or -not [IO.File]::Exists($moduleMarker)) {
            throw 'Caller module fixture was not discovered by unprotected Windows PowerShell.'
        }
    } finally {
        $env:PSModulePath = $saved
        if ($process) { $process.Dispose() }
    }
    [IO.File]::Delete($moduleMarker)
    Write-Host 'PASS: unprotected native Windows PowerShell discovers the caller-module fixture'
}

function Invoke-SystemDryRun {
    $checkScript = Join-Path $root 'installation-system-check.ps1'
    $proof = Join-Path $root 'installation-system-proof.txt'
    $contents = @'
$ErrorActionPreference = 'Stop'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
if ($identity -ne 'S-1-5-18') { throw 'The process is not running as SYSTEM.' }
$root = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'VeyonUpdater'
$powershell = Join-Path ([Environment]::GetFolderPath('Windows')) 'System32\WindowsPowerShell\v1.0\powershell.exe'
$env:PSModulePath = '__CALLER_MODULE_PATH__'
& $powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $root 'Start-VeyonUpdater.ps1') -Testlauf
if ($LASTEXITCODE -ne 0) { throw 'The installed launcher dry run failed.' }
[IO.File]::WriteAllText((Join-Path $root 'installation-system-proof.txt'), $identity)
'@
    $contents = $contents.Replace('__CALLER_MODULE_PATH__', $moduleRoot.Replace("'", "''"))
    [IO.File]::WriteAllText($checkScript, $contents)
    Set-VeyonProtectedAcl -Path $checkScript
    $stateHash = (Get-FileHash -LiteralPath (Join-Path $root 'state.json')).Hash
    $action = New-ScheduledTaskAction -Execute (Get-VeyonPowerShell) -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f $checkScript)
    $principal = New-ScheduledTaskPrincipal -UserId SYSTEM -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::FromMinutes(2))
    Register-ScheduledTask -TaskName $systemTaskName -Action $action -Principal $principal -Settings $settings -Force | Out-Null
    try {
        Start-ScheduledTask -TaskName $systemTaskName
        $limit = [DateTime]::UtcNow.AddSeconds(90)
        while ([DateTime]::UtcNow -lt $limit) {
            if ([IO.File]::Exists($proof) -and (Get-ScheduledTask -TaskName $systemTaskName).State -ne 'Running') { break }
            Start-Sleep -Milliseconds 500
        }
        if (-not [IO.File]::Exists($proof) -or [IO.File]::ReadAllText($proof) -cne 'S-1-5-18') {
            throw 'SYSTEM launch did not produce its verified identity result.'
        }
        if ((Get-FileHash -LiteralPath (Join-Path $root 'state.json')).Hash -ne $stateHash -or
            [IO.File]::Exists((Join-Path $root 'selfupdate-check.txt')) -or [IO.File]::Exists((Join-Path $root 'veyon_autoupdate.log'))) {
            throw 'The SYSTEM dry run changed runtime state.'
        }
        if ([IO.File]::Exists($moduleMarker)) { throw 'SYSTEM launcher executed an inherited caller module.' }
        Write-Host 'PASS: installed launcher and health check executed as SYSTEM with a polluted inherited module path and no update/network state'
    } finally {
        Unregister-ScheduledTask -TaskName $systemTaskName -Confirm:$false -ErrorAction SilentlyContinue
        foreach ($path in @($checkScript, $proof)) { if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) } }
    }
}

function Test-StandardUserAccess {
    param([string]$BackupPath, [string]$LegacyBackupPath)
    [IO.Directory]::CreateDirectory($probeRoot) | Out-Null
    $acl = New-VeyonDirectorySecurity
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        [Security.Principal.SecurityIdentifier]::new('S-1-5-32-545'),
        [Security.AccessControl.FileSystemRights]::ReadAndExecute,
        ([Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit),
        [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow))
    Set-Acl -LiteralPath $probeRoot -AclObject $acl
    $probe = Join-Path $probeRoot 'probe.ps1'
    $probeText = @'
param([string]$Root, [string]$ScriptPath, [string]$BackupPath, [string]$LegacyBackupPath)
$ErrorActionPreference = 'Stop'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if ([Security.Principal.WindowsPrincipal]::new($identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'The access probe unexpectedly has administrator privileges.'
}
function Assert-Denied([scriptblock]$Action) {
    $denied = $false
    try { & $Action } catch {
        $exception = $_.Exception
        while ($exception.InnerException) { $exception = $exception.InnerException }
        if ($exception.HResult -eq -2147024891) { $denied = $true } else { throw }
    }
    if (-not $denied) { throw 'A standard user crossed the updater permission boundary.' }
}
Assert-Denied { $stream = [IO.File]::Open($ScriptPath, 'Open', 'ReadWrite', 'ReadWrite'); $stream.Dispose() }
Assert-Denied { [IO.File]::WriteAllText((Join-Path $Root 'standard-user-file.txt'), 'unexpected') }
Assert-Denied { $stream = [IO.File]::Open((Join-Path $Root 'state.json'), 'Open', 'ReadWrite', 'ReadWrite'); $stream.Dispose() }
Assert-Denied { [IO.File]::ReadAllText($BackupPath) | Out-Null }
Assert-Denied { [IO.File]::ReadAllText($LegacyBackupPath) | Out-Null }
Assert-Denied {
    $service = New-Object -ComObject Schedule.Service
    $service.Connect()
    $service.GetFolder('\').DeleteTask('Veyon AutoUpdate (winget)', 0)
}
Write-Output 'STANDARD_USER_DENIED'
'@
    [IO.File]::WriteAllText($probe, $probeText)
    $password = 'Vt!8' + [guid]::NewGuid().ToString('N')
    $secure = ConvertTo-SecureString $password -AsPlainText -Force
    $user = New-LocalUser -Name $testUser -Password $secure -AccountNeverExpires -PasswordNeverExpires
    $script:userCreated = $true
    if (-not (Get-LocalGroupMember -SID 'S-1-5-32-545' | Where-Object { $_.SID.Value -eq $user.SID.Value })) {
        Add-LocalGroupMember -SID 'S-1-5-32-545' -Member $user.SID
    }
    $credential = [Management.Automation.PSCredential]::new(($env:COMPUTERNAME + '\' + $testUser), $secure)
    $state = Read-VeyonState -Root $root
    $scriptPath = Join-Path (Join-Path (Join-Path $root 'versions') $state.current.directory) 'Veyon-AutoUpdate.ps1'
    $stdout = Join-Path $probeRoot 'stdout.txt'
    $stderr = Join-Path $probeRoot 'stderr.txt'
    $process = Start-Process -FilePath (Get-VeyonPowerShell) -Credential $credential -WorkingDirectory $probeRoot -PassThru `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr -ArgumentList (
        '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Root "{1}" -ScriptPath "{2}" -BackupPath "{3}" -LegacyBackupPath "{4}"' -f $probe, $root, $scriptPath, $BackupPath, $LegacyBackupPath)
    try {
        if (-not $process.WaitForExit(60000)) { $process.Kill(); throw 'Standard user access test timed out.' }
        if ($process.ExitCode -ne 0 -or [IO.File]::ReadAllText($stdout) -notmatch 'STANDARD_USER_DENIED') {
            throw ('Standard user access test failed: ' + [IO.File]::ReadAllText($stderr))
        }
    } finally { $process.Dispose() }
    Write-Host 'PASS: a real standard-user process cannot change scripts/state, create files, read backups or delete the task'
}

$config = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../release.json') -Raw | ConvertFrom-Json
$assets = (Get-Item -LiteralPath $AssetDirectory).FullName
$pwshPath = (Get-Command pwsh.exe -CommandType Application -ErrorAction Stop).Source
$incompatibleModulePath = Join-Path ([IO.Path]::GetDirectoryName($pwshPath)) 'Modules'
if (-not [IO.Directory]::Exists($incompatibleModulePath)) { throw 'PowerShell 7 modules are required for the inherited-environment regression.' }
try {
    $env:VEYON_SETUP_NO_PAUSE = '1'
    Expand-Archive -LiteralPath (Join-Path $assets $config.archive) -DestinationPath $temporary
    . (Join-Path $temporary 'VeyonUpdater.Security.ps1')
    Initialize-CallerModuleFixture
    $legacyBackups = Join-Path $legacy 'config-backups'
    [IO.Directory]::CreateDirectory($legacyBackups) | Out-Null
    $legacyBackup = Join-Path $legacyBackups 'config-installation-test.json'
    [IO.File]::WriteAllText($legacyBackup, '{"installationTest":true}')
    $legacyScript = Join-Path $legacy 'Veyon-AutoUpdate.ps1'
    [IO.File]::WriteAllText($legacyScript, 'exit 0')
    $parentAcl = (Get-Acl -LiteralPath $legacyParent).Sddl
    $updateAcl = (Get-Acl -LiteralPath $legacy).Sddl
    $legacyAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $legacyScript)
    $legacyPrincipal = New-ScheduledTaskPrincipal -UserId SYSTEM -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName $taskName -Action $legacyAction -Principal $legacyPrincipal -Trigger (New-ScheduledTaskTrigger -AtStartup) -Force | Out-Null
    Set-ItemProperty -LiteralPath $powerKey -Name HiberbootEnabled -Type DWord -Value 0
    $savedModulePath = $env:PSModulePath
    Push-Location -LiteralPath $temporary
    try {
        # Reproduce a PowerShell 7 -> CMD -> Windows PowerShell process tree.
        $env:PSModulePath = $incompatibleModulePath
        & (Join-Path $windows 'System32\cmd.exe') /d /c Install-Veyon-AutoUpdate.cmd
        if ($LASTEXITCODE -ne 0) { throw "ZIP installation failed with exit code $LASTEXITCODE." }
    } finally { $env:PSModulePath = $savedModulePath; Pop-Location }
    Assert-Installation -TriggerType BootTrigger -PackageRoot $temporary
    $copiedBackup = Join-Path (Join-Path $root 'config-backups') 'legacy-config-installation-test.json'
    if ((Get-FileHash -LiteralPath $copiedBackup).Hash -ne (Get-FileHash -LiteralPath $legacyBackup).Hash -or
        (Get-Acl -LiteralPath $legacyParent).Sddl -cne $parentAcl -or (Get-Acl -LiteralPath $legacy).Sddl -cne $updateAcl) {
        throw 'Legacy migration changed data or parent permissions.'
    }
    Assert-VeyonAcl -Path $legacyBackups -Private
    Assert-VeyonAcl -Path $legacyBackup -Private
    Write-Host 'PASS: legacy task migration, retained backups and unchanged Veyon parent permissions'
    $savedModulePath = $env:PSModulePath
    try {
        $env:PSModulePath = $moduleRoot
        & $nativePowerShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $temporary 'Install-Veyon-AutoUpdate.ps1')
        if ($LASTEXITCODE -ne 0) { throw 'Direct Windows PowerShell installation with caller module path failed.' }
    } finally { $env:PSModulePath = $savedModulePath }
    if ([IO.File]::Exists($moduleMarker)) { throw 'Installer executed an inherited caller module.' }
    Write-Host 'PASS: direct Windows PowerShell installer ignores inherited caller modules'
    Invoke-SystemDryRun

    Set-ItemProperty -LiteralPath $powerKey -Name HiberbootEnabled -Type DWord -Value 1
    $process = Start-Process -FilePath (Join-Path $assets $config.setup) -ArgumentList '-y' -PassThru
    try {
        if (-not $process.WaitForExit(90000)) { $process.Kill(); throw 'Setup EXE timed out.' }
        if ($process.ExitCode -ne 0) { throw "Setup EXE failed with exit code $($process.ExitCode)." }
    } finally { $process.Dispose() }
    Assert-Installation -TriggerType LogonTrigger -PackageRoot $temporary
    Disable-ScheduledTask -TaskName $taskName -TaskPath '\' | Out-Null
    Test-StandardUserAccess -BackupPath $copiedBackup -LegacyBackupPath $legacyBackup
    $savedModulePath = $env:PSModulePath
    Push-Location -LiteralPath $temporary
    try {
        $env:PSModulePath = $incompatibleModulePath
        & (Join-Path $windows 'System32\cmd.exe') /d /c Remove-Veyon-AutoUpdate.cmd
        if ($LASTEXITCODE -ne 0) { throw "Uninstall wrapper failed with exit code $LASTEXITCODE." }
    } finally { $env:PSModulePath = $savedModulePath; Pop-Location }
    if (-not [IO.File]::Exists($copiedBackup) -or
        (Get-ScheduledTask -TaskPath '\' | Where-Object TaskName -eq $taskName) -or
        [IO.Directory]::Exists((Join-Path $root 'versions'))) {
        throw 'Uninstallation did not retain backups or remove the task and program.'
    }
    Assert-VeyonProtectedRoot -Root $root
    Write-Host 'PASS: uninstall removes task/program and preserves protected backups'
    & $nativePowerShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $temporary 'Remove-Veyon-AutoUpdate.ps1') -DeleteBackups
    if ($LASTEXITCODE -ne 0 -or [IO.Directory]::Exists($root)) { throw 'Explicit backup removal did not complete.' }
    Write-Host 'PASS: explicit full removal'
} finally {
    $env:VEYON_SETUP_NO_PAUSE = $oldNoPause
    if ($power.PSObject.Properties['HiberbootEnabled']) {
        Set-ItemProperty -LiteralPath $powerKey -Name HiberbootEnabled -Type DWord -Value $power.HiberbootEnabled
    } else { Remove-ItemProperty -LiteralPath $powerKey -Name HiberbootEnabled -ErrorAction SilentlyContinue }
    foreach ($name in @($taskName, $systemTaskName)) {
        Unregister-ScheduledTask -TaskName $name -TaskPath '\' -Confirm:$false -ErrorAction SilentlyContinue
    }
    if ($userCreated) { Remove-LocalUser -Name $testUser -ErrorAction SilentlyContinue }
    foreach ($path in @($root, $legacyParent, $temporary, $probeRoot, $moduleRoot)) {
        if ([IO.Directory]::Exists($path)) { [IO.Directory]::Delete($path, $true) }
    }
}
