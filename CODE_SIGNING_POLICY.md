# Code signing policy

## Status

Für dieses Projekt wurde die kostenlose Codesignierung über SignPath Foundation beantragt. Die Freigabe steht noch aus. **Version 1.4 und die bisherigen Downloads sind nicht mit SignPath signiert.**

Vorgesehener Hinweis für spätere, tatsächlich signierte Veröffentlichungen:

> Free code signing provided by [SignPath.io](https://signpath.io/), certificate by [SignPath Foundation](https://signpath.org/).

## Zuständigkeiten

- **Entwicklung und Pflege:** [Railsimulatornet](https://github.com/Railsimulatornet)
- **Prüfung von Beiträgen:** Railsimulatornet. Externe Pull Requests werden vor der Übernahme geprüft.
- **Freigabe der Signierung und Veröffentlichung:** Railsimulatornet. Jede Signierung wird einzeln genehmigt.

## Freigabe eines Releases

1. Änderungen erfolgen über einen Entwicklungsbranch und Pull Request.
2. GitHub Actions prüft PowerShell-Syntax, Updateentscheidungen, Paketinhalt, reproduzierbaren Build und die automatisierten Windows-Installationstests.
3. Die endgültigen ZIP- und EXE-Dateien müssen dem geprüften Commit zugeordnet sein. Nachträgliches Austauschen ungeprüfter Assets ist nicht zulässig.
4. Zuerst wird ein Pre-Release getestet. Ein Stable-Release benötigt zusätzlich eine erfolgreiche praktische Windows-Abnahme und die ausdrückliche Freigabe des Maintainers.
5. Nach Freischaltung von SignPath gilt zusätzlich: Herkunft des Builds prüfen, den Signiervorgang manuell genehmigen und Signatur, Zeitstempel, Dateimetadaten und Prüfsummen des fertigen Downloads kontrollieren.

Für signierte eigene Binärdateien müssen Produktname und Produktversion über den gesamten Build hinweg einheitlich und über SignPath-Dateimetadatenregeln abgesichert sein. Private Signierschlüssel gehören nicht ins Repository oder auf einen GitHub-Runner.

**Offener Punkt:** Das bisherige Setup verwendet ein vorgefertigtes 7-Zip-SFX-Modul. Es ist keine selbst entwickelte ausführbare Datei. Vor einer Signierung durch SignPath Foundation muss geklärt und nachgewiesen sein, dass die konkrete Paketform deren Vorgaben für Fremdbinärdateien erfüllt. Bis dahin bleibt die Signierung deaktiviert.

## Sicherheit und Datenschutz

Der Updater darf nur geprüfte Veröffentlichungen verarbeiten. Unbekannte oder manipulierte Dateien dürfen nicht mit erhöhten Rechten ausgeführt werden. Die spätere Selbstupdate-Funktion erhält hierfür eine eigene Signaturprüfung und einen Wiederherstellungsweg; sie ist in Version 1.4 noch nicht enthalten.

Datenschutz und tatsächliche Netzwerkverbindungen: [Privacy policy](PRIVACY.md).

Voraussetzungen der Foundation: [SignPath Foundation Conditions](https://signpath.org/terms).
