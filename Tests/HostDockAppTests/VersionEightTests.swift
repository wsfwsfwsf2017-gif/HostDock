import AppKit
import Foundation
import HostDockCore
import SwiftUI
import Testing
@testable import HostDock

@MainActor
@Test func selectedFileNameUsesSelectedTextColor() async throws {
    let fixture = try SessionFixture(); defer { fixture.clean() }
    let model = BrowserModel(); await model.attach(store: LocalFileStore(), home: fixture.remote(0))
    let hosting = NSHostingView(rootView: FileBrowserPane(model: model, remote: true, subtitle: "test"))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = hosting
    defer { window.close() }
    try await Task.sleep(for: .milliseconds(100)); hosting.layoutSubtreeIfNeeded()
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    let outline = try #require(descendants(hosting).first { $0 is NSOutlineView } as? NSOutlineView)
    let cell = try #require(outline.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTableCellView)
    cell.backgroundStyle = .emphasized
    #expect(cell.textField?.textColor == NSColor.alternateSelectedControlTextColor)
    let row = try #require(outline.rowView(atRow: 0, makeIfNecessary: true))
    for column in 0..<3 {
        let item = try #require(outline.view(atColumn: column, row: 0, makeIfNecessary: true) as? NSTableCellView)
        item.backgroundStyle = .emphasized
        #expect(item.textField?.textColor == NSColor.alternateSelectedControlTextColor)
        row.isSelected = true; row.isEmphasized = false; item.backgroundStyle = .normal
        #expect(item.textField?.textColor == NSColor.unemphasizedSelectedTextColor)
        row.isSelected = false; item.backgroundStyle = .normal
        #expect(item.textField?.textColor == (column == 0 ? DockTheme.textNS : DockTheme.secondaryNS))
    }
    window.setContentSize(NSSize(width: 300, height: 500)); hosting.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(30)); hosting.layoutSubtreeIfNeeded()
    #expect(outline.tableColumns[1].isHidden && outline.tableColumns[2].isHidden && !outline.tableColumns[0].isHidden)
    window.setContentSize(NSSize(width: 600, height: 500)); hosting.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(30)); hosting.layoutSubtreeIfNeeded()
    #expect(!outline.tableColumns[1].isHidden && !outline.tableColumns[2].isHidden)
}

private func accessFixture() -> JumpServerAccessProfile {
    var access = JumpServerAccessProfile()
    access.host = "gateway.example"; access.username = "张三"; access.privateKeyPath = "~/.ssh/test_rsa"
    access.lastValidatedAt = Date(timeIntervalSince1970: 123)
    return access
}

@MainActor
@Test func compactWorkspaceProposesActualFilePaneWidthToNativeOutline() async throws {
    let fixture = try SessionFixture(); defer { fixture.clean() }
    let app = fixture.app(transports: [FakeSessionConnection(home: fixture.remote(0))])
    let session = try app.connect(profile: fixture.profiles[0], password: "synthetic", rememberPassword: false)
    try await waitUntil { session.connected && !session.connecting }
    app.connectionPickerPresented = false
    let hosting = NSHostingView(rootView: WorkspaceView(app: app))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 620), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = hosting
    defer { window.close() }
    try await Task.sleep(for: .milliseconds(150)); hosting.layoutSubtreeIfNeeded()
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    let outline = try #require(descendants(hosting).compactMap { $0 as? NSOutlineView }.first { outline in
        (outline.item(atRow: 0) as? FileNode)?.entry.path.hasPrefix(fixture.remote(0)) == true
    })
    #expect(outline.enclosingScrollView!.contentSize.width < 340)
    #expect(outline.tableColumns[1].isHidden && outline.tableColumns[2].isHidden)
    await app.shutdown()
}


private func assetFixture(_ index: Int, access: JumpServerAccessProfile) throws -> ConnectionProfile {
    let profile = ConnectionProfile(name: "服务器 \(index)", endpoint: ConnectionEndpoint(host: access.host, port: access.port, username: ""),
        authenticationKind: .rsaKey, privateKeyPath: access.privateKeyPath, lastValidatedAt: access.lastValidatedAt,
        connectionMode: .jumpServer, jumpServer: JumpServerConfiguration(username: access.username, targetUsername: "ssta", targetHost: "192.0.2.\(index + 1)", accessProfileID: access.id))
    return try access.applying(to: profile)
}

@MainActor
@Test func sharedAccessMigrationGroupsOnlyIdenticalAuthenticationAndBacksUpV4() throws {
    let fixture = try SessionFixture(); defer { fixture.clean() }
    let access = accessFixture()
    var first = try assetFixture(0, access: access), second = try assetFixture(1, access: access)
    first.jumpServer?.accessProfileID = nil; second.jumpServer?.accessProfileID = nil
    var different = try assetFixture(2, access: access); different.jumpServer?.accessProfileID = nil; different.privateKeyPath = "~/.ssh/another_rsa"
    let ids = [first.id, second.id, different.id], accounts = [first.credentialAccount, second.credentialAccount, different.credentialAccount]
    first.localStartDirectory = fixture.root.path; first.remoteStartDirectory = "/asset/home"
    var old = ConnectionDocument(profiles: [first, second, different]); old.version = 4
    old.recent = [RecentConnection(name: first.name, endpoint: first.endpoint, lastConnected: Date(), connectionMode: first.connectionMode,
                                  jumpServer: first.jumpServer, authenticationKind: first.authenticationKind, privateKeyPath: first.privateKeyPath)]
    let bytes = try JSONEncoder().encode(old), url = fixture.root.appendingPathComponent("connections.json")
    try bytes.write(to: url)
    let catalog = ConnectionCatalog(storage: FileConnectionStorage(url: url))
    #expect(catalog.loadError == nil && catalog.accessProfiles.count == 2)
    let migrated = catalog.document.profiles
    #expect(migrated.map(\.id) == ids && migrated.map(\.credentialAccount) == accounts)
    #expect(migrated[0].jumpServer?.accessProfileID == migrated[1].jumpServer?.accessProfileID)
    #expect(migrated[0].jumpServer?.accessProfileID != migrated[2].jumpServer?.accessProfileID)
    #expect(migrated[0].localStartDirectory == first.localStartDirectory && migrated[0].remoteStartDirectory == first.remoteStartDirectory)
    #expect(catalog.recent.first?.jumpServer?.accessProfileID == migrated[0].jumpServer?.accessProfileID)
    try catalog.save(migrated[0])
    let backup = try #require(FileManager.default.contentsOfDirectory(at: fixture.root, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("connections-v4-") })
    #expect(try Data(contentsOf: backup) == bytes)
    #expect(ConnectionCatalog(storage: FileConnectionStorage(url: url)).document.version == 5)
}

@MainActor
@Test func firstSharedAccessSavesOnlyAfterSuccessfulAssetConnectionAndReusesSecrets() async throws {
    let fixture = try SessionFixture(); defer { fixture.clean() }
    var access = accessFixture(); access.lastValidatedAt = nil; access.keyRequiresPassphrase = true
    var first = try assetFixture(0, access: access); first.localStartDirectory = fixture.root.path
    let rejected = AppModel(catalog: ConnectionCatalog(storage: MemoryConnectionStorage()), credentials: MemoryCredentialStore(),
                            makeConnection: { FakeSessionConnection(home: fixture.remote(0), failure: .authentication) })
    let bad = try rejected.connect(profile: first, password: "synthetic", rememberPassword: true, accessProfile: access)
    try await waitUntil { !bad.connecting }
    #expect(rejected.catalog.accessProfiles.isEmpty && rejected.catalog.profiles.isEmpty)
    await rejected.shutdown()
    let credentials = MemoryCredentialStore()
    let transports = [FakeSessionConnection(home: fixture.remote(0)), FakeSessionConnection(home: fixture.remote(1))]
    var index = 0
    let app = AppModel(catalog: ConnectionCatalog(storage: MemoryConnectionStorage()), credentials: credentials, makeConnection: { defer { index += 1 }; return transports[index] })
    let a = try app.connect(profile: first, password: "synthetic-phrase", rememberPassword: true, accessProfile: access)
    try await waitUntil { a.connected && !a.connecting }
    #expect(app.catalog.profiles.count == 1 && app.catalog.accessProfiles.count == 1)
    #expect(try await credentials.read(account: access.credentialAccount) == "synthetic-phrase")
    let second = try assetFixture(1, access: access)
    let b = try app.connect(profile: second, password: nil, rememberPassword: true)
    try await waitUntil { b.connected && !b.connecting }
    #expect(await transports[1].authenticationSecrets == ["synthetic-phrase"])
    #expect(await transports[1].usernames == ["张三@ssta@192.0.2.2"])
    #expect(app.catalog.accessProfiles.count == 1 && app.catalog.profiles.count == 2)
    await app.shutdown()
}

@MainActor
@Test func sharedAccessChangesVerifySeparatelyAndOnlyAffectReconnect() async throws {
    let fixture = try SessionFixture(); defer { fixture.clean() }
    let access = accessFixture(); let profile = try assetFixture(0, access: access)
    let catalog = ConnectionCatalog(storage: MemoryConnectionStorage(ConnectionDocument(profiles: [profile], jumpServerAccessProfiles: [access])))
    let transport = FakeSessionConnection(home: fixture.remote(0)), probe = FakeSessionConnection(home: fixture.remote(0))
    var calls = 0
    let app = AppModel(catalog: catalog, credentials: MemoryCredentialStore(), makeConnection: { defer { calls += 1 }; return calls == 0 ? transport : probe })
    let active = try app.connect(profile: profile, password: nil, rememberPassword: true)
    try await waitUntil { active.terminalReady && !active.connecting }
    let history = catalog.recent, location = active.remote.path
    var changed = access; changed.host = "new-gateway.example"; changed.username = "李四"; changed.lastValidatedAt = nil
    try await app.validateAndSaveAccess(changed, asset: profile, password: nil)
    #expect(app.sessions.count == 1 && active.connected && active.terminalReady && active.remote.path == location)
    #expect(active.profile.endpoint.host == access.host && catalog.recent == history)
    #expect(await probe.endpoints.first?.host == changed.host)
    #expect(!(await probe.connected))
    let frame = app.maximizeRequest
    #expect(try app.connect(profile: profile, password: nil, rememberPassword: true, reusing: active) === active && app.maximizeRequest == frame)
    active.disconnect(); try await waitUntil { !active.disconnecting }
    let again = try app.connect(profile: try #require(catalog.profiles.first), password: nil, rememberPassword: true, reusing: active)
    try await waitUntil { again.connected && !again.connecting }
    #expect(again === active && again.profile.id == profile.id)
    #expect(await transport.endpoints.last?.host == changed.host && again.profile.endpoint.username == "李四@ssta@192.0.2.1")
    await app.shutdown()
}

@MainActor
@Test func sharedAccessAuthenticationAndPersistenceFailuresPreserveOldConfiguration() async throws {
    let fixture = try SessionFixture(); defer { fixture.clean() }
    for failure in [true, false] {
        let access = accessFixture(), credentials = MemoryCredentialStore()
        let profile = try assetFixture(0, access: access)
        let storage = MemoryConnectionStorage(ConnectionDocument(profiles: [profile], jumpServerAccessProfiles: [access]))
        let catalog = ConnectionCatalog(storage: storage)
        try await credentials.save("synthetic-old", account: access.credentialAccount)
        let app = AppModel(catalog: catalog, credentials: credentials, makeConnection: { FakeSessionConnection(home: fixture.remote(0), failure: failure ? .authentication : nil) })
        var changed = access; changed.keyRequiresPassphrase = true; changed.lastValidatedAt = nil
        if !failure { storage.rejectsWrites = true }
        await #expect(throws: (any Error).self) { try await app.validateAndSaveAccess(changed, asset: profile, password: "synthetic-new") }
        #expect(catalog.accessProfiles == [access] && catalog.profiles == [profile] && catalog.recent.isEmpty)
        #expect(try await credentials.read(account: access.credentialAccount) == "synthetic-old")
        #expect(!app.updatingRecords && app.accessValidationSession == nil)
        await app.shutdown()
    }
}

@MainActor
@Test func migratedLegacyPassphrasesAreRetainedAndExplicitForgetDisablesFallback() async throws {
    let fixture = try SessionFixture(); defer { fixture.clean() }
    var access = accessFixture(); access.keyRequiresPassphrase = true
    var profile = try assetFixture(0, access: access); profile.jumpServer?.accessProfileID = nil
    var old = ConnectionDocument(profiles: [profile]); old.version = 4
    let catalog = ConnectionCatalog(storage: MemoryConnectionStorage(old)), credentials = MemoryCredentialStore()
    try await credentials.save("synthetic-legacy", account: profile.credentialAccount)
    let app = AppModel(catalog: catalog, credentials: credentials, makeConnection: { FakeSessionConnection(home: fixture.remote(0)) })
    let migrated = try #require(catalog.profiles.first), shared = try #require(catalog.accessProfiles.first)
    let session = try app.connect(profile: migrated, password: nil, rememberPassword: true)
    try await waitUntil { session.connected && !session.connecting }
    #expect(try await credentials.read(account: shared.credentialAccount) == "synthetic-legacy")
    #expect(try await credentials.read(account: profile.credentialAccount) == "synthetic-legacy")
    var forgotten = shared; forgotten.rememberPassphrase = false
    try await app.validateAndSaveAccess(forgotten, asset: migrated, password: nil)
    #expect(try await credentials.read(account: shared.credentialAccount) == nil)
    #expect(catalog.authenticationAccounts(profile: migrated, access: forgotten) == [shared.credentialAccount])
    #expect(try await credentials.read(account: profile.credentialAccount) == "synthetic-legacy")
    await app.shutdown()
}

@MainActor
@Test func cancellingAccessValidationLeavesExistingSessionAndDoesNotTrustHost() async throws {
    let fixture = try SessionFixture(); defer { fixture.clean() }
    let access = accessFixture(), profile = try assetFixture(0, access: access)
    let catalog = ConnectionCatalog(storage: MemoryConnectionStorage(ConnectionDocument(profiles: [profile], jumpServerAccessProfiles: [access])))
    let primary = FakeSessionConnection(home: fixture.remote(0)), probe = FakeSessionConnection(home: fixture.remote(0), requiresTrust: true)
    var count = 0
    let app = AppModel(catalog: catalog, credentials: MemoryCredentialStore(), makeConnection: { defer { count += 1 }; return count == 0 ? primary : probe })
    let active = try app.connect(profile: profile, password: nil, rememberPassword: true)
    try await waitUntil { active.connected }
    var edited = access; edited.host = "v08-\(UUID()).example"
    let task = Task { try await app.validateAndSaveAccess(edited, asset: profile, password: nil) }
    try await waitUntil { app.accessValidationSession?.hostTrustRequest != nil }
    task.cancel(); _ = await task.result
    #expect(active.connected && catalog.accessProfiles == [access] && app.accessValidationSession == nil)
    #expect(!(await probe.connected) && !app.updatingRecords)
    await app.shutdown()
}

@MainActor
@Test func deletingAssetKeepsSharedCredentialsAndReferencedAccessCannotBeDeleted() async throws {
    let access = accessFixture(), profile = try assetFixture(0, access: access)
    let catalog = ConnectionCatalog(storage: MemoryConnectionStorage(ConnectionDocument(profiles: [profile], jumpServerAccessProfiles: [access])))
    let credentials = MemoryCredentialStore(); try await credentials.save("synthetic-shared", account: access.credentialAccount)
    let app = AppModel(catalog: catalog, credentials: credentials)
    await #expect(throws: (any Error).self) { try await app.removeAccessProfile(access) }
    try catalog.recordSuccess(profile: profile)
    try await app.removeProfile(profile)
    #expect(try await credentials.read(account: access.credentialAccount) == "synthetic-shared")
    await #expect(throws: (any Error).self) { try await app.removeAccessProfile(access) }
    try catalog.clearHistory(); try await app.removeAccessProfile(access)
    #expect(catalog.accessProfiles.isEmpty)
    #expect(try await credentials.read(account: access.credentialAccount) == nil)
    await app.shutdown()
}

@MainActor
@Test func sharedMetadataKeepsCredentialsAndConflictingOrMissingReferencesAreRejected() throws {
    let access = accessFixture(), first = try assetFixture(0, access: access)
    var metadata = access; metadata.name = "公司"; metadata.portalURL = "https://portal.example/core/auth/login/"
    #expect(metadata.credentialAccount == access.credentialAccount)
    var draft = ConnectionFormDraft(first); draft.useAccess(metadata)
    #expect(try draft.validated().endpoint == first.endpoint && draft.validated().credentialAccount == first.credentialAccount)
    var secondAccess = access; secondAccess.id = UUID(); secondAccess.host = "other.example"
    let second = try assetFixture(0, access: secondAccess)
    let catalog = ConnectionCatalog(storage: MemoryConnectionStorage(ConnectionDocument(profiles: [first, second], jumpServerAccessProfiles: [access, secondAccess])))
    secondAccess.host = access.host
    #expect(throws: (any Error).self) { try catalog.saveAccessProfile(secondAccess) }
    #expect(catalog.accessProfiles[1].host == "other.example")
    let invalid = ConnectionDocument(profiles: [first])
    #expect(ConnectionCatalog(storage: MemoryConnectionStorage(invalid)).loadError != nil)
}

@MainActor
@Test func preferredAccessRestoresAndAutomationConnectUsesLatestSharedConfiguration() async throws {
    let fixture = try SessionFixture(); defer { fixture.clean() }
    let suite = "HostDock-v08-" + UUID().uuidString
    let preferences = try #require(UserDefaults(suiteName: suite)); defer { preferences.removePersistentDomain(forName: suite) }
    var access = accessFixture(); access.privateKeyPath = fixture.root.appendingPathComponent("synthetic-key").path
    try Data("synthetic marker for fake transport".utf8).write(to: URL(fileURLWithPath: access.privateKeyPath))
    let profile = try assetFixture(0, access: access)
    var other = access; other.id = UUID(); other.host = "other.example"
    let catalog = ConnectionCatalog(storage: MemoryConnectionStorage(ConnectionDocument(profiles: [profile], jumpServerAccessProfiles: [access, other])))
    let transport = FakeSessionConnection(home: fixture.remote(0))
    let app = AppModel(catalog: catalog, credentials: MemoryCredentialStore(), preferences: preferences,
        automationRecords: AutomationRecords(storage: FileAutomationRecordStorage(directory: fixture.root.appendingPathComponent("automation"))), makeConnection: { transport })
    app.rememberAccessSelection(other)
    let reopened = AppModel(catalog: catalog, credentials: MemoryCredentialStore(), preferences: preferences)
    #expect(reopened.preferredAccessProfile?.id == other.id)
    var updated = access; updated.host = "current.example"; updated.username = "李四"
    try catalog.saveAccessProfile(updated)
    let socket = FileManager.default.temporaryDirectory.appendingPathComponent("h8-" + UUID().uuidString.prefix(8)).appendingPathComponent("agent.sock")
    defer { try? FileManager.default.removeItem(at: socket.deletingLastPathComponent()) }
    let controller = AutomationController(app: app, defaults: preferences, socketURL: socket)
    await controller.setEnabled(true)
    let result = await controller.handle(ControlRequest(command: "connect", arguments: ["profile": profile.id.uuidString]))
    #expect(result.ok)
    #expect(await transport.endpoints.first == ConnectionEndpoint(host: updated.host, port: updated.port, username: "李四@ssta@192.0.2.1"))
    #expect(app.backgroundSessions.first?.profile.id == profile.id && app.sessions.isEmpty && app.selectedSessionID == nil)
    await controller.setEnabled(false); await app.shutdown(); await reopened.shutdown()
}
