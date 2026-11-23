# Privacy policy / Datenschutz

## Was das Programm macht

Veyon Auto-Update for Windows aktualisiert eine bestehende Veyon-Installation. Die Einrichtung erfolgt mit Administratorrechten. Anschließend prüft eine geplante Windows-Aufgabe unter SYSTEM über WinGet, ob eine neuere Veyon-Version verfügbar ist.

## Netzwerkverbindungen

Für die Suche nach Updates und deren Installation ruft WinGet die konfigurierten Paketquellen und die dort angegebenen Downloadserver auf. Dabei erhalten die jeweiligen Betreiber übliche Verbindungsdaten wie die öffentliche IP-Adresse. Welche Server kontaktiert werden, hängt von der WinGet-Konfiguration und dem jeweiligen Veyon-Paket ab.

Beim manuellen Herunterladen über GitHub gelten zusätzlich die Datenschutzregeln von GitHub. Ein automatischer GitHub-Selbstupdater ist **in Version 1.4 noch nicht enthalten**.

Das Projekt betreibt keinen eigenen Telemetrie- oder Analysedienst und lädt keine Veyon-Konfigurationssicherungen zu Railsimulatornet hoch.

## Lokale Daten

- Protokolle und WinGet-Logs werden unter `C:\ProgramData\Veyon\Update\` gespeichert.
- Vor einem Veyon-Upgrade werden Konfigurationen lokal gesichert. Diese Sicherungen können sensible Einstellungen enthalten.
- Bei der Deinstallation über `Remove-Veyon-AutoUpdate.cmd` wird der Updateordner einschließlich Logs und Sicherungen gelöscht. Benötigte Sicherungen müssen vorher kopiert werden.

Die automatische Aufgabe lässt sich in der Windows-Aufgabenplanung deaktivieren oder über das Entfernungsskript entfernen. Ohne aktive Aufgabe erfolgen durch dieses Projekt keine geplanten Veyon-Updates.

Weitere Informationen zu den verwendeten Diensten: [Microsoft-Datenschutzerklärung](https://privacy.microsoft.com/de-de/privacystatement) und [GitHub-Datenschutzerklärung](https://docs.github.com/de/site-policy/privacy-policies/github-general-privacy-statement).

## English

The project does not operate its own telemetry or analytics service. WinGet connects to configured package sources and download servers to check for and install Veyon updates. Connection metadata such as an IP address may be visible to those services. Logs and configuration backups remain on the local computer. Backups may contain sensitive settings. The scheduled task can be disabled or the updater uninstalled. An automatic GitHub self-updater is not part of version 1.4.
