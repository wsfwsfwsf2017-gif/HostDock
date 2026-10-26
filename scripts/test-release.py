#!/usr/bin/env python3
import importlib.util
import plistlib
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('release', Path(__file__).with_name('release.py'))
release = importlib.util.module_from_spec(spec); spec.loader.exec_module(release)


class ReleaseChecks(unittest.TestCase):
    def test_version_and_build_are_validated(self):
        data = release.metadata()
        release.validate_tag('v' + data['CFBundleShortVersionString'], data)
        for tag in ('v0.0.0', 'latest', 'v1.0.0-extra'):
            with self.assertRaises(ValueError): release.validate_tag(tag, data)
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'Info.plist'
            for field, value in [('CFBundleVersion', '0'), ('CFBundleShortVersionString', '01.0.0'), ('LSMinimumSystemVersion', '15.0')]:
                broken = dict(data); broken[field] = value
                path.write_bytes(plistlib.dumps(broken))
                with self.assertRaises(ValueError): release.metadata(path)

    def test_dirty_or_wrong_commit_refuses_packaging(self):
        data = release.metadata(); tag = 'v' + data['CFBundleShortVersionString']
        with patch.object(release, 'run', return_value=' M file'):
            with self.assertRaises(ValueError): release.validate_tag(tag, data, True)
        with patch.object(release, 'run', side_effect=['', 'current', 'other']):
            with self.assertRaises(ValueError): release.validate_tag(tag, data, True)

    def test_missing_or_changed_resources_are_detected(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = Path(tmp); resources = app / 'Contents/Resources'; resources.mkdir(parents=True)
            icon = resources / 'HostDock.icns'; icon.write_bytes(b'icon')
            release.write_manifest(app)
            original = release.resource_hashes(app)
            icon.write_bytes(b'changed'); self.assertNotEqual(original, release.resource_hashes(app))
            icon.unlink(); self.assertNotEqual(original, release.resource_hashes(app))
            (resources / 'outside').symlink_to('/tmp')
            with self.assertRaises(ValueError): release.resource_hashes(app)

    def test_checksum_damage_duplicates_and_wrong_versions_are_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp); version = '1.2.3'
            names = [f'HostDock-{version}-arm64.{ext}' for ext in ('dmg', 'zip')]
            for name in names: (folder / name).write_bytes(name.encode())
            good = ''.join(f'{release.digest(folder / name)}  {name}\n' for name in names)
            checksum = folder / 'SHA256SUMS.txt'; checksum.write_text(good)
            release.verify_checksums(folder, version)
            for value in (good.splitlines()[0] + '\n' + good.splitlines()[0] + '\n', good.replace('1.2.3', '1.2.4'), good.replace(good[:64], '0' * 64)):
                checksum.write_text(value)
                with self.assertRaises(ValueError): release.verify_checksums(folder, version)
            checksum.write_text(good); (folder / names[1]).write_bytes(b'damaged zip')
            with self.assertRaises(ValueError): release.verify_checksums(folder, version)

    def test_zip_damage_and_path_escape_are_rejected_before_mounting(self):
        data = release.metadata(); version = data['CFBundleShortVersionString']
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp); base = 'HostDock-' + version + '-arm64'
            dmg = folder / (base + '.dmg'); dmg.write_bytes(b'fixture')
            zipped = folder / (base + '.zip')
            for invalid in (False, True):
                if invalid: zipped.write_bytes(b'broken archive')
                else:
                    with zipfile.ZipFile(zipped, 'w') as z: z.writestr('../escape', 'fixture')
                (folder / 'SHA256SUMS.txt').write_text(''.join(f'{release.digest(p)}  {p.name}\n' for p in (dmg, zipped)))
                with self.assertRaises((ValueError, zipfile.BadZipFile)):
                    release.verify_packages(folder, data)


if __name__ == '__main__': unittest.main()
