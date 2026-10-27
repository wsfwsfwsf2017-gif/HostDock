import AppKit
import Foundation
import Testing
@testable import HostDock
@testable import HostDockCore

actor TestGate {
    private var opened = false
    private(set) var entered = false
    func open() { opened = true }
    func close() { opened = false }
    func wait() async throws {
        entered = true
        while !opened { try await Task.sleep(for: .milliseconds(5)) }
        try Task.checkCancellation()
    }
}

struct GatedFileStore: FileStore {
    let base: any FileStore
    let gate: TestGate
    let readGate: TestGate?
    init(base: any FileStore = LocalFileStore(), gate: TestGate, readGate: TestGate? = nil) { self.base = base; self.gate = gate; self.readGate = readGate }
    func canonicalDirectory(at path: String) async throws -> String { try await base.canonicalDirectory(at: path) }
    func list(at path: String) async throws -> [FileEntry] { try await base.list(at: path) }
    func metadata(at path: String) async throws -> FileEntry? { try await base.metadata(at: path) }
    func createDirectory(at path: String) async throws { try await base.createDirectory(at: path) }
    func move(from: String, to: String) async throws { try await base.move(from: from, to: to) }
    func removeFile(at path: String) async throws { try await base.removeFile(at: path) }
    func removeEmptyDirectory(at path: String) async throws { try await base.removeEmptyDirectory(at: path) }
    func setPermissions(_ permissions: UInt32, at path: String) async throws { try await base.setPermissions(permissions, at: path) }
    func openReader(at path: String) async throws -> any FileReader {
        let reader = try await base.openReader(at: path)
        if let readGate { return GatedReader(base: reader, gate: readGate) }
        return reader
    }
    func createWriter(at path: String) async throws -> any FileWriter {
        GatedWriter(base: try await base.createWriter(at: path), gate: gate)
    }
}

private struct GatedReader: FileReader {
    let base: any FileReader
    let gate: TestGate
    func read(upToCount count: Int) async throws -> Data { try await gate.wait(); return try await base.read(upToCount: count) }
    func close() async throws { try await base.close() }
}

private struct GatedWriter: FileWriter {
    let base: any FileWriter
    let gate: TestGate
    func write(_ data: Data) async throws { try await base.write(data); try await gate.wait() }
    func close() async throws { try await base.close() }
}

actor FakeSessionConnection: SessionConnection {
    let store: any FileStore
    let home: String
    let requiresTrust: Bool
    let connectionGate: TestGate?
    private(set) var connects = 0
    private(set) var usernames: [String] = []
    private(set) var endpoints: [ConnectionEndpoint] = []
    private(set) var authenticationSecrets: [String?] = []
    private(set) var failure: SSHConnectionFailure?
    func configureFailure(_ failure: SSHConnectionFailure?) { self.failure = failure }
    private(set) var connected = false
    private(set) var inputs: [Data] = []
    private(set) var sizes: [(Int, Int)] = []
    private var executionGate: TestGate?
    private var executionResult = SSHCommandResult(stdout: Data("synthetic-result".utf8))
    private(set) var commands: [String] = []
    func configureExecution(gate: TestGate? = nil, result: SSHCommandResult? = nil) {
        executionGate = gate
        if let result { executionResult = result }
    }
    func execute(_ command: String, timeout: Double) async throws -> SSHCommandResult {
        guard connected else { throw ControlFailure("SESSION_OFFLINE", "测试连接已断开") }
        commands.append(command)
        try await executionGate?.wait()
        try Task.checkCancellation()
        return executionResult
    }
    private var output: AsyncStream<Data>.Continuation?
    private var disconnectHandler: (@Sendable () async -> Void)?

    init(home: String, store: any FileStore = LocalFileStore(), requiresTrust: Bool = false, connectionGate: TestGate? = nil,
         failure: SSHConnectionFailure? = nil) {
        self.home = home; self.store = store; self.requiresTrust = requiresTrust; self.connectionGate = connectionGate
        self.failure = failure
    }
    func connect(host: String, port: Int, username: String, authentication: SSHAuthentication,
                 verifyHostKey: @escaping @Sendable (HostKeyChallenge) async -> Bool,
                 onDisconnect: @escaping @Sendable () async -> Void) async throws -> (store: any FileStore, home: String) {
        connects += 1
        usernames.append(username)
        endpoints.append(ConnectionEndpoint(host: host, port: port, username: username))
        switch authentication { case .password(let value): authenticationSecrets.append(value); case .rsaKey(_, let phrase): authenticationSecrets.append(phrase) }
        if let failure { throw failure }
        if requiresTrust {
            let accepted = await verifyHostKey(HostKeyChallenge(host: host, port: port, algorithm: "test-only",
                                                               fingerprint: "SHA256:synthetic-\(host)"))
            guard accepted else { throw HostDockError("测试指纹未获信任") }
        }
        try Task.checkCancellation()
        connected = true
        disconnectHandler = onDisconnect
        try await connectionGate?.wait()
        try Task.checkCancellation()
        return (store, home)
    }
    func disconnect() { connected = false; output?.finish(); output = nil }
    func runTerminal(columns: Int, rows: Int, onReady: @escaping @Sendable () async -> Void,
                     onOutput: @escaping @Sendable (Data) async -> Void) async throws {
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        output = continuation
        await onReady()
        for await data in stream { await onOutput(data) }
    }
    func writeTerminal(_ data: Data) { inputs.append(data); output?.yield(data) }
    func resizeTerminal(columns: Int, rows: Int) { sizes.append((columns, rows)) }
    func emit(_ text: String) { output?.yield(Data(text.utf8)) }
    func drop() async { disconnect(); await disconnectHandler?() }
}

@MainActor
struct SessionFixture {
    let root: URL
    let profiles: [ConnectionProfile]
    init() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        root = FileManager.default.temporaryDirectory.appendingPathComponent("hostdock-sessions-\(UUID())")
        var profiles: [ConnectionProfile] = []
        for index in 0..<2 {
            let local = root.appendingPathComponent("local\(index)")
            let remote = root.appendingPathComponent("remote\(index)")
            try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
            try Data("from-local-\(index)".utf8).write(to: local.appendingPathComponent("payload.txt"))
            try Data("from-remote-\(index)".utf8).write(to: remote.appendingPathComponent("payload.txt"))
            profiles.append(ConnectionProfile(name: index == 0 ? "云服务器" : "开发环境",
                endpoint: ConnectionEndpoint(host: "session-\(index)-\(UUID()).example", port: 22, username: "tester"),
                localStartDirectory: local.path, remoteStartDirectory: remote.path))
        }
        self.profiles = profiles
    }
    func remote(_ index: Int) -> String { profiles[index].remoteStartDirectory! }
    func clean() { try? FileManager.default.removeItem(at: root) }
    func app(transports: [FakeSessionConnection], storage: MemoryConnectionStorage? = nil, credentials: any CredentialStore = MemoryCredentialStore(), editors: RemoteEditors? = nil) -> AppModel {
        var index = 0
        return AppModel(catalog: ConnectionCatalog(storage: storage ?? MemoryConnectionStorage(ConnectionDocument(profiles: profiles))),
                        credentials: credentials, editors: editors, makeConnection: {
                            guard index < transports.count else {
                                Issue.record("测试没有配置所需的连接替身")
                                return FakeSessionConnection(home: remote(0), failure: .network)
                            }
                            defer { index += 1 }; return transports[index]
                        })
    }
}

@MainActor
func waitForReservations(_ reservations: TransferReservations, active: Int? = nil, waiting: Int? = nil) async throws {
    for _ in 0..<400 {
        let a = await reservations.activeCount
        let w = await reservations.waitingCount
        if (active == nil || active == a) && (waiting == nil || waiting == w) { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw HostDockError("等待目标路径预约超时")
}
