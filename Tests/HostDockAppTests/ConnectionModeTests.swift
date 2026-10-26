import Foundation
import HostDockCore
import Testing
@testable import HostDock

private func jumpProfile() -> ConnectionProfile {
    ConnectionProfile(name: "网关资产", endpoint: ConnectionEndpoint(host: "gateway.example", port: 2222, username: "stale"),
        connectionMode: .jumpServer,
        jumpServer: JumpServerConfiguration(username: "张三", targetUsername: "deploy", targetHost: "192.0.2.123"))
}

@Test func connectionModeDefaultsAndSwitchesKeepInputsButClearSecret() throws {
    var draft = ConnectionFormDraft(sampleProfile())
    var secret = "synthetic"
    #expect(draft.profile.connectionMode == .direct && draft.profile.authenticationKind == .password && draft.port == "22")
    draft.jumpServer = jumpProfile().jumpServer!
    draft.changeMode(to: .jumpServer, secret: &secret)
    #expect(secret.isEmpty && draft.port == "2222" && draft.profile.authenticationKind == .rsaKey)
    #expect(draft.profile.name == sampleProfile().name && draft.profile.endpoint.host == sampleProfile().endpoint.host)
    draft.profile.privateKeyPath = "~/.ssh/example"
    #expect(try draft.validated().endpoint.username == "张三@deploy@192.0.2.123")
    draft.port = "2200"
    secret = "another-synthetic"
    draft.changeMode(to: .direct, secret: &secret)
    #expect(secret.isEmpty && draft.port == "2200" && draft.profile.authenticationKind == .password)
    #expect(try draft.validated().endpoint.username == sampleProfile().endpoint.username)
    #expect(try draft.validated().privateKeyPath == nil && draft.profile.privateKeyPath != nil)
    draft.changeMode(to: .jumpServer, secret: &secret)
    #expect(draft.jumpServer == jumpProfile().jumpServer && draft.port == "2200")
    draft.port = "0"
    #expect(throws: (any Error).self) { try draft.validated() }
}

@Test func jumpServerUsesOnlyGatewayAndPreservesUnicodeUsername() throws {
    let profile = try jumpProfile().validated()
    #expect(profile.endpoint == ConnectionEndpoint(host: "gateway.example", port: 2222, username: "张三@deploy@192.0.2.123"))
    var email = jumpProfile()
    email.jumpServer?.username = "张三@example.org"
    #expect(try email.validated().endpoint.username == "张三@example.org@deploy@192.0.2.123")
    for ip in ["", "https://asset.example", "192.0.2.123:22", "192.0.2.123\nignored", "../tmp"] {
        var invalid = jumpProfile()
        invalid.jumpServer?.targetHost = ip
        #expect(throws: (any Error).self) { try invalid.validated() }
    }
    var missing = jumpProfile()
    missing.jumpServer = nil
    #expect(throws: (any Error).self) { try missing.validated() }
    var url = jumpProfile()
    url.endpoint.host = "https://gateway.example"
    #expect(throws: (any Error).self) { try url.validated() }
}

@MainActor
@Test func oldProfilesStayDirectAndUpgradeBacksUpWithoutChangingCredentialIdentity() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hostdock-modes-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("connections.json")
    let current = try jumpProfile().validated()
    var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any])
    json.removeValue(forKey: "connectionMode"); json.removeValue(forKey: "jumpServer")
    let oldBytes = try JSONSerialization.data(withJSONObject: ["version": 2, "profiles": [json], "recent": []])
    try oldBytes.write(to: url)
    let storage = FileConnectionStorage(url: url)
    let catalog = ConnectionCatalog(storage: storage)
    let old = try #require(catalog.profiles.first)
    #expect(old.connectionMode == .direct && old.jumpServer == nil)
    #expect(old.endpoint.username == current.endpoint.username)
    #expect(old.id == current.id && old.credentialAccount == current.credentialAccount)
    try catalog.save(current)
    let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("connections-v2-") }
    #expect(backups.count == 1)
    #expect(try Data(contentsOf: #require(backups.first)) == oldBytes)
    #expect(try storage.load().version == 5)
    #expect(ConnectionCatalog(storage: storage).profiles.first == current)
    #expect((try FileManager.default.attributesOfItem(atPath: backups[0].path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    try catalog.save(current)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 2)
}

@MainActor
@Test func jumpHistoryRestoresModeAuthenticationAndResolvedIdentity() throws {
    let storage = MemoryConnectionStorage()
    let catalog = ConnectionCatalog(storage: storage)
    var profile = jumpProfile()
    profile.authenticationKind = .rsaKey; profile.privateKeyPath = "~/.ssh/example"
    try catalog.recordSuccess(profile: profile)
    let reopened = ConnectionCatalog(storage: storage)
    let recent = try #require(reopened.recent.first)
    let app = AppModel(catalog: reopened, credentials: MemoryCredentialStore())
    app.selectPickerTab(.recent)
    let draft = try #require(app.pickerProfile)
    #expect(draft.connectionMode == .jumpServer && draft.jumpServer == profile.jumpServer)
    #expect(draft.authenticationKind == .rsaKey && draft.privateKeyPath == profile.privateKeyPath)
    #expect(draft.endpoint.username == "张三@deploy@192.0.2.123" && recent.id == draft.endpoint.identity)
    #expect(draft.lastValidatedAt == nil && reopened.profiles.isEmpty)
    try catalog.recordSuccess(profile: profile)
    #expect(catalog.recent.count == 1)
}

@MainActor
@Test func gatewayProfileReconnectsExactTabAndCancelsWithResolvedEndpoint() async throws {
    let fixture = try SessionFixture()
    defer { fixture.clean() }
    let transport = FakeSessionConnection(home: fixture.remote(0))
    let app = AppModel(catalog: ConnectionCatalog(storage: MemoryConnectionStorage()), credentials: MemoryCredentialStore(), makeConnection: { transport })
    var profile = jumpProfile()
    profile.localStartDirectory = fixture.profiles[0].localStartDirectory
    app.showConnections()
    let session = try app.connectFromPicker(profile: profile, password: "synthetic", rememberPassword: false)
    try await waitUntil { session.connected && !session.connecting }
    #expect(await transport.endpoints == [try profile.validated().endpoint])
    #expect(!app.connectionPickerPresented && app.selectedSession === session)
    let request = app.maximizeRequest
    app.showConnection(session)
    var equivalent = profile
    equivalent.id = UUID(); equivalent.endpoint.username = "different-stale-value"
    let reused = try app.connectFromPicker(profile: equivalent, password: nil, rememberPassword: false)
    #expect(reused === session && app.sessions.count == 1 && app.maximizeRequest == request)
    #expect(await transport.connects == 1)
    await session.shutdown()
    app.showConnection(session)
    // 重连绑定原 Tab，最终组合用户名仍由 JumpServer 配置生成。
    let reconnect = try app.connectFromPicker(profile: equivalent, password: "synthetic", rememberPassword: false)
    #expect(reconnect === session)
    app.connectionPickerPresented = false
    try await waitUntil { !app.pickerCancelling }
    #expect(app.sessions.contains { $0.id == session.id })
    await app.shutdown()
}

@MainActor
@Test func failedJumpIdentityEditPreservesPreviouslySavedAuthentication() async throws {
    let fixture = try SessionFixture()
    defer { fixture.clean() }
    var original = try jumpProfile().validated()
    original.lastValidatedAt = Date()
    let storage = MemoryConnectionStorage(ConnectionDocument(profiles: [original]))
    let credentials = MemoryCredentialStore()
    try await credentials.save("synthetic-old", account: original.credentialAccount)
    let app = AppModel(catalog: ConnectionCatalog(storage: storage), credentials: credentials,
        makeConnection: { FakeSessionConnection(home: fixture.remote(0), failure: .authentication) })
    var edited = original
    edited.jumpServer?.targetHost = "192.0.2.124"
    app.showConnections()
    let session = try app.connectFromPicker(profile: edited, password: "synthetic-new", rememberPassword: true)
    try await waitUntil { !session.connecting }
    #expect(!session.connected && app.connectionPickerPresented)
    #expect(app.catalog.profiles == [original])
    #expect(try await credentials.read(account: original.credentialAccount) == "synthetic-old")
    #expect(try await credentials.read(account: edited.validated().credentialAccount) == nil)
    await app.shutdown()
}
