#!/bin/bash
set -euo pipefail

task_root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$task_root"
test "$(uname -m)" = arm64
python3 scripts/release.py version
swift package resolve --force-resolved-versions
python3 scripts/prepare-dependencies.py
swift build -c release -Xswiftc -gline-tables-only \
    -Xswiftc -debug-prefix-map -Xswiftc "$task_root=/HostDock" \
    -Xswiftc -debug-prefix-map -Xswiftc "$HOME=/BuildUser"
task_bin="$(swift build -c release --show-bin-path)"
mkdir -p dist
task_stage="$(mktemp -d "$task_root/dist/.HostDock.XXXXXX")"
mv "$task_stage" "$task_stage.noindex"
task_stage="$task_stage.noindex"
task_app="$task_stage/HostDock.app"
trap '"/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister" -u "$task_app" >/dev/null 2>&1 || true; rm -R -- "$task_stage"' EXIT
mkdir -p "$task_app/Contents/MacOS" "$task_app/Contents/Helpers" "$task_app/Contents/Resources" "$task_stage/HostDock.iconset"
cp "$task_bin/HostDock" "$task_app/Contents/MacOS/HostDock"
cp "$task_bin/HostDockCLI" "$task_app/Contents/Helpers/hostdock"
codesign --force --sign - "$task_app/Contents/Helpers/hostdock"
cp packaging/Info.plist "$task_app/Contents/Info.plist"
python3 scripts/archive-symbols.py "$task_bin" "$task_app/Contents/Resources"
for task_bundle in "$task_bin"/*.bundle; do
    if [ -d "$task_bundle" ]; then ditto "$task_bundle" "$task_app/Contents/Resources/$(basename "$task_bundle")"; fi
done
swift scripts/create-icon.swift "$task_stage/icon.png"
for task_size in 16 32 128 256 512; do
    sips -z "$task_size" "$task_size" "$task_stage/icon.png" --out "$task_stage/HostDock.iconset/icon_${task_size}x${task_size}.png" >/dev/null
    task_double=$((task_size * 2))
    sips -z "$task_double" "$task_double" "$task_stage/icon.png" --out "$task_stage/HostDock.iconset/icon_${task_size}x${task_size}@2x.png" >/dev/null
done
iconutil -c icns "$task_stage/HostDock.iconset" -o "$task_app/Contents/Resources/HostDock.icns"
python3 scripts/collect-licenses.py "$task_app/Contents/Resources/Licenses"
cp LICENSE "$task_app/Contents/Resources/LICENSE.txt"
cp THIRD_PARTY_NOTICES.md "$task_app/Contents/Resources/THIRD_PARTY_NOTICES.md"
python3 scripts/release.py manifest "$task_app"
codesign --force --deep --sign - "$task_app"
python3 scripts/release.py verify-app "$task_app"
python3 scripts/release.py archive-app "$task_app" "$task_stage/HostDock-build.zip"
if [ -e dist/HostDock-build.zip ]; then
    mkdir -p dist/Backups
    task_backup="dist/Backups/HostDock-build-$(date +%Y%m%d-%H%M%S)-$(uuidgen).zip"
    mv dist/HostDock-build.zip "$task_backup"
fi
if ! mv "$task_stage/HostDock-build.zip" dist/HostDock-build.zip; then
    if [ -n "${task_backup:-}" ]; then mv "$task_backup" dist/HostDock-build.zip; fi
    exit 1
fi
printf '已生成并校验：%s/dist/HostDock-build.zip（不保留构建 App 副本）\n' "$task_root"
