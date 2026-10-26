import AppKit
import Foundation
import HostDockCore
import SwiftUI
import Testing
@testable import HostDock

@MainActor
private func preparedApp(_ fixture: SessionFixture, transports: [FakeSessionConnection]) async throws -> AppModel {
    let credentials = MemoryCredentialStore()
    var profiles = fixture.profiles
    for index in profiles.indices {
        profiles[index].lastValidatedAt = Date()
        try await credentials.save("synthetic-only", account: profiles[index].credentialAccount)
    }
    let app = fixture.app(transports: transports, storage: MemoryConnectionStorage(ConnectionDocument(profiles: profiles)), credentials: credentials)
    await app.refreshSavedConnections()
    return app
}

@MainActor
private func backgroundController(_ app: AppModel) async throws -> AutomationController {
    let defaults = try #require(UserDefaults(suiteName: "HostDock-isolation-" + UUID().uuidString))
    let socket = FileManager.default.temporaryDirectory.appendingPathComponent("hdi-" + UUID().uuidString.prefix(8)).appendingPathComponent("agent.sock")
    let controller = AutomationController(app: app, defaults: defaults, socketURL: socket)
    await controller.setEnabled(true)
    #expect(controller.enabled)
    return controller
}

@Test func workspaceSlotsKeepUniqueSessionsAcrossSelectionAndFifthTab() {
    let tabs = (0..<5).map { _ in UUID() }
    var arrangement = WorkspaceArrangement()
    arrangement.activate(tabs[0]); arrangement.setLayout(.quad, tabs: tabs)
    #expect(arrangement.slots == tabs.prefix(4).map(Optional.some))
    arrangement.focus(2); arrangement.activate(tabs[4])
    #expect(arrangement.slots == [tabs[0], tabs[1], tabs[4], tabs[3]])
    arrangement.place(tabs[0], at: 3)
    #expect(arrangement.slots == [tabs[3], tabs[1], tabs[4], tabs[0]] && arrangement.activeSlot == 3)
    arrangement.activate(tabs[1])
    #expect(arrangement.activeSlot == 1 && arrangement.slots[3] == tabs[0])
    arrangement.expandedSessionID = tabs[1]
    arrangement.place(tabs[2], at: 0)
    #expect(arrangement.expandedSessionID == tabs[2])
    arrangement.setLayout(.single, tabs: tabs)
    #expect(arrangement.slots == [tabs[2], nil, nil, nil] && arrangement.expandedSessionID == nil)
    arrangement.setLayout(.dual, tabs: tabs)
    #expect(arrangement.slots[1] == tabs[0])
    arrangement.remove(tabs[2]); arrangement.activate(tabs[4])
    #expect(arrangement.slots == [tabs[4], tabs[0], nil, nil])
    arrangement.place(tabs[3], at: 3)
    #expect(arrangement.slots[3] == nil)
}

@MainActor
@Test func sidebarCreatesIndependentTabsAndNewFormStaysBlankWithoutChangingWorkspace() async throws {
    let fixture = try SessionFixture(); defer { fixture.clean() }
    let transports = [FakeSessionConnection(home: fixture.remote(0)), FakeSessionConnection(home: fixture.remote(1)), FakeSessionConnection(home: fixture.remote(0))]
    let app = try await preparedApp(fixture, transports: transports)
    #expect(!app.connectionPickerPresented && app.sessions.isEmpty)
    try app.openProfile(fixture.profiles[0])
    let a = try #require(app.selectedSession)
    try await waitUntil { a.terminalReady }
    try app.openProfile(fixture.profiles[1])
    let b = try #require(app.selectedSession)
    try await waitUntil { b.terminalReady }
    app.setLayout(.dual)
    let maximize = app.maximizeRequest
    try app.openProfile(a.profile)
    let c = try #require(app.selectedSession)
    try await waitUntil { c.terminalReady }
    #expect(app.sessions.count == 3 && c !== a && c.id != a.id && c.profile.id == a.profile.id)
    #expect(app.maximizeRequest == maximize + 1 && a.connected && b.connected)
    #expect(app.tabTitle(a) == a.profile.name + " · 1" && app.tabTitle(c) == c.profile.name + " · 2")
    await transports[0].emit("ONLY_FIRST_TAB\r\n")
    try await waitUntil { String(decoding: a.terminal.view.getBufferAsData(), as: UTF8.self).contains("ONLY_FIRST_TAB") }
    #expect(!String(decoding: c.terminal.view.getBufferAsData(), as: UTF8.self).contains("ONLY_FIRST_TAB"))
    let slots = app.workspace.slots
    app.showConnections()
    #expect(app.pickerSelection == .new && app.newProfile.name.isEmpty && app.newProfile.endpoint.host.isEmpty)
    #expect(app.selectedSession === c && app.workspace.slots == slots)
    app.connectionPickerPresented = false
    app.requestCloseTab(a)
    try await waitUntil { !app.sessions.contains { $0.id == a.id } }
    #expect(b.connected && !a.connected && app.catalog.profiles.count == 2)
    await app.shutdown()
}

@MainActor
@Test func emptyPaneSelectionMovesVisibleTabAndHiddenTabsReplaceOnlyTheActivePane() async throws {
    let fixture = try SessionFixture(); defer { fixture.clean() }
    let transports = (0..<6).map { _ in FakeSessionConnection(home: fixture.remote(0)) }
    let app = fixture.app(transports: transports)
    var tabs: [SessionModel] = []
    for _ in 0..<6 { tabs.append(try app.connect(profile: fixture.profiles[0], password: "synthetic-only", rememberPassword: false)) }
    try await waitUntil { tabs.allSatisfy(\.terminalReady) }
    app.setLayout(.quad)
    #expect(Set(app.workspace.slots.compactMap { $0 }).count == 4)
    let original = app.workspace.slots
    let moved = try #require(original[0])
    let removed = try #require(original[3])
    app.removeFromSplit(3)
    #expect(app.workspace.activeSlot == 3 && app.workspace.slots[3] == nil && app.selectedSession == nil)
    #expect(app.sessions.first(where: { $0.id == removed })?.connected == true)
    app.selectTab(moved)
    #expect(app.workspace.slots[3] == moved && app.workspace.slots[0] == nil && app.selectedSessionID == moved)
    app.focusPane(0)
    let hidden = try #require(tabs.first { !app.workspace.slots.contains($0.id) })
    app.selectTab(hidden.id)
    #expect(app.workspace.slots[0] == hidden.id && app.workspace.slots[3] == moved)
    app.focusPane(2)
    let next = try #require(tabs.first { !app.workspace.slots.contains($0.id) })
    app.selectTab(next.id)
    #expect(app.workspace.slots[2] == next.id && app.workspace.slots[0] == hidden.id && app.workspace.slots[3] == moved)
    let occupied = app.workspace.slots
    app.selectTab(moved)
    #expect(app.workspace.activeSlot == 3 && app.workspace.slots == occupied)
    #expect(tabs.allSatisfy(\.connected) && Set(app.workspace.slots.compactMap { $0 }).count == 4)
    for tab in tabs { await app.closeTab(tab) }
    #expect(app.sessions.isEmpty && app.workspace.layout == .single && app.workspace.slots.allSatisfy { $0 == nil })
    #expect(app.workspace.activeSlot == 0 && app.workspace.expandedSessionID == nil && app.selectedSessionID == nil)
    app.setLayout(.quad)
    #expect(app.workspace.layout == .single && !app.connectionPickerPresented)
    await app.shutdown()
}

@MainActor
@Test func reconnectingOneOfTwoIdenticalServersKeepsTheExactTabAndCancelOwnership() async throws {
    let fixture = try SessionFixture(); defer { fixture.clean() }
    let gate = TestGate(); await gate.open()
    let first = FakeSessionConnection(home: fixture.remote(0))
    let second = FakeSessionConnection(home: fixture.remote(0), connectionGate: gate)
    let app = fixture.app(transports: [first, second])
    let a = try app.connect(profile: fixture.profiles[0], password: "synthetic-only", rememberPassword: false)
    let b = try app.connect(profile: fixture.profiles[0], password: "synthetic-only", rememberPassword: false)
    try await waitUntil { a.terminalReady && b.terminalReady }
    app.setLayout(.dual)
    await b.shutdown(); await gate.close()
    app.showConnection(b)
    #expect(app.pickerSession === b)
    #expect(try app.connectFromPicker(profile: b.profile, password: "synthetic-only", rememberPassword: false) === b)
    app.connectionPickerPresented = false
    try await waitUntil { !app.pickerCancelling }
    #expect(app.sessions.count == 2 && a.connected && a.terminalReady && !b.connected && !b.connecting)
    #expect(await first.connects == 1)
    #expect(await second.connects <= 2)
    await gate.open()
    app.showConnection(b)
    #expect(try app.connectFromPicker(profile: b.profile, password: "synthetic-only", rememberPassword: false) === b)
    try await waitUntil { b.terminalReady && !b.connecting }
    #expect(app.sessions.count == 2 && app.selectedSession === b && a.connected && !app.connectionPickerPresented)
    await app.shutdown()
}

@MainActor
@Test func automationAlwaysCreatesIndependentConnectionsAndRejectsAllHumanSessionIDs() async throws {
    let fixture = try SessionFixture(); defer { fixture.clean() }
    let humanTransport = FakeSessionConnection(home: fixture.remote(0))
    let agentTransport = FakeSessionConnection(home: fixture.remote(0))
    let otherAgentTransport = FakeSessionConnection(home: fixture.remote(0))
    let app = try await preparedApp(fixture, transports: [humanTransport, agentTransport, otherAgentTransport])
    let human = try app.connect(profile: fixture.profiles[0], password: nil, rememberPassword: true)
    try await waitUntil { human.terminalReady && !human.connecting }
    let humanText = Data(human.terminal.view.getBufferAsData())
    human.remote.selection = [fixture.remote(0) + "/payload.txt"]
    let history = app.catalog.recent
    let maximize = app.maximizeRequest, slots = app.workspace.slots
    app.showConnections(); app.useDraft(ConnectionProfile(name: "未完成的表单", endpoint: ConnectionEndpoint(host: "draft.example", port: 22, username: "tester")))
    let draft = app.newProfile
    let controller = try await backgroundController(app)
    let first = await controller.handle(ControlRequest(command: "connect", arguments: ["profile": human.profile.id.uuidString]))
    #expect(first.ok && app.backgroundSessions.count == 1)
    let agent = try #require(app.backgroundSessions.first)
    #expect(agent.origin == .automation && !agent.terminalRunning && agent.id != human.id)
    #expect(app.selectedSession === human && app.maximizeRequest == maximize && app.workspace.slots == slots)
    #expect(app.connectionPickerPresented && app.newProfile == draft && app.catalog.recent == history)
    let repeated = await controller.handle(ControlRequest(command: "connect", arguments: ["profile": human.profile.id.uuidString]))
    #expect(repeated.ok && app.backgroundSessions.count == 2 && app.sessions.count == 1)
    let sessions = await controller.handle(ControlRequest(command: "sessions.list"))
    if case .array(let values) = sessions.result { #expect(values.count == 2) } else { Issue.record("缺少后台会话列表") }
    for command in ["exec", "terminal.send", "terminal.read", "terminal.key", "files.list", "files.upload", "files.download", "disconnect", "close"] {
        let rejected = await controller.handle(ControlRequest(command: command, arguments: ["session": human.id.uuidString]))
        #expect(rejected.error?.code == "SESSION_SCOPE_MISMATCH")
    }
    await agentTransport.configureExecution(result: SSHCommandResult(stdout: Data("中文结果".utf8), stderr: Data("details".utf8), exitCode: 17))
    let result = await controller.handle(ControlRequest(command: "exec", arguments: ["session": agent.id.uuidString, "command": "synthetic-command"]))
    #expect(result.ok && result.result == .object(["stdout": .string("中文结果"), "stderr": .string("details"), "stdoutEncoding": .string("utf8"), "stderrEncoding": .string("utf8"), "exitCode": .number(17)]))
    let sent = await controller.handle(ControlRequest(command: "terminal.send", arguments: ["session": agent.id.uuidString, "text": "echo 测试", "enter": "true"]))
    let key = await controller.handle(ControlRequest(command: "terminal.key", arguments: ["session": agent.id.uuidString, "key": "ctrl-c"]))
    #expect(sent.ok && key.ok && agent.terminalReady)
    #expect(await agentTransport.inputs == [Data("echo 测试\r".utf8), Data([3])])
    #expect(await humanTransport.inputs.isEmpty)
    #expect(await humanTransport.commands.isEmpty)
    #expect(await otherAgentTransport.inputs.isEmpty)
    await agentTransport.emit("ONLY_AGENT_OUTPUT\r\n")
    try await waitUntil { String(decoding: agent.terminal.view.getBufferAsData(), as: UTF8.self).contains("ONLY_AGENT_OUTPUT") }
    let read = await controller.handle(ControlRequest(command: "terminal.read", arguments: ["session": agent.id.uuidString]))
    #expect(read.ok && Data(human.terminal.view.getBufferAsData()) == humanText)
    #expect(human.remote.selection == [fixture.remote(0) + "/payload.txt"] && app.selectedSession === human)
    #expect(app.catalog.recent == history && app.newProfile == draft && app.workspace.slots == slots)
    await controller.setEnabled(false)
    #expect(app.backgroundSessions.isEmpty && human.connected && human.terminalReady)
    #expect(await controller.handle(ControlRequest(command: "sessions.list")).error?.code == "DISABLED")
    await app.shutdown()
}

@MainActor
@Test func backgroundCancellationDisableAndStopLeaveHumanWorkRunning() async throws {
    let fixture = try SessionFixture(); defer { fixture.clean() }
    let gate = TestGate()
    let humanTransport = FakeSessionConnection(home: fixture.remote(1))
    let first = FakeSessionConnection(home: fixture.remote(0)), second = FakeSessionConnection(home: fixture.remote(1))
    await first.configureExecution(gate: gate)
    let app = try await preparedApp(fixture, transports: [humanTransport, first, second])
    let human = try app.connect(profile: fixture.profiles[1], password: nil, rememberPassword: true)
    let a = try app.connectBackground(profile: fixture.profiles[0]), b = try app.connectBackground(profile: fixture.profiles[1])
    try await waitUntil { human.terminalReady && a.connected && b.connected && !a.connecting && !b.connecting }
    let controller = try await backgroundController(app)
    let request = ControlRequest(command: "exec", arguments: ["session": a.id.uuidString, "command": "wait"])
    let pending = Task { await controller.handle(request) }
    try await waitUntil { a.automationRequests == 1 }
    #expect(await controller.handle(ControlRequest(command: "exec", arguments: ["session": b.id.uuidString, "command": "finish"])).ok)
    #expect(await controller.handle(ControlRequest(command: "exec", arguments: request.arguments)).error?.code == "BUSY")
    #expect(await controller.handle(ControlRequest(command: "cancel", arguments: ["request": request.id.uuidString])).ok)
    #expect((await pending.value).error?.code == "CANCELLED" && a.connected && b.connected)
    let again = Task { await controller.handle(ControlRequest(command: "exec", arguments: request.arguments)) }
    try await waitUntil { a.automationRequests == 1 }
    await controller.stopBackground(a.id)
    #expect((await again.value).error?.code == "CANCELLED" && !a.connected && b.connected)
    #expect(app.backgroundSessions.count == 1 && human.connected && app.selectedSession === human)
    await controller.setEnabled(false)
    #expect(app.backgroundSessions.isEmpty && !b.connected && human.connected)
    await app.shutdown()
    #expect(!human.connected && !human.terminalRunning)
}

@MainActor
@Test func backgroundTransfersShareReservationsAndCancelOnlyOwnedOperation() async throws {
    let fixture = try SessionFixture(); defer { fixture.clean() }
    let gate = TestGate()
    let humanTransport = FakeSessionConnection(home: fixture.remote(0), store: GatedFileStore(gate: gate))
    let agentTransport = FakeSessionConnection(home: fixture.remote(0))
    let app = try await preparedApp(fixture, transports: [humanTransport, agentTransport, FakeSessionConnection(home: fixture.remote(0))])
    let human = try app.connect(profile: fixture.profiles[0], password: nil, rememberPassword: true)
    var agent = try app.connectBackground(profile: fixture.profiles[0])
    try await waitUntil { human.terminalReady && agent.connected && !agent.connecting }
    let source = URL(fileURLWithPath: human.local.path).appendingPathComponent("isolated-upload.txt")
    let bytes = Data(repeating: 65, count: 128 * 1024); try bytes.write(to: source)
    await human.local.refresh(); human.local.selection = [source.path]
    human.transfer(upload: true)
    try await waitForReservations(app.reservations, active: 1)
    let controller = try await backgroundController(app)
    let request = ControlRequest(command: "files.upload", arguments: ["session": agent.id.uuidString, "destination": fixture.remote(0)], paths: [source.path])
    let pending = Task { await controller.handle(request) }
    try await waitForReservations(app.reservations, active: 1, waiting: 1)
    #expect(app.selectedSession === human && !app.connectionPickerPresented)
    #expect(await controller.handle(ControlRequest(command: "cancel", arguments: ["request": request.id.uuidString])).ok)
    #expect((await pending.value).error?.code == "CANCELLED" && human.transferring && human.connected)
    try await waitForReservations(app.reservations, active: 1, waiting: 0)
    await controller.setEnabled(false)
    #expect(human.connected && human.transferring && app.backgroundSessions.isEmpty)
    await controller.setEnabled(true)
    agent = try app.connectBackground(profile: fixture.profiles[0])
    try await waitUntil { agent.connected && !agent.connecting }
    await gate.open(); try await waitUntil { !human.transferring }
    #expect(try Data(contentsOf: source) == bytes)
    #expect(try Data(contentsOf: URL(fileURLWithPath: fixture.remote(0)).appendingPathComponent(source.lastPathComponent)) == bytes)
    let conflict = Task { await controller.handle(ControlRequest(command: "files.upload", arguments: ["session": agent.id.uuidString, "destination": fixture.remote(0)], paths: request.paths)) }
    try await waitUntil { agent.conflictRequest != nil }
    #expect(human.conflictRequest == nil && app.selectedSession === human && !app.connectionPickerPresented)
    agent.finishConflict(.skip)
    #expect((await conflict.value).ok && agent.skipped == 1)
    #expect(try !FileManager.default.contentsOfDirectory(atPath: fixture.remote(0)).contains { $0.contains(".part") })
    await controller.setEnabled(false); await app.shutdown()
    try await waitForReservations(app.reservations, active: 0, waiting: 0)
}

@MainActor
@Test func missingBackgroundAuthenticationAndNetworkFailureNeverChangeHumanFormOrUseFallback() async throws {
    let fixture = try SessionFixture(); defer { fixture.clean() }
    let failing = FakeSessionConnection(home: fixture.remote(0), failure: .network)
    let app = try await preparedApp(fixture, transports: [FakeSessionConnection(home: fixture.remote(0)), failing])
    let human = try app.connect(profile: fixture.profiles[0], password: nil, rememberPassword: true)
    try await waitUntil { human.terminalReady }
    app.showConnections()
    let draft = app.newProfile, selection = app.pickerSelection, slots = app.workspace.slots
    let controller = try await backgroundController(app)
    let failure = await controller.handle(ControlRequest(command: "connect", arguments: ["profile": human.profile.id.uuidString]))
    #expect(failure.error?.code == "CONNECT_FAILED" && app.backgroundSessions.isEmpty)
    #expect(human.connected && app.selectedSession === human && app.workspace.slots == slots)
    #expect(app.connectionPickerPresented && app.newProfile == draft && app.pickerSelection == selection)
    var incomplete = fixture.profiles[1]; incomplete.lastValidatedAt = nil
    try app.catalog.save(incomplete)
    let missing = await controller.handle(ControlRequest(command: "connect", arguments: ["profile": incomplete.id.uuidString]))
    #expect(missing.error?.code == "AUTH_REQUIRED" && controller.connectionNotices[incomplete.id] != nil)
    #expect(app.newProfile == draft && app.pickerSelection == selection && app.selectedSession === human)
    #expect(await failing.connects == 1)
    await controller.setEnabled(false); await app.shutdown()
}

@MainActor
@Test func fourPaneMountsOneTerminalPerSessionAndBackgroundCallsNeverStealNativeFocus() async throws {
    let fixture = try SessionFixture(); defer { fixture.clean() }
    let transports = (0..<6).map { _ in FakeSessionConnection(home: fixture.remote(0)) }
    let app = try await preparedApp(fixture, transports: transports)
    var tabs: [SessionModel] = []
    for index in 0..<5 {
        var profile = fixture.profiles[0]
        if index > 0 { profile.id = UUID(); profile.endpoint.host = "grid-\(index).example"; profile.name = "测试服务器 \(index + 1)" }
        tabs.append(try app.connect(profile: profile, password: "synthetic-only", rememberPassword: true))
    }
    try await waitUntil { tabs.allSatisfy(\.terminalReady) }
    app.setLayout(.quad)
    let human = tabs[4]
    let hosting = NSHostingView(rootView: WorkspaceView(app: app))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = hosting
    defer { window.close() }
    func layout() async throws { try await Task.sleep(for: .milliseconds(120)); hosting.layoutSubtreeIfNeeded() }
    try await layout()
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    for tab in tabs {
        let expected = app.workspace.slots.contains(tab.id) ? 1 : 0
        #expect(descendants(hosting).filter { $0 === tab.terminal.view }.count == expected)
    }
    #expect(window.makeFirstResponder(human.terminal.view))
    let focused = window.firstResponder, selection = app.selectedSessionID, slots = app.workspace.slots
    let controller = try await backgroundController(app)
    #expect(await controller.handle(ControlRequest(command: "connect", arguments: ["profile": human.profile.id.uuidString])).ok)
    let background = try #require(app.backgroundSessions.first)
    #expect(await controller.handle(ControlRequest(command: "terminal.send", arguments: ["session": background.id.uuidString, "text": "agent-only", "enter": "true"])).ok)
    #expect(window.firstResponder === focused && app.selectedSessionID == selection && app.workspace.slots == slots)
    #expect(background.terminal.view.window == nil && !descendants(hosting).contains { $0 === background.terminal.view })
    #expect(await transports[4].inputs.isEmpty)
    let hidden = try #require(tabs.first { !slots.contains($0.id) })
    await transports[tabs.firstIndex(where: { $0.id == hidden.id })!].emit("HIDDEN_OUTPUT\r\n")
    try await waitUntil { String(decoding: hidden.terminal.view.getBufferAsData(), as: UTF8.self).contains("HIDDEN_OUTPUT") }
    app.focusPane(0); app.selectTab(hidden.id)
    try await layout()
    #expect(descendants(hosting).filter { $0 === hidden.terminal.view }.count == 1)
    app.selectTab(hidden.id); app.workspace.expandedSessionID = hidden.id
    try await layout()
    #expect(descendants(hosting).filter { $0 === hidden.terminal.view }.count == 1)
    #expect(descendants(hosting).contains { $0 is NSOutlineView })
    app.workspace.expandedSessionID = nil
    try await layout()
    #expect(app.workspace.slots[0] == hidden.id && tabs.allSatisfy(\.connected))
    await controller.setEnabled(false); await app.shutdown()
}

@MainActor
@Test func closingTabWithTransferRequiresConfirmationAndCancelKeepsItRunning() async throws {
    let fixture = try SessionFixture(); defer { fixture.clean() }
    let gate = TestGate()
    let app = fixture.app(transports: [FakeSessionConnection(home: fixture.remote(0), store: GatedFileStore(gate: gate))])
    let session = try app.connect(profile: fixture.profiles[0], password: "synthetic-only", rememberPassword: false)
    try await waitUntil { session.terminalReady }
    let source = URL(fileURLWithPath: session.local.path).appendingPathComponent("close-check.txt")
    try Data("preserve-source".utf8).write(to: source)
    await session.local.refresh(); session.local.selection = [source.path]; session.transfer(upload: true)
    try await waitUntil { session.transferring }
    app.requestCloseTab(session)
    #expect(app.closingSessionID == session.id && session.connected && session.transferring)
    app.closingSessionID = nil
    #expect(session.connected && session.transferring)
    app.requestCloseTab(session); await app.closeTab(session)
    #expect(!session.connected && !session.transferring && app.sessions.isEmpty)
    #expect(try Data(contentsOf: source) == Data("preserve-source".utf8))
    #expect(try !FileManager.default.contentsOfDirectory(atPath: fixture.remote(0)).contains { $0.contains(".part") })
    await app.shutdown()
}

@MainActor
@Test func changingLiveWorkspaceLayoutKeepsTerminalMountedReadableAndInteractive() async throws {
    let fixture = try SessionFixture(); defer { fixture.clean() }
    let first = FakeSessionConnection(home: fixture.remote(0)), second = FakeSessionConnection(home: fixture.remote(1))
    let app = fixture.app(transports: [first, second])
    let a = try app.connect(profile: fixture.profiles[0], password: "synthetic-only", rememberPassword: false)
    try await waitUntil { a.terminalReady }
    let hosting = NSHostingView(rootView: WorkspaceView(app: app))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = hosting
    defer { window.close() }
    func layout() async throws { try await Task.sleep(for: .milliseconds(150)); hosting.layoutSubtreeIfNeeded() }
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    try await layout()
    await first.emit("BEFORE_SPLIT_UNIQUE_MARKER\r\n")
    try await waitUntil { String(decoding: a.terminal.view.getBufferAsData(), as: UTF8.self).contains("BEFORE_SPLIT_UNIQUE_MARKER") }
    #expect(window.makeFirstResponder(a.terminal.view))
    for next in [WorkspaceLayout.dual, .quad, .single, .dual] {
        app.setLayout(next)
        try await layout()
        #expect(descendants(hosting).filter { $0 === a.terminal.view }.count == 1)
        #expect(a.terminal.view.window === window)
        #expect(a.terminal.view.bounds.width > 100 && a.terminal.view.bounds.height > 100)
        #expect(String(decoding: a.terminal.view.getBufferAsData(), as: UTF8.self).contains("BEFORE_SPLIT_UNIQUE_MARKER"))
        #expect(window.firstResponder === a.terminal.view)
        #expect(await first.connects == 1)
    }
    let b = try app.connect(profile: fixture.profiles[1], password: "synthetic-only", rememberPassword: false)
    try await waitUntil { b.terminalReady }
    try await layout()
    app.setLayout(.single); try await layout()
    app.setLayout(.dual); try await layout()
    for session in [a, b] {
        #expect(descendants(hosting).filter { $0 === session.terminal.view }.count == 1)
        #expect(session.terminal.view.window === window)
        let mount = try #require(session.terminal.view.superview)
        let point = session.terminal.view.convert(NSPoint(x: 40, y: 40), to: mount.superview)
        let hit = mount.hitTest(point)
        #expect(hit === session.terminal.view || hit?.isDescendant(of: session.terminal.view) == true)
        #expect(window.makeFirstResponder(session.terminal.view))
        session.terminal.view.insertText("split-input" as NSString, replacementRange: NSRange(location: NSNotFound, length: 0))
    }
    for _ in 0..<200 {
        if await first.inputs == [Data("split-input".utf8)] { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await first.inputs == [Data("split-input".utf8)])
    #expect(await second.inputs == [Data("split-input".utf8)])
    app.selectTab(a.id); app.workspace.expandedSessionID = a.id
    try await layout()
    app.workspace.expandedSessionID = nil
    try await layout()
    #expect(descendants(hosting).filter { $0 === a.terminal.view }.count == 1)
    #expect(a.terminal.view.window === window && b.terminal.view.window === window)
    #expect(await first.sizes.count > 1)
    #expect(await second.sizes.count > 1)
    await app.shutdown()
}

@MainActor
@Test func nativeTerminalFocusSelectsItsPaneBeforeMenusAct() async throws {
    let fixture = try SessionFixture(); defer { fixture.clean() }
    let app = fixture.app(transports: [FakeSessionConnection(home: fixture.remote(0)), FakeSessionConnection(home: fixture.remote(1))])
    let a = try app.connect(profile: fixture.profiles[0], password: "synthetic-only", rememberPassword: false)
    let b = try app.connect(profile: fixture.profiles[1], password: "synthetic-only", rememberPassword: false)
    try await waitUntil { a.terminalReady && b.terminalReady }
    app.setLayout(.dual)
    let hosting = NSHostingView(rootView: WorkspaceView(app: app))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = hosting
    defer { window.close() }
    func focusSettled(_ label: String, _ condition: () -> Bool) async throws {
        do { try await waitUntil(condition) }
        catch { throw HostDockError("焦点检查超时：" + label) }
    }
    try await Task.sleep(for: .milliseconds(120)); hosting.layoutSubtreeIfNeeded()
    #expect(window.makeFirstResponder(a.terminal.view))
    try await focusSettled("首次聚焦 A") { app.selectedSession === a }
    #expect(app.workspace.slots[app.workspace.activeSlot] == a.id)
    app.selectTab(b.id)
    let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 50, y: 80), modifierFlags: [],
        timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    a.terminal.view.mouseDown(with: click)
    #expect(app.selectedSession === a)
    app.selectTab(b.id)
    focusWorkspaceSession(app, id: b.id)
    try await Task.sleep(for: .milliseconds(80)); hosting.layoutSubtreeIfNeeded()
    try await focusSettled("点击 B 标签") { window.firstResponder === b.terminal.view }
    #expect(app.workspace.slots[app.workspace.activeSlot] == b.id)
    #expect(window.makeFirstResponder(a.terminal.view))
    try await focusSettled("原生焦点切到 A") { app.selectedSession === a }
    #expect(window.makeFirstResponder(b.terminal.view))
    try await focusSettled("原生焦点切到 B") { app.selectedSession === b }
    #expect(app.workspace.slots[app.workspace.activeSlot] == b.id)
    let pane = try #require(app.workspace.slots.firstIndex(of: b.id))
    app.removeFromSplit(pane)
    try await Task.sleep(for: .milliseconds(80)); hosting.layoutSubtreeIfNeeded()
    try await focusSettled("移出分屏清除焦点") { window.firstResponder !== a.terminal.view && window.firstResponder !== b.terminal.view }
    #expect(app.selectedSessionID == nil && b.connected && b.terminalReady && b.terminal.view.window == nil)
    app.selectTab(b.id)
    focusWorkspaceSession(app, id: b.id)
    try await Task.sleep(for: .milliseconds(80)); hosting.layoutSubtreeIfNeeded()
    try await focusSettled("重新填入 B") { window.firstResponder === b.terminal.view }
    app.selectedSession?.disconnect()
    try await waitUntil { !b.connected && !b.disconnecting }
    #expect(a.connected && !b.connected)
    await app.shutdown()
}
