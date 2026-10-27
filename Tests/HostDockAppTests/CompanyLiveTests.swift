import AppKit
import CryptoKit
import Foundation
import HostDockCore
import Testing
@testable import HostDock

private actor CompanyOutput {
    var ready = false
    var bytes = Data()
    func markReady() { ready = true }
    func append(_ data: Data) { bytes.append(data) }
    func contains(_ value: String) -> Bool { String(decoding: bytes, as: UTF8.self).contains(value) }
}

private struct ReadOnlySavedCredentials: CredentialStore {
    let base = EncryptedFileCredentialStore()
    func read(account: String) async throws -> String? { try await base.read(account: account) }
    func save(_ password: String, account: String) throws { throw HostDockError("只读验收禁止修改正式凭据") }
    func remove(account: String) throws { throw HostDockError("只读验收禁止删除正式凭据") }
}

@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["HOSTDOCK_SAVED_CONNECTION_CHECK"] == "1"))
func savedDirectAndJumpProfilesConnectWithReadOnlyCredentials() async throws {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    let env = ProcessInfo.processInfo.environment
    let ids = Set(try #require(env["HOSTDOCK_SAVED_PROFILE_IDS"]).split(separator: ",").map(String.init))
    let document = try FileConnectionStorage(url: FileConnectionStorage.defaultURL).load()
    var profiles = document.profiles.filter { ids.contains($0.id.uuidString) }
    #expect(profiles.count == ids.count && profiles.count == 2)
    if let id = env["HOSTDOCK_SAVED_JUMP_PROFILE"], let index = profiles.firstIndex(where: { $0.id.uuidString == id }) {
        let original = profiles[index]
        profiles[index].connectionMode = .jumpServer
        profiles[index].jumpServer = JumpServerConfiguration(username: try #require(env["HOSTDOCK_SAVED_JUMP_USER"]),
            targetUsername: try #require(env["HOSTDOCK_SAVED_TARGET_USER"]), targetHost: try #require(env["HOSTDOCK_SAVED_TARGET_IP"]))
        profiles[index] = try profiles[index].validated()
        #expect(profiles[index].endpoint == original.endpoint && profiles[index].credentialAccount == original.credentialAccount)
    }
    let trusted = try #require(UserDefaults(suiteName: "app.hostdock.mac")?.dictionary(forKey: "trustedHostKeys") as? [String: String])
    let oldTrust = UserDefaults.standard.object(forKey: "trustedHostKeys")
    UserDefaults.standard.set(trusted, forKey: "trustedHostKeys")
    defer {
        if let oldTrust { UserDefaults.standard.set(oldTrust, forKey: "trustedHostKeys") }
        else { UserDefaults.standard.removeObject(forKey: "trustedHostKeys") }
    }
    var selectedDocument = document; selectedDocument.profiles = profiles; selectedDocument.recent = []
    let storage = MemoryConnectionStorage(selectedDocument)
    for round in 0..<2 {
        let app = AppModel(catalog: ConnectionCatalog(storage: storage), credentials: ReadOnlySavedCredentials())
        do {
            await app.refreshSavedConnections()
            #expect(app.savedProfiles.count == profiles.count)
            for profile in app.savedProfiles {
                print("CHECK \(profile.connectionMode.title) 第 \(round + 1) 次连接")
                app.showConnections()
                let session = try app.connectFromPicker(profile: profile, password: nil, rememberPassword: true)
                try await waitForCompany { await MainActor.run { !session.connecting || session.hostTrustRequest != nil } }
                guard session.hostTrustRequest == nil else { throw HostDockError("服务器指纹变化，停止只读验收") }
                guard session.connected, session.remote.directoryReady else {
                    throw HostDockError(session.connectionError ?? session.remote.error ?? "保存记录连接失败")
                }
                #expect(session.credentialNotice == nil && !session.passwordRequired)
                let remote = try #require(session.remote.store)
                _ = try await remote.list(at: session.remote.path)
                let initial = profile.remoteStartDirectory ?? session.remote.home
                if profile.connectionMode == .jumpServer,
                   (try? FilePath.normalize(initial == "~" ? session.remote.home : initial)) == "/",
                   let asset = try await remote.list(at: "/").first(where: { $0.kind == .directory && $0.name == profile.targetHost }) {
                    #expect(session.remote.path == asset.path && session.remote.pathDraft == asset.path)
                    print("PASS JumpServer 初始进入目标资产目录，保留真实 SFTP 路径")
                }
                if round == 0 {
                    try await waitForCompany { await MainActor.run { session.terminalReady } }
                    let marker = UUID().uuidString
                    try await session.connection.writeTerminal(Data(("printf 'HDUSER='; id -un; printf 'HDHOST='; hostname; printf 'HDIP='; hostname -I; printf 'HDEND=%s\\n' '" + marker + "'\r").utf8))
                    let user = profile.targetUsername
                    try await waitForCompany {
                        await MainActor.run {
                            let text = String(decoding: session.terminal.view.getBufferAsData(), as: UTF8.self)
                            return text.contains("HDUSER=" + user) && text.contains("HDEND=" + marker)
                        }
                    }
                    if let target = profile.jumpServer?.targetHost {
                        #expect(String(decoding: session.terminal.view.getBufferAsData(), as: UTF8.self).contains(target))
                    }
                }
                print("PASS \(profile.connectionMode.title) 已保存认证、SSH 身份及 SFTP 浏览，第 \(round + 1) 次")
            }
            #expect(app.sessions.filter(\.connected).count == 2)
            if round == 0, let asset = app.catalog.profiles.first(where: { $0.jumpServer?.accessProfileID != nil }),
               let access = app.catalog.accessProfiles.first(where: { $0.id == asset.jumpServer?.accessProfileID }) {
                let history = app.catalog.recent, sessionIDs = app.sessions.map(\.id)
                try await app.validateAndSaveAccess(access, asset: asset, password: nil)
                #expect(app.catalog.recent == history && app.sessions.map(\.id) == sessionIDs && app.sessions.allSatisfy(\.connected))
                print("PASS 共享堡垒机独立 SSH/SFTP 验证，现有终端、会话及历史保持")
            }
            await app.shutdown()
        } catch {
            await app.shutdown()
            throw error
        }
    }
}

@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["HOSTDOCK_KEY_CHECK"] == "1"))
func liveCompanyKeyAuthenticationFilesEditorAndAssetMapping() async throws {
    let env = ProcessInfo.processInfo.environment
    let host = try #require(env["HOSTDOCK_KEY_HOST"])
    let port = try #require(Int(env["HOSTDOCK_KEY_PORT"] ?? ""))
    let username = try #require(env["HOSTDOCK_KEY_USERNAME"])
    let keyPath = try #require(env["HOSTDOCK_KEY_PATH"])
    let fingerprint = try #require(env["HOSTDOCK_KEY_FINGERPRINT"])
    let prefix = try #require(env["HOSTDOCK_KEY_ASSET_PREFIX"])
    let targetUser = try #require(env["HOSTDOCK_KEY_TARGET_USER"])
    let targetIP = try #require(env["HOSTDOCK_KEY_TARGET_IP"])
    let originalTrust = UserDefaults.standard.object(forKey: "trustedHostKeys")
    defer {
        if let originalTrust { UserDefaults.standard.set(originalTrust, forKey: "trustedHostKeys") }
        else { UserDefaults.standard.removeObject(forKey: "trustedHostKeys") }
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("hostdock-company-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("上传 文件夹")
    let downloads = root.appendingPathComponent("downloads")
    try FileManager.default.createDirectory(at: source.appendingPathComponent("中文 空目录"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    let binary = Data((0..<(2 * 1024 * 1024)).map { UInt8($0 % 251) })
    try binary.write(to: source.appendingPathComponent("binary.bin"))
    try Data("original\r\n".utf8).write(to: source.appendingPathComponent(".配置.txt"))
    let catalogURL = root.appendingPathComponent("connections.json")
    let catalog = ConnectionCatalog(storage: FileConnectionStorage(url: catalogURL))
    let credentials = EncryptedFileCredentialStore(directory: root.appendingPathComponent("credentials"))
    let app = AppModel(catalog: catalog, credentials: credentials)
    let profile = ConnectionProfile(name: "公钥验收", endpoint: ConnectionEndpoint(host: host, port: port, username: username),
        localStartDirectory: root.path, remoteStartDirectory: prefix + "/tmp", authenticationKind: .rsaKey, privateKeyPath: keyPath)
    let suffix = "hostdock-check-" + UUID().uuidString
    let testPath = try FilePath.join(prefix + "/tmp", name: suffix)
    var store: (any FileStore)?
    var ownsRoot = false
    do {
        app.showConnections()
        let session = try app.connectFromPicker(profile: profile, password: nil, rememberPassword: true)
        try await waitUntil { session.hostTrustRequest != nil || !session.connecting }
        if let challenge = session.hostTrustRequest {
            guard challenge.challenge.fingerprint == fingerprint else { throw HostDockError("公司网关指纹与已核对值不同，停止验收。") }
            session.trustHost()
        }
        try await waitUntil { !session.connecting }
        #expect(session.connected && !session.passwordRequired && session.remote.directoryReady)
        let remote = try #require(session.remote.store)
        store = remote
        guard try await remote.metadata(at: testPath) == nil else { throw HostDockError("测试目录已存在，停止以免覆盖。") }
        try await remote.createDirectory(at: testPath)
        ownsRoot = true
        print("公司测试目录：\(testPath)")
        let marker = try FilePath.join(testPath, name: "asset-marker.txt")
        let token = UUID().uuidString
        try await TransferEngine().replaceContents(Data(token.utf8), at: marker, in: remote, expectedDigest: nil)

        let output = CompanyOutput()
        let terminal = Task {
            try await session.connection.runTerminal(columns: 100, rows: 30,
                onReady: { await output.markReady() }, onOutput: { await output.append($0) })
        }
        try await waitForCompany { await output.ready }
        // 目录名和标记均为本测试生成的 UUID，不拼接远端文件名作为命令。
        let command = "printf '\\036ID='; id -un; printf '\\036IP='; hostname -I; printf '\\036ASSET='; cat /tmp/\(suffix)/asset-marker.txt; printf '\\037\\n'; stty size\r"
        try await session.connection.writeTerminal(Data(command.utf8))
        try await waitForCompany { await output.contains("\u{1e}ASSET=" + token + "\u{1f}") }
        #expect(await output.contains("\u{1e}ID=" + targetUser))
        #expect(await output.contains("\u{1e}IP=" + targetIP))
        try await session.connection.resizeTerminal(columns: 110, rows: 35)
        try await session.connection.writeTerminal(Data("stty size\r".utf8))
        try await waitForCompany { await output.contains("35 110") }
        print("PASS 公司 SSH 身份、SFTP 资产映射及同连接 PTY 尺寸同步")

        await session.remote.navigate(to: testPath)
        await session.local.refresh()
        session.local.selection = [source.path]
        session.transfer(upload: true)
        try await waitForCompany { await MainActor.run { !session.transferring } }
        #expect(session.transferLabel.hasPrefix("传输完成"))
        let uploaded = try FilePath.join(testPath, name: source.lastPathComponent)
        #expect(try await FileOperations.digest(at: uploaded + "/binary.bin", in: remote) == SHA256.hash(data: binary).map { String(format: "%02x", $0) }.joined())
        session.remote.selection = [uploaded]
        await session.local.navigate(to: downloads.path)
        session.transfer(upload: false)
        try await waitForCompany { await MainActor.run { !session.transferring } }
        #expect(try Data(contentsOf: downloads.appendingPathComponent(source.lastPathComponent + "/binary.bin")) == binary)
        #expect(FileManager.default.fileExists(atPath: downloads.appendingPathComponent(source.lastPathComponent + "/中文 空目录").path))
        #expect(try Data(contentsOf: downloads.appendingPathComponent(source.lastPathComponent + "/.配置.txt")) == Data("original\r\n".utf8))
        print("PASS 公司文件夹往返 SHA-256、中文、隐藏文件和空目录")

        let textPath = uploaded + "/.配置.txt"
        let doc = try RemoteDocument(session: session, path: textPath,
            contents: try await FileOperations.read(at: textPath, in: remote, limit: RemoteDocument.sizeLimit),
            drafts: EditDraftStore(directory: root.appendingPathComponent("drafts")))
        doc.text = "edited through HostDock\n"
        #expect(await doc.save())
        #expect(try await FileOperations.read(at: textPath, in: remote, limit: 1024) == Data("edited through HostDock\r\n".utf8))
        let mode = try await remote.metadata(at: textPath)?.permissions
        if let mode { try await remote.setPermissions(mode, at: textPath) }
        let renamed = uploaded + "/renamed.txt"
        try await remote.move(from: textPath, to: renamed)
        let oldEntry = try await remote.metadata(at: textPath)
        let newEntry = try await remote.metadata(at: renamed)
        #expect(oldEntry == nil && newEntry != nil)
        print("PASS 公司远程编辑、备份、权限结果检查及重命名")

        let cancelFile = root.appendingPathComponent("cancel.bin")
        try binary.write(to: cancelFile)
        await session.local.navigate(to: root.path)
        let gate = TestGate()
        await session.remote.attach(store: GatedFileStore(base: remote, gate: gate), home: session.remote.home, initialDirectory: testPath)
        session.local.selection = [cancelFile.path]
        session.transfer(upload: true)
        try await waitForCompany { await gate.entered }
        session.cancelTransfer()
        try await waitForCompany { await MainActor.run { !session.transferring } }
        #expect(try await remote.metadata(at: testPath + "/cancel.bin") == nil)
        #expect(try await !remote.list(at: testPath).contains { $0.name.hasSuffix(".part") })
        await session.remote.attach(store: remote, home: "/", initialDirectory: testPath)
        print("PASS 公司实际 SFTP 写入后的取消与临时文件清理")

        if let entry = try await remote.metadata(at: testPath) { try await FileOperations.remove([entry], in: remote) }
        ownsRoot = false
        #expect(try await remote.metadata(at: testPath) == nil)

        await app.refreshSavedConnections()
        #expect(app.savedProfiles.count == 1)
        await app.shutdown()
        terminal.cancel()
        let restarted = AppModel(catalog: ConnectionCatalog(storage: FileConnectionStorage(url: catalogURL)), credentials: credentials)
        await restarted.refreshSavedConnections()
        let saved = try #require(restarted.savedProfiles.first)
        restarted.showConnections()
        let again = try restarted.connectFromPicker(profile: saved, password: nil, rememberPassword: true)
        try await waitUntil { !again.connecting }
        #expect(again.connected && !again.passwordRequired)
        let cleanupStore = try #require(again.remote.store)
        store = cleanupStore
        #expect(try await cleanupStore.metadata(at: testPath) == nil)
        await restarted.shutdown()
        print("PASS 公司配置磁盘恢复、一键公钥重连及独立测试目录清理")
    } catch {
        for session in app.sessions { session.cancelTransfer() }
        try? await waitForCompany { await MainActor.run { !app.hasTransfers } }
        if ownsRoot, let store, let entry = try? await store.metadata(at: testPath) {
            try? await FileOperations.remove([entry], in: store)
        }
        await app.shutdown()
        throw error
    }
}

private func waitForCompany(_ condition: @escaping () async -> Bool) async throws {
    for _ in 0..<2500 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(40))
    }
    throw HostDockError("公司网关验收等待超时。")
}

// 仅安装验收显式启用；常规测试始终使用临时资料。
@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["HOSTDOCK_KEY_INSTALL"] == "1"))
func installVerifiedKeyConnectionProfile() async throws {
    guard NSRunningApplication.runningApplications(withBundleIdentifier: "app.hostdock.mac").isEmpty else {
        throw HostDockError("请先正常退出 HostDock，再写入已验证的连接配置。")
    }
    let env = ProcessInfo.processInfo.environment
    let endpoint = ConnectionEndpoint(host: try #require(env["HOSTDOCK_KEY_HOST"]),
        port: try #require(Int(env["HOSTDOCK_KEY_PORT"] ?? "")), username: try #require(env["HOSTDOCK_KEY_USERNAME"]))
    let catalog = ConnectionCatalog()
    #expect(catalog.loadError == nil)
    let previous = catalog.profiles
    let name = try #require(env["HOSTDOCK_KEY_NAME"])
    let home = try #require(env["HOSTDOCK_KEY_HOME"])
    var profile = catalog.profile(for: endpoint) ?? ConnectionProfile(name: name, endpoint: endpoint, remoteStartDirectory: home)
    profile.authenticationKind = .rsaKey
    profile.privateKeyPath = try #require(env["HOSTDOCK_KEY_PATH"])
    profile.rememberPassword = true
    let app = AppModel(catalog: catalog)
    do {
        app.showConnections()
        let session = try app.connectFromPicker(profile: profile, password: nil, rememberPassword: true)
        try await waitUntil { session.hostTrustRequest != nil || !session.connecting }
        if let request = session.hostTrustRequest {
            guard request.challenge.fingerprint == env["HOSTDOCK_KEY_FINGERPRINT"] else {
                throw HostDockError("网关指纹与已核对值不同，未保存连接。")
            }
            session.trustHost()
        }
        try await waitUntil { !session.connecting }
        guard session.connected, session.remote.directoryReady else {
            throw HostDockError(session.connectionError ?? session.remote.error ?? "连接或默认目录验证失败。")
        }
        await app.refreshSavedConnections()
        #expect(app.savedProfiles.contains { $0.id == profile.id })
        for original in previous where original.endpoint != endpoint {
            let preserved = try #require(catalog.profiles.first { $0.id == original.id })
            #expect(preserved.name == original.name && preserved.endpoint == original.endpoint)
            #expect(preserved.localStartDirectory == original.localStartDirectory && preserved.remoteStartDirectory == original.remoteStartDirectory)
        }
        print("PASS 已验证的公钥配置写入用户资料，原记录 ID、名称及目录保留")
        await app.shutdown()
    } catch {
        await app.shutdown()
        throw error
    }
}

@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["HOSTDOCK_AUTOMATION_LIVE"] == "1"))
func automationUsesRealSavedProfilesInTemporaryDirectories() async throws {
    _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
    let env = ProcessInfo.processInfo.environment
    let ids = Set(try #require(env["HOSTDOCK_SAVED_PROFILE_IDS"]).split(separator: ",").map(String.init))
    var selectedDocument = try FileConnectionStorage(url: FileConnectionStorage.defaultURL).load()
    let profiles = selectedDocument.profiles.filter { ids.contains($0.id.uuidString) }
    selectedDocument.profiles = profiles; selectedDocument.recent = []
    #expect(profiles.count == 2)
    let remoteTmp = try JSONDecoder().decode([String: String].self, from: Data(try #require(env["HOSTDOCK_LIVE_REMOTE_TMP"]).utf8))
    let trust = try #require(UserDefaults(suiteName: "app.hostdock.mac")?.dictionary(forKey: "trustedHostKeys") as? [String: String])
    let oldTrust = UserDefaults.standard.object(forKey: "trustedHostKeys")
    UserDefaults.standard.set(trust, forKey: "trustedHostKeys")
    defer { if let oldTrust { UserDefaults.standard.set(oldTrust, forKey: "trustedHostKeys") } else { UserDefaults.standard.removeObject(forKey: "trustedHostKeys") } }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("hostdock-agent-live-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = "HostDock-v7-live-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
    let app = AppModel(catalog: ConnectionCatalog(storage: MemoryConnectionStorage(selectedDocument)), credentials: ReadOnlySavedCredentials(), preferences: defaults)
    let socket = FileManager.default.temporaryDirectory.appendingPathComponent("hdl-" + UUID().uuidString.prefix(8)).appendingPathComponent("control.sock")
    defer { try? FileManager.default.removeItem(at: socket.deletingLastPathComponent()) }
    let controller = AutomationController(app: app, defaults: defaults, socketURL: socket)
    var cleanup: [(any FileStore, String)] = []
    do {
        await controller.setEnabled(true)
        guard controller.enabled else { throw HostDockError(controller.notice ?? "自动化验收接口未开启。") }
        let listed = try await runLiveRequest(socket, ["profiles", "list"])
        #expect(listed.ok)
        for profile in profiles {
            let manual = try app.connect(profile: profile, password: nil, rememberPassword: true)
            try await waitForCompany { await MainActor.run { manual.terminalReady } }
        }
        let selected = app.selectedSessionID, maximize = app.maximizeRequest, history = app.catalog.recent
        let humanDirectories = app.sessions.map { ($0.local.path, $0.remote.path) }
        for profile in profiles {
            let connected = try await runLiveRequest(socket, ["connect", "--profile", profile.id.uuidString])
            guard connected.ok else { throw HostDockError(connected.error?.message ?? "CLI 连接失败") }
            let session = try #require(app.backgroundSessions.first { $0.profile.id == profile.id })
            #expect(session.connected && !session.passwordRequired && session.credentialNotice == nil)
            #expect(!session.terminalRunning && session.origin == .automation)
        }
        #expect(app.sessions.filter(\.connected).count == 2 && app.backgroundSessions.filter(\.connected).count == 2)
        for profile in profiles {
            let session = try #require(app.backgroundSessions.first { $0.profile.id == profile.id })
            let remote = try #require(session.remote.store)
            let temp = try #require(remoteTmp[profile.id.uuidString])
            let testName = "hostdock-check-" + UUID().uuidString
            let target = try FilePath.join(try await remote.canonicalDirectory(at: temp), name: testName)
            guard try await remote.metadata(at: target) == nil else { throw HostDockError("临时目录已经存在，停止验收") }
            try await remote.createDirectory(at: target); cleanup.append((remote, target))
            let local = root.appendingPathComponent(profile.id.uuidString)
            let source = local.appendingPathComponent("agent-source")
            let downloads = local.appendingPathComponent("downloads")
            try FileManager.default.createDirectory(at: source.appendingPathComponent("中文 空目录"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
            let payload = Data((0..<131_072).map { UInt8($0 % 251) })
            let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
            try payload.write(to: source.appendingPathComponent("payload.bin"))
            try Data("HostDock 自动化验收\r\n".utf8).write(to: source.appendingPathComponent("说明.txt"))
            let args = ["--session", session.id.uuidString]
            let uploaded = try await runLiveRequest(socket, ["files", "upload"] + args + ["--source", source.path, "--destination", target])
            #expect(uploaded.ok)
            #expect(try await FileOperations.digest(at: target + "/agent-source/payload.bin", in: remote) == digest)
            let listed = try await runLiveRequest(socket, ["files", "list"] + args + ["--path", target])
            #expect(listed.ok)
            let downloaded = try await runLiveRequest(socket, ["files", "download"] + args + ["--source", target + "/agent-source", "--destination", downloads.path])
            #expect(downloaded.ok)
            #expect(try Data(contentsOf: downloads.appendingPathComponent("agent-source/payload.bin")) == payload)
            #expect(FileManager.default.fileExists(atPath: downloads.appendingPathComponent("agent-source/中文 空目录").path))
            let exec = try await runLiveRequest(socket, ["exec"] + args + ["--command", "printf 'HD_EXEC_OK\\n'; id -un; printf 'HD_STDERR\\n' >&2; exit 7", "--timeout", "15"])
            if exec.ok {
                if case .object(let output) = exec.result {
                    #expect(output["exitCode"] == .number(7))
                    #expect(output["stderr"] == .string("HD_STDERR\n"))
                }
                let timeout = try await runLiveRequest(socket, ["exec"] + args + ["--command", "sleep 3", "--timeout", "0.2"])
                #expect(timeout.error?.code == "TIMEOUT")
                let signalled = try await runLiveRequest(socket, ["exec"] + args + ["--command", "kill -TERM $$", "--timeout", "5"])
                if case .object(let result) = signalled.result { #expect(result["exitCode"] != .number(0)) }
                else { #expect(signalled.error?.code == "EXIT_STATUS_UNAVAILABLE") }
                print("PASS \(profile.connectionMode.title) 本机接口 exec stdout/stderr、非零退出码、超时、信号结束及通道清理")
            } else {
                #expect(profile.connectionMode == .jumpServer && exec.error?.code == "EXEC_UNAVAILABLE")
                print("LIMIT \(profile.connectionMode.title) 网关拒绝标准 exec，返回明确错误，继续验收 PTY")
            }
            let marker = UUID().uuidString
            let command = "printf 'HD_IDENT='; id -un; sha256sum -- '/tmp/" + testName + "/agent-source/payload.bin'; printf 'HD_FINISHED=%s\\n' '" + marker + "'"
            let sent = try await runLiveRequest(socket, ["terminal", "send"] + args + ["--text", command, "--enter"])
            #expect(sent.ok)
            var text = ""
            for _ in 0..<300 {
                let snapshot = try await runLiveRequest(socket, ["terminal", "read"] + args + ["--tail", "200"])
                if case .object(let value) = snapshot.result, case .string(let value) = value["text"] { text = value }
                if text.contains("HD_IDENT=" + profile.targetUsername) && text.contains(digest) && text.contains("HD_FINISHED=" + marker) { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(app.sessions.allSatisfy { !String(decoding: $0.terminal.view.getBufferAsData(), as: UTF8.self).contains(marker) })
            #expect(text.contains("HD_IDENT=" + profile.targetUsername) && text.contains(digest) && text.contains("HD_FINISHED=" + marker))
            #expect(try await runLiveRequest(socket, ["terminal", "key"] + args + ["--key", "ctrl-c"]).ok)
            let gate = TestGate()
            await session.remote.attach(store: GatedFileStore(base: remote, gate: gate), home: session.remote.home, initialDirectory: target)
            let cancelSource = local.appendingPathComponent("cancel.bin"); try payload.write(to: cancelSource)
            let pending = Task { try await runLiveRequest(socket, ["files", "upload"] + args + ["--source", cancelSource.path, "--destination", target]) }
            try await waitForCompany { await gate.entered }
            pending.cancel()
            if case .success = await pending.result { Issue.record("取消请求不应返回成功") }
            try await waitForCompany { await MainActor.run { !session.transferring } }
            #expect(try await remote.metadata(at: target + "/cancel.bin") == nil)
            #expect(try await !remote.list(at: target).contains { $0.name.hasSuffix(".part") })
            #expect(app.sessions.allSatisfy { $0.connected })
            await session.remote.attach(store: remote, home: session.remote.home, initialDirectory: target)
            if let entry = try await remote.metadata(at: target) { try await FileOperations.remove([entry], in: remote) }
            #expect(try await remote.metadata(at: target) == nil)
            print("PASS \(profile.connectionMode.title) 本机接口一键连接、终端身份、SFTP 与 PTY 同一校验文件、文件夹 SHA-256、空目录、取消清理及另一会话保持连接")
        }
        #expect(app.selectedSessionID == selected && app.maximizeRequest == maximize && app.catalog.recent == history)
        for (session, paths) in zip(app.sessions, humanDirectories) { #expect(session.local.path == paths.0 && session.remote.path == paths.1) }
        await controller.setEnabled(false)
        #expect(app.backgroundSessions.isEmpty && app.sessions.count == 2 && app.sessions.allSatisfy { $0.connected })
        await app.shutdown()
    } catch {
        for session in app.allSessions { session.cancelTransfer() }
        try? await waitForCompany { await MainActor.run { !app.hasTransfers } }
        for (store, path) in cleanup { if let entry = try? await store.metadata(at: path) { try? await FileOperations.remove([entry], in: store) } }
        await controller.setEnabled(false)
        await app.shutdown()
        throw error
    }
}

@MainActor
private func runLiveRequest(_ socket: URL, _ arguments: [String]) async throws -> ControlResponse {
    try await ControlClient.call(ControlRequest.parse(arguments), url: socket)
}
