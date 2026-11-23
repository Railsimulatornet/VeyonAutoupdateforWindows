# Code signing policy

## Umfang

Selbstupdates werden über ein getrennt signiertes Release-Manifest freigegeben. Verwendet werden RSA-3072, SHA-256 und RSA-PSS. Das Manifest bindet Produkt, Repository, stabilen Kanal, Version, Quellcommit sowie Namen, Größen und Prüfsummen der beiden Laufzeitskripte.

Der öffentliche Schlüssel ist Teil der vertrauenswürdigen Erstinstallation. SHA-256 des zugehörigen DER-Zertifikats:

```text
7B698F2726348060CDDF8B10A5A82D39ED907062265EDF2E926DD9D6C5A72B7D
```

Diese Manifest-Signatur ist keine Windows-Authenticode-Signatur. Setup-EXE und PowerShell-Dateien erhalten dadurch keinen von Windows bestätigten Herausgeber. Eine SHA-256-Prüfsumme erkennt abweichende Bytes, bestätigt für sich allein aber keine Herkunft. Die erste Installation und ein Austausch des Startprogramms, Sicherheitskerns oder Schlüssels erfordern deshalb einen vertrauenswürdigen manuellen Installationsweg.

## Freigabe

[Railsimulatornet](https://github.com/Railsimulatornet) pflegt das Projekt und genehmigt die Signierung. Release-Pakete werden aus einem festgelegten Commit gebaut und automatisch geprüft. Vor einer Veröffentlichung gehören auch ein praktischer Windows-Installationstest und die ausdrückliche Freigabe des Projektbetreuers dazu.

Das lokale Signierwerkzeug prüft Manifest, Prüfsummen, Paketgleichheit und den unveränderten Quellstand, bevor es nach dem PFX-Passwort fragt. Der private Schlüssel bleibt beim Projektbetreuer. Er wird weder im Repository noch auf den aktualisierten Geräten oder in automatisierten Builds benötigt. Das Werkzeug erstellt eine Signatur und veröffentlicht keine Dateien.

## Grenzen und Schlüsselwechsel

Nur neuere stabile Laufzeitversionen werden automatisch angenommen. Fehlerhafte Pakete werden verworfen. Der höchste bereits akzeptierte Versionsstand bleibt auch bei einem Rückfall auf eine bekannte vorherige Version gespeichert.

Die Zertifikatslaufzeit begrenzt die Annahme neuer Updates. Ein Ablauf beendet nicht den Betrieb der bereits installierten Version. Ein Schlüsselwechsel oder eine Wiederherstellung nach Schlüsselverlust erfordert eine vertrauenswürdige manuelle Neuinstallation. Es gibt keinen unabhängigen Online-Sperrdienst. Ein kompromittierter privater Schlüssel kann gültige Releases signieren; ein kompromittiertes Betriebssystem oder Administratorkonto liegt außerhalb dieses Schutzes.

Ein Angreifer oder eine Störung kann die Bereitstellung neuer Releases verhindern. Das Manifest hat keine regelmäßig zu erneuernde Ablaufzeit und erkennt ein dauerhaft zurückgehaltenes neueres Release nicht zuverlässig. Eine gültige Signatur belegt die Freigabe der geprüften Bytes, nicht deren Fehlerfreiheit.

## English

Runtime updates use a detached RSA-3072/PSS SHA-256 manifest signature and a public key pinned during trusted installation. This is not Authenticode and does not provide a Windows-verified publisher for the setup executable or scripts. Checksums alone do not authenticate an initial download.

The maintainer signs tested artifacts locally after checking the exact source commit. Private keys are not used on client devices or in automated builds. Publishing requires a separate approval. The launcher, security core and trust key are maintained through manual installation. Certificate expiry blocks new update acceptance, not execution of an already installed version. There is no independent revocation service or guarantee that a newer release cannot be withheld.

[Privacy policy](PRIVACY.md) · [Security](SECURITY.md)
