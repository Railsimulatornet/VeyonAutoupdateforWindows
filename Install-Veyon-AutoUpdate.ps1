# Veyon Updater V1.5.0
$ErrorActionPreference = 'Stop'
$env:PSModulePath = [IO.Path]::Combine($PSHOME, 'Modules')

function Test-VeyonAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-VeyonPackage {
    param([Parameter(Mandatory = $true)][string]$PackageRoot)
    $root = [IO.Path]::GetFullPath($PackageRoot).TrimEnd('\')
    $infoPath = Join-Path $root 'BUILDINFO.json'
    if (-not [IO.File]::Exists($infoPath) -or (Get-Item -LiteralPath $infoPath).Length -gt 65536) {
        throw 'BUILDINFO.json fehlt oder ist ungueltig. Bitte das vollstaendige Paket verwenden.'
    }
    $info = [IO.File]::ReadAllText($infoPath) | ConvertFrom-Json
    if ($info.version -cne '1.5.0' -or $info.source_commit -cnotmatch '^[a-f0-9]{40}$' -or
        $info.sha256 -isnot [pscustomobject]) {
        throw 'Die Paketinformationen sind ungueltig.'
    }
    $expected = @{}
    foreach ($property in $info.sha256.PSObject.Properties) {
        $name = $property.Name
        if ($name -cnotmatch '^(?:[A-Za-z0-9_-]+/)*[A-Za-z0-9_.-]+$' -or
            $name -in @('.', '..', 'BUILDINFO.json') -or $name.Length -gt 180 -or
            $property.Value -cnotmatch '^[a-f0-9]{64}$' -or $expected.ContainsKey($name)) {
            throw 'Die Dateiliste des Pakets ist ungueltig.'
        }
        $expected[$name] = $property.Value
    }
    $required = @('Install-Veyon-AutoUpdate.cmd', 'Install-Veyon-AutoUpdate.ps1',
        'Remove-Veyon-AutoUpdate.cmd', 'Remove-Veyon-AutoUpdate.ps1',
        'Register-Veyon-AutoUpdateTask.ps1', 'Start-VeyonUpdater.ps1',
        'VeyonUpdater.Security.ps1', 'VeyonUpdater-release-public.cer',
        'Veyon-AutoUpdate.ps1', 'Veyon-SelfUpdate.ps1')
    foreach ($name in $required) {
        if (-not $expected.ContainsKey($name)) { throw "Paketdatei fehlt in der Pruefsummenliste: $name" }
    }
    if ($expected.Count -gt 80) { throw 'Das Paket enthaelt zu viele Dateien.' }
    $found = @{}
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($root)
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        $item = Get-Item -LiteralPath $directory -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw 'Das Paket darf keine Verknuepfungen enthalten.'
        }
        foreach ($entry in @(Get-ChildItem -LiteralPath $directory -Force)) {
            if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw 'Das Paket darf keine Verknuepfungen enthalten.'
            }
            if ($entry.PSIsContainer) { $pending.Push($entry.FullName); continue }
            $relative = $entry.FullName.Substring($root.Length + 1).Replace('\', '/')
            if ($relative -eq 'BUILDINFO.json') { continue }
            if (-not $expected.ContainsKey($relative) -or $found.ContainsKey($relative) -or
                $entry.Length -gt 16MB -or (Get-FileHash -LiteralPath $entry.FullName -Algorithm SHA256).Hash -ine $expected[$relative]) {
                throw "Paketdatei fehlt, wurde veraendert oder ist nicht vorgesehen: $relative"
            }
            $found[$relative] = $true
        }
    }
    if ($found.Count -ne $expected.Count) { throw 'Das Paket ist unvollstaendig.' }
    if ($expected['VeyonUpdater-release-public.cer'] -cne '7b698f2726348060cddf8b10a5a82d39ed907062265edf2e926dd9d6c5a72b7d') {
        throw 'Das Paket enthaelt nicht den erwarteten oeffentlichen Schluessel.'
    }
    foreach ($name in $expected.Keys | Where-Object { $_.EndsWith('.ps1') }) {
        $tokens = $null; $errors = $null
        [Management.Automation.Language.Parser]::ParseFile((Join-Path $root $name), [ref]$tokens, [ref]$errors) | Out-Null
        if ($errors.Count -gt 0) { throw "PowerShell-Syntaxfehler im Paket: $name" }
    }
    return $info
}

function Get-VeyonTaskSnapshot {
    $task = Get-ScheduledTask -TaskPath '\' -ErrorAction Stop |
        Where-Object TaskName -eq 'Veyon AutoUpdate (winget)'
    if (-not $task) { return $null }
    $root = Get-VeyonRoot
    $legacy = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'Veyon\Update\Veyon-AutoUpdate.ps1'
    $arguments = @($task.Actions)[0].Arguments
    $acceptedArguments = @(
        ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + (Join-Path $root 'Start-VeyonUpdater.ps1') + '"'),
        ('-NoProfile -ExecutionPolicy Bypass -File "' + $legacy + '"'))
    if (@($task.Actions).Count -ne 1 -or $arguments -notin $acceptedArguments -or
        $task.Actions.Execute -notin @('powershell.exe', (Get-VeyonPowerShell)) -or
        $task.Principal.UserId -notin @('SYSTEM', 'S-1-5-18')) {
        throw 'Unter dem Aufgabennamen ist eine unerwartete Aufgabe vorhanden.'
    }
    $service = New-Object -ComObject Schedule.Service
    $service.Connect()
    return [pscustomobject]@{
        Xml = Export-ScheduledTask -TaskName 'Veyon AutoUpdate (winget)' -TaskPath '\'
        Security = $service.GetFolder('\').GetTask('Veyon AutoUpdate (winget)').GetSecurityDescriptor(7)
        Enabled = [bool]$task.Settings.Enabled
    }
}

function Suspend-VeyonTask {
    param($Snapshot)
    if (-not $Snapshot) { return }
    Disable-ScheduledTask -TaskName 'Veyon AutoUpdate (winget)' -TaskPath '\' | Out-Null
    $task = Get-ScheduledTask -TaskName 'Veyon AutoUpdate (winget)' -TaskPath '\'
    if ($task.State -eq 'Running') {
        throw 'Die Aktualisierung laeuft gerade. Bitte ihren Abschluss abwarten und das Setup erneut starten.'
    }
}

function Restore-VeyonTask {
    param($Snapshot)
    if ($Snapshot) {
        Register-ScheduledTask -TaskName 'Veyon AutoUpdate (winget)' -TaskPath '\' -Xml $Snapshot.Xml -Force | Out-Null
        $service = New-Object -ComObject Schedule.Service
        $service.Connect()
        $service.GetFolder('\').GetTask('Veyon AutoUpdate (winget)').SetSecurityDescriptor($Snapshot.Security, 0)
    } else {
        $task = Get-ScheduledTask -TaskPath '\' | Where-Object TaskName -eq 'Veyon AutoUpdate (winget)'
        if ($task) { Unregister-ScheduledTask -TaskName 'Veyon AutoUpdate (winget)' -TaskPath '\' -Confirm:$false }
    }
}

function Invoke-VeyonTaskRegistration {
    param([string]$PackageRoot, [string]$Root)
    & (Join-Path $PackageRoot 'Register-Veyon-AutoUpdateTask.ps1') -UpdaterPath (Join-Path $Root 'Start-VeyonUpdater.ps1')
}

function Invoke-VeyonCandidateHealth {
    param([string]$Path)
    $process = Start-Process -FilePath (Get-VeyonPowerShell) -ArgumentList (
        '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Testlauf' -f $Path
    ) -PassThru -WindowStyle Hidden
    try {
        if (-not $process.WaitForExit(60000)) { $process.Kill(); throw 'Der lokale Testlauf hat das Zeitlimit ueberschritten.' }
        if ($process.ExitCode -ne 0) { throw "Der lokale Testlauf ist fehlgeschlagen (Exitcode $($process.ExitCode))." }
    } finally { $process.Dispose() }
}

function Copy-VeyonVerifiedFile {
    param([string]$Source, [string]$Destination, [string]$ExpectedHash)
    Assert-VeyonSafePath -Path $Source
    if ([IO.File]::Exists($Destination)) {
        Assert-VeyonSafePath -Path $Destination
        if ((Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash -ine $ExpectedHash) {
            throw "Eine vorhandene Installationsdatei weicht ab: $Destination"
        }
        return
    }
    [IO.File]::Copy($Source, $Destination, $false)
    Set-VeyonProtectedAcl -Path $Destination
    if ((Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash -ine $ExpectedHash) {
        throw "Pruefsummenfehler nach dem Kopieren: $Destination"
    }
}

function Move-VeyonLegacyBackups {
    param([string]$Root)
    $legacy = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'Veyon\Update\config-backups'
    if (-not [IO.Directory]::Exists($legacy)) { return }
    if (-not (Test-VeyonAdministrator)) { throw 'Administratorrechte sind erforderlich.' }
    Assert-VeyonSafePath -Path $legacy
    $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $trustedOwners = @('S-1-5-18', 'S-1-5-32-544', $currentSid)
    $ancestorOwners = $trustedOwners + 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'
    $parent = [IO.Directory]::GetParent($legacy)
    while ($parent) {
        $acl = Get-Acl -LiteralPath $parent.FullName
        $descriptor = [Security.AccessControl.RawSecurityDescriptor]::new($acl.GetSecurityDescriptorBinaryForm(), 0)
        if ($null -eq $descriptor.DiscretionaryAcl -or $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin $ancestorOwners) {
            throw 'Ein uebergeordneter alter Sicherungspfad hat einen unerwarteten Besitzer.'
        }
        foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
            if ($rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
                -not ($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) -and
                $rule.IdentityReference.Value -notin $ancestorOwners -and ([int]$rule.FileSystemRights -band 0x100D0040)) {
                throw 'Ein uebergeordneter alter Sicherungspfad kann von unberechtigten Benutzern veraendert werden.'
            }
        }
        $parent = $parent.Parent
    }
    $items = @((Get-Item -LiteralPath $legacy -Force)) + @(Get-ChildItem -LiteralPath $legacy -Force)
    if ($items.Count -gt 33 -or ($items | Where-Object { -not $_.PSIsContainer } | Measure-Object -Property Length -Sum).Sum -gt 64MB) {
        throw 'Der alte Sicherungsbestand ist zu gross fuer eine automatische Uebernahme.'
    }
    foreach ($item in $items) {
        Assert-VeyonSafePath -Path $item.FullName
        if ($item.FullName -ne $legacy -and ($item.PSIsContainer -or
            $item.Name -notmatch '^(?:config-.+\.json|registry-backup-.+\.reg)$' -or $item.Length -gt 16MB)) {
            throw 'Der alte Sicherungsordner enthaelt unerwartete Dateien. Bitte den Bestand lokal pruefen.'
        }
        $owner = (Get-Acl -LiteralPath $item.FullName).GetOwner([Security.Principal.SecurityIdentifier]).Value
        if ($owner -notin $trustedOwners) { throw 'Der alte Sicherungsordner hat einen unerwarteten Besitzer.' }
    }
    $streams = @()
    try {
        # Open every file before changing permissions; an existing writer prevents migration.
        foreach ($item in $items | Where-Object { -not $_.PSIsContainer }) {
            $streams += [pscustomobject]@{ Item = $item; Stream = [IO.File]::Open(
                $item.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read) }
        }
        foreach ($item in $items) { Set-VeyonProtectedAcl -Path $item.FullName }
        foreach ($entry in $streams) {
            $destination = Join-Path (Join-Path $Root 'config-backups') ('legacy-' + $entry.Item.Name)
            $sha = [Security.Cryptography.SHA256]::Create()
            try {
                $hash = [BitConverter]::ToString($sha.ComputeHash($entry.Stream)).Replace('-', '')
                $entry.Stream.Position = 0
            } finally { $sha.Dispose() }
            if ([IO.File]::Exists($destination)) {
                Assert-VeyonSafePath -Path $destination
                if ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -ine $hash) {
                    throw 'Eine bestehende uebernommene Sicherung hat einen abweichenden Inhalt.'
                }
            } else {
                $output = [IO.File]::Open($destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                try { $entry.Stream.CopyTo($output); $output.Flush($true) } finally { $output.Dispose() }
                Set-VeyonProtectedAcl -Path $destination
                if ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -ine $hash) {
                    throw 'Die Uebernahme einer alten Sicherung ist fehlgeschlagen.'
                }
            }
        }
    } finally {
        foreach ($entry in $streams) { $entry.Stream.Dispose() }
    }
}

function Invoke-VeyonInstall {
    param([Parameter(Mandatory = $true)][string]$PackageRoot, [string]$Root)
    $info = Assert-VeyonPackage -PackageRoot $PackageRoot
    . (Join-Path $PackageRoot 'VeyonUpdater.Security.ps1')
    if (-not $Root) { $Root = Get-VeyonRoot }
    Initialize-VeyonProtectedRoot -Root $Root
    $lock = Enter-VeyonUpdateLock -Root $Root
    if (-not $lock) { throw 'Eine Installation oder Aktualisierung laeuft bereits.' }
    $snapshot = $null
    $taskTouched = $false
    $stateChanged = $false
    $oldState = $null
    try {
        Assert-VeyonProtectedRoot -Root $Root
        $statePath = Join-Path $Root 'state.json'
        if ([IO.File]::Exists($statePath)) { $oldState = Read-VeyonState -Root $Root }
        if ($oldState -and [version]$info.version -lt [version]$oldState.highestVersion) {
            throw 'Eine neuere Version wurde bereits freigegeben. Eine aeltere Version wird nicht installiert.'
        }
        $core = @('Start-VeyonUpdater.ps1', 'VeyonUpdater.Security.ps1', 'VeyonUpdater-release-public.cer')
        foreach ($name in $core) {
            $installed = Join-Path $Root $name
            if ($oldState -and (-not [IO.File]::Exists($installed) -or
                (Get-FileHash -LiteralPath $installed -Algorithm SHA256).Hash -ine $info.sha256.$name)) {
                throw 'Der installierte Bootstrap weicht ab. Bitte die Wartungshinweise im README verwenden.'
            }
        }
        $snapshot = Get-VeyonTaskSnapshot
        if ($snapshot) { $taskTouched = $true; Suspend-VeyonTask -Snapshot $snapshot }
        foreach ($directory in @('versions', 'staging', 'config-backups', 'logs')) {
            New-VeyonProtectedDirectory -Path (Join-Path $Root $directory) | Out-Null
        }
        foreach ($name in $core) {
            Copy-VeyonVerifiedFile -Source (Join-Path $PackageRoot $name) -Destination (Join-Path $Root $name) -ExpectedHash $info.sha256.$name
        }
        $buildHash = (Get-FileHash -LiteralPath (Join-Path $PackageRoot 'BUILDINFO.json') -Algorithm SHA256).Hash.ToLowerInvariant()
        $versionDirectory = $info.version + '-' + $buildHash.Substring(0, 16)
        $candidate = Join-Path (Join-Path $Root 'versions') $versionDirectory
        New-VeyonProtectedDirectory -Path $candidate | Out-Null
        $files = @()
        foreach ($name in @('Veyon-AutoUpdate.ps1', 'Veyon-SelfUpdate.ps1')) {
            $destination = Join-Path $candidate $name
            Copy-VeyonVerifiedFile -Source (Join-Path $PackageRoot $name) -Destination $destination -ExpectedHash $info.sha256.$name
            $files += [pscustomobject]@{ path = $name; length = (Get-Item -LiteralPath $destination).Length; sha256 = $info.sha256.$name }
        }
        Assert-VeyonProtectedRoot -Root $Root
        Invoke-VeyonCandidateHealth -Path (Join-Path $candidate 'Veyon-AutoUpdate.ps1')
        Move-VeyonLegacyBackups -Root $Root
        $state = [pscustomobject]@{
            schema = 1
            current = [pscustomobject]@{ version = $info.version; directory = $versionDirectory; sourceCommit = $info.source_commit; files = $files }
            previous = if ($oldState) { $oldState.current } else { $null }
            highestVersion = $info.version
            failedVersion = $null
        }
        Write-VeyonState -Root $Root -State $state
        $stateChanged = $true
        $taskTouched = $true
        Invoke-VeyonTaskRegistration -PackageRoot $PackageRoot -Root $Root
        Write-Host 'FERTIG. Veyon Updater V1.5.0 wurde eingerichtet.'
        Write-Host ('Daten und Sicherungen: ' + $Root)
    } catch {
        $originalError = $_
        $rollbackErrors = @()
        if ($stateChanged) {
            try {
                if ($oldState) { Write-VeyonState -Root $Root -State $oldState }
                elseif ([IO.File]::Exists((Join-Path $Root 'state.json'))) { [IO.File]::Delete((Join-Path $Root 'state.json')) }
            } catch { $rollbackErrors += $_.Exception.Message }
        }
        if ($taskTouched) {
            try { Restore-VeyonTask -Snapshot $snapshot }
            catch { $rollbackErrors += $_.Exception.Message }
        }
        if ($rollbackErrors.Count -gt 0) {
            throw ('Installation fehlgeschlagen; Wiederherstellung pruefen: ' + ($rollbackErrors -join '; ') + '. Ursache: ' + $originalError.Exception.Message)
        }
        throw $originalError
    } finally { $lock.Dispose() }
}

try {
    if (-not (Test-VeyonAdministrator)) {
        $powerShell = Join-Path ([Environment]::GetFolderPath('Windows')) 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (-not [Environment]::Is64BitProcess -and [Environment]::Is64BitOperatingSystem) {
            $powerShell = Join-Path ([Environment]::GetFolderPath('Windows')) 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
        }
        $process = Start-Process -FilePath $powerShell -Verb RunAs -Wait -PassThru -ArgumentList (
            '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f $PSCommandPath)
        exit $process.ExitCode
    }
    Invoke-VeyonInstall -PackageRoot $PSScriptRoot
    exit 0
} catch {
    Write-Host ('FEHLER: ' + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
