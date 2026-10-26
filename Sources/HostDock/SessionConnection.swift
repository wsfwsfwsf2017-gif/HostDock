import Foundation
import HostDockCore

protocol SessionConnection: Sendable {
    func connect(host: String, port: Int, username: String, authentication: SSHAuthentication,
                 verifyHostKey: @escaping @Sendable (HostKeyChallenge) async -> Bool,
                 onDisconnect: @escaping @Sendable () async -> Void) async throws -> (store: any FileStore, home: String)
    func execute(_ command: String, timeout: Double) async throws -> SSHCommandResult
    func disconnect() async
    func runTerminal(columns: Int, rows: Int, onReady: @escaping @Sendable () async -> Void,
                     onOutput: @escaping @Sendable (Data) async -> Void) async throws
    func writeTerminal(_ data: Data) async throws
    func resizeTerminal(columns: Int, rows: Int) async throws
}

struct LiveSessionConnection: SessionConnection {
    let ssh = SSHConnection()
    func connect(host: String, port: Int, username: String, authentication: SSHAuthentication,
                 verifyHostKey: @escaping @Sendable (HostKeyChallenge) async -> Bool,
                 onDisconnect: @escaping @Sendable () async -> Void) async throws -> (store: any FileStore, home: String) {
        let result = try await ssh.connect(host: host, port: port, username: username, authentication: authentication,
                                          verifyHostKey: verifyHostKey, onDisconnect: onDisconnect)
        return (result.store, result.home)
    }
    func execute(_ command: String, timeout: Double) async throws -> SSHCommandResult { try await ssh.execute(command, timeout: timeout) }
    func disconnect() async { await ssh.disconnect() }
    func runTerminal(columns: Int, rows: Int, onReady: @escaping @Sendable () async -> Void,
                     onOutput: @escaping @Sendable (Data) async -> Void) async throws {
        try await ssh.runTerminal(columns: columns, rows: rows, onReady: onReady, onOutput: onOutput)
    }
    func writeTerminal(_ data: Data) async throws { try await ssh.writeTerminal(data) }
    func resizeTerminal(columns: Int, rows: Int) async throws { try await ssh.resizeTerminal(columns: columns, rows: rows) }
}

extension SessionConnection {
    func execute(_ command: String, timeout: Double) async throws -> SSHCommandResult {
        throw ControlFailure("EXEC_UNAVAILABLE", "当前连接未提供命令通道。")
    }
}
