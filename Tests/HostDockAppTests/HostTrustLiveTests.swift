import AppKit
import Foundation
import Testing
import HostDockCore
@testable import HostDock

@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["HOSTDOCK_TOFU_CHECK"] == "1"))
func liveFirstTrustReconnectAndChangedFingerprintCancellation() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let host = env["HOSTDOCK_CHECK_HOST"], let user = env["HOSTDOCK_CHECK_USER"],
          let expected = env["HOSTDOCK_CHECK_FINGERPRINTS"], let secret = env["HOSTDOCK_CHECK_SECRET"], !secret.isEmpty else {
        throw HostDockError("只读验收缺少运行时参数。")
    }
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    let fixture = try SessionFixture(); defer { fixture.clean() }
    let profile = try ConnectionProfile(name: "只读连接验收", endpoint: ConnectionEndpoint(host: host, port: 22, username: user),
        localStartDirectory: fixture.root.path).validated()
    let restore = seedHostKey(profile.endpoint, fingerprint: nil); defer { restore() }
    let catalog = ConnectionCatalog(storage: MemoryConnectionStorage())
    let model = SessionModel(profile: profile, catalog: catalog, credentials: MemoryCredentialStore())
    let identity = "[\(profile.endpoint.host)]:\(profile.endpoint.port)"
    do {
        for _ in 0..<2 {
            model.connect(profile: profile, password: secret, rememberPassword: false)
            try await waitUntil { !model.connecting || model.hostTrustRequest != nil }
            let connected = model.connected && model.remote.directoryReady && model.hostTrustRequest == nil
            try #require(connected, "首次或重复连接未通过")
            let recorded = UserDefaults.standard.dictionary(forKey: "trustedHostKeys")?[identity] as? String
            try #require(recorded == expected, "记录的服务器指纹与已核对值不一致")
            try await waitUntil { model.terminalReady }
            await model.remote.refresh()
            let readable = model.remote.error == nil && model.remote.directoryReady
            #expect(readable)
            await model.shutdown()
        }
        let restoreChanged = seedHostKey(profile.endpoint); defer { restoreChanged() }
        model.connect(profile: profile, password: secret, rememberPassword: false)
        try await waitUntil { model.hostTrustRequest != nil || !model.connecting }
        let changeRequested = model.hostTrustRequest?.previous == "SHA256:synthetic-previous" && !model.connected
        try #require(changeRequested, "指纹变化应保持未连接并等待人工确认")
        model.cancelConnection(); try await waitUntil { !model.busy }
        let retained = UserDefaults.standard.dictionary(forKey: "trustedHostKeys")?[identity] as? String
        #expect(retained == "SHA256:synthetic-previous")
        await model.shutdown()
        print("PASS 首次自动记录、重复连接不弹窗、SSH/SFTP/终端只读验证、变化提示及取消保留原指纹")
    } catch { await model.shutdown(); throw error }
}
