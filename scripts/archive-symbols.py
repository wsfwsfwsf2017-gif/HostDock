#!/usr/bin/env python3
"""Archive symbols for the exact binaries being packaged; never ship dSYMs inside the App."""
import argparse
import hashlib
import json
import os
import pathlib
import plistlib
import re
import subprocess
import tempfile
import zipfile


def run(*args):
    return subprocess.check_output([str(a) for a in args], stderr=subprocess.STDOUT, text=True)


def binary_uuid(path):
    values = re.findall(r'UUID: ([0-9A-Fa-f-]{36}) \(([^)]+)\)', run('xcrun', 'dwarfdump', '--uuid', path))
    if len(values) != 1 or values[0][1] != 'arm64':
        raise ValueError('符号或程序必须仅包含 arm64 架构')
    return values[0][0].upper()


def validate(binary, symbols):
    identity = binary_uuid(binary)
    if binary_uuid(symbols) != identity:
        raise ValueError('调试符号 UUID 与程序不匹配')
    verification = run('xcrun', 'dwarfdump', '--verify', symbols)
    if 'Verifying unit:' not in verification or 'No errors.' not in verification:
        raise ValueError('调试符号缺失编译单元或校验失败')
    return identity


def archive(bin_directory, resources, output, info):
    metadata = plistlib.loads(info.read_bytes())
    version, build = metadata['CFBundleShortVersionString'], metadata['CFBundleVersion']
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.symbols-', suffix='.noindex', dir=output) as temporary:
        stage = pathlib.Path(temporary)
        identities = {}
        for name, key in [('HostDock', 'mainUUID'), ('HostDockCLI', 'cliUUID')]:
            binary, symbols = bin_directory / name, stage / (name + '.dSYM')
            run('xcrun', 'dsymutil', binary, '-o', symbols)
            identities[key] = validate(binary, symbols)
        (stage / 'BuildInfo.json').write_text(json.dumps(identities, indent=2) + '\n')
        files = {str(p.relative_to(stage)): p.read_bytes() for p in stage.rglob('*') if p.is_file()}
        checksum = {name: hashlib.sha256(data).hexdigest() for name, data in files.items()}
        files['SHA256.json'] = (json.dumps(checksum, sort_keys=True, indent=2) + '\n').encode()
        destination = output / f'HostDock-{version}-build{build}-{identities["mainUUID"]}.zip'
        if destination.exists():
            with zipfile.ZipFile(destination) as existing:
                if set(existing.namelist()) != set(files) or any(existing.read(k) != v for k, v in files.items()):
                    raise ValueError('同名符号归档内容不同，拒绝覆盖')
        else:
            pending = stage / 'symbols.zip'
            with zipfile.ZipFile(pending, 'w', zipfile.ZIP_DEFLATED) as zipped:
                for name, data in sorted(files.items()):
                    item = zipfile.ZipInfo(name)
                    item.external_attr = 0o100600 << 16
                    item.compress_type = zipfile.ZIP_DEFLATED
                    zipped.writestr(item, data)
            os.chmod(pending, 0o600)
            with zipfile.ZipFile(pending) as zipped:
                if zipped.testzip() is not None or any(zipped.read(k) != v for k, v in files.items()):
                    raise ValueError('符号归档校验失败')
            os.link(pending, destination)
        resources.mkdir(parents=True, exist_ok=True)
        (resources / 'BuildInfo.json').write_bytes(files['BuildInfo.json'])
        print('已归档并校验调试符号：' + destination.name)
        return destination


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('bin', type=pathlib.Path)
    parser.add_argument('resources', type=pathlib.Path)
    parser.add_argument('--output', type=pathlib.Path, default=pathlib.Path('dist/Symbols'))
    parser.add_argument('--info', type=pathlib.Path, default=pathlib.Path('packaging/Info.plist'))
    args = parser.parse_args()
    archive(args.bin, args.resources, args.output, args.info)
