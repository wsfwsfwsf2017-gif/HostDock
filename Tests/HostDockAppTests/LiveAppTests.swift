import AppKit
import CryptoKit
import Darwin
import Foundation
import HostDockCore
import Testing
@testable import HostDock

@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["HOSTDOCK_APP_CHECK"] == "1"))
func liveApplicationConnectsTransfersAndKeepsTerminalSession() async throws {
    let env = ProcessInfo.processInfo.environment
    let host = try #require(env["HOSTDOCK_CHECK_HOST"])
    let username = try #require(env["HOSTDOCK_CHECK_USER"])
    let pins = Set(try #require(env["HOSTDOCK_CHECK_FINGERPRINTS"]).split(separator: ",").map(String.init))
    // SwiftPM pipes stdin; getpass reads the controlling terminal directly.
    let tty = open("/dev/tty", O_RDWR | O_NOCTTY)
    try #require(tty >= 0, "此检查需要交互终端隐藏输入密码。")
    Darwin.close(tty)
    let raw = try #require(getpass("应用验收密码（不回显）："))
    let password = String(cString: raw)
    memset(raw, 0, strlen(raw))
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    let credentials = MemoryCredentialStore()
    let catalog = ConnectionCatalog(storage: MemoryConnectionStorage())
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("hostdock-app-check-\(UUID().uuidString)")
    let remoteRoot = "/tmp/hostdock-check-\(UUID().uuidString)"
    let fixtureProfile = ConnectionProfile(name: "应用验收", endpoint: ConnectionEndpoint(host: host, port: 22, username: username), localStartDirectory: root.path)
    let model = SessionModel(profile: fixtureProfile, catalog: catalog, credentials: credentials)
    let source = root.appendingPathComponent("样例 文件夹")
    let downloads = root.appendingPathComponent("downloads")
    let originalTrust = UserDefaults.standard.object(forKey: "trustedHostKeys")
    defer {
        try? FileManager.default.removeItem(at: root)
        if let originalTrust { UserDefaults.standard.set(originalTrust, forKey: "trustedHostKeys") }
        else { UserDefaults.standard.removeObject(forKey: "trustedHostKeys") }
    }
    var remote: RemoteFileStore?
    var remoteCreated = false
    do {
        try FileManager.default.createDirectory(at: source.appendingPathComponent("空目录"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: false)
        let payload = Data("HostDock 应用流程测试\n".utf8)
        try payload.write(to: source.appendingPathComponent("文件.txt"))
        var trust = UserDefaults.standard.dictionary(forKey: "trustedHostKeys") ?? [:]
        trust.removeValue(forKey: "[\(host.lowercased())]:22")
        UserDefaults.standard.set(trust, forKey: "trustedHostKeys")
        model.connect(profile: fixtureProfile, password: password, rememberPassword: false)
        try await eventually { model.hostTrustRequest != nil || model.connectionError != nil }
        let request = try #require(model.hostTrustRequest, "\(model.connectionError ?? "没有显示主机指纹")")
        try #require(pins.contains(request.challenge.fingerprint), "应用显示的服务器指纹不匹配。")
        model.cancelConnection()
        try await eventually { !model.disconnecting }
        #expect(!model.connected && catalog.recent.isEmpty)
        trust[request.challenge.identity] = "synthetic-previous-fingerprint"
        UserDefaults.standard.set(trust, forKey: "trustedHostKeys")
        model.connect(profile: fixtureProfile, password: password, rememberPassword: false)
        try await eventually { model.hostTrustRequest != nil || model.connectionError != nil }
        let changed = try #require(model.hostTrustRequest)
        #expect(changed.previous == "synthetic-previous-fingerprint")
        try #require(pins.contains(changed.challenge.fingerprint))
        model.trustHost()
        try await eventually { !model.connecting }
        try #require(model.connected, "\(model.connectionError ?? "应用连接未完成")")
        #expect(catalog.recent.count == 1)
        #expect(await credentials.saves == 0)
        #expect(model.hostTrustRequest == nil)
        remote = try #require(model.remote.store as? RemoteFileStore)
        let store = try #require(remote)
        remoteCreated = true
        try await store.createDirectory(at: remoteRoot)
        await model.remote.navigate(to: remoteRoot)
        try #require(model.remote.directoryReady && model.remote.path == remoteRoot)
        model.showTerminal = true
        model.startTerminal()
        try await eventually { model.terminalReady }
        let terminal = model.terminal.view
        terminal.insertText("printf '\\110\\117\\123\\124\\104\\117\\103\\113\\137\\101\\120\\120\\137\\117\\113\\n'\r" as NSString,
                            replacementRange: NSRange(location: NSNotFound, length: 0))
        try await eventually { String(decoding: terminal.getBufferAsData(), as: UTF8.self).contains("HOSTDOCK_APP_OK") }
        terminal.setFrameSize(NSSize(width: 1024, height: 300))
        let size = "\(model.terminal.rows) \(model.terminal.columns)"
        terminal.insertText("stty size\r" as NSString, replacementRange: NSRange(location: NSNotFound, length: 0))
        try await eventually { String(decoding: terminal.getBufferAsData(), as: UTF8.self).contains(size) }
        model.toggleTerminal()
        #expect(!model.showTerminal && model.terminalRunning)
        model.toggleTerminal()
        #expect(model.terminalReady && model.terminal.view === terminal)
        let selected = try #require(model.local.roots.first { $0.entry.name == source.lastPathComponent })
        model.local.selection = [selected.entry.path]
        model.transfer(upload: true)
        try #require(model.transferring, "应用未开始上传。")
        try await eventually { !model.transferring && model.remote.directoryReady }
        try #require(model.transferLabel.hasPrefix("传输完成"), "\(model.logs.map(\.text).joined(separator: "\n"))")
        try #require(try await store.metadata(at: remoteRoot + "/样例 文件夹/文件.txt")?.size == UInt64(payload.count))
        await model.local.navigate(to: downloads.path)
        let uploaded = try #require(model.remote.roots.first { $0.entry.name == source.lastPathComponent })
        model.remote.selection = [uploaded.entry.path]
        model.transfer(upload: false)
        try #require(model.transferring, "应用未开始下载。")
        try await eventually { !model.transferring && model.local.directoryReady }
        try #require(model.transferLabel.hasPrefix("传输完成"), "\(model.logs.map(\.text).joined(separator: "\n"))")
        let received = try Data(contentsOf: downloads.appendingPathComponent("样例 文件夹/文件.txt"))
        #expect(SHA256.hash(data: received) == SHA256.hash(data: payload))
        #expect(FileManager.default.fileExists(atPath: downloads.appendingPathComponent("样例 文件夹/空目录").path))
        try await clean(store, root: remoteRoot)
        remoteCreated = false
        await model.shutdown()
        #expect(!model.connected && !model.terminalReady && !model.remote.directoryReady)
        let profile = ConnectionProfile(name: "应用验收", endpoint: ConnectionEndpoint(host: host, port: 22, username: username))
        await credentials.rejectWrites()
        model.connect(profile: profile, password: password, rememberPassword: true)
        try await eventually { !model.connecting }
        try #require(model.connected && model.credentialNotice != nil)
        #expect(catalog.recent.count == 1)
        #expect(await credentials.saves == 0)
        await model.shutdown()
        await credentials.allowWrites()
        model.connect(profile: profile, password: password, rememberPassword: true)
        try await eventually { !model.connecting }
        try #require(model.connected)
        let saved = try #require(catalog.profile(for: profile.endpoint))
        #expect(saved.rememberPassword)
        #expect(await credentials.saves == 1)
        await model.shutdown()
        model.connect(profile: saved, password: nil, rememberPassword: true)
        try await eventually { !model.connecting }
        try #require(model.connected && model.credentialNotice == nil)
        #expect(catalog.recent.count == 1)
        #expect(await credentials.reads == 1)
        await model.shutdown()
        try await AppModel(catalog: catalog, credentials: credentials).removeProfile(saved)
        #expect(try await credentials.read(account: saved.credentialAccount) == nil)
        print("PASS 首次及变化指纹确认、取消连接、互传 SHA-256、终端命令与尺寸、会话保留、历史去重、成功后保存凭据、读取复用、保存失败仍保持连接、删除凭据及测试目录清理")
        try await checkConcurrentLiveSessions(host: host, username: username, password: password, pins: pins)
        try await prepareEncryptedReconnect(host: host, username: username, password: password, pins: pins)
    } catch {
        if remoteCreated, let remote {
            do { try await clean(remote, root: remoteRoot) }
            catch { print("应用验收目录未能清理：\(remoteRoot)") }
        }
        await model.shutdown()
        throw error
    }
}

@MainActor
private func prepareEncryptedReconnect(host: String, username: String, password: String, pins: Set<String>) async throws {
    let root = try encryptedReconnectDirectory()
    let local = root.appendingPathComponent("files")
    try FileManager.default.createDirectory(at: local, withIntermediateDirectories: false)
    let catalog = ConnectionCatalog(storage: FileConnectionStorage(url: root.appendingPathComponent("connections.json")))
    let credentials = EncryptedFileCredentialStore(directory: root)
    let profile = try ConnectionProfile(name: "重启连接验收", endpoint: ConnectionEndpoint(host: host, port: 22, username: username), localStartDirectory: local.path).validated()
    let app = AppModel(catalog: catalog, credentials: credentials)
    do {
        app.showConnections()
        app.pickerSelection = .saved(profile.id)
        let session = try app.connectFromPicker(profile: profile, password: password, rememberPassword: true)
        try await finishLivePickerConnection(session, pins: pins)
        #expect(!app.connectionPickerPresented && app.selectedSession === session)
        #expect(try #require(catalog.profile(for: profile.endpoint)).rememberPassword)
        for name in ["credentials.json", "connections.json"] {
            let data = try Data(contentsOf: root.appendingPathComponent(name))
            let containsPlaintext = data.range(of: Data(password.utf8)) != nil
            #expect(!containsPlaintext, "验收文件不得包含明文密码")
        }
        await app.shutdown()
        print("PASS 登录成功后保存本机加密密码，临时配置与密码文件中没有明文，连接已关闭；随后由新进程验证重启读取")
    } catch { await app.shutdown(); throw error }
}

@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["HOSTDOCK_DISK_RECONNECT"] == "1"))
func encryptedPasswordReconnectsInNewProcess() async throws {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    let env = ProcessInfo.processInfo.environment
    let host = try #require(env["HOSTDOCK_CHECK_HOST"])
    let pins = Set(try #require(env["HOSTDOCK_CHECK_FINGERPRINTS"]).split(separator: ",").map(String.init))
    let root = try encryptedReconnectDirectory()
    let originalTrust = UserDefaults.standard.object(forKey: "trustedHostKeys")
    defer {
        if let originalTrust { UserDefaults.standard.set(originalTrust, forKey: "trustedHostKeys") }
        else { UserDefaults.standard.removeObject(forKey: "trustedHostKeys") }
    }
    var known = UserDefaults.standard.dictionary(forKey: "trustedHostKeys") ?? [:]
    known.removeValue(forKey: "[\(host.lowercased())]:22")
    UserDefaults.standard.set(known, forKey: "trustedHostKeys")
    let catalog = ConnectionCatalog(storage: FileConnectionStorage(url: root.appendingPathComponent("connections.json")))
    let profile = try #require(catalog.profiles.first)
    let app = AppModel(catalog: catalog, credentials: EncryptedFileCredentialStore(directory: root))
    do {
        app.showConnections()
        let session = try app.connectFromPicker(profile: profile, password: nil, rememberPassword: true)
        try await finishLivePickerConnection(session, pins: pins)
        #expect(!app.connectionPickerPresented && app.selectedSession === session)
        session.toggleTerminal()
        try await eventually { session.terminalReady }
        try await session.connection.writeTerminal(Data("printf '\\110\\117\\123\\124\\104\\117\\103\\113\\137\\122\\105\\123\\124\\101\\122\\124\\n'\r".utf8))
        try await eventually { String(decoding: session.terminal.view.getBufferAsData(), as: UTF8.self).contains("HOSTDOCK_RESTART") }
        await app.shutdown()
        print("PASS 新进程未提供密码，成功从本机加密文件读取并登录真实服务器、关闭连接弹窗、执行终端命令并断开；临时密码库由脚本清理")
    } catch { await app.shutdown(); throw error }
}

private func encryptedReconnectDirectory() throws -> URL {
    let path = try #require(ProcessInfo.processInfo.environment["HOSTDOCK_RECONNECT_DIR"])
    let root = URL(fileURLWithPath: path).resolvingSymlinksInPath()
    let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
    try #require(root.lastPathComponent.hasPrefix("hostdock-reconnect.") && FilePath.isInside(root.path, directory: temporary.path))
    return root
}

@MainActor
private func finishLivePickerConnection(_ session: SessionModel, pins: Set<String>) async throws {
    for _ in 0..<400 {
        if let request = session.hostTrustRequest {
            try #require(pins.contains(request.challenge.fingerprint), "重启连接验收指纹不匹配")
            session.trustHost()
        }
        if !session.connecting { break }
        try await Task.sleep(for: .milliseconds(50))
    }
    try #require(session.connected && !session.connecting, "\(session.connectionError ?? session.credentialNotice ?? "连接未完成")")
}

@MainActor
private func checkConcurrentLiveSessions(host: String, username: String, password: String, pins: Set<String>) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("hostdock-concurrent-\(UUID())")
    let remoteRoot = "/tmp/hostdock-check-\(UUID())"
    let endpoint = ConnectionEndpoint(host: host, port: 22, username: username)
    let catalog = ConnectionCatalog(storage: MemoryConnectionStorage())
    let credentials = MemoryCredentialStore()
    let reservations = TransferReservations()
    let profiles = ["A", "B"].map {
        ConnectionProfile(name: "并发验收 \($0)", endpoint: endpoint,
            localStartDirectory: root.appendingPathComponent($0).path, remoteStartDirectory: remoteRoot + "/" + $0)
    }
    // 同一真实主机的两条独立 SSH 连接；应用内同一身份去重由替身测试验证。
    let models = profiles.map { SessionModel(profile: $0, catalog: catalog, credentials: credentials, reservations: reservations) }
    let a = models[0], b = models[1]
    let gateA = TestGate(), gateB = TestGate()
    var remoteA: RemoteFileStore?, remoteB: RemoteFileStore?
    var remoteCreated = false
    defer { try? FileManager.default.removeItem(at: root) }
    do {
        for (index, profile) in profiles.enumerated() {
            let local = URL(fileURLWithPath: profile.localStartDirectory!)
            let folder = local.appendingPathComponent("样例 \(index)")
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("空目录"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: local.appendingPathComponent("downloads"), withIntermediateDirectories: false)
            try Data(repeating: UInt8(index + 42), count: 2 * 1024 * 1024).write(to: folder.appendingPathComponent("内容.bin"))
            try Data("隐藏内容 \(index)".utf8).write(to: folder.appendingPathComponent(".hidden"))
            try Data().write(to: folder.appendingPathComponent("zero.txt"))
            models[index].connect(profile: profile, password: password, rememberPassword: false)
        }
        for _ in 0..<400 {
            for model in models {
                if let request = model.hostTrustRequest {
                    try #require(pins.contains(request.challenge.fingerprint), "并发验收指纹不匹配")
                    model.trustHost()
                }
            }
            if models.allSatisfy({ !$0.connecting }) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(a.connected && b.connected, "两条 SSH 连接未同时就绪")
        #expect(!a.remote.directoryReady && !b.remote.directoryReady)
        remoteA = try #require(a.remote.store as? RemoteFileStore)
        remoteB = try #require(b.remote.store as? RemoteFileStore)
        let storeA = try #require(remoteA), storeB = try #require(remoteB)
        remoteCreated = true
        try await storeA.createDirectory(at: remoteRoot)
        for label in ["A", "B", "browse"] { try await storeA.createDirectory(at: remoteRoot + "/" + label) }
        await a.remote.attach(store: GatedFileStore(base: storeA, gate: gateA), home: a.remote.home, initialDirectory: remoteRoot + "/A")
        await b.remote.attach(store: GatedFileStore(base: storeB, gate: gateB), home: b.remote.home, initialDirectory: remoteRoot + "/B")
        try #require(a.remote.directoryReady && b.remote.directoryReady)
        a.toggleTerminal(); b.toggleTerminal()
        try await eventually { a.terminalReady && b.terminalReady }
        b.setVisible(false)
        b.terminal.view.insertText("printf '\\110\\117\\123\\124\\104\\117\\103\\113\\137\\102\\101\\103\\113\\107\\122\\117\\125\\116\\104\\n'\r" as NSString,
                                  replacementRange: NSRange(location: NSNotFound, length: 0))
        try await eventually { String(decoding: b.terminal.view.getBufferAsData(), as: UTF8.self).contains("HOSTDOCK_BACKGROUND") }
        #expect(!String(decoding: a.terminal.view.getBufferAsData(), as: UTF8.self).contains("HOSTDOCK_BACKGROUND"))
        for (index, model) in models.enumerated() {
            model.local.selection = [try #require(model.local.roots.first { $0.entry.name == "样例 \(index)" }).entry.path]
            model.transfer(upload: true)
        }
        try await waitForReservations(reservations, active: 2)
        for (index, store) in [storeA, storeB].enumerated() {
            var partialFound = false
            for _ in 0..<400 {
                if let entries = try? await store.list(at: remoteRoot + (index == 0 ? "/A" : "/B") + "/样例 \(index)"),
                   entries.contains(where: { $0.name.hasSuffix(".part") }) { partialFound = true; break }
                try await Task.sleep(for: .milliseconds(20))
            }
            try #require(partialFound, "未观察到两条连接各自写入的临时文件")
        }
        await b.remote.navigate(to: remoteRoot + "/browse")
        a.cancelTransfer()
        try await eventually { !a.transferring }
        #expect(b.connected && b.transferring && a.transferLabel.hasPrefix("已取消"))
        #expect(!(try await storeA.list(at: remoteRoot + "/A/样例 0")).contains { $0.name.hasSuffix(".part") })
        await gateB.open()
        try await eventually { !b.transferring }
        try #require(b.transferLabel.hasPrefix("传输完成"), "\(b.logs.map(\.text))")
        #expect(b.remote.path == remoteRoot + "/browse")
        await gateA.open()
        a.transfer(upload: true)
        try await eventually { !a.transferring }
        try #require(a.transferLabel.hasPrefix("传输完成"), "\(a.logs.map(\.text))")
        for (index, model) in models.enumerated() {
            await model.remote.navigate(to: remoteRoot + (index == 0 ? "/A" : "/B"))
            await model.local.navigate(to: profiles[index].localStartDirectory! + "/downloads")
            model.remote.selection = [try #require(model.remote.roots.first { $0.entry.name == "样例 \(index)" }).entry.path]
            model.transfer(upload: false)
        }
        try await eventually { models.allSatisfy { !$0.transferring } }
        for (index, model) in models.enumerated() {
            try #require(model.transferLabel.hasPrefix("传输完成"), "\(model.logs.map(\.text))")
            let local = URL(fileURLWithPath: profiles[index].localStartDirectory!)
            for name in ["内容.bin", ".hidden", "zero.txt"] {
                let original = try Data(contentsOf: local.appendingPathComponent("样例 \(index)/" + name))
                let received = try Data(contentsOf: local.appendingPathComponent("downloads/样例 \(index)/" + name))
                #expect(SHA256.hash(data: original) == SHA256.hash(data: received))
            }
            #expect(FileManager.default.fileExists(atPath: local.appendingPathComponent("downloads/样例 \(index)/空目录").path))
        }
        b.setVisible(true)
        b.terminal.view.setFrameSize(NSSize(width: 960, height: 320))
        try await b.connection.writeTerminal(Data("sleep 30\r".utf8))
        try await Task.sleep(for: .milliseconds(100))
        try await b.connection.writeTerminal(Data([3]))
        try await b.connection.writeTerminal(Data("stty size\r".utf8))
        let size = "\(b.terminal.rows) \(b.terminal.columns)"
        try await eventually { String(decoding: b.terminal.view.getBufferAsData(), as: UTF8.self).contains(size) }
        await a.shutdown()
        #expect(b.connected && b.terminalReady)
        #expect(try await storeB.list(at: remoteRoot).count == 3)
        try await clean(storeB, root: remoteRoot)
        remoteCreated = false
        #expect(try await storeB.metadata(at: remoteRoot) == nil)
        await b.shutdown()
        try await waitForReservations(reservations, active: 0, waiting: 0)
        print("PASS 同一真实服务器两条独立 SSH：并发写入、单独取消及临时文件清理、浏览变化不改变任务目标、后台终端隔离、两份 2 MiB 文件夹往返 SHA-256、Ctrl+C 与尺寸同步、独立断开及远端测试目录清理")
    } catch {
        for model in models { model.cancelTransfer() }
        try? await eventually { models.allSatisfy { !$0.transferring } }
        if remoteCreated, let store = b.connected ? remoteB : remoteA {
            do { try await clean(store, root: remoteRoot) }
            catch { print("并发验收目录未能清理：\(remoteRoot)") }
        }
        for model in models { await model.shutdown() }
        throw error
    }
}

@MainActor
private func eventually(_ condition: () -> Bool) async throws {
    for _ in 0..<400 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(50))
    }
    throw HostDockError("应用流程等待超时。")
}

private func clean(_ store: RemoteFileStore, root: String) async throws {
    let prefix = "/tmp/hostdock-check-"
    guard root.hasPrefix(prefix), UUID(uuidString: String(root.dropFirst(prefix.count))) != nil else {
        throw HostDockError("拒绝清理非测试目录。")
    }
    func remove(_ path: String) async throws {
        guard FilePath.isInside(path, directory: root) else { throw HostDockError("清理路径越界。") }
        for entry in try await store.list(at: path) {
            if entry.kind == .directory { try await remove(entry.path) }
            else { try await store.removeFile(at: entry.path) }
        }
        try await store.removeEmptyDirectory(at: path)
    }
    try await remove(root)
}
