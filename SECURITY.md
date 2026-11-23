# Sicherheit / Security

Bitte melde Sicherheitsprobleme vertraulich über [GitHub Private Vulnerability Reporting](https://github.com/Railsimulatornet/VeyonAutoupdateforWindows/security/advisories/new). Falls dieser Weg nicht verfügbar ist, nutze den Kontakt im [GitHub-Profil](https://github.com/Railsimulatornet). Zugangsdaten, private Schlüssel und nicht bereinigte Konfigurationssicherungen gehören nicht in öffentliche Issues.

Hilfreich sind betroffene Version, Windows-Version, Voraussetzungen und ein reproduzierbarer Ablauf. Entferne persönliche Daten aus beigefügten Protokollen.

## Schutzumfang

Der Updater läuft als SYSTEM. Ausführbare Dateien, Versionszustand und Sicherungen liegen deshalb in einem geschützten Verzeichnis. Normale Benutzer sollen dort weder Code oder Zustand ändern noch Konfigurationssicherungen lesen können. Reparse Points und unsichere Pfade werden abgelehnt.

Automatische Laufzeitupdates erfordern ein gültig signiertes Manifest und passende Datei- und Paketprüfsummen. Neue Dateien werden vor ihrer Aktivierung geprüft. Ein lokaler Rückfall auf die bekannte vorherige Version setzt den gespeicherten höchsten Versionsstand nicht zurück.

Installiere ausschließlich über einen vertrauenswürdigen Weg aus den [offiziellen Releases](https://github.com/Railsimulatornet/VeyonAutoupdateforWindows/releases) und prüfe die zugehörigen Angaben. Die Erstinstallation, der Sicherheitskern und Schlüsselwechsel benötigen manuelle Kontrolle. Eine Signatur ersetzt keine Funktionstests. Details und Grenzen stehen in der [Code signing policy](CODE_SIGNING_POLICY.md).

## English

Report vulnerabilities privately through GitHub's reporting link above, or use the maintainer's profile contact if that route is unavailable. Include the affected version, Windows version and reproduction steps. Do not publish credentials, private keys or configuration backups.

The SYSTEM task uses protected installation files and state. Automatic runtime updates require a valid signed manifest and matching hashes before activation. Trusted initial installation and manual maintenance of the security core remain necessary. Administrator or operating-system compromise and release-signing key compromise are outside the protections provided by local file permissions and manifest verification.
