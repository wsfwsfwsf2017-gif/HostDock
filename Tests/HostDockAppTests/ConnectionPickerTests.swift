import AppKit
import Foundation
import SwiftUI
import Testing
@testable import HostDock

@MainActor
@Test func connectionPickerWindowAllowsApplicationTermination() async throws {
    let fixture = try SessionFixture()
    defer { fixture.clean() }
    let app = fixture.app(transports: [])
    app.showConnections()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 650),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let hosting = NSHostingView(rootView: ConnectionPickerView(app: app))
    window.contentView = hosting
    hosting.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(150))
    #expect(!window.preventsApplicationTerminationWhenModal)
    #expect(app.connectionPickerPresented && !app.shuttingDown)
}

@MainActor
@Test func startupKeepsMainPageAndNewFormKeepsWorkspaceSelectionIndependent() throws {
    let fixture = try SessionFixture()
    defer { fixture.clean() }
    let app = fixture.app(transports: [])
    #expect(!app.connectionPickerPresented && app.pickerSelection.tab == .new)
    app.showConnections()
    #expect(app.connectionPickerPresented && app.pickerSelection == .new)
    #expect(app.sessions.isEmpty && app.selectedSession == nil)
    let selected = UUID()
    app.selectedSessionID = selected
    for tab in ConnectionPickerTab.allCases {
        app.selectPickerTab(tab)
        #expect(app.pickerSelection.tab == tab && app.selectedSessionID == selected)
    }
    let empty = AppModel(catalog: ConnectionCatalog(storage: MemoryConnectionStorage()), credentials: MemoryCredentialStore())
    #expect(!empty.connectionPickerPresented && empty.pickerSelection.tab == .new)
    #expect(empty.newProfile.rememberPassword)
}

@MainActor
@Test func pickerSuccessSelectsSessionAndExistingConnectionDoesNotResizeAgain() async throws {
    let fixture = try SessionFixture()
    defer { fixture.clean() }
    let app = fixture.app(transports: [FakeSessionConnection(home: fixture.remote(0))])
    app.showConnections()
    app.pickerSelection = .saved(fixture.profiles[0].id)
    let a = try app.connectFromPicker(profile: fixture.profiles[0], password: "synthetic", rememberPassword: false)
    #expect(app.selectedSession == nil && app.connectionPickerPresented)
    try await waitUntil { a.connected && !a.connecting }
    #expect(!app.connectionPickerPresented && app.selectedSession === a && app.maximizeRequest == 1)
    app.showConnections()
    app.pickerSelection = .saved(a.profile.id)
    #expect(try app.connectFromPicker(profile: a.profile, password: nil, rememberPassword: true) === a)
    #expect(!app.connectionPickerPresented && app.sessions.count == 1 && app.maximizeRequest == 1)
    await app.shutdown()
}

@MainActor
@Test func closingPickerCancelsOnlyOwnedAttemptAndBackgroundWorkContinues() async throws {
    let fixture = try SessionFixture()
    defer { fixture.clean() }
    let gate = TestGate()
    let first = FakeSessionConnection(home: fixture.remote(0), store: GatedFileStore(gate: gate))
    let second = FakeSessionConnection(home: fixture.remote(1), requiresTrust: true)
    let app = fixture.app(transports: [first, second])
    app.connectionPickerPresented = false
    let a = try app.connect(profile: fixture.profiles[0], password: "synthetic", rememberPassword: false)
    try await waitUntil { a.connected && !a.connecting }
    a.toggleTerminal()
    try await waitUntil { a.terminalReady }
    let terminal = a.terminal.view
    let path = a.local.path
    let payload = URL(fileURLWithPath: path).appendingPathComponent("background-only.txt")
    try Data("continue-background".utf8).write(to: payload)
    await a.local.refresh()
    a.local.selection = [try #require(a.local.roots.first { $0.entry.name == payload.lastPathComponent }).entry.path]
    a.transfer(upload: true)
    try await waitForReservations(app.reservations, active: 1)
    app.showConnections()
    app.pickerSelection = .saved(fixture.profiles[1].id)
    let b = try app.connectFromPicker(profile: fixture.profiles[1], password: "synthetic", rememberPassword: false)
    try await waitUntil { b.hostTrustRequest != nil }
    #expect(app.selectedSession === a && app.pickerSession === b)
    await first.emit("TERMINAL_WHILE_PICKER\r\n")
    try await waitUntil { String(decoding: terminal.getBufferAsData(), as: UTF8.self).contains("TERMINAL_WHILE_PICKER") }
    app.connectionPickerPresented = false
    try await waitUntil { !app.pickerCancelling }
    #expect(app.sessions.count == 1 && app.selectedSession === a)
    #expect(!b.connected && !b.connecting && b.hostTrustRequest == nil)
    #expect(a.connected && a.transferring && a.terminal.view === terminal && a.local.path == path)
    await gate.open()
    try await waitUntil { !a.transferring }
    #expect(a.transferLabel.hasPrefix("传输完成"))
    #expect(try String(contentsOfFile: fixture.remote(0) + "/background-only.txt", encoding: .utf8) == "continue-background")
    #expect(app.catalog.profiles.count == 2 && app.catalog.recent.count == 1)
    await app.shutdown()
}

@MainActor
@Test func cancellingReconnectKeepsExistingOfflineSession() async throws {
    let fixture = try SessionFixture()
    defer { fixture.clean() }
    let gate = TestGate()
    await gate.open()
    let app = fixture.app(transports: [FakeSessionConnection(home: fixture.remote(0), connectionGate: gate)])
    app.connectionPickerPresented = false
    let a = try app.connect(profile: fixture.profiles[0], password: "synthetic", rememberPassword: false)
    try await waitUntil { a.connected && !a.connecting }
    await a.shutdown()
    await gate.close()
    app.showConnection(a)
    #expect(try app.connectFromPicker(profile: a.profile, password: "synthetic", rememberPassword: false) === a)
    app.connectionPickerPresented = false
    try await waitUntil { !app.pickerCancelling }
    await gate.open()
    #expect(app.sessions.count == 1 && app.sessions.first === a && !a.connected && !a.connecting)
    #expect(app.catalog.profiles.count == 2 && app.catalog.recent.count == 1)
    await app.shutdown()
}

@MainActor
@Test func quittingWithPickerCancelsHostConfirmationAndClosesExistingTerminal() async throws {
    let fixture = try SessionFixture()
    defer { fixture.clean() }
    let app = fixture.app(transports: [FakeSessionConnection(home: fixture.remote(0)),
                                     FakeSessionConnection(home: fixture.remote(1), requiresTrust: true)])
    app.connectionPickerPresented = false
    let a = try app.connect(profile: fixture.profiles[0], password: "synthetic", rememberPassword: false)
    try await waitUntil { a.connected && !a.connecting }
    a.toggleTerminal()
    try await waitUntil { a.terminalReady }
    app.showConnections()
    let b = try app.connectFromPicker(profile: fixture.profiles[1], password: "synthetic", rememberPassword: false)
    try await waitUntil { b.hostTrustRequest != nil }
    await app.shutdown()
    #expect(app.shuttingDown && !app.connectionPickerPresented && !app.pickerCancelling)
    #expect(!a.connected && !a.terminalRunning && !b.connected && !b.connecting && b.hostTrustRequest == nil)
    #expect(app.sessions.count == 1 && app.sessions.first === a)
}

@MainActor
@Test func missingPasswordKeepsPickerAndPersistenceFailureKeepsTemporarySession() async throws {
    let fixture = try SessionFixture()
    defer { fixture.clean() }
    let app = fixture.app(transports: [FakeSessionConnection(home: fixture.remote(0))])
    app.showConnections()
    app.pickerSelection = .saved(fixture.profiles[0].id)
    let a = try app.connectFromPicker(profile: fixture.profiles[0], password: nil, rememberPassword: true)
    try await waitUntil { a.passwordRequired }
    #expect(app.connectionPickerPresented && app.selectedSession == nil && app.catalog.recent.isEmpty)
    app.connectionPickerPresented = false
    try await waitUntil { !app.pickerCancelling }
    #expect(app.sessions.isEmpty)
    let storage = MemoryConnectionStorage()
    storage.rejectsWrites = true
    let failed = fixture.app(transports: [FakeSessionConnection(home: fixture.remote(0))], storage: storage)
    failed.showConnections()
    let temporary = try failed.connectFromPicker(profile: fixture.profiles[0], password: "synthetic", rememberPassword: true)
    try await waitUntil { temporary.connected && !temporary.connecting }
    #expect(temporary.credentialNotice != nil && failed.catalog.profiles.isEmpty && failed.catalog.recent.isEmpty)
    await app.shutdown()
    await failed.shutdown()
}
