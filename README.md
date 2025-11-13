# Veyon Auto-Update (WinGet) – Start bei Systemstart

Automatisiert Updates von **Veyon** über **WinGet** beim **Systemstart** – leise, robust und mit Sicherung der bestehenden Konfiguration. Ideal für Eltern-/Schülergeräte, wo Standardkonten ohne Adminrechte genutzt werden.

> **Hinweis:** Dieses Repository liefert ein fertig gepacktes ZIP für den Rollout. Es ändert keine Veyon-Einstellungen, übernimmt aber vorhandene Konfigurationen.

---

## Features

- **Update nur bei echter neuer Version**  
  Ermittelt die Online-Version über `winget show` und vergleicht sie numerisch mit der lokal installierten Version. Nur wenn *Online > Lokal*, wird ein Upgrade ausgeführt.

- **Sauberes Upgrade (silent)**
  - Nutzt `winget upgrade VeyonSolutions.Veyon` mit `--silent`, `--disable-interactivity` und Lizenz-Flags.  
  - Wenn **kein Veyon Master** installiert war, wird er **nicht** nachinstalliert: das Skript hängt **`/NoMaster`** über `--custom` an (Silent-Argumente aus dem Manifest bleiben erhalten).

- **Konfig-Backup nur bei Update**  
  Vor dem Upgrade wird **genau ein** Backup erstellt (Primär: `veyon-cli config export` JSON; Fallback: Registry-Export).  
  **Rotation:** Es bleiben automatisch die **letzten 3** Backups.

- **Start bei Systemstart (SYSTEM)**  
  Geplante Aufgabe **ONSTART** mit **2 Minuten Verzögerung**, Ausführung als **SYSTEM**.

- **Deutsches Log + Auto-Trimming**  
  Log: `C:\ProgramData\Veyon\Update\veyon_autoupdate.log` (deutsches Datumsformat). Ab ~1 MB werden ältere Einträge abgeschnitten, der letzte Lauf bleibt erhalten.

- **Idempotent & unbeaufsichtigt**  
  Bei „bereits aktuell“: **kein** Backup, **kein** Upgrade, **keine** UI.

---

## Systemvoraussetzungen

- Windows 10/11 mit **App Installer / WinGet** (Bestandteil von Windows; über den Store/Updates registriert).
- Veyon 4.x/4.9.x (Master optional). Der Windows-Installer von Veyon unterstützt **Silent-Install** (`/S`) und Komponenten-Schalter (z. B. `/NoMaster`).

---

## Installation (Kurz)

1. ZIP aus den Releases herunterladen und **entpacken**.  
2. **Als Administrator** `Install-Veyon-AutoUpdate.cmd` starten.  
   - Kopiert die Dateien nach `C:\ProgramData\Veyon\Update\`  
   - Legt eine geplante Aufgabe an (SYSTEM, ONSTART, Delay 2 min).  
3. Fertig – beim nächsten Boot prüft das Skript die Online-Version und aktualisiert *nur wenn nötig*.

### Deinstallation
`Remove-Veyon-AutoUpdate.cmd` als Administrator ausführen (Aufgabe + Dateien werden gelöscht).

---

## Wie es intern funktioniert

1. **WinGet-Quellen pflegen**: `winget source update` (bei Problemen automatisch `source reset --force` und erneut `update`).  
2. **Online-Version ermitteln**: `winget show VeyonSolutions.Veyon -e` – Parsen der Zeile `Version: ...`.  
3. **Entscheidung**: Nur wenn *Online > Lokal* →  
   a) **Konfig-Backup**,  
   b) `winget upgrade --id VeyonSolutions.Veyon -e --silent --disable-interactivity --accept-source-agreements --accept-package-agreements --log <Pfad>`  
   c) Falls vorher **kein Master** installiert war: `--custom "/NoMaster"` anhängen (Silent-Switches aus dem Manifest bleiben erhalten).  
4. **Logging** inkl. Exitcodes; **Backup-Rotation (3)**; **Log-Trimming** ab 1 MB.

---

## FAQ

**Was, wenn während des Upgrades der PC ausgeschaltet wird?**  
Beim nächsten Systemstart läuft die Prüfung erneut. Ist die Version noch alt, wird das Upgrade wieder ausgelöst. Mehrfache Aufrufe sind unkritisch.

**Warum `--custom "/NoMaster"` und nicht `--override`?**  
`--override` **ersetzt** die Standard-Installerargumente des Manifests (Silent-Switch kann verloren gehen). `--custom` **ergänzt** zusätzliche Argumente – der Silent-Modus bleibt erhalten.

---

## Haftungsausschluss

Benutzung auf eigene Verantwortung. Bitte vorherige Backups/Images vorhalten. Keine Garantie, keine Gewährleistung.

---

## Copyright

Copyright © Roman Glos, 11.11.2025.  
Siehe **TERMS.md** für Nutzungsbedingungen.
