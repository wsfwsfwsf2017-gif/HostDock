#!/usr/bin/env python3
"""Version, signed bundle and downloaded-package checks shared by local/CI releases."""
import argparse
import hashlib
import json
import plistlib
import re
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def require(condition, message):
    if not condition:
        raise ValueError(message)


def run(*args):
    return subprocess.check_output([str(a) for a in args], stderr=subprocess.STDOUT, text=True).strip()


def metadata(path=None):
    with (path or ROOT / 'packaging/Info.plist').open('rb') as f:
        data = plistlib.load(f)
    version = data['CFBundleShortVersionString']
    build = data['CFBundleVersion']
    require(isinstance(version, str) and re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', version), '版本必须为 X.Y.Z')
    require(isinstance(build, str) and re.fullmatch(r'[1-9][0-9]*', build), '构建号必须为正整数')
    require(data['LSMinimumSystemVersion'] == '14.0', '最低系统版本必须为 14.0')
    return data


def validate_tag(tag, data, commit=False):
    require(tag == 'v' + data['CFBundleShortVersionString'], '标签与 Info.plist 版本不一致')
    if commit:
        require(not run('git', '-C', ROOT, 'status', '--porcelain'), '源码未提交，拒绝正式打包')
        head = run('git', '-C', ROOT, 'rev-parse', 'HEAD')
        require(run('git', '-C', ROOT, 'rev-parse', f'refs/tags/{tag}^{{commit}}') == head, '标签未指向当前提交')
        run('git', '-C', ROOT, 'merge-base', '--is-ancestor', head, 'origin/main')


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda: f.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def resource_hashes(app):
    root = app / 'Contents/Resources'
    result = {}
    for p in sorted(root.rglob('*')):
        require(not p.is_symlink(), '资源不应包含符号链接：' + str(p))
        if p.is_file() and p.name != 'ResourceManifest.json':
            result[p.relative_to(root).as_posix()] = digest(p)
    return result


def write_manifest(app):
    (app / 'Contents/Resources/ResourceManifest.json').write_text(
        json.dumps(resource_hashes(app), indent=2, ensure_ascii=False) + '\n', encoding='utf8')


def verify_app(app, data):
    require(app.is_dir() and not app.is_symlink(), '应用目录不存在或为符号链接')
    actual = metadata(app / 'Contents/Info.plist')
    for key in ('CFBundleIdentifier', 'CFBundleExecutable', 'CFBundleShortVersionString', 'CFBundleVersion', 'LSMinimumSystemVersion'):
        require(actual[key] == data[key], '应用元数据不一致：' + key)
    require(actual['CFBundleIdentifier'] == 'app.hostdock.mac', '应用标识不正确')
    resources = app / 'Contents/Resources'
    icon = resources / actual['CFBundleIconFile']
    require(icon.is_file() and icon.stat().st_size > 1024, '图标缺失或无效')
    require(run('sips', '-g', 'format', icon).endswith('format: icns'), '图标格式不正确')
    for source, target in [('LICENSE', 'LICENSE.txt'), ('THIRD_PARTY_NOTICES.md', 'THIRD_PARTY_NOTICES.md')]:
        require((resources / target).is_file() and digest(ROOT / source) == digest(resources / target), '许可声明缺失或不一致：' + source)
    require((resources / 'Licenses/README.md').is_file(), '缺少第三方许可索引')
    pins = json.loads((ROOT / 'Package.resolved').read_text())['pins']
    for pin in pins:
        folder = resources / 'Licenses' / pin['identity']
        require(folder.is_dir() and any(p.is_file() for p in folder.rglob('*')), '缺少依赖许可：' + pin['identity'])
    for patch in ('Citadel-LSTAT.patch', 'Citadel-Exec.patch', 'Citadel-macOS14.patch'):
        require(digest(ROOT / 'packaging' / patch) == digest(resources / 'Licenses/citadel' / ('HostDock-' + patch.removeprefix('Citadel-'))), '缺少依赖修改声明')
    require('Niels Provos' in (resources / 'Licenses/citadel/Embedded-C-Licenses.txt').read_text(), '缺少内嵌 bcrypt 版权与许可')
    require(any(resources.glob('*.bundle')), '缺少 SwiftPM 资源包')
    manifest = json.loads((resources / 'ResourceManifest.json').read_text())
    require(manifest == resource_hashes(app), '资源缺失或校验不一致')
    binaries = [app / 'Contents/MacOS/HostDock', app / 'Contents/Helpers/hostdock']
    binaries += list(app.rglob('*.dylib'))
    for binary in binaries:
        require(binary.is_file() and binary.stat().st_mode & 0o111, '可执行文件缺失或权限错误')
        require(run('lipo', '-archs', binary) == 'arm64', '包含非 ARM64 可执行文件')
        load = run('otool', '-l', binary)
        target = re.search(r'\bminos\s+(\d+)\.(\d+)', load) or re.search(r'LC_VERSION_MIN_MACOSX\s+cmdsize\s+\d+\s+version\s+(\d+)\.(\d+)', load)
        require(target and tuple(map(int, target.groups())) <= (14, 0), '二进制最低系统版本高于 macOS 14')
        run('codesign', '--verify', '--strict', binary)
    run('codesign', '--verify', '--deep', '--strict', app)
    require('Signature=adhoc' in run('codesign', '-d', '--verbose=4', app), '签名方式与当前临时签名发布约定不一致')
    require('HostDock' in run(app / 'Contents/Helpers/hostdock', '--help'), 'CLI 帮助无法运行')
    return digest(app / 'Contents/MacOS/HostDock'), digest(app / 'Contents/Helpers/hostdock'), digest(resources / 'ResourceManifest.json')


def verify_checksums(folder, version):
    names = [f'HostDock-{version}-arm64.{ext}' for ext in ('dmg', 'zip')]
    lines = (folder / 'SHA256SUMS.txt').read_text().splitlines()
    require(len(lines) == 2, '校验清单必须恰好包含 DMG 和 ZIP')
    seen = set()
    for line in lines:
        match = re.fullmatch(r'([0-9a-f]{64})  (HostDock-[0-9.]+-arm64\.(?:dmg|zip))', line)
        require(match is not None, '校验清单格式不正确')
        checksum, name = match.groups()
        require(name in names and name not in seen, '校验清单文件名重复或不匹配')
        require(digest(folder / name) == checksum, 'SHA-256 不一致：' + name)
        seen.add(name)


def verify_packages(folder, data):
    version = data['CFBundleShortVersionString']
    verify_checksums(folder, version)
    name = f'HostDock-{version}-arm64'
    with zipfile.ZipFile(folder / (name + '.zip')) as z:
        require(z.testzip() is None, 'ZIP 校验失败')
        for entry in z.infolist():
            path = Path(entry.filename)
            require(not path.is_absolute() and '..' not in path.parts and path.parts[0] in ('HostDock.app', '__MACOSX'), 'ZIP 包含非法路径')
    with tempfile.TemporaryDirectory(prefix='hostdock-verify-') as temporary:
        root = Path(temporary)
        run('ditto', '-x', '-k', folder / (name + '.zip'), root / 'zip')
        zipped = verify_app(root / 'zip/HostDock.app', data)
        run('hdiutil', 'verify', folder / (name + '.dmg'))
        mount = root / 'mount'; mount.mkdir()
        attached = False
        try:
            run('hdiutil', 'attach', '-readonly', '-nobrowse', '-noautoopen', '-mountpoint', mount, folder / (name + '.dmg'))
            attached = True
            require((mount / 'Applications').is_symlink() and (mount / 'Applications').readlink() == Path('/Applications'), 'DMG 缺少 Applications 快捷方式')
            require(verify_app(mount / 'HostDock.app', data) == zipped, 'DMG 与 ZIP 中的应用不一致')
        finally:
            if attached:
                run('hdiutil', 'detach', mount)
    print(f'安装包、版本 {version}、构建 {data["CFBundleVersion"]}、ARM64、签名、资源、许可及 SHA-256 检查通过')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    version = commands.add_parser('version')
    version.add_argument('--tag'); version.add_argument('--require-commit', action='store_true')
    for name in ('manifest', 'verify-app', 'verify-packages'):
        command = commands.add_parser(name); command.add_argument('path', type=Path)
        command.add_argument('--tag')
    args = parser.parse_args()
    data = metadata()
    if args.tag:
        validate_tag(args.tag, data, getattr(args, 'require_commit', False))
    if args.command == 'version': print(data['CFBundleShortVersionString'])
    elif args.command == 'manifest': write_manifest(args.path)
    elif args.command == 'verify-app': verify_app(args.path, data); print('App 完整性检查通过')
    else: verify_packages(args.path, data)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError, json.JSONDecodeError, plistlib.InvalidFileException, zipfile.BadZipFile, subprocess.CalledProcessError) as error:
        print('发布检查失败：' + str(error), file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError): print(error.output, file=sys.stderr)
        sys.exit(1)
