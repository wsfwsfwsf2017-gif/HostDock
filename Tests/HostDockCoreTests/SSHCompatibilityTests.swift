import Citadel
import CryptoKit
import Foundation
import NIOCore
import NIOSSH
import Testing
@testable import HostDockCore

private actor CompatibilityTerminal {
    var ready = false
    var ended = false
    func markReady() { ready = true }
    func markEnded() { ended = true }
}

private struct PinnedCompatibilityHost: NIOSSHClientServerAuthenticationDelegate {
    let fingerprint: String
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let fields = String(openSSHPublicKey: hostKey).split(separator: " ")
        guard fields.count >= 2, let raw = Data(base64Encoded: String(fields[1])) else {
            validationCompletePromise.fail(SSHConnectionFailure.hostKey); return
        }
        let value = "SHA256:" + Data(SHA256.hash(data: raw)).base64EncodedString().replacingOccurrences(of: "=", with: "")
        if value == fingerprint { validationCompletePromise.succeed(()) }
        else { validationCompletePromise.fail(SSHConnectionFailure.hostKey) }
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["HOSTDOCK_SSH_COMPATIBILITY_CHECK"] == "1"))
func passwordServerHandshakeCompatibility() async throws {
    let env = ProcessInfo.processInfo.environment
    let host = try #require(env["HOSTDOCK_CHECK_HOST"])
    let user = try #require(env["HOSTDOCK_CHECK_USER"])
    let fingerprint = try #require(env["HOSTDOCK_CHECK_FINGERPRINTS"])
    guard let password = env["HOSTDOCK_CHECK_SECRET"], !password.isEmpty else { throw HostDockError("只读验收未提供运行时认证。") }
    var settings = SSHClientSettings(host: host, port: 22,
        authenticationMethod: { .passwordBased(username: user, password: password) },
        hostKeyValidator: .custom(PinnedCompatibilityHost(fingerprint: fingerprint)))
    settings.algorithms.publicKeyAlgorihtms = .add([(Insecure.RSA.PublicKey.self, Insecure.RSA.Signature.self)])
    do {
        let client = try await SSHClient.connect(to: settings)
        print("PASS SSH 密码握手与固定指纹")
        try await client.close()
        let connection = SSHConnection()
        do {
            let delay = Double(env["HOSTDOCK_CHECK_TRUST_DELAY"] ?? "0") ?? 0
            let result = try await connection.connect(host: host, port: 22, username: user, password: password,
                verifyHostKey: { challenge in
                    if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                    return challenge.fingerprint == fingerprint
                })
            let entries = try await result.store.list(at: result.home)
            print("PASS HostDock SSH/SFTP 登录与目录读取 · \(entries.count) 项（不输出文件名）")
            let state = CompatibilityTerminal()
            let terminal = Task {
                defer { Task { await state.markEnded() } }
                try await connection.runTerminal(columns: 100, rows: 30,
                    onReady: { await state.markReady() }, onOutput: { _ in })
            }
            for _ in 0..<500 {
                if await state.ready { break }
                if await state.ended { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let ready = await state.ready
            try #require(ready, "HostDock PTY 未就绪")
            try await connection.resizeTerminal(columns: 120, rows: 40)
            await connection.disconnect()
            terminal.cancel()
            _ = await terminal.result
            print("PASS HostDock 交互终端与尺寸同步；未发送命令")
        } catch { await connection.disconnect(); throw error }
    } catch {
        if let failure = error as? NIOSSHError { print("SSH handshake failure: " + failure.type.description) }
        else { print("SSH handshake failure type: " + String(reflecting: type(of: error))) }
        throw error
    }
}
