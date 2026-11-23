# Release packages

`release.json` defines the version, packaged files and artifact names. `BUILDINFO.json` records the source commit and canonical SHA-256 of every packaged source file. PowerShell and CMD files use CRLF; the public DER certificate is copied without text conversion.

## Build and checks

Build from the selected commit with Python 3 and 7-Zip installed:

```powershell
python scripts/build_release.py --check --check-setup-launch --output dist
```

The Windows checks compare repeated builds, verify ZIP and SFX contents, parse packaged scripts with Windows PowerShell and run packaged-source regressions. CI additionally tests the security boundary, Windows runtime helpers and installation. The `parse` and `windows-11-installation` checks remain required. A practical test on the intended Windows hardware is part of release approval.

The build produces:

| File | Purpose |
|---|---|
| `VeyonUpdater_v1.5.0.zip` | Complete manual installation package |
| `VeyonUpdater_v1.5.0_Setup.exe` | SFX containing the same installation files |
| `VeyonUpdater_v1.5.0_Update.zip` | The two versioned runtime scripts only |
| `VeyonUpdater-release.manifest` | Exact ASCII/LF metadata for signing |
| `SHA256SUMS` | SHA-256 of those four artifacts |

The build never creates a production signature or publishes a release.

## Local signing

Use the tested artifact set and an unchanged Git checkout of its exact source commit. Keep the private PFX outside the repository. Windows, Git and 7-Zip are required. Validate the artifacts before signing:

```powershell
.\scripts\Sign-VeyonRelease.ps1 -AssetDirectory .\dist -SourceCommit <tested-40-character-commit> -ValidateOnly
```

Repeat without `-ValidateOnly` after the Windows tests and release approval. The tool checks the source checkout, all package hashes, setup contents, update payload and public certificate before asking for local confirmation and the PFX password. Its default key location is `%LOCALAPPDATA%\VeyonReleaseSigning\VeyonUpdater-release-private.pfx`; use `-PfxPath` to select another protected location. `-SevenZip` accepts an explicit absolute path to `7z.exe`.

The PFX is loaded ephemerally. The tool signs the original manifest bytes with RSA-3072/PSS SHA-256, verifies the resulting signature and creates `VeyonUpdater-release.manifest.sig` without overwriting an existing file. It does not store the password or publish anything. The signature is created after `SHA256SUMS`; the checksum file continues to describe the four build artifacts.

A stable release must contain the tested build artifacts and the corresponding signature under the exact manifest tag. Prereleases are not accepted by production clients. Initial installation and updates to the launcher, security core or public key remain manual. See the [signing policy](../CODE_SIGNING_POLICY.md).

## SFX module

Unmodified `bin/7zSD.sfx` from the official [LZMA SDK 26.05](https://github.com/ip7z/7zip/releases/download/26.05/lzma2605.7z).

- SDK archive SHA-256: `668fda469b7f584f246008cf28359c66ef98d65fafb3b22a52672eebe6970c28`
- SFX SHA-256: `3a335e4338ebb8a8cff7b81aaa35decc148845e2ce144bfaf680b09cd647cb8c`

Igor Pavlov places the SDK in the public domain. Its original notice is included in [LZMA-SDK.txt](LZMA-SDK.txt), and the matching source is in the linked SDK archive. The module's component version is independent of the updater version.
