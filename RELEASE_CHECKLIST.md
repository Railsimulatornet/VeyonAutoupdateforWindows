# Release-Checkliste

**Grundsatz:** Qualität vor Quantität. Kein Stable-Release ohne nachgewiesene Tests und Freigabe.

## Vor jeder Veröffentlichung

- [ ] Pull Request geprüft; Quellstand und Buildskripte nachvollziehbar.
- [ ] GitHub Actions vollständig grün: PowerShell-Parser, simulierte Update- und Fehlerfälle, ZIP-/EXE-Bau.
- [ ] Echte Windows-Installationstests erfolgreich: Aufgabenplanung, SYSTEM-Konto, Startverzögerung, Akkubetrieb und installierte Dateiprüfsummen.
- [ ] Windows-11-x64-Praxistest einschließlich Setup und Veyon-Update dokumentiert.
- [ ] Backup, bestehender Veyon Master und Fehler-/Abbruchverhalten kontrolliert.
- [ ] EXE und ZIP eindeutig auf den geprüften Quell-Commit zurückführbar; finale Prüfsummen protokolliert.
- [ ] Falls für dieses Release vorgesehen und freigeschaltet: SignPath-Herkunft, manuelle Signierfreigabe, gültige Signatur und Produktmetadaten geprüft.
- [ ] Neues Verhalten erst als Pre-Release bereitstellen. Stable erst nach ausdrücklicher Freigabe.
- [ ] Release-Text enthält einen Link auf die [Code signing policy](CODE_SIGNING_POLICY.md) und den Hinweis, ob die Dateien tatsächlich signiert sind.

## Noch nicht umgesetzt

- Automatisches Selbstupdate des Updaters mit Signaturprüfung und Rollback.
- Produktive SignPath-Anbindung, solange die Bewerbung und die technische Eignung des SFX-Installers offen sind.
- Technisch erzwungene Branch-/Release-Regeln in den Repository-Einstellungen; diese müssen zusätzlich eingerichtet und geprüft werden.

Ein bestandener Test beweist nur den tatsächlich getesteten Umfang. Ein erfolgreicher Paketbau ersetzt keinen Installationstest auf der Zielplattform.
