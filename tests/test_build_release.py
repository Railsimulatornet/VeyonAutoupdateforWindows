"""Regression checks for the signed manifest boundary and deterministic ZIP format."""
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile

SPEC = importlib.util.spec_from_file_location('build_release',
    Path(__file__).resolve().parents[1] / 'scripts/build_release.py')
BUILD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BUILD)


class ReleaseContractTests(unittest.TestCase):
    def setUp(self):
        config = dict(BUILD.CONFIG, version='1.5.0', tag='1.5.0',
                      update_archive='VeyonUpdater_v1.5.0_Update.zip')
        self.config_patch = patch.object(BUILD, 'CONFIG', config)
        self.config_patch.start()
        self.addCleanup(self.config_patch.stop)

    def files(self):
        files = {BUILD.UPDATE_FILES[0]: b'# first\r\n', BUILD.UPDATE_FILES[1]: b'# second\r\n'}
        files['BUILDINFO.json'] = json.dumps({'version': '1.5.0', 'source_commit': 'a' * 40,
            'sha256': {name: BUILD.digest(data) for name, data in files.items()}}).encode()
        return files

    def test_versions_reject_ambiguous_or_unsupported_forms(self):
        for value in ('1.5', 'v1.5.0', '01.5.0', '1.05.0', '1.5.00', '1.5.0-rc1',
                      '1.5.0\n', '65536.0.0', '-1.0.0', '1.0.0.0', 15):
            with self.subTest(value=value), self.assertRaises(ValueError):
                BUILD.validate_version(value)
        self.assertEqual(BUILD.validate_version('65535.0.1'), '65535.0.1')

    def test_manifest_exact_bytes_and_file_order(self):
        files = self.files()
        archive = b'update ZIP bytes'
        actual = BUILD.update_manifest(files, archive)
        expected = ('VEYON-UPDATER-MANIFEST-1\nproduct=VeyonUpdater\n'
            'repository=Railsimulatornet/VeyonAutoupdateforWindows\nchannel=stable\n'
            'version=1.5.0\ntag=1.5.0\nsource=' + 'a' * 40 + '\nbootstrap=1\n'
            'payload=VeyonUpdater_v1.5.0_Update.zip\nlength=16\nsha256=' + BUILD.digest(archive) + '\n'
            'file=Veyon-AutoUpdate.ps1|9|' + BUILD.digest(files[BUILD.UPDATE_FILES[0]]) + '\n'
            'file=Veyon-SelfUpdate.ps1|10|' + BUILD.digest(files[BUILD.UPDATE_FILES[1]]) + '\n').encode('ascii')
        self.assertEqual(actual, expected)
        self.assertNotIn(b'\r', actual)
        self.assertLessEqual(len(actual), BUILD.MAX_MANIFEST)

    def test_manifest_rejects_mismatched_buildinfo(self):
        files = self.files()
        files[BUILD.UPDATE_FILES[0]] += b'changed'
        with self.assertRaisesRegex(ValueError, 'BUILDINFO'):
            BUILD.update_manifest(files, b'zip')

    def test_manifest_rejects_oversize_empty_and_wrong_asset_filename(self):
        files = self.files()
        for data in (b'', b'x' * (BUILD.MAX_UPDATE + 1)):
            with self.assertRaises(ValueError):
                BUILD.update_manifest(files, data)
        config = dict(BUILD.CONFIG, update_archive='different.zip')
        with patch.object(BUILD, 'CONFIG', config), self.assertRaises(ValueError):
            BUILD.update_manifest(files, b'zip')

    def test_zip_has_only_expected_regular_entries_and_is_reproducible(self):
        files = {name: self.files()[name] for name in BUILD.UPDATE_FILES}
        with tempfile.TemporaryDirectory() as temporary:
            one, two = Path(temporary) / 'a.zip', Path(temporary) / 'b.zip'
            BUILD.write_zip(one, files)
            BUILD.write_zip(two, dict(reversed(list(files.items()))))
            self.assertEqual(one.read_bytes(), two.read_bytes())
            with zipfile.ZipFile(io.BytesIO(one.read_bytes())) as archive:
                self.assertEqual(archive.namelist(), list(BUILD.UPDATE_FILES))
                for entry in archive.infolist():
                    self.assertEqual(entry.create_system, 3)
                    self.assertEqual(entry.external_attr >> 16, 0o100644)
                    self.assertEqual(archive.read(entry), files[entry.filename])

    def test_canonical_preserves_certificate_bytes(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(BUILD, 'ROOT', Path(temporary)):
            certificate = b'\x30\x82\xff\r\n\x80\x00'
            (Path(temporary) / 'public.cer').write_bytes(certificate)
            (Path(temporary) / 'test.ps1').write_bytes(b'\xef\xbb\xbfline\nnext\r\n')
            self.assertEqual(BUILD.canonical('public.cer'), certificate)
            self.assertEqual(BUILD.canonical('test.ps1'), b'\xef\xbb\xbfline\r\nnext\r\n')


if __name__ == '__main__':
    unittest.main()
