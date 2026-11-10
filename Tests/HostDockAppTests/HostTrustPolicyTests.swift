import Foundation
import Testing
@testable import HostDock
import HostDockCore

@MainActor
func seedHostKey(_ endpoint: ConnectionEndpoint, fingerprint: String? = "SHA256:synthetic-previous") -> () -> Void {
    let identity = "[\(endpoint.host.lowercased())]:\(endpoint.port)"
    var keys = UserDefaults.standard.dictionary(forKey: "trustedHostKeys") ?? [:]
    let previous = keys[identity]
    keys[identity] = fingerprint
    UserDefaults.standard.set(keys, forKey: "trustedHostKeys")
    return {
        var current = UserDefaults.standard.dictionary(forKey: "trustedHostKeys") ?? [:]
        current[identity] = previous
        UserDefaults.standard.set(current, forKey: "trustedHostKeys")
    }
}

@MainActor
@Test func firstHostKeyIsRecordedWithoutPromptAndReusedAfterRestart() async throws {
    let fixture = try SessionFixture(); defer { fixture.clean() }
    let profile = try fixture.profiles[0].validated()
    let restore = seedHostKey(profile.endpoint, fingerprint: nil); defer { restore() }
    let transport = FakeSessionConnection(home: fixture.remote(0), requiresTrust: true)
    let app = fixture.app(transports: [transport])
    let first = try app.connect(profile: profile, password: "synthetic", rememberPassword: false)
    try await waitUntil { !first.connecting }
    #expect(first.connected && first.hostTrustRequest == nil)
    let identity = "[\(profile.endpoint.host)]:\(profile.endpoint.port)"
    let recorded = UserDefaults.standard.dictionary(forKey: "trustedHostKeys")?[identity] as? String
    #expect(recorded == "SHA256:synthetic-\(profile.endpoint.host)")
    await app.shutdown()
    let restarted = fixture.app(transports: [FakeSessionConnection(home: fixture.remote(0), requiresTrust: true)])
    let second = try restarted.connect(profile: profile, password: "synthetic", rememberPassword: false)
    try await waitUntil { !second.connecting }
    #expect(second.connected && second.hostTrustRequest == nil)
    await restarted.shutdown()
}

@MainActor
@Test func changedHostKeyNeedsApprovalAndCancellationKeepsThePreviousKey() async throws {
    let fixture = try SessionFixture(); defer { fixture.clean() }
    let profile = try fixture.profiles[0].validated()
    let restore = seedHostKey(profile.endpoint); defer { restore() }
    let transport = FakeSessionConnection(home: fixture.remote(0), requiresTrust: true)
    let app = fixture.app(transports: [transport])
    let session = try app.connect(profile: profile, password: "synthetic", rememberPassword: true)
    try await waitUntil { session.hostTrustRequest != nil }
    #expect(!session.connected && session.hostTrustRequest?.previous == "SHA256:synthetic-previous")
    session.cancelConnection(); try await waitUntil { !session.busy }
    let identity = "[\(profile.endpoint.host)]:\(profile.endpoint.port)"
    #expect(UserDefaults.standard.dictionary(forKey: "trustedHostKeys")?[identity] as? String == "SHA256:synthetic-previous")
    _ = try app.connect(profile: profile, password: "synthetic", rememberPassword: true, reusing: session)
    try await waitUntil { session.hostTrustRequest != nil }
    session.trustHost()
    try await waitUntil { !session.connecting }
    #expect(session.connected && session.hostTrustRequest == nil)
    #expect(UserDefaults.standard.dictionary(forKey: "trustedHostKeys")?[identity] as? String == "SHA256:synthetic-\(profile.endpoint.host)")
    await app.shutdown()
}

@MainActor
@Test func concurrentFirstConnectionsDoNotOverwriteADifferentRecordedKey() async throws {
    let fixture = try SessionFixture(); defer { fixture.clean() }
    let profile = try fixture.profiles[0].validated()
    let restore = seedHostKey(profile.endpoint, fingerprint: nil); defer { restore() }
    let first = FakeSessionConnection(home: fixture.remote(0), requiresTrust: true, hostFingerprint: "SHA256:first")
    let second = FakeSessionConnection(home: fixture.remote(0), requiresTrust: true, hostFingerprint: "SHA256:second")
    let app = fixture.app(transports: [first, second])
    let a = try app.connect(profile: profile, password: "synthetic", rememberPassword: false)
    let b = try app.connect(profile: profile, password: "synthetic", rememberPassword: false)
    try await waitUntil { a.connected || b.connected }
    try await waitUntil { a.hostTrustRequest != nil || b.hostTrustRequest != nil }
    #expect(a.connected != b.connected)
    let pending = a.hostTrustRequest == nil ? b : a
    #expect(pending.hostTrustRequest?.previous != pending.hostTrustRequest?.challenge.fingerprint)
    pending.cancelConnection()
    await app.shutdown()
}

@MainActor
@Test func automationFirstTrustDoesNotCreateAHumanTabOrTerminal() async throws {
    let fixture = try SessionFixture(); defer { fixture.clean() }
    var profile = try fixture.profiles[0].validated(); profile.lastValidatedAt = Date()
    let restore = seedHostKey(profile.endpoint, fingerprint: nil); defer { restore() }
    let credentials = MemoryCredentialStore()
    try await credentials.save("synthetic", account: profile.credentialAccount)
    let app = fixture.app(transports: [FakeSessionConnection(home: fixture.remote(0), requiresTrust: true)], credentials: credentials)
    let session = try app.connectBackground(profile: profile)
    try await waitUntil { !session.connecting }
    #expect(session.connected && session.hostTrustRequest == nil && !session.terminalRunning)
    #expect(app.sessions.isEmpty && app.selectedSessionID == nil && app.workspaceTabIDs.isEmpty && app.maximizeRequest == 0)
    await app.shutdown()
}

@MainActor
@Test func unreadableStoredFingerprintDoesNotBecomeAFirstTrust() async throws {
    let fixture = try SessionFixture(); defer { fixture.clean() }
    let profile = try fixture.profiles[0].validated()
    let restore = seedHostKey(profile.endpoint, fingerprint: nil); defer { restore() }
    let identity = "[\(profile.endpoint.host)]:\(profile.endpoint.port)"
    var keys = UserDefaults.standard.dictionary(forKey: "trustedHostKeys") ?? [:]
    keys[identity] = 42
    UserDefaults.standard.set(keys, forKey: "trustedHostKeys")
    let app = fixture.app(transports: [FakeSessionConnection(home: fixture.remote(0), requiresTrust: true)])
    let session = try app.connect(profile: profile, password: "synthetic", rememberPassword: false)
    try await waitUntil { session.hostTrustRequest != nil }
    #expect(!session.connected && session.hostTrustRequest?.previous == "已保存的指纹无法读取")
    session.cancelConnection(); try await waitUntil { !session.busy }
    #expect(UserDefaults.standard.dictionary(forKey: "trustedHostKeys")?[identity] as? Int == 42)
    await app.shutdown()
}
