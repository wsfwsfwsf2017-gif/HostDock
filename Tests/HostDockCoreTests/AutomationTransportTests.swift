import Foundation
import Testing
@testable import HostDockCore

@Test func commandParserPreservesUTF8AndRejectsSecretsAsOptions() throws {
    let request = try ControlRequest.parse(["terminal", "send", "--session", UUID().uuidString, "--text", "echo 中文@账号", "--enter"])
    #expect(request.command == "terminal.send" && request.arguments["text"] == "echo 中文@账号" && request.arguments["enter"] == "true")
    let stdin = try ControlRequest.parse(["exec", "--session", UUID().uuidString, "--stdin"], input: "printf 'a b'\n")
    #expect(stdin.arguments["command"] == "printf 'a b'\n")
    #expect(throws: ControlFailure.self) { try ControlRequest.parse(["connect", "--password", "synthetic-only"]) }
    #expect(throws: ControlFailure.self) { try ControlRequest.parse(["exec", "--session"]) }
    #expect(throws: ControlFailure.self) { try ControlRequest.parse(["unknown"]) }
    let files = try ControlRequest.parse(["files", "upload", "--source", "/tmp/中文 a", "--source", "/tmp/b", "--destination", "/tmp/to", "--session", UUID().uuidString])
    #expect(files.paths == ["/tmp/中文 a", "/tmp/b"])
}

private actor CancellationFlag {
    var entered = false
    var cancelled = false
    func run() async {
        entered = true
        do { while true { try await Task.sleep(for: .seconds(1)) } }
        catch { cancelled = Task.isCancelled }
    }
    func state() -> (Bool, Bool) { (entered, cancelled) }
}

@Test func unixSocketIsPrivateRoundTripsAndDoesNotRemoveAnotherListener() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("hdc-" + UUID().uuidString.prefix(8))
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("control.sock")
    let server = ControlServer(url: url)
    try await server.start { request in ControlResponse(request.id, result: .string(request.arguments["text"] ?? "ok")) }
    let request = ControlRequest(command: "test", arguments: ["text": "中文多@字符"])
    #expect(try await ControlClient.call(request, url: url).result == .string("中文多@字符"))
    #expect((try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    #expect((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    let duplicate = ControlServer(url: url)
    await #expect(throws: (any Error).self) { try await duplicate.start { ControlResponse($0.id, result: .null) } }
    #expect(try await ControlClient.call(request, url: url).ok)
    var future = request; future.version = 99
    #expect(try await ControlClient.call(future, url: url).error?.code == "UNSUPPORTED_VERSION")
    await server.stop(); await server.stop()
    #expect(!FileManager.default.fileExists(atPath: url.path))
    let file = root.appendingPathComponent("keep.sock")
    try Data("keep-original".utf8).write(to: file)
    let bad = ControlServer(url: file)
    await #expect(throws: (any Error).self) { try await bad.start { ControlResponse($0.id, result: .null) } }
    #expect(try String(contentsOf: file, encoding: .utf8) == "keep-original")
}

@Test func closingClientCancelsOnlyItsServerRequest() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("hdc-" + UUID().uuidString.prefix(8))
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("control.sock")
    let flag = CancellationFlag()
    let server = ControlServer(url: url)
    try await server.start { request in
        if request.command == "wait" { await flag.run() }
        return ControlResponse(request.id, result: .string("ok"))
    }
    let client = Task { try await ControlClient.call(ControlRequest(command: "wait"), url: url) }
    for _ in 0..<300 { if await flag.state().0 { break }; try await Task.sleep(for: .milliseconds(10)) }
    #expect(await flag.state().0)
    client.cancel()
    _ = await client.result
    for _ in 0..<300 { if await flag.state().1 { break }; try await Task.sleep(for: .milliseconds(10)) }
    #expect(await flag.state().1)
    #expect(try await ControlClient.call(ControlRequest(command: "other"), url: url).ok)
    await server.stop()
}
