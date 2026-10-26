#!/bin/bash
set -euo pipefail

if [ "$#" -ne 3 ] || [ ! -t 0 ]; then
    printf '用法：在交互终端运行 %s <服务器> <用户名> <已核对的SHA256指纹，多个用逗号分隔>\n密码随后隐藏输入。\n' "$0" >&2
    exit 64
fi
task_root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$task_root"
HOSTDOCK_DISK_RECONNECT=0 HOSTDOCK_APP_CHECK=0 ./scripts/test.sh
task_developer="$(xcode-select -p)"
task_tools="$(dirname "$(xcrun --find swiftc)")"
task_runtime="$task_developer/Library/Developer"
if [ -d "$task_developer/Platforms/MacOSX.platform/Developer/Library/Frameworks/Testing.framework" ]; then
    task_runtime="$task_developer/Platforms/MacOSX.platform/Developer/Library"
    task_frameworks="$task_runtime/Frameworks"
    task_libraries="$task_developer/Platforms/MacOSX.platform/Developer/usr/lib"
else
    task_frameworks="$task_runtime/Frameworks"
    task_libraries="$task_runtime/usr/lib"
fi
task_helper="$task_tools/../libexec/swift/pm/swiftpm-testing-helper"
if [ ! -d "$task_frameworks/Testing.framework" ] || [ ! -x "$task_helper" ]; then
    printf '未找到 Swift Testing 运行库或测试运行器。\n' >&2
    exit 1
fi
task_bin="$(swift build --show-bin-path)"
task_test="$task_bin/HostDockAppTests.xctest/Contents/MacOS/HostDockAppTests"
export HOSTDOCK_APP_CHECK=1 HOSTDOCK_CHECK_HOST="$1" HOSTDOCK_CHECK_USER="$2" HOSTDOCK_CHECK_FINGERPRINTS="$3"
export DYLD_FRAMEWORK_PATH="$task_frameworks${DYLD_FRAMEWORK_PATH:+:$DYLD_FRAMEWORK_PATH}"
export DYLD_LIBRARY_PATH="$task_libraries${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
task_reconnect_dir="$(mktemp -d "${TMPDIR:-/tmp}/hostdock-reconnect.XXXXXX")"
trap 'rm -rf -- "$task_reconnect_dir"' EXIT
export HOSTDOCK_RECONNECT_DIR="$task_reconnect_dir"
# SwiftPM launches test helpers in a background process group; getpass needs the foreground terminal.
"$task_helper" --test-bundle-path "$task_test" --filter liveApplicationConnectsTransfersAndKeepsTerminalSession "$task_test" --testing-library swift-testing
HOSTDOCK_APP_CHECK=0 HOSTDOCK_DISK_RECONNECT=1 "$task_helper" --test-bundle-path "$task_test" --filter encryptedPasswordReconnectsInNewProcess "$task_test" --testing-library swift-testing
