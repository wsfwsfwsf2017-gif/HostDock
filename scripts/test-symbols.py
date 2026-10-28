#!/usr/bin/env python3
import importlib.util
import json
import pathlib
import plistlib
import subprocess
import tempfile
import unittest
import zipfile
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('symbols', ROOT / 'scripts/archive-symbols.py')
symbols = importlib.util.module_from_spec(spec); spec.loader.exec_module(symbols)


class SymbolChecks(unittest.TestCase):
    def test_real_symbols_uuid_archive_and_mismatch(self):
        with tempfile.TemporaryDirectory(suffix='.noindex') as temp:
            root = pathlib.Path(temp)
            source = root / 'main.swift'; source.write_text('print("HostDock symbol fixture")\n')
            obj = root / 'main.o'
            subprocess.run(['xcrun', 'swiftc', '-gline-tables-only', '-debug-prefix-map', f'{root}=/Fixture',
                            '-debug-prefix-map', f'{pathlib.Path.home()}=/BuildUser', '-c', source, '-o', obj], check=True)
            for name in ['HostDock', 'HostDockCLI']:
                subprocess.run(['xcrun', 'swiftc', '-gline-tables-only', obj, '-o', root / name], check=True)
            info = root / 'Info.plist'
            info.write_bytes(plistlib.dumps({'CFBundleShortVersionString': '1.2.3', 'CFBundleVersion': '9'}))
            resources, output = root / 'Resources', root / 'Symbols'
            archive = symbols.archive(root, resources, output, info)
            build = json.loads((resources / 'BuildInfo.json').read_bytes())
            self.assertEqual(build['mainUUID'], symbols.binary_uuid(root / 'HostDock'))
            self.assertIn('HostDock-1.2.3-build9-', archive.name)
            with zipfile.ZipFile(archive) as zipped:
                self.assertIsNone(zipped.testzip())
                self.assertIn('HostDock.dSYM/Contents/Resources/DWARF/HostDock', zipped.namelist())
                self.assertIn('SHA256.json', zipped.namelist())
                for name in zipped.namelist():
                    if '/DWARF/' in name:
                        self.assertNotIn(str(pathlib.Path.home()).encode(), zipped.read(name))
            old = archive.read_bytes()
            self.assertEqual(symbols.archive(root, resources, output, info), archive)
            self.assertEqual(old, archive.read_bytes())
            with patch.object(symbols, 'binary_uuid', side_effect=['11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222']):
                with self.assertRaisesRegex(ValueError, '不匹配'): symbols.validate(root / 'HostDock', root / 'HostDock.dSYM')
            with patch.object(symbols, 'run', return_value='UUID: 11111111-1111-1111-1111-111111111111 (x86_64)'):
                with self.assertRaisesRegex(ValueError, 'arm64'): symbols.binary_uuid(root / 'HostDock')


if __name__ == '__main__': unittest.main()
