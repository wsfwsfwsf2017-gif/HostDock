#!/bin/bash
set -euo pipefail
task_root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$task_root"
swift package resolve --force-resolved-versions
python3 scripts/prepare-dependencies.py
task_tools="$(dirname "$(xcrun --find swiftc)")"
task_flags=()
if [ -d "$task_tools/../lib/swift/host/plugins/testing" ]; then
    task_flags=(-Xswiftc -plugin-path -Xswiftc "$task_tools/../lib/swift/host/plugins/testing")
fi
swift test "${task_flags[@]}"
python3 scripts/test-release.py
python3 scripts/test-symbols.py
