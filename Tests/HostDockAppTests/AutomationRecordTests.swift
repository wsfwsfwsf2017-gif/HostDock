import AppKit
import Foundation
import HostDockCore
import SwiftUI
import Testing
@testable import HostDock

private actor FailingRecordStorage: AutomationRecordStorage {
    let base: FileAutomationRecordStorage
    var failing = false
    var writes = 0
    init(_ directory: URL) { base = FileAutomationRecordStorage(directory: directory) }
    func fail(_ value: Bool) { failing = value }
    func loadRecords() async throws -> AutomationRecordSnapshot { try await base.loadRecords() }
    func loadEvents(_ id: UUID) async throws -> [AutomationRecordEvent] { try await base.loadEvents(id) }
    func loadProtections() async throws -> [AutomationProtection] { try await base.loadProtections() }
    func write(_ command: AutomationRecordWrite) async throws {
        writes += 1
        if failing { throw HostDockError("合成写入失败") }
        try await base.write(command)
    }
    func flush() async throws { if failing { throw HostDockError("合成刷盘失败") }; try await base.flush() }
}

@MainActor
func recordController(_ fixture: SessionFixture, transports: [FakeSessionConnection], profiles: [ConnectionProfile]? = nil,
                              records: AutomationRecords? = nil) async throws -> (AppModel, AutomationController) {
    let credentials = MemoryCredentialStore()
    var profiles = profiles ?? fixture.profiles
    for index in profiles.indices {
        profiles[index].lastValidatedAt = Date()
        try await credentials.save("synthetic-auth-never-log", account: profiles[index].credentialAccount)
    }
    let app = fixture.app(transports: transports, storage: MemoryConnectionStorage(ConnectionDocument(profiles: profiles)), credentials: credentials, automationRecords: records)
    await app.refreshSavedConnections()
    let defaults = try #require(UserDefaults(suiteName: "HostDock-records-" + UUID().uuidString))
    let socket = fixture.root.appendingPathComponent("control.sock")
    let controller = AutomationController(app: app, defaults: defaults, socketURL: socket)
    await controller.setEnabled(true)
    #expect(controller.enabled)
    return (app, controller)
}

@MainActor
@Test func aiRecordStoresOrderedResultsButNotAuthenticationInputOrPolling() async throws {
    let fixture = try SessionFixture(); defer { fixture.clean() }
    let transport = FakeSessionConnection(home: fixture.remote(0))
    await transport.setEchoInput(false)
    await transport.configureExecution(result: SSHCommandResult(stdout: Data("中文输出".utf8), stderr: Data("失败详情".utf8), exitCode: 7))
    let (app, controller) = try await recordController(fixture, transports: [transport])
    #expect(await controller.handle(ControlRequest(command: "connect", arguments: ["profile": fixture.profiles[0].id.uuidString])).ok)
    let session = try #require(app.backgroundSessions.first), history = app.automationRecords
    let record = try #require(history.record(sessionID: session.id))
    #expect(!session.terminalRunning && app.workspaceTabIDs.isEmpty)
    let command = ControlRequest(command: "exec", arguments: ["session": session.id.uuidString, "command": "printf synthetic"])
    #expect(await controller.handle(command).ok)
    #expect(await controller.handle(ControlRequest(command: "terminal.send", arguments: ["session": session.id.uuidString, "text": "synthetic-input-not-echoed", "enter": "true"])).ok)
    await transport.emit("PTY_ONLY\r\n")
    try await waitUntil { String(decoding: session.terminal.view.getBufferAsData(), as: UTF8.self).contains("PTY_ONLY") }
    #expect(await controller.handle(ControlRequest(command: "files.list", arguments: ["session": session.id.uuidString, "path": fixture.remote(0)])).ok)
    for _ in 0..<3 { _ = await controller.handle(ControlRequest(command: "terminal.read", arguments: ["session": session.id.uuidString])) }
    try await history.flush()
    await history.open(record)
    #expect(record.hasTerminal && !record.loading)
    #expect(record.events.map(\.sequence) == Array(0..<record.events.count))
    #expect(record.operations.filter { $0.title == "exec" }.count == 1)
    #expect(record.operations.first { $0.requestID == command.id && $0.kind == .result }?.result == .object([
        "stdout": .string("中文输出"), "stderr": .string("失败详情"), "exitCode": .number(7), "stdoutEncoding": .string("utf8"), "stderrEncoding": .string("utf8")]))
    #expect(!record.operations.contains { $0.title == "terminal.read" })
    let data = try JSONEncoder().encode(record.events), text = String(decoding: data, as: UTF8.self)
    #expect(!text.contains("synthetic-auth-never-log") && !text.contains("synthetic-input-not-echoed"))
    #expect(text.contains("printf synthetic") && text.contains("输入正文不单独保存"))
    history.closeView(record.id)
    await controller.setEnabled(false); try await history.flush(); await app.shutdown()
    let reopened = AutomationRecords(storage: FileAutomationRecordStorage(directory: fixture.root.appendingPathComponent("automation")))
    await reopened.restore()
    let saved = try #require(reopened.records.first)
    #expect(!saved.active && saved.header.sessionID == session.id && saved.id == record.id)
    await reopened.open(saved)
    #expect(saved.hasTerminal && saved.operations.contains { $0.title == "exec" })
    try await reopened.flush()
}

@MainActor
@Test func aiRecordTabsDeduplicateCloseAndSplitWithoutTakingOverBackgroundTerminal() async throws {
    let fixture = try SessionFixture(); defer { fixture.clean() }
    let humanTransport = FakeSessionConnection(home: fixture.remote(0)), background = FakeSessionConnection(home: fixture.remote(0))
    let (app, controller) = try await recordController(fixture, transports: [humanTransport, background])
    let human = try app.connect(profile: fixture.profiles[0], password: nil, rememberPassword: true)
    try await waitUntil { human.terminalReady }
    let humanBuffer = Data(human.terminal.view.getBufferAsData()), selection = app.selectedSessionID, maximize = app.maximizeRequest
    #expect(await controller.handle(ControlRequest(command: "connect", arguments: ["profile": human.profile.id.uuidString])).ok)
    let session = try #require(app.backgroundSessions.first), history = app.automationRecords
    let record = try #require(history.record(sessionID: session.id))
    #expect(app.selectedSessionID == selection && !session.terminalRunning)
    app.showRecord(record); app.showRecord(record)
    try await waitUntil { record.loaded && !record.loading }
    #expect(app.recordTabs.count == 1 && app.workspaceTabIDs == [human.id, record.id] && !session.terminalRunning)
    #expect(record.id != session.id && app.selectedSession == nil && app.selectedRecord === record)
    record.showingTerminal = true
    app.setLayout(.quad)
    #expect(Set(app.workspace.slots.compactMap { $0 }) == Set([human.id, record.id]))
    #expect(await controller.handle(ControlRequest(command: "terminal.send", arguments: ["session": session.id.uuidString, "text": "only agent"])).ok)
    await background.emit("MIRRORED\r\n")
    try await waitUntil { record.hasTerminal }
    let mirror = record.terminal()
    #expect(mirror !== session.terminal && mirror.view !== session.terminal.view)
    #expect(mirror.view.readOnly && !mirror.view.allowMouseReporting)
    try await waitUntil { String(decoding: mirror.view.getBufferAsData(), as: UTF8.self).contains("MIRRORED") }
    let inputs = await background.inputs, sizes = await background.sizes.count
    var forwarded = false
    mirror.ready = true; mirror.onInput = { _ in forwarded = true }; mirror.onResize = { _, _ in forwarded = true }
    mirror.send(source: mirror.view, data: [3][...])
    mirror.view.insertText("never send", replacementRange: NSRange(location: 0, length: 0))
    mirror.view.paste(NSNull())
    mirror.sizeChanged(source: mirror.view, newCols: 40, newRows: 10)
    let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control], timestamp: 0,
        windowNumber: 0, context: nil, characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8))
    mirror.view.keyDown(with: key)
    #expect(!forwarded)
    #expect(await background.inputs == inputs)
    #expect(await background.sizes.count == sizes)
    #expect(Data(human.terminal.view.getBufferAsData()) == humanBuffer && app.maximizeRequest == maximize)
    let slot = try #require(app.workspace.slots.firstIndex(of: record.id))
    app.removeFromSplit(slot)
    #expect(record.loaded && session.connected)
    app.selectTab(record.id); app.setLayout(.dual); app.setLayout(.single)
    #expect(record.showingTerminal)
    app.closeRecord(record.id)
    #expect(session.connected && app.recordTabs.isEmpty && !record.loaded)
    app.showRecord(record)
    await app.closeAllTabs()
    #expect(app.workspaceTabIDs.isEmpty && app.workspace.layout == .single && app.backgroundSessions.count == 1 && session.connected)
    await controller.setEnabled(false); try await history.flush(); await app.shutdown()
}

@MainActor
@Test func aiRecordPermissionsCorruptionAndInterruptedSessionAreExplicit() async throws {
    let fixture = try SessionFixture(); defer { fixture.clean() }
    let directory = fixture.root.appendingPathComponent("records"), storage = FileAutomationRecordStorage(directory: fixture.root.appendingPathComponent("records"))
    let history = AutomationRecords(storage: storage); await history.restore()
    let record = history.begin(profile: fixture.profiles[0], sessionID: UUID())
    history.emit(record, kind: .request, title: "exec", detail: "synthetic")
    try await history.flush()
    let fm = FileManager.default
    #expect((try fm.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    for file in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
        #expect((try fm.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
    let restored = AutomationRecords(storage: FileAutomationRecordStorage(directory: directory)); await restored.restore()
    let saved = try #require(restored.records.first)
    #expect(!saved.active && saved.header.endReason == "上次运行已结束")
    try await restored.flush()
    let file = directory.appendingPathComponent(record.id.uuidString + ".jsonl")
    let corrupt = Data("{incomplete".utf8); try corrupt.write(to: file)
    await restored.open(saved)
    #expect(saved.notice?.contains("原文件已保留") == true)
    #expect(try Data(contentsOf: file) == corrupt)
    restored.closeView(saved.id)
    try Data("broken".utf8).write(to: directory.appendingPathComponent(UUID().uuidString + ".json"))
    let corruptHistory = AutomationRecords(storage: FileAutomationRecordStorage(directory: directory)); await corruptHistory.restore()
    #expect(corruptHistory.notice != nil && corruptHistory.records.count == 1)
    try await corruptHistory.flush()
}

@MainActor
@Test func aiRecordCapacityTruncatesAndPrunesOnlyEndedUnopenedHistory() async throws {
    let fixture = try SessionFixture(); defer { fixture.clean() }
    var clock = Date()
    let history = AutomationRecords(storage: FileAutomationRecordStorage(directory: fixture.root.appendingPathComponent("records")), now: { clock }, recordLimit: 900, totalLimit: 1300)
    await history.restore()
    let old = history.begin(profile: fixture.profiles[0], sessionID: UUID())
    history.emit(old, kind: .request, title: "old", detail: String(repeating: "a", count: 250))
    history.end(sessionID: old.header.sessionID!, reason: "ended")
    await history.open(old)
    let active = history.begin(profile: fixture.profiles[0])
    for _ in 0..<20 { history.emit(active, kind: .request, title: "output", detail: String(repeating: "b", count: 300)) }
    #expect(active.header.truncated && active.active && history.records.contains { $0.id == old.id })
    #expect(active.notice?.contains("AI 任务继续运行") == true)
    history.closeView(old.id)
    let next = history.begin(profile: fixture.profiles[1])
    history.emit(next, kind: .request, detail: String(repeating: "c", count: 300))
    #expect(!history.records.contains { $0.id == old.id })
    clock = clock.addingTimeInterval(31 * 86400)
    _ = history.begin(profile: fixture.profiles[0])
    #expect(history.records.contains { $0.id == active.id })
    try await history.flush()
}

@MainActor
@Test func aiRecordThirtyDayRetentionProtectsOpenHistoryAndActiveRecords() async throws {
    let fixture = try SessionFixture(); defer { fixture.clean() }
    var clock = Date()
    let history = AutomationRecords(storage: FileAutomationRecordStorage(directory: fixture.root.appendingPathComponent("records")), now: { clock })
    await history.restore()
    let a = history.begin(profile: fixture.profiles[0], sessionID: UUID()), b = history.begin(profile: fixture.profiles[1], sessionID: UUID())
    history.end(sessionID: a.header.sessionID!, reason: "ended"); history.end(sessionID: b.header.sessionID!, reason: "ended")
    await history.open(a)
    let active = history.begin(profile: fixture.profiles[0])
    clock = clock.addingTimeInterval(30 * 86400 + 1)
    _ = history.begin(profile: fixture.profiles[0])
    #expect(history.records.contains { $0.id == a.id } && history.records.contains { $0.id == active.id })
    #expect(!history.records.contains { $0.id == b.id })
    history.closeView(a.id); _ = history.begin(profile: fixture.profiles[0])
    #expect(!history.records.contains { $0.id == a.id })
    try await history.flush()
}

@MainActor
@Test func aiRecordWriteFailureRetainsPendingContentAndSerialRetryDoesNotDuplicate() async throws {
    let fixture = try SessionFixture(); defer { fixture.clean() }
    let storage = FailingRecordStorage(fixture.root.appendingPathComponent("records"))
    let history = AutomationRecords(storage: storage); await history.restore(); await storage.fail(true)
    let record = history.begin(profile: fixture.profiles[0], sessionID: UUID())
    for index in 0..<15 { history.emit(record, kind: .request, detail: "line \(index)") }
    await #expect(throws: (any Error).self) { try await history.flush() }
    #expect(history.notice != nil)
    await history.open(record)
    #expect(record.events.count == 15)
    await storage.fail(false)
    async let first: Void = history.flush()
    async let second: Void = history.flush()
    history.emit(record, kind: .request, detail: "last")
    try await first; try await second; try await history.flush()
    let saved = try await storage.loadEvents(record.id)
    #expect(saved.count == 16 && Set(saved.map(\.id)).count == 16 && saved.map(\.sequence) == Array(0..<16))
    #expect(history.notice == nil)
}

@MainActor
@Test func aiProtectionStopsAllAccountsAtTargetAndReturnsProtectedForInflightAndOldIDs() async throws {
    let fixture = try SessionFixture(); defer { fixture.clean() }
    var same = fixture.profiles[0]; same.id = UUID(); same.endpoint.username = "second-account"; same.endpoint.port = 2222
    let humanTransport = FakeSessionConnection(home: fixture.remote(0)), first = FakeSessionConnection(home: fixture.remote(0)), second = FakeSessionConnection(home: fixture.remote(0)), other = FakeSessionConnection(home: fixture.remote(1))
    let gate = TestGate(); await first.configureExecution(gate: gate)
    let (app, controller) = try await recordController(fixture, transports: [humanTransport, first, second, other], profiles: fixture.profiles + [same])
    let human = try app.connect(profile: fixture.profiles[0], password: nil, rememberPassword: true)
    try await waitUntil { human.terminalReady }
    for profile in [fixture.profiles[0], same, fixture.profiles[1]] {
        #expect(await controller.handle(ControlRequest(command: "connect", arguments: ["profile": profile.id.uuidString])).ok)
    }
    let targets = Array(app.backgroundSessions.prefix(2)), unaffected = try #require(app.backgroundSessions.last)
    let request = ControlRequest(command: "exec", arguments: ["session": targets[0].id.uuidString, "command": "wait"])
    let inflight = Task { await controller.handle(request) }
    for _ in 0..<100 { if await gate.entered { break }; try await Task.sleep(for: .milliseconds(5)) }
    #expect(await gate.entered)
    await controller.protectAndStop(targets[0].id)
    let response = await inflight.value
    #expect(!response.ok && response.error?.code == "SERVER_PROTECTED")
    if case .object(let data) = response.result { #expect(data["retryable"] == .bool(false) && data["protectedUntil"] != nil) }
    else { Issue.record("保护错误缺少截止时间") }
    #expect(app.backgroundSessions.count == 1 && unaffected.connected && human.connected)
    #expect(targets.allSatisfy { !$0.connected } && app.selectedSession === human)
    let history = app.automationRecords
    #expect(history.protectedServers.count == 1 && history.record(sessionID: targets[0].id)?.header.endReason?.contains("保护") == true)
    for profile in [fixture.profiles[0], same] {
        #expect(await controller.handle(ControlRequest(command: "connect", arguments: ["profile": profile.id.uuidString])).error?.code == "SERVER_PROTECTED")
    }
    for command in ["exec", "terminal.send", "terminal.read", "terminal.key", "files.list", "files.upload", "files.download"] {
        #expect(await controller.handle(ControlRequest(command: command, arguments: ["session": targets[0].id.uuidString])).error?.code == "SERVER_PROTECTED")
    }
    #expect(await controller.handle(ControlRequest(command: "disconnect", arguments: ["session": targets[0].id.uuidString])).ok)
    #expect(await controller.handle(ControlRequest(command: "status")).ok)
    #expect(await controller.handle(ControlRequest(command: "exec", arguments: ["session": unaffected.id.uuidString, "command": "safe"])).ok)
    #expect(await controller.handle(ControlRequest(command: "exec", arguments: ["session": human.id.uuidString])).error?.code == "SESSION_SCOPE_MISMATCH")
    await history.clearHistory()
    #expect(!history.protectedServers.isEmpty)
    let reopened = AutomationRecords(storage: FileAutomationRecordStorage(directory: fixture.root.appendingPathComponent("automation"))); await reopened.restore()
    #expect(reopened.protection(sessionID: targets[0].id) != nil)
    await reopened.release(AutomationRecords.serverKey(same.targetHost))
    #expect(reopened.protectedServers.isEmpty)
    await controller.setEnabled(false); try await history.flush(); try await reopened.flush(); await app.shutdown()
}

@MainActor
@Test func aiProtectionIsFiveMinutesNormalizesTargetAndDoesNotLockWholeGateway() async throws {
    let fixture = try SessionFixture(); defer { fixture.clean() }
    var clock = Date()
    let storage = FileAutomationRecordStorage(directory: fixture.root.appendingPathComponent("records"))
    let history = AutomationRecords(storage: storage, now: { clock }); await history.restore()
    let id = UUID(); history.protect(host: "HOST.Example.", sessionIDs: [id])
    #expect(history.protection(host: "host.example")?.until == clock.addingTimeInterval(300))
    #expect(history.protection(host: "other.example") == nil)
    #expect(AutomationRecords.serverKey("[2001:0db8::1]") == AutomationRecords.serverKey("2001:db8::1"))
    clock = clock.addingTimeInterval(299)
    #expect(history.protection(sessionID: id) != nil)
    clock = clock.addingTimeInterval(1)
    #expect(history.protection(sessionID: id) == nil)
    history.protect(host: "192.0.2.10", sessionIDs: [id]); try await history.flush()
    let restored = AutomationRecords(storage: FileAutomationRecordStorage(directory: fixture.root.appendingPathComponent("records")), now: { clock }); await restored.restore()
    #expect(restored.protection(host: "192.0.2.10") != nil && restored.protection(host: "192.0.2.11") == nil)
    await restored.release("192.0.2.10")
    let released = try await storage.loadProtections()
    #expect(released.isEmpty)
}

@MainActor
@Test func aiProtectionFailsClosedOnCorruptionAndStaysInMemoryWhenWriteFails() async throws {
    let fixture = try SessionFixture(); defer { fixture.clean() }
    let directory = fixture.root.appendingPathComponent("protected")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("protections.json"), original = Data("corrupt-protection".utf8)
    try original.write(to: file)
    let history = AutomationRecords(storage: FileAutomationRecordStorage(directory: directory))
    let (app, controller) = try await recordController(fixture, transports: [], records: history)
    #expect(history.protectionFailure != nil)
    #expect(await controller.handle(ControlRequest(command: "connect", arguments: ["profile": fixture.profiles[0].id.uuidString])).error?.code == "PROTECTION_STATE_UNAVAILABLE")
    #expect(app.backgroundSessions.isEmpty)
    #expect(try Data(contentsOf: file) == original)
    try JSONEncoder().encode([AutomationProtection]()).write(to: file)
    await history.retryProtectionLoad(); #expect(history.protectionFailure == nil)
    await controller.setEnabled(false); await app.shutdown()
    let failing = FailingRecordStorage(fixture.root.appendingPathComponent("failing"))
    let secondHistory = AutomationRecords(storage: failing)
    let (secondApp, secondController) = try await recordController(fixture, transports: [FakeSessionConnection(home: fixture.remote(0))], records: secondHistory)
    #expect(await secondController.handle(ControlRequest(command: "connect", arguments: ["profile": fixture.profiles[0].id.uuidString])).ok)
    let session = try #require(secondApp.backgroundSessions.first)
    await failing.fail(true)
    await secondController.protectAndStop(session.id)
    #expect(secondApp.backgroundSessions.isEmpty && secondHistory.protection(host: session.profile.targetHost) != nil)
    #expect(secondController.notice?.contains("重启后的保护未获保证") == true)
    #expect(await secondController.handle(ControlRequest(command: "connect", arguments: ["profile": session.profile.id.uuidString])).error?.code == "SERVER_PROTECTED")
    await failing.fail(false); try await secondHistory.flush()
    #expect(try await failing.loadProtections().count == 1)
    await secondController.setEnabled(false); await secondApp.shutdown()
}
