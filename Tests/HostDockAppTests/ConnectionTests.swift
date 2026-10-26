import AppKit
import Foundation
import HostDockCore
import Testing
@testable import HostDock

final class MemoryConnectionStorage: ConnectionStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var document: ConnectionDocument
    var rejectsWrites = false
    init(_ document: ConnectionDocument = ConnectionDocument()) { self.document = document }
    func load() -> ConnectionDocument { lock.withLock { document } }
    func save(_ document: ConnectionDocument) throws {
        try lock.withLock {
            if rejectsWrites { throw HostDockError("模拟磁盘写入失败") }
            self.document = document
        }
    }
}

actor MemoryCredentialStore: CredentialStore {
    private var items: [String: String] = [:]
    private(set) var saves = 0
    private(set) var reads = 0
    var rejectsReads = false
    var rejectsWrites = false
    func rejectReads() { rejectsReads = true }
    func rejectWrites() { rejectsWrites = true }
    func allowWrites() { rejectsWrites = false }
    func read(account: String) throws -> String? {
        reads += 1
        if rejectsReads { throw HostDockError("模拟钥匙串拒绝读取") }
        return items[account]
    }
    func save(_ password: String, account: String) throws {
        if rejectsWrites { throw HostDockError("模拟钥匙串拒绝写入") }
        saves += 1
        items[account] = password
    }
    func remove(account: String) { items.removeValue(forKey: account) }
}

func sampleProfile(_ index: Int = 1) -> ConnectionProfile {
    ConnectionProfile(name: "测试服务器 \(index)", endpoint: ConnectionEndpoint(host: "server\(index).example", port: 22, username: "tester"))
}

@MainActor
@Test func newProfilesDefaultToRememberAndExplicitOptOutStillPersists() throws {
    var profile = sampleProfile()
    #expect(profile.rememberPassword)
    profile.rememberPassword = false
    let storage = MemoryConnectionStorage()
    try ConnectionCatalog(storage: storage).save(profile)
    #expect(ConnectionCatalog(storage: storage).profiles.first?.rememberPassword == false)
}

@MainActor
@Test func profilesPersistWithPrivatePermissionsAndNoSecrets() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("hostdock-records-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("connections.json")
    let storage = FileConnectionStorage(url: url)
    let catalog = ConnectionCatalog(storage: storage)
    #expect(catalog.profiles.isEmpty && catalog.recent.isEmpty)
    var profile = sampleProfile()
    profile.endpoint.host = " SERVER1.example \n"
    profile.endpoint.username = " tester "
    try catalog.save(profile)
    let reopened = ConnectionCatalog(storage: storage)
    #expect(reopened.profiles.first?.endpoint == sampleProfile().endpoint)
    profile.name = "改名"
    profile.rememberPassword = true
    try reopened.save(profile)
    #expect(ConnectionCatalog(storage: storage).profiles.first?.name == "改名")
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
    #expect(!text.contains("synthetic-secret") && !text.contains("\"password\":"))
    try reopened.remove(profile)
    #expect(ConnectionCatalog(storage: storage).profiles.isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["connections.json"])
}

@MainActor
@Test func historyDeduplicatesLimitsAndClearsWithoutRemovingProfiles() throws {
    let storage = MemoryConnectionStorage()
    let catalog = ConnectionCatalog(storage: storage)
    try catalog.save(sampleProfile())
    for index in 1...25 {
        let profile = sampleProfile(index)
        try catalog.recordSuccess(profile: profile, at: Date(timeIntervalSince1970: Double(index)))
    }
    #expect(catalog.recent.count == 20)
    let recent = sampleProfile(12)
    var renamed = recent
    renamed.name = "最近一次"
    try catalog.recordSuccess(profile: renamed, at: Date(timeIntervalSince1970: 30))
    #expect(catalog.recent.count == 20 && catalog.recent.first?.name == "最近一次")
    #expect(catalog.recent.filter { $0.endpoint == recent.endpoint }.count == 1)
    #expect(ConnectionCatalog(storage: storage).recent == catalog.recent)
    try catalog.clearHistory()
    #expect(catalog.recent.isEmpty && catalog.profiles.count == 1)
}

@MainActor
@Test func damagedOrFutureRecordsArePreservedAndWriteFailuresDoNotPublish() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("hostdock-damaged-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("connections.json")
    for raw in ["{bad-json", "{\"version\":99,\"profiles\":[],\"recent\":[]}"] {
        let original = Data(raw.utf8)
        try original.write(to: url)
        let catalog = ConnectionCatalog(storage: FileConnectionStorage(url: url))
        #expect(catalog.loadError != nil)
        #expect(throws: (any Error).self) { try catalog.save(sampleProfile()) }
        #expect(throws: (any Error).self) { try catalog.clearHistory() }
        #expect(try Data(contentsOf: url) == original)
    }
    let storage = MemoryConnectionStorage()
    let catalog = ConnectionCatalog(storage: storage)
    storage.rejectsWrites = true
    #expect(throws: (any Error).self) { try catalog.save(sampleProfile()) }
    #expect(catalog.profiles.isEmpty)
}

@MainActor
@Test func validationRejectsDuplicateTargetsAndInvalidEndpoints() throws {
    let catalog = ConnectionCatalog(storage: MemoryConnectionStorage())
    try catalog.save(sampleProfile())
    #expect(throws: (any Error).self) { try catalog.save(sampleProfile()) }
    for endpoint in [ConnectionEndpoint(host: "", port: 22, username: "u"),
                     ConnectionEndpoint(host: "a b", port: 22, username: "u"),
                     ConnectionEndpoint(host: "host", port: 0, username: "u"),
                     ConnectionEndpoint(host: "host", port: 65536, username: "u"),
                     ConnectionEndpoint(host: "host", port: 22, username: "a\nb")] {
        #expect(throws: (any Error).self) { try endpoint.validated() }
    }
}

@MainActor
@Test func credentialsFollowRecordAndEndpointAndAreDeletedWithProfile() async throws {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    let credentials = MemoryCredentialStore()
    let catalog = ConnectionCatalog(storage: MemoryConnectionStorage())
    let app = AppModel(catalog: catalog, credentials: credentials)
    var original = sampleProfile()
    original.rememberPassword = true
    try catalog.save(original)
    try await credentials.save("synthetic-secret", account: original.credentialAccount)
    for field in 0..<3 {
        var changed = original
        if field == 0 { changed.endpoint.host = "other.example" }
        if field == 1 { changed.endpoint.port = 2222 }
        if field == 2 { changed.endpoint.username = "other" }
        #expect(changed.credentialAccount != original.credentialAccount)
        #expect(try await credentials.read(account: changed.credentialAccount) == nil)
    }
    var changed = original
    changed.endpoint.username = "other"
    await #expect(throws: HostDockError.self) { try await app.saveProfile(changed) }
    #expect(try await credentials.read(account: original.credentialAccount) != nil)
    try catalog.recordSuccess(profile: original)
    try catalog.clearHistory()
    #expect(try await credentials.read(account: original.credentialAccount) != nil)
    try await app.removeProfile(original)
    #expect(try await credentials.read(account: original.credentialAccount) == nil)
    #expect(catalog.profiles.isEmpty)
    var anotherRecord = original
    anotherRecord.id = UUID()
    #expect(anotherRecord.credentialAccount != original.credentialAccount)
}

@MainActor
@Test func deniedOrMissingCredentialsAllowManualInputAndDoNotRecordHistory() async throws {
    let credentials = MemoryCredentialStore()
    var profile = sampleProfile()
    profile.rememberPassword = true
    let catalog = ConnectionCatalog(storage: MemoryConnectionStorage(ConnectionDocument(profiles: [profile])))
    let app = SessionModel(profile: profile, catalog: catalog, credentials: credentials)
    await credentials.rejectReads()
    app.connect(profile: profile, password: nil, rememberPassword: true)
    try await waitUntil { !app.connecting }
    #expect(app.passwordRequired && app.credentialNotice != nil && !app.connected)
    #expect(catalog.recent.isEmpty)
    #expect(await credentials.saves == 0)
    let reads = await credentials.reads
    app.connect(profile: profile, password: nil, rememberPassword: false)
    try await waitUntil { !app.connecting }
    #expect(app.passwordRequired)
    #expect(await credentials.reads == reads)
    await app.shutdown()
}

@MainActor
@Test func failedOrCancelledConnectionNeverSavesCredentialsOrHistory() async throws {
    let credentials = MemoryCredentialStore()
    let catalog = ConnectionCatalog(storage: MemoryConnectionStorage())
    let profile = ConnectionProfile(name: "本机拒绝连接测试", endpoint: ConnectionEndpoint(host: "127.0.0.1", port: 1, username: "synthetic"))
    let app = SessionModel(profile: profile, catalog: catalog, credentials: credentials)
    app.connect(profile: profile, password: "synthetic-secret", rememberPassword: true)
    try await waitUntil { !app.connecting }
    #expect(!app.connected && app.connectionError != nil)
    #expect(catalog.recent.isEmpty && catalog.profiles.isEmpty)
    #expect(await credentials.saves == 0)
    app.connect(profile: profile, password: "synthetic-secret", rememberPassword: true)
    app.cancelConnection()
    try await waitUntil { !app.disconnecting }
    #expect(!app.connected && !app.connecting && !app.passwordRequired)
    #expect(catalog.recent.isEmpty)
    #expect(await credentials.saves == 0)
    await app.shutdown()
}

@MainActor
func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<400 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(25))
    }
    throw HostDockError("等待应用状态超时")
}
