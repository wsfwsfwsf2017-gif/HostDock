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
    let fileQueue = FileOperationQueue()
    @Published var queueExpanded = true
    @Published var queueHeight: CGFloat = 180
    @Published private(set) var recoveringFiles = false
    @Published private(set) var filesHealthy = true
    private var sessionStore: SessionFileStore?
    private var recoveryTask: Task<Void, Error>?
    private var healthTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    private var recoveringFullConnection = false
    private var executingFileOperation = false
    private var probingFiles = false
    private var probeTask: Task<Void, Never>?
    var connectionIndicatorHealthy: Bool { connected && filesHealthy && !recoveringFiles }

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

    var busy: Bool { connecting || disconnecting || transferring || recoveringFiles }
    var connectionGeneration: UUID { session }
    var verifiedRemoteIdentity: String { profile.endpoint.identity + ":" + (acceptedFingerprint ?? "") }
    var needsAttention: Bool { fileQueue.paused || hostTrustRequest != nil || conflictRequest != nil || passwordRequired || connectionError != nil }
    var needsAuthentication: Bool {
        passwordRequired || connectionFailure == .authentication || connectionFailure == .keyFile
            || connectionFailure == .keyFormat || connectionFailure == .keyPassphrase
    }
    var status: String {
        if recoveringFiles { return "正在恢复连接" }
        if !filesHealthy && connected { return "文件连接不可用" }
        if disconnecting { return "正在断开" }
        if hostTrustRequest != nil { return "确认指纹" }
        if conflictRequest != nil { return "确认同名文件" }
        if waitingForTarget { return "等待目标释放" }
        if fileQueue.paused { return "操作待处理" }
        if transferring { return "文件操作中" }
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
        remote.prepareRead = { [weak self] in
            guard let self else { throw CancellationError() }
            if !self.connecting && self.sessionStore != nil && (!self.connected || !self.filesHealthy) {
                try await self.recoverFiles(); return true
            }
            return false
        }
        remote.recoverRead = { [weak self] error in
            guard let self, error is FileConnectionFailure else { return false }
            try await self.recoverFiles()
            return true
        }
        fileQueue.changed = { [weak self] in
            guard let self else { return }
            self.transferring = self.fileQueue.hasWork
        }
        fileQueue.cancellingActive = { [weak self] in self?.finishConflict(.cancel) }
        fileQueue.finished = { [weak self] in self?.scheduleFileRefresh() }
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
                filesHealthy = true
                let storeToken = session
                let bound = SessionFileStore(result.store) { [weak self] error in await self?.fileAccessFailed(error, generation: storeToken) }
                sessionStore = bound
                remoteLabel = profile.name
                await local.attach(store: localStore, home: NSHomeDirectory(), initialDirectory: profile.localStartDirectory)
                guard attempt == token, !Task.isCancelled else { return }
                await remote.attach(store: bound, home: result.home, initialDirectory: profile.remoteStartDirectory)
                guard attempt == token, !Task.isCancelled else { return }
                if profile.connectionMode == .jumpServer, remote.path == "/", remote.error == nil,
                   let asset = remote.roots.first(where: { $0.entry.kind == .directory && $0.entry.name == profile.targetHost }) {
                    await remote.attach(store: bound, home: result.home, initialDirectory: asset.entry.path)
                    guard attempt == token, !Task.isCancelled else { return }
                    if remote.error == nil,
                       let account = remote.roots.first(where: { $0.entry.kind == .directory && $0.entry.name == profile.targetUsername }) {
                        await remote.attach(store: bound, home: result.home, initialDirectory: account.entry.path)
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
                    startHealthChecks()
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

    private func fileAccessFailed(_ error: Error, generation: UUID? = nil) {
        if let generation, generation != session { return }
        filesHealthy = false
        remote.markUnavailable(error)
        connectionError = error.localizedDescription
    }

    func checkFileHealth() async {
        guard connected, !connecting, !disconnecting, !recoveringFiles, !fileQueue.hasWork, !remote.loading, !probingFiles else { return }
        let token = session
        probingFiles = true
        let task = Task { [self] in
            let span = diagnostics.begin(.fileProbe, id: id, origin: diagnosticOrigin)
            defer { probingFiles = false; probeTask = nil }
            do { try await connection.checkFiles(); diagnostics.finish(span) }
            catch {
                diagnostics.finish(span, failure: .classify(error))
                guard session == token, !Task.isCancelled else { return }
                if error is FileConnectionFailure { fileAccessFailed(error) }
            }
        }
        probeTask = task
        await task.value
    }

    private func startHealthChecks() {
        healthTask?.cancel()
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                guard let self else { return }
                await self.checkFileHealth()
            }
        }
        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.checkFileHealth() }
            }
        }
    }

    func recoverFiles() async throws {
        if let probeTask { await probeTask.value }
        if let recoveryTask {
            return try await withTaskCancellationHandler { try await recoveryTask.value } onCancel: { recoveryTask.cancel() }
        }
        guard !disconnecting, let sessionStore else { throw FileConnectionFailure.closed }
        // Never replace a channel underneath a mutation or its cleanup.
        guard !executingFileOperation else { throw HostDockError("文件操作尚未完成，请等待清理后刷新。") }
        let token = session
        recoveringFiles = true; filesHealthy = false
        let task = Task { [self] in
            let span = diagnostics.begin(.fileRecovery, id: id, origin: diagnosticOrigin)
            var failure: Error?
            defer {
                recoveringFiles = false
                recoveryTask = nil
                diagnostics.finish(span, failure: failure.map(DiagnosticFailure.classify))
            }
            do {
                var repaired: (store: any FileStore, home: String)?
                if connected {
                    do { repaired = try await connection.repairFiles() }
                    catch is CancellationError { throw CancellationError() }
                    catch {
                        if Task.isCancelled { throw CancellationError() }
                        guard error is FileConnectionFailure else { throw error }
                    }
                }
                if repaired == nil {
                    recoveringFullConnection = true
                    defer { recoveringFullConnection = false; connecting = false }
                    try Task.checkCancellation()
                    attempt = UUID()
                    let attemptID = attempt
                    terminalInputTask?.cancel(); terminalTask?.cancel()
                    terminal.ready = false; terminalReady = false; terminalRunning = false; terminal.onInput = nil
                    await connection.disconnect()
                    await terminalTask?.value
                    terminalTask = nil
                    connected = false
                    let original = profile
                    let resolved = try catalog.resolve(original)
                    guard resolved.profile.endpoint == original.endpoint else { throw HostDockError("保存的服务器身份已变化，请手动重新连接。") }
                    var secret: String?
                    for account in catalog.authenticationAccounts(profile: original, access: resolved.access) {
                        if let value = try await credentials.read(account: account) { secret = value; break }
                    }
                    let authentication: SSHAuthentication
                    if original.authenticationKind == .password {
                        guard let secret else { passwordRequired = true; throw HostDockError("未保存连接认证，请通过修改认证补全。") }
                        authentication = .password(secret)
                    } else {
                        if original.keyRequiresPassphrase && secret == nil { passwordRequired = true; throw SSHConnectionFailure.keyPassphrase }
                        authentication = .rsaKey(path: original.privateKeyPath ?? "", passphrase: secret)
                    }
                    try Task.checkCancellation()
                    connecting = true
                    repaired = try await connection.connect(host: original.endpoint.host, port: original.endpoint.port,
                        username: original.endpoint.username, authentication: authentication,
                        verifyHostKey: { [weak self] challenge in await self?.verify(challenge, attempt: attemptID) ?? false },
                        onDisconnect: { [weak self] in await self?.connectionDropped(attempt: attemptID) })
                    try Task.checkCancellation()
                    guard session == token, !disconnecting else { throw CancellationError() }
                    connected = true
                    if origin == .interactive { terminal.message("连接已恢复，未重放之前的命令。"); startTerminal() }
                }
                try Task.checkCancellation()
                guard session == token, !disconnecting, let repaired else { throw CancellationError() }
                await sessionStore.replace(repaired.store)
                filesHealthy = true; connected = true
                remote.markAvailable()
                connectionError = nil; connectionFailure = nil; passwordRequired = false
                fileQueue.resumeWhenSafe()
            } catch {
                failure = error
                fileAccessFailed(error)
                connectionFailure = error as? SSHConnectionFailure
                finishHostTrust(false)
                throw error
            }
        }
        recoveryTask = task
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
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
        if recoveringFiles { recoveryTask?.cancel(); finishHostTrust(false); return }
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
        if recoveringFullConnection { return }
        diagnostics.record(.operationFinished, id: id, operation: .disconnect, origin: diagnosticOrigin, failure: .network)
        attempt = UUID()
        connectionTask?.cancel()
        connectionTask = nil
        connecting = false
        connectionError = "连接已断开，请重新连接。"
        finishHostTrust(false)
        if origin == .automation || sessionStore == nil { session = UUID(); remote.clear() }
        connected = false
        filesHealthy = false
        remote.markUnavailable(FileConnectionFailure.closed)
        remoteLabel = "连接已断开"
        if origin == .automation { fileQueue.cancelAll() }
        terminal.ready = false
        terminalReady = false
        terminalRunning = false
        terminal.onInput = nil
        terminalInputTask?.cancel()
        terminalTask?.cancel()
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
        healthTask?.cancel(); healthTask = nil
        probeTask?.cancel(); await probeTask?.value
        refreshTask?.cancel(); refreshTask = nil
        recoveryTask?.cancel()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver); self.wakeObserver = nil }
        finishHostTrust(false)
        attempt = UUID()
        connectionTask?.cancel()
        connectionTask = nil
        fileQueue.cancelAll()
        finishConflict(.cancel)
        terminal.ready = false
        terminalReady = false
        terminal.onInput = nil
        terminalInputTask?.cancel()
        await fileQueue.drain()
        _ = await recoveryTask?.result
        sessionStore = nil
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
        guard connected, !disconnecting, local.directoryReady, remote.directoryReady else { return }
        let browser = upload ? local : remote
        let entries = browser.selectedEntries
        let directory = (upload ? remote : local).path
        guard !entries.isEmpty else { return }
        let token = session
        transferring = true
        Task {
            defer { transferring = fileQueue.hasWork }
            guard token == session, connected, !disconnecting else { return }
            do { try await FileActions(session: self, remote: !upload).copy(entries, toRemote: upload, directory: directory, cut: false) }
            catch { if !(error is CancellationError) { logs.append(TransferLog(text: error.localizedDescription, warning: true)) } }
        }
    }

    func cancelTransfer() {
        guard let id = fileQueue.activeID else { fileQueue.cancelWaiting(); return }
        diagnostics.record(.cancelled, id: self.id, operation: .transfer, origin: diagnosticOrigin, critical: true)
        finishConflict(.cancel)
        fileQueue.cancel(id)
        transferLabel = "正在取消并清理临时文件…"
    }

    func resolve(_ conflict: FileConflict) async -> ConflictDecision {
        guard !Task.isCancelled else { return .cancel }
        return await withCheckedContinuation { continuation in
            conflictDecision = continuation
            conflictRequest = conflict
            fileQueue.update(.confirmation)
        }
    }

    func runFileOperation(_ label: String, localPaths: [String] = [], remotePaths: [String] = [],
                          operation: @escaping @Sendable () async throws -> Void) async throws {
        let token = session
        let identity = verifiedRemoteIdentity
        diagnostics.record(.fileQueued, id: id, operation: .fileOperation, origin: diagnosticOrigin)
        try await fileQueue.submit(label) { [self] in
            let span = diagnostics.begin(.fileOperation, id: id, origin: diagnosticOrigin)
            var failure: Error?
            defer { diagnostics.finish(span, failure: failure.map(DiagnosticFailure.classify)) }
            var acquired = false
            let requestID = UUID()
            do {
                if let refreshTask { refreshTask.cancel(); await refreshTask.value; self.refreshTask = nil }
                if let probeTask { await probeTask.value }
                try Task.checkCancellation()
                guard !disconnecting, session == token else { throw HostDockError("原会话已变化，操作未执行。") }
                if !connected || !filesHealthy { try await recoverFiles() }
                guard verifiedRemoteIdentity == identity, session == token else { throw HostDockError("服务器身份已变化，操作未执行。") }
                let identities = ["remote:\(profile.endpoint.host):\(profile.endpoint.port)"]
                    + (acceptedFingerprint.map { ["hostkey:\($0)"] } ?? [])
                let paths = try localPaths.map { try TransferDestination(storage: "local", path: $0) }
                    + remotePaths.flatMap { path in try identities.map { try TransferDestination(storage: $0, path: path) } }
                transferLabel = label; completed = 0; skipped = 0; progress = 0
                lastProgressUpdate = .distantPast
                logs = [TransferLog(text: label, warning: false)]
                waitingForTarget = true; fileQueue.update(.waiting)
                try await reservations.acquire(paths, id: requestID)
                acquired = true; waitingForTarget = false
                try Task.checkCancellation()
                guard session == token, !disconnecting else { throw HostDockError("原会话已变化，操作未执行。") }
                if !connected || !filesHealthy { try await recoverFiles() }
                guard verifiedRemoteIdentity == identity else { throw HostDockError("服务器身份已变化，操作未执行。") }
                fileQueue.update(.running)
                diagnostics.record(.fileExecuting, id: id, operation: .fileOperation, origin: diagnosticOrigin)
                executingFileOperation = true
                try await operation()
                transferLabel = label.hasPrefix("上传") || label.hasPrefix("下载") ? "传输完成 · 完成 \(completed) 项" : "\(label)完成"
                progress = 1
            } catch {
                failure = error
                if !executingFileOperation && (!connected || !filesHealthy), !Task.isCancelled, !disconnecting, session == token {
                    failure = FileJobDeferred(reason: "操作尚未发送，等待恢复连接。" + error.localizedDescription)
                }
                transferLabel = error is CancellationError ? "已取消 · 已完成的项目保留" : "\(label)失败"
                logs.append(TransferLog(text: error.localizedDescription, warning: true))
                if error is FileConnectionFailure { fileAccessFailed(error) }
            }
            if acquired { await reservations.release(requestID) }
            executingFileOperation = false
            waitingForTarget = false; finishConflict(.cancel)
            if let failure { throw failure }
        }
    }

    func recordDeletion(path: String, finished: Bool) {
        if finished { completed += 1 }
        fileQueue.update(detail: "已完成 \(completed) 项 · " + (finished ? "已删除 " : "等待服务器确认 · ") + URL(fileURLWithPath: path).lastPathComponent)
    }

    private func scheduleFileRefresh() {
        guard !fileQueue.hasWork, !disconnecting, connected else { return }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            guard let self, !self.fileQueue.hasWork, !self.disconnecting else { return }
            let span = self.diagnostics.begin(.fileRefresh, id: self.id, origin: self.diagnosticOrigin)
            await self.local.refresh()
            await self.remote.refresh()
            self.diagnostics.finish(span)
        }
    }

    func finishConflict(_ decision: ConflictDecision) {
        let continuation = conflictDecision
        conflictDecision = nil
        conflictRequest = nil
        fileQueue.update(.running)
        continuation?.resume(returning: decision)
    }

    func record(_ event: TransferEvent) {
        defer { fileQueue.update(detail: logs.last(where: { $0.warning })?.text ?? transferLabel, progress: progress) }
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
