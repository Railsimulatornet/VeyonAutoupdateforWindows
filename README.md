# Veyon Auto-Update (WinGet)

Version: **1.5.0**

[![PowerShell](https://github.com/Railsimulatornet/VeyonAutoupdateforWindows/actions/workflows/powershell-validation.yml/badge.svg?branch=main)](https://github.com/Railsimulatornet/VeyonAutoupdateforWindows/actions/workflows/powershell-validation.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

[Deutsch](#deutsch) · [English](#english)

[Code signing policy](CODE_SIGNING_POLICY.md) · [Datenschutz / Privacy](PRIVACY.md) · [Sicherheit / Security](SECURITY.md) · [Nutzungshinweise / Terms](TERMS.md)

## Deutsch

Der Updater aktualisiert eine vorhandene Veyon-Installation über WinGet. Eine geplante Aufgabe läuft als SYSTEM etwa zwei Minuten nach dem Systemstart oder, bei aktiviertem Windows-Schnellstart, nach der Benutzeranmeldung. Für die Einrichtung werden Administratorrechte benötigt; spätere automatische Läufe benötigen keine Administratoranmeldung.

### Voraussetzungen

- Windows 10 oder 11 mit Windows PowerShell 5.1 und .NET Framework 4.8.
- App Installer / WinGet, auch im SYSTEM-Kontext verfügbar.
- Bereits installiertes Veyon; Veyon Master ist optional.
- Zugriff auf GitHub für Updater-Aktualisierungen sowie auf WinGet-Quellen und Veyon-Downloads.

### Installation

1. Lade das gewünschte Paket aus den [offiziellen Releases](https://github.com/Railsimulatornet/VeyonAutoupdateforWindows/releases). Für diese Version heißen die Dateien `VeyonUpdater_v1.5.0_Setup.exe` und `VeyonUpdater_v1.5.0.zip`.
2. Prüfe Herkunft und SHA-256 anhand der Angaben zu genau diesem Release. Die erste Installation legt den vertrauenswürdigen Startpunkt fest; beachte die [Signierrichtlinie](CODE_SIGNING_POLICY.md).
3. Starte die Setup-Datei. Alternativ entpacke die ZIP vollständig und führe `Install-Veyon-AutoUpdate.cmd` als Administrator aus.
4. Prüfe die Aufgabe `Veyon AutoUpdate (winget)` und führe den unten beschriebenen Prüflauf aus. Teste das Paket auf einem passenden Gerät, bevor du es breiter verteilst.

Das Setup installiert nach `C:\ProgramData\VeyonUpdater`. Startprogramm, Sicherheitskern, Zustand, Versionsdateien und Sicherungen sind gegen Änderungen durch Standardbenutzer geschützt. Konfigurationssicherungen sind nur für Administratoren und SYSTEM lesbar.

Beim Wechsel von Version 1.4 wird die vorhandene Aufgabe umgestellt. Vorhandene Konfigurationssicherungen aus `C:\ProgramData\Veyon\Update\config-backups` werden abgesichert und übernommen. Die bisherigen Sicherungsdateien bleiben erhalten. Die Berechtigungen des übergeordneten Veyon-Verzeichnisses werden dabei nicht pauschal verändert.

### Updateverhalten

| Bereich | Verhalten |
|---|---|
| Veyon | Nur `VeyonSolutions.Veyon` aus der Quelle `winget`; die zuvor geprüfte Zielversion wird fest angegeben |
| Versionsprüfung | Upgrade nur bei eindeutig ermittelter neuerer Version |
| Sicherung | Vor dem Upgrade JSON-Export über die Veyon-CLI, ersatzweise Registry-Export |
| Veyon Master | War Master nicht vorhanden, wird `/NoMaster` übergeben |
| Fehlende Sicherung | Kein Veyon-Upgrade |
| Selbstupdate | Höchstens einmal innerhalb von 24 Stunden bei einem regulären Lauf; nur neuere stabile Releases |
| Freigabeprüfung | RSA-3072/PSS mit SHA-256, fest hinterlegter öffentlicher Schlüssel und Dateiprüfsummen |
| Aktivierung | Vollständig geprüfte neue Versionsdateien, lokaler Prüflauf, anschließend Wechsel des geschützten Zustands |
| Rückfall | Bekannte vorherige Version bei lokalem Integritäts- oder Prüflauffehler; der höchste akzeptierte Versionsstand bleibt erhalten |

Die Selbstaktualisierung umfasst die beiden Laufzeitskripte. Startprogramm, Sicherheitskern und Vertrauensschlüssel werden über eine manuelle Installation gepflegt. Ein abweichender vorhandener Sicherheitskern wird bei einer erneuten Installation nicht still überschrieben.

Ist GitHub nicht erreichbar oder ein Update ungültig, bleibt die installierte Version bestehen. Die reguläre Veyon-Prüfung kann weiterlaufen. Eine beschädigte lokale Installation wird nicht ausgeführt. Die eigene Veyon-Konfiguration wird nicht durch vorgegebene Einstellungen ersetzt; Sicherungen stehen für eine gesonderte manuelle Wiederherstellung bereit.

### Protokolle und Prüflauf

Die folgenden Dateien liegen unter `C:\ProgramData\VeyonUpdater`:

| Datei / Ordner | Inhalt |
|---|---|
| `veyon_autoupdate.log` | Veyon-Updateablauf, Versionen und Exitcodes |
| `winget_last.log` | WinGet-Protokoll des Upgrade-Aufrufs |
| `selfupdate.log` | Prüfung und Aktivierung von Updater-Versionen |
| `config-backups` | Bis zu drei laufende JSON- und drei Registry-Sicherungen; übernommene `legacy-*`-Sicherungen bleiben zusätzlich erhalten |

Laufprotokolle und Sicherungen werden auch nach fehlgeschlagenen Läufen begrenzt. Das Veyon-Protokoll wird oberhalb von 1 MiB, das WinGet-Protokoll oberhalb von 4 MiB auf einen Ausschnitt vom Ende gekürzt.

Prüflauf in einer PowerShell mit Administratorrechten:

```powershell
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "C:\ProgramData\VeyonUpdater\Start-VeyonUpdater.ps1" -Testlauf
```

Der Prüflauf kontrolliert die installierten Dateien und liest die lokale Veyon-Dateiversion. Er lädt nichts herunter, startet kein Upgrade und verändert weder Konfiguration noch Protokolle oder Sicherungen.

### Wartung und Deinstallation

Bei geändertem Windows-Schnellstart kann eine erneute Installation mit demselben Sicherheitskern den passenden Trigger einrichten. Sichere benötigte Konfigurationsdateien vor Wartungsarbeiten. Manuelle Rückstufungen und Änderungen am Vertrauensschlüssel erfordern eine bewusste Neuinstallation; sie werden nicht über normale Selbstupdates verteilt.

Wurde eine Erstinstallation oder Neuinstallation durch Stromausfall oder Prozessabbruch unterbrochen, kann die Aufgabe deaktiviert bleiben. Starte dasselbe unveränderte vertrauenswürdige Installationspaket erneut. Ein abweichender oder fehlender Sicherheitskern bei vorhandenem Installationszustand wird nicht automatisch ersetzt.

Für einen bewussten Wechsel des Sicherheitskerns oder Schlüssels:

1. Stelle zuerst das vollständige neue Installationspaket aus einer vertrauenswürdigen Quelle bereit und sichere benötigte Konfigurationssicherungen separat.
2. Entferne die bisherige Aufgabe und die Programmdateien mit `Remove-Veyon-AutoUpdate.cmd`, ohne `-DeleteBackups` zu verwenden.
3. Installiere das neue Paket als Administrator und prüfe Aufgabe und Prüflauf.

Während dieser Umstellung läuft kein automatischer Updater. Die geschützten Konfigurationssicherungen bleiben erhalten. Die neue Installation legt den vertrauenswürdigen Startpunkt erneut fest.

**Unterbrochener externer Prozess:** Bleibt `native-operation.json` zurück, werden weitere normale Läufe und Installationen gesperrt. Starte den Rechner kontrolliert neu und prüfe danach die installierte Veyon-Version, die Protokolle und gegebenenfalls noch laufende Windows-Installer-Vorgänge. Erst wenn keine Installation mehr läuft und der Zustand geklärt ist, entferne diese Markierungsdatei bewusst als Administrator. Wiederhole anschließend Prüflauf und normalen Start. Die Datei wird nicht automatisch gelöscht; ein Prozessabbruch bestätigt keinen vollständigen Abbruch aller Installer-Dienstvorgänge.

`Remove-Veyon-AutoUpdate.cmd` entfernt als Administrator die Aufgabe und die Updater-Programmdateien. Konfigurationssicherungen bleiben standardmäßig erhalten. Die optionale PowerShell-Option `-DeleteBackups` entfernt sie ausdrücklich. Veyon selbst wird nicht deinstalliert.

| Problem | Prüfen |
|---|---|
| Nach dem Einschalten kein Lauf | Aufgabenplanung; bei Schnellstart wird die Anmeldung als Trigger verwendet |
| Kein Veyon-Update | WinGet im SYSTEM-Kontext, Versionsangaben, Netzwerk und Sicherungsfehler im Log |
| Selbstupdate wird übersprungen | Stabiles Release, Signatur, Versionsstand, Zertifikatslaufzeit und `selfupdate.log` |
| Integritäts- oder Berechtigungsfehler | Installation als Administrator prüfen; keine Schutzprüfung abschalten |
| Unterbrochenes Veyon-Upgrade | Installierte Veyon-Version und WinGet-Protokoll kontrollieren; ein Timeout bestätigt keinen abgeschlossenen Rollback |

## English

The updater maintains an existing Veyon installation through WinGet. Its SYSTEM task runs about two minutes after startup, or after user logon when Windows Fast Startup is enabled. Installation requires administrator privileges; later automatic runs do not require an administrator to sign in.

### Installation and requirements

Use Windows 10 or 11 with Windows PowerShell 5.1, .NET Framework 4.8, an existing Veyon installation and WinGet available to SYSTEM. Network access is required for GitHub release checks, WinGet sources and Veyon downloads.

Download the setup executable or ZIP from the [official releases](https://github.com/Railsimulatornet/VeyonAutoupdateforWindows/releases). Verify its origin and the SHA-256 for that release before running it. Run the setup, or fully extract the ZIP and run `Install-Veyon-AutoUpdate.cmd` as administrator. The initial installation establishes trust; see the [signing policy](CODE_SIGNING_POLICY.md).

The protected installation directory is `C:\ProgramData\VeyonUpdater`. The task is named `Veyon AutoUpdate (winget)`. Migration from version 1.4 protects and copies existing configuration backups and switches the task. It retains the original backup files and does not change permissions across the parent Veyon directory.

### Behaviour

- Veyon upgrades use the exact package ID, the `winget` source and the checked target version. Ambiguous versions or a failed configuration backup prevent an upgrade.
- A JSON configuration export is attempted first, with a registry export as fallback. `/NoMaster` is passed when Veyon Master was not installed.
- Updater release checks occur at most once per 24 hours during normal runs. Only newer stable releases with a valid RSA-3072/PSS SHA-256 manifest and matching payload hashes are accepted.
- Runtime scripts are staged and checked before an atomic state change activates them. A known previous version can recover from a local integrity or healthcheck failure; the highest accepted version is retained.
- The launcher, security core and public trust key require manual installation. Reinstallation does not silently replace a different security core.
- GitHub failures leave the current version in place and allow the normal Veyon check to continue. A damaged local installation is not executed.

Logs and configuration backups use the same filenames listed above. Up to three current JSON and three registry backups are retained; migrated `legacy-*` backups are kept separately in addition. Logs are bounded, including failed runs. Configuration backups are readable only by administrators and SYSTEM.

Run the PowerShell command above from an elevated shell for a local integrity and version check. It performs no downloads or upgrades and makes no configuration, log or backup changes.

### Maintenance and removal

Test an installation on your target Windows system before wider deployment. Keep the configuration backups you need. Signature verification does not guarantee that a release is free of defects, and an unavailable update service cannot guarantee delivery of newer releases.

An interrupted manual installation may leave the task disabled. Rerun the same unchanged trusted package. A missing or different security core with existing installation state requires manual maintenance. To replace the security core or key, first obtain the complete trusted new package and save the backups you need. Remove the old task and program files without `-DeleteBackups`, then install the new package as administrator and check the task and test run. Automatic updating pauses during this change; protected configuration backups remain. The new installation establishes trust again.

If `native-operation.json` remains after an interrupted external process, further normal runs and installations are blocked. Restart the computer in a controlled manner, then inspect the installed Veyon version, logs and any continuing Windows Installer activity. Only after confirming that no installation is still running and resolving the state should an administrator remove the marker and repeat the test and normal run. The marker is never removed automatically, and process termination does not prove that every installer service operation was stopped.

Run `Remove-Veyon-AutoUpdate.cmd` as administrator to remove the task and updater files. Configuration backups are retained by default; the PowerShell `-DeleteBackups` option explicitly removes them. Veyon itself remains installed.

## License

[MIT License](LICENSE). Copyright © 2026 Roman Glos / Railsimulatornet.
