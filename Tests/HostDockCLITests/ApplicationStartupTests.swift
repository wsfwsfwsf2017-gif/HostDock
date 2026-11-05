import Foundation
import HostDockCore
import Testing
@testable import HostDockCLI

@MainActor
@Test func readyApplicationDoesNotLaunchOrHideItAgain() async throws {
    var launches = 0
    try await ApplicationStartup.prepare(probe: {}, launch: { launches += 1 })
    #expect(launches == 0)
}

@MainActor
@Test func startupWaitsForReadinessBeforeDispatchingTheRequest() async throws {
    var probes = 0, launches = 0, requests = 0
    try await ApplicationStartup.prepare(timeout: .seconds(2), probe: {
        probes += 1
        #expect(requests == 0)
        if probes < 3 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNREFUSED)) }
    }, launch: { launches += 1 })
    requests += 1
    #expect(probes == 3 && launches == 1 && requests == 1)
}

@MainActor
@Test(arguments: ["DISABLED", "FORBIDDEN", "CONNECTION_CLOSED", "INVALID_RESPONSE"])
func applicationErrorsAreNotRetriedOrHiddenByLaunching(code: String) async throws {
    var launches = 0
    do {
        try await ApplicationStartup.prepare(probe: { throw ControlFailure(code, "synthetic") }, launch: { launches += 1 })
        Issue.record("应用错误不应视为启动成功")
    } catch let error as ControlFailure { #expect(error.code == code) }
    #expect(launches == 0)
}

@MainActor
@Test func launchFailureAndTimeoutDoNotDispatchBusinessRequests() async throws {
    for code in ["DISABLED", "APP_UNAVAILABLE"] {
        var requests = 0
        do {
            try await ApplicationStartup.prepare(timeout: .zero, probe: {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
            }, launch: { if code == "DISABLED" { throw ControlFailure(code, "synthetic") } })
            requests += 1
            Issue.record("启动失败或超时不应继续业务请求")
        } catch let error as ControlFailure { #expect(error.code == code) }
        #expect(requests == 0)
    }
}

@MainActor
@Test func cancellingStartupStopsWaitingWithoutDispatchingARequest() async throws {
    var launches = 0, probes = 0, requests = 0
    let task = Task {
        try await ApplicationStartup.prepare(probe: {
            probes += 1
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNREFUSED))
        }, launch: { launches += 1 })
        requests += 1
    }
    while probes < 2 { try await Task.sleep(for: .milliseconds(10)) }
    task.cancel()
    do { try await task.value; Issue.record("取消启动应返回取消错误") }
    catch is CancellationError { }
    #expect(launches == 1 && requests == 0)
}

@MainActor
@Test func backgroundLaunchDoesNotActivateOrPromptOrCreateAnotherInstance() {
    let configuration = ApplicationStartup.configuration()
    #expect(!configuration.activates && configuration.hides)
    #expect(!configuration.promptsUserIfNeeded && !configuration.addsToRecentItems)
    #expect(!configuration.createsNewApplicationInstance)
}
