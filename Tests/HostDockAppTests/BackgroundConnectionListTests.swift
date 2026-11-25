import Foundation
import HostDockCore
import Testing
@testable import HostDock

@MainActor
@Test func currentConnectionsUseAttemptOrderAndClearOnlyFinishedIDs() async throws {
    let fixture = try SessionFixture(); defer { fixture.clean() }
    let first = FakeSessionConnection(home: fixture.remote(0))
    let gate = TestGate(), work = TestGate()
    let delayed = FakeSessionConnection(home: fixture.remote(0), connectionGate: gate)
    let online = FakeSessionConnection(home: fixture.remote(0))
    let badPassword = FakeSessionConnection(home: fixture.remote(1), failure: .authentication)
    let (app, controller) = try await recordController(fixture, transports: [first, delayed, online, badPassword])
    func connect(_ profile: Int = 0) async -> ControlResponse {
        await controller.handle(ControlRequest(command: "connect", arguments: ["profile": fixture.profiles[profile].id.uuidString]))
    }
    try #require(await connect().ok)
    let oldest = try #require(app.backgroundSessions.first)
    let record = try #require(app.automationRecords.record(sessionID: oldest.id))
    app.showRecord(record)
    try #require(await controller.handle(ControlRequest(command: "terminal.send", arguments: ["session": oldest.id.uuidString, "text": "synthetic"])).ok)

    let laterFailure = Task { await connect() }
    try await waitUntil { app.backgroundSessions.count == 2 }
    for _ in 0..<400 { if await gate.entered { break }; try await Task.sleep(for: .milliseconds(25)) }
    try #require(await gate.entered)
    let delayedID = try #require(app.backgroundSessions.last?.id)
    try #require(await connect().ok)
    let newest = try #require(app.backgroundSessions.last)
    #expect(controller.currentConnections.map(\.id) == [newest.id, delayedID, oldest.id])
    await first.emit("still here\r\n")
    try await waitUntil { String(decoding: oldest.terminal.view.getBufferAsData(), as: UTF8.self).contains("still here") }
    #expect(controller.currentConnections.map(\.id) == [newest.id, delayedID, oldest.id])
    #expect(!controller.canClearFinished)

    await delayed.drop()
    #expect(await laterFailure.value.error?.code == "CONNECT_FAILED")
    let failedNotice = try #require(controller.connectionNotices.first)
    #expect(controller.currentConnections.map(\.id) == [newest.id, failedNotice.id, oldest.id])
    #expect(await connect(1).error?.code == "CONNECT_FAILED")
    let authNotice = try #require(controller.connectionNotices.first { $0.needsAuthentication })

    await first.configureExecution(gate: work)
    let inFlight = Task { await controller.handle(ControlRequest(command: "exec", arguments: ["session": oldest.id.uuidString, "command": "synthetic"])) }
    try await waitUntil { oldest.automationRequests > 0 }
    await first.drop()
    #expect(controller.canClearFinished)
    await controller.clearFinishedConnections()
    #expect(controller.currentConnections.map(\.id) == [authNotice.id, newest.id, oldest.id])
    #expect(!controller.canClearFinished)
    await work.open()
    _ = await inFlight.value
    await controller.clearFinishedConnections()
    await controller.clearFinishedConnections()
    #expect(controller.currentConnections.map(\.id) == [authNotice.id, newest.id])
    #expect(app.backgroundSessions.map(\.id) == [newest.id] && newest.connected)
    #expect(app.recordTabs.contains { $0.id == record.id } && record.header.endReason == "连接意外断开")
    #expect(app.automationRecords.records.count == 4 && app.automationRecords.protectedServers.isEmpty)
    await controller.setEnabled(false); await app.shutdown()
}

@MainActor
@Test func clearFinishedLeavesPendingFileReviewAndTrust() async throws {
    let fixture = try SessionFixture(); defer { fixture.clean() }
    let restoreKey = seedHostKey(fixture.profiles[1].endpoint); defer { restoreKey() }
    let offline = FakeSessionConnection(home: fixture.remote(0))
    let reviewing = FakeSessionConnection(home: fixture.remote(0))
    let trust = FakeSessionConnection(home: fixture.remote(1), requiresTrust: true)
    let (app, controller) = try await recordController(fixture, transports: [offline, reviewing, trust])
    for _ in 0..<2 {
        try #require(await controller.handle(ControlRequest(command: "connect", arguments: ["profile": fixture.profiles[0].id.uuidString])).ok)
    }
    let ended = app.backgroundSessions[0], pending = app.backgroundSessions[1]
    try #require(await controller.handle(ControlRequest(command: "disconnect", arguments: ["session": ended.id.uuidString])).ok)
    do { try await pending.fileQueue.submit("synthetic") { throw FileConnectionFailure.closed }; Issue.record("预期文件操作待核对") }
    catch FileConnectionFailure.closed {}
    await reviewing.drop()
    let result = await controller.handle(ControlRequest(command: "connect", arguments: ["profile": fixture.profiles[1].id.uuidString]))
    #expect(result.error?.code == "NEEDS_USER_ACTION")
    let checking = try #require(app.backgroundSessions.last)
    await controller.clearFinishedConnections()
    #expect(!controller.canClearFinished && pending.fileQueue.paused && checking.hostTrustRequest != nil)
    #expect(app.backgroundSessions.map(\.id) == [pending.id, checking.id])
    #expect(app.automationRecords.record(sessionID: ended.id)?.header.endReason == "AI 断开连接")
    await controller.setEnabled(false); await app.shutdown()
}
