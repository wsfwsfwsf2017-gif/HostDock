import Foundation
import HostDockCore
import Testing
@testable import HostDock

@MainActor
@Test func protectionCancelsItsUploadCleansTemporaryFilesAndReleasesReservations() async throws {
    let fixture = try SessionFixture(); defer { fixture.clean() }
    let gate = TestGate()
    let transport = FakeSessionConnection(home: fixture.remote(0), store: GatedFileStore(gate: gate))
    let (app, controller) = try await recordController(fixture, transports: [transport])
    #expect(await controller.handle(ControlRequest(command: "connect", arguments: ["profile": fixture.profiles[0].id.uuidString])).ok)
    let session = try #require(app.backgroundSessions.first)
    let source = fixture.root.appendingPathComponent("agent-owned.bin")
    try Data(repeating: 0x61, count: 2048).write(to: source)
    let operation = Task { await controller.handle(ControlRequest(command: "files.upload", arguments: ["session": session.id.uuidString, "destination": fixture.remote(0)], paths: [source.path])) }
    for _ in 0..<200 { if await gate.entered { break }; try await Task.sleep(for: .milliseconds(5)) }
    #expect(await gate.entered)
    await controller.protectAndStop(session.id)
    #expect(await operation.value.error?.code == "SERVER_PROTECTED")
    #expect(await app.reservations.activeCount == 0)
    #expect(await app.reservations.waitingCount == 0)
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.remote(0)) == ["payload.txt"])
    #expect(try Data(contentsOf: source) == Data(repeating: 0x61, count: 2048))
    await controller.setEnabled(false); try await app.automationRecords.flush(); await app.shutdown()
}

@MainActor
@Test func protectionCancelsConnectingRequestBeforeConnectionCompletes() async throws {
    let fixture = try SessionFixture(); defer { fixture.clean() }
    let gate = TestGate()
    let transport = FakeSessionConnection(home: fixture.remote(0), connectionGate: gate)
    let (app, controller) = try await recordController(fixture, transports: [transport])
    let operation = Task { await controller.handle(ControlRequest(command: "connect", arguments: ["profile": fixture.profiles[0].id.uuidString])) }
    for _ in 0..<200 { if await gate.entered { break }; try await Task.sleep(for: .milliseconds(5)) }
    #expect(await gate.entered)
    let session = try #require(app.backgroundSessions.first)
    await controller.protectAndStop(session.id)
    let response = await operation.value
    #expect(response.error?.code == "SERVER_PROTECTED")
    #expect(app.backgroundSessions.isEmpty && !session.connected && !session.connecting)
    #expect(await controller.handle(ControlRequest(command: "connect", arguments: ["profile": session.profile.id.uuidString])).error?.code == "SERVER_PROTECTED")
    await controller.setEnabled(false); try await app.automationRecords.flush(); await app.shutdown()
}

@MainActor
@Test func protectionUsesJumpServerAssetInsteadOfSharedGatewayAndAllowsEarlyRelease() async throws {
    let fixture = try SessionFixture(); defer { fixture.clean() }
    let key = fixture.root.appendingPathComponent("synthetic-rsa")
    try Data("fake-transport-key-marker".utf8).write(to: key)
    var profiles = fixture.profiles
    for index in profiles.indices {
        profiles[index].connectionMode = .jumpServer
        profiles[index].jumpServer = JumpServerConfiguration(username: "张三", targetUsername: "ssta", targetHost: "192.0.2.\(index + 10)")
        profiles[index].endpoint = ConnectionEndpoint(host: "gateway.example", port: 2222, username: profiles[index].jumpServer!.loginUsername)
        profiles[index].authenticationKind = .rsaKey; profiles[index].privateKeyPath = key.path
    }
    let first = FakeSessionConnection(home: fixture.remote(0)), second = FakeSessionConnection(home: fixture.remote(1)), again = FakeSessionConnection(home: fixture.remote(0))
    let (app, controller) = try await recordController(fixture, transports: [first, second, again], profiles: profiles)
    for profile in profiles { #expect(await controller.handle(ControlRequest(command: "connect", arguments: ["profile": profile.id.uuidString])).ok) }
    let a = try #require(app.backgroundSessions.first), b = try #require(app.backgroundSessions.last)
    await controller.protectAndStop(a.id)
    let history = app.automationRecords
    #expect(history.protection(host: "192.0.2.10") != nil && history.protection(host: "gateway.example") == nil)
    #expect(b.connected && app.backgroundSessions.count == 1)
    #expect(await controller.handle(ControlRequest(command: "exec", arguments: ["session": b.id.uuidString, "command": "synthetic"])).ok)
    await history.release("192.0.2.10")
    #expect(history.protectedServers.isEmpty)
    #expect(await controller.handle(ControlRequest(command: "connect", arguments: ["profile": profiles[0].id.uuidString])).ok)
    await controller.setEnabled(false); try await history.flush(); await app.shutdown()
}
