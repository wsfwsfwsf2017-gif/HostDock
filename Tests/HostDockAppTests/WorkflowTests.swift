import AppKit
import Foundation
import HostDockCore
import Testing
@testable import HostDock

private actor PausedCredentialStore: CredentialStore {
    let gate: TestGate
    var value: String?
    init(gate: TestGate) { self.gate = gate }
    func read(account: String) -> String? { value }
    func save(_ password: String, account: String) async throws {
        try await gate.wait()
        try Task.checkCancellation()
        value = password
    }
    func remove(account: String) { value = nil }
}

@MainActor
@Test func closingPickerDuringCredentialSaveCannotPublishLateConnectionOrRecord() async throws {
    let f = try SessionFixture()
    defer { f.clean() }
    let gate = TestGate()
    let credentials = PausedCredentialStore(gate: gate)
    let app = AppModel(catalog: ConnectionCatalog(storage: MemoryConnectionStorage()), credentials: credentials,
                       makeConnection: { FakeSessionConnection(home: f.remote(0)) })
    app.showConnections()
    let session = try app.connectFromPicker(profile: f.profiles[0], password: "synthetic", rememberPassword: true)
    for _ in 0..<400 {
        if await gate.entered { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await gate.entered)
    #expect(!session.connected && session.connecting)
    app.connectionPickerPresented = false
    try await waitUntil { !app.pickerCancelling }
    await gate.open()
    #expect(app.sessions.isEmpty && app.catalog.profiles.isEmpty)
    #expect(await credentials.value == nil)
    #expect(!session.connected)
    await app.shutdown()
}

@MainActor
@Test func verifiedSavedConnectionRestartsWithoutAskingForPassword() async throws {
    let f = try SessionFixture()
    defer { f.clean() }
    let storage = MemoryConnectionStorage()
    let credentials = MemoryCredentialStore()
    let transport = FakeSessionConnection(home: f.remote(0))
    let app = AppModel(catalog: ConnectionCatalog(storage: storage), credentials: credentials, makeConnection: { transport })
    var profile = f.profiles[0]
    profile.endpoint.username = "姓名@ssta@192.0.2.123"
    let first = try app.connect(profile: profile, password: "synthetic", rememberPassword: true)
    try await waitUntil { first.connected && !first.connecting }
    await app.refreshSavedConnections()
    #expect(app.savedProfiles.count == 1 && app.savedProfiles.first?.id == profile.id)
    #expect(await transport.usernames == [profile.endpoint.username])
    await app.shutdown()
    let next = FakeSessionConnection(home: f.remote(0))
    let restarted = AppModel(catalog: ConnectionCatalog(storage: storage), credentials: credentials, makeConnection: { next })
    await restarted.refreshSavedConnections()
    let saved = try #require(restarted.savedProfiles.first)
    restarted.showConnections()
    let second = try restarted.connectFromPicker(profile: saved, password: nil, rememberPassword: true)
    try await waitUntil { second.connected && !second.connecting }
    #expect(!second.passwordRequired && !restarted.connectionPickerPresented)
    await restarted.shutdown()
}

@MainActor
@Test func failedAndTemporaryConnectionsNeverBecomeOneClickSavedRecords() async throws {
    let f = try SessionFixture()
    defer { f.clean() }
    for failure in [SSHConnectionFailure.network, .authentication, .sftp] {
        let app = AppModel(catalog: ConnectionCatalog(storage: MemoryConnectionStorage()), credentials: MemoryCredentialStore(),
                           makeConnection: { FakeSessionConnection(home: f.remote(0), failure: failure) })
        let session = try app.connect(profile: f.profiles[0], password: "synthetic", rememberPassword: true)
        try await waitUntil { !session.connecting }
        #expect(!session.passwordRequired && session.connectionError != nil)
        #expect(app.catalog.profiles.isEmpty && app.catalog.recent.isEmpty)
        await app.shutdown()
    }
    let app = AppModel(catalog: ConnectionCatalog(storage: MemoryConnectionStorage()), credentials: MemoryCredentialStore(),
                       makeConnection: { FakeSessionConnection(home: f.remote(0)) })
    let session = try app.connect(profile: f.profiles[0], password: "synthetic", rememberPassword: false)
    try await waitUntil { session.connected && !session.connecting }
    #expect(app.catalog.profiles.isEmpty && app.catalog.recent.count == 1)
    await app.shutdown()
}

@MainActor
@Test func credentialWriteFailureKeepsLiveConnectionButDoesNotClaimSaved() async throws {
    let f = try SessionFixture()
    defer { f.clean() }
    let credentials = MemoryCredentialStore()
    await credentials.rejectWrites()
    let app = AppModel(catalog: ConnectionCatalog(storage: MemoryConnectionStorage()), credentials: credentials,
                       makeConnection: { FakeSessionConnection(home: f.remote(0)) })
    let session = try app.connect(profile: f.profiles[0], password: "synthetic", rememberPassword: true)
    try await waitUntil { session.connected && !session.connecting }
    #expect(session.credentialNotice != nil && app.catalog.profiles.isEmpty && app.savedProfiles.isEmpty)
    await app.shutdown()
}

@MainActor
@Test func temporaryKeyConnectionNeverSavesOrRemovesAnExistingAuthentication() async throws {
    let f = try SessionFixture()
    defer { f.clean() }
    for hasOriginal in [false, true] {
        var original = try f.profiles[0].validated()
        original.lastValidatedAt = Date()
        let catalog = ConnectionCatalog(storage: MemoryConnectionStorage(ConnectionDocument(profiles: hasOriginal ? [original] : [])))
        let credentials = MemoryCredentialStore()
        if hasOriginal { try await credentials.save("old-synthetic", account: original.credentialAccount) }
        let app = AppModel(catalog: catalog, credentials: credentials, makeConnection: { FakeSessionConnection(home: f.remote(0)) })
        var temporary = original
        temporary.authenticationKind = .rsaKey
        temporary.privateKeyPath = f.remote(0) + "/payload.txt"
        let session = try app.connect(profile: temporary, password: nil, rememberPassword: false)
        try await waitUntil { !session.connecting }
        #expect(session.connected && catalog.recent.count == 1)
        #expect(catalog.profiles == (hasOriginal ? [original] : []))
        #expect(try await credentials.read(account: original.credentialAccount) == (hasOriginal ? "old-synthetic" : nil))
        await app.shutdown()

        temporary.rememberPassword = false
        let optedOut = AppModel(catalog: ConnectionCatalog(storage: MemoryConnectionStorage(ConnectionDocument(profiles: [temporary]))), credentials: credentials)
        await optedOut.refreshSavedConnections()
        #expect(optedOut.savedProfiles.isEmpty)
        await optedOut.shutdown()
    }
}

@MainActor
@Test func authenticationReplacementCommitsOnlyAfterLoginAndCredentialPersistence() async throws {
    let f = try SessionFixture()
    defer { f.clean() }
    for scenario in ["authentication failure", "credential failure", "success"] {
        var original = try f.profiles[0].validated()
        original.lastValidatedAt = Date()
        let catalog = ConnectionCatalog(storage: MemoryConnectionStorage(ConnectionDocument(profiles: [original])))
        let credentials = MemoryCredentialStore()
        try await credentials.save("old-synthetic", account: original.credentialAccount)
        if scenario == "credential failure" { await credentials.rejectWrites() }
        let app = AppModel(catalog: catalog, credentials: credentials,
            makeConnection: { FakeSessionConnection(home: f.remote(0), failure: scenario == "authentication failure" ? .authentication : nil) })
        var changed = original
        changed.endpoint.username = "姓名@ssta@192.0.2.123"
        let session = try app.connect(profile: changed, password: "new-synthetic", rememberPassword: true)
        try await waitUntil { !session.connecting }
        let saved = try #require(catalog.profiles.first)
        #expect(saved.id == original.id)
        if scenario == "success" {
            #expect(saved.endpoint == changed.endpoint && saved.lastValidatedAt != nil)
            #expect(try await credentials.read(account: original.credentialAccount) == nil)
            #expect(try await credentials.read(account: changed.credentialAccount) == "new-synthetic")
        } else {
            #expect(saved == original)
            #expect(try await credentials.read(account: original.credentialAccount) == "old-synthetic")
            #expect(try await credentials.read(account: changed.credentialAccount) == nil)
        }
        await app.shutdown()
    }
}

@MainActor
@Test func legacyProfilesRemainPendingAndAuthenticationAccountsStayIsolated() async throws {
    let f = try SessionFixture()
    defer { f.clean() }
    let app = f.app(transports: [])
    await app.refreshSavedConnections()
    let pendingIDs = app.pendingProfiles.map { $0.id.uuidString }.sorted()
    let expectedIDs = f.profiles.map { $0.id.uuidString }.sorted()
    #expect(app.savedProfiles.isEmpty)
    #expect(pendingIDs == expectedIDs)
    var key = f.profiles[0]
    key.authenticationKind = .rsaKey; key.privateKeyPath = "~/.ssh/example"
    #expect(key.credentialAccount != f.profiles[0].credentialAccount)
    let original = key.credentialAccount
    key.localStartDirectory = "/tmp"; key.remoteStartDirectory = "/tmp"
    #expect(key.credentialAccount == original)
    key.privateKeyPath = "~/.ssh/another"
    #expect(key.credentialAccount != original)
    app.useDraft(f.profiles[0])
    #expect(app.pickerSelection == .new && app.pickerProfile?.id == f.profiles[0].id)
    await app.shutdown()
}

@MainActor
private func editingFixture(gate: TestGate? = nil) async throws -> (SessionFixture, AppModel, SessionModel, EditDraftStore) {
    let f = try SessionFixture()
    let store: any FileStore = gate.map { GatedFileStore(gate: $0) } ?? GatedFileStore(gate: TestGate())
    let transport = FakeSessionConnection(home: f.remote(0), store: gate == nil ? LocalFileStore() : store)
    let app = f.app(transports: [transport])
    let session = try app.connect(profile: f.profiles[0], password: "synthetic", rememberPassword: false)
    try await waitUntil { session.connected && !session.connecting }
    return (f, app, session, EditDraftStore(directory: f.root.appendingPathComponent("drafts")))
}

@MainActor
@Test func editorPreservesUTF8BOMCRLFPermissionsAndRecoversPrivateDrafts() async throws {
    let (f, app, session, drafts) = try await editingFixture()
    defer { f.clean() }
    let file = URL(fileURLWithPath: f.remote(0)).appendingPathComponent("payload.txt")
    let original = Data([0xef, 0xbb, 0xbf]) + Data("第一行\r\n".utf8)
    try original.write(to: file)
    try await LocalFileStore().setPermissions(0o640, at: file.path)
    let doc = try RemoteDocument(session: session, path: file.path, contents: original, drafts: drafts)
    #expect(!doc.isDirty)
    doc.text += "第二行\n"
    try doc.persistDraft()
    let restored = try RemoteDocument(session: session, path: file.path, contents: original, drafts: drafts)
    #expect(restored.text == doc.text && restored.isDirty)
    let draftURL = drafts.directory.appendingPathComponent(doc.key + ".json")
    #expect(try FileManager.default.attributesOfItem(atPath: drafts.directory.path)[.posixPermissions] as? Int == 0o700)
    #expect(try FileManager.default.attributesOfItem(atPath: draftURL.path)[.posixPermissions] as? Int == 0o600)
    #expect(await restored.save())
    #expect(try Data(contentsOf: file) == Data([0xef, 0xbb, 0xbf]) + Data("第一行\r\n第二行\r\n".utf8))
    #expect(try await LocalFileStore().metadata(at: file.path)?.permissions == 0o640)
    #expect(!restored.isDirty && !FileManager.default.fileExists(atPath: draftURL.path))
    await app.shutdown()
}

@MainActor
@Test func editorDetectsExternalChangesAndKeepsNewEditsDuringUpload() async throws {
    let gate = TestGate()
    let (f, app, session, drafts) = try await editingFixture(gate: gate)
    defer { f.clean() }
    let file = URL(fileURLWithPath: f.remote(0)).appendingPathComponent("payload.txt")
    let original = try Data(contentsOf: file)
    let doc = try RemoteDocument(session: session, path: file.path, contents: original, drafts: drafts)
    doc.text = "first upload\n"
    let save = Task { await doc.save() }
    try await waitUntil { session.transferring }
    doc.text = "newer edit\n"
    await gate.open()
    #expect(await save.value)
    #expect(doc.isDirty && doc.text == "newer edit\n")
    #expect(try String(contentsOf: file, encoding: .utf8) == "first upload\n")
    try Data("changed externally".utf8).write(to: file)
    #expect(await !doc.save())
    #expect(doc.conflict && doc.isDirty)
    #expect(try String(contentsOf: file, encoding: .utf8) == "changed externally")
    #expect(await doc.save(overwrite: true))
    #expect(!doc.isDirty)
    await app.shutdown()
    doc.text = "offline draft"
    #expect(await !doc.save())
    #expect(doc.isDirty)
    try doc.persistDraft()
}

@MainActor
@Test func menusAndClipboardPreserveSourceOnSkipAndRejectSelfCopies() async throws {
    let (f, app, session, _) = try await editingFixture()
    defer { f.clean() }
    let actions = FileActions(session: session, remote: false)
    let entry = try #require(session.local.roots.first?.entry)
    let menu = actions.menu(entries: [entry], directory: session.local.path, window: nil)
    #expect(menu.items.contains { $0.title == "上传到服务器当前目录" && $0.isEnabled })
    #expect(menu.items.contains { $0.title == "重命名" && $0.isEnabled })
    let empty = actions.menu(entries: [], directory: session.local.path, window: nil)
    #expect(empty.items.contains { $0.title == "新建文件夹" && $0.isEnabled })
    #expect(empty.items.contains { $0.title == "重命名" && !$0.isEnabled })
    await #expect(throws: HostDockError.self) {
        try await actions.copy([entry], toRemote: false, directory: session.local.path, cut: false)
    }
    let move = Task { try await actions.copy([entry], toRemote: true, directory: session.remote.path, cut: true) }
    try await waitUntil { session.conflictRequest != nil }
    session.finishConflict(.skip)
    await #expect(throws: HostDockError.self) { try await move.value }
    #expect(FileManager.default.fileExists(atPath: entry.path))
    try actions.putClipboard([entry], cut: false)
    #expect(FileClipboard.shared.item?.entries == [entry])
    FileClipboard.shared.item = nil
    await app.shutdown()
}
