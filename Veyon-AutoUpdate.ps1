# Veyon-AutoUpdate.ps1
# Copyright Roman Glos 12.11.2025 V1.0

param([switch]$Testlauf)

$ErrorActionPreference = 'Stop'

$PkgId   = 'VeyonSolutions.Veyon'
$Base    = 'C:\ProgramData\Veyon\Update'
$Log     = Join-Path $Base 'veyon_autoupdate.log'
$WingLog = Join-Path $Base 'winget_last.log'
$BkDir   = Join-Path $Base 'config-backups'

New-Item -ItemType Directory -Force -Path $Base,$BkDir | Out-Null

# Deutsches Datumsformat
$de = [System.Globalization.CultureInfo]::GetCultureInfo('de-DE')
function Write-Log {
    param([string]$Text)
    $stamp = (Get-Date).ToString('dd.MM.yyyy HH:mm:ss', $de)
    Add-Content -Path $Log -Value "[$stamp] $Text"
}

# Logfile kürzen, wenn > 1 MB
function Trim-LogIfOversize {
    $maxBytes = 1MB
    try {
        if (Test-Path $Log) {
            $len = (Get-Item $Log).Length
            if ($len -gt $maxBytes) {
                $raw = Get-Content -Path $Log -Raw -ErrorAction Stop
                $marker = '=== Start ==='
                $idx = $raw.LastIndexOf($marker)
                if ($idx -ge 0) {
                    $keep = $raw.Substring($idx)
                    Set-Content -Path $Log -Value $keep -Encoding utf8
                    $stamp = (Get-Date).ToString('dd.MM.yyyy HH:mm:ss', $de)
                    Add-Content -Path $Log -Value "[$stamp] Hinweis: Log gekürzt (ältere Einträge entfernt; letzter Lauf beibehalten)."
                } else {
                    Clear-Content -Path $Log
                    $stamp = (Get-Date).ToString('dd.MM.yyyy HH:mm:ss', $de)
                    Add-Content -Path $Log -Value "[$stamp] Hinweis: Log gekürzt (kein Marker gefunden)."
                }
            }
        }
    } catch {
        Add-Content -Path $Log -Value "[$((Get-Date).ToString('dd.MM.yyyy HH:mm:ss', $de))] Warnung: Log-Trimming fehlgeschlagen: $($_.Exception.Message)"
    }
}

function Resolve-WingetPath {
    $patterns = @(
        (Join-Path $Env:ProgramFiles 'WindowsApps\Microsoft.DesktopAppInstaller_*\winget.exe'),
        'C:\Windows\System32\winget.exe'
    )
    foreach ($p in $patterns) {
        try {
            $cands = Get-ChildItem -Path $p -ErrorAction SilentlyContinue | Sort-Object FullName -Descending
            if ($cands -and $cands[0].FullName) { return $cands[0].FullName }
        } catch {}
    }
    try {
        $v = winget --version 2>$null
        if ($LASTEXITCODE -eq 0 -and $v) { return 'winget.exe' }
    } catch {}
    return $null
}

function Invoke-Proc {
    param([string]$File,[string[]]$ArgList)
    $psi = @{
        FilePath     = $File
        WindowStyle  = 'Hidden'
        PassThru     = $true
        Wait         = $true
    }
    if ($ArgList -and $ArgList.Count -gt 0) { $psi['ArgumentList'] = $ArgList }
    $p = Start-Process @psi
    return $p.ExitCode
}

function Get-VeyonCliPath {
    $cand = @(
        (Get-Command veyon-cli -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue),
        (Join-Path $Env:ProgramFiles 'Veyon\veyon-cli.exe'),
        (Join-Path ${Env:ProgramFiles(x86)} 'Veyon\veyon-cli.exe'),
        (Join-Path $Env:ProgramFiles 'Veyon\veyon-ctl.exe'),
        (Join-Path ${Env:ProgramFiles(x86)} 'Veyon\veyon-ctl.exe')
    ) | Where-Object { $_ -and (Test-Path $_ -PathType Leaf) } | Select-Object -First 1
    if ($cand) { return $cand } else { return $null }
}

function Test-MasterPresent {
    $p1 = Join-Path $Env:ProgramFiles 'Veyon\veyon-master.exe'
    $p2 = Join-Path ${Env:ProgramFiles(x86)} 'Veyon\veyon-master.exe'
    return (Test-Path $p1 -PathType Leaf) -or (Test-Path $p2 -PathType Leaf)
}

# --- Backup-Rotation: behält die 3 neuesten Backups ---
function Rotate-Backups {
    try {
        $keep = 3
        $json = Get-ChildItem -Path $BkDir -Filter 'config-*.json' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
        $reg  = Get-ChildItem -Path $BkDir -Filter 'registry-backup-*.reg' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
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

function Export-RegistryBackup {
    $ts = (Get-Date -f 'yyyyMMdd-HHmmss')
    $regBk = Join-Path $BkDir ("registry-backup-{0}.reg" -f $ts)
    try {
        $ec2 = Invoke-Proc -File 'reg.exe' -ArgList @('export','HKLM\Software\Veyon Solutions',"$regBk","/y","/reg:64")
        if ($ec2 -eq 0 -and (Test-Path $regBk -PathType Leaf)) {
            Write-Log ("Konfigurations-Backup (Registry) erstellt: " + $regBk)
        } else {
            Write-Log ("Konfigurations-Backup (Registry) Exitcode: " + $ec2)
        }
    } catch {
        Write-Log ("Konfigurations-Backup (Registry) fehlgeschlagen: " + $_.Exception.Message)
    }
    Rotate-Backups
}

function Backup-VeyonConfig {
    $ts = (Get-Date -f 'yyyyMMdd-HHmmss')
    try {
        $cli = Get-VeyonCliPath
        if ($null -ne $cli) {
            $bk = Join-Path $BkDir ("config-{0}.json" -f $ts)
            $ec = Invoke-Proc -File $cli -ArgList @('config','export',"$bk")
            if ($ec -eq 0 -and (Test-Path $bk -PathType Leaf)) {
                Write-Log ("Konfigurations-Backup (CLI) erstellt: " + $bk)
                Rotate-Backups
                return
            } else {
                Write-Log ("Konfigurations-Backup (CLI) Exitcode: " + $ec + " – wechsle auf Registry-Backup")
            }
        } else {
            Write-Log "veyon-cli nicht gefunden – wechsle auf Registry-Backup"
        }
    } catch {
        Write-Log ("Konfigurations-Backup (CLI) fehlgeschlagen: " + $_.Exception.Message + " – wechsle auf Registry-Backup")
    }
    Export-RegistryBackup
}

# ---- Versionsermittlung ----
function Parse-InstalledSemVer {
    param([string]$Text)
    if (-not $Text) { return $null }
    if ($Text -match '(\d+(?:\.\d+){1,3})') {
        try { return [version]$matches[1] } catch { return $null }
    }
    return $null
}

function Get-VeyonInstalledVersion {
    try {
        $cli = Get-VeyonCliPath
        if ($cli) {
            $t = (& "$cli" --version 2>&1) -join "`n"
            $v = Parse-InstalledSemVer $t
            if ($v) { return $v }
        }
    } catch {}
    $cand = @(
        (Join-Path $Env:ProgramFiles 'Veyon\veyon-service.exe'),
        (Join-Path $Env:ProgramFiles 'Veyon\veyon-server.exe'),
        (Join-Path ${Env:ProgramFiles(x86)} 'Veyon\veyon-service.exe'),
        (Join-Path ${Env:ProgramFiles(x86)} 'Veyon\veyon-server.exe')
    ) | Where-Object { Test-Path $_ -PathType Leaf } | Select-Object -First 1
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
        Write-Log ("winget source update Exitcode: " + $ec + " → versuche Reset")
        $ec2 = Invoke-Proc -File $WingetExe -ArgList @('source','reset','--force')
        Write-Log ("winget source reset --force Exitcode: " + $ec2)
        $ec3 = Invoke-Proc -File $WingetExe -ArgList @('source','update')
        Write-Log ("winget source update (nach Reset) Exitcode: " + $ec3)
    } else {
        Write-Log "winget source update: OK"
    }
}

function Get-OnlineVersionStrict {
    param([string]$WingetExe)
    try {
        $out = (& "$WingetExe" show --id $PkgId -e --source winget --disable-interactivity 2>&1) -split "`r?`n"
        foreach ($line in $out) {
            if ($line -match '^\s*Version\s*:\s*([0-9]+(?:\.[0-9]+){1,3})\s*$') {
                try { return [version]$matches[1] } catch { return $null }
            }
        }
        return $null
    } catch {
        return $null
    }
}

# ---------------- Hauptablauf ----------------
Write-Log "=== Start ==="

$wingetPath = Resolve-WingetPath
if ($null -eq $wingetPath) {
    Write-Log "winget im aktuellen Kontext nicht verfügbar. Abbruch."
    Write-Log "=== Ende ==="
    Trim-LogIfOversize
    exit 0
} else {
    try {
        $v = & "$wingetPath" --version 2>$null
        Write-Log ("winget gefunden: " + $wingetPath + " (" + $v + ")")
    } catch {
        Write-Log ("winget gefunden, Versionsabfrage fehlgeschlagen: " + $_.Exception.Message)
    }
}

$beforeVer = Get-VeyonInstalledVersion
if ($beforeVer) { Write-Log ("Installierte Version: " + $beforeVer) } else { Write-Log "Installierte Version: unbekannt" }

# Quellen bereinigen
Ensure-WingetSources -WingetExe $wingetPath

# ---- Testlauf: nur Online-Version prüfen, *keine* Installation/Backups ----
if ($Testlauf) {
    $online = Get-OnlineVersionStrict -WingetExe $wingetPath
    if ($online) {
        Write-Log ("Online verfügbare Version laut winget: " + $online)
        if ($beforeVer -and ($online -gt $beforeVer)) {
            Write-Log "TESTLAUF: Update wäre verfügbar – keine Installation im Testmodus."
        } elseif ($beforeVer -and ($online -le $beforeVer)) {
            Write-Log "TESTLAUF: Bereits aktuell – keine Installation nötig."
        }
    }
    Write-Log "=== Ende (Testlauf) ==="
    Trim-LogIfOversize
    exit 0
}

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
} elseif (-not $onlineVer) {
    if (-not $beforeVer) { $doUpgrade = $true }
}

if ($doBackup) {
    Backup-VeyonConfig
}

if ($doUpgrade) {
    $args = @(
        'upgrade','--id',$PkgId,'-e',
        '--silent','--disable-interactivity',
        '--accept-source-agreements','--accept-package-agreements',
        '--log',"$WingLog"
    )
    if (-not $masterWasPresent) {
        $args += @('--custom','/NoMaster')
    }
    Write-Log ("Ausführen: " + $wingetPath + " " + ($args -join ' '))
    $ec = Invoke-Proc -File $wingetPath -ArgList $args
    Write-Log ("winget Exitcode: " + $ec)
} else {
    Write-Log "Kein Update notwendig – Skip (kein Backup, kein Upgrade)."
}

$afterVer = Get-VeyonInstalledVersion
if ($afterVer) { Write-Log ("Version nach Update: " + $afterVer) } else { Write-Log "Version nach Update: unbekannt" }

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
Trim-LogIfOversize
