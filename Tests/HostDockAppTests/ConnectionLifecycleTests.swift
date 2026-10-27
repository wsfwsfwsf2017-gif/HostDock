import AppKit
import Foundation
import HostDockCore
import SwiftUI
import Testing
@testable import HostDock

@MainActor
private func lifecycleApp(_ fixture: SessionFixture, transports: [FakeSessionConnection], editors: RemoteEditors? = nil) async throws -> (AppModel, MemoryCredentialStore) {
    let credentials = MemoryCredentialStore()
    var profiles = fixture.profiles
    for index in profiles.indices {
        profiles[index].lastValidatedAt = Date()
        try await credentials.save("synthetic-only", account: profiles[index].credentialAccount)
    }
    let app = fixture.app(transports: transports, storage: MemoryConnectionStorage(ConnectionDocument(profiles: profiles)), credentials: credentials, editors: editors)
    await app.refreshSavedConnections()
    return (app, credentials)
}

@MainActor
private func editorDocument(in session: SessionModel) -> RemoteDocument? {
    NSApp.windows.compactMap { ($0.contentView as? NSHostingView<RemoteEditorView>)?.rootView.document }.first { $0.session === session }
}

@Suite(.serialized)
@MainActor
struct ConnectionLifecycleTests {
    @Test func concurrentEditorOpensCreateOnlyOneWindow() async throws {
        let fixture = try SessionFixture(); defer { fixture.clean() }
        let gate = TestGate()
        let store = GatedFileStore(gate: TestGate(), readGate: gate)
        let app = fixture.app(transports: [FakeSessionConnection(home: fixture.remote(0), store: store)])
        let session = try app.connect(profile: fixture.profiles[0], password: "synthetic-only", rememberPassword: false)
        try await waitUntil { session.terminalReady }
        let entry = try #require(session.remote.roots.first?.entry)
        let editors = RemoteEditors(drafts: EditDraftStore(directory: fixture.root.appendingPathComponent("drafts")))
        defer {
            for window in NSApp.windows where window.title.contains(fixture.root.path) { window.close() }
        }
        let first = Task { try await editors.open(entry, session: session) }
        for _ in 0..<100 {
            if await gate.entered { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let second = Task { try await editors.open(entry, session: session) }
        try await Task.sleep(for: .milliseconds(80))
        await gate.open()
        try await first.value; try await second.value
        let windows = NSApp.windows.filter { window in
            (window.contentView as? NSHostingView<RemoteEditorView>)?.rootView.document.path == entry.path
        }
        #expect(windows.count == 1)
        editors.closeAll()
        await app.shutdown()
    }

    @Test func directReconnectUsesLatestSavedSettingsAndKeepsTheExactTabAndPane() async throws {
        let fixture = try SessionFixture(); defer { fixture.clean() }
        let first = FakeSessionConnection(home: fixture.remote(0)), second = FakeSessionConnection(home: fixture.remote(0))
        let (app, _) = try await lifecycleApp(fixture, transports: [first, second])
        try app.openProfile(fixture.profiles[0]); let a = try #require(app.selectedSession)
        try await waitUntil { a.terminalReady }
        try app.openProfile(fixture.profiles[0]); let b = try #require(app.selectedSession)
        try await waitUntil { b.terminalReady }
        app.setLayout(.quad); app.focusPane(3)
        let slots = app.workspace.slots, id = b.id
        await b.shutdown()
        var saved = try #require(app.catalog.profiles.first { $0.id == b.profile.id })
        saved.name = "更新后的别称"; saved.localStartDirectory = fixture.root.path
        try app.catalog.save(saved)
        app.reconnect(b); app.reconnect(b)
        #expect(!app.connectionPickerPresented && app.sessions.count == 2 && app.workspace.slots == slots)
        try await waitUntil { b.terminalReady && !b.connecting }
        #expect(b.id == id && b.profile.name == saved.name && b.local.path == fixture.root.path)
        #expect(a.connected && a.local.path != b.local.path && app.selectedSession === b)
        #expect(await first.connects == 1)
        #expect(await second.connects == 2)
        await app.shutdown()
    }

    @Test func directReconnectShowsSpecificErrorsWithoutOpeningAuthenticationForms() async throws {
        for failure in [SSHConnectionFailure.network, .authentication, .keyFile] {
            let fixture = try SessionFixture(); defer { fixture.clean() }
            let transport = FakeSessionConnection(home: fixture.remote(0))
            let (app, _) = try await lifecycleApp(fixture, transports: [transport])
            try app.openProfile(fixture.profiles[0]); let session = try #require(app.selectedSession)
            try await waitUntil { session.terminalReady }
            await session.shutdown(); await transport.configureFailure(failure)
            app.reconnect(session)
            try await waitUntil { !session.connecting }
            #expect(session.connectionFailure == failure && session.connectionError == failure.localizedDescription)
            #expect(session.needsAuthentication == (failure != .network))
            #expect(app.sessions.count == 1 && !app.connectionPickerPresented)
            await app.shutdown()
        }
    }

    @Test func missingCredentialsStayInlineAndExplicitAuthenticationRepairsTheOriginalTab() async throws {
        let fixture = try SessionFixture(); defer { fixture.clean() }
        let transport = FakeSessionConnection(home: fixture.remote(0))
        let (app, credentials) = try await lifecycleApp(fixture, transports: [transport])
        try app.openProfile(fixture.profiles[0]); let session = try #require(app.selectedSession)
        try await waitUntil { session.terminalReady }
        await session.shutdown(); await credentials.remove(account: session.profile.credentialAccount)
        app.reconnect(session)
        try await waitUntil { !session.connecting }
        #expect(session.passwordRequired && session.needsAuthentication && !app.connectionPickerPresented)
        #expect(await transport.connects == 1)
        app.showConnection(session, authenticating: true)
        #expect(app.connectionPickerPresented && app.pickerAuthenticating && app.pickerSession === session)
        #expect(try app.connectFromPicker(profile: session.profile, password: "synthetic-repaired", rememberPassword: true) === session)
        try await waitUntil { session.terminalReady && !session.connecting }
        #expect(app.sessions.count == 1 && !app.connectionPickerPresented)
        await app.shutdown()
    }

    @Test func reconnectHostTrustCanBeCancelledWithoutClosingTheTabOrOpeningAForm() async throws {
        let fixture = try SessionFixture(); defer { fixture.clean() }
        let transport = FakeSessionConnection(home: fixture.remote(0), requiresTrust: true)
        let (app, _) = try await lifecycleApp(fixture, transports: [transport])
        try app.openProfile(fixture.profiles[0]); let session = try #require(app.selectedSession)
        try await waitUntil { session.hostTrustRequest != nil }
        session.cancelConnection(); try await waitUntil { !session.busy }
        app.reconnect(session)
        try await waitUntil { session.hostTrustRequest != nil }
        #expect(app.sessions.count == 1 && !app.connectionPickerPresented && !session.connected)
        session.cancelConnection(); try await waitUntil { !session.busy }
        #expect(app.sessions.first === session && session.hostTrustRequest == nil)
        #expect(await transport.connects == 2)
        await app.shutdown()
    }

    @Test func closeAllIdleTabsKeepsBackgroundSessionsRecordsAndBlocksOverlappingActions() async throws {
        let fixture = try SessionFixture(); defer { fixture.clean() }
        let transports = (0..<7).map { _ in FakeSessionConnection(home: fixture.remote(0)) }
        let (app, _) = try await lifecycleApp(fixture, transports: transports)
        for _ in 0..<6 { try app.openProfile(fixture.profiles[0]) }
        let background = try app.connectBackground(profile: fixture.profiles[0])
        try await waitUntil { app.sessions.allSatisfy(\.terminalReady) && background.connected }
        app.setLayout(.quad)
        let records = app.catalog.profiles, history = app.catalog.recent
        app.requestCloseAllTabs()
        #expect(app.closingTabs && !app.closeAllConfirmationPresented)
        app.showConnections(); app.requestCloseAllTabs()
        #expect(!app.connectionPickerPresented)
        #expect(throws: (any Error).self) { try app.connect(profile: fixture.profiles[1], password: "synthetic-only", rememberPassword: true) }
        await app.closeAllTabs()
        #expect(app.sessions.isEmpty && app.workspace.layout == .single && app.workspace.slots.allSatisfy { $0 == nil })
        #expect(app.selectedSession == nil && !app.closingTabs && !app.canCloseAllTabs)
        #expect(app.backgroundSessions.count == 1 && background.connected)
        #expect(app.catalog.profiles == records && app.catalog.recent == history)
        await app.shutdown()
    }

    @Test func closeAllTransfersHasOneConfirmationAndCancellationKeepsWorkRunning() async throws {
        let fixture = try SessionFixture(); defer { fixture.clean() }
        let gateA = TestGate(), gateB = TestGate()
        let app = fixture.app(transports: [FakeSessionConnection(home: fixture.remote(0), store: GatedFileStore(gate: gateA)),
                                           FakeSessionConnection(home: fixture.remote(1), store: GatedFileStore(gate: gateB))])
        let a = try app.connect(profile: fixture.profiles[0], password: "synthetic-only", rememberPassword: false)
        let b = try app.connect(profile: fixture.profiles[1], password: "synthetic-only", rememberPassword: false)
        try await waitUntil { a.terminalReady && b.terminalReady }
        for session in [a, b] {
            let source = session.local.path + "/lifecycle-upload.txt"
            try Data(repeating: 65, count: 131_072).write(to: URL(fileURLWithPath: source))
            await session.local.refresh(); session.local.selection = [source]; session.transfer(upload: true)
        }
        try await waitForReservations(app.reservations, active: 2)
        app.requestCloseAllTabs(); app.requestCloseAllTabs()
        #expect(app.closeAllConfirmationPresented && !app.closingTabs)
        app.showConnections(); #expect(!app.connectionPickerPresented)
        #expect(throws: (any Error).self) { try app.connect(profile: fixture.profiles[0], password: "synthetic-only", rememberPassword: false) }
        app.cancelCloseAllTabs()
        #expect(!app.closeAllConfirmationPresented && a.connected && b.connected && a.transferring && b.transferring)
        app.requestCloseAllTabs(); await app.closeAllTabs()
        #expect(app.sessions.isEmpty && !a.connected && !b.connected && !a.transferring && !b.transferring)
        for path in [fixture.remote(0), fixture.remote(1)] {
            #expect(try !FileManager.default.contentsOfDirectory(atPath: path).contains { $0.hasSuffix(".part") })
        }
        try await waitForReservations(app.reservations, active: 0, waiting: 0)
        await app.shutdown()
    }

    @Test func closeAllSavesEveryDraftBeforeClosingAndFailureKeepsAllTabs() async throws {
        for rejectsDraft in [false, true] {
            let fixture = try SessionFixture(); defer { fixture.clean() }
            let drafts = EditDraftStore(directory: fixture.root.appendingPathComponent("private-drafts"))
            let editors = RemoteEditors(drafts: drafts); defer { editors.closeAll() }
            let app = fixture.app(transports: [FakeSessionConnection(home: fixture.remote(0)), FakeSessionConnection(home: fixture.remote(1))], editors: editors)
            let a = try app.connect(profile: fixture.profiles[0], password: "synthetic-only", rememberPassword: false)
            let b = try app.connect(profile: fixture.profiles[1], password: "synthetic-only", rememberPassword: false)
            try await waitUntil { a.terminalReady && b.terminalReady }
            try await editors.open(try #require(a.remote.roots.first?.entry), session: a)
            let document = try #require(editorDocument(in: a)); document.text += "\nUNUPLOADED_DRAFT"
            try await editors.open(try #require(b.remote.roots.first?.entry), session: b)
            let other = try #require(editorDocument(in: b)); other.text += "\nSECOND_UNUPLOADED_DRAFT"
            if rejectsDraft { try FileManager.default.createDirectory(at: drafts.directory.appendingPathComponent(other.key + ".json"), withIntermediateDirectories: true) }
            app.requestCloseAllTabs()
            #expect(app.closeAllConfirmationPresented && editors.hasUnuploadedEdits(in: a))
            await app.closeAllTabs()
            if rejectsDraft {
                #expect(app.sessions.count == 2 && a.connected && b.connected && !document.isClosing && !other.isClosing)
                #expect(app.workspaceNotice?.contains("关闭全部已取消") == true)
                #expect(document.text.contains("UNUPLOADED_DRAFT"))
            } else {
                #expect(app.sessions.isEmpty && !a.connected && !b.connected)
                #expect(try drafts.load(document.key)?.contents == document.encoded)
                #expect(try drafts.load(other.key)?.contents == other.encoded)
                #expect(!editors.contains(identity: document.identity, path: document.path))
            }
            await app.shutdown()
        }
    }

    @Test func closeAllDuringSavePreservesDraftAndCleansTheStagedFile() async throws {
        let fixture = try SessionFixture(); defer { fixture.clean() }
        let gate = TestGate(), drafts = EditDraftStore(directory: fixture.root.appendingPathComponent("drafts"))
        let editors = RemoteEditors(drafts: drafts); defer { editors.closeAll() }
        let app = fixture.app(transports: [FakeSessionConnection(home: fixture.remote(0), store: GatedFileStore(gate: gate))], editors: editors)
        let session = try app.connect(profile: fixture.profiles[0], password: "synthetic-only", rememberPassword: false)
        try await waitUntil { session.terminalReady }
        let entry = try #require(session.remote.roots.first?.entry)
        let original = try Data(contentsOf: URL(fileURLWithPath: entry.path))
        try await editors.open(entry, session: session)
        let document = try #require(editorDocument(in: session)); document.text = "PRESERVE_SAVING_DRAFT"
        let saving = Task { await document.save() }
        try await waitUntil { document.saving && session.transferring }
        app.requestCloseAllTabs(); #expect(app.closeAllConfirmationPresented)
        await app.closeAllTabs()
        #expect(await !saving.value)
        #expect(try Data(contentsOf: URL(fileURLWithPath: entry.path)) == original)
        #expect(try drafts.load(document.key)?.contents == document.encoded)
        #expect(try !FileManager.default.contentsOfDirectory(atPath: fixture.remote(0)).contains { $0.hasSuffix(".part") })
        await app.shutdown()
    }

    @Test func closingAllRejectsLateEditorReadAndFailedOpenCanBeRetried() async throws {
        let fixture = try SessionFixture(); defer { fixture.clean() }
        let gate = TestGate(), drafts = EditDraftStore(directory: fixture.root.appendingPathComponent("drafts"))
        let editors = RemoteEditors(drafts: drafts); defer { editors.closeAll() }
        let delayed = GatedFileStore(gate: TestGate(), readGate: gate)
        let app = fixture.app(transports: [FakeSessionConnection(home: fixture.remote(0), store: delayed), FakeSessionConnection(home: fixture.remote(0), store: delayed)], editors: editors)
        let session = try app.connect(profile: fixture.profiles[0], password: "synthetic-only", rememberPassword: false)
        try await waitUntil { session.terminalReady }
        let entry = try #require(session.remote.roots.first?.entry)
        let opening = Task { try await editors.open(entry, session: session) }
        for _ in 0..<100 {
            if await gate.entered { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        await app.closeAllTabs(); await gate.open()
        await #expect(throws: (any Error).self) { try await opening.value }
        #expect(!editors.contains(identity: session.verifiedRemoteIdentity, path: entry.path) && editorDocument(in: session) == nil)
        let next = try app.connect(profile: fixture.profiles[0], password: "synthetic-only", rememberPassword: false)
        try await waitUntil { next.terminalReady }
        try await editors.open(entry, session: next)
        #expect(editorDocument(in: next) != nil)
        await app.closeAllTabs(); await app.shutdown()
    }

    @Test func activeTabScrollsIntoViewInCompactWindows() async throws {
        let fixture = try SessionFixture(); defer { fixture.clean() }
        let app = fixture.app(transports: (0..<6).map { _ in FakeSessionConnection(home: fixture.remote(0)) })
        for _ in 0..<6 { try app.connect(profile: fixture.profiles[0], password: "synthetic-only", rememberPassword: false) }
        try await waitUntil { app.sessions.allSatisfy(\.terminalReady) }
        let hosting = NSHostingView(rootView: WorkspaceView(app: app))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 620), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting
        defer { window.close() }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func layout() async throws { try await Task.sleep(for: .milliseconds(150)); hosting.layoutSubtreeIfNeeded() }
        try await layout()
        let strip = try #require(descendants(hosting).compactMap { $0 as? NSScrollView }.first {
            $0.frame.height < 80 && ($0.documentView?.frame.width ?? 0) > $0.contentView.bounds.width + 50
        })
        #expect(strip.contentView.bounds.origin.x > 0)
        app.selectTab(try #require(app.sessions.first).id); try await layout()
        #expect(strip.contentView.bounds.origin.x < 2)
        app.selectTab(try #require(app.sessions.last).id); try await layout()
        #expect(strip.contentView.bounds.origin.x > 0)
        await app.closeAllTabs(); await app.shutdown()
    }
}
