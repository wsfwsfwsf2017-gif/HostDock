#!/usr/bin/env python3
"""Apply the small, reviewed SSH/SFTP patches to the pinned Citadel checkout."""
import json
import stat
from pathlib import Path

root = Path(__file__).resolve().parent.parent
pins = json.loads((root / 'Package.resolved').read_text())['pins']
citadel = next(pin for pin in pins if pin['identity'] == 'citadel')
if citadel['state'].get('version') != '0.12.1':
    raise SystemExit('Citadel 版本变化，请先审查 LSTAT 补丁，未修改依赖。')
source = root / '.build/checkouts/Citadel/Sources/Citadel/SFTP/Client/SFTPClient.swift'
before = '''        at filePath: String
    ) async throws -> SFTPFileAttributes {
        self.logger.info("SFTP requesting file attributes at '\\(filePath)'")
        
        let response = try await sendRequest(.stat(.init(
            requestId: allocateRequestId(),
            path: filePath
        )))
        
        guard case .attributes(let attributes) = response else {'''
after = '''        at filePath: String, followSymlinks: Bool = true
    ) async throws -> SFTPFileAttributes {
        self.logger.info("SFTP requesting file attributes at '\\(filePath)'")
        let request: SFTPRequest = followSymlinks
            ? .stat(.init(requestId: allocateRequestId(), path: filePath))
            : .lstat(.init(requestId: allocateRequestId(), path: filePath))
        let response = try await sendRequest(request)
        if case .status(let status) = response { throw SFTPError.errorStatus(status) }
        guard case .attributes(let attributes) = response else {'''
text = source.read_text()
if after in text:
    print('Citadel LSTAT 补丁已就绪')
elif text.count(before) == 1:
    mode = source.stat().st_mode
    try:
        source.chmod(mode | stat.S_IWUSR)
        source.write_text(text.replace(before, after))
    finally:
        source.chmod(mode)
    print('已为 Citadel 0.12.1 应用 LSTAT 补丁')
else:
    raise SystemExit('Citadel 源码与补丁基线不符，未修改依赖。')

message = source.parents[1] / 'SFTPMessage.swift'
text = message.read_text()
request, response = text.split('enum SFTPResponse:', 1)
if 'case lstat(SFTPMessage.LStat)' not in request:
    replacements = [
        ('    case stat(SFTPMessage.Stat)', '    case stat(SFTPMessage.Stat)\n    case lstat(SFTPMessage.LStat)'),
        ('            case .stat(let message):\n                return message.requestId',
         '            case .lstat(let message):\n                return message.requestId\n            case .stat(let message):\n                return message.requestId'),
        ('        case .stat(let message):\n            return .stat(message)',
         '        case .lstat(let message):\n            return .lstat(message)\n        case .stat(let message):\n            return .stat(message)'),
        ('        case .stat(let message): return message.debugDescription',
         '        case .lstat(let message): return message.debugDescription\n        case .stat(let message): return message.debugDescription'),
    ]
    for before, after in replacements:
        if request.count(before) != 1:
            raise SystemExit('Citadel 请求封装与补丁基线不符，未修改请求文件。')
        request = request.replace(before, after)
    mode = message.stat().st_mode
    try:
        message.chmod(mode | stat.S_IWUSR)
        message.write_text(request + 'enum SFTPResponse:' + response)
    finally:
        message.chmod(mode)
    print('已为 Citadel 请求封装补齐 LSTAT')

# 命令通道缺少退出状态时，不能按成功退出处理；PTY/Shell 保持原行为。
tty = root / '.build/checkouts/Citadel/Sources/Citadel/TTY/Client/TTY.swift'
replacements = [
    ('    /// Executes a command on the remote server and returns its output as a single buffer',
     '    public struct CommandExitStatusUnavailable: Error {}\n\n    /// Executes a command on the remote server and returns its output as a single buffer'),
    ('                    streamContinuation.finish(throwing: CommandFailed(exitCode: exitCode))\n                } else {',
     '                    streamContinuation.finish(throwing: CommandFailed(exitCode: exitCode))\n                } else if case .command = mode, exitCode.withLockedValue({ $0 }) == nil {\n                    streamContinuation.finish(throwing: CommandExitStatusUnavailable())\n                } else {')
]
original = tty.read_text()
text = original
for before, after in replacements:
    if after in text:
        continue
    if text.count(before) != 1:
        raise SystemExit('Citadel 命令通道与补丁基线不符，未修改命令文件。')
    text = text.replace(before, after)
if text != original:
    mode = tty.stat().st_mode
    try:
        tty.chmod(mode | stat.S_IWUSR)
        tty.write_text(text)
    finally:
        tty.chmod(mode)
print('Citadel Exec 退出状态保护已就绪')

# 这些封装仅使用既有 AsyncThrowingStream/NIO；与 Citadel 自身的 macOS 14 下限保持一致。
text = tty.read_text()
old = '@available(macOS 15.0, *)'
new = '@available(macOS 14.0, *)'
if text.count(old) == 4:
    mode = tty.stat().st_mode
    try:
        tty.chmod(mode | stat.S_IWUSR)
        tty.write_text(text.replace(old, new))
    finally:
        tty.chmod(mode)
elif text.count(new) != 4 or old in text:
    raise SystemExit('Citadel TTY 可用性与已审查基线不符。')
print('Citadel TTY macOS 14 可用性补丁已就绪')
