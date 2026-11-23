# Veyon-AutoUpdate.ps1
# Copyright Roman Glos 2026 V1.5.0

param(
    [switch]$Testlauf,
    [System.IO.FileStream]$UpdateLock
)

$ErrorActionPreference = 'Stop'

$PkgId   = 'VeyonSolutions.Veyon'
$Base    = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'VeyonUpdater'
$Log     = Join-Path $Base 'veyon_autoupdate.log'
$WingLog = Join-Path $Base 'winget_last.log'
$BkDir   = Join-Path $Base 'config-backups'

# Deutsches Datumsformat
$de = [System.Globalization.CultureInfo]::GetCultureInfo('de-DE')
function Write-Log {
    param([string]$Text)
    if ($Testlauf) { Write-Host $Text; return }
    $stamp = (Get-Date).ToString('dd.MM.yyyy HH:mm:ss', $de)
    Add-Content -LiteralPath $Log -Value "[$stamp] $Text" -Encoding UTF8
}

# Logfiles bleiben auch nach fehlgeschlagenen Laeufen begrenzt.
function Trim-LogIfOversize {
    if ($Testlauf) { return }
    foreach ($entry in @(
        @{ Path = $Log; Limit = 1MB },
        @{ Path = $WingLog; Limit = 4MB }
    )) {
        if (-not (Test-Path -LiteralPath $entry.Path -PathType Leaf)) { continue }
        if ((Get-Item -LiteralPath $entry.Path).Length -le $entry.Limit) { continue }
        # Ein begrenzter Ausschnitt vermeidet das Einlesen beliebig grosser Logs.
        $stream = [System.IO.File]::Open($entry.Path, 'Open', 'Read', 'Read')
        try {
            $count = [int]([Math]::Min(256KB, $stream.Length))
            $bytes = New-Object byte[] $count
            [void]$stream.Seek(-$count, [System.IO.SeekOrigin]::End)
            $read = $stream.Read($bytes, 0, $count)
            $tail = [System.Text.Encoding]::UTF8.GetString($bytes, 0, $read)
        } finally { $stream.Dispose() }
        $lineBreak = $tail.IndexOf("`n")
        if ($lineBreak -ge 0) { $tail = $tail.Substring($lineBreak + 1) }
        [System.IO.File]::WriteAllText($entry.Path, "[Log gekuerzt]`r`n" + $tail, [System.Text.UTF8Encoding]::new($true))
    }
}

function Get-VeyonProgramRoots {
    @(
        [Environment]::GetFolderPath('ProgramFiles'),
        [Environment]::GetFolderPath('ProgramFilesX86')
    ) | Where-Object { $_ } | Select-Object -Unique
}

function Get-VeyonSystemExecutable {
    param([ValidateSet('reg.exe', 'taskkill.exe')][string]$Name)
    $path = Join-Path ([Environment]::SystemDirectory) $Name
    Assert-VeyonTrustedExecutable -Path $path
    return $path
}

function Resolve-WingetPath {
    foreach ($programRoot in @(Get-VeyonProgramRoots)) {
        $pattern = Join-Path $programRoot 'WindowsApps\Microsoft.DesktopAppInstaller_*\winget.exe'
        $candidates = @(Get-ChildItem -Path $pattern -File -ErrorAction SilentlyContinue | Where-Object {
            $_.Directory.Name -match '^Microsoft\.DesktopAppInstaller_[0-9]+(?:\.[0-9]+){3}_[^_]+__8wekyb3d8bbwe$'
        } | Sort-Object -Property @{ Expression = {
            [version]([regex]::Match($_.Directory.Name, '_([0-9]+(?:\.[0-9]+){3})_').Groups[1].Value)
        }; Descending = $true })
        foreach ($candidate in $candidates) {
            Assert-VeyonTrustedExecutable -Path $candidate.FullName
            return $candidate.FullName
        }
    }
    $systemWinget = Join-Path ([Environment]::SystemDirectory) 'winget.exe'
    if (Test-Path -LiteralPath $systemWinget -PathType Leaf) {
        Assert-VeyonTrustedExecutable -Path $systemWinget
        return $systemWinget
    }
    return $null
}

function ConvertTo-VeyonNativeArgument {
    param([AllowNull()][AllowEmptyString()][string]$Argument)
    if ($null -eq $Argument) { $Argument = '' }
    if ($Argument.IndexOf([char]0) -ge 0) { throw 'Ein Prozessargument enthaelt ein Nullzeichen.' }
    # Windows argv: Backslashes vor Anfuehrungszeichen und am Ende verdoppeln.
    $quoted = [System.Text.StringBuilder]::new()
    [void]$quoted.Append('"')
    $slashes = 0
    foreach ($character in $Argument.ToCharArray()) {
        if ($character -eq [char]92) { $slashes++; continue }
        if ($character -eq [char]34) {
            [void]$quoted.Append(('\' * (2 * $slashes + 1)))
            [void]$quoted.Append('"')
        } else {
            [void]$quoted.Append(('\' * $slashes))
            [void]$quoted.Append($character)
        }
        $slashes = 0
    }
    [void]$quoted.Append(('\' * (2 * $slashes)))
    [void]$quoted.Append('"')
    return $quoted.ToString()
}

function Stop-VeyonProcessTree {
    param([System.Diagnostics.Process]$Process)
    if ($Process.HasExited) { return }
    $killer = $null
    try {
        $start = [System.Diagnostics.ProcessStartInfo]::new()
        $start.FileName = Get-VeyonSystemExecutable -Name 'taskkill.exe'
        $start.Arguments = '/PID ' + $Process.Id + ' /T /F'
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $killer = [System.Diagnostics.Process]::Start($start)
        if (-not $killer.WaitForExit(20000)) { $killer.Kill() }
    } finally {
        if ($killer) { $killer.Dispose() }
        if (-not $Process.HasExited) {
            $Process.Kill()
            if (-not $Process.WaitForExit(10000)) { throw 'Prozess konnte nicht beendet werden.' }
        }
    }
}

function Invoke-VeyonNativeProcess {
    param(
        [Parameter(Mandatory = $true)][string]$File,
        [string[]]$ArgList,
        [ValidateRange(1, 1800)][int]$TimeoutSeconds = 120,
        [switch]$CaptureOutput
    )
    Assert-VeyonTrustedExecutable -Path $File
    $start = [System.Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $File
    $start.Arguments = (@($ArgList | ForEach-Object { ConvertTo-VeyonNativeArgument $_ }) -join ' ')
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.WorkingDirectory = [System.IO.Path]::GetDirectoryName($File)
    $start.RedirectStandardOutput = [bool]$CaptureOutput
    $start.RedirectStandardError = [bool]$CaptureOutput
    $process = $null
    $marker = $null
    $normalExitObserved = $false
    $runtimeLock = Get-Variable -Name 'VeyonRuntimeLock' -Scope Script -ErrorAction SilentlyContinue
    if ($runtimeLock -and $runtimeLock.Value -is [IO.FileStream]) {
        if (-not $runtimeLock.Value.CanRead -or -not $runtimeLock.Value.CanWrite -or
            $runtimeLock.Value.SafeFileHandle.IsClosed -or $runtimeLock.Value.SafeFileHandle.IsInvalid) {
            throw 'Die Laufzeitsperre ist nicht mehr gueltig.'
        }
        $runtimeRoot = (Get-Variable -Name 'VeyonRuntimeRoot' -Scope Script -ErrorAction Stop).Value
        $marker = Join-Path $runtimeRoot 'native-operation.json'
        $operation = [ordered]@{schema=1;startedUtc=[DateTime]::UtcNow.ToString('O');hostPid=$PID;executable=$File}
        $markerBytes = [Text.Encoding]::UTF8.GetBytes(($operation | ConvertTo-Json -Compress))
        $markerStream = [IO.FileStream]::new($marker, [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::WriteThrough)
        try {
            $markerStream.Write($markerBytes, 0, $markerBytes.Length)
            $markerStream.Flush($true)
        } finally { $markerStream.Dispose() }
        Set-VeyonProtectedAcl -Path $marker
    }
    try {
        $process = [System.Diagnostics.Process]::Start($start)
        $output = [System.Text.StringBuilder]::new()
        if ($CaptureOutput) {
            $watch = [System.Diagnostics.Stopwatch]::StartNew()
            $readers = @($process.StandardOutput, $process.StandardError)
            $buffers = @((New-Object char[] 4096), (New-Object char[] 4096))
            $tasks = @($readers[0].ReadAsync($buffers[0], 0, 4096), $readers[1].ReadAsync($buffers[1], 0, 4096))
            while ($null -ne $tasks[0] -or $null -ne $tasks[1] -or -not $process.HasExited) {
                if ($watch.Elapsed.TotalSeconds -ge $TimeoutSeconds) { throw 'Prozess-Zeitlimit ueberschritten.' }
                for ($i = 0; $i -lt 2; $i++) {
                    if ($null -eq $tasks[$i] -or -not $tasks[$i].IsCompleted) { continue }
                    $count = $tasks[$i].GetAwaiter().GetResult()
                    if ($count -eq 0) { $tasks[$i] = $null; continue }
                    if ($output.Length + $count -gt 1MB) { throw 'Prozessausgabe ueberschreitet das Groessenlimit.' }
                    [void]$output.Append($buffers[$i], 0, $count)
                    $tasks[$i] = $readers[$i].ReadAsync($buffers[$i], 0, 4096)
                }
                [System.Threading.Thread]::Sleep(10)
            }
        } elseif (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            throw 'Prozess-Zeitlimit ueberschritten.'
        }
        $process.WaitForExit()
        $result = [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $output.ToString() }
        $normalExitObserved = $true
        return $result
    } catch {
        if ($process -and -not $process.HasExited) { Stop-VeyonProcessTree -Process $process }
        throw
    } finally {
        if ($process) { $process.Dispose() }
        # Bei Timeout oder Hostabbruch ist der Zustand eines Installers nicht
        # sicher bekannt. Der Marker blockiert dann weitere Laeufe bis zur Pruefung.
        if ($marker -and $normalExitObserved) { [IO.File]::Delete($marker) }
    }
}

function Invoke-Proc {
    param([string]$File, [string[]]$ArgList, [int]$TimeoutSeconds = 120)
    return (Invoke-VeyonNativeProcess -File $File -ArgList $ArgList -TimeoutSeconds $TimeoutSeconds).ExitCode
}

function Invoke-VeyonQuery {
    param([string]$File, [string[]]$ArgList)
    return Invoke-VeyonNativeProcess -File $File -ArgList $ArgList -TimeoutSeconds 120 -CaptureOutput
}

function Get-VeyonCliPath {
    foreach ($programRoot in @(Get-VeyonProgramRoots)) {
        foreach ($name in @('veyon-cli.exe', 'veyon-ctl.exe')) {
            $candidate = Join-Path $programRoot ('Veyon\' + $name)
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                Assert-VeyonTrustedExecutable -Path $candidate
                return $candidate
            }
        }
    }
    return $null
}

function Test-MasterPresent {
    foreach ($programRoot in @(Get-VeyonProgramRoots)) {
        if (Test-Path -LiteralPath (Join-Path $programRoot 'Veyon\veyon-master.exe') -PathType Leaf) { return $true }
    }
    return $false
}

# --- Backup-Rotation: behält die 3 neuesten Backups ---
function Rotate-Backups {
    try {
        $keep = 3
        $json = @(Get-ChildItem -LiteralPath $BkDir -File -Filter 'config-*.json' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
        $reg  = @(Get-ChildItem -LiteralPath $BkDir -File -Filter 'registry-backup-*.reg' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
        if ($json.Count -gt $keep) {
            $del = $json[$keep..($json.Count-1)]
            foreach ($f in $del) { try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; Write-Log ("Backup-Rotation: gelöscht (JSON): " + $f.FullName) } catch {} }
        }
        if ($reg.Count -gt $keep) {
            $del = $reg[$keep..($reg.Count-1)]
            foreach ($f in $del) { try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; Write-Log ("Backup-Rotation: gelöscht (REG): " + $f.FullName) } catch {} }
        }
    } catch {
        Write-Log ("Backup-Rotation fehlgeschlagen: " + $_.Exception.Message)
    }
}

function Invoke-RegistryExport {
    param([string]$RegistryKey, [string]$OutputPath)
    return Invoke-Proc -File (Get-VeyonSystemExecutable -Name 'reg.exe') -ArgList @(
        'export', $RegistryKey, $OutputPath, '/y', '/reg:64'
    )
}

function Export-RegistryBackup {
    $ts = (Get-Date -f 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N')
    $regBk = Join-Path $BkDir ("registry-backup-{0}.reg" -f $ts)
    $backupSucceeded = $false
    try {
        $ec2 = Invoke-RegistryExport -RegistryKey 'HKLM\Software\Veyon Solutions' -OutputPath $regBk
        if ($ec2 -eq 0 -and (Test-Path $regBk -PathType Leaf) -and (Get-Item $regBk).Length -gt 0 -and (Get-Item $regBk).Length -le 16MB) {
            $registryText = Get-Content -LiteralPath $regBk -Raw
            if ($registryText -notmatch '(?m)^Windows Registry Editor Version 5\.00' -or
                $registryText -notmatch '(?im)^\[HKEY_LOCAL_MACHINE\\SOFTWARE\\Veyon Solutions(?:\\[^\r\n\]]*)?\]') {
                Write-Log 'Registry-Backup ist ungueltig.'
                return $false
            }
            Write-Log ("Konfigurations-Backup (Registry) erstellt: " + $regBk)
            $backupSucceeded = $true
            Rotate-Backups
            return $true
        } else {
            Write-Log ("Konfigurations-Backup (Registry) Exitcode: " + $ec2)
        }
    } catch {
        Write-Log ("Konfigurations-Backup (Registry) fehlgeschlagen: " + $_.Exception.Message)
    } finally {
        if (-not $backupSucceeded -and (Test-Path -LiteralPath $regBk)) {
            Remove-Item -LiteralPath $regBk -Force
        }
    }
    return $false
}

function Backup-VeyonConfig {
    $ts = (Get-Date -f 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N')
    $bk = $null
    try {
        $cli = Get-VeyonCliPath
        if ($null -ne $cli) {
            $bk = Join-Path $BkDir ("config-{0}.json" -f $ts)
            $ec = Invoke-Proc -File $cli -ArgList @('config','export',"$bk")
            if ($ec -eq 0 -and (Test-Path $bk -PathType Leaf) -and (Get-Item $bk).Length -gt 0 -and (Get-Item $bk).Length -le 16MB) {
                $configuration = Get-Content -LiteralPath $bk -Raw | ConvertFrom-Json -ErrorAction Stop
                if ($null -eq $configuration -or $configuration -isnot [pscustomobject]) {
                    throw 'Konfigurationsexport ist kein JSON-Objekt.'
                }
                Write-Log ("Konfigurations-Backup (CLI) erstellt: " + $bk)
                Rotate-Backups
                return $true
            } else {
                Write-Log ("Konfigurations-Backup (CLI) Exitcode: " + $ec + " – wechsle auf Registry-Backup")
            }
        } else {
            Write-Log "veyon-cli nicht gefunden – wechsle auf Registry-Backup"
        }
    } catch {
        Write-Log 'Konfigurations-Backup (CLI) fehlgeschlagen – wechsle auf Registry-Backup.'
    }
    if ($bk -and (Test-Path -LiteralPath $bk)) {
        Remove-Item -LiteralPath $bk -Force
    }
    return (Export-RegistryBackup)
}

# ---- Versionsermittlung ----
function Parse-InstalledSemVer {
    param([string]$Text)
    if (-not $Text) { return $null }
    if ($Text -match '^\s*(?:Veyon\s+)?v?(\d+(?:\.\d+){1,3})\s*$') {
        try { return [version]$matches[1] } catch { return $null }
    }
    return $null
}

function Get-VeyonInstalledVersion {
    param([switch]$FilesOnly)
    try {
        $cli = $null
        if (-not $FilesOnly) { $cli = Get-VeyonCliPath }
        if ($cli) {
            $result = Invoke-VeyonQuery -File $cli -ArgList @('--version')
            $v = $null
            if ($result.ExitCode -eq 0) { $v = Parse-InstalledSemVer $result.Output }
            if ($v) { return $v }
        }
    } catch {}
    $cand = @(foreach ($programRoot in @(Get-VeyonProgramRoots)) {
        Join-Path $programRoot 'Veyon\veyon-service.exe'
        Join-Path $programRoot 'Veyon\veyon-server.exe'
    }) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    if ($cand) {
        try {
            $info = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($cand)
            return [version]$info.FileVersion
        } catch {}
    }
    return $null
}

function Ensure-WingetSources {
    param([string]$WingetExe)
    Write-Log "winget: Quellen prüfen/aktualisieren ..."
    $ec = Invoke-Proc -File $WingetExe -ArgList @('source','update')
    if ($ec -ne 0) {
        throw "WinGet-Quellen konnten nicht aktualisiert werden (Exitcode $ec). Kein automatischer Quellen-Reset."
    } else {
        Write-Log "winget source update: OK"
    }
}

function Get-OnlineVersionStrict {
    param([string]$WingetExe)
    try {
        $result = Invoke-VeyonQuery -File $WingetExe -ArgList @('show', '--id', $PkgId, '-e', '--source', 'winget', '--disable-interactivity')
        if ($result.ExitCode -ne 0) { return $null }
        $out = $result.Output -split "`r?`n"
        $versions = @()
        foreach ($line in $out) {
            if ($line -match '^\s*Version\s*:\s*([0-9]+(?:\.[0-9]+){1,3})\s*$') {
                try { $versions += [version]$matches[1] } catch { return $null }
            }
        }
        if ($versions.Count -eq 1) { return $versions[0] }
        return $null
    } catch {
        return $null
    }
}

# ---------------- Hauptablauf ----------------
function Invoke-VeyonUpdate {
try {
Write-Log "=== Start ==="

if ($Testlauf) {
    $installed = Get-VeyonInstalledVersion -FilesOnly
    Write-Log ("TESTLAUF: Lokale Dateiversion: " + $installed)
    Write-Log 'TESTLAUF: Keine Dateien, Quellen oder Installation werden geaendert. Die Online-Abfrage wird ausgelassen, weil WinGet dabei seinen Cache aktualisieren kann.'
    return
}

$wingetPath = Resolve-WingetPath
if ($null -eq $wingetPath) {
    Write-Log "winget im aktuellen Kontext nicht verfügbar. Abbruch."
    Write-Log "=== Ende ==="
    return
} else {
    try {
        $query = Invoke-VeyonQuery -File $wingetPath -ArgList @('--version')
        if ($query.ExitCode -ne 0) { throw 'Versionsabfrage fehlgeschlagen.' }
        Write-Log ("winget gefunden: " + $wingetPath + " (" + $query.Output.Trim() + ")")
    } catch {
        Write-Log ("winget gefunden, Versionsabfrage fehlgeschlagen: " + $_.Exception.Message)
    }
}

$beforeVer = Get-VeyonInstalledVersion
if ($beforeVer) { Write-Log ("Installierte Version: " + $beforeVer) } else { Write-Log "Installierte Version: unbekannt" }
if (-not $beforeVer) {
    Write-Log 'Installierte Version unbekannt. Kein Upgrade und keine Quellenaenderung.'
    return
}

# Quellen aktualisieren
Ensure-WingetSources -WingetExe $wingetPath

$masterWasPresent = Test-MasterPresent
if ($masterWasPresent) { Write-Log "Veyon Master bereits vorhanden (wird beibehalten)." }
else { Write-Log "Veyon Master war NICHT vorhanden – wird NICHT nachinstalliert." }

# --- Entscheidung: nur bei *gesicherter* Online‑Neu‑Version sichern + upgraden ---
$onlineVer = Get-OnlineVersionStrict -WingetExe $wingetPath

$doBackup = $false
$doUpgrade = $false

if ($onlineVer -and $beforeVer -and ($onlineVer -gt $beforeVer)) {
    $doBackup = $true
    $doUpgrade = $true
} elseif ($onlineVer -and $beforeVer -and ($onlineVer -le $beforeVer)) {
    $doBackup = $false
    $doUpgrade = $false
} elseif (-not $onlineVer -or -not $beforeVer) {
    Write-Log 'Version nicht eindeutig ermittelbar. Kein Upgrade.'
}

if ($doBackup) {
    if (-not (Backup-VeyonConfig)) {
        throw 'Konfigurationssicherung fehlgeschlagen. Kein Upgrade.'
    }
}

if ($doUpgrade) {
    $args = @(
        'upgrade','--id',$PkgId,'-e',
        '--version',("{0}" -f $onlineVer),'--source','winget',
        '--silent','--disable-interactivity',
        '--accept-source-agreements','--accept-package-agreements',
        '--log',"$WingLog"
    )
    if (-not $masterWasPresent) {
        $args += @('--custom','/NoMaster')
    }
    Write-Log ("Ausführen: " + $wingetPath + " " + ($args -join ' '))
    $ec = Invoke-Proc -File $wingetPath -ArgList $args -TimeoutSeconds 1800
    Write-Log ("winget Exitcode: " + $ec)
    if ($ec -ne 0) { throw "WinGet-Upgrade fehlgeschlagen (Exitcode $ec)." }
} else {
    Write-Log "Kein Update notwendig – Skip (kein Backup, kein Upgrade)."
}

$afterVer = Get-VeyonInstalledVersion
if ($afterVer) { Write-Log ("Version nach Update: " + $afterVer) } else { Write-Log "Version nach Update: unbekannt" }
if ($doUpgrade -and (-not $afterVer -or $afterVer -lt $onlineVer)) {
    throw 'Die erwartete Version wurde nach dem Upgrade nicht bestaetigt.'
}

if ($beforeVer -and $afterVer) {
    if ($afterVer -gt $beforeVer) { Write-Log "Ergebnis: UPDATE ERFOLGREICH." }
    elseif ($afterVer -eq $beforeVer) { Write-Log "Ergebnis: Keine Änderung." }
    else { Write-Log "Ergebnis: WARNUNG – Version nachher kleiner als vorher." }
} elseif ($afterVer -and -not $beforeVer) {
    Write-Log "Ergebnis: Installation/Version ermittelt (vormals unbekannt)."
} else {
    Write-Log "Ergebnis: Version nicht ermittelbar."
}

Write-Log "=== Ende ==="
} catch {
    Write-Log ("Update fehlgeschlagen: " + $_.Exception.Message)
    throw
} finally {
    if (-not $Testlauf) {
        try { Rotate-Backups } catch { Write-Warning 'Backup-Rotation fehlgeschlagen.' }
        try { Trim-LogIfOversize } catch { Write-Warning 'Log-Rotation fehlgeschlagen.' }
    }
}
}

if (-not $Testlauf) {
    # Normalbetrieb nur aus der geschuetzten Installation. Die erste Pruefung
    # erfolgt vor dem Laden weiterer Skripte.
    if ($Base -notmatch '^[A-Za-z]:\\' -or $Base.Substring(2).Contains(':')) { throw 'Lokale Installation erforderlich.' }
    $expectedLock = [IO.Path]::GetFullPath((Join-Path $Base 'update.lock'))
    if ($null -eq $UpdateLock -or -not $UpdateLock.CanRead -or -not $UpdateLock.CanWrite -or
        $UpdateLock.SafeFileHandle.IsClosed -or $UpdateLock.SafeFileHandle.IsInvalid -or
        -not [string]::Equals([IO.Path]::GetFullPath($UpdateLock.Name), $expectedLock, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Normalbetrieb erfordert die offene Sperre des installierten Launchers.'
    }
    $versionsRoot = Join-Path $Base 'versions'
    if (-not [string]::Equals((Split-Path $PSScriptRoot -Parent), $versionsRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Bitte den installierten Launcher oder die geplante Aufgabe starten.'
    }
    $security = Join-Path $Base 'VeyonUpdater.Security.ps1'
    foreach ($guardPath in @($Base, $versionsRoot, $PSScriptRoot, $security)) {
        $item = Get-Item -LiteralPath $guardPath -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Unsicherer Installationspfad.' }
        if ($guardPath -eq $security -and $item.PSIsContainer) { throw 'Sicherheitsmodul ist keine Datei.' }
        if ($guardPath -ne $security -and -not $item.PSIsContainer) { throw 'Installationsverzeichnis fehlt.' }
        $acl = Get-Acl -LiteralPath $guardPath -ErrorAction Stop
        $rawAcl = [Security.AccessControl.RawSecurityDescriptor]::new($acl.GetSecurityDescriptorBinaryForm(), 0)
        if ($null -eq $rawAcl.DiscretionaryAcl -or
            ($rawAcl.ControlFlags -band [Security.AccessControl.ControlFlags]::DiscretionaryAclPresent) -eq 0) {
            throw 'Fehlende Zugriffsbeschraenkung im Installationspfad.'
        }
        if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin @('S-1-5-18', 'S-1-5-32-544')) {
            throw 'Unsicherer Besitzer des Installationspfads.'
        }
        if ($guardPath -eq $Base -and -not $acl.AreAccessRulesProtected) { throw 'Ungeschuetzte Vererbung im Installationspfad.' }
        foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
            if ($rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
                $rule.IdentityReference.Value -notin @('S-1-5-18', 'S-1-5-32-544')) {
                throw 'Unzulaessiger Zugriff auf den Installationspfad.'
            }
        }
    }
    $ancestor = [IO.Directory]::GetParent($Base)
    $trustedAncestors = @('S-1-5-18', 'S-1-5-32-544', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
    while ($ancestor) {
        if (([IO.File]::GetAttributes($ancestor.FullName) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Unsicherer uebergeordneter Installationspfad.'
        }
        $ancestorAcl = Get-Acl -LiteralPath $ancestor.FullName -ErrorAction Stop
        $rawAcl = [Security.AccessControl.RawSecurityDescriptor]::new($ancestorAcl.GetSecurityDescriptorBinaryForm(), 0)
        if ($null -eq $rawAcl.DiscretionaryAcl -or
            ($rawAcl.ControlFlags -band [Security.AccessControl.ControlFlags]::DiscretionaryAclPresent) -eq 0 -or
            $ancestorAcl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin $trustedAncestors) {
            throw 'Unsichere Zugriffsbeschraenkung im uebergeordneten Installationspfad.'
        }
        foreach ($rule in $ancestorAcl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
            if ($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or
                ($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) -ne 0) { continue }
            if ($rule.IdentityReference.Value -notin $trustedAncestors -and
                ([int]$rule.FileSystemRights -band 0x100D0040) -ne 0) {
                throw 'Uebergeordneter Installationspfad kann ersetzt werden.'
            }
        }
        $ancestor = $ancestor.Parent
    }
    . $security
    Assert-VeyonProtectedRoot -Root $Base
    if (-not (Test-Path -LiteralPath $BkDir -PathType Container)) { throw 'Geschuetztes Backup-Verzeichnis fehlt.' }
    $script:VeyonRuntimeLock = $UpdateLock
    $script:VeyonRuntimeRoot = $Base
}
Invoke-VeyonUpdate
