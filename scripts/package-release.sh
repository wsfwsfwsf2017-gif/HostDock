#!/bin/bash
set -euo pipefail
task_root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$task_root"
if [ "$#" -ne 1 ]; then printf '用法：%s vX.Y.Z\n' "$0" >&2; exit 64; fi
task_tag="$1"
task_version="$(python3 scripts/release.py version --tag "$task_tag" --require-commit)"
task_output="$task_root/dist/releases/$task_version"
if [ -e "$task_output" ]; then printf '安装包目录已存在，拒绝覆盖：%s\n' "$task_output" >&2; exit 1; fi
./scripts/build-app.sh
task_stage="$(mktemp -d "$task_root/dist/.release.XXXXXX")"
trap 'rm -rf -- "$task_stage"' EXIT
mkdir -p "$task_stage/dmg" "$task_stage/packages" "$task_root/dist/releases"
ditto dist/HostDock.app "$task_stage/dmg/HostDock.app"
ln -s /Applications "$task_stage/dmg/Applications"
task_name="HostDock-$task_version-arm64"
hdiutil create -volname "HostDock $task_version" -srcfolder "$task_stage/dmg" -format UDZO "$task_stage/packages/$task_name.dmg"
ditto -c -k --sequesterRsrc --keepParent dist/HostDock.app "$task_stage/packages/$task_name.zip"
(
    cd "$task_stage/packages"
    shasum -a 256 "$task_name.dmg" "$task_name.zip" > SHA256SUMS.txt
)
python3 scripts/release.py verify-packages "$task_stage/packages" --tag "$task_tag"
python3 - "$task_stage/packages/release-notes.md" <<'PY'
import importlib.util, pathlib, sys
spec=importlib.util.spec_from_file_location('release', 'scripts/release.py')
release=importlib.util.module_from_spec(spec); spec.loader.exec_module(release)
data=release.metadata(); version=data['CFBundleShortVersionString']
body=pathlib.Path('CHANGELOG.md').read_text().split(f'## [{version}]',1)[1].split('\n',1)[1].split('\n## ',1)[0].strip()
assert body, '缺少版本更新记录'
body += f'\n\n版本 {version}，构建 {data["CFBundleVersion"]}。最低构建目标 macOS 14，适用于 Apple Silicon。macOS 14 实机及其他 Mac 尚未验收。\n\n'
body += '下载 DMG 后将 HostDock 拖入 Applications，或解压 ZIP 后安装。SHA256SUMS.txt 可用于核对两个安装包。\n\n'
body += '本版本采用本地临时签名，未经 Developer ID 签名及 Apple 公证。确认来源和 SHA-256 后，如系统阻止打开，可在「系统设置 → 隐私与安全性」中选择「仍要打开」。请勿关闭系统安全保护。\n\n'
body += '标准 SSH exec 可能被部分 JumpServer 网关拒绝或改写，此时返回明确错误，交互终端仍可使用。\n'
body += '\nHostDock 采用 MIT 许可证，第三方许可原文随 App 分发。This product includes software developed by Niels Provos.\n'
pathlib.Path(sys.argv[1]).write_text(body)
PY
mv "$task_stage/packages" "$task_output"
printf '已生成并验证：%s\n' "$task_output"
