import AppKit
import Foundation
import Testing
@testable import HostDock
import HostDockCore

@MainActor
@Test func oldProfilesDecodeAndStartDirectoriesKeepCredentialIdentity() throws {
    let profile = sampleProfile()
    let old = try JSONEncoder().encode(profile)
    let decoded = try JSONDecoder().decode(ConnectionProfile.self, from: old)
    #expect(decoded.localStartDirectory == nil && decoded.remoteStartDirectory == nil)
    var changed = decoded
    changed.localStartDirectory = "~/项目 空格"
    changed.remoteStartDirectory = "/var/www"
    #expect(try changed.validated().credentialAccount == profile.credentialAccount)
    let storage = MemoryConnectionStorage()
    try ConnectionCatalog(storage: storage).save(changed)
    #expect(ConnectionCatalog(storage: storage).profiles.first == changed)
    for invalid in ["relative/path", "~someone/path", " ", "/bad\0path"] {
        changed.remoteStartDirectory = invalid
        #expect(throws: (any Error).self) { try changed.validated() }
    }
}

@MainActor
@Test func invalidStartDirectoryStaysUnreadyUntilUserChoosesHome() async throws {
    let fixture = try SessionFixture()
    defer { fixture.clean() }
    let home = fixture.root.path
    let browser = BrowserModel()
    await browser.attach(store: LocalFileStore(), home: home, initialDirectory: home + "/missing")
    #expect(browser.error != nil && !browser.directoryReady && browser.path.isEmpty)
    #expect(browser.home == home)
    await browser.refresh()
    #expect(browser.error != nil && !browser.directoryReady && browser.path.isEmpty)
    await browser.navigate(to: browser.home)
    #expect(browser.directoryReady)
    await browser.attach(store: LocalFileStore(), home: home, initialDirectory: "~/remote0")
    #expect(browser.directoryReady && browser.home == home)
    #expect(browser.path.hasSuffix("/remote0"))
}

@MainActor
@Test func explicitReconnectKeepsDirectoriesTerminalsAndDisconnectIsolated() async throws {
    let fixture = try SessionFixture()
    defer { fixture.clean() }
    let first = FakeSessionConnection(home: fixture.remote(0))
    let second = FakeSessionConnection(home: fixture.remote(1))
    let app = fixture.app(transports: [first, second])
    let a = try app.connect(profile: fixture.profiles[0], password: "synthetic", rememberPassword: false)
    #expect(try app.connect(profile: fixture.profiles[0], password: nil, rememberPassword: true, reusing: a) === a)
    let b = try app.connect(profile: fixture.profiles[1], password: "synthetic", rememberPassword: false)
    try await waitUntil { a.connected && b.connected && !a.connecting && !b.connecting }
    #expect(app.sessions.count == 2 && app.catalog.recent.count == 2)
    #expect(app.maximizeRequest == 1)
    #expect(await first.connects == 1)
    let aPath = a.local.path
    let bPath = b.remote.path
    let selected = try #require(a.local.roots.first)
    a.local.selection = [selected.entry.path]
    app.selectTab(b.id)
    app.selectTab(a.id)
    #expect(app.maximizeRequest == 1)
    #expect(a.local.path == aPath && b.remote.path == bPath && a.local.selection.contains(selected.entry.path))
    a.toggleTerminal(); b.toggleTerminal()
    try await waitUntil { a.terminalReady && b.terminalReady }
    await first.emit("FIRST_ONLY\r\n")
    await second.emit("SECOND_ONLY\r\n")
    try await waitUntil { String(decoding: a.terminal.view.getBufferAsData(), as: UTF8.self).contains("FIRST_ONLY") }
    #expect(!String(decoding: b.terminal.view.getBufferAsData(), as: UTF8.self).contains("FIRST_ONLY"))
    a.terminal.view.insertText("only-first" as NSString, replacementRange: NSRange(location: NSNotFound, length: 0))
    for _ in 0..<200 {
        if await first.inputs == [Data("only-first".utf8)] { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await first.inputs == [Data("only-first".utf8)])
    #expect(await second.inputs.isEmpty)
    await a.shutdown()
    #expect(b.connected && b.terminalReady && !a.connected)
    await app.closeSession(a)
    #expect(app.sessions.count == 1 && app.catalog.profiles.count == 2)
    await app.shutdown()
    #expect(!b.connected && !b.terminalReady)
}

@MainActor
@Test func directoryEditsKeepCredentialsAndInvalidDefaultsKeepSSHConnected() async throws {
    let fixture = try SessionFixture()
    defer { fixture.clean() }
    let credentials = MemoryCredentialStore()
    let catalog = ConnectionCatalog(storage: MemoryConnectionStorage(ConnectionDocument(profiles: fixture.profiles)))
    let transport = FakeSessionConnection(home: fixture.remote(0))
    let app = AppModel(catalog: catalog, credentials: credentials, makeConnection: { transport })
    var profile = try fixture.profiles[0].validated()
    try await credentials.save("synthetic", account: profile.credentialAccount)
    profile.localStartDirectory = fixture.root.path + "/missing-local"
    profile.remoteStartDirectory = fixture.root.path + "/missing-remote"
    try await app.saveProfile(profile)
    #expect(try await credentials.read(account: profile.credentialAccount) == "synthetic")
    #expect(catalog.profiles.contains { $0.id == fixture.profiles[0].id })
    let session = try app.connect(profile: profile, password: nil, rememberPassword: true)
    try await waitUntil { session.connected && !session.connecting }
    #expect(!session.local.directoryReady && !session.remote.directoryReady)
    #expect(session.local.error != nil && session.remote.error != nil)
    session.transfer(upload: true)
    #expect(!session.transferring)
    await session.remote.navigate(to: session.remote.home)
    #expect(session.connected && session.remote.directoryReady)
    await session.shutdown()
    let saved = try #require(catalog.profile(for: profile.endpoint))
    #expect(saved.remoteStartDirectory == profile.remoteStartDirectory)
    #expect(try app.connect(profile: saved, password: nil, rememberPassword: true, reusing: session) === session)
    try await waitUntil { session.connected && !session.connecting }
    #expect(!session.remote.directoryReady && session.remote.error != nil)
    await app.shutdown()
}

@MainActor
@Test func reservationsQueueAncestorsWithoutBlockingIndependentPaths() async throws {
    let reservations = TransferReservations()
    let root = try TransferDestination(storage: "hostkey:one", path: "/Data/项目/../项目/")
    let child = try TransferDestination(storage: "hostkey:one", path: "/data/项目/file")
    #expect(root.overlaps(child))
    #expect(!(try TransferDestination(storage: "hostkey:two", path: child.path)).overlaps(root))
    #expect(!(try TransferDestination(storage: root.storage, path: "/data/项目-other")).overlaps(root))
    #expect(try TransferDestination(storage: "local", path: "/café").overlaps(TransferDestination(storage: "local", path: "/cafe\u{301}/child")))
    let firstID = UUID(), childID = UUID(), laterID = UUID(), otherID = UUID()
    try await reservations.acquire([root], id: firstID)
    let waiting = Task { try await reservations.acquire([child], id: childID) }
    try await waitForReservations(reservations, waiting: 1)
    let later = Task { try await reservations.acquire([root], id: laterID) }
    try await waitForReservations(reservations, waiting: 2)
    try await reservations.acquire([TransferDestination(storage: "local", path: "/independent")], id: otherID)
    try await waitForReservations(reservations, active: 2, waiting: 2)
    await reservations.release(firstID)
    try await waiting.value
    try await waitForReservations(reservations, active: 2, waiting: 1)
    later.cancel()
    do { try await later.value; Issue.record("等待中的预约未被取消") } catch is CancellationError {} catch { throw error }
    await reservations.release(childID)
    await reservations.release(otherID)
    try await waitForReservations(reservations, active: 0, waiting: 0)
}

@MainActor
@Test func independentServersTransferInParallelAndCancelOnlyOne() async throws {
    let fixture = try SessionFixture()
    defer { fixture.clean() }
    let gateA = TestGate(), gateB = TestGate()
    let aStore = GatedFileStore(gate: gateA), bStore = GatedFileStore(gate: gateB)
    let app = fixture.app(transports: [FakeSessionConnection(home: fixture.remote(0), store: aStore), FakeSessionConnection(home: fixture.remote(1), store: bStore)])
    let a = try app.connect(profile: fixture.profiles[0], password: "synthetic", rememberPassword: false)
    let b = try app.connect(profile: fixture.profiles[1], password: "synthetic", rememberPassword: false)
    try await waitUntil { a.connected && b.connected && !a.connecting && !b.connecting }
    // 上传独立文件名，避免测试夹具的既有 payload 文件触发确认。
    for session in [a, b] {
        try Data("parallel".utf8).write(to: URL(fileURLWithPath: session.local.path).appendingPathComponent("upload.txt"))
        await session.local.refresh()
        session.local.selection = [try #require(session.local.roots.first { $0.entry.name == "upload.txt" }).entry.path]
        session.transfer(upload: true)
    }
    try await waitForReservations(app.reservations, active: 2)
    app.selectTab(b.id)
    a.cancelTransfer()
    try await waitUntil { !a.transferring }
    #expect(b.transferring && b.connected)
    #expect(!(try FileManager.default.contentsOfDirectory(atPath: fixture.remote(0))).contains { $0.hasSuffix(".part") })
    await gateB.open()
    try await waitUntil { !b.transferring }
    #expect(b.transferLabel.hasPrefix("传输完成"))
    #expect(try Data(contentsOf: URL(fileURLWithPath: fixture.remote(1)).appendingPathComponent("upload.txt")) == Data("parallel".utf8))
    await app.shutdown()
}

@MainActor
@Test func overlappingDownloadsWaitAndConflictBelongsToOriginatingSession() async throws {
    let fixture = try SessionFixture()
    defer { fixture.clean() }
    let gate = TestGate()
    let app = fixture.app(transports: [FakeSessionConnection(home: fixture.remote(0)), FakeSessionConnection(home: fixture.remote(1))])
    let a = try app.connect(profile: fixture.profiles[0], password: "synthetic", rememberPassword: false)
    let b = try app.connect(profile: fixture.profiles[1], password: "synthetic", rememberPassword: false)
    try await waitUntil { a.connected && b.connected && !a.connecting && !b.connecting }
    let shared = fixture.root.appendingPathComponent("downloads")
    try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: false)
    await a.local.attach(store: GatedFileStore(gate: gate), home: shared.path)
    await b.local.attach(store: LocalFileStore(), home: shared.path)
    for session in [a, b] { session.remote.selection = [try #require(session.remote.roots.first).entry.path] }
    a.transfer(upload: false)
    try await waitForReservations(app.reservations, active: 1)
    b.transfer(upload: false)
    try await waitForReservations(app.reservations, waiting: 1)
    #expect(b.waitingForTarget)
    b.cancelTransfer()
    try await waitUntil { !b.transferring }
    #expect(a.transferring)
    b.transfer(upload: false)
    try await waitForReservations(app.reservations, waiting: 1)
    app.selectTab(a.id)
    await gate.open()
    try await waitUntil { !a.transferring && b.conflictRequest != nil }
    #expect(a.conflictRequest == nil && b.needsAttention)
    b.finishConflict(.overwrite)
    try await waitUntil { !b.transferring }
    #expect(try Data(contentsOf: shared.appendingPathComponent("payload.txt")) == Data("from-remote-1".utf8))
    #expect(try FileManager.default.contentsOfDirectory(atPath: shared.path) == ["payload.txt"])
    await app.shutdown()
    try await waitForReservations(app.reservations, active: 0, waiting: 0)
}

@MainActor
@Test func shutdownCancelsActiveAndWaitingTransfersAndReleasesTargets() async throws {
    let fixture = try SessionFixture()
    defer { fixture.clean() }
    let gate = TestGate()
    let app = fixture.app(transports: [FakeSessionConnection(home: fixture.remote(0)), FakeSessionConnection(home: fixture.remote(1))])
    let a = try app.connect(profile: fixture.profiles[0], password: "synthetic", rememberPassword: false)
    let b = try app.connect(profile: fixture.profiles[1], password: "synthetic", rememberPassword: false)
    try await waitUntil { a.connected && b.connected && !a.connecting && !b.connecting }
    let shared = fixture.root.appendingPathComponent("quit-downloads")
    try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: false)
    for session in [a, b] {
        await session.local.attach(store: GatedFileStore(gate: gate), home: shared.path)
        session.remote.selection = [try #require(session.remote.roots.first).entry.path]
    }
    a.transfer(upload: false)
    try await waitForReservations(app.reservations, active: 1)
    b.transfer(upload: false)
    try await waitForReservations(app.reservations, waiting: 1)
    #expect(app.hasTransfers)
    app.showConnections()
    #expect(app.connectionPickerPresented)
    await app.shutdown()
    #expect(!app.connectionPickerPresented && !app.hasTransfers && !a.connected && !b.connected)
    #expect(try FileManager.default.contentsOfDirectory(atPath: shared.path).isEmpty)
    try await waitForReservations(app.reservations, active: 0, waiting: 0)
}

@MainActor
@Test func backgroundTrustAndPasswordRequestsRemainSessionScoped() async throws {
    let fixture = try SessionFixture()
    defer { fixture.clean() }
    let before = UserDefaults.standard.object(forKey: "trustedHostKeys")
    defer {
        if let before { UserDefaults.standard.set(before, forKey: "trustedHostKeys") }
        else { UserDefaults.standard.removeObject(forKey: "trustedHostKeys") }
    }
    let app = fixture.app(transports: [FakeSessionConnection(home: fixture.remote(0), requiresTrust: true), FakeSessionConnection(home: fixture.remote(1), requiresTrust: true)])
    let a = try app.connect(profile: fixture.profiles[0], password: "synthetic", rememberPassword: false)
    let b = try app.connect(profile: fixture.profiles[1], password: "synthetic", rememberPassword: false)
    try await waitUntil { a.hostTrustRequest != nil && b.hostTrustRequest != nil }
    #expect(a.hostTrustRequest?.challenge.host != b.hostTrustRequest?.challenge.host)
    a.trustHost()
    b.cancelConnection()
    try await waitUntil { a.connected && !b.disconnecting }
    #expect(b.hostTrustRequest == nil && !b.connected && app.catalog.recent.count == 1)
    await app.shutdown()
}

@MainActor
@Test func failedNewConnectionPersistenceDoesNotClaimSavedConfiguration() async throws {
    let fixture = try SessionFixture()
    defer { fixture.clean() }
    let store = MemoryConnectionStorage()
    store.rejectsWrites = true
    let app = fixture.app(transports: [FakeSessionConnection(home: fixture.remote(0))], storage: store)
    let session = try app.connect(profile: fixture.profiles[0], password: "synthetic", rememberPassword: true)
    try await waitUntil { session.connected && !session.connecting }
    #expect(session.credentialNotice != nil && app.catalog.profiles.isEmpty && app.catalog.recent.isEmpty)
    await app.shutdown()
}

@MainActor
@Test func droppedConnectionCannotPublishLateSuccessOrAffectAnotherSession() async throws {
    let fixture = try SessionFixture()
    defer { fixture.clean() }
    let gate = TestGate()
    let first = FakeSessionConnection(home: fixture.remote(0), connectionGate: gate)
    let app = fixture.app(transports: [first, FakeSessionConnection(home: fixture.remote(1))])
    let a = try app.connect(profile: fixture.profiles[0], password: "synthetic", rememberPassword: false)
    let b = try app.connect(profile: fixture.profiles[1], password: "synthetic", rememberPassword: false)
    try await waitUntil { b.connected }
    await first.drop()
    await gate.open()
    try await waitUntil { !a.connecting }
    #expect(!a.connected && a.connectionError != nil && b.connected)
    #expect(app.catalog.recent.count == 1)
    await app.shutdown()
}

@MainActor
@Test func recentConnectionFormKeepsItsIdentityAcrossBackgroundChanges() throws {
    let profile = sampleProfile()
    let recent = RecentConnection(name: profile.name, endpoint: profile.endpoint, lastConnected: Date())
    let app = AppModel(catalog: ConnectionCatalog(storage: MemoryConnectionStorage(ConnectionDocument(recent: [recent]))), credentials: MemoryCredentialStore())
    app.pickerSelection = .recent(recent.id)
    let first = try #require(app.pickerProfile)
    app.selectedSessionID = UUID()
    #expect(app.pickerProfile?.id == first.id)
}

@MainActor
@Test func windowPlacementUsesAvailableFrameOnBothAttachedDisplays() {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    #expect(WindowPlacement.screen(containing: NSPoint(x: 2000, y: 500), screens: [NSRect(x: 0, y: 0, width: 1920, height: 1080), NSRect(x: 1920, y: 0, width: 1920, height: 1080)]) == 1)
    for screen in NSScreen.screens {
        let rect = NSRect(x: screen.visibleFrame.midX - 200, y: screen.visibleFrame.midY - 150, width: 400, height: 300)
        let window = NSWindow(contentRect: rect, styleMask: [.titled, .resizable], backing: .buffered, defer: false, screen: screen)
        window.isReleasedWhenClosed = false
        window.setFrame(rect, display: false)
        WindowPlacement.maximize(window)
        #expect(window.frame == screen.visibleFrame)
        #expect(!window.styleMask.contains(.fullScreen))
        window.close()
    }
}
