import Foundation
import Testing
@testable import HostDockCore

private actor RequestGate {
    var pending: CheckedContinuation<Int, Never>?
    var aborted = false
    func wait() async -> Int { await withCheckedContinuation { pending = $0 } }
    func abort() { aborted = true; pending?.resume(returning: 1); pending = nil }
}

@Test func fileDeadlineEndsNonCooperativeRequestsAndClosesTransport() async throws {
    let gate = RequestGate(), start = ContinuousClock.now
    do {
        _ = try await fileRequestDeadline(seconds: 0.05, abort: { await gate.abort() }) { await gate.wait() }
        Issue.record("无响应请求应超时")
    } catch { #expect(error as? FileConnectionFailure == .timedOut) }
    #expect(start.duration(to: .now) < .seconds(1))
    for _ in 0..<100 { if await gate.aborted { break }; try await Task.sleep(for: .milliseconds(5)) }
    #expect(await gate.aborted)
}

@Test func fileDeadlineCancellationAndNormalCompletionAreSingleShot() async throws {
    let gate = RequestGate()
    let task = Task { try await fileRequestDeadline(seconds: 30, abort: { await gate.abort() }) { await gate.wait() } }
    for _ in 0..<100 { if await gate.pending != nil { break }; try await Task.sleep(for: .milliseconds(5)) }
    task.cancel()
    do { _ = try await task.value; Issue.record("取消应结束请求") }
    catch { #expect(error as? FileConnectionFailure == .interrupted) }
    for _ in 0..<100 { if await gate.aborted { break }; try await Task.sleep(for: .milliseconds(5)) }
    #expect(await gate.aborted)
    let normal = try await fileRequestDeadline(seconds: 0.05, abort: { Issue.record("完成后不能关闭连接") }) { 42 }
    #expect(normal == 42)
    try await Task.sleep(for: .milliseconds(80))
}
