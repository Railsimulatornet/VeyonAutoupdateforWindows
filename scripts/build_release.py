"""Build reproducible setup and update packages; never sign or publish a release."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
CONFIG = json.loads((ROOT / 'release.json').read_text(encoding='utf-8'))
SOURCE_COMMIT = None
LAUNCH_CHECK = False
UPDATE_FILES = ('Veyon-AutoUpdate.ps1', 'Veyon-SelfUpdate.ps1')
PUBLIC_CERT_SHA256 = '7b698f2726348060cddf8b10a5a82d39ed907062265edf2e926dd9d6c5a72b7d'
MAX_SCRIPT = 1024 * 1024
MAX_UPDATE = 4 * 1024 * 1024
MAX_MANIFEST = 4096
BINARY_SUFFIXES = {'.cer', '.pdf', '.sfx', '.png', '.jpg', '.jpeg', '.ico'}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def validate_version(version):
    if not isinstance(version, str) or not re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', version):
        raise ValueError('The release version must use MAJOR.MINOR.PATCH without leading zeros')
    if any(int(part) > 65535 for part in version.split('.')):
        raise ValueError('Each version component must be at most 65535')
    return version


def canonical(name):
    data = (ROOT / name).read_bytes()
    if Path(name).suffix.lower() not in BINARY_SUFFIXES:
        data.decode('utf-8-sig')
        data = data.replace(b'\r\n', b'\n')
        if Path(name).suffix.lower() in ('.cmd', '.ps1'):
            data = data.replace(b'\n', b'\r\n')
    return data


def source_commit():
    commit = SOURCE_COMMIT or subprocess.check_output(
        ['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    if not re.fullmatch(r'[0-9a-f]{40}', commit):
        raise ValueError('A complete lower-case source commit SHA is required')
    return commit


def payload():
    version = validate_version(CONFIG['version'])
    if CONFIG['tag'] != version or CONFIG['bootstrap_version'] != 1:
        raise ValueError('Unexpected release tag or bootstrap version')
    for name, marker in CONFIG['version_markers'].items():
        if marker.format(version=version) not in (ROOT / name).read_text(encoding='utf-8-sig'):
            raise ValueError('Version mismatch: ' + name)
    names = CONFIG['files']
    if len({name.casefold() for name in names}) != len(names):
        raise ValueError('Duplicate package file')
    if any(not re.fullmatch(r'[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*', name) or
           any(part in ('.', '..') for part in name.split('/')) or
           name.lower().endswith(('.pfx', '.p12', '.key')) for name in names):
        raise ValueError('Invalid package path')
    files = {name: canonical(name) for name in names}
    if digest(files['VeyonUpdater-release-public.cer']) != PUBLIC_CERT_SHA256:
        raise ValueError('Public release certificate does not match the pinned certificate')
    for name in UPDATE_FILES:
        if not 0 < len(files[name]) <= MAX_SCRIPT:
            raise ValueError('Update script exceeds its size limit: ' + name)
    info = {'version': version, 'source_commit': source_commit(),
            'sha256': {name: digest(data) for name, data in sorted(files.items())}}
    files['BUILDINFO.json'] = (json.dumps(info, indent=2, sort_keys=True) + '\n').encode('utf-8')
    return files


def seven_zip():
    tool = os.environ.get('SEVEN_ZIP') or shutil.which('7z')
    if not tool and os.name == 'nt':
        candidate = Path(os.environ.get('ProgramFiles', 'C:/Program Files')) / '7-Zip/7z.exe'
        if candidate.is_file():
            tool = str(candidate)
    if not tool:
        raise RuntimeError('7-Zip is required to build and verify the setup')
    return tool


def write_zip(path, files):
    with zipfile.ZipFile(path, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name, data in sorted(files.items()):
            entry = zipfile.ZipInfo(name, (2026, 1, 1, 0, 0, 0))
            entry.compress_type = zipfile.ZIP_DEFLATED
            entry.create_system = 3
            entry.external_attr = 0o100644 << 16
            archive.writestr(entry, data)
    with zipfile.ZipFile(path) as archive:
        if archive.testzip() is not None or sorted(archive.namelist()) != sorted(files):
            raise ValueError('Invalid or incomplete ZIP')
        if any(archive.read(name) != data for name, data in files.items()):
            raise ValueError('ZIP content mismatch')


def build_setup(output, files):
    output.mkdir(parents=True, exist_ok=True)
    setup = output / CONFIG['setup']
    stub = (ROOT / 'packaging/7zSD.sfx').read_bytes()
    if digest(stub) != CONFIG['sfx_sha256']:
        raise ValueError('SFX module checksum mismatch')
    if len(stub) < 64:
        raise ValueError('Invalid SFX executable')
    pe = struct.unpack_from('<I', stub, 0x3c)[0]
    if stub[:2] != b'MZ' or stub[pe:pe + 4] != b'PE\x00\x00':
        raise ValueError('Invalid SFX executable')
    with tempfile.TemporaryDirectory(prefix='veyon-package-') as temporary:
        directory = Path(temporary)
        for name, data in files.items():
            target = directory / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
        compressed = directory / 'payload.7z'
        subprocess.run([seven_zip(), 'a', '-t7z', '-mx=9', '-mtc=off', '-mta=off', '-mtm=off',
                        str(compressed), *sorted(files)], cwd=directory, check=True,
                       stdout=subprocess.DEVNULL)
        config = (';!@Install@!UTF-8!\nTitle="Veyon Updater v' + CONFIG['version'] +
                  '"\nBeginPrompt="Veyon Updater installieren?"\n'
                  'Progress="no"\nDirectory=""\nRunProgram="cmd.exe /d /c Install-Veyon-AutoUpdate.cmd"\n'
                  ';!@InstallEnd@!\n').encode('utf-8')
        setup.write_bytes(stub + config + compressed.read_bytes())
        extracted = directory / 'verify'
        subprocess.run([seven_zip(), 'x', '-y', '-o' + str(extracted), str(setup.resolve())],
                       check=True, stdout=subprocess.DEVNULL)
        actual = {p.relative_to(extracted).as_posix(): p.read_bytes()
                  for p in extracted.rglob('*') if p.is_file()}
        if actual != files:
            raise ValueError('Setup payload does not match ZIP/source payload')
    return setup


def update_manifest(files, update_bytes):
    version = validate_version(CONFIG['version'])
    info = json.loads(files['BUILDINFO.json'].decode('utf-8'))
    commit = info['source_commit']
    if not re.fullmatch(r'[0-9a-f]{40}', commit) or info['version'] != version:
        raise ValueError('Invalid build provenance')
    if not 0 < len(update_bytes) <= MAX_UPDATE:
        raise ValueError('Update ZIP exceeds its size limit')
    expected_name = 'VeyonUpdater_v' + version + '_Update.zip'
    if CONFIG['update_archive'] != expected_name or CONFIG['tag'] != version:
        raise ValueError('Unexpected update asset name or release tag')
    lines = ['VEYON-UPDATER-MANIFEST-1', 'product=VeyonUpdater',
             'repository=Railsimulatornet/VeyonAutoupdateforWindows', 'channel=stable',
             'version=' + version, 'tag=' + version, 'source=' + commit, 'bootstrap=1',
             'payload=' + expected_name, 'length=' + str(len(update_bytes)),
             'sha256=' + digest(update_bytes)]
    for name in UPDATE_FILES:
        data = files[name]
        if not 0 < len(data) <= MAX_SCRIPT:
            raise ValueError('Update script exceeds its size limit: ' + name)
        if info['sha256'].get(name) != digest(data):
            raise ValueError('Update script does not match BUILDINFO: ' + name)
        lines.append('file=' + name + '|' + str(len(data)) + '|' + digest(data))
    result = ('\n'.join(lines) + '\n').encode('ascii')
    if len(result) > MAX_MANIFEST:
        raise ValueError('Release manifest exceeds its size limit')
    return result


def build(output, files):
    output.mkdir(parents=True, exist_ok=True)
    archive = output / CONFIG['archive']
    write_zip(archive, files)
    setup = build_setup(output, files)
    update = output / CONFIG['update_archive']
    write_zip(update, {name: files[name] for name in UPDATE_FILES})
    manifest = output / CONFIG['manifest']
    manifest.write_bytes(update_manifest(files, update.read_bytes()))
    assets = [archive, setup, update, manifest]
    (output / 'SHA256SUMS').write_bytes(''.join(
        digest(path.read_bytes()) + '  ' + path.name + '\n' for path in assets).encode('ascii'))
    return assets


def check(files):
    with tempfile.TemporaryDirectory(prefix='release-check-') as temporary:
        directory = Path(temporary)
        first = build(directory / 'first', files)
        second = build(directory / 'second', files)
        if [p.read_bytes() for p in first] != [p.read_bytes() for p in second]:
            raise ValueError('Package build is not reproducible')
        if (directory / 'first/SHA256SUMS').read_bytes() != (directory / 'second/SHA256SUMS').read_bytes():
            raise ValueError('Package checksum records are not reproducible')
        extracted = directory / 'source'
        for name, data in files.items():
            target = extracted / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
        if os.name == 'nt':
            env = dict(os.environ)
            for variable, name in CONFIG['test_sources'].items():
                env[variable] = str(extracted / name)
            powershell = str(Path(os.environ['SystemRoot']) /
                             'System32/WindowsPowerShell/v1.0/powershell.exe')
            for name, arguments in (('test_update.ps1', []), ('test_parser.ps1', [str(extracted)]),
                                    ('test_installer.ps1', [str(extracted)])):
                subprocess.run([powershell, '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                                '-File', str(ROOT / 'tests' / name), *arguments], cwd=ROOT, env=env, check=True)
            print('Packaged Windows PowerShell regression tests: OK')
        else:
            print('Windows execution checks require Windows; package checks are available on this host.')
        if LAUNCH_CHECK:
            if os.name != 'nt':
                raise RuntimeError('Setup launch check requires Windows')
            marker = directory / 'bootstrap-marker.txt'
            synthetic = {'Install-Veyon-AutoUpdate.cmd':
                         b'@echo off\r\n> "%SFX_TEST_MARKER%" echo %CD%\r\nexit /b 0\r\n'}
            probe = build_setup(directory / 'bootstrap', synthetic)
            env = dict(os.environ, SFX_TEST_MARKER=str(marker))
            subprocess.run([str(probe), '-y'], env=env, check=True, timeout=30,
                           creationflags=subprocess.CREATE_NO_WINDOW)
            if not marker.is_file():
                raise ValueError('SFX did not run the synthetic bootstrap')
            if Path(marker.read_text().strip()).exists():
                raise ValueError('SFX left its temporary extraction directory behind')
            print('SFX bootstrap launch and extraction cleanup: OK')
    print('Package versions, contents, checksums and reproducibility: OK')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path)
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--source-commit', help='Source SHA when building a verified exported source tree')
    parser.add_argument('--check-setup-launch', action='store_true',
                        help='Windows: exercise the SFX with a harmless installer stand-in')
    args = parser.parse_args()
    SOURCE_COMMIT = args.source_commit
    LAUNCH_CHECK = args.check_setup_launch
    release_files = payload()
    if args.check:
        check(release_files)
    if args.output:
        build(args.output.resolve(), release_files)
    if not args.check and not args.output:
        parser.error('Use --check and/or --output DIRECTORY')
