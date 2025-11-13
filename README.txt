Veyon Auto-Update (Start bei Systemstart) – Anleitung
====================================================
Copyright Roman Glos 12.11.2025 V1.0

Was macht dieses Scriptpaket?
--------------
Dieses Paket richtet eine automatische, lautlose Aktualisierung von Veyon ein.
Die bestehende Konfiguration bleibt unverändert.

Ablauf
------
- Die Aktualisierung startet bei jedem Systemstart, mit ca. 2 Minuten Verzögerung.
- Die Ausführung erfolgt als SYSTEM (keine Benutzerrechte nötig).

Inhalt
------
- Install-Veyon-AutoUpdate.cmd  -> richtet alles ein (fragt automatisch Adminrechte an)
- Veyon-AutoUpdate.ps1          -> führt das Update aus (liegt danach in C:\ProgramData\Veyon\Update)
- Remove-Veyon-AutoUpdate.cmd   -> entfernt alles wieder
- README.txt                    -> diese Anleitung

Nutzung (für Eltern)
---------------------
1) ZIP-Datei entpacken.
2) Install-Veyon-AutoUpdate.cmd doppelklicken -> Administratorabfrage bestätigen.
3) Warten, bis "FERTIG" angezeigt wird.

Protokoll
---------
- Log: C:\ProgramData\Veyon\Update\veyon_autoupdate.log
- Falls winget fehlt, versucht das Skript eine Reparatur des "App Installer".
  Gelingt das nicht, bitte "App Installer" aus dem Microsoft Store installieren/aktualisieren.

Entfernen
---------
- Remove-Veyon-AutoUpdate.cmd doppelklicken -> Administratorabfrage bestätigen.

Wichtig
---------
- Dieses Scriptpaket nicht von einem Netzwerkpfad ausführen Beispiel: \\Server\Daten \\192.168.178.10