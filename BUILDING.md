# Release-Pakete / Release packages

Version, Dateiliste und Dateinamen stehen in `release.json`. Versionsangaben in den dort genannten Skripten und der README müssen dazu passen. Aktive Konfigurationen gehören nicht in das Paket.

Version, file list and asset names are defined in `release.json`. The listed script and README version markers must agree. Never package active configurations.

```text
python scripts/build_release.py --check
python scripts/build_release.py --output dist
```

Die Prüfung baut zweimal, vergleicht alle Paketdateien und führt die Regressionstests gegen die entpackten Skripte aus. `BUILDINFO.json` enthält Quell-Commit und Dateiprüfsummen; `SHA256SUMS` prüft die fertigen Downloads.

The check builds twice, compares every payload file and runs regressions against the extracted scripts. `BUILDINFO.json` records the source commit and file hashes; `SHA256SUMS` covers the completed downloads.

Veröffentlichen ist ein separater, manueller Schritt nach erfolgreicher Prüfung des endgültigen Commits. Keine bestehenden Tags oder Assets ersetzen. Ein Merge baut oder veröffentlicht kein produktives Deployment.

Publishing is a separate manual step after the final commit passes its checks. Do not replace existing tags or assets. A merge does not publish or deploy a production service.

## Setup-EXE

Windows und 7-Zip werden für den Setup-Bau benötigt. Das unveränderte SFX-Modul stammt aus dem offiziellen LZMA SDK 26.05; sein SHA-256-Wert ist fest hinterlegt. Herkunft und Lizenz stehen in `packaging/`. Der Build prüft die EXE durch Entpacken mit 7-Zip, ohne den Installer auszuführen. ZIP und EXE müssen exakt dieselben Nutzdateien enthalten.

Windows and 7-Zip are required for the setup build. The unchanged SFX module comes from the official LZMA SDK 26.05 and is checksum-pinned. Provenance and license are in `packaging/`. Verification extracts the EXE with 7-Zip without running the installer. ZIP and EXE must contain exactly the same payload files.
