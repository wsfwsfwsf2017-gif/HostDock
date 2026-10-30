import AppKit
import Combine
import Foundation
import HostDockCore

struct TransferLog: Identifiable {
    let id = UUID()
    let text: String
    let warning: Bool
}

struct HostTrustRequest {
    let challenge: HostKeyChallenge
    let previous: String?
}

enum WorkspaceMode: String, CaseIterable {
    case terminal = "终端", files = "文件传输"
}

enum SessionOrigin { case interactive, automation }

@MainActor
final class SessionModel: ObservableObject, Identifiable {
    let id = UUID()
    let origin: SessionOrigin
    let diagnostics: DiagnosticLog
    var diagnosticOrigin: DiagnosticOrigin { origin == .interactive ? .interactive : .automation }
    @Published private(set) var profile: ConnectionProfile
    var onConnected: ((UUID) -> Void)?
    var onTerminalOutput: ((Data) -> Void)?
    var onConnectionLost: (() -> Void)?
    let local = BrowserModel()
    let remote = BrowserModel()
    let terminal = TerminalController()
    let connection: any SessionConnection
    private let reservations: TransferReservations
    private var acceptedFingerprint: String?
    private var visible = true
    let catalog: ConnectionCatalog
    private let credentials: any CredentialStore
    private let localStore = LocalFileStore()
    @Published private(set) var connecting = false
    @Published private(set) var connected = false
    @Published private(set) var disconnecting = false
    @Published var connectionError: String?
    @Published private(set) var connectionFailure: SSHConnectionFailure?
    @Published private(set) var credentialNotice: String?
    @Published private(set) var passwordRequired = false
    @Published private(set) var hostTrustRequest: HostTrustRequest?
    @Published private(set) var remoteLabel = "尚未连接"
    @Published var workspaceMode = WorkspaceMode.terminal
    @Published var terminalFraction = 0.7
    @Published var fileFraction = 0.5
    var showTerminal: Bool {
        get { workspaceMode == .terminal }
        set { setWorkspaceMode(newValue ? .terminal : .files) }
    }
    @Published private(set) var terminalReady = false
    @Published private(set) var terminalRunning = false
    @Published private(set) var transferring = false
    @Published private(set) var transferLabel = "选择文件或文件夹，上传或下载到另一侧当前目录"
    @Published private(set) var progress: Double = 0
    @Published private(set) var completed = 0
    @Published private(set) var skipped = 0
    @Published private(set) var logs: [TransferLog] = []
    private var connectionTask: Task<Void, Never>?
    private var cancellationTask: Task<Void, Never>?
    private var transferTask: Task<Void, Never>?
    private var fileOperationID: UUID?
    private var terminalTask: Task<Void, Never>?
    private var terminalInputTask: Task<Void, Never>?
    private var attempt = UUID()
    private var session = UUID()
    private var lastProgressUpdate = Date.distantPast
    private var hostTrustDecision: CheckedContinuation<Bool, Never>?
    @Published private(set) var conflictRequest: FileConflict?
    @Published private(set) var waitingForTarget = false
    @Published var automationRequests = 0
    private var conflictDecision: CheckedContinuation<ConflictDecision, Never>?

    var busy: Bool { connecting || disconnecting || transferring }
    var connectionGeneration: UUID { session }
    var verifiedRemoteIdentity: String { profile.endpoint.identity + ":" + (acceptedFingerprint ?? "") }
    var needsAttention: Bool { hostTrustRequest != nil || conflictRequest != nil || passwordRequired || connectionError != nil }
    var needsAuthentication: Bool {
        passwordRequired || connectionFailure == .authentication || connectionFailure == .keyFile
            || connectionFailure == .keyFormat || connectionFailure == .keyPassphrase
    }
    var status: String {
        if disconnecting { return "正在断开" }
        if hostTrustRequest != nil { return "确认指纹" }
        if conflictRequest != nil { return "确认同名文件" }
        if waitingForTarget { return "等待目标释放" }
        if transferring { return "传输中" }
        if connecting { return "正在连接" }
        if connected { return "已连接" }
        if passwordRequired { return profile.authenticationKind == .rsaKey ? "需要解锁密钥" : "需要密码" }
        return connectionError == nil ? "已断开" : "连接失败"
    }

    init(profile: ConnectionProfile, catalog: ConnectionCatalog, credentials: any CredentialStore,
         connection: any SessionConnection = LiveSessionConnection(), reservations: TransferReservations = TransferReservations(),
         origin: SessionOrigin = .interactive, diagnostics: DiagnosticLog = .disabled) {
        self.diagnostics = diagnostics
        self.origin = origin
        self.visible = origin == .interactive
        self.profile = profile
        self.catalog = catalog
        self.credentials = credentials
        self.connection = connection
        self.reservations = reservations
    }

    func connect(profile requested: ConnectionProfile, password supplied: String?, rememberPassword: Bool,
                 accessProfile: JumpServerAccessProfile? = nil, validationOnly: Bool = false) {
        guard !busy, !connected else { return }
        let diagnosticSpan = diagnostics.begin(.connect, id: id, origin: diagnosticOrigin)
        let profile: ConnectionProfile
        let access: JumpServerAccessProfile?
        do { let resolved = try catalog.resolve(requested, accessProfile: accessProfile); profile = resolved.profile; access = resolved.access }
        catch { diagnostics.finish(diagnosticSpan, failure: .classify(error)); connectionError = error.localizedDescription; return }
        let endpoint = profile.endpoint
        self.profile = profile
        acceptedFingerprint = nil
        connectionError = nil; connectionFailure = nil; credentialNotice = nil; passwordRequired = false
        connecting = true
        let token = UUID()
        attempt = token
        connectionTask = Task { [self] in
            var diagnosticFailure: DiagnosticFailure? = .cancelled
            defer { diagnostics.finish(diagnosticSpan, failure: diagnosticFailure) }
            defer { if attempt == token { connecting = false; connectionTask = nil } }
            do {
                var secret = supplied.flatMap { $0.isEmpty ? nil : $0 }
                var reusedAccount: String?
                if secret == nil && rememberPassword && profile.rememberPassword && (profile.authenticationKind == .password || profile.keyRequiresPassphrase) {
                    do {
                        for account in catalog.authenticationAccounts(profile: profile, access: access) {
                            if let saved = try await credentials.read(account: account) { secret = saved; reusedAccount = account; break }
                        }
                    }
                    catch { credentialNotice = "未能读取已保存的认证，请通过修改认证重新设置。\n\(error.localizedDescription)" }
                }
                guard attempt == token, !Task.isCancelled else { return }
                let authentication: SSHAuthentication
                switch profile.authenticationKind {
                case .password:
                    guard let secret else { diagnosticFailure = .authentication; passwordRequired = true; return }
                    authentication = .password(secret)
                case .rsaKey:
                    if profile.keyRequiresPassphrase && secret == nil { diagnosticFailure = .keyPassphrase; passwordRequired = true; return }
                    authentication = .rsaKey(path: profile.privateKeyPath ?? "", passphrase: secret)
                }
                let result = try await connection.connect(
                    host: endpoint.host, port: endpoint.port, username: endpoint.username, authentication: authentication,
                    verifyHostKey: { [weak self] challenge in await self?.verify(challenge, attempt: token) ?? false },
                    onDisconnect: { [weak self] in await self?.connectionDropped(attempt: token) }
                )
                guard attempt == token, !Task.isCancelled else { return }
                session = UUID()
                remoteLabel = profile.name
                await local.attach(store: localStore, home: NSHomeDirectory(), initialDirectory: profile.localStartDirectory)
                guard attempt == token, !Task.isCancelled else { return }
                await remote.attach(store: result.store, home: result.home, initialDirectory: profile.remoteStartDirectory)
                guard attempt == token, !Task.isCancelled else { return }
                if profile.connectionMode == .jumpServer, remote.path == "/", remote.error == nil,
                   let asset = remote.roots.first(where: { $0.entry.kind == .directory && $0.entry.name == profile.targetHost }) {
                    await remote.attach(store: result.store, home: result.home, initialDirectory: asset.entry.path)
                    guard attempt == token, !Task.isCancelled else { return }
                    if remote.error == nil,
                       let account = remote.roots.first(where: { $0.entry.kind == .directory && $0.entry.name == profile.targetUsername }) {
                        await remote.attach(store: result.store, home: result.home, initialDirectory: account.entry.path)
                        guard attempt == token, !Task.isCancelled else { return }
                    }
                }
                do {
                    if origin == .interactive && (rememberPassword || validationOnly) {
                        self.profile = try await persistAuthentication(profile: profile, access: access, secret: secret,
                            reusedAccount: reusedAccount, token: token, validationOnly: validationOnly)
                    } else if origin == .interactive, var old = catalog.profiles.first(where: { $0.id == profile.id && $0.credentialAccount == profile.credentialAccount }) {
                        try await credentials.remove(account: old.credentialAccount)
                        old.lastValidatedAt = nil; old.rememberPassword = false
                        try catalog.save(old)
                        self.profile = old
                    }
                } catch {
                    if validationOnly { throw error }
                    if attempt == token {
                        credentialNotice = "已连接，但认证保存未完成，此连接暂不能一键重连。\n\(error.localizedDescription)"
                    }
                }
                if !validationOnly && origin == .interactive {
                    var recentProfile = self.profile
                    if let id = recentProfile.jumpServer?.accessProfileID, !catalog.accessProfiles.contains(where: { $0.id == id }) { recentProfile.jumpServer?.accessProfileID = nil }
                    do { try catalog.recordSuccess(profile: recentProfile) }
                    catch { credentialNotice = "已连接，但最近连接记录未能保存。\(error.localizedDescription)" }
                }
                if attempt == token, !Task.isCancelled {
                    diagnosticFailure = nil
                    connected = true
                    if !validationOnly && origin == .interactive { terminal.reset(); startTerminal() }
                    onConnected?(id)
                }
            } catch {
                diagnosticFailure = .classify(error)
                if attempt == token {
                    finishHostTrust(false)
                    if !Task.isCancelled {
                        connectionFailure = error as? SSHConnectionFailure
                        passwordRequired = (error as? SSHConnectionFailure) == .keyPassphrase
                        connectionError = error.localizedDescription
                    }
                }
            }
        }
    }

    private func persistAuthentication(profile: ConnectionProfile, access: JumpServerAccessProfile?, secret: String?,
                                       reusedAccount: String?, token: UUID, validationOnly: Bool) async throws -> ConnectionProfile {
        let lockID = UUID()
        let lockPath = access?.id.uuidString ?? profile.id.uuidString
        try await reservations.acquire([try TransferDestination(storage: "HostDock.authentication", path: "/" + lockPath)], id: lockID)
        do {
            var record = profile
            record.lastValidatedAt = Date(); record.rememberPassword = true
            record.keyRequiresPassphrase = access?.keyRequiresPassphrase ?? (profile.authenticationKind == .rsaKey && secret != nil)
            var verifiedAccess = access
            verifiedAccess?.lastValidatedAt = record.lastValidatedAt
            let account = access?.credentialAccount ?? record.credentialAccount
            let previousAccount = catalog.profiles.first(where: { $0.id == record.id })?.credentialAccount
            let shouldWrite = secret != nil && reusedAccount != account && (access?.rememberPassphrase ?? true)
            let shouldRemove = access?.rememberPassphrase == false
            let oldSecret = shouldWrite || shouldRemove ? try await credentials.read(account: account) : nil
            var changed = false
            do {
                guard attempt == token, !Task.isCancelled else { throw CancellationError() }
                if shouldWrite, let secret { try await credentials.save(secret, account: account); changed = true }
                if shouldRemove { try await credentials.remove(account: account); changed = true }
                guard attempt == token, !Task.isCancelled else { throw CancellationError() }
                if validationOnly {
                    guard let verifiedAccess else { throw HostDockError("请选择要验证的堡垒机配置。") }
                    try catalog.saveAccessProfile(verifiedAccess)
                } else { try catalog.save(record, accessProfile: verifiedAccess, replaceAccess: access?.lastValidatedAt == nil) }
            } catch {
                if changed {
                    if let oldSecret { try? await credentials.save(oldSecret, account: account) }
                    else { try? await credentials.remove(account: account) }
                }
                throw error
            }
            if access == nil, let previousAccount, previousAccount != account {
                do { try await credentials.remove(account: previousAccount) }
                catch { credentialNotice = "新认证已保存，但旧认证清理失败，请检查本机密码库。" }
            }
            await reservations.release(lockID)
            return record
        } catch { await reservations.release(lockID); throw error }
    }

    func cancelConnection() {
        guard connecting, !connected else { return }
        diagnostics.record(.cancelled, id: id, operation: .connect, origin: diagnosticOrigin, critical: true)
        finishHostTrust(false)
        attempt = UUID()
        connecting = false
        connectionTask?.cancel()
        connectionTask = nil
        passwordRequired = false
        disconnecting = true
        cancellationTask = Task { await connection.disconnect(); disconnecting = false; cancellationTask = nil }
    }

    private func verify(_ challenge: HostKeyChallenge, attempt token: UUID) async -> Bool {
        guard attempt == token, connecting else { return false }
        let known = UserDefaults.standard.dictionary(forKey: "trustedHostKeys") as? [String: String] ?? [:]
        let previous = known[challenge.identity]
        if previous == challenge.fingerprint { acceptedFingerprint = challenge.fingerprint; return true }
        return await withCheckedContinuation { continuation in
            hostTrustDecision = continuation
            hostTrustRequest = HostTrustRequest(challenge: challenge, previous: previous)
        }
    }

    func trustHost() {
        guard let request = hostTrustRequest, connecting else { return }
        var known = UserDefaults.standard.dictionary(forKey: "trustedHostKeys") as? [String: String] ?? [:]
        known[request.challenge.identity] = request.challenge.fingerprint
        UserDefaults.standard.set(known, forKey: "trustedHostKeys")
        acceptedFingerprint = request.challenge.fingerprint
        finishHostTrust(true)
    }

    private func finishHostTrust(_ trusted: Bool) {
        let decision = hostTrustDecision
        hostTrustDecision = nil
        hostTrustRequest = nil
        decision?.resume(returning: trusted)
    }

    private func connectionDropped(attempt token: UUID) {
        guard attempt == token else { return }
        diagnostics.record(.operationFinished, id: id, operation: .disconnect, origin: diagnosticOrigin, failure: .network)
        attempt = UUID()
        connectionTask?.cancel()
        connectionTask = nil
        connecting = false
        connectionError = "连接已断开，请重新连接。"
        finishHostTrust(false)
        session = UUID()
        connected = false
        remote.clear()
        remoteLabel = "连接已断开"
        cancelTransfer()
        terminal.ready = false
        terminalReady = false
        terminalRunning = false
        terminal.onInput = nil
        terminalInputTask?.cancel()
        terminalTask?.cancel()
        terminalTask = nil
        terminal.message("连接已断开，请重新连接。")
        onConnectionLost?()
    }

    func disconnect() {
        guard !disconnecting else { return }
        disconnecting = true
        Task { await shutdown(); disconnecting = false }
    }

    func shutdown() async {
        let diagnosticSpan = diagnostics.begin(.disconnect, id: id, origin: diagnosticOrigin)
        defer { diagnostics.finish(diagnosticSpan) }
        await cancellationTask?.value
        disconnecting = true
        await closeSession()
        disconnecting = false
    }

    private func closeSession() async {
        finishHostTrust(false)
        attempt = UUID()
        connectionTask?.cancel()
        connectionTask = nil
        cancelTransfer()
        terminal.ready = false
        terminalReady = false
        terminal.onInput = nil
        terminalInputTask?.cancel()
        await transferTask?.value
        session = UUID()
        await connection.disconnect()
        terminalTask?.cancel()
        terminalTask = nil
        terminalRunning = false
        connected = false
        connecting = false
        passwordRequired = false
        remote.clear()
        remoteLabel = "尚未连接"
    }

    func toggleTerminal() {
        setWorkspaceMode(workspaceMode == .terminal ? .files : .terminal)
    }

    func setWorkspaceMode(_ mode: WorkspaceMode) {
        guard workspaceMode != mode else { return }
        workspaceMode = mode
        if mode == .terminal && connected && !terminalRunning { startTerminal() }
    }

    func setVisible(_ value: Bool) {
        visible = value
        if value && terminalReady {
            Task { try? await connection.resizeTerminal(columns: terminal.columns, rows: terminal.rows) }
        }
    }

    func startTerminal() {
        guard connected, !terminalRunning else { return }
        let diagnosticSpan = diagnostics.begin(.terminal, id: id, origin: diagnosticOrigin)
        terminalRunning = true
        terminalReady = false
        terminal.ready = false
        let token = session
        let (input, continuation) = AsyncStream<Data>.makeStream()
        terminal.onInput = { continuation.yield($0) }
        terminal.onResize = { [weak self] columns, rows in
            guard let self, self.visible else { return }
            Task { try? await self.connection.resizeTerminal(columns: columns, rows: rows) }
        }
        terminalInputTask = Task { [weak self] in
            guard let connection = self?.connection else { return }
            for await data in input {
                guard !Task.isCancelled else { break }
                do { try await connection.writeTerminal(data) }
                catch { self?.terminal.message("终端输入失败：\(error.localizedDescription)"); break }
            }
        }
        terminalTask = Task { [self] in
            var diagnosticFailure: DiagnosticFailure?
            defer {
                diagnostics.finish(diagnosticSpan, failure: diagnosticFailure)
                continuation.finish()
                if session == token {
                    terminal.ready = false
                    terminal.onInput = nil
                    terminalReady = false
                    terminalRunning = false
                    terminalTask = nil
                    terminalInputTask?.cancel()
                }
            }
            do {
                try await connection.runTerminal(columns: terminal.columns, rows: terminal.rows,
                    onReady: { [weak self] in
                        await self?.terminalDidBecomeReady(session: token)
                    },
                    onOutput: { [weak self] data in await self?.receiveTerminal(data, session: token) })
                if session == token { terminal.message("终端会话已结束。") }
            } catch {
                diagnosticFailure = .classify(error)
                if session == token && connected { terminal.message("终端结束：\(error.localizedDescription)") }
            }
        }
    }

    private func terminalDidBecomeReady(session token: UUID) async {
        guard session == token else { return }
        terminalReady = true
        terminal.ready = true
        try? await connection.resizeTerminal(columns: terminal.columns, rows: terminal.rows)
    }

    private func receiveTerminal(_ data: Data, session token: UUID) {
        if session == token { terminal.feed(data); onTerminalOutput?(data) }
    }

    func transfer(upload: Bool) {
        guard connected, !transferring, !disconnecting, local.directoryReady, remote.directoryReady,
              let source = upload ? local.store : remote.store,
              let destination = upload ? remote.store : local.store else { return }
        let browser = upload ? local : remote
        let entries = browser.selectedEntries
        guard !entries.isEmpty else { return }
        let target = upload ? remote : local
        let directory = target.path
        transferring = true
        completed = 0
        skipped = 0
        progress = 0
        logs = [TransferLog(text: upload ? "上传至 \(remoteLabel):\(directory)" : "下载至本机：\(directory)", warning: false)]
        lastProgressUpdate = .distantPast
        transferLabel = upload ? "准备上传…" : "准备下载…"
        let requestID = UUID()
        let endpoint = profile.endpoint
        let identities = upload
            ? ["remote:\(endpoint.host):\(endpoint.port)"] + (acceptedFingerprint.map { ["hostkey:\($0)"] } ?? [])
            : ["local"]
        waitingForTarget = true
        transferTask = Task { [self] in
            let diagnosticSpan = diagnostics.begin(.transfer, id: id, origin: diagnosticOrigin)
            var diagnosticFailure: DiagnosticFailure?
            defer { diagnostics.finish(diagnosticSpan, failure: diagnosticFailure, count: completed) }
            var acquired = false
            do {
                let canonical = try await destination.canonicalDirectory(at: directory)
                let paths = try FilePath.topLevelSelection(entries).flatMap { entry in
                    try identities.map { try TransferDestination(storage: $0, path: FilePath.join(canonical, name: entry.name)) }
                }
                try await reservations.acquire(paths, id: requestID)
                acquired = true
                waitingForTarget = false
                try Task.checkCancellation()
                try await TransferEngine().transfer(entries, from: source, to: destination, directory: canonical,
                    onConflict: { [weak self] conflict in await self?.resolve(conflict) ?? .cancel },
                    onEvent: { [weak self] event in await self?.record(event) })
                transferLabel = "传输完成 · 完成 \(completed) 项" + (skipped > 0 ? "，跳过 \(skipped) 项" : "")
                progress = 1
            } catch is CancellationError {
                diagnosticFailure = .cancelled
                transferLabel = "已取消 · 已完成的项目保留"
            } catch {
                diagnosticFailure = .classify(error)
                transferLabel = "传输失败，请查看记录"
                logs.append(TransferLog(text: error.localizedDescription, warning: true))
            }
            if acquired { await reservations.release(requestID) }
            waitingForTarget = false
            finishConflict(.cancel)
            // 用户可能已切换目录，刷新其当前目录，不改变任务捕获的目标。
            await target.refresh()
            transferring = false
            transferTask = nil
        }
    }

    func cancelTransfer() {
        guard transferring else { return }
        diagnostics.record(.cancelled, id: id, operation: .transfer, origin: diagnosticOrigin, critical: true)
        finishConflict(.cancel)
        transferTask?.cancel()
        transferLabel = "正在取消并清理临时文件…"
    }

    func resolve(_ conflict: FileConflict) async -> ConflictDecision {
        guard !Task.isCancelled else { return .cancel }
        return await withCheckedContinuation { continuation in
            conflictDecision = continuation
            conflictRequest = conflict
        }
    }

    func runFileOperation(_ label: String, localPaths: [String] = [], remotePaths: [String] = [],
                          operation: @escaping @Sendable () async throws -> Void) async throws {
        let diagnosticSpan = diagnostics.begin(.fileOperation, id: id, origin: diagnosticOrigin)
        do {
            let token = session
            while transferring {
                try Task.checkCancellation()
                guard connected, !disconnecting, session == token else { throw HostDockError("原会话已断开，操作未执行。") }
                try await Task.sleep(for: .milliseconds(80))
            }
            guard connected, !disconnecting, session == token else { throw HostDockError("请先连接原服务器。") }
            let remoteIdentities = ["remote:\(profile.endpoint.host):\(profile.endpoint.port)"]
                + (acceptedFingerprint.map { ["hostkey:\($0)"] } ?? [])
            let paths = try localPaths.map { try TransferDestination(storage: "local", path: $0) }
                + remotePaths.flatMap { path in try remoteIdentities.map { try TransferDestination(storage: $0, path: path) } }
            transferring = true
            transferLabel = label
            completed = 0; skipped = 0
            logs = [TransferLog(text: label, warning: false)]
            progress = 0
            let requestID = UUID()
            fileOperationID = requestID
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    transferTask = Task { [self] in
                        var acquired = false
                        var failure: Error?
                        do {
                            waitingForTarget = true
                            try await reservations.acquire(paths, id: requestID)
                            acquired = true; waitingForTarget = false
                            try Task.checkCancellation()
                            try await operation()
                            transferLabel = "\(label)完成"; progress = 1
                        } catch {
                            failure = error
                            transferLabel = error is CancellationError ? "已取消 · 已完成的项目保留" : "\(label)失败"
                            logs.append(TransferLog(text: error.localizedDescription, warning: true))
                        }
                        if acquired { await reservations.release(requestID) }
                        waitingForTarget = false
                        finishConflict(.cancel)
                        await local.refresh(); await remote.refresh()
                        transferring = false; transferTask = nil
                        if fileOperationID == requestID { fileOperationID = nil }
                        if let failure { continuation.resume(throwing: failure) }
                        else { continuation.resume() }
                    }
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    if self?.fileOperationID == requestID { self?.cancelTransfer() }
                }
            }
            diagnostics.finish(diagnosticSpan)
        } catch {
            diagnostics.finish(diagnosticSpan, failure: .classify(error))
            throw error
        }
    }

    func finishConflict(_ decision: ConflictDecision) {
        let continuation = conflictDecision
        conflictDecision = nil
        conflictRequest = nil
        continuation?.resume(returning: decision)
    }

    func record(_ event: TransferEvent) {
        switch event {
        case let .progress(path, bytes, total):
            if bytes != total && Date().timeIntervalSince(lastProgressUpdate) < 0.1 { return }
            lastProgressUpdate = Date()
            progress = total == 0 ? 1 : min(1, Double(bytes) / Double(total))
            transferLabel = "\(URL(fileURLWithPath: path).lastPathComponent) · \(ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: Int64(clamping: total), countStyle: .file))"
        case .completed(let path):
            completed += 1
            logs.append(TransferLog(text: "完成 · \(path)", warning: false))
        case let .skipped(path, reason):
            skipped += 1
            logs.append(TransferLog(text: "跳过 · \(path) · \(reason)", warning: true))
        case .warning(let message): logs.append(TransferLog(text: message, warning: true))
        }
    }

}
