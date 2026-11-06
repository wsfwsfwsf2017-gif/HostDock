import AppKit
import Foundation
import Testing
@testable import HostDock
@testable import HostDockCore

actor FailingBrowserStore: FileStore {
    let base = LocalFileStore()
    var listGate: TestGate?
    var failure: Error?
    func configure(gate: TestGate? = nil, failure: Error? = nil) { listGate = gate; self.failure = failure }
    func canonicalDirectory(at path: String) async throws -> String { if let failure { throw failure }; return try await base.canonicalDirectory(at: path) }
    func list(at path: String) async throws -> [FileEntry] { try await listGate?.wait(); if let failure { throw failure }; return try await base.list(at: path) }
    func metadata(at path: String) async throws -> FileEntry? { try await base.metadata(at: path) }
    func createDirectory(at path: String) async throws { try await base.createDirectory(at: path) }
    func move(from: String, to: String) async throws { try await base.move(from: from, to: to) }
    func removeFile(at path: String) async throws { try await base.removeFile(at: path) }
    func openReader(at path: String) async throws -> any FileReader { try await base.openReader(at: path) }
    func createWriter(at path: String) async throws -> any FileWriter { try await base.createWriter(at: path) }
}

@MainActor
@Test func completedMutationDoesNotWaitForDirectoryRefresh() async throws {
    let fixture = try SessionFixture(); defer { fixture.clean() }
    let store = FailingBrowserStore(), refresh = TestGate(), executed = TestGate()
    let transport = FakeSessionConnection(home: fixture.remote(0), store: store)
    let app = fixture.app(transports: [transport])
    let session = try app.connect(profile: fixture.profiles[0], password: "synthetic", rememberPassword: true)
    try await waitUntil { session.connected && !session.connecting }
    await store.configure(gate: refresh)
    let first = Task { try await session.runFileOperation("第一个") {} }
    let second = Task { try await session.runFileOperation("第二个") { await executed.open() } }
    for _ in 0..<400 {
        if session.fileQueue.jobs.count == 2 && !session.transferring { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    // The next mutation must start even while a directory response is outstanding.
    let check = Task { try await executed.wait() }
    try await Task.sleep(for: .milliseconds(30))
    #expect(!session.transferring, "目录刷新不应占用已完成的修改任务")
    await refresh.open()
    try await first.value; try await second.value; try await check.value
    await app.shutdown()
}

@MainActor
@Test func fileQueueShowsPendingFIFOAndCancelsOnlyRequestedJob() async throws {
    let queue = FileOperationQueue(), gate = TestGate()
    var order: [Int] = []
    let first = Task { try await queue.submit("first") { order.append(1); try await gate.wait() } }
    try await waitUntil { queue.jobs.count == 1 }
    let second = Task { try await queue.submit("second") { order.append(2) } }
    try await waitUntil { queue.jobs.count == 2 }
    let third = Task { try await queue.submit("third") { order.append(3) } }
    try await waitUntil { queue.jobs.count == 3 }
    #expect(queue.jobs.map(\.state) == [.running, .queued, .queued])
    #expect(order == [1])
    second.cancel()
    do { try await second.value; Issue.record("等待任务应取消") } catch is CancellationError {}
    await gate.open()
    try await first.value; try await third.value
    #expect(order == [1, 3])
    #expect(queue.jobs.map(\.state) == [.succeeded, .cancelled, .succeeded])
    #expect(!queue.hasWork)
}

@MainActor
@Test func fileQueueContinuesOrdinaryErrorsButPausesUncertainMutations() async throws {
    let queue = FileOperationQueue(), gate = TestGate()
    let first = Task { try await queue.submit("slow") { try await gate.wait(); throw FileConnectionFailure.timedOut } }
    try await waitUntil { queue.jobs.count == 1 }
    var ran = false
    let second = Task { try await queue.submit("next") { ran = true; throw HostDockError("synthetic permission error") } }
    try await waitUntil { queue.jobs.count == 2 }
    await gate.open()
    do { try await first.value; Issue.record("预期超时") } catch is FileConnectionFailure {}
    #expect(queue.paused && !ran && queue.jobs[0].state == .review)
    queue.resumeWhenSafe()
    #expect(queue.paused && !ran)
    queue.resumeAfterReview()
    do { try await second.value; Issue.record("预期权限错误") } catch is HostDockError {}
    try await queue.submit("third") { ran = true }
    #expect(queue.jobs.last?.state == .succeeded && !queue.hasWork)
    for _ in 0..<55 { try await queue.submit("bounded") {} }
    #expect(queue.jobs.count == 50)
}

@MainActor
@Test func fileQueueShutdownCancelsWaitingAndDrainsActiveCleanup() async throws {
    let queue = FileOperationQueue(), gate = TestGate()
    var cleaned = false, dispatched = false
    let first = Task { try await queue.submit("active") { defer { cleaned = true }; try await gate.wait() } }
    try await waitUntil { queue.running }
    let second = Task { try await queue.submit("waiting") { dispatched = true } }
    try await waitUntil { queue.jobs.count == 2 }
    queue.cancelAll(); await queue.drain()
    _ = await first.result; _ = await second.result
    #expect(cleaned && !dispatched && !queue.hasWork)
    #expect(queue.jobs.allSatisfy { $0.state == .cancelled })
}

@MainActor
@Test func fileOnlyRecoveryPreservesTerminalViewportAndDoesNotReselect() async throws {
    let fixture = try SessionFixture(); defer { fixture.clean() }
    let store = FailingBrowserStore()
    let transport = FakeSessionConnection(home: fixture.remote(0), store: store)
    let app = fixture.app(transports: [transport])
    let session = try app.connect(profile: fixture.profiles[0], password: "synthetic", rememberPassword: true)
    try await waitUntil { session.connected && !session.connecting && session.terminalReady }
    await transport.emit("PRESERVE-TERMINAL\r\n")
    try await waitUntil { String(decoding: session.terminal.view.getBufferAsData(), as: UTF8.self).contains("PRESERVE-TERMINAL") }
    let terminal = session.terminal.view, generation = session.connectionGeneration
    let path = session.remote.path, directoryID = session.remote.directoryID, maximize = app.maximizeRequest
    session.remote.selection = [path + "/payload.txt"]; session.remote.scrollOrigin = NSPoint(x: 0, y: 80)
    await store.configure(failure: FileConnectionFailure.closed)
    await transport.configureFiles(failure: .closed, repair: LocalFileStore())
    await session.checkFileHealth()
    #expect(!session.connectionIndicatorHealthy && !session.remote.directoryReady)
    await session.remote.refresh()
    #expect(session.connected && session.filesHealthy && !session.remote.loading && session.remote.error == nil)
    #expect(await transport.repairs == 1)
    #expect(await transport.connects == 1)
    #expect(session.remote.path == path && session.remote.directoryID == directoryID && session.remote.scrollOrigin.y == 80)
    #expect(session.remote.selection == [path + "/payload.txt"] && session.connectionGeneration == generation)
    #expect(session.terminal.view === terminal && session.terminalReady && app.maximizeRequest == maximize)
    await app.shutdown()
}

@MainActor
@Test func sshRecoveryUsesSavedAuthenticationWithoutNewTabOrHistory() async throws {
    let fixture = try SessionFixture(); defer { fixture.clean() }
    let transport = FakeSessionConnection(home: fixture.remote(0))
    let app = fixture.app(transports: [transport])
    let session = try app.connect(profile: fixture.profiles[0], password: "synthetic", rememberPassword: true)
    try await waitUntil { session.connected && !session.connecting }
    let history = app.catalog.recent, tabs = app.sessions.map(\.id), maximize = app.maximizeRequest
    let path = session.remote.path, generation = session.connectionGeneration
    await transport.drop()
    #expect(!session.connected && !session.remote.directoryReady && session.remote.path == path)
    await session.remote.refresh()
    #expect(session.connected && session.filesHealthy && session.remote.error == nil)
    try await waitUntil { session.terminalReady }
    await transport.emit("AFTER-RECOVERY\r\n")
    try await waitUntil { String(decoding: session.terminal.view.getBufferAsData(), as: UTF8.self).contains("AFTER-RECOVERY") }
    #expect(await transport.connects == 2)
    #expect(await transport.authenticationSecrets.last == "synthetic")
    #expect(session.connectionGeneration == generation && app.sessions.map(\.id) == tabs && app.catalog.recent == history && app.maximizeRequest == maximize)
    await app.shutdown()
}

@MainActor
@Test func permissionFailureNeverReconnectsAndRefreshRecoveryIsBounded() async throws {
    let fixture = try SessionFixture(); defer { fixture.clean() }
    let store = FailingBrowserStore()
    let transport = FakeSessionConnection(home: fixture.remote(0), store: store)
    let app = fixture.app(transports: [transport])
    let session = try app.connect(profile: fixture.profiles[0], password: "synthetic", rememberPassword: true)
    try await waitUntil { session.connected && !session.connecting }
    await store.configure(failure: HostDockError("synthetic access denied"))
    await session.remote.refresh()
    #expect(session.remote.error != nil && !session.remote.loading && session.filesHealthy)
    #expect(await transport.repairs == 0)
    #expect(await transport.connects == 1)
    await store.configure(failure: FileConnectionFailure.timedOut)
    await transport.configureFiles(failure: .timedOut, repair: store)
    await session.remote.refresh()
    #expect(!session.remote.loading && !session.connectionIndicatorHealthy && session.remote.error != nil)
    #expect(await transport.repairs == 1)
    await app.shutdown()
}

@MainActor
@Test func queuedOperationsUseRepairedStoreWithoutChangingTarget() async throws {
    let fixture = try SessionFixture(); defer { fixture.clean() }
    let store = FailingBrowserStore(), gate = TestGate()
    let transport = FakeSessionConnection(home: fixture.remote(0), store: store)
    let app = fixture.app(transports: [transport])
    let session = try app.connect(profile: fixture.profiles[0], password: "synthetic", rememberPassword: true)
    try await waitUntil { session.connected && !session.connecting }
    let captured = try #require(session.remote.store), path = fixture.remote(0) + "/queued-directory"
    let first = Task { try await session.runFileOperation("first") { try await gate.wait() } }
    try await waitUntil { session.fileQueue.running }
    let second = Task { try await session.runFileOperation("second", remotePaths: [path]) { try await captured.createDirectory(at: path) } }
    try await waitUntil { session.fileQueue.jobs.count == 2 }
    await transport.configureFiles(failure: .closed, repair: LocalFileStore())
    await transport.drop()
    await gate.open()
    try await first.value; try await second.value
    #expect(FileManager.default.fileExists(atPath: path))
    #expect(session.fileQueue.jobs.map(\.state) == [.succeeded, .succeeded])
    await app.shutdown()
}

@MainActor
@Test func closingDuringRecoveryCannotPublishSuccessOrStartAnotherTerminal() async throws {
    let fixture = try SessionFixture(); defer { fixture.clean() }
    let gate = TestGate(); await gate.open()
    let transport = FakeSessionConnection(home: fixture.remote(0), connectionGate: gate)
    let app = fixture.app(transports: [transport])
    let session = try app.connect(profile: fixture.profiles[0], password: "synthetic", rememberPassword: true)
    try await waitUntil { session.connected && !session.connecting }
    await transport.drop(); await gate.close()
    let refresh = Task { await session.remote.refresh() }
    try await waitUntil { session.recoveringFiles && session.connecting }
    await app.shutdown(); await refresh.value
    #expect(!session.connected && !session.recoveringFiles && !session.terminalReady && session.remote.store == nil)
    #expect(await transport.connected == false)
}

@MainActor
@Test func healthProbeSkipsFileOperationsAndWakeChecksIdleConnection() async throws {
    let fixture = try SessionFixture(); defer { fixture.clean() }
    let transport = FakeSessionConnection(home: fixture.remote(0)), gate = TestGate()
    let app = fixture.app(transports: [transport])
    let session = try app.connect(profile: fixture.profiles[0], password: "synthetic", rememberPassword: true)
    try await waitUntil { session.connected && !session.connecting }
    let operation = Task { try await session.runFileOperation("slow") { try await gate.wait() } }
    try await waitUntil { session.fileQueue.running }
    await session.checkFileHealth()
    #expect(await transport.probes == 0)
    await gate.open(); try await operation.value
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
    for _ in 0..<100 { if await transport.probes > 0 { break }; try await Task.sleep(for: .milliseconds(5)) }
    #expect(await transport.probes == 1)
    await app.shutdown()
}

@MainActor
@Test func cancellingQueuedCallerReleasesAnActiveConflict() async throws {
    let fixture = try SessionFixture(); defer { fixture.clean() }
    let app = fixture.app(transports: [FakeSessionConnection(home: fixture.remote(0))])
    let session = try app.connect(profile: fixture.profiles[0], password: "synthetic", rememberPassword: true)
    try await waitUntil { session.connected && !session.connecting }
    let entry = try #require(session.local.roots.first?.entry)
    let copy = Task { try await FileActions(session: session, remote: false).copy([entry], toRemote: true, directory: fixture.remote(0), cut: false) }
    try await waitUntil { session.conflictRequest != nil }
    copy.cancel()
    _ = await copy.result
    #expect(!session.transferring && session.conflictRequest == nil && session.fileQueue.jobs.last?.state == .cancelled)
    await app.shutdown()
}

@MainActor
@Test func unsentTaskStaysQueuedUntilRecoveryAndCanBeCancelled() async throws {
    let queue = FileOperationQueue()
    var online = false, attempts = 0, executions = 0
    let request = Task { try await queue.submit("unsent") {
        attempts += 1
        guard online else { throw FileJobDeferred(reason: "not sent") }
        executions += 1
    } }
    try await waitUntil { queue.paused }
    #expect(queue.hasWork && queue.jobs.first?.state == .queued && executions == 0 && attempts == 1)
    online = true; queue.resumeWhenSafe()
    try await request.value
    #expect(executions == 1 && queue.jobs.first?.state == .succeeded)
    let cancelled = Task { try await queue.submit("offline") { throw FileJobDeferred(reason: "not sent") } }
    try await waitUntil { queue.paused }
    cancelled.cancel(); _ = await cancelled.result
    #expect(!queue.hasWork && queue.jobs.last?.state == .cancelled)
}
