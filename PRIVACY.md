# Datenschutz / Privacy policy

## Deutsch

Der Updater prüft und aktualisiert eine vorhandene Veyon-Installation über WinGet. Eine geplante Windows-Aufgabe übernimmt die Ausführung als SYSTEM.

**Netzwerk:** WinGet kontaktiert konfigurierte Paketquellen und Veyon-Downloadserver. Für eigene Updates fragt der Updater die öffentlichen Releases dieses GitHub-Repositorys ab und lädt bei Bedarf Manifest, Signatur und Updatepaket. Dabei erhalten die jeweiligen Anbieter übliche Verbindungsdaten, etwa die öffentliche IP-Adresse. Der GitHub-Aufruf enthält die Updater-Version im User-Agent, aber keine Veyon-Konfiguration oder Gerätekennung. Für die öffentlichen Releaseabfragen wird kein GitHub-Zugangstoken verwendet.

**Lokal:** Protokolle, Installationszustand und Konfigurationssicherungen liegen unter `C:\ProgramData\VeyonUpdater`. Die Sicherungen können sensible Einstellungen enthalten und sind nur für Administratoren und SYSTEM lesbar. Protokolle und Sicherungen werden begrenzt aufbewahrt. Die Deinstallation erhält Konfigurationssicherungen standardmäßig; die Option `-DeleteBackups` entfernt sie ausdrücklich. Bei einer Migration bleiben außerdem die übernommenen Originaldateien im bisherigen Sicherungsverzeichnis erhalten.

Das Projekt betreibt keinen eigenen Telemetriedienst und lädt keine Konfigurationssicherungen oder Protokolle zu Railsimulatornet hoch. Das Verhalten und die Datenschutzkonfiguration von Veyon selbst werden durch diese Angaben nicht ersetzt.

[Datenschutz bei Microsoft](https://privacy.microsoft.com/de-de/privacystatement) · [Datenschutz bei GitHub](https://docs.github.com/de/site-policy/privacy-policies/github-general-privacy-statement)

## English

WinGet contacts configured package sources and Veyon download servers. The updater also checks this repository's public GitHub releases and downloads update metadata and payloads when needed. Providers receive normal connection data such as IP addresses. GitHub requests include the updater version in the User-Agent, with no Veyon configuration, device identifier or GitHub access token.

Logs, installation state and configuration backups remain under `C:\ProgramData\VeyonUpdater`. Backups may contain sensitive settings and are restricted to administrators and SYSTEM. Logs and backups have retention limits. Uninstallation keeps configuration backups unless `-DeleteBackups` is explicitly selected. Migration also retains the original files in the old backup directory.

The project runs no telemetry service and does not upload logs or configuration backups to Railsimulatornet. Veyon's own privacy settings and behaviour remain separate.
