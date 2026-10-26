import Citadel
import CryptoKit
import Foundation
import Logging
import NIOCore
import NIOSSH

public struct HostKeyChallenge: Sendable {
    public let host: String
    public let port: Int
    public let algorithm: String
    public let fingerprint: String
    public var identity: String { "[\(host.lowercased())]:\(port)" }
}

private final class HostKeyValidator: NIOSSHClientServerAuthenticationDelegate, Sendable {
    let host: String
    let port: Int
    let verify: @Sendable (HostKeyChallenge) async -> Bool

    init(host: String, port: Int, verify: @escaping @Sendable (HostKeyChallenge) async -> Bool) {
        self.host = host
        self.port = port
        self.verify = verify
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let encoded = String(openSSHPublicKey: hostKey).split(separator: " ")
        guard encoded.count >= 2, let raw = Data(base64Encoded: String(encoded[1])) else {
            validationCompletePromise.fail(HostDockError("无法读取服务器指纹。"))
            return
        }
        let fingerprint = "SHA256:" + Data(SHA256.hash(data: raw)).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        let challenge = HostKeyChallenge(host: host, port: port, algorithm: String(encoded[0]), fingerprint: fingerprint)
        Task {
            if await verify(challenge) { validationCompletePromise.succeed(()) }
            else { validationCompletePromise.fail(SSHConnectionFailure.hostKey) }
        }
    }
}

public actor SSHConnection {
    private var client: SSHClient?
    private var terminalWriter: TTYStdinWriter?
    private var generation = UUID()
    private var commandCapability: Bool?
    public init() {}

    public func connect(
        host: String, port: Int, username: String, password: String,
        verifyHostKey: @escaping @Sendable (HostKeyChallenge) async -> Bool,
        onDisconnect: @escaping @Sendable () async -> Void = {}
    ) async throws -> (store: RemoteFileStore, home: String) {
        try await connect(host: host, port: port, username: username, authentication: .password(password),
                          verifyHostKey: verifyHostKey, onDisconnect: onDisconnect)
    }

    public func connect(
        host: String, port: Int, username: String, authentication: SSHAuthentication,
        verifyHostKey: @escaping @Sendable (HostKeyChallenge) async -> Bool,
        onDisconnect: @escaping @Sendable () async -> Void = {}
    ) async throws -> (store: RemoteFileStore, home: String) {
        guard !host.isEmpty, !username.isEmpty, (1...65535).contains(port) else {
            throw HostDockError("请填写服务器、用户名以及有效端口。")
        }
        await disconnect()
        let token = generation
        let validator = HostKeyValidator(host: host, port: port, verify: verifyHostKey)
        let method = try authentication.method(username: username)
        var settings = SSHClientSettings(host: host, port: port,
            authenticationMethod: { method },
            hostKeyValidator: .custom(validator))
        settings.algorithms.publicKeyAlgorihtms = .add([(Insecure.RSA.PublicKey.self, Insecure.RSA.Signature.self)])
        settings.connectTimeout = .seconds(60)
        let connected: SSHClient
        do { connected = try await SSHClient.connect(to: settings) }
        catch let failure as SSHConnectionFailure { throw failure }
        catch let error as SSHClientError {
            switch error {
            case .allAuthenticationOptionsFailed, .unsupportedPasswordAuthentication, .unsupportedPrivateKeyAuthentication:
                throw SSHConnectionFailure.authentication
            default: throw SSHConnectionFailure.network
            }
        }
        catch { throw SSHConnectionFailure.network }
        guard token == generation, !Task.isCancelled else {
            try? await connected.close()
            throw CancellationError()
        }
        client = connected
        connected.onDisconnect { [weak self] in
            Task { await self?.didDisconnect(token: token, notify: onDisconnect) }
        }
        do {
            var logger = Logger(label: "HostDock.SFTP")
            logger.logLevel = .critical
            let store = RemoteFileStore(client: try await connected.openSFTP(logger: logger))
            let home = try await store.canonicalDirectory(at: ".")
            guard token == generation, !Task.isCancelled else { throw CancellationError() }
            return (store, home)
        } catch {
            if token == generation { await disconnect() }
            else { try? await connected.close() }
            if error is CancellationError { throw error }
            throw SSHConnectionFailure.sftp
        }
    }

    public func disconnect() async {
        generation = UUID()
        commandCapability = nil
        let closing = client
        client = nil
        terminalWriter = nil
        try? await closing?.close()
    }

    private func didDisconnect(token: UUID, notify: @Sendable () async -> Void) async {
        guard token == generation else { return }
        generation = UUID()
        client = nil
        terminalWriter = nil
        await notify()
    }

    public func runTerminal(
        columns: Int, rows: Int,
        onReady: @escaping @Sendable () async -> Void = {},
        onOutput: @escaping @Sendable (Data) async -> Void
    ) async throws {
        guard let client else { throw HostDockError("请先连接服务器。") }
        guard terminalWriter == nil else { throw HostDockError("终端会话已打开。") }
        let token = generation
        defer { if token == generation { terminalWriter = nil } }
        do {
            try await client.withPTY(.init(
                wantReply: true, term: "xterm-256color",
                terminalCharacterWidth: max(1, columns), terminalRowHeight: max(1, rows),
                terminalPixelWidth: 0, terminalPixelHeight: 0, terminalModes: .init([:])
            )) { output, input in
                self.installTerminalWriter(input, token: token)
                await onReady()
                for try await chunk in output {
                    switch chunk {
                    case .stdout(let buffer), .stderr(let buffer):
                        await onOutput(Data(buffer.readableBytesView))
                    }
                }
            }
        } catch ChannelError.alreadyClosed {
            // The server can close an exited shell before Citadel closes the PTY again.
        }
    }

    private func installTerminalWriter(_ writer: TTYStdinWriter, token: UUID) {
        if generation == token { terminalWriter = writer }
    }

    public func writeTerminal(_ data: Data) async throws {
        guard let terminalWriter else { throw HostDockError("终端尚未就绪。") }
        try await terminalWriter.write(ByteBuffer(bytes: data))
    }

    public func resizeTerminal(columns: Int, rows: Int) async throws {
        try await terminalWriter?.changeSize(cols: max(1, columns), rows: max(1, rows), pixelWidth: 0, pixelHeight: 0)
    }
}

public struct SSHCommandResult: Sendable {
    public let stdout: Data
    public let stderr: Data
    public let exitCode: Int
    public init(stdout: Data, stderr: Data = Data(), exitCode: Int = 0) {
        self.stdout = stdout; self.stderr = stderr; self.exitCode = exitCode
    }
}

extension SSHConnection {
    public func execute(_ command: String, timeout: Double = 30) async throws -> SSHCommandResult {
        guard !command.isEmpty, !command.contains("\0"), command.utf8.count <= 65_536, timeout.isFinite, (0.1...3600).contains(timeout) else {
            throw ControlFailure("INVALID_ARGUMENT", "命令需为有效文本，超时范围为 0.1–3600 秒。")
        }
        if commandCapability == nil {
            let marker = "HDPROBE" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            do {
                let probe = try await executeUnchecked("printf '%s' '" + marker + "OUT'; printf '%s' '" + marker + "ERR' >&2; exit 23", timeout: min(10, timeout))
                commandCapability = probe.exitCode == 23 && String(decoding: probe.stdout, as: UTF8.self).contains(marker + "OUT")
                    && String(decoding: probe.stderr, as: UTF8.self).contains(marker + "ERR")
            } catch let failure as ControlFailure where failure.code == "EXIT_STATUS_UNAVAILABLE" { commandCapability = false }
        }
        guard commandCapability == true else { throw ControlFailure("EXEC_UNAVAILABLE", "网关没有可靠保留命令退出码或标准输出／错误流，请使用 terminal send/read 交互终端。") }
        return try await executeUnchecked(command, timeout: timeout)
    }

    private func executeUnchecked(_ command: String, timeout: Double) async throws -> SSHCommandResult {
        guard let client else { throw ControlFailure("SESSION_OFFLINE", "服务器未连接。") }
        guard !command.isEmpty, !command.contains("\0"), command.utf8.count <= 65_536, timeout.isFinite, (0.1...3600).contains(timeout) else {
            throw ControlFailure("INVALID_ARGUMENT", "命令需为有效文本，超时范围为 0.1–3600 秒。")
        }
        let token = generation
        let result = try await withThrowingTaskGroup(of: SSHCommandResult.self) { group in
            group.addTask {
                var stdout = Data(), stderr = Data(), exitCode = 0
                var streamFailure: Error?
                var streamFinished = false
                do {
                    try await client.withExec(command) { input, _ in
                        do {
                            for try await chunk in input {
                                try Task.checkCancellation()
                                switch chunk {
                                case .stdout(let buffer): stdout.append(contentsOf: buffer.readableBytesView)
                                case .stderr(let buffer): stderr.append(contentsOf: buffer.readableBytesView)
                                }
                                guard stdout.count + stderr.count <= 524_288 else { throw ControlFailure("OUTPUT_LIMIT", "命令输出超过 512 KiB，本次命令通道已关闭。") }
                            }
                            try Task.checkCancellation()
                            streamFinished = true
                        } catch { streamFailure = error; throw error }
                    }
                } catch {
                    // Citadel 二次关闭已结束通道时，不能丢掉原来的退出码或流错误。
                    let original = streamFailure ?? error
                    if Task.isCancelled || original is CancellationError { throw CancellationError() }
                    if let failure = original as? SSHClient.CommandFailed { exitCode = failure.exitCode }
                    else if original is SSHClient.CommandExitStatusUnavailable {
                        throw ControlFailure("EXIT_STATUS_UNAVAILABLE", "命令可能已经执行，但服务端未提供退出状态；不要自动重复执行。")
                    }
                    else if let failure = original as? ControlFailure { throw failure }
                    else if streamFinished, let channelError = error as? ChannelError, channelError == .alreadyClosed {}
                    else { throw ControlFailure("EXEC_UNAVAILABLE", "服务器未能完成标准命令通道，请使用 terminal send/read 交互终端。") }
                }
                return SSHCommandResult(stdout: stdout, stderr: stderr, exitCode: exitCode)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw ControlFailure("TIMEOUT", "命令执行超时，本次命令通道已关闭。")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
        guard token == generation else { throw ControlFailure("SESSION_CHANGED", "执行期间原连接已关闭。") }
        return result
    }
}
