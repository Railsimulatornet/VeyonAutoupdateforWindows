# Datenschutz / Privacy policy

## Deutsch

Veyon Auto-Update for Windows aktualisiert eine bestehende Veyon-Installation über WinGet. Die Einrichtung benötigt Administratorrechte. Danach übernimmt eine geplante Windows-Aufgabe die Updateprüfung.

**Netzwerk:** WinGet kontaktiert die eingerichteten Paketquellen und die für Veyon hinterlegten Downloadserver. Dabei fallen beim jeweiligen Anbieter übliche Verbindungsdaten an, etwa die öffentliche IP-Adresse. Das Projekt betreibt keinen eigenen Telemetriedienst und überträgt keine Konfigurationssicherungen an Railsimulatornet.

**Lokal:** Protokolle und Sicherungen liegen unter `C:\ProgramData\Veyon\Update\`. Konfigurationssicherungen können sensible Einstellungen enthalten. Das Deinstallationsskript entfernt diesen Ordner; benötigte Sicherungen müssen vorher kopiert werden.

**Dienste:** [Datenschutz bei Microsoft](https://privacy.microsoft.com/de-de/privacystatement) · [Datenschutz bei GitHub](https://docs.github.com/de/site-policy/privacy-policies/github-general-privacy-statement)

## English

The updater uses WinGet to check package sources and download Veyon updates. Package source and download providers may receive standard connection data such as IP addresses. The project does not run its own telemetry service or upload configuration backups to Railsimulatornet.

Logs and backups are stored locally under `C:\ProgramData\Veyon\Update\`. Configuration backups may contain sensitive settings. Uninstalling the updater removes this folder; copy any backups that you want to keep before uninstalling.
