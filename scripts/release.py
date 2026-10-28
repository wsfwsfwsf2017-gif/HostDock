#!/usr/bin/env python3
"""Version, signed bundle and downloaded-package checks shared by local/CI releases."""
import argparse
import hashlib
import json
import os
import plistlib
import re
import shutil
import stat
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


def zip_name(entry):
    # ditto 写入 UTF-8 文件名，但未设置 ZIP 的 UTF-8 标记。
    return entry.filename if entry.flag_bits & 0x800 else entry.filename.encode('cp437').decode('utf8')


def unregister_app(app):
    try:
        run('/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister', '-u', app)
    except subprocess.CalledProcessError as error:
        # 未注册的 .noindex 临时应用返回 kLSApplicationNotFoundErr。
        if error.returncode != 1 or not re.search(r': -10814(?:\n|$)', error.output or ''):
            raise


def check_zip(archive, root_name='HostDock.app', allow_symlinks=False):
    with zipfile.ZipFile(archive) as z:
        require(z.testzip() is None, 'ZIP 校验失败')
        names = set()
        for entry in z.infolist():
            name = zip_name(entry)
            path = Path(name)
            require(path.parts and not path.is_absolute() and '..' not in path.parts
                    and path.parts[0] in (root_name, '__MACOSX'), 'ZIP 包含非法路径')
            require(name not in names, 'ZIP 包含重复路径')
            names.add(name)
            require(allow_symlinks or not stat.S_ISLNK(entry.external_attr >> 16), '安装 ZIP 不应包含符号链接')
        require(root_name + '/Contents/Info.plist' in names, 'ZIP 缺少应用信息')


def archive_app(app, archive, remove_source=False):
    require(app.is_dir() and not app.is_symlink(), '待归档应用不存在或为符号链接')
    with (app / 'Contents/Info.plist').open('rb') as f:
        require(plistlib.load(f).get('CFBundleIdentifier') == 'app.hostdock.mac', '仅允许归档 HostDock 应用')
    require(not remove_source or app.resolve() != Path('/Applications/HostDock.app'), '不得清理正式安装位置')
    require(not archive.exists() and not archive.resolve().is_relative_to(app.resolve()), '归档目标已存在或位于应用内')
    archive.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.archive-', suffix='.noindex', dir=archive.parent) as temporary:
        zipped = Path(temporary) / 'app.zip'
        run('ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', app, zipped)
        check_zip(zipped, app.name, allow_symlinks=True)
        with zipfile.ZipFile(zipped) as z:
            entries = {zip_name(entry): entry for entry in z.infolist()}
            for path in app.rglob('*'):
                name = app.name + '/' + path.relative_to(app).as_posix()
                if path.is_symlink():
                    require(z.read(entries[name]) == os.fsencode(path.readlink()), '归档链接不一致：' + name)
                elif path.is_file():
                    h = hashlib.sha256()
                    with z.open(entries[name]) as f:
                        for block in iter(lambda: f.read(1024 * 1024), b''):
                            h.update(block)
                    require(h.hexdigest() == digest(path), '归档内容不一致：' + name)
                    require(stat.S_IMODE(entries[name].external_attr >> 16) == stat.S_IMODE(path.stat().st_mode), '归档权限不一致：' + name)
                elif path.is_dir():
                    require(name + '/' in entries, '归档缺少目录：' + name)
        zipped.chmod(0o600)
        os.link(zipped, archive)
    if remove_source:
        unregister_app(app)
        shutil.rmtree(app)


def extract_app(archive, directory):
    require(not directory.exists(), '解包目录已存在，拒绝覆盖')
    check_zip(archive)
    try:
        directory.mkdir(mode=0o700, parents=True)
        run('ditto', '-x', '-k', archive, directory)
    except Exception:
        shutil.rmtree(directory, ignore_errors=True)
        raise


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
    if int(actual['CFBundleVersion']) >= 28:
        build_info = json.loads((resources / 'BuildInfo.json').read_text())
        for key, binary in [('mainUUID', app / 'Contents/MacOS/HostDock'), ('cliUUID', app / 'Contents/Helpers/hostdock')]:
            match = re.search(r'UUID: ([0-9A-Fa-f-]{36}) \(arm64\)', run('xcrun', 'dwarfdump', '--uuid', binary))
            require(match and match[1].upper() == build_info.get(key), '构建信息与程序 UUID 不一致：' + key)
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
    check_zip(folder / (name + '.zip'))
    with tempfile.TemporaryDirectory(prefix='.hostdock-verify-', suffix='.noindex') as temporary:
        root = Path(temporary)
        extract_app(folder / (name + '.zip'), root / 'zip')
        mount = root / 'mount'; mount.mkdir()
        attached = False
        try:
            zipped = verify_app(root / 'zip/HostDock.app', data)
            run('hdiutil', 'verify', folder / (name + '.dmg'))
            run('hdiutil', 'attach', '-readonly', '-nobrowse', '-noautoopen', '-mountpoint', mount, folder / (name + '.dmg'))
            attached = True
            require((mount / 'Applications').is_symlink() and (mount / 'Applications').readlink() == Path('/Applications'), 'DMG 缺少 Applications 快捷方式')
            require(verify_app(mount / 'HostDock.app', data) == zipped, 'DMG 与 ZIP 中的应用不一致')
        finally:
            try:
                if attached:
                    try:
                        unregister_app(mount / 'HostDock.app')
                    finally:
                        run('hdiutil', 'detach', mount)
            finally:
                unregister_app(root / 'zip/HostDock.app')
    print(f'安装包、版本 {version}、构建 {data["CFBundleVersion"]}、ARM64、签名、资源、许可及 SHA-256 检查通过')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    version = commands.add_parser('version')
    version.add_argument('--tag'); version.add_argument('--require-commit', action='store_true')
    for name in ('manifest', 'verify-app', 'verify-packages'):
        command = commands.add_parser(name); command.add_argument('path', type=Path)
        command.add_argument('--tag')
    archive = commands.add_parser('archive-app')
    archive.add_argument('path', type=Path); archive.add_argument('archive', type=Path)
    archive.add_argument('--remove-source', action='store_true')
    extract = commands.add_parser('extract-app')
    extract.add_argument('path', type=Path); extract.add_argument('directory', type=Path)
    args = parser.parse_args()
    data = metadata()
    if getattr(args, 'tag', None):
        validate_tag(args.tag, data, getattr(args, 'require_commit', False))
    if args.command == 'version': print(data['CFBundleShortVersionString'])
    elif args.command == 'manifest': write_manifest(args.path)
    elif args.command == 'verify-app': verify_app(args.path, data); print('App 完整性检查通过')
    elif args.command == 'archive-app': archive_app(args.path, args.archive, args.remove_source)
    elif args.command == 'extract-app': extract_app(args.path, args.directory)
    else: verify_packages(args.path, data)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError, json.JSONDecodeError, plistlib.InvalidFileException, zipfile.BadZipFile, subprocess.CalledProcessError) as error:
        print('发布检查失败：' + str(error), file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError): print(error.output, file=sys.stderr)
        sys.exit(1)
