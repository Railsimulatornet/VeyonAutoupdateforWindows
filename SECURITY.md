# Sicherheit / Security

Sicherheitsprobleme bitte nicht mit Exploit-Details oder Zugangsdaten in öffentlichen Issues melden. Verwende nach Möglichkeit eine private Sicherheitsmeldung über GitHub oder den am [GitHub-Profil](https://github.com/Railsimulatornet) hinterlegten Kontaktweg.

Dieses Projekt richtet die Veyon-Aktualisierung mit erhöhten Rechten ein. Deshalb werden Änderungen am Installer, den Update-Skripten und dem Build-Prozess besonders sorgfältig geprüft.

- Kein ungeprüfter Download darf unter SYSTEM ausgeführt werden.
- Kein Signierschlüssel und kein Zugangstoken gehört in den Quellcode.
- Automatische Selbstupdates benötigen vor ihrer Aktivierung eine geprüfte Vertrauenskette und Wiederherstellung.
- Neue Funktionen werden zuerst als Pre-Release erprobt.

Die verbindlichen Veröffentlichungsschritte stehen in der [Release-Checkliste](RELEASE_CHECKLIST.md). Die [Code signing policy](CODE_SIGNING_POLICY.md) beschreibt die geplante Signierung.
