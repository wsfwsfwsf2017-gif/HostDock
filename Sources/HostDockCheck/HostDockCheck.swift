import CryptoKit
import Darwin
import Foundation
import HostDockCore

private actor Capture {
    var ready = false
    var ended = false
    var error: String?
    var data = Data()
    var skipped = 0
    func markReady() { ready = true }
    func append(_ bytes: Data) {
        data.append(bytes)
        if data.count > 128 * 1024 { data.removeFirst(data.count - 128 * 1024) }
    }
    func contains(_ text: String) -> Bool { String(decoding: data, as: UTF8.self).contains(text) }
    func end(_ error: String? = nil) { ended = true; self.error = error }
    func record(_ event: TransferEvent) { if case .skipped = event { skipped += 1 } }
}

@main
enum HostDockCheck {
    static func main() async {
        let args = CommandLine.arguments
        if args.count == 7, args[1] == "--key-probe", let port = Int(args[3]) {
            do {
                let connection = SSHConnection()
                let result = try await connection.connect(host: args[2], port: port, username: args[4],
                    authentication: .rsaKey(path: args[5], passphrase: nil), verifyHostKey: { $0.fingerprint == args[6] })
                print("PASS RSA 公钥认证、固定指纹、SFTP 初始化；home=\(result.home)")
                let entries = try await result.store.list(at: result.home)
                print("SFTP root entries=\(entries.map { $0.name + ":" + String(describing: $0.kind) })")
                if let folder = entries.first(where: { $0.kind == .directory }) {
                    print("SFTP asset entry=\(folder.path), children=\(try await result.store.list(at: folder.path).prefix(8).map(\.name))")
                }
                let terminal = Task {
                    try await connection.runTerminal(columns: 100, rows: 30, onReady: {
                        try? await connection.writeTerminal(Data("id -un; hostname; hostname -I; pwd\r".utf8))
                    }, onOutput: { FileHandle.standardOutput.write($0) })
                }
                try await Task.sleep(for: .seconds(4))
                await connection.disconnect()
                terminal.cancel()
            } catch { fputs("公钥检查失败：\(error.localizedDescription)\n", stderr); exit(1) }
            return
        }
        guard args.count == 4 else {
            fputs("用法：HostDockCheck <服务器> <用户名> <SSH SHA256 指纹，多个用逗号分隔>\n密码在终端隐藏输入，不接收密码参数。\n", stderr)
            exit(64)
        }
        guard isatty(STDIN_FILENO) == 1, let rawPassword = getpass("服务器密码（不回显）：") else {
            fputs("请在交互终端运行，以隐藏输入密码。\n", stderr)
            exit(64)
        }
        let password = String(cString: rawPassword)
        memset(rawPassword, 0, strlen(rawPassword))
        let fingerprints = Set(args[3].split(separator: ",").map(String.init))
        let connection = SSHConnection()
        let local = LocalFileStore()
        let localRoot = FileManager.default.temporaryDirectory.appendingPathComponent("hostdock-check-\(UUID().uuidString)")
        let remoteRoot = "/tmp/hostdock-check-\(UUID().uuidString)"
        var remote: RemoteFileStore?
        var remoteCreated = false
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(ProcessInfo.processInfo.environment["HOSTDOCK_UI_CHECK"] == "1" ? 600 : 180))
            if !Task.isCancelled {
                fputs("验收超时，测试目录可能保留，请检查上面列出的路径。\n", stderr)
                exit(1)
            }
        }
        defer { watchdog.cancel(); try? FileManager.default.removeItem(at: localRoot) }
        do {
            print("测试远端目录：\(remoteRoot)")
            try await expectFailure("拒绝未信任主机指纹") {
                _ = try await connection.connect(host: args[1], port: 22, username: args[2], password: password,
                                                 verifyHostKey: { _ in false })
            }
            let result = try await connection.connect(host: args[1], port: 22, username: args[2], password: password,
                verifyHostKey: { fingerprints.contains($0.fingerprint) })
            remote = result.store
            if let previous = ProcessInfo.processInfo.environment["HOSTDOCK_PREVIOUS_CHECK_ROOT"] {
                try await cleanup(result.store, root: previous)
                print("PASS 上次超时留下的独立测试目录已清理")
            }
            print("PASS SSH 密码登录、已固定主机指纹、SFTP 与用户主目录读取")
            let capture = Capture()
            let terminalTask = Task {
                do {
                    try await connection.runTerminal(columns: 80, rows: 24,
                        onReady: { await capture.markReady() }, onOutput: { await capture.append($0) })
                    await capture.end()
                } catch { await capture.end(String(reflecting: error)) }
            }
            try await waitUntil { await capture.ready }
            try await connection.writeTerminal(Data((printfMarker("HOSTDOCK_PTY") + "; stty size\r").utf8))
            try await waitUntil {
                let marker = await capture.contains("HOSTDOCK_PTY")
                let size = await capture.contains("24 80")
                return marker && size
            }
            try await connection.resizeTerminal(columns: 100, rows: 32)
            try await connection.writeTerminal(Data("stty size\r".utf8))
            try await waitUntil { await capture.contains("32 100") }
            try await connection.writeTerminal(Data((printfMarker("HOSTDOCK_SLEEP") + "; sleep 20\r").utf8))
            try await waitUntil { await capture.contains("HOSTDOCK_SLEEP") }
            try await connection.writeTerminal(Data([3]))
            try await Task.sleep(for: .milliseconds(250))
            try await connection.writeTerminal(Data((printfMarker("HOSTDOCK_INTERRUPT") + "\r").utf8))
            try await waitUntil { await capture.contains("HOSTDOCK_INTERRUPT") }
            print("PASS 交互式 PTY、尺寸同步、Ctrl+C")

            let source = localRoot.appendingPathComponent("样例 文件夹")
            let nested = source.appendingPathComponent("中文 空格")
            let downloaded = localRoot.appendingPathComponent("download")
            try FileManager.default.createDirectory(at: nested.appendingPathComponent("空目录"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: downloaded, withIntermediateDirectories: true)
            try Data((0..<2_000_000).map { UInt8($0 % 251) }).write(to: source.appendingPathComponent("binary.bin"))
            try Data().write(to: source.appendingPathComponent("zero.txt"))
            try Data("HOSTDOCK_TEST=1\n".utf8).write(to: source.appendingPathComponent(".env"))
            let unusual = nested.appendingPathComponent("quote ' $; 文件.txt")
            try Data("原始内容\n".utf8).write(to: unusual)
            try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("循环链接").path,
                                                       withDestinationPath: source.path)
            remoteCreated = true
            try await result.store.createDirectory(at: remoteRoot)
            let sourceEntry = try await local.metadata(at: source.path).unwrap("本地测试目录不存在")
            try await TransferEngine().transfer([sourceEntry], from: local, to: result.store, directory: remoteRoot,
                                               onEvent: { await capture.record($0) })
            let remoteFolder = try FilePath.join(remoteRoot, name: source.lastPathComponent)
            try require(await capture.skipped == 1, "符号链接未按预期跳过")
            let remoteEntry = try await result.store.metadata(at: remoteFolder).unwrap("上传目录不存在")
            try await TransferEngine().transfer([remoteEntry], from: result.store, to: local, directory: downloaded.path)
            try compareManifests(source, downloaded.appendingPathComponent(source.lastPathComponent))
            print("PASS 文件夹上传下载、2 MB 二进制文件 SHA-256、中文/空格/引号文件名、隐藏文件、零字节、空目录、跳过循环链接")

            try Data("覆盖后的新内容\n".utf8).write(to: unusual)
            let edited = try await local.metadata(at: unusual.path).unwrap("修改文件不存在")
            let remoteNested = try FilePath.join(remoteFolder, name: nested.lastPathComponent)
            try await TransferEngine().transfer([edited], from: local, to: result.store, directory: remoteNested,
                                               onConflict: { _ in .overwrite })
            try await TransferEngine().transfer([remoteEntry], from: result.store, to: local, directory: downloaded.path,
                                               onConflict: { _ in .overwrite })
            try compareManifests(source, downloaded.appendingPathComponent(source.lastPathComponent))
            try await TransferEngine().transfer([sourceEntry], from: local, to: result.store, directory: remoteRoot,
                                               onEvent: { await capture.record($0) })
            try require(await capture.skipped >= 6, "同名文件默认跳过未生效")
            try await expectFailure("SFTP 建目录失败不会误报成功") {
                try await result.store.createDirectory(at: remoteFolder + "/binary.bin")
            }
            print("PASS 目录合并、同名跳过、双向覆盖与旧文件备份清理")

            let cancelRoot = try FilePath.join(remoteRoot, name: "cancel")
            try await result.store.createDirectory(at: cancelRoot)
            let binary = try await local.metadata(at: source.appendingPathComponent("binary.bin").path).unwrap("二进制文件不存在")
            let cancelled = Task {
                try await TransferEngine().transfer([binary], from: local, to: result.store, directory: cancelRoot,
                    onEvent: { event in
                        if case .progress(_, let count, _) = event, count > 0 {
                            withUnsafeCurrentTask { $0?.cancel() }
                        }
                    })
            }
            try await expectFailure("取消传输返回失败状态") { try await cancelled.value }
            try require(try await result.store.list(at: cancelRoot).isEmpty, "取消后的临时文件未清理")
            try await connection.writeTerminal(Data((printfMarker("HOSTDOCK_STILL_ALIVE") + "\r").utf8))
            try await waitUntil { await capture.contains("HOSTDOCK_STILL_ALIVE") }
            print("PASS 取消清理；SFTP 传输期间终端会话保持可用")
            try await connection.writeTerminal(Data("exit\r".utf8))
            try await waitUntil { await capture.ended }
            await terminalTask.value
            let terminalError = await capture.error
            try require(terminalError == nil, "终端退出异常：\(terminalError ?? "")")
            if ProcessInfo.processInfo.environment["HOSTDOCK_UI_CHECK"] == "1" {
                watchdog.cancel()
                print("UI 本地目录：\(source.path)")
                print("UI 远端目录：\(remoteFolder)")
                print("完成界面验收后按回车，继续清理测试数据。")
                _ = readLine()
            }
            try await cleanup(result.store, root: remoteRoot)
            remoteCreated = false
            print("PASS 独立远端测试目录已清理")
            await connection.disconnect()
            try await expectFailure("断开后的 SFTP 请求明确失败") { _ = try await result.store.list(at: result.home) }
            _ = try await connection.connect(host: args[1], port: 22, username: args[2], password: password,
                verifyHostKey: { fingerprints.contains($0.fingerprint) })
            await connection.disconnect()
            print("PASS 断开与重新连接")
            print("全部服务器验收通过；未操作现有业务目录。")
        } catch {
            if remoteCreated, let remote {
                do { try await cleanup(remote, root: remoteRoot); print("失败后的测试目录已清理") }
                catch { fputs("测试目录未能清理，请检查：\(remoteRoot)\n", stderr) }
            }
            await connection.disconnect()
            try? FileManager.default.removeItem(at: localRoot)
            fputs("FAIL \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func printfMarker(_ text: String) -> String {
        "printf '" + text.utf8.map { String(format: "\\%03o", $0) }.joined() + "\\n'"
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw HostDockError(message) }
    }

    private static func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<100 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw HostDockError("终端验收等待超时")
    }

    private static func expectFailure(_ name: String, action: () async throws -> Void) async throws {
        var failed = false
        do { try await action() } catch { failed = true }
        try require(failed, "未拒绝应失败的操作：\(name)")
        print("PASS \(name)")
    }

    private static func manifest(_ root: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        func walk(_ directory: URL, prefix: String) throws {
            for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey]) {
                let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                if values.isSymbolicLink == true { continue }
                let relative = prefix + "/" + url.lastPathComponent
                if values.isDirectory == true { result[relative] = "directory"; try walk(url, prefix: relative) }
                else {
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    var digest = SHA256()
                    while let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty { digest.update(data: data) }
                    result[relative] = digest.finalize().map { String(format: "%02x", $0) }.joined()
                }
            }
        }
        try walk(root, prefix: "")
        return result
    }

    private static func compareManifests(_ source: URL, _ destination: URL) throws {
        let expected = try manifest(source)
        let actual = try manifest(destination)
        let differences = Set(expected.keys).union(actual.keys).filter { expected[$0] != actual[$0] }.sorted()
        for key in differences.prefix(10) {
            print("校验差异：\(key) · 源 \(expected[key] ?? "不存在") · 目标 \(actual[key] ?? "不存在")")
        }
        try require(differences.isEmpty, "往返 SHA-256 或目录结构不一致")
    }

    private static func cleanup(_ store: RemoteFileStore, root: String) async throws {
        let prefix = "/tmp/hostdock-check-"
        guard root.hasPrefix(prefix), UUID(uuidString: String(root.dropFirst(prefix.count))) != nil else {
            throw HostDockError("拒绝清理非测试目录")
        }
        if try await store.metadata(at: root) == nil { return }
        func remove(_ path: String) async throws {
            guard FilePath.isInside(path, directory: root) else { throw HostDockError("清理路径越界") }
            for entry in try await store.list(at: path) {
                if entry.kind == .directory { try await remove(entry.path) }
                else { try await store.removeFile(at: entry.path) }
            }
            try await store.removeEmptyDirectory(at: path)
        }
        try await remove(root)
    }
}

private extension Optional {
    func unwrap(_ message: String) throws -> Wrapped {
        guard let value = self else { throw HostDockError(message) }
        return value
    }
}
