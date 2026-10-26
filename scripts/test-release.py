#!/usr/bin/env python3
import importlib.util
import json
import plistlib
import stat
import struct
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('release', Path(__file__).with_name('release.py'))
release = importlib.util.module_from_spec(spec); spec.loader.exec_module(release)


class ReleaseChecks(unittest.TestCase):
    def test_icon_master_is_editable_and_build_preserves_approved_png(self):
        root = Path(__file__).resolve().parent.parent
        master = root / 'packaging/Icon/HostDock.png'
        png = master.read_bytes()
        self.assertEqual(png[:8], b'\x89PNG\r\n\x1a\n')
        self.assertEqual(struct.unpack('>II', png[16:24]), (1024, 1024))
        self.assertEqual(png[25], 6)  # PNG RGBA，透明边缘不能变成不透明底板。
        document = json.loads((root / 'packaging/Icon/HostDock.photon/document.json').read_text())
        self.assertEqual([len(layer['shape']['path']['subPaths'][0]['points']) for layer in document['layers']], [8, 12, 12])
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / 'icon.png'
            subprocess.run(['swift', str(root / 'scripts/create-icon.swift'), str(output)], cwd=tmp, check=True)
            self.assertEqual(output.read_bytes(), png)

    def fixture_app(self, root, name='HostDock.app'):
        app = root / name
        (app / 'Contents/MacOS').mkdir(parents=True)
        (app / 'Contents/Empty').mkdir()
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'app.hostdock.mac'}))
        binary = app / 'Contents/MacOS/HostDock'
        binary.write_bytes(b'fixture\x00\xff'); binary.chmod(0o755)
        (app / 'Contents/中文.txt').write_text('归档内容\n')
        return app

    def test_archive_round_trip_preserves_files_modes_and_empty_directories(self):
        with tempfile.TemporaryDirectory(suffix='.noindex') as tmp:
            root = Path(tmp); app = self.fixture_app(root); archive = root / 'app.zip'
            release.archive_app(app, archive)
            self.assertTrue(app.is_dir())
            self.assertEqual(stat.S_IMODE(archive.stat().st_mode), 0o600)
            restored = root / 'restored'; release.extract_app(archive, restored)
            actual = restored / app.name
            self.assertEqual((actual / 'Contents/中文.txt').read_bytes(), (app / 'Contents/中文.txt').read_bytes())
            self.assertEqual((actual / 'Contents/MacOS/HostDock').read_bytes(), (app / 'Contents/MacOS/HostDock').read_bytes())
            self.assertEqual(stat.S_IMODE((actual / 'Contents/MacOS/HostDock').stat().st_mode), 0o755)
            self.assertTrue((actual / 'Contents/Empty').is_dir())
            with self.assertRaises(ValueError): release.archive_app(app, archive)
            with self.assertRaises(ValueError): release.archive_app(app, app / 'inside.zip')
            with self.assertRaises(ValueError): release.extract_app(archive, restored)

    def test_old_bundle_is_unregistered_and_removed_after_verified_archive(self):
        with tempfile.TemporaryDirectory(suffix='.noindex') as tmp:
            root = Path(tmp); app = self.fixture_app(root, 'HostDock-old.app-backup'); archive = root / 'old.zip'
            actual_run = release.run
            def run(*args):
                return '' if str(args[0]).endswith('/lsregister') else actual_run(*args)
            with patch.object(release, 'run', side_effect=run) as calls:
                release.archive_app(app, archive, remove_source=True)
            self.assertFalse(app.exists()); self.assertTrue(archive.is_file())
            self.assertTrue(any(call.args[1:] == ('-u', app) for call in calls.call_args_list))
            with zipfile.ZipFile(archive) as z: self.assertIsNone(z.testzip())

    def test_archive_failure_keeps_source_and_does_not_publish_partial_zip(self):
        with tempfile.TemporaryDirectory(suffix='.noindex') as tmp:
            root = Path(tmp); app = self.fixture_app(root); archive = root / 'app.zip'
            with patch.object(release, 'digest', return_value='wrong digest'):
                with self.assertRaises(ValueError): release.archive_app(app, archive, remove_source=True)
            self.assertTrue((app / 'Contents/MacOS/HostDock').is_file())
            self.assertFalse(archive.exists())
            self.assertFalse(list(root.glob('.archive-*')))

    def test_extract_rejects_links_duplicates_and_path_escape(self):
        with tempfile.TemporaryDirectory(suffix='.noindex') as tmp:
            root = Path(tmp); archive = root / 'bad.zip'; destination = root / 'unpacked'
            for name in ('../escape', '/absolute', 'HostDock.app/../escape', 'HostDock.app/Contents/Info.plist', 'HostDock.app/link'):
                with zipfile.ZipFile(archive, 'w') as z:
                    z.writestr('HostDock.app/Contents/Info.plist', b'fixture')
                    entry = zipfile.ZipInfo(name)
                    if name.endswith('/link'):
                        entry.create_system = 3; entry.external_attr = (stat.S_IFLNK | 0o777) << 16
                    if name == 'HostDock.app/Contents/Info.plist':
                        with self.assertWarns(UserWarning): z.writestr(entry, b'/outside')
                    else: z.writestr(entry, b'/outside')
                with self.assertRaises(ValueError): release.extract_app(archive, destination)
                self.assertFalse(destination.exists())

    def test_extract_failure_cleans_temporary_app_and_keeps_archive(self):
        with tempfile.TemporaryDirectory(suffix='.noindex') as tmp:
            root = Path(tmp); app = self.fixture_app(root); archive = root / 'app.zip'
            release.archive_app(app, archive)
            destination = root / 'unpacked'
            def fail(*args):
                (destination / 'HostDock.app').mkdir()
                raise subprocess.CalledProcessError(1, args)
            with patch.object(release, 'run', side_effect=fail):
                with self.assertRaises(subprocess.CalledProcessError): release.extract_app(archive, destination)
            self.assertFalse(destination.exists()); self.assertTrue(archive.is_file())

    def test_unregister_accepts_missing_application_but_preserves_other_errors(self):
        for status in (-10814, -54):
            error = subprocess.CalledProcessError(1, ['lsregister'], output=f'failed to scan temporary.app: {status}\n from spotlight\n')
            with patch.object(release, 'run', side_effect=error):
                if status == -10814: release.unregister_app(Path('temporary.app'))
                else:
                    with self.assertRaises(subprocess.CalledProcessError): release.unregister_app(Path('temporary.app'))

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
